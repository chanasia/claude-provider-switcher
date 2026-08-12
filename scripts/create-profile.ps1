# create-profile.ps1 -Name <name> -AuthType none|credman|env_var
#                    [-Description <text>] [-BaseUrl <url>] [-Model <name>]
#                    [-CredTarget <target>] [-EnvVar <VAR>] [-TtlMs <int>]
#                    [-Extra KEY=VALUE -Extra KEY2=VALUE2] [-Force]
#
# Non-interactive profile creation. The /provider:add command collects the
# values through AskUserQuestion and calls this. Never accepts a token -
# secrets go to Credential Manager via set-credential.ps1.
#
# Exit codes: 0 ok | 1 runtime | 2 usage | 4 already exists | 6 schema

# CredTarget is a Credential Manager target NAME (a reference), never a secret.
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSAvoidUsingPlainTextForPassword', 'CredTarget',
    Justification = 'Target name is a reference into Credential Manager, not secret material')]
param(
    [string]$Name = '',
    [string]$AuthType = '',
    [string]$Description = '',
    [string]$BaseUrl = '',
    [string]$Model = '',
    [string]$CredTarget = '',
    [string]$EnvVar = '',
    [string]$TtlMs = '',
    [string[]]$Extra = @(),
    [switch]$Force
)

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'lib.ps1')

if ($Name -eq '' -or $AuthType -eq '') {
    [Console]::Error.WriteLine('usage: create-profile.ps1 -Name <name> -AuthType none|credman|env_var [options]')
    exit $EXIT_USAGE
}
if ($AuthType -notin @('none', 'credman', 'env_var')) {
    [Console]::Error.WriteLine("provider: -AuthType must be none, credman, or env_var (got '$AuthType')")
    exit $EXIT_USAGE
}

$dest = Get-ProfilePath -Name $Name
if ((Test-Path -LiteralPath $dest) -and -not $Force) {
    [Console]::Error.WriteLine("provider: profile already exists: $Name")
    [Console]::Error.WriteLine('  pass -Force to overwrite, or pick another name')
    exit $EXIT_EXISTS
}

# ---- build the profile object ----
$doc = New-Object PSObject
$doc | Add-Member -MemberType NoteProperty -Name 'name' -Value $Name
if ($Description -ne '') { $doc | Add-Member -MemberType NoteProperty -Name 'description' -Value $Description }
if ($BaseUrl -ne '') { $doc | Add-Member -MemberType NoteProperty -Name 'base_url' -Value $BaseUrl }

$auth = New-Object PSObject
$auth | Add-Member -MemberType NoteProperty -Name 'type' -Value $AuthType
if ($AuthType -eq 'credman') {
    if ($CredTarget -eq '') {
        [Console]::Error.WriteLine('provider: -CredTarget is required for -AuthType credman')
        exit $EXIT_USAGE
    }
    $auth | Add-Member -MemberType NoteProperty -Name 'target' -Value $CredTarget
} elseif ($AuthType -eq 'env_var') {
    if ($EnvVar -eq '') {
        [Console]::Error.WriteLine('provider: -EnvVar is required for -AuthType env_var')
        exit $EXIT_USAGE
    }
    $auth | Add-Member -MemberType NoteProperty -Name 'var' -Value $EnvVar
}
$doc | Add-Member -MemberType NoteProperty -Name 'auth' -Value $auth

if ($Model -ne '') { $doc | Add-Member -MemberType NoteProperty -Name 'model' -Value $Model }
if ($TtlMs -ne '') {
    $ttlInt = 0
    if (-not [int]::TryParse($TtlMs, [ref]$ttlInt)) {
        [Console]::Error.WriteLine("provider: -TtlMs must be an integer (got '$TtlMs')")
        exit $EXIT_USAGE
    }
    $doc | Add-Member -MemberType NoteProperty -Name 'ttl_ms' -Value $ttlInt
}

if ($Extra.Count -gt 0) {
    $extras = New-Object PSObject
    foreach ($pair in $Extra) {
        $idx = $pair.IndexOf('=')
        if ($idx -lt 1) {
            [Console]::Error.WriteLine("provider: -Extra entries must be KEY=VALUE (got '$pair')")
            exit $EXIT_USAGE
        }
        $k = $pair.Substring(0, $idx)
        $v = $pair.Substring($idx + 1)
        if ($null -ne $extras.PSObject.Properties[$k]) { $extras.PSObject.Properties.Remove($k) }
        $extras | Add-Member -MemberType NoteProperty -Name $k -Value $v
    }
    $doc | Add-Member -MemberType NoteProperty -Name 'extras' -Value $extras
}

# ---- write to a temp file, validate, then move into place ----
$dir = Get-ProfileDir
$null = New-Item -ItemType Directory -Path $dir -Force
$staging = Join-Path $dir ".staging-$Name.json"
$json = ($doc | ConvertTo-Json -Depth 10) + "`n"

try {
    Write-AtomicFile -Path $staging -Content $json
    # Validation checks name-matches-filename, so validate under the final name.
    $probe = Join-Path ([System.IO.Path]::GetTempPath()) ("cps-" + [System.IO.Path]::GetRandomFileName())
    $null = New-Item -ItemType Directory -Path $probe -Force
    $probeFile = Join-Path $probe ($Name + '.json')
    [System.IO.File]::WriteAllText($probeFile, $json, (New-Object System.Text.UTF8Encoding($false)))

    & powershell.exe -NoProfile -NonInteractive -ExecutionPolicy Bypass `
        -File (Join-Path $PSScriptRoot 'validate-profile.ps1') $probeFile | Out-Null
    $validateExit = $LASTEXITCODE
    Remove-Item -LiteralPath $probe -Recurse -Force -ErrorAction SilentlyContinue

    if ($validateExit -ne 0) {
        Remove-Item -LiteralPath $staging -Force -ErrorAction SilentlyContinue
        [Console]::Error.WriteLine("provider: refusing to write an invalid profile (see errors above)")
        exit $EXIT_SCHEMA
    }

    Move-Item -LiteralPath $staging -Destination $dest -Force
} catch {
    Remove-Item -LiteralPath $staging -Force -ErrorAction SilentlyContinue
    [Console]::Error.WriteLine("provider: $($_.Exception.Message)")
    exit $EXIT_RUNTIME
}

Write-Output "provider: created profile '$Name' at $dest"
if ($AuthType -eq 'credman') {
    Write-Output "  auth: credman -> $CredTarget"
    if (-not (Test-StoredCredential -Target $CredTarget)) {
        Write-Output "  note: no credential is stored under that target yet - the switch will fail until you store one."
    }
} elseif ($AuthType -eq 'env_var') {
    Write-Output "  auth: env_var -> $EnvVar"
}
Write-Output "  activate with: /provider:switch $Name  (then restart Claude Code)"
exit $EXIT_OK
