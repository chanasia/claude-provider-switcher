# claude-provider-switcher

> Switch Claude Code between Anthropic direct and custom LLM gateway providers — with per-profile default models — via slash commands. Windows-first. Zero secrets in files.

`claude-provider-switcher` is a [Claude Code](https://code.claude.com) plugin that lets you keep multiple LLM endpoint profiles — Anthropic subscription (OAuth), a company gateway, a self-hosted proxy, a local relay — and switch between them with one command. Profiles live in `~/.claude/provider-profiles/`; tokens live in **Windows Credential Manager** (or an env var of your choice), never in any file.

**Design principle:** the plugin never holds secret material. It manages *references* only, and delegates key retrieval to Claude Code's built-in `apiKeyHelper` mechanism.

## Status

**v0.1.0 — all seven commands implemented, 95 Pester tests green on Windows PowerShell 5.1.**

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
| `/provider:install-cli` | Install the offline `provider` CLI (the escape hatch — see below) |

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

> **Close other Claude Code sessions before switching.** Claude Code itself writes `~/.claude/settings.json` (plugin registry, `/model` persistence), so a session left running across a switch can write stale provider keys back afterward. `/provider:doctor` flags those as *stray* keys and `--fix` removes them.

## Security model

- **No secrets in plugin-managed files.** Profiles, sidecar state, and rendered helper shims hold only references.
- **Extras denylist** — env vars that could alter process semantics (`PATH`, `NODE_OPTIONS`, `LD_*`, `PYTHONPATH`, `SSL_CERT_*`, …) are rejected at validate-time *and* apply-time.
- **Drift detection** — if a plugin-managed key was hand-edited since the last switch, the switch stops and asks before overwriting.
- **Atomic writes** — settings, sidecar, profile, and shim writes follow a same-directory temp-then-rename protocol under an advisory lock.
- Plugin writes only the keys it manages to the **user-scope** `~/.claude/settings.json` (so profiles apply in every project directory); it never touches any project's `.claude/settings*.json`.

See [`docs/design.md`](./docs/design.md) for the full invariant list and threat model.

## Install

### Via the plugin marketplace (recommended)

Inside any Claude Code session:

```
/plugin marketplace add chanasia/claude-provider-switcher
/plugin install provider@claude-provider-switcher
```

### Via a local clone

```powershell
git clone https://github.com/chanasia/claude-provider-switcher.git
claude --plugin-dir path\to\claude-provider-switcher
```

Either way, run `/provider:init` inside the session afterwards, then `/provider:list` to confirm the commands are loaded.

## Typical flow

```
/provider:init                    seed ~/.claude/provider-profiles/
/provider:add                     create a gateway profile; token goes to Credential Manager
/provider:switch work-gateway     writes the config, reports "restart required"
  (exit Claude Code, start it again)
/provider:current                 confirms the session is really on it
/model some/other-model           change model mid-session, no restart
/provider:switch anthropic        back to your subscription (restart again)
```

## Troubleshooting

**Locked out — switched to a broken provider and Claude can't respond.**
Slash commands need a working model to interpret them, so when the provider is broken you fix it from plain PowerShell instead. If you installed the CLI (`/provider:install-cli` — do it while things still work), it's one line:

```
claude-provider anthropic
```

Then restart Claude Code — you're back on Anthropic direct. Without the CLI, every script still runs standalone:

```powershell
$scripts = Split-Path (Get-ChildItem "$env:USERPROFILE\.claude\plugins\cache" -Recurse -Filter apply-profile.ps1 | Select-Object -First 1).FullName
powershell -NoProfile -ExecutionPolicy Bypass -File "$scripts\init.ps1"                    # if 'anthropic' was never seeded
powershell -NoProfile -ExecutionPolicy Bypass -File "$scripts\apply-profile.ps1" anthropic
```

(Local-clone installs: use `<clone>\scripts` directly.) Before re-trying the broken profile, check that its helper prints a token and run doctor:

```powershell
& "$env:USERPROFILE\.claude\provider-profiles\.helpers\<name>.cmd"
powershell -NoProfile -ExecutionPolicy Bypass -File "$scripts\doctor.ps1"
```

## Offline CLI

`/provider:install-cli` copies a `claude-provider` command to `~\.claude\bin` and puts it on your user Path. It is deliberately an **emergency tool with exactly two commands** — day-to-day management stays in the slash commands — and needs no model and no network:

| Command | What it does |
|---|---|
| `claude-provider anthropic` | Back to Anthropic direct, self-healing: seeds the profile if missing, repairs a corrupt sidecar, overwrites drift. Restart Claude Code afterwards. |
| `claude-provider reset [-Force]` | Remove **all** plugin state — managed settings keys, every profile, the sidecar and shims, referenced Credential Manager entries, and the CLI itself. The plugin stays installed in Claude Code; `/provider:init` starts fresh. |

Install it right after `/provider:init`.

**"I switched but nothing changed."**
Claude Code reads provider environment variables at process startup. Exit and relaunch. Exit code 9 from `switch` is the plugin saying exactly this. `/provider:current` will show `STALE` until you do.

**`/provider:switch` reports drift.**
Something other than the plugin edited a plugin-managed key in `~/.claude/settings.json` since the last switch. The command offers three resolutions: overwrite with the new profile's values, incorporate the hand-edits where the new profile doesn't manage them, or cancel. A drifted `apiKeyHelper` can only be overwritten or cancelled, never silently incorporated.

**"No credential stored in Windows Credential Manager."**
The profile references a target that has no credential. Store one without putting it on a command line — run in a PowerShell window and it prompts with the input hidden:

```powershell
powershell -NoProfile -File scripts\set-credential.ps1 -Target "claude-provider/work-gateway"
```

(Or pipe it: `Get-Content token.txt | powershell -NoProfile -File scripts\set-credential.ps1 -Target ...`.) Never pass the token as a `-Secret` argument from inside a Claude Code session: approved command lines are recorded verbatim in `settings.local.json`, which would write the token to a plain-text file. `/provider:doctor` flags that and `--fix` cleans it up.

**Running the scripts directly.**
Every script is standalone and takes `-Json` or `-Fix` where relevant. `CLAUDE_PROVIDER_HOME` overrides `$HOME`, which is how the test suite stays out of your real `~/.claude`.

## Portability

v0.1.0 is Windows-only in its *auth and helper* layer; everything else (validation, drift, sidecar, merge) is OS-agnostic JSON logic. Porting to macOS/Linux means reimplementing two marked regions — `#region platform` in [`scripts/lib.ps1`](./scripts/lib.ps1) (credential storage) and the shim templates in [`templates/`](./templates/) — against `security` or `secret-tool`. See [`docs/design.md`](./docs/design.md) §8.

## License

MIT. See [LICENSE](./LICENSE).
