---
description: Diagnose provider profile problems, optionally repairing what is safe to repair
argument-hint: [--fix]
---

Diagnose the plugin's on-disk state.

### Invocation

Without arguments:

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "${CLAUDE_PLUGIN_ROOT}/scripts/doctor.ps1"
```

When the user passed `--fix`:

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "${CLAUDE_PLUGIN_ROOT}/scripts/doctor.ps1" -Fix
```

### Exit codes

- **0** - no errors (warnings may still be present). Relay the report.
- **1** - at least one error. Relay the report and help with the specific errors.

### What it checks

Profile directory and sidecar exist and parse; every profile validates; the active profile still exists; its helper shims are present; its auth reference resolves (credential stored / environment variable set); `settings.local.json` parses and still matches what the plugin wrote (drift); `apiKeyHelper` points at a real file; no orphaned shims, stale temp files, or stale locks.

It never runs a helper shim and never reads a secret's value - existence checks only.

### What `--fix` will and will not do

Repairs: recreates a missing or corrupt sidecar, re-renders missing helper shims, removes orphaned shims and stale temp files, clears a stale lock.

Does **not** repair drift. Drift means someone hand-edited plugin-managed settings, and choosing what wins is the user's call - route that through `/provider:switch <name>`, which offers Overwrite / Incorporate / Cancel. If `--fix` reset a corrupt sidecar, tell the user to re-run `/provider:switch <name>` so the plugin knows what it manages again.

Does not fix a malformed `settings.local.json`. The plugin refuses to overwrite a file it cannot parse; that one needs a hand edit.

After relaying the report (and helping with any errors it names), end the command. Do not ask follow-up questions or offer "next step" menus.
