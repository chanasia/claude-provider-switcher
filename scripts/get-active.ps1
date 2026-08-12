# get-active.ps1 [-Json]
#
# Reports the effective provider profile: what's active on disk (sidecar),
# what the running session was started with (CLAUDE_PROVIDER_ACTIVE env
# marker), and whether the two disagree (stale — restart pending).
# Output is redacted by design: profiles contain references, never secrets.
#
# Exit codes: 0 ok | 1 runtime (corrupt sidecar)

param(
    [switch]$Json
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

try {
    $scope = Read-SidecarScope -ScopeKey 'global'
} catch {
    [Console]::Error.WriteLine("provider: $($_.Exception.Message)")
    exit $EXIT_RUNTIME
}

$active = $null
if ($null -ne $scope) { $active = [string](Get-Prop $scope 'active_profile') }
$marker = $env:CLAUDE_PROVIDER_ACTIVE
$stale = $false
if ($null -ne $active -and $active -ne '') {
    $stale = ($marker -cne $active)
}

# ---- profile summary (references only — nothing secret exists to leak) ----
$summary = $null
if ($null -ne $active -and $active -ne '') {
    $profilePath = Get-ProfilePath -Name $active
    if (Test-Path -LiteralPath $profilePath) {
        try {
            $doc = Read-JsonFile -Path $profilePath
            $auth = Get-Prop $doc 'auth'
            $authType = [string](Get-Prop $auth 'type')
            $authRef = ''
            if ($authType -eq 'credman') { $authRef = [string](Get-Prop $auth 'target') }
            if ($authType -eq 'env_var') { $authRef = [string](Get-Prop $auth 'var') }
            $summary = New-Object PSObject -Property @{
                description = [string](Get-Prop $doc 'description')
                base_url    = [string](Get-Prop $doc 'base_url')
                auth_type   = $authType
                auth_ref    = $authRef
                model       = [string](Get-Prop $doc 'model')
            }
        } catch {
            [Console]::Error.WriteLine("provider: warning: active profile file is unreadable: $profilePath")
        }
    } else {
        [Console]::Error.WriteLine("provider: warning: active profile '$active' has no profile file (was it removed?)")
    }
}

if ($Json) {
    $out = New-Object PSObject -Property @{
        active_profile = $active
        session_marker = $(if ([string]::IsNullOrEmpty($marker)) { $null } else { $marker })
        stale          = $stale
        profile        = $summary
    }
    Write-Output ($out | ConvertTo-Json -Depth 5)
    exit $EXIT_OK
}

if ($null -eq $active -or $active -eq '') {
    Write-Output 'provider: no profile is active (run /provider:switch <name>, or /provider:init for first-time setup)'
    if (-not [string]::IsNullOrEmpty($marker)) {
        Write-Output "  note: this session was started with profile '$marker', but the sidecar no longer tracks it."
    }
    exit $EXIT_OK
}

Write-Output "active profile (on disk): $active"
if ([string]::IsNullOrEmpty($marker)) {
    Write-Output 'session marker (env):     (none — this session predates the switch)'
} else {
    Write-Output "session marker (env):     $marker"
}
if ($stale) {
    Write-Output 'status:                   STALE — restart Claude Code to activate the on-disk profile'
} else {
    Write-Output 'status:                   in effect'
}
if ($null -ne $summary) {
    if ($summary.description) { Write-Output "  description: $($summary.description)" }
    if ($summary.base_url) { Write-Output "  base_url:    $($summary.base_url)" } else { Write-Output '  base_url:    (default — Anthropic direct)' }
    if ($summary.auth_ref) {
        Write-Output "  auth:        $($summary.auth_type) -> $($summary.auth_ref)"
    } else {
        Write-Output "  auth:        $($summary.auth_type)"
    }
    if ($summary.model) { Write-Output "  model:       $($summary.model)" }
}
exit $EXIT_OK
