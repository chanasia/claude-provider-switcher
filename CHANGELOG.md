# Changelog

All notable changes to claude-provider-switcher are documented in this file.

The format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Planned

- Project scope (`<repo>/.claude/settings.local.json`) alongside global
- `/provider:edit` for flag-driven field changes
- macOS / Linux port of the credential and shim layers

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
