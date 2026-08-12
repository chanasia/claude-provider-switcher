# validate-profile.ps1 <path-to-profile.json>
#
# Enforces every rule in docs/design.md section 3 (mirrored by lib/profile-schema.json).
# Prints all violations to stderr, not just the first.
#
# Exit codes: 0 valid | 2 usage | 3 file not found | 6 schema violation

param(
    [string]$Path = ''
)

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'lib.ps1')

if ($Path -eq '') {
    [Console]::Error.WriteLine('usage: validate-profile.ps1 <path-to-profile.json>')
    exit $EXIT_USAGE
}
if (-not (Test-Path -LiteralPath $Path)) {
    [Console]::Error.WriteLine("provider: profile file not found: $Path")
    exit $EXIT_NOT_FOUND
}

$problems = New-Object System.Collections.Generic.List[string]

# ---- parse ----
$doc = $null
try {
    $doc = Read-JsonFile -Path $Path
} catch {
    [Console]::Error.WriteLine("provider: $($_.Exception.Message)")
    exit $EXIT_SCHEMA
}
if ($doc -isnot [PSCustomObject]) {
    [Console]::Error.WriteLine('provider: profile must be a JSON object')
    exit $EXIT_SCHEMA
}

function Get-Prop {
    param($Obj, [string]$Name)
    $p = $Obj.PSObject.Properties[$Name]
    if ($null -eq $p) { return $null }
    return $p.Value
}

# ---- rule: no unknown top-level keys ----
$allowedTop = @('name', 'description', 'base_url', 'auth', 'model', 'ttl_ms', 'extras')
foreach ($p in $doc.PSObject.Properties) {
    if ($allowedTop -notcontains $p.Name) {
        $problems.Add("unknown top-level key: '$($p.Name)'")
    }
}

# ---- rule: name ----
$name = Get-Prop $doc 'name'
if ($null -eq $name -or $name -isnot [string] -or $name -eq '') {
    $problems.Add("'name' is required and must be a string")
} else {
    if ($name -cnotmatch '^[a-z0-9][a-z0-9-]{0,62}$') {
        $problems.Add("'name' must match ^[a-z0-9][a-z0-9-]{0,62}$ (got '$name')")
    }
    $basename = [System.IO.Path]::GetFileNameWithoutExtension($Path)
    if ($name -cne $basename) {
        $problems.Add("'name' ('$name') must equal the filename basename ('$basename')")
    }
}

# ---- rule: description ----
$description = Get-Prop $doc 'description'
if ($null -ne $description) {
    if ($description -isnot [string]) {
        $problems.Add("'description' must be a string")
    } elseif ($description.Length -gt 200) {
        $problems.Add("'description' must be at most 200 characters (got $($description.Length))")
    }
}

# ---- rule: base_url ----
$baseUrl = Get-Prop $doc 'base_url'
if ($null -ne $baseUrl) {
    if ($baseUrl -isnot [string]) {
        $problems.Add("'base_url' must be a string or null")
    } else {
        $uri = $null
        if (-not [System.Uri]::TryCreate($baseUrl, [System.UriKind]::Absolute, [ref]$uri)) {
            $problems.Add("'base_url' is not a valid absolute URI: $baseUrl")
        } else {
            $isLocal = ($uri.Host -eq 'localhost' -or $uri.Host -eq '127.0.0.1')
            if ($uri.Scheme -ne 'https' -and -not ($uri.Scheme -eq 'http' -and $isLocal)) {
                $problems.Add("'base_url' must use https:// (http:// allowed only for localhost/127.0.0.1)")
            }
        }
    }
}

# ---- rule: auth ----
$auth = Get-Prop $doc 'auth'
if ($null -eq $auth -or $auth -isnot [PSCustomObject]) {
    $problems.Add("'auth' is required and must be an object")
} else {
    $authType = Get-Prop $auth 'type'
    $authKeys = @($auth.PSObject.Properties | ForEach-Object { $_.Name })
    switch ($authType) {
        'none' {
            $allowed = @('type')
        }
        'credman' {
            $allowed = @('type', 'target')
            $target = Get-Prop $auth 'target'
            if ($null -eq $target -or $target -isnot [string] -or $target -cnotmatch '^[A-Za-z0-9_./-]{1,255}$') {
                $problems.Add("auth.type 'credman' requires 'target' matching ^[A-Za-z0-9_./-]{1,255}$")
            }
        }
        'env_var' {
            $allowed = @('type', 'var')
            $var = Get-Prop $auth 'var'
            if ($null -eq $var -or $var -isnot [string] -or $var -cnotmatch '^[A-Z_][A-Z0-9_]*$') {
                $problems.Add("auth.type 'env_var' requires 'var' matching ^[A-Z_][A-Z0-9_]*$")
            }
        }
        default {
            $allowed = $null
            $problems.Add("auth.type must be one of: none, credman, env_var (got '$authType')")
        }
    }
    if ($null -ne $allowed) {
        foreach ($k in $authKeys) {
            if ($allowed -notcontains $k) {
                $problems.Add("unknown key in auth for type '$authType': '$k'")
            }
        }
    }
}

# ---- rule: model ----
$model = Get-Prop $doc 'model'
if ($null -ne $model) {
    if ($model -isnot [string] -or $model -cnotmatch '^[A-Za-z0-9_.:/-]{1,128}$') {
        $problems.Add("'model' must match ^[A-Za-z0-9_.:/-]{1,128}$")
    }
}

# ---- rule: ttl_ms ----
$ttl = Get-Prop $doc 'ttl_ms'
if ($null -ne $ttl) {
    $isIntegral = ($ttl -is [int] -or $ttl -is [long] -or ($ttl -is [double] -and $ttl -eq [math]::Floor($ttl)))
    if (-not $isIntegral) {
        $problems.Add("'ttl_ms' must be an integer")
    } elseif ($ttl -lt 1000 -or $ttl -gt 86400000) {
        $problems.Add("'ttl_ms' must be between 1000 and 86400000 (got $ttl)")
    }
}

# ---- rule: extras ----
$extras = Get-Prop $doc 'extras'
if ($null -ne $extras) {
    if ($extras -isnot [PSCustomObject]) {
        $problems.Add("'extras' must be an object")
    } else {
        foreach ($p in $extras.PSObject.Properties) {
            if ($p.Name -cnotmatch '^[A-Z_][A-Z0-9_]*$') {
                $problems.Add("extras key '$($p.Name)' must match ^[A-Z_][A-Z0-9_]*$")
            }
            if ($p.Value -isnot [string]) {
                $problems.Add("extras value for '$($p.Name)' must be a string")
            }
            if (Test-DenylistedKey -Key $p.Name) {
                $problems.Add("extras key '$($p.Name)' is denylisted (can alter process semantics or is plugin-managed)")
            }
        }
    }
}

# ---- report ----
if ($problems.Count -gt 0) {
    foreach ($msg in $problems) {
        [Console]::Error.WriteLine("provider: schema: $msg")
    }
    exit $EXIT_SCHEMA
}

Write-Output "OK: $name"
exit $EXIT_OK
