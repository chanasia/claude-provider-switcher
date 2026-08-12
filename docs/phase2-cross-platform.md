# Phase 2 — Cross-platform (macOS / Linux)

Target: v0.2.0. Written by the v0.1.x implementer as both a plan and a
handoff. Read [design.md](./design.md) first — it is the contract; this
document is about porting the *implementation* without breaking that
contract.

## What must NOT change

These are the product. Any port that alters them is a regression:

- The profile schema ([lib/profile-schema.json](../lib/profile-schema.json))
  and the sidecar format (design.md §4) — machines share dotfiles; a mac
  and a Windows box reading the same profile JSON must agree.
- The exit-code protocol (design.md §7) — the command layer and the CLI
  are built on it.
- Invariants 1–10, especially: no secret material in any plugin-managed
  file, sidecar-first write ordering, drift is never silently overwritten,
  and **minimal interactivity** (commands report and end; that one came
  from a real user telling us to stop asking questions — respect it).
- The slash-command UX (`commands/*.md`) and the emergency CLI's
  two-command shape (`claude-provider anthropic` / `reset`). Do not grow
  the CLI back into a second management interface; we deliberately cut it
  down from full parity after real-world confusion.

## Where the platform boundary already is

The code was written with this port in mind. OS-specific behavior lives in
exactly three places:

1. **`scripts/lib.ps1` `#region platform`** — Windows Credential Manager
   P/Invoke behind four functions: `Get-StoredCredential`,
   `Set-StoredCredential`, `Test-StoredCredential`,
   `Remove-StoredCredential`. Port = reimplement these four names:
   - macOS: `security add-generic-password -U` / `find-generic-password -w`
     / `delete-generic-password` (validate the target pattern before
     shelling out — the schema regex `^[A-Za-z0-9_./-]{1,255}$` already
     rejects shell metacharacters; keep re-validating at the call site,
     defense in depth is a habit here).
   - Linux: `secret-tool store/lookup/clear` (libsecret) when present;
     `env_var` auth is the fallback story when it is not. A new
     `auth.type` is NOT needed — `credman` should be renamed or aliased
     (e.g. accept `keystore` with `credman` as a documented alias) —
     decide once, migrate profiles never.

2. **`scripts/render-helper.ps1` + `templates/`** — Windows renders a
   `.ps1` reader plus a `.cmd` wrapper because Claude Code on Windows
   cannot exec a `.ps1`. On POSIX render a single `.sh` with a shebang and
   `chmod 700`, and write the `.sh` path into `apiKeyHelper`. Keep the
   post-render checks (re-parse, leftover `{{PLACEHOLDER}}` scan).

3. **`scripts/install-cli.ps1` / `reset.ps1` (CLI + Path handling)** —
   user-Path registry manipulation is Windows-only. POSIX: install to
   `~/.local/bin/claude-provider` (symlink or copy) and stay out of shell
   rc files; if `~/.local/bin` is not on PATH, say so and stop.

Everything else — validation, drift detection, sidecar, the merge
algorithm, list/current/doctor logic — is JSON manipulation with no OS
assumptions **except paths** (next section).

## The path problem (do this first)

