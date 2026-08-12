# Pester 3.4-compatible tests for init / list / create / remove / doctor

$here = Split-Path -Parent $MyInvocation.MyCommand.Path
. (Join-Path $here 'Integration.Helpers.ps1')
. (Join-Path $here '..\scripts\lib.ps1')

Describe 'init.ps1' {

    It 'creates the profile dir, seeds only anthropic, and writes a sidecar' {
        $h = Join-Path $TestDrive 'init-fresh'
        $null = New-Item -ItemType Directory -Path $h -Force
        $env:CLAUDE_PROVIDER_HOME = $h

        $r = Invoke-ProviderScript 'init.ps1'
        $r.Exit | Should Be 0

        $dir = Join-Path $h '.claude\provider-profiles'
        Test-Path (Join-Path $dir 'anthropic.json') | Should Be $true
        # the example template documents the shape but must NOT be seeded -
        # unusable placeholders in the list confuse users
        Test-Path (Join-Path $dir 'gateway-example.json') | Should Be $false
        Test-Path (Join-Path $dir '.state.json') | Should Be $true
        Test-Path (Join-Path $dir '.helpers') | Should Be $true
    }

    It 'seeds a profile that passes validation' {
        $h = Join-Path $TestDrive 'init-valid'
        $null = New-Item -ItemType Directory -Path $h -Force
        $env:CLAUDE_PROVIDER_HOME = $h
        $null = Invoke-ProviderScript 'init.ps1'

        $p = Join-Path $h '.claude\provider-profiles\anthropic.json'
        (Invoke-ProviderScript 'validate-profile.ps1' @($p)).Exit | Should Be 0
    }

    It 'is idempotent and never overwrites an edited profile' {
        $h = Join-Path $TestDrive 'init-idem'
        $null = New-Item -ItemType Directory -Path $h -Force
        $env:CLAUDE_PROVIDER_HOME = $h
        $null = Invoke-ProviderScript 'init.ps1'

        $p = Join-Path $h '.claude\provider-profiles\anthropic.json'
        [System.IO.File]::WriteAllText($p, '{"name":"anthropic","description":"MY EDIT","auth":{"type":"none"}}')

        $r = Invoke-ProviderScript 'init.ps1'
        $r.Exit | Should Be 0
        $r.Output | Should Match 'already present'
        ([System.IO.File]::ReadAllText($p)) | Should Match 'MY EDIT'
    }
}

Describe 'list-profiles.ps1' {

    It 'exits 3 when the profile dir does not exist' {
        $env:CLAUDE_PROVIDER_HOME = (Join-Path $TestDrive 'list-nodir')
        (Invoke-ProviderScript 'list-profiles.ps1').Exit | Should Be 3
    }

    It 'lists seeded profiles and marks none active' {
        $h = Join-Path $TestDrive 'list-seeded'
        $null = New-Item -ItemType Directory -Path $h -Force
        $env:CLAUDE_PROVIDER_HOME = $h
        $null = Invoke-ProviderScript 'init.ps1'

        $r = Invoke-ProviderScript 'list-profiles.ps1'
        $r.Exit | Should Be 0
        $r.Output | Should Match 'anthropic'
        $r.Output | Should Match 'no profile is active'
    }

    It 'marks the active profile after a switch (-Json)' {
        $h = New-TestHome $TestDrive 'list-active'
        $null = Write-TestProfile $h 'anthropic' '{"name":"anthropic","auth":{"type":"none"}}'
        (Invoke-ProviderScript 'apply-profile.ps1' @('anthropic')).Exit | Should Be 9

        $j = (Invoke-ProviderScript 'list-profiles.ps1' @('-Json')).Output | ConvertFrom-Json
        $j.active_profile | Should Be 'anthropic'
        @($j.profiles | Where-Object { $_.name -eq 'anthropic' }).active | Should Be $true
    }

    It 'flags an unparseable profile instead of failing' {
        $h = New-TestHome $TestDrive 'list-broken'
        $null = Write-TestProfile $h 'broken' '{oops'
        $r = Invoke-ProviderScript 'list-profiles.ps1'
        $r.Exit | Should Be 0
        $r.Output | Should Match 'INVALID JSON'
    }
}

