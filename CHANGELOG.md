# Changelog

All notable changes to claude-provider-switcher are documented in this file.

The format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Planned

- **Phase 2: macOS / Linux support** — plan and implementer handoff in
  [docs/phase2-cross-platform.md](./docs/phase2-cross-platform.md)
- Project scope (`<repo>/.claude/settings.local.json`) alongside global
- `/provider:edit` for flag-driven field changes

## [0.1.11]

### Added

- **settings.json backup on switch.** apply-profile now copies the
  pre-switch `settings.json` to `settings.json.bak` (single rolling
  backup) before writing, so a bad switch can be undone by hand.

### Changed

- `model` now accepts commas, allowing the router-style
  `provider,model` form used by gateways such as claude-code-router.

## [0.1.10]

### Added

- **doctor check 11: stray plugin-like keys.** Claude Code itself writes
  `~/.claude/settings.json` (plugin registry, `/model` persistence), so a
  session left running across a switch can write stale provider keys
  back after apply-profile cleaned them - found in real use. doctor now
  flags unmanaged keys that are recognizably the plugin's (an
  `apiKeyHelper` path inside the profile dir, an `ANTHROPIC_BASE_URL`
  matching a profile, the `CLAUDE_PROVIDER_ACTIVE` marker); `--fix`
  removes them. A hand-set `model` alone (e.g. via `/model`) is never
  flagged, and keys the sidecar owns stay in the drift check.
- README: close other Claude Code sessions before switching.

## [0.1.9]

### Fixed

