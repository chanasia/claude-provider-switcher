# Shared helpers for integration tests that exercise scripts end-to-end
# in child powershell.exe processes (the scripts use `exit`).

$script:ScriptsDir = (Resolve-Path (Join-Path (Split-Path -Parent $MyInvocation.MyCommand.Path) '..\scripts')).Path

function Invoke-ProviderScript {
    param(
        [string]$Script,
        [string[]]$Arguments = @()
    )
    # Under ErrorActionPreference=Stop (e.g. the GitHub Actions shell
    # wrapper), 2>&1-redirected child stderr becomes a terminating error.
    # Expected stderr is part of what these tests assert on, so relax it
    # for the duration of the call.
    $prev = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    try {
        $out = & powershell.exe -NoProfile -ExecutionPolicy Bypass `
            -File (Join-Path $script:ScriptsDir $Script) @Arguments 2>&1
        $code = $LASTEXITCODE
    } finally {
        $ErrorActionPreference = $prev
    }
    return New-Object PSObject -Property @{
        Exit   = $code
        Output = (($out | ForEach-Object { "$_" }) -join "`n")
    }
}

function New-TestHome {
    # Creates an isolated fake $HOME with a seeded profile dir and points
    # CLAUDE_PROVIDER_HOME (inherited by child processes) at it.
    param([string]$Root, [string]$CaseName)
    $testHome = Join-Path $Root $CaseName
    $null = New-Item -ItemType Directory -Path (Join-Path $testHome '.claude\provider-profiles') -Force
    $env:CLAUDE_PROVIDER_HOME = $testHome
    return $testHome
}

function Write-TestProfile {
    param([string]$TestHome, [string]$Name, [string]$Json)
    $path = Join-Path $TestHome ".claude\provider-profiles\$Name.json"
    [System.IO.File]::WriteAllText($path, $Json)
    return $path
}

function Read-TestSettings {
    param([string]$TestHome)
    $path = Join-Path $TestHome '.claude\settings.local.json'
    if (-not (Test-Path -LiteralPath $path)) { return $null }
    return ([System.IO.File]::ReadAllText($path) | ConvertFrom-Json)
}
