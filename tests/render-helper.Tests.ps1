# Pester 3.4-compatible tests for scripts/render-helper.ps1

$here = Split-Path -Parent $MyInvocation.MyCommand.Path
. (Join-Path $here 'Integration.Helpers.ps1')
. (Join-Path $here '..\scripts\lib.ps1')

Describe 'render-helper.ps1' {

    It 'exits 2 with no arguments' {
        (Invoke-ProviderScript 'render-helper.ps1').Exit | Should Be 2
    }

    It 'renders nothing for auth:none and prints an empty helper path' {
        $home1 = New-TestHome $TestDrive 'none'
        $p = Write-TestProfile $home1 'anthropic' '{"name":"anthropic","auth":{"type":"none"}}'
        $r = Invoke-ProviderScript 'render-helper.ps1' @($p)
        $r.Exit | Should Be 0
        (Test-Path (Join-Path $home1 '.claude\provider-profiles\.helpers\anthropic.cmd')) | Should Be $false
    }

    It 'renders an executable env_var shim pair' {
        $home1 = New-TestHome $TestDrive 'envvar'
        $p = Write-TestProfile $home1 'gw' '{"name":"gw","auth":{"type":"env_var","var":"CPS_TEST_KEY"}}'
        $r = Invoke-ProviderScript 'render-helper.ps1' @($p)
        $r.Exit | Should Be 0

        $ps1 = Join-Path $home1 '.claude\provider-profiles\.helpers\gw.ps1'
        $cmd = Join-Path $home1 '.claude\provider-profiles\.helpers\gw.cmd'
        Test-Path $ps1 | Should Be $true
        Test-Path $cmd | Should Be $true
        $r.Output | Should Match ([regex]::Escape($cmd))

        # The rendered .ps1 must actually print the key.
        $env:CPS_TEST_KEY = 'sk-fake-value-for-test'
        try {
            $secret = & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $ps1
            $LASTEXITCODE | Should Be 0
            "$secret" | Should Be 'sk-fake-value-for-test'
        } finally {
            Remove-Item Env:CPS_TEST_KEY -ErrorAction SilentlyContinue
        }
    }

    It 'env_var shim fails loudly when the variable is unset' {
        $home1 = New-TestHome $TestDrive 'envvar-missing'
        $p = Write-TestProfile $home1 'gw' '{"name":"gw","auth":{"type":"env_var","var":"CPS_DEFINITELY_UNSET_VAR"}}'
        $null = Invoke-ProviderScript 'render-helper.ps1' @($p)
        $ps1 = Join-Path $home1 '.claude\provider-profiles\.helpers\gw.ps1'
        $null = & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $ps1 2>&1
        $LASTEXITCODE | Should Be 1
    }

    It 'renders an executable credman shim (end-to-end through the .cmd wrapper)' {
        $home1 = New-TestHome $TestDrive 'credman'
        $target = "claude-provider-switcher/render-test-$PID"
        $p = Write-TestProfile $home1 'cm' ('{"name":"cm","auth":{"type":"credman","target":"' + $target + '"}}')
        Set-StoredCredential -Target $target -Secret 'sk-credman-test-value'
        try {
            $r = Invoke-ProviderScript 'render-helper.ps1' @($p)
            $r.Exit | Should Be 0
            $cmd = Join-Path $home1 '.claude\provider-profiles\.helpers\cm.cmd'
            # Execute exactly what Claude Code would execute: the .cmd itself.
            $secret = & cmd.exe /c $cmd
            $LASTEXITCODE | Should Be 0
            "$secret" | Should Be 'sk-credman-test-value'
        } finally {
            $null = Remove-StoredCredential -Target $target
        }
    }

    It 'removes a stale shim pair when the profile becomes auth:none' {
        $home1 = New-TestHome $TestDrive 'cleanup'
        $p = Write-TestProfile $home1 'gw' '{"name":"gw","auth":{"type":"env_var","var":"CPS_TEST_KEY"}}'
        $null = Invoke-ProviderScript 'render-helper.ps1' @($p)
        Test-Path (Join-Path $home1 '.claude\provider-profiles\.helpers\gw.cmd') | Should Be $true

        $p = Write-TestProfile $home1 'gw' '{"name":"gw","auth":{"type":"none"}}'
        (Invoke-ProviderScript 'render-helper.ps1' @($p)).Exit | Should Be 0
        Test-Path (Join-Path $home1 '.claude\provider-profiles\.helpers\gw.cmd') | Should Be $false
        Test-Path (Join-Path $home1 '.claude\provider-profiles\.helpers\gw.ps1') | Should Be $false
    }

    It 'rejects a credman target that fails the pattern (render-time defense in depth)' {
        $home1 = New-TestHome $TestDrive 'defense'
        $p = Write-TestProfile $home1 'evil' '{"name":"evil","auth":{"type":"credman","target":"a''; Invoke-Evil #"}}'
        (Invoke-ProviderScript 'render-helper.ps1' @($p)).Exit | Should Be 6
        Test-Path (Join-Path $home1 '.claude\provider-profiles\.helpers\evil.ps1') | Should Be $false
    }
}

Remove-Item Env:CLAUDE_PROVIDER_HOME -ErrorAction SilentlyContinue
