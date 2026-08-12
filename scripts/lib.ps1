# lib.ps1 — shared helpers for claude-provider-switcher scripts.
#
# Every script dot-sources this file first:
#   . (Join-Path $PSScriptRoot 'lib.ps1')
#
# Windows PowerShell 5.1 compatible. See docs/design.md for the invariants
# each helper enforces.

Set-StrictMode -Version 2.0

# ============================================================
# Exit codes (design.md §7)
# ============================================================
$EXIT_OK               = 0
$EXIT_RUNTIME          = 1
$EXIT_USAGE            = 2
$EXIT_NOT_FOUND        = 3
$EXIT_EXISTS           = 4
$EXIT_LOCKED           = 5
$EXIT_SCHEMA           = 6
$EXIT_MISSING_DEP      = 7
$EXIT_DRIFT            = 8
$EXIT_RESTART_REQUIRED = 9

# ============================================================
# Paths (design.md §2). CLAUDE_PROVIDER_HOME overrides $HOME for tests.
# ============================================================
function Get-ProviderUserHome {
    if ($env:CLAUDE_PROVIDER_HOME) { return $env:CLAUDE_PROVIDER_HOME }
    return $HOME
}

function Get-ProfileDir {
    return (Join-Path (Get-ProviderUserHome) '.claude\provider-profiles')
}

function Get-HelpersDir {
    return (Join-Path (Get-ProfileDir) '.helpers')
}

function Get-SettingsPath {
    return (Join-Path (Get-ProviderUserHome) '.claude\settings.local.json')
}

function Get-SidecarPath {
    return (Join-Path (Get-ProfileDir) '.state.json')
}

function Get-LockDir {
    return (Join-Path (Get-ProfileDir) '.state.lock')
}

function Get-ProfilePath {
    param([string]$Name)
    return (Join-Path (Get-ProfileDir) ($Name + '.json'))
}

# ============================================================
# Extras denylist (design.md §3). Env vars that can alter process
# semantics MUST NOT appear as extras keys. Checked at validate-time
# AND apply-time (defense in depth). LD_*/DYLD_* are prefix matches.
# ============================================================
$ExtrasDenylist = @(
    'PATH', 'HOME', 'USER', 'USERNAME', 'USERPROFILE', 'TEMP', 'TMP',
    'SHELL', 'TERM', 'TMPDIR', 'EDITOR', 'VISUAL',
    'COMSPEC', 'PSMODULEPATH', 'PATHEXT', 'SYSTEMROOT',
    'LD_LIBRARY_PATH', 'LD_PRELOAD',
    'XDG_CONFIG_HOME', 'XDG_DATA_HOME', 'XDG_CACHE_HOME', 'XDG_STATE_HOME', 'XDG_RUNTIME_DIR',
    'NODE_OPTIONS', 'NODE_PATH', 'NODE_EXTRA_CA_CERTS',
    'PYTHONPATH', 'PYTHONSTARTUP', 'PYTHONDONTWRITEBYTECODE',
    'RUBYLIB', 'RUBYOPT', 'PERL5LIB', 'PERL5OPT',
    'JAVA_TOOL_OPTIONS', '_JAVA_OPTIONS', 'MAVEN_OPTS', 'GRADLE_OPTS',
    'GIT_SSH_COMMAND', 'GIT_EXEC_PATH',
    'SSL_CERT_FILE', 'SSL_CERT_DIR',
    'CARGO_HOME', 'GOPATH', 'GOBIN', 'CMAKE_PREFIX_PATH', 'PKG_CONFIG_PATH', 'COMPOSER_HOME',
    'ANTHROPIC_BASE_URL', 'ANTHROPIC_AUTH_TOKEN', 'ANTHROPIC_API_KEY', 'ANTHROPIC_MODEL',
    'CLAUDE_PROVIDER_ACTIVE', 'CLAUDE_CODE_API_KEY_HELPER_TTL_MS'
)

function Test-DenylistedKey {
    param([string]$Key)
    $upper = $Key.ToUpperInvariant()
    if ($upper.StartsWith('LD_') -or $upper.StartsWith('DYLD_')) { return $true }
    return ($ExtrasDenylist -contains $upper)
}

# ============================================================
# JSON helpers
# ============================================================
function Read-JsonFile {
    # Parses a JSON file. Throws on missing file or invalid JSON.
    param([string]$Path)
    if (-not (Test-Path -LiteralPath $Path)) {
        throw "file not found: $Path"
    }
    # .NET APIs resolve relative paths against a CWD PowerShell doesn't sync.
    $full = (Resolve-Path -LiteralPath $Path).ProviderPath
    $raw = [System.IO.File]::ReadAllText($full)
    try {
        return ($raw | ConvertFrom-Json)
    } catch {
        throw "not valid JSON: $Path"
    }
}

function Test-JsonFileValid {
    param([string]$Path)
    try { $null = Read-JsonFile -Path $Path; return $true } catch { return $false }
}

