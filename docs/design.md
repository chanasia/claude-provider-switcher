# claude-provider-switcher — Design Record

Windows-first Claude Code plugin for switching LLM providers (Anthropic direct ↔
Anthropic-compatible gateways) and per-profile default models, implemented in
pure PowerShell.

## 1. Invariants

1. **No secret material in plugin-managed files.** Profile JSONs, the sidecar,
   and rendered helper shims contain only *references* (Credential Manager
   target names, env var names) — never tokens.
2. **Plugin writes only to `settings.local.json`** (global:
   `~/.claude/settings.local.json`), never `settings.json`. Machine-specific
   auth stays out of dotfiles repos.
3. **Sidecar-first crash-safe ordering.** The sidecar (`.state.json`) records
   what the plugin is about to manage *before* the target settings file is
   written. A crash between the two writes leaves a recoverable state.
4. **Drift is never silently overwritten.** Every switch compares the settings
   file against the sidecar's record of what the plugin last wrote. Any
   mismatch stops the switch (exit 8) until the user chooses a resolution.
5. **Atomic writes everywhere.** Same-directory temp file → write (UTF-8,
   no BOM) → `Move-Item -Force`, under an advisory lock (mkdir-based with
   stale-PID reclaim).
6. **Extras denylist enforced twice** — validate-time and apply-time
   (defense in depth). Keys that can alter process semantics are rejected.
7. **No autonomous activation.** Every behavior is user-invoked via a slash
   command. The plugin ships no agents, hooks, or skills.
8. **Doctor never executes helpers.** Diagnostics report file existence /
   parseability / credential presence without running anything that could
   print a secret.
9. **Restart honesty.** Claude Code reads auth env vars at process startup;
   a switch prepares the *next* session. Exit 9 = "written successfully,
   restart required" and the command layer states this plainly and stops.
10. **Minimal interactivity.** Commands report and end. The only questions
    the command layer may ask are decisions the plugin cannot make: drift
    resolution (switch), the destructive-delete confirmation (remove), and
    the add wizard's field collection. Never "next step" menus.

## 2. On-disk layout (outside the repo)

```
~/.claude/provider-profiles/
  anthropic.json              seed: auth none → subscription OAuth
  <name>.json                 gateway profiles created via /provider:add
                              (templates/profile-gateway-example.json in the
                              repo documents the shape; it is NOT seeded)
  .state.json                 sidecar (managed-keys record per scope)
  .state.lock/                advisory lock dir (transient)
  .helpers/<name>.ps1         rendered secret-reading shim (reference only)
  .helpers/<name>.cmd         cmd wrapper — the value written to apiKeyHelper
```

`CLAUDE_PROVIDER_HOME` env var overrides `$HOME` for tests.

## 3. Profile schema

Authoritative reference: [`lib/profile-schema.json`](../lib/profile-schema.json).
Enforced by `scripts/validate-profile.ps1` (pure PowerShell, no external
validator).

| Field | Rule |
|---|---|
| `name` | required, `^[a-z0-9][a-z0-9-]{0,62}$`, must equal filename basename |
| `description` | optional, ≤ 200 chars |
| `base_url` | optional, `https://` required except `localhost` / `127.0.0.1` |
| `auth.type` | required: `none` \| `credman` \| `env_var` |
| `auth.target` | credman only: `^[A-Za-z0-9_./-]{1,255}$` (rejects shell metacharacters) |
| `auth.var` | env_var only: `^[A-Z_][A-Z0-9_]*$` |
| `model` | optional, `^[A-Za-z0-9_.:/-]{1,128}$` — written as top-level `model` in settings |
| `ttl_ms` | optional int, 1000–86400000 → `CLAUDE_CODE_API_KEY_HELPER_TTL_MS` |
| `extras` | optional map, keys `^[A-Z_][A-Z0-9_]*$`, string values, no denylisted keys |

Unknown top-level keys are rejected.

### Extras denylist

`PATH HOME USER USERNAME USERPROFILE TEMP TMP SHELL TERM EDITOR VISUAL
COMSPEC PSModulePath PATHEXT SystemRoot
LD_* DYLD_* LD_LIBRARY_PATH LD_PRELOAD
XDG_CONFIG_HOME XDG_DATA_HOME XDG_CACHE_HOME XDG_STATE_HOME XDG_RUNTIME_DIR
NODE_OPTIONS NODE_PATH NODE_EXTRA_CA_CERTS
PYTHONPATH PYTHONSTARTUP RUBYLIB RUBYOPT PERL5LIB PERL5OPT
JAVA_TOOL_OPTIONS _JAVA_OPTIONS MAVEN_OPTS GRADLE_OPTS
GIT_SSH_COMMAND GIT_EXEC_PATH SSL_CERT_FILE SSL_CERT_DIR
CARGO_HOME GOPATH GOBIN CMAKE_PREFIX_PATH PKG_CONFIG_PATH COMPOSER_HOME
ANTHROPIC_BASE_URL ANTHROPIC_AUTH_TOKEN ANTHROPIC_API_KEY ANTHROPIC_MODEL
CLAUDE_PROVIDER_ACTIVE CLAUDE_CODE_API_KEY_HELPER_TTL_MS`

(`ANTHROPIC_*` / marker / TTL are plugin-managed — profiles express them via
dedicated fields, not extras. `LD_*`/`DYLD_*` are prefix matches.)

## 4. Managed keys & sidecar

