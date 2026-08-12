# Pester 3.4-compatible tests for scripts/validate-profile.ps1
#
# The script under test uses `exit`, so every invocation runs in a child
# powershell.exe process and asserts on $LASTEXITCODE.

$here = Split-Path -Parent $MyInvocation.MyCommand.Path
$validateScript = (Resolve-Path (Join-Path $here '..\scripts\validate-profile.ps1')).Path

function New-ProfileFile {
    param([string]$Dir, [string]$Name, [string]$Json)
    $path = Join-Path $Dir ($Name + '.json')
    [System.IO.File]::WriteAllText($path, $Json)
    return $path
}

function Invoke-Validate {
    param([string[]]$Arguments = @())
    # See Integration.Helpers.ps1: expected child stderr must not terminate
    # the test under ErrorActionPreference=Stop hosts (GitHub Actions).
    $prev = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    try {
        $out = & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $validateScript @Arguments 2>&1
        $code = $LASTEXITCODE
    } finally {
        $ErrorActionPreference = $prev
    }
    return New-Object PSObject -Property @{
        Exit   = $code
        Output = (($out | ForEach-Object { "$_" }) -join "`n")
    }
}

Describe 'validate-profile.ps1' {

    It 'exits 2 with no arguments' {
        (Invoke-Validate).Exit | Should Be 2
    }

    It 'exits 3 for a missing file' {
        (Invoke-Validate @(Join-Path $TestDrive 'missing.json')).Exit | Should Be 3
    }

    It 'accepts a minimal auth:none profile' {
        $p = New-ProfileFile $TestDrive 'anthropic' '{"name":"anthropic","auth":{"type":"none"}}'
        $r = Invoke-Validate @($p)
        $r.Output | Should Match 'OK: anthropic'
        $r.Exit | Should Be 0
    }

    It 'accepts a full credman profile' {
        $json = @'
{
  "name": "gw",
  "description": "example gateway",
  "base_url": "https://gateway.example.com/anthropic",
  "auth": { "type": "credman", "target": "claude-provider/gw" },
  "model": "some/model-name:tag",
  "ttl_ms": 300000,
  "extras": { "CLAUDE_CODE_MAX_OUTPUT_TOKENS": "64000" }
}
'@
        $p = New-ProfileFile $TestDrive 'gw' $json
        (Invoke-Validate @($p)).Exit | Should Be 0
    }

    It 'accepts an env_var profile with http://localhost base_url' {
        $json = '{"name":"local","base_url":"http://localhost:4000","auth":{"type":"env_var","var":"MY_LOCAL_KEY"}}'
        $p = New-ProfileFile $TestDrive 'local' $json
        (Invoke-Validate @($p)).Exit | Should Be 0
    }

    It 'rejects invalid JSON with exit 6' {
        $p = New-ProfileFile $TestDrive 'broken' '{not json!'
        (Invoke-Validate @($p)).Exit | Should Be 6
    }

    It 'rejects a name that does not match the filename' {
        $p = New-ProfileFile $TestDrive 'fileA' '{"name":"other","auth":{"type":"none"}}'
        $r = Invoke-Validate @($p)
        $r.Exit | Should Be 6
        $r.Output | Should Match 'filename basename'
    }

    It 'rejects an uppercase name' {
        $p = New-ProfileFile $TestDrive 'bad' '{"name":"Bad","auth":{"type":"none"}}'
        (Invoke-Validate @($p)).Exit | Should Be 6
    }

    It 'rejects http:// for non-localhost hosts' {
        $p = New-ProfileFile $TestDrive 'insecure' '{"name":"insecure","base_url":"http://gateway.example.com","auth":{"type":"none"}}'
        $r = Invoke-Validate @($p)
        $r.Exit | Should Be 6
        $r.Output | Should Match 'https'
    }

    It 'rejects unknown top-level keys' {
        $p = New-ProfileFile $TestDrive 'extra' '{"name":"extra","auth":{"type":"none"},"fallbackModel":["x"]}'
        $r = Invoke-Validate @($p)
        $r.Exit | Should Be 6
        $r.Output | Should Match 'fallbackModel'
    }

    It 'rejects credman auth without target' {
        $p = New-ProfileFile $TestDrive 'nocm' '{"name":"nocm","auth":{"type":"credman"}}'
        (Invoke-Validate @($p)).Exit | Should Be 6
    }

    It 'rejects a credman target with shell metacharacters' {
        $p = New-ProfileFile $TestDrive 'evil' '{"name":"evil","auth":{"type":"credman","target":"a;rm -rf"}}'
        (Invoke-Validate @($p)).Exit | Should Be 6
    }

    It 'rejects env_var auth with a lowercase var' {
        $p = New-ProfileFile $TestDrive 'lc' '{"name":"lc","auth":{"type":"env_var","var":"my_key"}}'
        (Invoke-Validate @($p)).Exit | Should Be 6
    }

    It 'rejects an unknown auth.type' {
        $p = New-ProfileFile $TestDrive 'keych' '{"name":"keych","auth":{"type":"keychain","service":"x"}}'
        (Invoke-Validate @($p)).Exit | Should Be 6
    }

    It 'rejects extra keys inside auth' {
        $p = New-ProfileFile $TestDrive 'authx' '{"name":"authx","auth":{"type":"none","target":"x"}}'
        (Invoke-Validate @($p)).Exit | Should Be 6
    }

    It 'rejects a denylisted extras key' {
        $p = New-ProfileFile $TestDrive 'deny' '{"name":"deny","auth":{"type":"none"},"extras":{"NODE_OPTIONS":"--inspect"}}'
        $r = Invoke-Validate @($p)
        $r.Exit | Should Be 6
        $r.Output | Should Match 'denylisted'
    }

    It 'rejects extras expressing plugin-managed keys' {
        $p = New-ProfileFile $TestDrive 'mng' '{"name":"mng","auth":{"type":"none"},"extras":{"ANTHROPIC_MODEL":"x"}}'
        (Invoke-Validate @($p)).Exit | Should Be 6
    }

    It 'rejects a lowercase extras key' {
        $p = New-ProfileFile $TestDrive 'lex' '{"name":"lex","auth":{"type":"none"},"extras":{"my_key":"v"}}'
        (Invoke-Validate @($p)).Exit | Should Be 6
    }

    It 'rejects ttl_ms below 1000' {
        $p = New-ProfileFile $TestDrive 'ttl' '{"name":"ttl","auth":{"type":"none"},"ttl_ms":10}'
        (Invoke-Validate @($p)).Exit | Should Be 6
    }

    It 'rejects a model with spaces' {
        $p = New-ProfileFile $TestDrive 'mdl' '{"name":"mdl","auth":{"type":"none"},"model":"bad model"}'
        (Invoke-Validate @($p)).Exit | Should Be 6
    }

    It 'reports multiple violations at once' {
        $p = New-ProfileFile $TestDrive 'multi' '{"name":"MULTI","auth":{"type":"nope"},"ttl_ms":1,"junk":true}'
        $r = Invoke-Validate @($p)
        $r.Exit | Should Be 6
        $r.Output | Should Match 'junk'
        $r.Output | Should Match 'auth.type'
        $r.Output | Should Match 'ttl_ms'
    }
}
