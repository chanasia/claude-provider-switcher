# Pester 3.4-compatible tests for scripts/lib.ps1

$here = Split-Path -Parent $MyInvocation.MyCommand.Path
. (Join-Path $here '..\scripts\lib.ps1')

Describe 'Path helpers' {
    $env:CLAUDE_PROVIDER_HOME = $TestDrive

    It 'Get-ProfileDir honors CLAUDE_PROVIDER_HOME' {
        Get-ProfileDir | Should Be (Join-Path $TestDrive '.claude\provider-profiles')
    }

    It 'Get-SettingsPath points at the user-scope settings.json' {
        # settings.local.json is a PROJECT-level file only; Claude Code
        # never reads a user-level one (the <= 0.1.8 bug).
        Get-SettingsPath | Should Be (Join-Path $TestDrive '.claude\settings.json')
    }

    It 'Get-LegacySettingsPath points at the pre-0.1.9 settings.local.json' {
        Get-LegacySettingsPath | Should Be (Join-Path $TestDrive '.claude\settings.local.json')
    }

    It 'Get-ProfilePath appends .json' {
        Get-ProfilePath -Name 'foo' | Should Be (Join-Path (Get-ProfileDir) 'foo.json')
    }
}

Describe 'Test-DenylistedKey' {
    It 'rejects PATH' {
        Test-DenylistedKey -Key 'PATH' | Should Be $true
    }

    It 'rejects lower-case path (env vars are case-insensitive on Windows)' {
        Test-DenylistedKey -Key 'path' | Should Be $true
    }

    It 'rejects LD_ prefix' {
        Test-DenylistedKey -Key 'LD_ANYTHING' | Should Be $true
    }

    It 'rejects DYLD_ prefix' {
        Test-DenylistedKey -Key 'DYLD_INSERT_LIBRARIES' | Should Be $true
    }

    It 'rejects plugin-managed keys' {
        Test-DenylistedKey -Key 'ANTHROPIC_BASE_URL' | Should Be $true
        Test-DenylistedKey -Key 'ANTHROPIC_MODEL' | Should Be $true
        Test-DenylistedKey -Key 'CLAUDE_PROVIDER_ACTIVE' | Should Be $true
        Test-DenylistedKey -Key 'CLAUDE_CODE_API_KEY_HELPER_TTL_MS' | Should Be $true
    }

    It 'rejects NODE_OPTIONS and PYTHONPATH' {
        Test-DenylistedKey -Key 'NODE_OPTIONS' | Should Be $true
        Test-DenylistedKey -Key 'PYTHONPATH' | Should Be $true
    }

    It 'allows ordinary custom keys' {
        Test-DenylistedKey -Key 'CLAUDE_CODE_MAX_OUTPUT_TOKENS' | Should Be $false
        Test-DenylistedKey -Key 'MY_GATEWAY_FLAG' | Should Be $false
    }
}

Describe 'Write-AtomicFile' {
    It 'writes content to the target' {
        $target = Join-Path $TestDrive 'out.txt'
        Write-AtomicFile -Path $target -Content 'hello'
        [System.IO.File]::ReadAllText($target) | Should Be 'hello'
    }

    It 'writes UTF-8 without BOM' {
        $target = Join-Path $TestDrive 'bom.txt'
        Write-AtomicFile -Path $target -Content 'abc'
        $bytes = [System.IO.File]::ReadAllBytes($target)
        $bytes[0] | Should Be ([byte][char]'a')
    }

    It 'replaces an existing file' {
        $target = Join-Path $TestDrive 'replace.txt'
        Write-AtomicFile -Path $target -Content 'one'
        Write-AtomicFile -Path $target -Content 'two'
        [System.IO.File]::ReadAllText($target) | Should Be 'two'
    }

    It 'leaves no temp files behind' {
        $target = Join-Path $TestDrive 'clean.txt'
        Write-AtomicFile -Path $target -Content 'x'
        (Get-ChildItem $TestDrive -Filter '.clean.txt.*' -Force | Measure-Object).Count | Should Be 0
    }

    It 'throws when the parent directory is missing' {
        { Write-AtomicFile -Path (Join-Path $TestDrive 'nodir\f.txt') -Content 'x' } | Should Throw
    }
}

Describe 'Advisory lock' {
    $env:CLAUDE_PROVIDER_HOME = $TestDrive
    $null = New-Item -ItemType Directory -Path (Get-ProfileDir) -Force

    It 'acquires and releases' {
        Lock-ProviderState | Should Be $true
        Test-Path (Get-LockDir) | Should Be $true
        Unlock-ProviderState
        Test-Path (Get-LockDir) | Should Be $false
    }

    It 'refuses a second acquisition while held by a live process' {
        Lock-ProviderState | Should Be $true
        Lock-ProviderState | Should Be $false
        Unlock-ProviderState
    }

    It 'reclaims a stale lock whose holder PID is dead' {
        $null = New-Item -ItemType Directory -Path (Get-LockDir) -Force
        Set-Content -LiteralPath (Join-Path (Get-LockDir) 'pid') -Value '999999' -Encoding Ascii
        Lock-ProviderState | Should Be $true
        Unlock-ProviderState
    }
}

Describe 'Sidecar state' {
    $env:CLAUDE_PROVIDER_HOME = $TestDrive
    $null = New-Item -ItemType Directory -Path (Get-ProfileDir) -Force

    It 'reads missing sidecar as empty' {
        Read-SidecarScope -ScopeKey 'global' | Should Be $null
    }

    It 'round-trips a scope entry' {
        Write-SidecarScope -ScopeKey 'global' -Entry @{ active_profile = 'foo'; managed_env_keys = @('A', 'B') }
        $entry = Read-SidecarScope -ScopeKey 'global'
        $entry.active_profile | Should Be 'foo'
        @($entry.managed_env_keys).Count | Should Be 2
    }

    It 'preserves other scopes on write' {
        Write-SidecarScope -ScopeKey 'global' -Entry @{ active_profile = 'foo' }
        Write-SidecarScope -ScopeKey 'project' -Entry @{ active_profile = 'bar' }
        (Read-SidecarScope -ScopeKey 'global').active_profile | Should Be 'foo'
        (Read-SidecarScope -ScopeKey 'project').active_profile | Should Be 'bar'
    }

    It 'throws on a corrupt sidecar instead of treating it as empty' {
        Set-Content -LiteralPath (Get-SidecarPath) -Value '{not json' -Encoding Ascii
        { Read-Sidecar } | Should Throw
        Remove-Item -LiteralPath (Get-SidecarPath) -Force
    }
}

Describe 'Windows Credential Manager round-trip' {
    $target = "claude-provider-switcher/pester-test-$PID"

    It 'writes, detects, reads, and deletes a credential' {
        Set-StoredCredential -Target $target -Secret 'test-secret-123'
        Test-StoredCredential -Target $target | Should Be $true
        Get-StoredCredential -Target $target | Should Be 'test-secret-123'
        Remove-StoredCredential -Target $target | Should Be $true
        Test-StoredCredential -Target $target | Should Be $false
    }

    It 'throws when reading a missing credential' {
        { Get-StoredCredential -Target "claude-provider-switcher/definitely-missing-$PID" } | Should Throw
    }
}

# Cleanup: don't leak the test HOME override into the caller's session.
Remove-Item Env:CLAUDE_PROVIDER_HOME -ErrorAction SilentlyContinue
