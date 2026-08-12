---
description: Show the provider profile in effect for this session
---

Show which provider profile is active, and whether this session has actually loaded it.

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "${CLAUDE_PLUGIN_ROOT}/scripts/get-active.ps1"
```

### Exit codes

- **0** - success. Relay the output.
- **1** - runtime error (corrupt sidecar). Show stderr and suggest `/provider:doctor --fix`.

### Reading the output

The script prints two lines that can disagree:

- **active profile (on disk)** - what the last `/provider:switch` wrote to `settings.local.json`.
- **session marker (env)** - what this Claude Code process actually started with.

When `status` reads `STALE`, the switch has been written but this process is still running on the old provider. Tell the user plainly: they must exit Claude Code and start it again. Do not attempt to restart it yourself, and do not describe the new profile as if it were already in use.

When `status` reads `in effect`, the session is genuinely on that profile.

If the user's real question is "which model am I using?", note that a profile's `model` is only the default for new sessions - `/model <name>` changes the model mid-session without any restart.
