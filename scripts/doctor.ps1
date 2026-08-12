# doctor.ps1 [-Fix] [-Json]
#
# Diagnoses the plugin's on-disk state. Never executes a helper shim and
# never reads a secret's value - existence checks only (design.md
# invariant 8).
#
# Checks:
#   1. profile directory + sidecar exist and parse
#   2. every profile file is valid per the schema
#   3. the active profile still exists
#   4. rendered shims exist and match the active profile's auth
#   5. the auth reference resolves (credential present / env var set)
#   6. the settings file the sidecar targets parses, and managed keys
#      match the sidecar (drift); warns when that file is the legacy
#      pre-0.1.9 location (settings.local.json, only read from home)
#   7. apiKeyHelper points at a file that exists
#   8. no orphaned shims or stale temp files
#   9. no secret material recorded in settings permissions, current or
#      legacy file (approved command lines are stored verbatim there -
#      a -Secret argument means a token leaked into a plain-text file)
#  10. no plugin-managed keys left behind in the legacy file after
#      migration
#  11. no STRAY plugin-like keys in the settings file - keys shaped like
#      the plugin's output but not owned by the sidecar (helper path
#      inside the profile dir, base_url matching a profile). Found in
#      real use: Claude Code itself writes settings.json, and a session
#      left running across a switch can write stale provider keys back.
#      A hand-set model alone (e.g. via /model) is never flagged.
#
# -Fix repairs what is safely repairable: recreates a missing sidecar,
# re-renders missing/mismatched shims, removes orphans, deletes permission
# entries that embed a secret (worst case the user is re-prompted for
# approval). It never resolves drift (that is /provider:switch's job,
# with user confirmation).
#
# Exit codes: 0 all clear | 1 problems found

