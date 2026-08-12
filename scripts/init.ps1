# init.ps1
#
# First-time setup: creates ~/.claude/provider-profiles/, seeds the two
# example profiles, and creates an empty sidecar. Idempotent - existing
# profiles are never overwritten.
#
# Exit codes: 0 ok | 1 runtime

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'lib.ps1')

try {
    $dir = Get-ProfileDir
    $created = $false
    if (-not (Test-Path -LiteralPath $dir)) {
        $null = New-Item -ItemType Directory -Path $dir -Force
        $created = $true
    }
    $null = New-Item -ItemType Directory -Path (Get-HelpersDir) -Force

    $templatesDir = Join-Path (Split-Path -Parent $PSScriptRoot) 'templates'
    $seeds = @(
        @{ Template = 'profile-anthropic.json'; Name = 'anthropic' },
        @{ Template = 'profile-gateway-example.json'; Name = 'gateway-example' }
    )

    $seeded = New-Object System.Collections.Generic.List[string]
    $skipped = New-Object System.Collections.Generic.List[string]
    foreach ($seed in $seeds) {
        $dest = Get-ProfilePath -Name $seed.Name
        if (Test-Path -LiteralPath $dest) {
            $skipped.Add($seed.Name)
            continue
        }
        $src = Join-Path $templatesDir $seed.Template
        if (-not (Test-Path -LiteralPath $src)) {
            throw "seed template missing: $src"
        }
        Write-AtomicFile -Path $dest -Content ([System.IO.File]::ReadAllText((Resolve-Path -LiteralPath $src).ProviderPath))
        $seeded.Add($seed.Name)
    }

    # Empty sidecar so /current and /doctor have something well-formed to read.
    $sidecar = Get-SidecarPath
    if (-not (Test-Path -LiteralPath $sidecar)) {
        Write-AtomicFile -Path $sidecar -Content "{}`n"
    }

    if ($created) {
        Write-Output "created: $dir"
    } else {
        Write-Output "profile directory already exists: $dir"
    }
    if ($seeded.Count -gt 0) { Write-Output "seeded profiles: $($seeded -join ', ')" }
    if ($skipped.Count -gt 0) { Write-Output "left untouched (already present): $($skipped -join ', ')" }
    Write-Output ''
    Write-Output 'Next steps:'
    Write-Output '  /provider:list                    see what you have'
    Write-Output '  /provider:add                     create a gateway profile (stores the token in Credential Manager)'
    Write-Output '  /provider:switch anthropic        activate Anthropic direct'
    exit $EXIT_OK
} catch {
    [Console]::Error.WriteLine("provider: $($_.Exception.Message)")
    exit $EXIT_RUNTIME
}
