# reset.ps1 [-Force]
#
# Removes EVERYTHING this plugin put on the machine, except the plugin
# installation inside Claude Code itself:
#
#   1. plugin-managed keys in ~\.claude\settings.json AND the legacy
#      ~\.claude\settings.local.json (other keys in both files are
#      preserved) -> the next session is Anthropic direct
#   2. ~\.claude\provider-profiles\  (profiles, sidecar, shims, locks)
#   3. Windows Credential Manager entries referenced by credman profiles
#   4. the offline CLI in ~\.claude\bin (claude-provider.*, legacy
#      provider.*) and its user-Path entry
#
# Asks for confirmation unless -Force is given (non-interactive hosts
# must pass -Force).
#
# Exit codes: 0 done | 1 runtime | 2 refused / not confirmed

param(
    [switch]$Force
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

function Remove-Prop {
    param($Obj, [string]$PropName)
    if ($null -ne $Obj -and $null -ne $Obj.PSObject.Properties[$PropName]) {
        $Obj.PSObject.Properties.Remove($PropName)
    }
}

# ---- confirmation ----
if (-not $Force) {
    [Console]::Error.WriteLine('This removes ALL plugin state on this machine:')
    [Console]::Error.WriteLine('  - plugin-managed keys in settings.json / settings.local.json (back to Anthropic direct)')
    [Console]::Error.WriteLine('  - every profile, the sidecar, and rendered helper shims')
    [Console]::Error.WriteLine('  - Credential Manager entries referenced by your profiles')
    [Console]::Error.WriteLine('  - the offline claude-provider CLI')
    [Console]::Error.WriteLine('The plugin itself stays installed in Claude Code.')
    $answer = ''
    try { $answer = Read-Host 'Type yes to continue' } catch { $answer = '' }
    if ($answer -cne 'yes') {
        [Console]::Error.WriteLine('provider: reset not confirmed (pass -Force to skip the prompt). Nothing was changed.')
        exit $EXIT_USAGE
    }
}

$done = New-Object System.Collections.Generic.List[string]

try {
    # ---- collect credman targets BEFORE deleting the profiles ----
    $targets = New-Object System.Collections.Generic.List[string]
    foreach ($file in @(Get-ProfileFiles)) {
        try {
            $doc = Read-JsonFile -Path $file.FullName
            $auth = Get-Prop $doc 'auth'
            if ([string](Get-Prop $auth 'type') -eq 'credman') {
                $t = [string](Get-Prop $auth 'target')
                if ($t -ne '' -and -not $targets.Contains($t)) { $targets.Add($t) }
            }
        } catch {
            # unparseable profile - nothing to collect
            $doc = $null
        }
    }

    # ---- 1. strip plugin-managed keys from BOTH settings files ----
    # Current location is ~\.claude\settings.json; versions <= 0.1.8 wrote
    # ~\.claude\settings.local.json. Clean whichever exist.
    $scope = $null
    try { $scope = Read-SidecarScope -ScopeKey 'global' } catch { $scope = $null }
    $scopeNoteShown = $false

    foreach ($settingsPath in @((Get-SettingsPath), (Get-LegacySettingsPath))) {
        if (-not (Test-Path -LiteralPath $settingsPath)) { continue }
        $settings = $null
        try { $settings = Read-JsonFile -Path $settingsPath } catch { $settings = $null }
        if ($null -eq $settings) {
            [Console]::Error.WriteLine("provider: warning: $settingsPath is not valid JSON - left untouched")
            continue
        }
        $settingsEnv = Get-Prop $settings 'env'

        if ($null -ne $scope) {
            # normal path: the sidecar knows exactly what we manage
            foreach ($key in @(Get-Prop $scope 'managed_env_keys')) {
                if ($null -ne $key) { Remove-Prop $settingsEnv ([string]$key) }
            }
            if ((Get-Prop $scope 'managed_model') -eq $true) { Remove-Prop $settings 'model' }
            if ((Get-Prop $scope 'managed_api_key_helper') -eq $true) { Remove-Prop $settings 'apiKeyHelper' }
        } else {
            if (-not $scopeNoteShown) {
                [Console]::Error.WriteLine('provider: note: sidecar unavailable - profile extras and model (if plugin-set) may remain in the settings files')
                $scopeNoteShown = $true
            }
        }
        # best-effort removal of known plugin keys, in both modes: the
        # sidecar only describes ONE of the two files
        foreach ($key in @('CLAUDE_PROVIDER_ACTIVE', 'ANTHROPIC_BASE_URL', 'CLAUDE_CODE_API_KEY_HELPER_TTL_MS')) {
            Remove-Prop $settingsEnv $key
        }
        $helper = [string](Get-Prop $settings 'apiKeyHelper')
        if ($helper -ne '' -and $helper.StartsWith((Get-ProfileDir), [System.StringComparison]::OrdinalIgnoreCase)) {
            Remove-Prop $settings 'apiKeyHelper'
        }

        if ($null -ne $settingsEnv -and @($settingsEnv.PSObject.Properties).Count -eq 0) {
            Remove-Prop $settings 'env'
        }
        Write-AtomicFile -Path $settingsPath -Content (($settings | ConvertTo-Json -Depth 10) + "`n")
        $done.Add("$(Split-Path -Leaf $settingsPath): plugin-managed keys removed (other settings preserved)")
    }

    # ---- 2. delete the profile directory ----
    $dir = Get-ProfileDir
    if (Test-Path -LiteralPath $dir) {
        Remove-Item -LiteralPath $dir -Recurse -Force
        $done.Add("deleted: $dir")
    }

    # ---- 3. delete referenced Credential Manager entries ----
    foreach ($t in $targets) {
        if (Remove-StoredCredential -Target $t) {
            $done.Add("deleted credential: $t")
        }
    }

    # ---- 4. remove the offline CLI and its Path entry ----
    $binDir = Join-Path (Get-ProviderUserHome) '.claude\bin'
    $removedCli = $false
    foreach ($name in @('claude-provider.cmd', 'claude-provider.ps1', 'provider.cmd', 'provider.ps1')) {
        $f = Join-Path $binDir $name
        if (Test-Path -LiteralPath $f) { Remove-Item -LiteralPath $f -Force; $removedCli = $true }
    }
    if ($removedCli) { $done.Add("deleted CLI from: $binDir") }
    if ((Test-Path -LiteralPath $binDir) -and @(Get-ChildItem -LiteralPath $binDir -Force).Count -eq 0) {
        Remove-Item -LiteralPath $binDir -Force
        $userPath = [Environment]::GetEnvironmentVariable('Path', 'User')
        if ($null -ne $userPath -and $userPath -ne '') {
            $kept = @()
            $changed = $false
            foreach ($entry in $userPath.Split(';')) {
                if ($entry.TrimEnd('\') -ieq $binDir.TrimEnd('\')) { $changed = $true } else { $kept += $entry }
            }
            if ($changed) {
                [Environment]::SetEnvironmentVariable('Path', ($kept -join ';'), 'User')
                $done.Add('removed CLI directory from user Path')
            }
        }
    }
} catch {
    [Console]::Error.WriteLine("provider: $($_.Exception.Message)")
    exit $EXIT_RUNTIME
}

if ($done.Count -eq 0) {
    Write-Output 'provider: nothing to reset - no plugin state found on this machine.'
} else {
    Write-Output 'provider: reset complete.'
    foreach ($line in $done) { Write-Output "  $line" }
    Write-Output ''
    Write-Output 'Restart Claude Code - the next session runs on Anthropic direct.'
    Write-Output 'The plugin itself is still installed; /provider:init starts fresh.'
}
exit $EXIT_OK
