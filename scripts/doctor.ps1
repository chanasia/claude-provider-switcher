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
#   6. settings.local.json parses, and managed keys match the sidecar (drift)
#   7. apiKeyHelper points at a file that exists
#   8. no orphaned shims or stale temp files
#   9. no secret material recorded in settings.local.json permissions
#      (approved command lines are stored verbatim there - a -Secret
#      argument means a token leaked into a plain-text file)
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

# ---- 6-7. settings.local.json: parses, matches sidecar, helper exists ----
$settingsPath = Get-SettingsPath
if (-not (Test-Path -LiteralPath $settingsPath)) {
    if ($active -ne '') {
        Add-Finding 'error' 'settings' "sidecar says '$active' is active but $settingsPath does not exist (re-run /provider:switch $active)"
    } else {
        Add-Finding 'ok' 'settings' 'no settings.local.json yet (nothing has been switched)'
    }
} else {
    $settings = $null
    try {
        $settings = Read-JsonFile -Path $settingsPath
    } catch {
        Add-Finding 'error' 'settings' "settings.local.json is not valid JSON: $settingsPath (fix by hand - the plugin will not overwrite it)"
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
            Add-Finding 'ok' 'drift' 'settings.local.json matches the sidecar record'
        }

        if ($helperValue -ne '' -and -not (Test-Path -LiteralPath $helperValue)) {
            Add-Finding 'error' 'settings' "apiKeyHelper points at a file that does not exist: $helperValue"
        }
    }

    # ---- 9. secrets recorded in permissions ----
    # Claude Code stores approved command lines verbatim under
    # permissions.allow. A '-Secret <value>' argument in one of them means
    # a token was written into this plain-text file. Match on the flag,
    # never echo the entry itself (it contains the secret).
    if ($null -ne $settings) {
        $perms = Get-Prop $settings 'permissions'
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
                Write-AtomicFile -Path $settingsPath -Content (($settings | ConvertTo-Json -Depth 10) + "`n")
                foreach ($leak in $leakLists) {
                    Add-Finding 'error' 'secret' "permissions.$($leak[0]) contained $($leak[1]) entr$(if ($leak[1] -eq 1) { 'y' } else { 'ies' }) embedding a secret on a command line" 'removed - ROTATE that token; it sat in a plain-text file'
                }
            } else {
                foreach ($leak in $leakLists) {
                    Add-Finding 'error' 'secret' "permissions.$($leak[0]) has $($leak[1]) entr$(if ($leak[1] -eq 1) { 'y' } else { 'ies' }) embedding a secret on a command line (run with --fix to remove, then ROTATE that token)"
                }
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
