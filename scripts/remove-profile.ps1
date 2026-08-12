# remove-profile.ps1 <name> [-DeleteCredential]
#
# Deletes a profile and its rendered shims. Refuses when the profile is the
# active one - switch away first, so a live settings.local.json is never
# left pointing at a profile that no longer exists.
#
# -DeleteCredential also removes the profile's Credential Manager entry
# (credman auth only). Off by default: the same target may be shared.
#
# Exit codes: 0 ok | 1 runtime | 2 usage | 3 not found | 5 active (locked)

param(
    [Parameter(Position = 0)][string]$Name = '',
    [switch]$DeleteCredential
)

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'lib.ps1')

function Get-Prop {
    param($Obj, [string]$PropName)
    if ($null -eq $Obj) { return $null }
    $p = $Obj.PSObject.Properties[$PropName]
    if ($null -eq $p) { return $null }
    return $p.Value
}

if ($Name -eq '') {
    [Console]::Error.WriteLine('usage: remove-profile.ps1 <name> [-DeleteCredential]')
    exit $EXIT_USAGE
}

$path = Get-ProfilePath -Name $Name
if (-not (Test-Path -LiteralPath $path)) {
    [Console]::Error.WriteLine("provider: profile not found: $Name")
    exit $EXIT_NOT_FOUND
}

try {
    $scope = Read-SidecarScope -ScopeKey 'global'
} catch {
    [Console]::Error.WriteLine("provider: $($_.Exception.Message)")
    exit $EXIT_RUNTIME
}
if ($null -ne $scope -and [string](Get-Prop $scope 'active_profile') -ceq $Name) {
    [Console]::Error.WriteLine("provider: '$Name' is the active profile and cannot be removed.")
    [Console]::Error.WriteLine('  Switch to another profile first: /provider:switch <other>')
    exit $EXIT_LOCKED
}

# Read auth details before deleting, in case the credential goes too.
$credTarget = ''
try {
    $doc = Read-JsonFile -Path $path
    $auth = Get-Prop $doc 'auth'
    if ([string](Get-Prop $auth 'type') -eq 'credman') {
        $credTarget = [string](Get-Prop $auth 'target')
    }
} catch {
    # An unparseable profile can still be removed.
}

try {
    Remove-Item -LiteralPath $path -Force
} catch {
    [Console]::Error.WriteLine("provider: failed to delete profile: $($_.Exception.Message)")
    exit $EXIT_RUNTIME
}

$helpersDir = Get-HelpersDir
foreach ($ext in @('.ps1', '.cmd')) {
    $shim = Join-Path $helpersDir ($Name + $ext)
    if (Test-Path -LiteralPath $shim) { Remove-Item -LiteralPath $shim -Force -ErrorAction SilentlyContinue }
}

Write-Output "provider: removed profile '$Name'"

if ($DeleteCredential) {
    if ($credTarget -eq '') {
        Write-Output '  (no credman credential associated with this profile)'
    } elseif (Remove-StoredCredential -Target $credTarget) {
        Write-Output "  also deleted Credential Manager entry '$credTarget'"
    } else {
        Write-Output "  note: no Credential Manager entry found for '$credTarget'"
    }
} elseif ($credTarget -ne '') {
    Write-Output "  note: Credential Manager entry '$credTarget' was left in place (pass -DeleteCredential to remove it)"
}
exit $EXIT_OK
