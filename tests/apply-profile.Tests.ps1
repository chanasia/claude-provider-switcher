# Pester 3.4-compatible tests for scripts/apply-profile.ps1
#
# Each test uses an isolated fake HOME (New-TestHome) so switches never
# touch the real ~/.claude. Scripts run in child powershell.exe processes.

$here = Split-Path -Parent $MyInvocation.MyCommand.Path
. (Join-Path $here 'Integration.Helpers.ps1')

$anthropicJson = '{"name":"anthropic","auth":{"type":"none"}}'
$gwJson = @'
{
  "name": "gw",
  "base_url": "https://gateway.example.com/anthropic",
  "auth": { "type": "env_var", "var": "CPS_APPLY_TEST_KEY" },
  "model": "some/model-name",
  "ttl_ms": 300000,
  "extras": { "CLAUDE_CODE_MAX_OUTPUT_TOKENS": "64000" }
}
'@

Describe 'apply-profile.ps1 basics' {

    It 'exits 2 with no arguments' {
        $null = New-TestHome $TestDrive 'usage'
        (Invoke-ProviderScript 'apply-profile.ps1').Exit | Should Be 2
    }

    It 'exits 2 for a bad -AcceptDrift value' {
        $null = New-TestHome $TestDrive 'baddrift'
        (Invoke-ProviderScript 'apply-profile.ps1' @('x', '-AcceptDrift', 'maybe')).Exit | Should Be 2
    }

    It 'exits 3 for an unknown profile and lists available ones' {
        $h = New-TestHome $TestDrive 'notfound'
        $null = Write-TestProfile $h 'anthropic' $anthropicJson
        $r = Invoke-ProviderScript 'apply-profile.ps1' @('nope')
        $r.Exit | Should Be 3
        $r.Output | Should Match 'anthropic'
    }

    It 'exits 6 for a profile that fails validation' {
        $h = New-TestHome $TestDrive 'invalid'
        $null = Write-TestProfile $h 'bad' '{"name":"bad","auth":{"type":"nope"}}'
        (Invoke-ProviderScript 'apply-profile.ps1' @('bad')).Exit | Should Be 6
    }

    It 'exits 1 when the lock is held by a live process' {
        $h = New-TestHome $TestDrive 'locked'
        $null = Write-TestProfile $h 'anthropic' $anthropicJson
        $lockDir = Join-Path $h '.claude\provider-profiles\.state.lock'
        $null = New-Item -ItemType Directory -Path $lockDir -Force
        Set-Content -LiteralPath (Join-Path $lockDir 'pid') -Value $PID -Encoding Ascii
        $r = Invoke-ProviderScript 'apply-profile.ps1' @('anthropic')
        $r.Exit | Should Be 1
        $r.Output | Should Match 'lock'
        Remove-Item -LiteralPath $lockDir -Recurse -Force
    }

    It 'exits 1 on a corrupt sidecar instead of proceeding' {
        $h = New-TestHome $TestDrive 'corrupt'
        $null = Write-TestProfile $h 'anthropic' $anthropicJson
        Set-Content -LiteralPath (Join-Path $h '.claude\provider-profiles\.state.json') -Value '{broken' -Encoding Ascii
        $r = Invoke-ProviderScript 'apply-profile.ps1' @('anthropic')
        $r.Exit | Should Be 1
        $r.Output | Should Match 'corrupt'
    }

    It 'exits 1 for a credman profile whose credential is not stored' {
        $h = New-TestHome $TestDrive 'nocred'
        $null = Write-TestProfile $h 'cm' '{"name":"cm","auth":{"type":"credman","target":"claude-provider-switcher/apply-missing-cred"}}'
        $r = Invoke-ProviderScript 'apply-profile.ps1' @('cm')
        $r.Exit | Should Be 1
        $r.Output | Should Match 'Credential Manager'
    }
}

