# apply-profile.ps1 <name> [-AcceptDrift overwrite|incorporate]
#
# Core switch logic (design.md section 5). Applies a profile to the
# user-scope ~/.claude/settings.json + sidecar atomically, with drift
# detection, advisory locking, and crash-safe sidecar-first ordering.
#
# Migration: versions <= 0.1.8 wrote ~/.claude/settings.local.json, which
# Claude Code only reads when started from the home directory. The sidecar
# records which file holds the current record (target_file); when that is
# the legacy file, drift is checked against IT, and after a successful
# apply the managed keys are removed from it.
#
# v0.1.0 scope: global only.
#
# Exit codes: 0 ok | 1 runtime | 2 usage | 3 not found | 6 schema
#             8 drift | 9 success-but-restart-required

param(
    [Parameter(Position = 0)][string]$Name = '',
    [string]$AcceptDrift = ''
)

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'lib.ps1')

# ============================================================
# Argument checks (no lock needed yet)
# ============================================================
if ($Name -eq '') {
    [Console]::Error.WriteLine('usage: apply-profile.ps1 <name> [-AcceptDrift overwrite|incorporate]')
    exit $EXIT_USAGE
}
if ($AcceptDrift -notin @('', 'overwrite', 'incorporate')) {
    [Console]::Error.WriteLine("provider: -AcceptDrift must be 'overwrite' or 'incorporate' (got '$AcceptDrift')")
    exit $EXIT_USAGE
}

$profilePath = Get-ProfilePath -Name $Name
if (-not (Test-Path -LiteralPath $profilePath)) {
    [Console]::Error.WriteLine("provider: profile not found: $Name")
    $dir = Get-ProfileDir
    if (Test-Path -LiteralPath $dir) {
        $available = @(Get-ProfileFiles) | ForEach-Object { $_.BaseName }
        if ($available) {
            [Console]::Error.WriteLine("  available profiles: $($available -join ', ')")
        }
        if ($Name -eq 'anthropic') {
            [Console]::Error.WriteLine("  hint: run /provider:init to seed the built-in 'anthropic' (Anthropic direct) profile.")
            # If nothing is active, there is nothing to switch away from anyway.
            $scopeEntry = $null
            try { $scopeEntry = Read-SidecarScope -ScopeKey 'global' } catch { $scopeEntry = $null }
            $activeNow = ''
            if ($null -ne $scopeEntry) {
                $p = $scopeEntry.PSObject.Properties['active_profile']
                if ($null -ne $p) { $activeNow = [string]$p.Value }
            }
            if ($activeNow -eq '') {
                [Console]::Error.WriteLine('  note: no profile is active, so this session is ALREADY on Anthropic direct (Claude Code defaults).')
            }
        }
    } else {
        [Console]::Error.WriteLine('  run /provider:init first')
    }
    exit $EXIT_NOT_FOUND
}