Describe 'create-profile.ps1' {

    It 'exits 2 without required arguments' {
        $null = New-TestHome $TestDrive 'create-usage'
        (Invoke-ProviderScript 'create-profile.ps1').Exit | Should Be 2
    }

    It 'exits 2 when credman is chosen without a target' {
        $null = New-TestHome $TestDrive 'create-notarget'
        (Invoke-ProviderScript 'create-profile.ps1' @('-Name', 'x', '-AuthType', 'credman')).Exit | Should Be 2
    }

    It 'creates a valid credman profile' {
        $h = New-TestHome $TestDrive 'create-ok'
        $r = Invoke-ProviderScript 'create-profile.ps1' @(
            '-Name', 'mygw',
            '-AuthType', 'credman',
            '-CredTarget', 'claude-provider/mygw',
            '-Description', 'my gateway',
            '-BaseUrl', 'https://gateway.example.com/anthropic',
            '-Model', 'vendor/model-a',
            '-TtlMs', '300000',
            '-Extra', 'CLAUDE_CODE_MAX_OUTPUT_TOKENS=64000'
        )
        $r.Exit | Should Be 0

        $p = Join-Path $h '.claude\provider-profiles\mygw.json'
        (Invoke-ProviderScript 'validate-profile.ps1' @($p)).Exit | Should Be 0
        $doc = [System.IO.File]::ReadAllText($p) | ConvertFrom-Json
        $doc.auth.target | Should Be 'claude-provider/mygw'
        $doc.model | Should Be 'vendor/model-a'
        $doc.ttl_ms | Should Be 300000
        $doc.extras.CLAUDE_CODE_MAX_OUTPUT_TOKENS | Should Be '64000'
    }

    It 'exits 4 when the profile already exists, and 0 with -Force' {
        $h = New-TestHome $TestDrive 'create-exists'
        $args1 = @('-Name', 'dup', '-AuthType', 'none')
        (Invoke-ProviderScript 'create-profile.ps1' $args1).Exit | Should Be 0
        (Invoke-ProviderScript 'create-profile.ps1' $args1).Exit | Should Be 4
        (Invoke-ProviderScript 'create-profile.ps1' ($args1 + '-Force')).Exit | Should Be 0
    }

    It 'refuses to write a profile that would fail validation, leaving no file' {
        $h = New-TestHome $TestDrive 'create-invalid'
        $r = Invoke-ProviderScript 'create-profile.ps1' @(
            '-Name', 'bad', '-AuthType', 'none', '-Extra', 'NODE_OPTIONS=--inspect')
        $r.Exit | Should Be 6
        Test-Path (Join-Path $h '.claude\provider-profiles\bad.json') | Should Be $false
    }

    It 'refuses an http:// base_url for a non-local host' {
        $h = New-TestHome $TestDrive 'create-http'
        $r = Invoke-ProviderScript 'create-profile.ps1' @(
            '-Name', 'insecure', '-AuthType', 'none', '-BaseUrl', 'http://gateway.example.com')
        $r.Exit | Should Be 6
        Test-Path (Join-Path $h '.claude\provider-profiles\insecure.json') | Should Be $false
    }

    It 'leaves no staging file behind on failure' {
        $h = New-TestHome $TestDrive 'create-staging'
        $null = Invoke-ProviderScript 'create-profile.ps1' @('-Name', 'bad2', '-AuthType', 'none', '-Model', 'has space')
        @(Get-ChildItem (Join-Path $h '.claude\provider-profiles') -Filter '.staging-*' -Force).Count | Should Be 0
    }
}