Describe 'apply-profile.ps1 switching' {
    $env:CPS_APPLY_TEST_KEY = 'sk-fake-apply-key'

    It 'applies auth:none and exits 9 (stale env, restart required)' {
        $h = New-TestHome $TestDrive 'first'
        $null = Write-TestProfile $h 'anthropic' $anthropicJson
        $r = Invoke-ProviderScript 'apply-profile.ps1' @('anthropic')
        $r.Exit | Should Be 9
        $r.Output | Should Match 'Restart Claude Code'

        $s = Read-TestSettings $h
        $s.env.CLAUDE_PROVIDER_ACTIVE | Should Be 'anthropic'
        $s.PSObject.Properties['apiKeyHelper'] | Should Be $null
        $s.PSObject.Properties['model'] | Should Be $null
    }

    It 'exits 0 when the session env marker already matches' {
        $h = New-TestHome $TestDrive 'fresh'
        $null = Write-TestProfile $h 'anthropic' $anthropicJson
        $env:CLAUDE_PROVIDER_ACTIVE = 'anthropic'
        try {
            (Invoke-ProviderScript 'apply-profile.ps1' @('anthropic')).Exit | Should Be 0
        } finally {
            Remove-Item Env:CLAUDE_PROVIDER_ACTIVE -ErrorAction SilentlyContinue
        }
    }

    It 'applies a full gateway profile: env, model, ttl, extras, apiKeyHelper' {
        $h = New-TestHome $TestDrive 'gw'
        $null = Write-TestProfile $h 'gw' $gwJson
        $r = Invoke-ProviderScript 'apply-profile.ps1' @('gw')
        $r.Exit | Should Be 9

        $s = Read-TestSettings $h
        $s.env.CLAUDE_PROVIDER_ACTIVE | Should Be 'gw'
        $s.env.ANTHROPIC_BASE_URL | Should Be 'https://gateway.example.com/anthropic'
        $s.env.CLAUDE_CODE_API_KEY_HELPER_TTL_MS | Should Be '300000'
        $s.env.CLAUDE_CODE_MAX_OUTPUT_TOKENS | Should Be '64000'
        $s.model | Should Be 'some/model-name'
        $s.apiKeyHelper | Should Match 'gw\.cmd$'
        Test-Path $s.apiKeyHelper | Should Be $true
    }

    It 'backs up the pre-switch settings file to settings.json.bak' {
        $h = New-TestHome $TestDrive 'bak'
        $null = Write-TestProfile $h 'anthropic' $anthropicJson
        $settingsPath = Join-Path $h '.claude\settings.json'
        $null = New-Item -ItemType Directory -Path (Split-Path -Parent $settingsPath) -Force
        Set-Content -LiteralPath $settingsPath -Value '{"theme":"dark"}' -Encoding Ascii

        (Invoke-ProviderScript 'apply-profile.ps1' @('anthropic')).Exit | Should Be 9

        $bak = Get-Content -LiteralPath "$settingsPath.bak" -Raw
        $bak.Trim() | Should Be '{"theme":"dark"}'
        (Read-TestSettings $h).env.CLAUDE_PROVIDER_ACTIVE | Should Be 'anthropic'
    }

    It 'switching back to auth:none removes every managed key but preserves unmanaged ones' {
        $h = New-TestHome $TestDrive 'roundtrip'
        $null = Write-TestProfile $h 'anthropic' $anthropicJson
        $null = Write-TestProfile $h 'gw' $gwJson
        # Pre-existing user settings that the plugin must never touch.
        $null = New-Item -ItemType Directory -Path (Join-Path $h '.claude') -Force
        [System.IO.File]::WriteAllText((Join-Path $h '.claude\settings.json'),
            '{"permissions":{"allow":["Bash(git:*)"]},"env":{"MY_CUSTOM_FLAG":"1"}}')

        (Invoke-ProviderScript 'apply-profile.ps1' @('gw')).Exit | Should Be 9
        (Invoke-ProviderScript 'apply-profile.ps1' @('anthropic')).Exit | Should Be 9

        $s = Read-TestSettings $h
        $s.env.CLAUDE_PROVIDER_ACTIVE | Should Be 'anthropic'
        $s.PSObject.Properties['apiKeyHelper'] | Should Be $null
        $s.PSObject.Properties['model'] | Should Be $null
        $s.env.PSObject.Properties['ANTHROPIC_BASE_URL'] | Should Be $null
        $s.env.PSObject.Properties['CLAUDE_CODE_MAX_OUTPUT_TOKENS'] | Should Be $null
        # unmanaged content preserved through both switches
        $s.env.MY_CUSTOM_FLAG | Should Be '1'
        @($s.permissions.allow)[0] | Should Be 'Bash(git:*)'
    }
}

