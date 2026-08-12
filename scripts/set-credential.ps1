# set-credential.ps1 -Target <name> [-Secret <value>]
#
# Stores a secret in Windows Credential Manager under a generic-credential
# target. When -Secret is omitted the value is read from stdin, so it never
# has to appear on a command line (command lines are visible in process
# listings and shell history):
#
#   Get-Content token.txt | powershell -File set-credential.ps1 -Target claude-provider/my-gateway
#
# Exit codes: 0 ok | 1 runtime | 2 usage

param(
    [string]$Target = '',
    [string]$Secret = ''
)

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'lib.ps1')

if ($Target -eq '') {
    [Console]::Error.WriteLine('usage: set-credential.ps1 -Target <name> [-Secret <value>]')
    exit $EXIT_USAGE
}
if ($Target -cnotmatch '^[A-Za-z0-9_./-]{1,255}$') {
    [Console]::Error.WriteLine('provider: target must match ^[A-Za-z0-9_./-]{1,255}$')
    exit $EXIT_USAGE
}

if ($Secret -eq '') {
    $Secret = [Console]::In.ReadToEnd()
    if ($null -ne $Secret) { $Secret = $Secret.Trim() }
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
