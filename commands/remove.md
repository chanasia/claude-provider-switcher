---
description: Delete a provider profile
argument-hint: <profile-name>
---

Delete a provider profile. `$1` is the profile name (required).

If `$1` is missing, list the profiles and ask which one; do not invoke the script with an empty name.

### Confirm first

Deleting is not reversible from inside the plugin. Before invoking, confirm with `AskUserQuestion` - state the profile name and, if the profile uses `credman`, whether the stored credential should be deleted too.

- **Keep the credential** (default) - the Credential Manager entry stays. Correct when the same target is shared with another profile or may be reused.
- **Delete the credential too** - pass `-DeleteCredential`.

### Invocation

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "${CLAUDE_PLUGIN_ROOT}/scripts/remove-profile.ps1" $ARGUMENTS
```

### Exit codes

- **0** - removed. The profile file and its rendered helper shims are gone. Relay the output, which states what happened to the credential.
- **1** - runtime error. Show stderr.
- **2** - usage error. Show stderr.
- **3** - profile not found. List the available profiles.
- **5** - the profile is currently active and was not removed. Tell the user to switch to another profile first (`/provider:switch <other>`), then remove this one. Do not offer to force it - there is no force, by design: a live `settings.local.json` must never point at a profile that no longer exists.