Describe 'apply-profile.ps1 drift' {
    $env:CPS_APPLY_TEST_KEY = 'sk-fake-apply-key'

    It 'exits 8 when a managed env key was hand-edited' {
        $h = New-TestHome $TestDrive 'drift'
        $null = Write-TestProfile $h 'anthropic' $anthropicJson
        $null = Write-TestProfile $h 'gw' $gwJson
        (Invoke-ProviderScript 'apply-profile.ps1' @('gw')).Exit | Should Be 9

        # Hand-edit a managed key.
        $sPath = Join-Path $h '.claude\settings.json'
        $s = [System.IO.File]::ReadAllText($sPath) | ConvertFrom-Json
        $s.env.ANTHROPIC_BASE_URL = 'https://tampered.example.com'
        [System.IO.File]::WriteAllText($sPath, ($s | ConvertTo-Json -Depth 10))

        $r = Invoke-ProviderScript 'apply-profile.ps1' @('anthropic')
        $r.Exit | Should Be 8
        $r.Output | Should Match 'ANTHROPIC_BASE_URL'

        # -AcceptDrift overwrite proceeds and cleans up.
        $r2 = Invoke-ProviderScript 'apply-profile.ps1' @('anthropic', '-AcceptDrift', 'overwrite')
        $r2.Exit | Should Be 9
        $s2 = Read-TestSettings $h
        $s2.env.PSObject.Properties['ANTHROPIC_BASE_URL'] | Should Be $null
    }

    It 'incorporate preserves a drifted key the new profile does not manage' {
        $h = New-TestHome $TestDrive 'incorporate'
        $null = Write-TestProfile $h 'anthropic' $anthropicJson
        $null = Write-TestProfile $h 'gw' $gwJson
        (Invoke-ProviderScript 'apply-profile.ps1' @('gw')).Exit | Should Be 9

        # Hand-edit the managed extras key.
        $sPath = Join-Path $h '.claude\settings.json'
        $s = [System.IO.File]::ReadAllText($sPath) | ConvertFrom-Json
        $s.env.CLAUDE_CODE_MAX_OUTPUT_TOKENS = '128000'
        [System.IO.File]::WriteAllText($sPath, ($s | ConvertTo-Json -Depth 10))

        $r = Invoke-ProviderScript 'apply-profile.ps1' @('anthropic', '-AcceptDrift', 'incorporate')
        $r.Exit | Should Be 9
        $s2 = Read-TestSettings $h
        # anthropic doesn't manage this key -> the hand-edited value survives, unmanaged
        $s2.env.CLAUDE_CODE_MAX_OUTPUT_TOKENS | Should Be '128000'
        # and it is NOT tracked in the sidecar anymore
        $sidecar = [System.IO.File]::ReadAllText((Join-Path $h '.claude\provider-profiles\.state.json')) | ConvertFrom-Json
        @($sidecar.global.managed_env_keys) -contains 'CLAUDE_CODE_MAX_OUTPUT_TOKENS' | Should Be $false
    }

    It 'refuses to incorporate apiKeyHelper drift (exit 8)' {
        $h = New-TestHome $TestDrive 'helperdrift'
        $null = Write-TestProfile $h 'anthropic' $anthropicJson
        $null = Write-TestProfile $h 'gw' $gwJson
        (Invoke-ProviderScript 'apply-profile.ps1' @('gw')).Exit | Should Be 9

        $sPath = Join-Path $h '.claude\settings.json'
        $s = [System.IO.File]::ReadAllText($sPath) | ConvertFrom-Json
        $s.apiKeyHelper = 'C:\evil\stealer.cmd'
        [System.IO.File]::WriteAllText($sPath, ($s | ConvertTo-Json -Depth 10))

        $r = Invoke-ProviderScript 'apply-profile.ps1' @('anthropic', '-AcceptDrift', 'incorporate')
        $r.Exit | Should Be 8
        $r.Output | Should Match 'apiKeyHelper drift cannot be incorporated'
    }
}