Per scope (v0.1: `global` only) the sidecar records:

```json
{
  "global": {
    "active_profile": "gateway-example",
    "managed_env_keys": ["CLAUDE_PROVIDER_ACTIVE", "ANTHROPIC_BASE_URL", "..."],
    "managed_env_values": { "CLAUDE_PROVIDER_ACTIVE": "gateway-example" },
    "managed_model": true,
    "managed_model_value": "some/model-name",
    "managed_api_key_helper": true,
    "managed_api_key_helper_value": "C:\\Users\\me\\.claude\\provider-profiles\\.helpers\\gateway-example.cmd",
    "target_file": "C:\\Users\\me\\.claude\\settings.local.json"
  }
}
```

Managed env keys are always `CLAUDE_PROVIDER_ACTIVE` (session marker), plus
`ANTHROPIC_BASE_URL` (if `base_url`), `CLAUDE_CODE_API_KEY_HELPER_TTL_MS`
(if `ttl_ms`), plus every extras key. Managed top-level keys: `model`
(if profile sets one) and `apiKeyHelper` (if auth is credman/env_var).

## 5. Switch algorithm (apply-profile.ps1)

0. Validate profile (exit 6 on failure).
1. Acquire advisory lock (exit 1 if held by a live process).
2. Read target settings file (must be valid JSON if present).
3. Read sidecar scope entry (missing sidecar file ⇒ empty scope; *corrupt*
   sidecar ⇒ refuse, exit 1 — silently treating it as empty would strand
   previously managed keys).
4. **Drift detection** over every previously managed env key + `model` +
   `apiKeyHelper`. On drift: exit 8 unless `-AcceptDrift overwrite`
   (new profile wins) or `-AcceptDrift incorporate` (drifted keys not managed
   by the new profile are preserved as unmanaged; drifted `apiKeyHelper` can
   never be incorporated — overwrite or cancel only).
5. Compute new managed set; re-check extras against the denylist.
6. Render helper shim if auth is credman/env_var (see §6); resolve the `.cmd`
   path in Windows form for the `apiKeyHelper` value.
7. Remove all previously managed keys from the settings object; re-insert
   incorporated drifted values as unmanaged when applicable.
8. Merge new keys: extras first, plugin-managed keys last (plugin wins
   conflicts).
9. Write sidecar (atomic) — **before** the target.
10. Write settings (atomic).
11. Stale-env check: if `$env:CLAUDE_PROVIDER_ACTIVE` ≠ new profile name,
    exit 9 (restart required). Lock released via `finally`.

## 6. apiKeyHelper on Windows

Claude Code invokes `apiKeyHelper` through the OS shell; POSIX `.sh` paths do
not work on native Windows. The plugin therefore renders **two files** per
credman/env_var profile:

- `<name>.ps1` — self-contained secret reader (P/Invoke `advapi32!CredReadW`
  for credman; `$env:VAR` for env_var). Prints the token to stdout, errors to
  stderr, non-zero exit on failure. Never logs.
- `<name>.cmd` — one-line wrapper:
  `powershell -NoProfile -ExecutionPolicy Bypass -File "<abs path to ps1>"` —
  this `.cmd` Windows path is what goes into `settings.local.json`'s
  `apiKeyHelper`.

Rendering substitutes only values that already passed the schema regexes
(defense in depth: re-validated at render time), then re-parses the result
and rejects any leftover `{{PLACEHOLDER}}`.

## 7. Exit code protocol

| Code | Meaning |
|---|---|
| 0 | success |
| 1 | runtime error (lock held, corrupt sidecar, write failure) |
| 2 | usage error |
| 3 | profile not found |
| 4 | profile already exists |
| 5 | locked — the operation targets the active profile (e.g. `remove`); also reserved for project-scope locking post-v0.1 |
| 6 | schema validation failure |
| 7 | missing dependency |
| 8 | drift detected — needs user resolution |
| 9 | success, but running session env is stale — restart required |

The command layer (`commands/*.md`) maps codes to user-facing flows:
8 → Drift Confirm Flow (AskUserQuestion: Overwrite / Incorporate / Cancel,
at most one retry), 9 → a plain one-line "restart to activate" statement
(no prompt; never attempt to restart Claude Code).

## 8. Platform extension points

All platform-specific behavior lives in two places, marked with
`#region platform` comments:

- `scripts/lib.ps1` — secret read/write (`Get-StoredCredential` /
  `Set-StoredCredential`, Windows Credential Manager P/Invoke). Porting to
  macOS/Linux means adding `security` / `secret-tool` equivalents behind the
  same function names.
- `scripts/render-helper.ps1` + `templates/` — shim format (`.cmd` + `.ps1`
  on Windows; a POSIX port renders a single `.sh`).

Everything else (validation, drift, sidecar, merge) is pure JSON logic with
no OS assumptions beyond path separators.

## 9. Threat model highlights

- **Token exfil via repo commit** — mitigated by invariant 1: nothing to leak.
- **Malicious profile escalation via extras** — denylist blocks env vars that
  change process semantics (`PATH`, `NODE_OPTIONS`, loader variables, CA/SSL
  overrides, VCS hooks).
- **Shell injection via profile fields** — every value substituted into a shim
  passes a strict character allowlist; shims are re-parsed post-render.
- **Concurrent switches** — advisory lock + atomic renames; worst case is a
  refused switch, never a torn file.
- **Hand-edited settings clobbered** — drift detection halts before any
  destructive merge.