`lib.ps1` builds paths like `Join-Path $home '.claude\provider-profiles'`.
On Linux/macOS a literal backslash is a *valid filename character*, so this
creates a directory named `.claude\provider-profiles` instead of nesting.
Sweep every literal `\` path segment into nested `Join-Path` calls (there
are also several in the scripts and tests). This is mechanical, testable,
and unblocks everything else.

## Runtime and test strategy (the real decision)

Recommendation: **PowerShell 7 (pwsh) as the single cross-platform
runtime**, not a parallel bash implementation. One codebase, and pwsh is a
one-line install on mac/brew and every Linux package manager. The
alternative (bash port sharing only the design contract) doubles every
future change; only choose it if requiring pwsh proves unacceptable to
real users.

Consequences to plan for:

- **Windows PowerShell 5.1 stays the Windows runtime** (it is what users
  have without installing anything), so the code must run on BOTH 5.1 and
  pwsh 7. That is why the source is frozen at 5.1-compatible syntax: no
  `&&`, no ternary, no `??`, no `-AsHashtable`. Do not modernize the
  syntax; you will silently drop 5.1.
- **Migrate the test suite from Pester 3.4 to Pester 5 first.** Pester 3.4
  does not run on pwsh; Pester 5 runs on both 5.1 and 7. This is the
  gateway task for the whole phase: after migration, add `ubuntu-latest`
  and `macos-latest` to the CI matrix and watch what breaks — that list IS
  the porting backlog. (`Should Be` becomes `Should -Be`, script-level
  helper functions must move into `BeforeAll`, `$TestDrive` semantics
  differ slightly.)
- The `commands/*.md` invocations hardcode `powershell.exe`. They need a
  launcher decision: either Claude Code resolves `pwsh` vs `powershell`
  per platform in each command file, or (cleaner) every command goes
  through one tiny dispatch script that picks the runtime.

## Scars — read before touching anything

Hard-won, all verified by tests or CI history. Ignore at your own risk:

1. **Windows PowerShell 5.1 reads BOM-less `.ps1` as ANSI.** One em-dash
   inside a double-quoted string decoded to a byte sequence containing a
   quote and broke parsing of an entire file. Hence the ASCII-only rule
   for executable files and the `ascii` CI job. Keep the rule until 5.1
   support is dropped; pwsh reads UTF-8 and will mask the bug on your
   machine while it detonates on users'.
2. **`@($list)` on a `List[object]` throws "Argument types do not match"
   on 5.1.** Use `.ToArray()` before `ConvertTo-Json`/PSCustomObject.
3. **Array splatting binds `-Fix`-style strings positionally.** That is
   why child scripts are invoked via `powershell -File` (which re-parses
   argument strings into real switches) instead of in-process calls.
   `Invoke-ChildScript` in lib.ps1 exists for this; use it.
4. **Never capture a function that streams child output.**
   `$code = Invoke-Step ...` swallowed stdout into the "return value"
   (provider-cli bug, fixed by passing the exit code via `$script:` scope).
5. **CI failed three times for three different reasons**: runner ships
   Pester 5 (pinned 3.4.0); runner wrapper sets
   `$ErrorActionPreference=Stop` which turns 2>&1-redirected *expected*
   stderr into terminating errors (helpers save/restore the preference);
   and the wrapper adopts a stale `$LASTEXITCODE` from intentionally
   failing child processes as the step result (explicit `exit 0`). The
   local repro for the second: run the suite under `Stop` yourself.
6. **cmd.exe misparses LF-only batch files** — render-helper forces CRLF
   on `.cmd` output regardless of checkout settings. The POSIX `.sh`
   render needs the mirror image: force LF, or the shebang dies on CRLF.
7. **`Get-ChildItem -Filter '*.json'` happily returns `.state.json`.**
   Anything enumerating profiles must go through `Get-ProfileFiles`.
8. **`New-Object PSObject -Property @{...}` with a `$null` value throws
   on 5.1** ("Argument types do not match"). Use `[PSCustomObject]@{}`.

## Unverified assumptions to test early

- `apiKeyHelper` exec behavior in Claude Code on macOS/Linux: we assume a
  chmod'd `.sh` path works (it matches Claude Code's documented model on
  POSIX), but v0.1's Windows `.cmd` assumption was only proven by a real
  switch. Prove the `.sh` end-to-end before building on it.
- Whether the gateway-auth story needs `Authorization: Bearer` support
  (`ANTHROPIC_AUTH_TOKEN` semantics) in addition to `apiKeyHelper`'s
  x-api-key. This came up in real use and was never resolved — if
  gateways reject x-api-key, no amount of porting matters. Investigate
  before or alongside Phase 2; it may force an `auth.style` field
  (and note: `ANTHROPIC_AUTH_TOKEN` is denylisted in extras on purpose —
  a Bearer token in `settings.local.json` would violate invariant 1, so
  the solution must go through a helper, not through env).

## Suggested order

1. Pester 3.4 → 5 migration; CI matrix `windows` (5.1) + `windows` (pwsh)
   — prove dual-runtime on one OS first.
2. Path portability sweep (nested Join-Path everywhere).
3. CI matrix + `ubuntu-latest` / `macos-latest`; fix what falls out.
4. Secret-store adapters (`security` / `secret-tool`) behind the four
   function names; decide the `credman` naming question.
5. POSIX shim render (`.sh`, chmod 700, LF) + real end-to-end apiKeyHelper
   verification on a mac.
6. POSIX install-cli / reset.
7. Docs, README platform matrix, v0.2.0.

Good luck. The test suite is the safety net — 103 tests, all real
behavior, no mocks of our own code. If a port change is correct, the
suite says so on every OS; if the suite disagrees with your reasoning,
trust the suite.