Describe 'apply-profile.ps1 migration from <= 0.1.8' {
    $env:CPS_APPLY_TEST_KEY = 'sk-fake-apply-key'

    # Builds the on-disk state a 0.1.8 install leaves behind: managed keys
    # in .claude\settings.local.json and a sidecar whose target_file points
    # there. Done by applying normally, then relocating the settings file
    # and rewriting the sidecar pointer.
    function New-LegacyState {
        param([string]$TestHome, [string]$ExtraJsonKeys = '')
        $newPath = Join-Path $TestHome '.claude\settings.json'
        $legacyPath = Join-Path $TestHome '.claude\settings.local.json'
        $content = [System.IO.File]::ReadAllText($newPath)
        if ($ExtraJsonKeys -ne '') {
            $doc = $content | ConvertFrom-Json
            $extra = $ExtraJsonKeys | ConvertFrom-Json
            foreach ($p in $extra.PSObject.Properties) {
                $doc | Add-Member -NotePropertyName $p.Name -NotePropertyValue $p.Value -Force
            }
            $content = ($doc | ConvertTo-Json -Depth 10)
        }
        [System.IO.File]::WriteAllText($legacyPath, $content)
        Remove-Item -LiteralPath $newPath -Force
        $scPath = Join-Path $TestHome '.claude\provider-profiles\.state.json'
        $sc = [System.IO.File]::ReadAllText($scPath) | ConvertFrom-Json
        $sc.global.target_file = $legacyPath
        [System.IO.File]::WriteAllText($scPath, ($sc | ConvertTo-Json -Depth 10))
        return $legacyPath
    }

    It 'moves managed keys to settings.json and preserves the rest of the legacy file' {
        $h = New-TestHome $TestDrive 'mig-full'
        $null = Write-TestProfile $h 'anthropic' $anthropicJson
        $null = Write-TestProfile $h 'gw' $gwJson
        (Invoke-ProviderScript 'apply-profile.ps1' @('gw')).Exit | Should Be 9
        $legacyPath = New-LegacyState $h '{"permissions":{"allow":["Bash(git:*)"]}}'

        $r = Invoke-ProviderScript 'apply-profile.ps1' @('anthropic')
        $r.Exit | Should Be 9
        $r.Output | Should Match 'migrated'

        $s = Read-TestSettings $h
        $s.env.CLAUDE_PROVIDER_ACTIVE | Should Be 'anthropic'
        $s.env.PSObject.Properties['ANTHROPIC_BASE_URL'] | Should Be $null

        # legacy file keeps the user's permissions but loses every managed key
        $leg = [System.IO.File]::ReadAllText($legacyPath) | ConvertFrom-Json
        @($leg.permissions.allow)[0] | Should Be 'Bash(git:*)'
        $leg.PSObject.Properties['apiKeyHelper'] | Should Be $null
        $leg.PSObject.Properties['model'] | Should Be $null
        $leg.PSObject.Properties['env'] | Should Be $null

        # sidecar now targets the new file
        $sc = [System.IO.File]::ReadAllText((Join-Path $h '.claude\provider-profiles\.state.json')) | ConvertFrom-Json
        $sc.global.target_file | Should Be (Join-Path $h '.claude\settings.json')
    }

    It 'deletes the legacy file when nothing else is left in it' {
        $h = New-TestHome $TestDrive 'mig-empty'
        $null = Write-TestProfile $h 'anthropic' $anthropicJson
        $null = Write-TestProfile $h 'gw' $gwJson
        (Invoke-ProviderScript 'apply-profile.ps1' @('gw')).Exit | Should Be 9
        $legacyPath = New-LegacyState $h

        (Invoke-ProviderScript 'apply-profile.ps1' @('anthropic')).Exit | Should Be 9
        Test-Path -LiteralPath $legacyPath | Should Be $false
    }

    It 'still detects drift that happened in the legacy file' {
        $h = New-TestHome $TestDrive 'mig-drift'
        $null = Write-TestProfile $h 'anthropic' $anthropicJson
        $null = Write-TestProfile $h 'gw' $gwJson
        (Invoke-ProviderScript 'apply-profile.ps1' @('gw')).Exit | Should Be 9
        $legacyPath = New-LegacyState $h

        $s = [System.IO.File]::ReadAllText($legacyPath) | ConvertFrom-Json
        $s.env.ANTHROPIC_BASE_URL = 'https://tampered.example.com'
        [System.IO.File]::WriteAllText($legacyPath, ($s | ConvertTo-Json -Depth 10))

        $r = Invoke-ProviderScript 'apply-profile.ps1' @('anthropic')
        $r.Exit | Should Be 8
        $r.Output | Should Match 'ANTHROPIC_BASE_URL'
    }

    It 'proceeds cleanly when the legacy record file was deleted by hand' {
        $h = New-TestHome $TestDrive 'mig-gone'
        $null = Write-TestProfile $h 'anthropic' $anthropicJson
        $null = Write-TestProfile $h 'gw' $gwJson
        (Invoke-ProviderScript 'apply-profile.ps1' @('gw')).Exit | Should Be 9
        $legacyPath = New-LegacyState $h
        Remove-Item -LiteralPath $legacyPath -Force

        (Invoke-ProviderScript 'apply-profile.ps1' @('anthropic')).Exit | Should Be 9
        (Read-TestSettings $h).env.CLAUDE_PROVIDER_ACTIVE | Should Be 'anthropic'
    }

    Remove-Item Env:CPS_APPLY_TEST_KEY -ErrorAction SilentlyContinue
}

