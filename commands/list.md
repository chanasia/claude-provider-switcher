---
description: List all provider profiles and show which one is active
---

List every configured provider profile.

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "${CLAUDE_PLUGIN_ROOT}/scripts/list-profiles.ps1"
```

### Exit codes

- **0** - success. Relay the listing. `*` marks the profile that is active on disk.
- **1** - runtime error (corrupt sidecar). Show stderr and suggest `/provider:doctor --fix`.
- **3** - the profile directory does not exist. Tell the user to run `/provider:init` first; do not create anything yourself.

### Notes

Profiles contain references only (Credential Manager target names, environment variable names) - never tokens - so the listing is safe to show in full. Do not redact it.

Active-on-disk is not the same as active-in-this-session. If the user asks which provider they are actually talking to right now, run `/provider:current` instead - it compares the two.
