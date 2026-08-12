# set-credential.ps1 -Target <name> [-Secret <value>]
#
# Stores a secret in Windows Credential Manager under a generic-credential
# target. Run it with only -Target and it prompts for the token with the
# input hidden:
#
#   powershell -NoProfile -File set-credential.ps1 -Target claude-provider/my-gateway
#
# When stdin is redirected the value is read from there instead:
#
#   Get-Content token.txt | powershell -File set-credential.ps1 -Target claude-provider/my-gateway
#
# -Secret exists for tests and scripted setup only. Do NOT use it from an
# assistant-run command: a command line is visible in process listings and
# shell history, and Claude Code records approved commands verbatim in
# settings.local.json, which would put the token in a file (invariant 1).
#
# Exit codes: 0 ok | 1 runtime | 2 usage

param(
    [string]$Target = '',
    [string]$Secret = '',
    [switch]$Test
)

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'lib.ps1')

if ($Target -eq '') {
    [Console]::Error.WriteLine('usage: set-credential.ps1 -Target <name> [-Secret <value>] [-Test]')
    exit $EXIT_USAGE
}
if ($Target -cnotmatch '^[A-Za-z0-9_./-]{1,255}$') {
    [Console]::Error.WriteLine('provider: target must match ^[A-Za-z0-9_./-]{1,255}$')
    exit $EXIT_USAGE
}

# -Test: existence check only - never reads or prints the value. Lets the
# add wizard verify the user stored the token without the token ever
# passing through the conversation.
if ($Test) {
    if (Test-StoredCredential -Target $Target) {
        Write-Output "provider: a credential is stored under '$Target'."
        exit $EXIT_OK
    }
    [Console]::Error.WriteLine("provider: no credential stored under '$Target'.")
    exit $EXIT_NOT_FOUND
}

if ($Secret -eq '') {
    $stdinRedirected = $true
    try { $stdinRedirected = [Console]::IsInputRedirected } catch { $stdinRedirected = $true }
    if (-not $stdinRedirected) {
        # Interactive console: prompt with input hidden, so the token never
        # appears on screen, on a command line, or in shell history.
        $secure = Read-Host -Prompt "Token for '$Target' (input is hidden)" -AsSecureString
        $bstr = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($secure)
        try {
            $Secret = [Runtime.InteropServices.Marshal]::PtrToStringBSTR($bstr)
        } finally {
            [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($bstr)
        }
        if ($null -ne $Secret) { $Secret = $Secret.Trim() }
    } else {
        $Secret = [Console]::In.ReadToEnd()
        if ($null -ne $Secret) { $Secret = $Secret.Trim() }
    }
}
if ([string]::IsNullOrEmpty($Secret)) {
    [Console]::Error.WriteLine('provider: no secret provided (pass -Secret or pipe it via stdin)')
    exit $EXIT_USAGE
}

try {
    Set-StoredCredential -Target $Target -Secret $Secret
} catch {
    [Console]::Error.WriteLine("provider: $($_.Exception.Message)")
    exit $EXIT_RUNTIME
}

Write-Output "provider: credential stored in Windows Credential Manager under '$Target'."
exit $EXIT_OK
