# provider-cli.ps1 <command> [args...]
#
# The offline emergency CLI, installed as `claude-provider` by
# install-cli.ps1. Slash commands need a working model to interpret them;
# this needs nothing but PowerShell - no model, no network.
#
# Deliberately minimal - exactly two commands (day-to-day management
# belongs to the /provider:* slash commands):
#
#   claude-provider anthropic      switch this machine back to Anthropic
#                                  direct, self-healing: seeds the profile
#                                  if missing, repairs a broken sidecar,
#                                  overwrites drift (emergency semantics)
#   claude-provider reset [-Force] remove ALL plugin state (managed
#                                  settings keys, profiles, credentials,
#                                  this CLI) - the plugin itself stays
#                                  installed in Claude Code
#
# Script resolution order:
#   1. CLAUDE_PROVIDER_SCRIPTS env var (local clones, tests)
#   2. newest version under ~\.claude\plugins\cache (marketplace installs)
#
# Exit codes: the invoked script's own code | 1 scripts not found | 2 usage

$ErrorActionPreference = 'Stop'

$cmd = ''
if ($args.Count -gt 0) { $cmd = [string]$args[0] }
$rest = @()
if ($args.Count -gt 1) { $rest = @($args[1..($args.Count - 1)] | ForEach-Object { [string]$_ }) }

if ($cmd -cne 'anthropic' -and $cmd -cne 'reset') {
    [Console]::Error.WriteLine('usage: claude-provider <command>')
    [Console]::Error.WriteLine('')
    [Console]::Error.WriteLine('  anthropic        switch this machine back to Anthropic direct')
    [Console]::Error.WriteLine('                   (then restart Claude Code)')
    [Console]::Error.WriteLine('  reset [-Force]   remove all plugin state: managed settings keys,')
    [Console]::Error.WriteLine('                   profiles, stored credentials, and this CLI.')
    [Console]::Error.WriteLine('                   The plugin stays installed in Claude Code.')
    [Console]::Error.WriteLine('')
    [Console]::Error.WriteLine('Emergency tool - works with no model and no network.')
    [Console]::Error.WriteLine('Everything else is a /provider:* slash command inside Claude Code.')
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

function Invoke-Step {
    # Child powershell -File parses switch-style args into real parameters;
    # in-process array splatting would bind them positionally. The child's
    # stdout flows straight through (never capture this function's output -
    # the exit code travels via $script:StepCode instead).
    param([string]$ScriptName, [string[]]$StepArgs = @())
    & powershell.exe -NoProfile -ExecutionPolicy Bypass `
        -File (Join-Path $scriptsDir $ScriptName) @StepArgs
    $script:StepCode = $LASTEXITCODE
}

if ($cmd -ceq 'reset') {
    Invoke-Step 'reset.ps1' $rest
    exit $script:StepCode
}

# ---- claude-provider anthropic: self-healing switch-back ----
# Seed the anthropic profile if this machine never ran /provider:init
# (suppress the first-time-setup chatter; only the switch outcome matters).
Invoke-Step 'init.ps1' | Out-Null

Invoke-Step 'apply-profile.ps1' @('anthropic')

if ($script:StepCode -eq 1) {
    # Most likely a corrupt sidecar or stale lock - repair and retry once.
    [Console]::Error.WriteLine('provider: first attempt failed - running doctor -Fix and retrying...')
    Invoke-Step 'doctor.ps1' @('-Fix')
    Invoke-Step 'apply-profile.ps1' @('anthropic')
}

if ($script:StepCode -eq 8) {
    # Emergency semantics: hand-edits lose; getting back to a working
    # session wins. Say so instead of asking.
    [Console]::Error.WriteLine('provider: managed keys were hand-edited since the last switch - overwriting them (emergency mode).')
    Invoke-Step 'apply-profile.ps1' @('anthropic', '-AcceptDrift', 'overwrite')
}

exit $script:StepCode
