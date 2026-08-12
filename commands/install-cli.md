---
description: Install the offline `provider` CLI - the escape hatch for when a switch breaks the session
---

Install the standalone `provider` command-line tool.

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "${CLAUDE_PLUGIN_ROOT}/scripts/install-cli.ps1"
```

### Exit codes

- **0** - installed. Relay the script's output (it says whether Path changed and that a new terminal is needed).
- **1** - runtime error. Show stderr.

### Why this exists

Slash commands are interpreted by the model, so if a switch lands on a broken provider, `/provider:switch anthropic` cannot run - the session cannot respond at all. The `provider` CLI runs in plain PowerShell with no model and no network:

```
provider switch anthropic
provider doctor -Fix
provider list
```

Recommend installing it right after `/provider:init`, while everything still works.

State the result and end the command. Do not ask follow-up questions.
