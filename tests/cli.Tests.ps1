# Pester 3.4-compatible tests for scripts/provider-cli.ps1 (the offline
# `claude-provider` CLI) and scripts/reset.ps1

$here = Split-Path -Parent $MyInvocation.MyCommand.Path
. (Join-Path $here 'Integration.Helpers.ps1')
. (Join-Path $here '..\scripts\lib.ps1')

Describe 'claude-provider CLI dispatch' {
    $env:CLAUDE_PROVIDER_SCRIPTS = (Resolve-Path (Join-Path $here '..\scripts')).Path

    It 'exits 2 with usage for no command' {
        $r = Invoke-ProviderScript 'provider-cli.ps1'
        $r.Exit | Should Be 2
        $r.Output | Should Match 'usage: claude-provider'
    }

    It 'exits 2 for any command that is not anthropic or reset' {
        (Invoke-ProviderScript 'provider-cli.ps1' @('switch')).Exit | Should Be 2
        (Invoke-ProviderScript 'provider-cli.ps1' @('list')).Exit | Should Be 2
    }
}

Describe 'claude-provider anthropic' {
    $env:CLAUDE_PROVIDER_SCRIPTS = (Resolve-Path (Join-Path $here '..\scripts')).Path

    It 'seeds the profile on a fresh machine and switches back (exit 9)' {
        $h = New-TestHome $TestDrive 'cli-fresh'
        $r = Invoke-ProviderScript 'provider-cli.ps1' @('anthropic')
        $r.Exit | Should Be 9
        Test-Path (Join-Path $h '.claude\provider-profiles\anthropic.json') | Should Be $true
        (Read-TestSettings $h).env.CLAUDE_PROVIDER_ACTIVE | Should Be 'anthropic'
    }

    It 'overwrites drift instead of stopping (emergency semantics)' {
        $h = New-TestHome $TestDrive 'cli-drift'
        (Invoke-ProviderScript 'provider-cli.ps1' @('anthropic')).Exit | Should Be 9

        $sPath = Join-Path $h '.claude\settings.json'
        $s = [System.IO.File]::ReadAllText($sPath) | ConvertFrom-Json
        $s.env.CLAUDE_PROVIDER_ACTIVE = 'tampered'
        [System.IO.File]::WriteAllText($sPath, ($s | ConvertTo-Json -Depth 10))

        $r = Invoke-ProviderScript 'provider-cli.ps1' @('anthropic')
        $r.Exit | Should Be 9
        $r.Output | Should Match 'emergency mode'
        (Read-TestSettings $h).env.CLAUDE_PROVIDER_ACTIVE | Should Be 'anthropic'
    }

    It 'repairs a corrupt sidecar and still succeeds' {
        $h = New-TestHome $TestDrive 'cli-corrupt'
        (Invoke-ProviderScript 'provider-cli.ps1' @('anthropic')).Exit | Should Be 9
        Set-Content -LiteralPath (Join-Path $h '.claude\provider-profiles\.state.json') -Value '{broken' -Encoding Ascii

        $r = Invoke-ProviderScript 'provider-cli.ps1' @('anthropic')
        $r.Exit | Should Be 9
        (Read-TestSettings $h).env.CLAUDE_PROVIDER_ACTIVE | Should Be 'anthropic'
    }
}

Describe 'claude-provider reset' {
    $env:CLAUDE_PROVIDER_SCRIPTS = (Resolve-Path (Join-Path $here '..\scripts')).Path

    It 'refuses without -Force in a non-interactive host and changes nothing' {
        $h = New-TestHome $TestDrive 'reset-refuse'
        $null = Write-TestProfile $h 'anthropic' '{"name":"anthropic","auth":{"type":"none"}}'
        $r = Invoke-ProviderScript 'provider-cli.ps1' @('reset')
        $r.Exit | Should Be 2
        $r.Output | Should Match 'not confirmed'
        Test-Path (Join-Path $h '.claude\provider-profiles\anthropic.json') | Should Be $true
    }

    It 'removes settings keys, profiles, credential, and CLI files with -Force' {
        $h = New-TestHome $TestDrive 'reset-full'
        $target = "claude-provider-switcher/reset-test-$PID"
        Set-StoredCredential -Target $target -Secret 'sk-reset-test'
        try {
            $null = Write-TestProfile $h 'cm' ('{"name":"cm","auth":{"type":"credman","target":"' + $target + '"}}')
            (Invoke-ProviderScript 'apply-profile.ps1' @('cm')).Exit | Should Be 9

            # fake installed CLI inside the sandbox home
            $bin = Join-Path $h '.claude\bin'
            $null = New-Item -ItemType Directory -Path $bin -Force
            Set-Content -LiteralPath (Join-Path $bin 'claude-provider.cmd') -Value '@echo off' -Encoding Ascii
            Set-Content -LiteralPath (Join-Path $bin 'claude-provider.ps1') -Value '# cli' -Encoding Ascii

            # user settings that must survive
            $sPath = Join-Path $h '.claude\settings.json'
            $s = [System.IO.File]::ReadAllText($sPath) | ConvertFrom-Json
            $s | Add-Member NoteProperty permissions (@{ allow = @('Bash(git:*)') })
            [System.IO.File]::WriteAllText($sPath, ($s | ConvertTo-Json -Depth 10))

            $r = Invoke-ProviderScript 'provider-cli.ps1' @('reset', '-Force')
            $r.Exit | Should Be 0
            $r.Output | Should Match 'reset complete'

            Test-Path (Join-Path $h '.claude\provider-profiles') | Should Be $false
            Test-Path (Join-Path $bin 'claude-provider.cmd') | Should Be $false
            Test-StoredCredential -Target $target | Should Be $false

            $after = [System.IO.File]::ReadAllText($sPath) | ConvertFrom-Json
            $after.PSObject.Properties['apiKeyHelper'] | Should Be $null
            $after.PSObject.Properties['env'] | Should Be $null
            @($after.permissions.allow)[0] | Should Be 'Bash(git:*)'
        } finally {
            $null = Remove-StoredCredential -Target $target
        }
    }

    It 'exits 0 when there is nothing to reset' {
        # a truly empty home - New-TestHome would pre-create the profile dir
        $h = Join-Path $TestDrive 'reset-empty'
        $null = New-Item -ItemType Directory -Path $h -Force
        $env:CLAUDE_PROVIDER_HOME = $h
        $r = Invoke-ProviderScript 'provider-cli.ps1' @('reset', '-Force')
        $r.Exit | Should Be 0
        $r.Output | Should Match 'nothing to reset'
    }
}

Remove-Item Env:CLAUDE_PROVIDER_SCRIPTS -ErrorAction SilentlyContinue
Remove-Item Env:CLAUDE_PROVIDER_HOME -ErrorAction SilentlyContinue