- **Profiles now apply in EVERY project directory.** Versions up to 0.1.8
  wrote managed keys to `~/.claude/settings.local.json`, assuming it was
  a user-scope file. It is not: `settings.local.json` is a project-level
  concept only, so Claude Code read that path solely when started from
  the home directory (home being that session's "project"). The symptom,
  found in real use: switch works in a terminal at `%USERPROFILE%`, but a
  session started inside any project still runs the old provider.
  The plugin now writes to the real user-scope file,
  `~/.claude/settings.json` - managed keys only; everything else in the
  file is preserved, and project settings files are never touched.

### Migration

Automatic. The sidecar's `target_file` records where the current record
lives; the first `/provider:switch` after updating checks drift against
the legacy file, moves the managed keys to `settings.json`, and cleans
the legacy file (deleting it if nothing else remains). `doctor` warns
while the record is still in the legacy location and flags leftovers;
`--fix` removes them.

## [0.1.8]

### Changed

- Removed the token-rotation advice from doctor's `secret` finding and
  from the docs (user feedback). The check still detects and `-Fix`
  still removes permission entries embedding a secret; whether to
  rotate is the user's call.

## [0.1.7]

### Security

- **The `/provider:add` and `/provider:switch` flows no longer pass the
  token on a command line or ask for it in chat.** Claude Code records
  approved command lines verbatim in `settings.local.json`'s
  `permissions.allow`, so the previous `-Secret "<token>"` invocation
  wrote the token into a plain-text file (found in real use, violating
  invariant 1). The user now runs `set-credential.ps1 -Target <target>`
  themselves; it prompts for the token with input hidden.
- `set-credential.ps1`: interactive hidden prompt when run in a console
  without piped stdin; new `-Test` switch for an existence-only check
  (exit 0 stored / exit 3 not stored) so the wizard can verify without
  ever touching the value.
- `doctor` check 9: flags permission entries embedding a secret
  (`-Secret`-style command lines) without echoing them; `-Fix` removes
  the entries.

**If you used `/provider:add` with a `credman` profile on v0.1.6 or
earlier: your token is sitting in `~/.claude/settings.local.json`.** Run
`/provider:doctor --fix` after updating.

## [0.1.6]

### Changed

- **Offline CLI renamed `provider` -> `claude-provider`** and slimmed to an
  emergency-only tool with exactly two commands (user feedback - full
  command parity duplicated the slash commands and invited misuse):
  - `claude-provider anthropic` - self-healing switch-back: seeds the
    profile if missing, repairs a corrupt sidecar via doctor -Fix, and
    overwrites drift instead of stopping to ask.
  - `claude-provider reset [-Force]` - removes all plugin state (managed
    settings keys, profiles, sidecar, shims, referenced Credential Manager
    entries, the CLI itself). The plugin stays installed in Claude Code.
- install-cli removes the legacy `provider.cmd`/`provider.ps1` on upgrade.

## [0.1.5]

### Changed

- `/provider:init` no longer seeds `gateway-example` (user feedback): an
  unusable placeholder showing up in `/provider:list` next to real,
  switchable profiles is confusing. The template stays in the repo's
  `templates/` as schema documentation; real gateway profiles come from
  `/provider:add`. Existing machines: `/provider:remove gateway-example`.

## [0.1.4]

### Changed

- `/provider:add` no longer offers "Anthropic direct" as an endpoint
  choice (user feedback): the seeded `anthropic` profile already covers
  it, so the wizard is now explicitly for gateway/proxy profiles. When
  other gateway profiles exist, their endpoint is offered as the default.

## [0.1.3]

### Added

- **Offline `provider` CLI** (`/provider:install-cli`): installs a
  `provider` command onto the user Path that dispatches to the standalone
  scripts with no model and no network - the escape hatch for when a
  switch lands on a broken provider and slash commands cannot run.
  `provider switch anthropic` recovers the session from any terminal.
- README: "Locked out" troubleshooting and "Offline CLI" sections.

## [0.1.2]

### Changed

- Commands now report and END. Removed every source of unsolicited
  follow-up questions and "next step" menus (user feedback). The only
  remaining questions are real decisions: drift resolution in `switch`,
  the delete confirmation in `remove`, and the `add` wizard's fields.
- Exit 9 (restart required) is a plain one-line statement instead of an
  acknowledgement prompt - there was never a decision to make there.

## [0.1.1]

### Changed

- "No profile is active" now states the implication explicitly everywhere
  (`current`, `list`, and the `switch anthropic` not-found path): the session
  is on Anthropic direct - Claude Code defaults - not in an unknown state.
- `switch anthropic` when the seed profile is missing now hints that
  `/provider:init` creates it, and notes when the session is already on
  Anthropic direct so no switch is needed.

## [0.1.0]

Initial release. Windows-first.

### Added

- **7 slash commands:** `init`, `list`, `current`, `switch`, `add`, `remove`, `doctor`
- **3 auth types:** `none` (Anthropic subscription/OAuth), `credman` (Windows
  Credential Manager), `env_var`
- **Per-profile default model**, written as the top-level `model` key and
  tracked as a managed key like any other
- **Profile schema** with validation at create time and apply time
- **Extras denylist** (~50 env vars) enforced at both validate-time and
  apply-time
- **Drift detection** with three resolutions (overwrite / incorporate /
  cancel); `apiKeyHelper` drift is never silently incorporated
- **Atomic writes** for settings, sidecar, profiles, and shims — same-directory
  temp file, UTF-8 without BOM, rename, under an advisory lock with stale-PID
  reclaim
- **Crash-safe sidecar-first ordering**
- **`apiKeyHelper` shim pair** per profile: a `.ps1` secret reader plus the
  `.cmd` wrapper whose Windows path goes into settings, since Claude Code on
  Windows cannot execute a `.ps1` directly
- **`set-credential.ps1`** for storing a token in Credential Manager, reading
  from stdin so secrets need never appear on a command line
- **Exit-code protocol** (0/1/2/3/4/6/8/9) that the command layer maps to
  user-facing flows, including the restart acknowledgement on exit 9

### Invariants

No secret material in any plugin-managed file. Writes go only to
`settings.local.json`, never `settings.json`. Drift is never silently
overwritten. `doctor` never executes a helper or reads a secret's value.
Nothing activates without an explicit user command.

### Tests

95 Pester tests on Windows PowerShell 5.1, including end-to-end execution of a
rendered Credential Manager shim through `cmd.exe`. CI additionally runs
PSScriptAnalyzer and an ASCII-only check on executable files.