param(
    [switch]$Fix,
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

$findings = New-Object System.Collections.Generic.List[object]
function Add-Finding {
    param([string]$Level, [string]$Check, [string]$Message, [string]$Fixed = '')
    $findings.Add(([PSCustomObject]@{
        level = $Level; check = $Check; message = $Message; fixed = $Fixed
    }))
}

$dir = Get-ProfileDir
$helpersDir = Get-HelpersDir

# ---- 1. profile dir + sidecar ----
if (-not (Test-Path -LiteralPath $dir)) {
    Add-Finding 'error' 'layout' "profile directory missing: $dir (run /provider:init)"
    if ($Json) { Write-Output (([PSCustomObject]@{ findings = $findings.ToArray() }) | ConvertTo-Json -Depth 5) }
    else { Write-Output "ERROR  layout    profile directory missing: $dir (run /provider:init)" }
    exit $EXIT_RUNTIME
}

$sidecarPath = Get-SidecarPath
$scope = $null
$sidecarBroken = $false
if (-not (Test-Path -LiteralPath $sidecarPath)) {
    if ($Fix) {
        Write-AtomicFile -Path $sidecarPath -Content "{}`n"
        Add-Finding 'warn' 'sidecar' 'sidecar was missing' 'recreated as empty; run /provider:switch to repopulate'
    } else {
        Add-Finding 'warn' 'sidecar' 'sidecar state file is missing (run with --fix to recreate)'
    }
} else {
    try {
        $scope = Read-SidecarScope -ScopeKey 'global'
    } catch {
        $sidecarBroken = $true
        if ($Fix) {
            Write-AtomicFile -Path $sidecarPath -Content "{}`n"
            Add-Finding 'error' 'sidecar' 'sidecar state file was corrupt' 'reset to empty; re-run /provider:switch <name> to repopulate'
        } else {
            Add-Finding 'error' 'sidecar' 'sidecar state file is corrupt (run with --fix to reset)'
        }
    }
}

$active = ''
if ($null -ne $scope) { $active = [string](Get-Prop $scope 'active_profile') }

# ---- 2. every profile validates ----
$profileFiles = @(Get-ProfileFiles)
$validNames = New-Object System.Collections.Generic.List[string]
foreach ($file in $profileFiles) {
    if ((Invoke-ChildScript -ScriptName 'validate-profile.ps1' -Arguments @($file.FullName)) -ne 0) {
        Add-Finding 'error' 'schema' "profile '$($file.BaseName)' fails validation (run: validate-profile.ps1 '$($file.FullName)' for details)"
    } else {
        $validNames.Add($file.BaseName)
    }
}
if ($profileFiles.Count -eq 0) {
    Add-Finding 'warn' 'profiles' 'no profiles found (run /provider:init or /provider:add)'
}

# ---- 3-5. active profile: exists, auth resolves, shim is correct ----
$activeDoc = $null
$expectedShimCmd = ''
if ($active -ne '') {
    $activePath = Get-ProfilePath -Name $active
    if (-not (Test-Path -LiteralPath $activePath)) {
        Add-Finding 'error' 'active' "active profile '$active' has no profile file (switch to an existing profile)"
    } else {
        try {
            $activeDoc = Read-JsonFile -Path $activePath
        } catch {
            Add-Finding 'error' 'active' "active profile '$active' is unparseable"
        }
    }
}

if ($null -ne $activeDoc) {
    $auth = Get-Prop $activeDoc 'auth'
    $authType = [string](Get-Prop $auth 'type')

    if ($authType -eq 'credman') {
        $target = [string](Get-Prop $auth 'target')
        if (Test-StoredCredential -Target $target) {
            Add-Finding 'ok' 'auth' "credential present in Credential Manager: $target"
        } else {
            Add-Finding 'error' 'auth' "no credential stored under Credential Manager target '$target' (store it, then re-switch)"
        }
    } elseif ($authType -eq 'env_var') {
        $var = [string](Get-Prop $auth 'var')
        $found = $false
        foreach ($s in @('Process', 'User', 'Machine')) {
            if (-not [string]::IsNullOrEmpty([Environment]::GetEnvironmentVariable($var, $s))) { $found = $true; break }
        }
        if ($found) {
            Add-Finding 'ok' 'auth' "environment variable is set: $var"
        } else {
            Add-Finding 'error' 'auth' "environment variable '$var' is not set (Process/User/Machine)"
        }
    } else {
        Add-Finding 'ok' 'auth' 'auth type none (Anthropic direct - no helper needed)'
    }

    # shim presence
    if ($authType -eq 'credman' -or $authType -eq 'env_var') {
        $expectedShimCmd = Join-Path $helpersDir ($active + '.cmd')
        $expectedShimPs1 = Join-Path $helpersDir ($active + '.ps1')
        $missing = @()
        foreach ($f in @($expectedShimCmd, $expectedShimPs1)) {
            if (-not (Test-Path -LiteralPath $f)) { $missing += $f }
        }
        if ($missing.Count -gt 0) {
            if ($Fix) {
                $renderCode = Invoke-ChildScript -ScriptName 'render-helper.ps1' `
                    -Arguments @((Get-ProfilePath -Name $active))
                if ($renderCode -eq 0) {
                    Add-Finding 'warn' 'shim' "helper shim files were missing for '$active'" 're-rendered'
                } else {
                    Add-Finding 'error' 'shim' "helper shim missing for '$active' and re-render failed"
                }
            } else {
                Add-Finding 'error' 'shim' "helper shim missing for '$active' (run with --fix to re-render)"
            }
        } else {
            Add-Finding 'ok' 'shim' "helper shim present: $expectedShimCmd"
        }
    }
}

# ---- 6-7. settings: parses, matches sidecar, helper exists ----
# The sidecar records which file holds its managed keys (target_file).
# Pre-0.1.9 sidecars point at the legacy settings.local.json.
$settingsPath = Get-SettingsPath
$legacyPath = Get-LegacySettingsPath
$recordPath = $settingsPath
if ($null -ne $scope) {
    $tf = [string](Get-Prop $scope 'target_file')
    if ($tf -ne '') { $recordPath = $tf } else { $recordPath = $legacyPath }
}
if ($recordPath -ne $settingsPath -and $active -ne '') {
    Add-Finding 'warn' 'legacy' "managed keys live in the pre-0.1.9 location ($recordPath), which Claude Code only reads when started from your HOME directory - run /provider:switch $active to migrate them to settings.json"
}
if (-not (Test-Path -LiteralPath $recordPath)) {
    if ($active -ne '') {
        Add-Finding 'error' 'settings' "sidecar says '$active' is active but $recordPath does not exist (re-run /provider:switch $active)"
    } else {
        Add-Finding 'ok' 'settings' 'no managed settings written yet (nothing has been switched)'
    }
} else {
    $settings = $null
    try {
        $settings = Read-JsonFile -Path $recordPath
    } catch {
        Add-Finding 'error' 'settings' "settings file is not valid JSON: $recordPath (fix by hand - the plugin will not overwrite it)"
    }

    if ($null -ne $settings -and $null -ne $scope -and -not $sidecarBroken) {
        $settingsEnv = Get-Prop $settings 'env'
        $prevVals = Get-Prop $scope 'managed_env_values'
        $drift = New-Object System.Collections.Generic.List[string]

        $pk = Get-Prop $scope 'managed_env_keys'
        foreach ($key in @($pk)) {
            if ([string](Get-Prop $prevVals $key) -cne [string](Get-Prop $settingsEnv $key)) { $drift.Add($key) }
        }
        if ((Get-Prop $scope 'managed_model') -eq $true) {
            if ([string](Get-Prop $settings 'model') -cne [string](Get-Prop $scope 'managed_model_value')) { $drift.Add('model') }
        }
        $helperValue = [string](Get-Prop $settings 'apiKeyHelper')
        if ((Get-Prop $scope 'managed_api_key_helper') -eq $true) {
            if ($helperValue -cne [string](Get-Prop $scope 'managed_api_key_helper_value')) { $drift.Add('apiKeyHelper') }
        }

        if ($drift.Count -gt 0) {
            Add-Finding 'warn' 'drift' "plugin-managed keys were hand-edited since the last switch: $($drift -join ', ') (resolve with /provider:switch $active)"
        } else {
            Add-Finding 'ok' 'drift' 'settings file matches the sidecar record'
        }

        if ($helperValue -ne '' -and -not (Test-Path -LiteralPath $helperValue)) {
            Add-Finding 'error' 'settings' "apiKeyHelper points at a file that does not exist: $helperValue"
        }
    }
}

# ---- 9. secrets recorded in permissions (current AND legacy file) ----
# Claude Code stores approved command lines verbatim under
# permissions.allow. A '-Secret <value>' argument in one of them means
# a token was written into a plain-text file. Match on the flag, never
# echo the entry itself (it contains the secret).
foreach ($permPath in @($settingsPath, $legacyPath)) {
    if (-not (Test-Path -LiteralPath $permPath)) { continue }
    $permDoc = $null
    try { $permDoc = Read-JsonFile -Path $permPath } catch { $permDoc = $null }
    if ($null -eq $permDoc) { continue }
    $perms = Get-Prop $permDoc 'permissions'
    $leakLists = @()
    foreach ($listName in @('allow', 'ask', 'deny')) {
        $entries = Get-Prop $perms $listName
        if ($null -eq $entries) { continue }
        $kept = New-Object System.Collections.Generic.List[string]
        $dropped = 0
        foreach ($entry in @($entries)) {
            if ([string]$entry -match '(?i)[-/]secret[\s:="]') { $dropped++ }
            else { $kept.Add([string]$entry) }
        }
        if ($dropped -gt 0) {
            $leakLists += ,@($listName, $dropped, $kept)
        }
    }
    if ($leakLists.Count -gt 0) {
        if ($Fix) {
            foreach ($leak in $leakLists) {
                $perms.PSObject.Properties[$leak[0]].Value = $leak[2].ToArray()
            }
            Write-AtomicFile -Path $permPath -Content (($permDoc | ConvertTo-Json -Depth 10) + "`n")
            foreach ($leak in $leakLists) {
                Add-Finding 'error' 'secret' "$(Split-Path -Leaf $permPath): permissions.$($leak[0]) contained $($leak[1]) entr$(if ($leak[1] -eq 1) { 'y' } else { 'ies' }) embedding a secret on a command line" 'removed'
            }
        } else {
            foreach ($leak in $leakLists) {
                Add-Finding 'error' 'secret' "$(Split-Path -Leaf $permPath): permissions.$($leak[0]) has $($leak[1]) entr$(if ($leak[1] -eq 1) { 'y' } else { 'ies' }) embedding a secret on a command line (run with --fix to remove)"
            }
        }
    }
}

# ---- 10. plugin keys left behind in the legacy file ----
# After migration (or a crash between the two writes) the legacy
# settings.local.json must not still carry plugin keys: Claude Code reads
# it as HOME's project-local settings and would pin sessions started from
# the home directory to a stale provider.
if ($recordPath -ne $legacyPath -and (Test-Path -LiteralPath $legacyPath)) {
    $legacyDoc = $null
    try { $legacyDoc = Read-JsonFile -Path $legacyPath } catch { $legacyDoc = $null }
    if ($null -ne $legacyDoc) {
        $legacyEnv = Get-Prop $legacyDoc 'env'
        $leftover = New-Object System.Collections.Generic.List[string]
        foreach ($key in @('CLAUDE_PROVIDER_ACTIVE', 'ANTHROPIC_BASE_URL', 'CLAUDE_CODE_API_KEY_HELPER_TTL_MS')) {
            if ($null -ne (Get-Prop $legacyEnv $key)) { $leftover.Add("env.$key") }
        }
        $legacyHelper = [string](Get-Prop $legacyDoc 'apiKeyHelper')
        $helperIsOurs = ($legacyHelper -ne '' -and $legacyHelper.StartsWith((Get-ProfileDir), [System.StringComparison]::OrdinalIgnoreCase))
        if ($helperIsOurs) { $leftover.Add('apiKeyHelper') }
        if ($leftover.Count -gt 0) {
            if ($Fix) {
                foreach ($key in @('CLAUDE_PROVIDER_ACTIVE', 'ANTHROPIC_BASE_URL', 'CLAUDE_CODE_API_KEY_HELPER_TTL_MS')) {
                    if ($null -ne $legacyEnv -and $null -ne $legacyEnv.PSObject.Properties[$key]) { $legacyEnv.PSObject.Properties.Remove($key) }
                }
                if ($helperIsOurs) { $legacyDoc.PSObject.Properties.Remove('apiKeyHelper') }
                if ($null -ne $legacyEnv -and @($legacyEnv.PSObject.Properties).Count -eq 0) { $legacyDoc.PSObject.Properties.Remove('env') }
                if (@($legacyDoc.PSObject.Properties).Count -eq 0) {
                    Remove-Item -LiteralPath $legacyPath -Force -ErrorAction SilentlyContinue
                } else {
                    Write-AtomicFile -Path $legacyPath -Content (($legacyDoc | ConvertTo-Json -Depth 10) + "`n")
                }
                Add-Finding 'warn' 'legacy' "plugin keys left behind in the pre-0.1.9 location: $($leftover -join ', ')" 'removed'
            } else {
                Add-Finding 'warn' 'legacy' "plugin keys left behind in the pre-0.1.9 location ($legacyPath): $($leftover -join ', ') (run with --fix to remove)"
            }
        }
    }
}

# ---- 11. stray plugin-like keys the sidecar does not own ----
# Claude Code itself writes the settings file (plugin registry, /model
# persistence), and a session left running across a switch can write
# stale provider keys back after apply-profile cleaned them; manual
# edits leave the same shape. Only keys that are recognizably the
# plugin's are flagged; keys the sidecar DOES own are drift (check 6),
# never touched here.
if (Test-Path -LiteralPath $settingsPath) {
    $strayDoc = $null
    try { $strayDoc = Read-JsonFile -Path $settingsPath } catch { $strayDoc = $null }
    if ($null -ne $strayDoc) {
        $strayEnv = Get-Prop $strayDoc 'env'
        $mgKeys = @()
        $helperManaged = $false
        $modelManaged = $false
        if ($null -ne $scope) {
            $mk = Get-Prop $scope 'managed_env_keys'
            if ($null -ne $mk) { $mgKeys = @($mk) }
            $helperManaged = ((Get-Prop $scope 'managed_api_key_helper') -eq $true)
            $modelManaged = ((Get-Prop $scope 'managed_model') -eq $true)
        }

        $profileDocs = @{}
        foreach ($pf in $profileFiles) {
            try { $profileDocs[$pf.BaseName] = Read-JsonFile -Path $pf.FullName } catch { $profileDocs.Remove($pf.BaseName) }
        }

        $stray = New-Object System.Collections.Generic.List[string]
        $strayHelperProfile = ''

        $docHelper = [string](Get-Prop $strayDoc 'apiKeyHelper')
        if (-not $helperManaged -and $docHelper -ne '' -and
            $docHelper.StartsWith((Get-ProfileDir), [System.StringComparison]::OrdinalIgnoreCase)) {
            $stray.Add('apiKeyHelper')
            $strayHelperProfile = [System.IO.Path]::GetFileNameWithoutExtension($docHelper)
        }
        if ($mgKeys -notcontains 'CLAUDE_PROVIDER_ACTIVE' -and $null -ne (Get-Prop $strayEnv 'CLAUDE_PROVIDER_ACTIVE')) {
            $stray.Add('env.CLAUDE_PROVIDER_ACTIVE')
        }
        if ($mgKeys -notcontains 'ANTHROPIC_BASE_URL') {
            $docBase = [string](Get-Prop $strayEnv 'ANTHROPIC_BASE_URL')
            if ($docBase -ne '') {
                foreach ($pd in $profileDocs.Values) {
                    if ([string](Get-Prop $pd 'base_url') -ceq $docBase) { $stray.Add('env.ANTHROPIC_BASE_URL'); break }
                }
            }
        }
        # model is flagged ONLY next to a stray helper of the same profile:
        # a bare unmanaged model is a legitimate hand choice (e.g. /model).
        if (-not $modelManaged -and $strayHelperProfile -ne '' -and $profileDocs.ContainsKey($strayHelperProfile)) {
            $docModel = [string](Get-Prop $strayDoc 'model')
            if ($docModel -ne '' -and $docModel -ceq [string](Get-Prop $profileDocs[$strayHelperProfile] 'model')) {
                $stray.Add('model')
            }
        }

        if ($stray.Count -gt 0) {
            if ($Fix) {
                foreach ($k in $stray.ToArray()) {
                    if ($k -eq 'apiKeyHelper' -or $k -eq 'model') {
                        $strayDoc.PSObject.Properties.Remove($k)
                    } elseif ($k.StartsWith('env.')) {
                        $envKey = $k.Substring(4)
                        if ($null -ne $strayEnv -and $null -ne $strayEnv.PSObject.Properties[$envKey]) { $strayEnv.PSObject.Properties.Remove($envKey) }
                    }
                }
                if ($null -ne $strayEnv -and @($strayEnv.PSObject.Properties).Count -eq 0) { $strayDoc.PSObject.Properties.Remove('env') }
                Write-AtomicFile -Path $settingsPath -Content (($strayDoc | ConvertTo-Json -Depth 10) + "`n")
                Add-Finding 'warn' 'stray' "unmanaged plugin keys in $(Split-Path -Leaf $settingsPath): $($stray -join ', ')" 'removed - typically written back by a session that was still running during a switch'
            } else {
                Add-Finding 'warn' 'stray' "unmanaged plugin keys in $(Split-Path -Leaf $settingsPath): $($stray -join ', ') (not owned by the sidecar; run with --fix to remove)"
            }
        }
    }
}

# ---- 8. orphaned shims + stale temp files ----
if (Test-Path -LiteralPath $helpersDir) {
    foreach ($shim in (Get-ChildItem -LiteralPath $helpersDir -File)) {
        $base = $shim.BaseName
        if ($validNames -notcontains $base -and -not (Test-Path -LiteralPath (Get-ProfilePath -Name $base))) {
            if ($Fix) {
                Remove-Item -LiteralPath $shim.FullName -Force -ErrorAction SilentlyContinue
                Add-Finding 'warn' 'orphan' "orphaned shim for deleted profile '$base'" 'removed'
            } else {
                Add-Finding 'warn' 'orphan' "orphaned shim for deleted profile '$base': $($shim.Name) (run with --fix to remove)"
            }
        }
    }
}
foreach ($tmp in (Get-ChildItem -LiteralPath $dir -Filter '.*.tmp' -File -Force -ErrorAction SilentlyContinue)) {
    if ($Fix) {
        Remove-Item -LiteralPath $tmp.FullName -Force -ErrorAction SilentlyContinue
        Add-Finding 'warn' 'temp' "stale temp file $($tmp.Name)" 'removed'
    } else {
        Add-Finding 'warn' 'temp' "stale temp file: $($tmp.Name) (run with --fix to remove)"
    }
}
$lockDir = Get-LockDir
if (Test-Path -LiteralPath $lockDir) {
    $pidFile = Join-Path $lockDir 'pid'
    $holder = ''
    if (Test-Path -LiteralPath $pidFile) { $holder = (Get-Content -LiteralPath $pidFile | Select-Object -First 1) }
    $alive = $false
    if ($holder -ne '') {
        try { $alive = ($null -ne (Get-Process -Id ([int]$holder) -ErrorAction Stop)) } catch { $alive = $false }
    }
    if (-not $alive) {
        if ($Fix) {
            Remove-Item -LiteralPath $lockDir -Recurse -Force -ErrorAction SilentlyContinue
            Add-Finding 'warn' 'lock' "stale lock held by dead PID $holder" 'removed'
        } else {
            Add-Finding 'warn' 'lock' "stale lock directory held by dead PID $holder (run with --fix to clear)"
        }
    } else {
        Add-Finding 'warn' 'lock' "a switch is currently in progress (PID $holder)"
    }
}

# ---- report ----
$errors = @($findings | Where-Object { $_.level -eq 'error' })
$warns = @($findings | Where-Object { $_.level -eq 'warn' })

if ($Json) {
    $activeOut = $null
    if ($active -ne '') { $activeOut = $active }
    $out = [PSCustomObject]@{
        active_profile = $activeOut
        errors         = $errors.Count
        warnings       = $warns.Count
        findings       = $findings.ToArray()
    }
    Write-Output ($out | ConvertTo-Json -Depth 5)
    if ($errors.Count -gt 0) { exit $EXIT_RUNTIME }
    exit $EXIT_OK
}

foreach ($f in $findings) {
    $label = switch ($f.level) { 'error' { 'ERROR' } 'warn' { 'WARN ' } default { 'ok   ' } }
    $line = "$label  $($f.check.PadRight(9)) $($f.message)"
    if ($f.fixed -ne '') { $line = "$line`n         FIXED: $($f.fixed)" }
    Write-Output $line
}
Write-Output ''
if ($errors.Count -eq 0 -and $warns.Count -eq 0) {
    Write-Output 'All checks passed.'
} else {
    Write-Output "$($errors.Count) error(s), $($warns.Count) warning(s)."
    if (-not $Fix) { Write-Output 'Run /provider:doctor --fix to repair what can be repaired automatically.' }
}
if ($errors.Count -gt 0) { exit $EXIT_RUNTIME }
exit $EXIT_OK