# ============================================================
# Atomic write protocol (design.md invariant 5): same-directory temp
# file -> write UTF-8 (no BOM) -> rename over target.
# ============================================================
function Write-AtomicFile {
    param(
        [string]$Path,
        [string]$Content
    )
    if (-not [System.IO.Path]::IsPathRooted($Path)) {
        $Path = Join-Path (Get-Location).ProviderPath $Path
    }
    $dir = Split-Path -Parent $Path
    if (-not (Test-Path -LiteralPath $dir)) {
        throw "Write-AtomicFile: parent dir does not exist: $dir"
    }
    $base = Split-Path -Leaf $Path
    $tmp = Join-Path $dir ('.{0}.{1}.tmp' -f $base, [System.IO.Path]::GetRandomFileName())
    try {
        $utf8NoBom = New-Object System.Text.UTF8Encoding($false)
        [System.IO.File]::WriteAllText($tmp, $Content, $utf8NoBom)
        Move-Item -LiteralPath $tmp -Destination $Path -Force
    } catch {
        if (Test-Path -LiteralPath $tmp) { Remove-Item -LiteralPath $tmp -Force -ErrorAction SilentlyContinue }
        throw
    }
}

# ============================================================
# Advisory lock (design.md invariant 5): mkdir-based, PID recorded,
# stale locks (dead holder PID) are reclaimed.
# ============================================================
function Lock-ProviderState {
    $lockDir = Get-LockDir
    $retries = 0
    while ($retries -lt 3) {
        try {
            $null = New-Item -ItemType Directory -Path $lockDir -ErrorAction Stop
            Set-Content -LiteralPath (Join-Path $lockDir 'pid') -Value $PID -Encoding Ascii
            return $true
        } catch {
            # Lock exists — is the holder still alive?
            $pidFile = Join-Path $lockDir 'pid'
            $holderPid = $null
            if (Test-Path -LiteralPath $pidFile) {
                try { $holderPid = [int](Get-Content -LiteralPath $pidFile -ErrorAction Stop | Select-Object -First 1) } catch {}
            }
            if ($holderPid) {
                $alive = $false
                try { $alive = ($null -ne (Get-Process -Id $holderPid -ErrorAction Stop)) } catch {}
                if (-not $alive) {
                    Remove-Item -LiteralPath $lockDir -Recurse -Force -ErrorAction SilentlyContinue
                    $retries = $retries + 1
                    continue
                }
            }
            return $false
        }
    }
    return $false
}

function Unlock-ProviderState {
    $lockDir = Get-LockDir
    if (Test-Path -LiteralPath $lockDir) {
        Remove-Item -LiteralPath $lockDir -Recurse -Force -ErrorAction SilentlyContinue
    }
}

# ============================================================
# Sidecar state (design.md §4). Missing file reads as an empty object;
# a CORRUPT file always throws — treating it as empty would strand
# previously managed keys in the settings file.
# ============================================================
function Read-Sidecar {
    $path = Get-SidecarPath
    if (-not (Test-Path -LiteralPath $path)) {
        return (New-Object PSObject)
    }
    $raw = [System.IO.File]::ReadAllText($path)
    if ($raw.Trim() -eq '') { return (New-Object PSObject) }
    try {
        return ($raw | ConvertFrom-Json)
    } catch {
        throw "sidecar state file is corrupt: $path (run /provider:doctor --fix to rebuild)"
    }
}

function Read-SidecarScope {
    # Returns the scope entry (PSObject) or $null if the scope isn't tracked.
    param([string]$ScopeKey)
    $sidecar = Read-Sidecar
    $prop = $sidecar.PSObject.Properties[$ScopeKey]
    if ($null -eq $prop) { return $null }
    return $prop.Value
}

function Write-SidecarScope {
    # Atomically updates one scope entry, preserving other scopes.
    param(
        [string]$ScopeKey,
        $Entry
    )
    $sidecar = Read-Sidecar   # throws if corrupt
    if ($null -ne $sidecar.PSObject.Properties[$ScopeKey]) {
        $sidecar.PSObject.Properties.Remove($ScopeKey)
    }
    $sidecar | Add-Member -MemberType NoteProperty -Name $ScopeKey -Value $Entry
    $dir = Split-Path -Parent (Get-SidecarPath)
    if (-not (Test-Path -LiteralPath $dir)) {
        $null = New-Item -ItemType Directory -Path $dir -Force
    }
    Write-AtomicFile -Path (Get-SidecarPath) -Content (($sidecar | ConvertTo-Json -Depth 10) + "`n")
}

#region platform — Windows Credential Manager (P/Invoke advapi32)
# Porting note (design.md §8): a macOS/Linux port implements these same
# four functions against `security` / `secret-tool`. Nothing outside this
# region touches an OS credential store.
# ============================================================

