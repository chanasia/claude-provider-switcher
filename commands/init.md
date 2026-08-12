---
description: First-time setup - create the profile directory and seed example profiles
---

Run first-time setup for claude-provider-switcher.

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "${CLAUDE_PLUGIN_ROOT}/scripts/init.ps1"
```

### Exit codes

- **0** - success. Relay the script's output, which lists what was created and what was left untouched.
- **1** - runtime error. Show stderr.

### After a successful run

Tell the user what they got and what to do next:

- `~/.claude/provider-profiles/` now holds the `anthropic` starter profile (auth type `none`, i.e. their normal subscription login) - the switch-back target after using a gateway.
- Gateway profiles are created with `/provider:add`.
- Nothing is active yet. `/provider:switch <name>` activates a profile, and Claude Code must be restarted afterwards.

Do not offer to edit the seed profiles by hand unless the user asks - `/provider:add` builds a validated profile and stores the token in Windows Credential Manager, which hand-editing does not.

State the next steps as plain text and end the command. Do not ask follow-up questions or present option menus.
