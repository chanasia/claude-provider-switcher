# render-helper.ps1 <path-to-profile.json>
#
# Renders the per-profile apiKeyHelper shim pair into
# ~/.claude/provider-profiles/.helpers/ (design.md section 6):
#   <name>.ps1 - self-contained secret reader (credman / env_var)
#   <name>.cmd - wrapper whose Windows path goes into settings.local.json
#
# auth:none needs no shim - any stale shim pair for the profile is removed.
# Substituted values are re-validated against the schema regexes at render
# time (defense in depth), and the rendered .ps1 is re-parsed after write.
#
# On success prints the absolute .cmd path (empty for auth:none).
#
# Exit codes: 0 ok | 1 runtime | 2 usage | 3 not found | 6 schema

param(
    [string]$Path = ''
)

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'lib.ps1')

if ($Path -eq '') {
    [Console]::Error.WriteLine('usage: render-helper.ps1 <path-to-profile.json>')
    exit $EXIT_USAGE
}
if (-not (Test-Path -LiteralPath $Path)) {
    [Console]::Error.WriteLine("provider: profile file not found: $Path")
    exit $EXIT_NOT_FOUND
}

$doc = $null
try {
    $doc = Read-JsonFile -Path $Path
} catch {
    [Console]::Error.WriteLine("provider: $($_.Exception.Message)")
    exit $EXIT_SCHEMA
}

function Get-Prop {
    param($Obj, [string]$Name)
    $p = $Obj.PSObject.Properties[$Name]
    if ($null -eq $p) { return $null }
    return $p.Value
}

$name = Get-Prop $doc 'name'
$auth = Get-Prop $doc 'auth'
if ($null -eq $name -or $null -eq $auth) {
    [Console]::Error.WriteLine('provider: profile is missing name or auth')
    exit $EXIT_SCHEMA
}
if ($name -cnotmatch '^[a-z0-9][a-z0-9-]{0,62}$') {
    [Console]::Error.WriteLine("provider: schema: name '$name' fails pattern check at render time")
    exit $EXIT_SCHEMA
}
$authType = Get-Prop $auth 'type'

$helpersDir = Get-HelpersDir
$ps1Path = Join-Path $helpersDir ($name + '.ps1')
$cmdPath = Join-Path $helpersDir ($name + '.cmd')

# ---- auth:none - nothing to render; clean up any stale shim pair ----
if ($authType -eq 'none') {
    foreach ($f in @($ps1Path, $cmdPath)) {
        if (Test-Path -LiteralPath $f) { Remove-Item -LiteralPath $f -Force }
    }
    Write-Output ''
    exit $EXIT_OK
}

if ($authType -ne 'credman' -and $authType -ne 'env_var') {
    [Console]::Error.WriteLine("provider: schema: unknown auth.type '$authType'")
    exit $EXIT_SCHEMA
}

# ---- resolve template + validated substitution value ----
$templatesDir = Join-Path (Split-Path -Parent $PSScriptRoot) 'templates'

if ($authType -eq 'credman') {
    $template = Join-Path $templatesDir 'helper-credman.ps1.tmpl'
    $value = Get-Prop $auth 'target'
    # Defense in depth: the pattern rejects quotes and shell metacharacters,
    # so the value cannot escape the single-quoted context in the template.
    if ($null -eq $value -or $value -cnotmatch '^[A-Za-z0-9_./-]{1,255}$') {
        [Console]::Error.WriteLine("provider: schema: auth.target fails pattern check at render time")
        exit $EXIT_SCHEMA
    }
    $placeholder = '{{TARGET}}'
} else {
    $template = Join-Path $templatesDir 'helper-env-var.ps1.tmpl'
    $value = Get-Prop $auth 'var'
    if ($null -eq $value -or $value -cnotmatch '^[A-Z_][A-Z0-9_]*$') {
        [Console]::Error.WriteLine("provider: schema: auth.var fails pattern check at render time")
        exit $EXIT_SCHEMA
    }
    $placeholder = '{{VAR}}'
}

if (-not (Test-Path -LiteralPath $template)) {
    [Console]::Error.WriteLine("provider: template missing: $template")
    exit $EXIT_RUNTIME
}

# ---- render ----
$null = New-Item -ItemType Directory -Path $helpersDir -Force

$ps1Body = [System.IO.File]::ReadAllText((Resolve-Path -LiteralPath $template).ProviderPath)
$ps1Body = $ps1Body.Replace('{{NAME}}', $name).Replace($placeholder, $value)

$cmdTemplate = Join-Path $templatesDir 'helper-wrapper.cmd.tmpl'
if (-not (Test-Path -LiteralPath $cmdTemplate)) {
    [Console]::Error.WriteLine("provider: template missing: $cmdTemplate")
    exit $EXIT_RUNTIME
}
$cmdBody = [System.IO.File]::ReadAllText((Resolve-Path -LiteralPath $cmdTemplate).ProviderPath)
$cmdBody = $cmdBody.Replace('{{NAME}}', $name).Replace('{{PS1_PATH}}', $ps1Path)
# cmd.exe misparses LF-only batch files - force CRLF regardless of how the
# template was checked out.
$cmdBody = $cmdBody.Replace("`r`n", "`n").Replace("`n", "`r`n")

try {
    Write-AtomicFile -Path $ps1Path -Content $ps1Body
    Write-AtomicFile -Path $cmdPath -Content $cmdBody
} catch {
    [Console]::Error.WriteLine("provider: failed to write shim: $($_.Exception.Message)")
    exit $EXIT_RUNTIME
}

# ---- post-write validation ----
# 1. The rendered .ps1 must still parse - no construct survived substitution.
$parseErrors = $null
$null = [System.Management.Automation.PSParser]::Tokenize([System.IO.File]::ReadAllText($ps1Path), [ref]$parseErrors)
if ($parseErrors -and $parseErrors.Count -gt 0) {
    Remove-Item -LiteralPath $ps1Path, $cmdPath -Force -ErrorAction SilentlyContinue
    [Console]::Error.WriteLine("provider: rendered shim failed post-write parse: $ps1Path")
    exit $EXIT_RUNTIME
}
# 2. No un-substituted placeholders may remain in either file.
foreach ($f in @($ps1Path, $cmdPath)) {
    if ((Select-String -LiteralPath $f -Pattern '\{\{[A-Z_]+\}\}' -Quiet)) {
        Remove-Item -LiteralPath $ps1Path, $cmdPath -Force -ErrorAction SilentlyContinue
        [Console]::Error.WriteLine("provider: rendered shim contains un-substituted placeholders: $f")
        exit $EXIT_RUNTIME
    }
}

Write-Output $cmdPath
exit $EXIT_OK