if (-not ('ClaudeProviderSwitcher.CredMan' -as [type])) {
    Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;

namespace ClaudeProviderSwitcher
{
    public class CredMan
    {
        public const int CRED_TYPE_GENERIC = 1;
        public const int CRED_PERSIST_LOCAL_MACHINE = 2;

        [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)]
        public struct CREDENTIAL
        {
            public int Flags;
            public int Type;
            public string TargetName;
            public string Comment;
            public System.Runtime.InteropServices.ComTypes.FILETIME LastWritten;
            public int CredentialBlobSize;
            public IntPtr CredentialBlob;
            public int Persist;
            public int AttributeCount;
            public IntPtr Attributes;
            public string TargetAlias;
            public string UserName;
        }

        [DllImport("advapi32.dll", EntryPoint = "CredReadW", CharSet = CharSet.Unicode, SetLastError = true)]
        public static extern bool CredRead(string target, int type, int reservedFlag, out IntPtr credentialPtr);

        [DllImport("advapi32.dll", EntryPoint = "CredWriteW", CharSet = CharSet.Unicode, SetLastError = true)]
        public static extern bool CredWrite(ref CREDENTIAL credential, int flags);

        [DllImport("advapi32.dll", EntryPoint = "CredDeleteW", CharSet = CharSet.Unicode, SetLastError = true)]
        public static extern bool CredDelete(string target, int type, int flags);

        [DllImport("advapi32.dll")]
        public static extern void CredFree(IntPtr buffer);
    }
}
'@
}

function Get-StoredCredential {
    # Returns the secret string for a Credential Manager generic target,
    # or throws if the target does not exist. NEVER log the return value.
    param([string]$Target)
    $credPtr = [IntPtr]::Zero
    $ok = [ClaudeProviderSwitcher.CredMan]::CredRead(
        $Target, [ClaudeProviderSwitcher.CredMan]::CRED_TYPE_GENERIC, 0, [ref]$credPtr)
    if (-not $ok) {
        throw "credential not found in Windows Credential Manager: $Target"
    }
    try {
        $cred = [System.Runtime.InteropServices.Marshal]::PtrToStructure(
            $credPtr, [type][ClaudeProviderSwitcher.CredMan+CREDENTIAL])
        if ($cred.CredentialBlobSize -eq 0) { return '' }
        $bytes = New-Object byte[] $cred.CredentialBlobSize
        [System.Runtime.InteropServices.Marshal]::Copy($cred.CredentialBlob, $bytes, 0, $cred.CredentialBlobSize)
        # This plugin writes UTF-8. Tools like cmdkey write UTF-16LE, whose
        # ASCII-range bytes contain NULs — detect and decode accordingly.
        if ($bytes -contains 0) {
            return [System.Text.Encoding]::Unicode.GetString($bytes)
        }
        return [System.Text.Encoding]::UTF8.GetString($bytes)
    } finally {
        [ClaudeProviderSwitcher.CredMan]::CredFree($credPtr)
    }
}

function Test-StoredCredential {
    # Existence check that never materializes the secret in PowerShell space.
    param([string]$Target)
    $credPtr = [IntPtr]::Zero
    $ok = [ClaudeProviderSwitcher.CredMan]::CredRead(
        $Target, [ClaudeProviderSwitcher.CredMan]::CRED_TYPE_GENERIC, 0, [ref]$credPtr)
    if ($ok) { [ClaudeProviderSwitcher.CredMan]::CredFree($credPtr) }
    return $ok
}

function Set-StoredCredential {
    param(
        [string]$Target,
        [string]$Secret
    )
    $bytes = [System.Text.Encoding]::UTF8.GetBytes($Secret)
    $blob = [System.Runtime.InteropServices.Marshal]::AllocHGlobal($bytes.Length)
    try {
        [System.Runtime.InteropServices.Marshal]::Copy($bytes, 0, $blob, $bytes.Length)
        $cred = New-Object ClaudeProviderSwitcher.CredMan+CREDENTIAL
        $cred.Type = [ClaudeProviderSwitcher.CredMan]::CRED_TYPE_GENERIC
        $cred.TargetName = $Target
        $cred.CredentialBlob = $blob
        $cred.CredentialBlobSize = $bytes.Length
        $cred.Persist = [ClaudeProviderSwitcher.CredMan]::CRED_PERSIST_LOCAL_MACHINE
        $cred.UserName = 'claude-provider-switcher'
        $ok = [ClaudeProviderSwitcher.CredMan]::CredWrite([ref]$cred, 0)
        if (-not $ok) {
            $err = [System.Runtime.InteropServices.Marshal]::GetLastWin32Error()
            throw "CredWrite failed for '$Target' (Win32 error $err)"
        }
    } finally {
        [System.Runtime.InteropServices.Marshal]::FreeHGlobal($blob)
    }
}

function Remove-StoredCredential {
    param([string]$Target)
    $ok = [ClaudeProviderSwitcher.CredMan]::CredDelete(
        $Target, [ClaudeProviderSwitcher.CredMan]::CRED_TYPE_GENERIC, 0)
    return $ok
}

#endregion platform
