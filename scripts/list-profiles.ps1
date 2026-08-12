# list-profiles.ps1 [-Json]
#
# Lists every profile with its endpoint, auth reference, model, and which
# one is active. Output holds references only - profiles never contain
# secrets, so there is nothing to redact.
#
# Exit codes: 0 ok | 1 runtime | 3 profile dir missing

param(
    [switch]$Json
)

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'lib.ps1')

function Get-Prop {
    param($Obj, [string]$PropName)
    if ($null -eq $Obj) { return $null }
    $p = $Obj.PSObject.Properties[$PropName]
    if ($null -eq $p) { return $null }
    return $p.Value
}

$dir = Get-ProfileDir
if (-not (Test-Path -LiteralPath $dir)) {
    [Console]::Error.WriteLine("provider: profile directory not found: $dir")
    [Console]::Error.WriteLine('  run /provider:init for first-time setup')
    exit $EXIT_NOT_FOUND
}

try {
    $scope = Read-SidecarScope -ScopeKey 'global'
} catch {
    [Console]::Error.WriteLine("provider: $($_.Exception.Message)")
    exit $EXIT_RUNTIME
}
$active = ''
if ($null -ne $scope) { $active = [string](Get-Prop $scope 'active_profile') }

$rows = New-Object System.Collections.Generic.List[object]
foreach ($file in @(Get-ProfileFiles)) {
    $row = [PSCustomObject]@{
        name        = $file.BaseName
        active      = ($file.BaseName -ceq $active)
        description = ''
        base_url    = ''
        auth_type   = ''
        auth_ref    = ''
        model       = ''
        valid       = $true
    }
    try {
        $doc = Read-JsonFile -Path $file.FullName
        $auth = Get-Prop $doc 'auth'
        $row.description = [string](Get-Prop $doc 'description')
        $row.base_url = [string](Get-Prop $doc 'base_url')
        $row.model = [string](Get-Prop $doc 'model')
        $row.auth_type = [string](Get-Prop $auth 'type')
        if ($row.auth_type -eq 'credman') { $row.auth_ref = [string](Get-Prop $auth 'target') }
        if ($row.auth_type -eq 'env_var') { $row.auth_ref = [string](Get-Prop $auth 'var') }
    } catch {
        $row.valid = $false
    }
    $rows.Add($row)
}

if ($Json) {
    $activeOut = $null
    if ($active -ne '') { $activeOut = $active }
    $out = [PSCustomObject]@{
        active_profile = $activeOut
        profiles       = $rows.ToArray()
    }
    Write-Output ($out | ConvertTo-Json -Depth 5)
    exit $EXIT_OK
}

if ($rows.Count -eq 0) {
    Write-Output "no profiles found in $dir"
    Write-Output '  run /provider:init to seed examples, or /provider:add to create one'
    exit $EXIT_OK
}

foreach ($row in $rows) {
    $marker = '  '
    if ($row.active) { $marker = '* ' }
    if (-not $row.valid) {
        Write-Output "$marker$($row.name)   [INVALID JSON - run /provider:doctor]"
        continue
    }
    $endpoint = $row.base_url
    if ($endpoint -eq '') { $endpoint = '(Anthropic direct)' }
    Write-Output "$marker$($row.name)"
    if ($row.description -ne '') { Write-Output "      $($row.description)" }
    Write-Output "      endpoint: $endpoint"
    if ($row.auth_ref -ne '') {
        Write-Output "      auth:     $($row.auth_type) -> $($row.auth_ref)"
    } else {
        Write-Output "      auth:     $($row.auth_type)"
    }
    if ($row.model -ne '') { Write-Output "      model:    $($row.model)" }
}
Write-Output ''
if ($active -eq '') {
    Write-Output 'no profile is active (* marks the active one once you switch)'
} else {
    Write-Output "* = active on disk. Run /provider:current to check whether this session has it loaded."
}
exit $EXIT_OK
