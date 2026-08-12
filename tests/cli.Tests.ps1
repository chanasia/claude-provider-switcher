# Pester 3.4-compatible tests for scripts/provider-cli.ps1

$here = Split-Path -Parent $MyInvocation.MyCommand.Path
. (Join-Path $here 'Integration.Helpers.ps1')

Describe 'provider-cli.ps1' {
    # Point the dispatcher straight at the repo scripts (resolution rule 1).
    $env:CLAUDE_PROVIDER_SCRIPTS = (Resolve-Path (Join-Path $here '..\scripts')).Path

    It 'exits 2 with usage for no command' {
        $r = Invoke-ProviderScript 'provider-cli.ps1'
        $r.Exit | Should Be 2
        $r.Output | Should Match 'usage: provider'
    }

    It 'exits 2 for an unknown command' {
        (Invoke-ProviderScript 'provider-cli.ps1' @('frobnicate')).Exit | Should Be 2
    }

    It 'dispatches current and reports Anthropic direct on a fresh home' {
        $null = New-TestHome $TestDrive 'cli-current'
        $r = Invoke-ProviderScript 'provider-cli.ps1' @('current')
        $r.Exit | Should Be 0
        $r.Output | Should Match 'Anthropic direct'
    }

    It 'passes positional args through (switch -> not found -> exit 3)' {
        $h = New-TestHome $TestDrive 'cli-switch'
        $null = Write-TestProfile $h 'anthropic' '{"name":"anthropic","auth":{"type":"none"}}'
        $r = Invoke-ProviderScript 'provider-cli.ps1' @('switch', 'nope')
        $r.Exit | Should Be 3
        $r.Output | Should Match 'anthropic'
    }

    It 'passes switch-style args through (-Json reaches list as a real switch)' {
        $h = New-TestHome $TestDrive 'cli-json'
        $null = Write-TestProfile $h 'anthropic' '{"name":"anthropic","auth":{"type":"none"}}'
        $r = Invoke-ProviderScript 'provider-cli.ps1' @('list', '-Json')
        $r.Exit | Should Be 0
        $j = $r.Output | ConvertFrom-Json
        @($j.profiles).Count | Should Be 1
    }

    It 'runs a full switch end-to-end through the dispatcher' {
        $h = New-TestHome $TestDrive 'cli-e2e'
        $null = Write-TestProfile $h 'anthropic' '{"name":"anthropic","auth":{"type":"none"}}'
        $r = Invoke-ProviderScript 'provider-cli.ps1' @('switch', 'anthropic')
        $r.Exit | Should Be 9
        (Read-TestSettings $h).env.CLAUDE_PROVIDER_ACTIVE | Should Be 'anthropic'
    }

    It 'exits 1 with guidance when no scripts can be found' {
        $saved = $env:CLAUDE_PROVIDER_SCRIPTS
        $savedProfile = $env:USERPROFILE
        try {
            Remove-Item Env:CLAUDE_PROVIDER_SCRIPTS
            $env:USERPROFILE = Join-Path $TestDrive 'cli-nocache'
            $null = New-Item -ItemType Directory -Path $env:USERPROFILE -Force
            $r = Invoke-ProviderScript 'provider-cli.ps1' @('current')
            $r.Exit | Should Be 1
            $r.Output | Should Match 'could not find'
        } finally {
            $env:CLAUDE_PROVIDER_SCRIPTS = $saved
            $env:USERPROFILE = $savedProfile
        }
    }
}

Remove-Item Env:CLAUDE_PROVIDER_SCRIPTS -ErrorAction SilentlyContinue
Remove-Item Env:CLAUDE_PROVIDER_HOME -ErrorAction SilentlyContinue
