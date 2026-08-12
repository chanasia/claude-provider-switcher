# install-cli.ps1
#
# Installs the offline `provider` CLI: copies provider-cli.ps1 to
# ~\.claude\bin\provider.ps1, writes a provider.cmd wrapper next to it,
# and adds that directory to the USER Path if it is not already there.
#
# Install this while your provider still works - it is the escape hatch
# for when a switch lands on a broken provider and slash commands (which
# need a working model) cannot run:
#
#   provider switch anthropic
#
# Exit codes: 0 ok | 1 runtime

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'lib.ps1')

try {
    $binDir = Join-Path $env:USERPROFILE '.claude\bin'
    $null = New-Item -ItemType Directory -Path $binDir -Force

    # The dispatcher, installed under its runtime name.
    $source = Join-Path $PSScriptRoot 'provider-cli.ps1'
    if (-not (Test-Path -LiteralPath $source)) {
        throw "provider-cli.ps1 not found next to this script: $source"
    }
    Write-AtomicFile -Path (Join-Path $binDir 'provider.ps1') `
        -Content ([System.IO.File]::ReadAllText((Resolve-Path -LiteralPath $source).ProviderPath))

    # cmd wrapper so `provider` works from cmd, PowerShell, and Run boxes.
    $cmdBody = "@echo off`r`n" +
        "rem claude-provider-switcher offline CLI - see install-cli.ps1`r`n" +
        "powershell.exe -NoProfile -ExecutionPolicy Bypass -File `"%~dp0provider.ps1`" %*`r`n" +
        "exit /b %ERRORLEVEL%`r`n"
    Write-AtomicFile -Path (Join-Path $binDir 'provider.cmd') -Content $cmdBody

    # USER Path (never machine scope).
    $userPath = [Environment]::GetEnvironmentVariable('Path', 'User')
    if ($null -eq $userPath) { $userPath = '' }
    $onPath = $false
    foreach ($entry in $userPath.Split(';')) {
        if ($entry.TrimEnd('\') -ieq $binDir.TrimEnd('\')) { $onPath = $true; break }
    }
    if (-not $onPath) {
        $newPath = $userPath.TrimEnd(';')
        if ($newPath -ne '') { $newPath = $newPath + ';' }
        [Environment]::SetEnvironmentVariable('Path', $newPath + $binDir, 'User')
        Write-Output "added to user Path: $binDir"
        Write-Output '  (open a NEW terminal for the Path change to take effect)'
    } else {
        Write-Output "already on user Path: $binDir"
    }

    Write-Output "installed: $binDir\provider.cmd"
    Write-Output ''
    Write-Output 'The `provider` command now works in any terminal, with no model or'
    Write-Output 'network needed. If a switch ever strands you on a broken provider:'
    Write-Output '  provider switch anthropic'
    Write-Output '  (then restart Claude Code)'
    exit $EXIT_OK
} catch {
    [Console]::Error.WriteLine("provider: $($_.Exception.Message)")
    exit $EXIT_RUNTIME
}