Describe 'remove-profile.ps1' {

    It 'exits 3 for an unknown profile' {
        $null = New-TestHome $TestDrive 'rm-missing'
        (Invoke-ProviderScript 'remove-profile.ps1' @('nope')).Exit | Should Be 3
    }

    It 'exits 5 and keeps the file when the profile is active' {
        $h = New-TestHome $TestDrive 'rm-active'
        $null = Write-TestProfile $h 'anthropic' '{"name":"anthropic","auth":{"type":"none"}}'
        (Invoke-ProviderScript 'apply-profile.ps1' @('anthropic')).Exit | Should Be 9

        $r = Invoke-ProviderScript 'remove-profile.ps1' @('anthropic')
        $r.Exit | Should Be 5
        $r.Output | Should Match 'active profile'
        Test-Path (Join-Path $h '.claude\provider-profiles\anthropic.json') | Should Be $true
    }

    It 'removes an inactive profile and its shims' {
        $h = New-TestHome $TestDrive 'rm-ok'
        $env:CPS_RM_KEY = 'sk-fake'
        try {
            $null = Write-TestProfile $h 'anthropic' '{"name":"anthropic","auth":{"type":"none"}}'
            $null = Write-TestProfile $h 'gw' '{"name":"gw","auth":{"type":"env_var","var":"CPS_RM_KEY"}}'
            (Invoke-ProviderScript 'apply-profile.ps1' @('gw')).Exit | Should Be 9
            (Invoke-ProviderScript 'apply-profile.ps1' @('anthropic')).Exit | Should Be 9

            $r = Invoke-ProviderScript 'remove-profile.ps1' @('gw')
            $r.Exit | Should Be 0
            Test-Path (Join-Path $h '.claude\provider-profiles\gw.json') | Should Be $false
            Test-Path (Join-Path $h '.claude\provider-profiles\.helpers\gw.cmd') | Should Be $false
            Test-Path (Join-Path $h '.claude\provider-profiles\.helpers\gw.ps1') | Should Be $false
        } finally {
            Remove-Item Env:CPS_RM_KEY -ErrorAction SilentlyContinue
        }
    }

    It 'leaves the Credential Manager entry alone unless -DeleteCredential is passed' {
        $h = New-TestHome $TestDrive 'rm-cred'
        $target = "claude-provider-switcher/rm-test-$PID"
        Set-StoredCredential -Target $target -Secret 'sk-test'
        try {
            $null = Write-TestProfile $h 'cm' ('{"name":"cm","auth":{"type":"credman","target":"' + $target + '"}}')
            (Invoke-ProviderScript 'remove-profile.ps1' @('cm')).Exit | Should Be 0
            Test-StoredCredential -Target $target | Should Be $true

            $null = Write-TestProfile $h 'cm' ('{"name":"cm","auth":{"type":"credman","target":"' + $target + '"}}')
            (Invoke-ProviderScript 'remove-profile.ps1' @('cm', '-DeleteCredential')).Exit | Should Be 0
            Test-StoredCredential -Target $target | Should Be $false
        } finally {
            $null = Remove-StoredCredential -Target $target
        }
    }
}

