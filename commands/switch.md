---
description: Switch the active LLM provider profile (requires a Claude Code restart)
argument-hint: <profile-name>
---

Switch the active provider profile. `$1` is the profile name (required).

If `$1` is missing, run `/provider:list` output logic instead - show the available profiles and ask which one - and do NOT invoke the script with an empty name.

### Primary invocation

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "${CLAUDE_PLUGIN_ROOT}/scripts/apply-profile.ps1" $ARGUMENTS
```

### Exit codes

- **0** - success and this session's environment already matches. Confirm briefly and end.
- **1** - runtime error: another switch holds the lock, the sidecar is corrupt, the Credential Manager entry is missing, or the referenced environment variable is unset. Show stderr; it names which. For a missing credential, offer to store one (see **Storing a credential** below). Do not retry blindly.
- **2** - usage error. Show stderr and end.
- **3** - profile not found. The script lists available profiles (and hints) on stderr; relay that and END. Do not present an options menu or ask what to do next - the user can type the command again with the name they want.
- **6** - profile failed schema validation. Show the specific rules that failed and end.
- **8** - drift detected. Enter the **Drift Confirm Flow** below.
- **9** - success, but this session is stale. Enter the **Restart Flow** below.

After any terminal outcome, end the command. Never append "next step" menus or unsolicited follow-up questions; the only interactive flow in this command is the Drift Confirm Flow.

### Drift Confirm Flow (exit 8)

Exit 8 means keys the plugin manages in `settings.local.json` were changed by something other than this plugin since the last switch. The script has already printed which keys on stderr. Relay that list, then use `AskUserQuestion` with exactly these options:

1. **Overwrite** - re-invoke with `-AcceptDrift overwrite`. The new profile's values win everywhere; the hand-edits are discarded.
2. **Incorporate** - re-invoke with `-AcceptDrift incorporate`. Hand-edited keys that the new profile does not manage are preserved as unmanaged settings; everything else takes the new profile's values. A drifted `apiKeyHelper` can never be incorporated - if that is what drifted, the script will exit 8 again saying so, and only Overwrite or Cancel apply.
3. **Cancel** - stop. Nothing changes.

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "${CLAUDE_PLUGIN_ROOT}/scripts/apply-profile.ps1" <name> -AcceptDrift <overwrite|incorporate>
```

Handle the new exit code as above (normally 9). Do not loop on drift more than once per command - if it is still 8 after one retry, the file changed again underneath; tell the user and stop.

### Restart Flow (exit 9)

The profile was written successfully, but Claude Code reads provider environment variables only at process startup, so this session is still on the old provider. State it in one plain line and end the command:

> Switched to '<name>'. Exit Claude Code and start it again to activate.

There is no decision to make here, so do NOT use `AskUserQuestion`. Never attempt to restart Claude Code yourself, and never imply the new provider is already active.

### Storing a credential (exit 1, credman auth)

When the failure is a missing Credential Manager entry, the token must be stored before the switch can succeed. Ask the user to paste the token, then store it without echoing it back:

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "${CLAUDE_PLUGIN_ROOT}/scripts/set-credential.ps1" -Target "<target>" -Secret "<token>"
```

Never write the token into a profile file, a settings file, or any file in the repository. After storing it, re-run the switch.
