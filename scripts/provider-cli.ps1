# provider-cli.ps1 <command> [args...]
#
# Offline command-line entry point. Slash commands need a working model to
# interpret them; this dispatcher needs nothing but PowerShell, so it works
# with a broken provider or no network at all. install-cli.ps1 copies it to
# ~\.claude\bin\provider.ps1 with a provider.cmd wrapper on PATH.
#
# Commands map 1:1 onto the standalone scripts; all remaining arguments are
# passed through untouched:
#   provider init
#   provider list [-Json]
#   provider current [-Json]
#   provider switch <name> [-AcceptDrift overwrite|incorporate]
#   provider create -Name <n> -AuthType <t> [...]
#   provider remove <name> [-DeleteCredential]
#   provider doctor [-Fix] [-Json]
#   provider set-credential -Target <t> [-Secret <s>]
#   provider validate <path>
#
# Script resolution order:
#   1. CLAUDE_PROVIDER_SCRIPTS env var (local clones, tests)
#   2. newest version under ~\.claude\plugins\cache (marketplace installs)
#
# Exit codes: the invoked script's own code | 1 scripts not found | 2 usage

$ErrorActionPreference = 'Stop'

$commandMap = @{
    'init'           = 'init.ps1'
    'list'           = 'list-profiles.ps1'
    'current'        = 'get-active.ps1'
    'switch'         = 'apply-profile.ps1'
    'create'         = 'create-profile.ps1'
    'remove'         = 'remove-profile.ps1'
    'doctor'         = 'doctor.ps1'
    'set-credential' = 'set-credential.ps1'
    'validate'       = 'validate-profile.ps1'
}

$cmd = ''
if ($args.Count -gt 0) { $cmd = [string]$args[0] }
$rest = @()
if ($args.Count -gt 1) { $rest = @($args[1..($args.Count - 1)] | ForEach-Object { [string]$_ }) }

if ($cmd -eq '' -or -not $commandMap.ContainsKey($cmd)) {
    [Console]::Error.WriteLine('usage: provider <command> [args...]')
    [Console]::Error.WriteLine('')
    [Console]::Error.WriteLine('  init                          first-time setup, seed example profiles')
    [Console]::Error.WriteLine('  list [-Json]                  list profiles, mark the active one')
    [Console]::Error.WriteLine('  current [-Json]               effective profile for this machine')
    [Console]::Error.WriteLine('  switch <name>                 activate a profile (then restart Claude Code)')
    [Console]::Error.WriteLine('  create -Name <n> -AuthType <t> [...]   non-interactive profile creation')
    [Console]::Error.WriteLine('  remove <name> [-DeleteCredential]')
    [Console]::Error.WriteLine('  doctor [-Fix] [-Json]         diagnose / repair')
    [Console]::Error.WriteLine('  set-credential -Target <t>    store a token (reads stdin if no -Secret)')
    [Console]::Error.WriteLine('  validate <path>               validate a profile file')
    [Console]::Error.WriteLine('')
    [Console]::Error.WriteLine('Works offline - no model or network needed. Escape hatch:')
    [Console]::Error.WriteLine('  provider switch anthropic')
    exit 2
}

# ---- locate the plugin scripts ----
$scriptsDir = $null
if ($env:CLAUDE_PROVIDER_SCRIPTS -and (Test-Path (Join-Path $env:CLAUDE_PROVIDER_SCRIPTS 'apply-profile.ps1'))) {
    $scriptsDir = $env:CLAUDE_PROVIDER_SCRIPTS
} else {
    $cache = Join-Path $env:USERPROFILE '.claude\plugins\cache'
    if (Test-Path -LiteralPath $cache) {
        $best = $null
        $bestVer = $null
        foreach ($hit in (Get-ChildItem -LiteralPath $cache -Recurse -Filter 'apply-profile.ps1' -ErrorAction SilentlyContinue)) {
            $dir = Split-Path $hit.FullName -Parent
            # .../<plugin>/<version>/scripts/apply-profile.ps1 -> version folder
            $verName = Split-Path (Split-Path $dir -Parent) -Leaf
            $ver = $null
            if (-not [Version]::TryParse($verName, [ref]$ver)) { $ver = [Version]'0.0.0' }
            if ($null -eq $bestVer -or $ver -gt $bestVer) { $bestVer = $ver; $best = $dir }
        }
        $scriptsDir = $best
    }
}

if ($null -eq $scriptsDir) {
    [Console]::Error.WriteLine('provider: could not find the plugin scripts.')
    [Console]::Error.WriteLine('  Looked in CLAUDE_PROVIDER_SCRIPTS and ~\.claude\plugins\cache.')
    [Console]::Error.WriteLine('  For a local clone, set CLAUDE_PROVIDER_SCRIPTS to its scripts\ folder.')
    exit 1
}

# Child powershell -File parses '-Fix' / '-Json' style args into real
# parameters; in-process array splatting would bind them positionally.
& powershell.exe -NoProfile -ExecutionPolicy Bypass `
    -File (Join-Path $scriptsDir $commandMap[$cmd]) @rest
exit $LASTEXITCODE