Describe 'set-credential.ps1' {

    It 'round-trips a secret passed via stdin' {
        $target = "claude-provider-switcher/setcred-stdin-$PID"
        try {
            $prev = $ErrorActionPreference
            $ErrorActionPreference = 'Continue'
            try {
                $null = 'sk-stdin-value' | & powershell.exe -NoProfile -ExecutionPolicy Bypass `
                    -File (Join-Path $script:ScriptsDir 'set-credential.ps1') -Target $target 2>&1
                $code = $LASTEXITCODE
            } finally {
                $ErrorActionPreference = $prev
            }
            $code | Should Be 0
            Get-StoredCredential -Target $target | Should Be 'sk-stdin-value'
        } finally {
            $null = Remove-StoredCredential -Target $target
        }
    }

    It 'exits 2 when stdin is empty and no -Secret was given' {
        $prev = $ErrorActionPreference
        $ErrorActionPreference = 'Continue'
        try {
            $null = '' | & powershell.exe -NoProfile -ExecutionPolicy Bypass `
                -File (Join-Path $script:ScriptsDir 'set-credential.ps1') -Target 'claude-provider-switcher/setcred-empty' 2>&1
            $code = $LASTEXITCODE
        } finally {
            $ErrorActionPreference = $prev
        }
        $code | Should Be 2
    }

    It '-Test exits 0 for a stored credential and never prints the value' {
        $target = "claude-provider-switcher/setcred-test-$PID"
        Set-StoredCredential -Target $target -Secret 'sk-hidden-value'
        try {
            $r = Invoke-ProviderScript 'set-credential.ps1' @('-Target', $target, '-Test')
            $r.Exit | Should Be 0
            $r.Output | Should Not Match 'sk-hidden-value'
        } finally {
            $null = Remove-StoredCredential -Target $target
        }
    }

    It '-Test exits 3 when nothing is stored under the target' {
        $r = Invoke-ProviderScript 'set-credential.ps1' @('-Target', 'claude-provider-switcher/setcred-absent', '-Test')
        $r.Exit | Should Be 3
    }
}

Describe 'doctor.ps1' {

    It 'exits 1 when the profile dir is missing' {
        $env:CLAUDE_PROVIDER_HOME = (Join-Path $TestDrive 'dr-nodir')
        (Invoke-ProviderScript 'doctor.ps1').Exit | Should Be 1
    }

    It 'reports all clear on a healthy freshly-switched setup' {
        $h = New-TestHome $TestDrive 'dr-clean'
        $null = Write-TestProfile $h 'anthropic' '{"name":"anthropic","auth":{"type":"none"}}'
        (Invoke-ProviderScript 'apply-profile.ps1' @('anthropic')).Exit | Should Be 9

        $r = Invoke-ProviderScript 'doctor.ps1'
        $r.Exit | Should Be 0
        $r.Output | Should Match 'All checks passed'
    }

    It 'detects drift in a managed key' {
        $h = New-TestHome $TestDrive 'dr-drift'
        $null = Write-TestProfile $h 'anthropic' '{"name":"anthropic","auth":{"type":"none"}}'
        (Invoke-ProviderScript 'apply-profile.ps1' @('anthropic')).Exit | Should Be 9

        $sPath = Join-Path $h '.claude\settings.local.json'
        $s = [System.IO.File]::ReadAllText($sPath) | ConvertFrom-Json
        $s.env.CLAUDE_PROVIDER_ACTIVE = 'tampered'
        [System.IO.File]::WriteAllText($sPath, ($s | ConvertTo-Json -Depth 10))

        $j = (Invoke-ProviderScript 'doctor.ps1' @('-Json')).Output | ConvertFrom-Json
        @($j.findings | Where-Object { $_.check -eq 'drift' -and $_.level -eq 'warn' }).Count | Should Be 1
    }

    It 'detects a missing credential for the active credman profile' {
        $h = New-TestHome $TestDrive 'dr-cred'
        $target = "claude-provider-switcher/doctor-test-$PID"
        Set-StoredCredential -Target $target -Secret 'sk-test'
        $null = Write-TestProfile $h 'cm' ('{"name":"cm","auth":{"type":"credman","target":"' + $target + '"}}')
        (Invoke-ProviderScript 'apply-profile.ps1' @('cm')).Exit | Should Be 9
        $null = Remove-StoredCredential -Target $target

        $r = Invoke-ProviderScript 'doctor.ps1'
        $r.Exit | Should Be 1
        $r.Output | Should Match 'no credential stored'
    }

    It 'reports and then repairs a corrupt sidecar with -Fix' {
        $h = New-TestHome $TestDrive 'dr-sidecar'
        $null = Write-TestProfile $h 'anthropic' '{"name":"anthropic","auth":{"type":"none"}}'
        Set-Content -LiteralPath (Join-Path $h '.claude\provider-profiles\.state.json') -Value '{bad' -Encoding Ascii

        (Invoke-ProviderScript 'doctor.ps1').Exit | Should Be 1
        $r = Invoke-ProviderScript 'doctor.ps1' @('-Fix')
        $r.Output | Should Match 'FIXED'
        (Invoke-ProviderScript 'doctor.ps1').Exit | Should Be 0
    }

    It 're-renders a deleted shim with -Fix' {
        $h = New-TestHome $TestDrive 'dr-shim'
        $env:CPS_DR_KEY = 'sk-fake'
        try {
            $null = Write-TestProfile $h 'gw' '{"name":"gw","auth":{"type":"env_var","var":"CPS_DR_KEY"}}'
            (Invoke-ProviderScript 'apply-profile.ps1' @('gw')).Exit | Should Be 9
            Remove-Item (Join-Path $h '.claude\provider-profiles\.helpers\gw.cmd') -Force

            (Invoke-ProviderScript 'doctor.ps1').Exit | Should Be 1
            $null = Invoke-ProviderScript 'doctor.ps1' @('-Fix')
            Test-Path (Join-Path $h '.claude\provider-profiles\.helpers\gw.cmd') | Should Be $true
        } finally {
            Remove-Item Env:CPS_DR_KEY -ErrorAction SilentlyContinue
        }
    }

    It 'removes an orphaned shim with -Fix' {
        $h = New-TestHome $TestDrive 'dr-orphan'
        $null = Write-TestProfile $h 'anthropic' '{"name":"anthropic","auth":{"type":"none"}}'
        $helpers = Join-Path $h '.claude\provider-profiles\.helpers'
        $null = New-Item -ItemType Directory -Path $helpers -Force
        Set-Content -LiteralPath (Join-Path $helpers 'ghost.cmd') -Value '@echo off' -Encoding Ascii

        $null = Invoke-ProviderScript 'doctor.ps1' @('-Fix')
        Test-Path (Join-Path $helpers 'ghost.cmd') | Should Be $false
    }

    It 'flags a permissions entry embedding a secret without echoing it' {
        $h = New-TestHome $TestDrive 'dr-secretperm'
        $null = Write-TestProfile $h 'anthropic' '{"name":"anthropic","auth":{"type":"none"}}'
        (Invoke-ProviderScript 'apply-profile.ps1' @('anthropic')).Exit | Should Be 9

        $sPath = Join-Path $h '.claude\settings.local.json'
        $s = [System.IO.File]::ReadAllText($sPath) | ConvertFrom-Json
        $leaked = 'Bash(powershell.exe -File set-credential.ps1 -Target "t" -Secret "sk-leaked-token-value")'
        $s | Add-Member -NotePropertyName permissions -NotePropertyValue ([PSCustomObject]@{
            allow = @($leaked, 'Bash(echo ok)')
        })
        [System.IO.File]::WriteAllText($sPath, ($s | ConvertTo-Json -Depth 10))

        $r = Invoke-ProviderScript 'doctor.ps1'
        $r.Exit | Should Be 1
        $r.Output | Should Match 'embedding a secret'
        $r.Output | Should Not Match 'sk-leaked-token-value'
    }

    It 'removes only the secret-embedding permission entries with -Fix' {
        $h = New-TestHome $TestDrive 'dr-secretfix'
        $null = Write-TestProfile $h 'anthropic' '{"name":"anthropic","auth":{"type":"none"}}'
        (Invoke-ProviderScript 'apply-profile.ps1' @('anthropic')).Exit | Should Be 9

        $sPath = Join-Path $h '.claude\settings.local.json'
        $s = [System.IO.File]::ReadAllText($sPath) | ConvertFrom-Json
        $s | Add-Member -NotePropertyName permissions -NotePropertyValue ([PSCustomObject]@{
            allow = @(
                'Bash(powershell.exe -File set-credential.ps1 -Target "t" -Secret "sk-leaked-token-value")',
                'Bash(echo ok)'
            )
        })
        [System.IO.File]::WriteAllText($sPath, ($s | ConvertTo-Json -Depth 10))

        $r = Invoke-ProviderScript 'doctor.ps1' @('-Fix')
        $r.Output | Should Match 'FIXED: removed'
        $r.Output | Should Not Match 'sk-leaked-token-value'

        $after = [System.IO.File]::ReadAllText($sPath)
        $after | Should Not Match 'sk-leaked-token-value'
        $after | Should Match 'Bash\(echo ok\)'
        # managed keys survive the rewrite
        ($after | ConvertFrom-Json).env.CLAUDE_PROVIDER_ACTIVE | Should Be 'anthropic'

        (Invoke-ProviderScript 'doctor.ps1').Exit | Should Be 0
    }

    It 'clears a stale lock with -Fix' {
        $h = New-TestHome $TestDrive 'dr-lock'
        $lockDir = Join-Path $h '.claude\provider-profiles\.state.lock'
        $null = New-Item -ItemType Directory -Path $lockDir -Force
        Set-Content -LiteralPath (Join-Path $lockDir 'pid') -Value '999999' -Encoding Ascii

        $null = Invoke-ProviderScript 'doctor.ps1' @('-Fix')
        Test-Path $lockDir | Should Be $false
    }
}

Remove-Item Env:CLAUDE_PROVIDER_HOME -ErrorAction SilentlyContinue
