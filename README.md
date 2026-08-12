# claude-provider-switcher

> Switch Claude Code between Anthropic direct and custom LLM gateway providers — with per-profile default models — via slash commands. Windows-first. Zero secrets in files.

`claude-provider-switcher` is a [Claude Code](https://code.claude.com) plugin that lets you keep multiple LLM endpoint profiles — Anthropic subscription (OAuth), a company gateway, a self-hosted proxy, a local relay — and switch between them with one command. Profiles live in `~/.claude/provider-profiles/`; tokens live in **Windows Credential Manager** (or an env var of your choice), never in any file.

**Design principle:** the plugin never holds secret material. It manages *references* only, and delegates key retrieval to Claude Code's built-in `apiKeyHelper` mechanism.

## Status

**v0.1.0 — in development.**

## Prerequisites

- [Claude Code](https://code.claude.com/docs/en/install) on Windows
- Windows PowerShell 5.1+ (ships with Windows 10/11)

No other dependencies — no jq, no bash, no external modules.

## Commands

| Command | What it does |
|---------|--------------|
| `/provider:init` | First-time setup — creates `~/.claude/provider-profiles/` and seeds example profiles |
| `/provider:list` | Show all profiles and which is active |
| `/provider:current` | Show the effective profile for this session (redacted; warns if a restart is pending) |
| `/provider:switch <name>` | Change the active provider profile |
| `/provider:add` | Interactive wizard to create a new profile (stores token in Credential Manager) |
| `/provider:remove <name>` | Delete a profile (refuses if it's currently active) |
| `/provider:doctor [--fix]` | Diagnose broken shims, missing credentials, drift, invalid JSON |

Every command must be invoked explicitly. The plugin never auto-activates — switching auth is an explicit action, not an inferred one.

## Profile schema

```json
{
  "name": "gateway-example",
  "description": "Example Anthropic-compatible gateway",
  "base_url": "https://gateway.example.com/anthropic",
  "auth": { "type": "credman", "target": "claude-provider/gateway-example" },
  "model": "some/model-name",
  "ttl_ms": 300000,
  "extras": { "CLAUDE_CODE_MAX_OUTPUT_TOKENS": "64000" }
}
```

| `auth.type` | Required fields | Use for |
|-------------|-----------------|---------|
| `none` | — | Anthropic direct (subscription OAuth or `ANTHROPIC_API_KEY`) |
| `credman` | `target` | Tokens stored in Windows Credential Manager |
| `env_var` | `var` | Static keys kept in an environment variable |

The authoritative schema lives at [`lib/profile-schema.json`](./lib/profile-schema.json). Full design record: [`docs/design.md`](./docs/design.md).

## How activation works

Claude Code reads auth environment variables at process startup. `/provider:switch` prepares the **next** session — after switching, exit Claude Code and relaunch. (Exit code 9 = "written successfully, restart to activate".)

Switching **models within the same provider** needs no restart at all — use Claude Code's built-in `/model <name>` mid-session. A profile's `model` field only sets the default for new sessions.

## Security model

- **No secrets in plugin-managed files.** Profiles, sidecar state, and rendered helper shims hold only references.
- **Extras denylist** — env vars that could alter process semantics (`PATH`, `NODE_OPTIONS`, `LD_*`, `PYTHONPATH`, `SSL_CERT_*`, …) are rejected at validate-time *and* apply-time.
- **Drift detection** — if a plugin-managed key was hand-edited since the last switch, the switch stops and asks before overwriting.
- **Atomic writes** — settings, sidecar, profile, and shim writes follow a same-directory temp-then-rename protocol under an advisory lock.
- Plugin writes only to `settings.local.json`, never `settings.json`.

See [`docs/design.md`](./docs/design.md) for the full invariant list and threat model.

## Install

```powershell
git clone https://github.com/chanasia/claude-provider-switcher.git
claude --plugin-dir path\to\claude-provider-switcher
```

Inside the session run `/provider:init`, then `/provider:list` to confirm.

## License

MIT. See [LICENSE](./LICENSE).