# ============================================================
# Step 0: Preflight - validate the profile
# ============================================================
& powershell.exe -NoProfile -NonInteractive -ExecutionPolicy Bypass `
    -File (Join-Path $PSScriptRoot 'validate-profile.ps1') $profilePath | Out-Null
if ($LASTEXITCODE -ne 0) {
    [Console]::Error.WriteLine("provider: profile '$Name' failed validation (see above)")
    exit $EXIT_SCHEMA
}

# ============================================================
# PSObject helpers
# ============================================================
function Get-Prop {
    param($Obj, [string]$PropName)
    if ($null -eq $Obj) { return $null }
    $p = $Obj.PSObject.Properties[$PropName]
    if ($null -eq $p) { return $null }
    return $p.Value
}

function Set-Prop {
    param($Obj, [string]$PropName, $Value)
    if ($null -ne $Obj.PSObject.Properties[$PropName]) {
        $Obj.PSObject.Properties.Remove($PropName)
    }
    $Obj | Add-Member -MemberType NoteProperty -Name $PropName -Value $Value
}

function Remove-Prop {
    param($Obj, [string]$PropName)
    if ($null -ne $Obj.PSObject.Properties[$PropName]) {
        $Obj.PSObject.Properties.Remove($PropName)
    }
}

# ============================================================
# Main logic. Runs under the advisory lock; returns an exit code.
# All user-facing text goes to [Console] streams directly so the
# function's return value is only the code.
# ============================================================
function Invoke-Apply {
    # ---- Step 2: read target settings file ----
    $settingsPath = Get-SettingsPath
    if (Test-Path -LiteralPath $settingsPath) {
        try {
            $settings = Read-JsonFile -Path $settingsPath
        } catch {
            [Console]::Error.WriteLine("provider: settings file is not valid JSON: $settingsPath")
            return $EXIT_RUNTIME
        }
    } else {
        $settings = New-Object PSObject
    }

    # ---- Step 3: read sidecar scope entry (corrupt sidecar throws) ----
    $prev = Read-SidecarScope -ScopeKey 'global'

    # Where does the sidecar's record actually live? Pre-0.1.9 sidecars
    # point target_file at the legacy settings.local.json - drift must be
    # checked against THAT file, and the managed keys migrate out of it.
    $recordPath = $settingsPath
    if ($null -ne $prev) {
        $tf = ''
        $tfProp = $prev.PSObject.Properties['target_file']
        if ($null -ne $tfProp) { $tf = [string]$tfProp.Value }
        if ($tf -ne '') { $recordPath = $tf } else { $recordPath = Get-LegacySettingsPath }
    }
    $migrating = ($recordPath -ne $settingsPath)
    $recordDoc = $settings
    $legacyExists = $false
    if ($migrating) {
        if (Test-Path -LiteralPath $recordPath) {
            try {
                $recordDoc = Read-JsonFile -Path $recordPath
                $legacyExists = $true
            } catch {
                [Console]::Error.WriteLine("provider: legacy settings file is not valid JSON: $recordPath")
                [Console]::Error.WriteLine('  Fix or delete it by hand, then re-run the switch.')
                return $EXIT_RUNTIME
            }
        } else {
            # Legacy record file is gone - nothing to preserve or migrate.
            $recordDoc = New-Object PSObject
        }
    }

    $prevKeys = @()
    $prevVals = $null
    $prevManagedModel = $false
    $prevModelValue = ''
    $prevManagedHelper = $false
    $prevHelperValue = ''
    if ($null -ne $prev) {
        $pk = Get-Prop $prev 'managed_env_keys'
        if ($null -ne $pk) { $prevKeys = @($pk) }
        $prevVals = Get-Prop $prev 'managed_env_values'
        $pm = Get-Prop $prev 'managed_model'
        if ($pm -eq $true) {
            $prevManagedModel = $true
            $prevModelValue = [string](Get-Prop $prev 'managed_model_value')
        }
        $ph = Get-Prop $prev 'managed_api_key_helper'
        if ($ph -eq $true) {
            $prevManagedHelper = $true
            $prevHelperValue = [string](Get-Prop $prev 'managed_api_key_helper_value')
        }
    }

    # ---- Step 4: drift detection BEFORE any mutation ----
    # Compared against the file the sidecar record was written to
    # ($recordDoc) - during migration that is the legacy file. If the
    # legacy file was deleted, there are no hand edits left to protect.
    $settingsEnv = Get-Prop $settings 'env'
    $recordEnv = Get-Prop $recordDoc 'env'
    $driftKeys = New-Object System.Collections.Generic.List[string]
    $driftActual = @{}
    $helperDrifted = $false

    if (-not ($migrating -and -not $legacyExists)) {
        foreach ($key in $prevKeys) {
            $expected = [string](Get-Prop $prevVals $key)
            $actual = [string](Get-Prop $recordEnv $key)
            if ($expected -cne $actual) {
                $driftKeys.Add($key)
                $driftActual[$key] = $actual
            }
        }
        if ($prevManagedModel) {
            $actualModel = [string](Get-Prop $recordDoc 'model')
            if ($actualModel -cne $prevModelValue) {
                $driftKeys.Add('model')
                $driftActual['model'] = $actualModel
            }
        }
        if ($prevManagedHelper) {
            $actualHelper = [string](Get-Prop $recordDoc 'apiKeyHelper')
            if ($actualHelper -cne $prevHelperValue) {
                $driftKeys.Add('apiKeyHelper')
                $helperDrifted = $true
            }
        }
    }

    if ($driftKeys.Count -gt 0) {
        if ($AcceptDrift -eq 'overwrite') {
            # proceed; the new profile's values win for everything
        } elseif ($AcceptDrift -eq 'incorporate') {
            if ($helperDrifted) {
                [Console]::Error.WriteLine('provider: apiKeyHelper drift cannot be incorporated.')
                [Console]::Error.WriteLine('  Use -AcceptDrift overwrite, or revert the apiKeyHelper edit and re-run.')
                return $EXIT_DRIFT
            }
            # proceed; drifted keys not managed by the new profile survive as unmanaged
        } else {
            [Console]::Error.WriteLine("provider: drift detected in managed keys: $($driftKeys -join ', ')")
            [Console]::Error.WriteLine('  These keys were hand-edited since the last switch.')
            [Console]::Error.WriteLine('  Re-run with -AcceptDrift overwrite to apply the new profile anyway,')
            [Console]::Error.WriteLine('  or -AcceptDrift incorporate to preserve the hand-edited values where possible.')
            return $EXIT_DRIFT
        }
    }

    # ---- Step 5: compute the new managed set (denylist re-checked) ----
    $doc = Read-JsonFile -Path $profilePath
    $auth = Get-Prop $doc 'auth'
    $authType = [string](Get-Prop $auth 'type')
    $baseUrl = Get-Prop $doc 'base_url'
    $model = Get-Prop $doc 'model'
    $ttl = Get-Prop $doc 'ttl_ms'
    $extras = Get-Prop $doc 'extras'

    $extrasKeys = @()
    if ($null -ne $extras) {
        $extrasKeys = @($extras.PSObject.Properties | ForEach-Object { $_.Name })
    }
    foreach ($key in $extrasKeys) {
        if (Test-DenylistedKey -Key $key) {
            [Console]::Error.WriteLine("provider: schema: extras key '$key' is denylisted (caught at apply time)")
            return $EXIT_SCHEMA
        }
    }

    $newManagedKeys = New-Object System.Collections.Generic.List[string]
    foreach ($key in $extrasKeys) { $newManagedKeys.Add($key) }
    $newManagedKeys.Add('CLAUDE_PROVIDER_ACTIVE')
    if ($null -ne $baseUrl -and $baseUrl -ne '') { $newManagedKeys.Add('ANTHROPIC_BASE_URL') }
    if ($null -ne $ttl) { $newManagedKeys.Add('CLAUDE_CODE_API_KEY_HELPER_TTL_MS') }
    $newManagesModel = ($null -ne $model -and $model -ne '')

    # ---- Step 6: auth preflight + shim render ----
    $newManagedHelper = $false
    $newHelperValue = ''
    if ($authType -eq 'credman') {
        $target = [string](Get-Prop $auth 'target')
        if (-not (Test-StoredCredential -Target $target)) {
            [Console]::Error.WriteLine("provider: no credential stored in Windows Credential Manager for target '$target'.")
            [Console]::Error.WriteLine("  Store it first, e.g.: scripts/set-credential.ps1 -Target '$target'")
            return $EXIT_RUNTIME
        }
    } elseif ($authType -eq 'env_var') {
        $var = [string](Get-Prop $auth 'var')
        $found = $false
        foreach ($scope in @('Process', 'User', 'Machine')) {
            if (-not [string]::IsNullOrEmpty([Environment]::GetEnvironmentVariable($var, $scope))) { $found = $true; break }
        }
        if (-not $found) {
            [Console]::Error.WriteLine("provider: environment variable '$var' is not set (Process/User/Machine).")
            [Console]::Error.WriteLine('  Set it first, then re-run the switch.')
            return $EXIT_RUNTIME
        }
    }

    if ($authType -eq 'credman' -or $authType -eq 'env_var') {
        $renderOut = & powershell.exe -NoProfile -NonInteractive -ExecutionPolicy Bypass `
            -File (Join-Path $PSScriptRoot 'render-helper.ps1') $profilePath
        if ($LASTEXITCODE -ne 0) {
            [Console]::Error.WriteLine('provider: failed to render apiKeyHelper shim (see above)')
            return $EXIT_RUNTIME
        }
        $newManagedHelper = $true
        $newHelperValue = [string](@($renderOut) | Select-Object -Last 1)
    } else {
        # auth:none - no helper. Clean up stale shims for this profile name.
        & powershell.exe -NoProfile -NonInteractive -ExecutionPolicy Bypass `
            -File (Join-Path $PSScriptRoot 'render-helper.ps1') $profilePath | Out-Null
    }

    # ---- Step 7: remove all previously managed keys from settings ----
    # From the new target too, even when the record lived in the legacy
    # file: a manual migration may have copied plugin keys there already.
    if ($null -ne $settingsEnv) {
        foreach ($key in $prevKeys) { Remove-Prop $settingsEnv $key }
    }
    if ($prevManagedModel) { Remove-Prop $settings 'model' }
    if ($prevManagedHelper) { Remove-Prop $settings 'apiKeyHelper' }
    if ($migrating -and $legacyExists) {
        if ($null -ne $recordEnv) {
            foreach ($key in $prevKeys) { Remove-Prop $recordEnv $key }
        }
        if ($prevManagedModel) { Remove-Prop $recordDoc 'model' }
        if ($prevManagedHelper) { Remove-Prop $recordDoc 'apiKeyHelper' }
        if ($null -ne $recordEnv -and @($recordEnv.PSObject.Properties).Count -eq 0) {
            Remove-Prop $recordDoc 'env'
        }
    }

    # ---- Step 8: incorporate drifted values the new profile does NOT
    # manage - they survive as unmanaged user edits ----
    if ($AcceptDrift -eq 'incorporate' -and $driftKeys.Count -gt 0) {
        foreach ($dkey in @($driftActual.Keys)) {
            if ($dkey -eq 'model') {
                if (-not $newManagesModel -and $driftActual['model'] -ne '') {
                    Set-Prop $settings 'model' $driftActual['model']
                }
                continue
            }
            if ($newManagedKeys -notcontains $dkey -and $driftActual[$dkey] -ne '') {
                if ($null -eq $settingsEnv) {
                    $settingsEnv = New-Object PSObject
                    Set-Prop $settings 'env' $settingsEnv
                }
                Set-Prop $settingsEnv $dkey $driftActual[$dkey]
            }
        }
    }

    # ---- Step 9: merge new keys - extras first, plugin-managed last ----
    if ($null -eq $settingsEnv) {
        $settingsEnv = New-Object PSObject
        Set-Prop $settings 'env' $settingsEnv
    }
    $newManagedValues = New-Object PSObject

    foreach ($key in $extrasKeys) {
        $value = [string](Get-Prop $extras $key)
        Set-Prop $settingsEnv $key $value
        Set-Prop $newManagedValues $key $value
    }
    Set-Prop $settingsEnv 'CLAUDE_PROVIDER_ACTIVE' $Name
    Set-Prop $newManagedValues 'CLAUDE_PROVIDER_ACTIVE' $Name
    if ($null -ne $baseUrl -and $baseUrl -ne '') {
        Set-Prop $settingsEnv 'ANTHROPIC_BASE_URL' ([string]$baseUrl)
        Set-Prop $newManagedValues 'ANTHROPIC_BASE_URL' ([string]$baseUrl)
    }
    if ($null -ne $ttl) {
        Set-Prop $settingsEnv 'CLAUDE_CODE_API_KEY_HELPER_TTL_MS' ([string]$ttl)
        Set-Prop $newManagedValues 'CLAUDE_CODE_API_KEY_HELPER_TTL_MS' ([string]$ttl)
    }
    if ($newManagesModel) {
        Set-Prop $settings 'model' ([string]$model)
    }
    if ($newManagedHelper) {
        Set-Prop $settings 'apiKeyHelper' $newHelperValue
    }

    # Drop an env object left empty by removals.
    if (@($settingsEnv.PSObject.Properties).Count -eq 0) {
        Remove-Prop $settings 'env'
    }

    # ---- Step 10: sidecar write FIRST (crash-safe ordering), then target ----
    $newScope = New-Object PSObject
    Set-Prop $newScope 'active_profile' $Name
    Set-Prop $newScope 'managed_env_keys' $newManagedKeys.ToArray()
    Set-Prop $newScope 'managed_env_values' $newManagedValues
    Set-Prop $newScope 'managed_model' $newManagesModel
    Set-Prop $newScope 'managed_model_value' $(if ($newManagesModel) { [string]$model } else { '' })
    Set-Prop $newScope 'managed_api_key_helper' $newManagedHelper
    Set-Prop $newScope 'managed_api_key_helper_value' $newHelperValue
    Set-Prop $newScope 'target_file' $settingsPath

    Write-SidecarScope -ScopeKey 'global' -Entry $newScope

    $settingsDir = Split-Path -Parent $settingsPath
    $null = New-Item -ItemType Directory -Path $settingsDir -Force
    Write-AtomicFile -Path $settingsPath -Content (($settings | ConvertTo-Json -Depth 10) + "`n")

    # ---- Step 10b: migration tail - clean the legacy file ----
    # Managed keys were removed from $recordDoc in Step 7. Write what is
    # left back (preserving the user's other content, e.g. permissions),
    # or delete the file if nothing remains. Crash-safe: if this never
    # runs, doctor flags the leftovers.
    if ($migrating -and $legacyExists) {
        if (@($recordDoc.PSObject.Properties).Count -eq 0) {
            Remove-Item -LiteralPath $recordPath -Force -ErrorAction SilentlyContinue
        } else {
            Write-AtomicFile -Path $recordPath -Content (($recordDoc | ConvertTo-Json -Depth 10) + "`n")
        }
        [Console]::Error.WriteLine("provider: migrated managed keys from the legacy location ($recordPath) to $settingsPath.")
    }

    # ---- Step 11: post-apply stale-env check ----
    if ($env:CLAUDE_PROVIDER_ACTIVE -cne $Name) {
        [Console]::Error.WriteLine("provider: profile switched to '$Name'. Restart Claude Code to activate.")
        return $EXIT_RESTART_REQUIRED
    }

    [Console]::Out.WriteLine("provider: profile '$Name' applied.")
    return $EXIT_OK
}

# ============================================================
# Step 1: acquire advisory lock, run, always release
# ============================================================
$null = New-Item -ItemType Directory -Path (Get-ProfileDir) -Force
if (-not (Lock-ProviderState)) {
    [Console]::Error.WriteLine('provider: another switch is in progress (lock held)')
    exit $EXIT_RUNTIME
}

$exitCode = $EXIT_RUNTIME
try {
    $exitCode = Invoke-Apply
} catch {
    [Console]::Error.WriteLine("provider: $($_.Exception.Message)")
    $exitCode = $EXIT_RUNTIME
} finally {
    Unlock-ProviderState
}
exit $exitCode