Describe 'get-active.ps1' {
    $env:CPS_APPLY_TEST_KEY = 'sk-fake-apply-key'

    It 'reports no active profile before any switch' {
        $null = New-TestHome $TestDrive 'ga-empty'
        $r = Invoke-ProviderScript 'get-active.ps1'
        $r.Exit | Should Be 0
        $r.Output | Should Match 'no profile is active'
    }

    It 'reports the active profile with stale flag via -Json' {
        $h = New-TestHome $TestDrive 'ga-json'
        $null = Write-TestProfile $h 'gw' $gwJson
        (Invoke-ProviderScript 'apply-profile.ps1' @('gw')).Exit | Should Be 9

        $r = Invoke-ProviderScript 'get-active.ps1' @('-Json')
        $r.Exit | Should Be 0
        $j = $r.Output | ConvertFrom-Json
        $j.active_profile | Should Be 'gw'
        $j.stale | Should Be $true
        $j.profile.auth_type | Should Be 'env_var'
        $j.profile.base_url | Should Be 'https://gateway.example.com/anthropic'
    }

    It 'reports in-effect when the session marker matches' {
        $h = New-TestHome $TestDrive 'ga-live'
        $null = Write-TestProfile $h 'anthropic' $anthropicJson
        (Invoke-ProviderScript 'apply-profile.ps1' @('anthropic')).Exit | Should Be 9
        $env:CLAUDE_PROVIDER_ACTIVE = 'anthropic'
        try {
            $r = Invoke-ProviderScript 'get-active.ps1' @('-Json')
            ($r.Output | ConvertFrom-Json).stale | Should Be $false
        } finally {
            Remove-Item Env:CLAUDE_PROVIDER_ACTIVE -ErrorAction SilentlyContinue
        }
    }
}

Remove-Item Env:CPS_APPLY_TEST_KEY -ErrorAction SilentlyContinue
Remove-Item Env:CLAUDE_PROVIDER_HOME -ErrorAction SilentlyContinue
