---
description: Create a new provider profile (stores the token in Windows Credential Manager)
---

Create a new provider profile interactively. Gather the fields with `AskUserQuestion`, then call the script once with everything filled in.

This wizard is for **gateway/proxy profiles**. Do not offer "Anthropic direct" as an endpoint choice: the seeded `anthropic` profile already covers it, and a second auth:none profile adds nothing. The one exception - the user explicitly asks for an Anthropic-direct variant with a different default model (e.g. `anthropic-opus`) - is theirs to raise, not yours to suggest. If the user seems to want Anthropic direct and the `anthropic` profile is missing, point them to `/provider:init` instead.

### Step 1 - collect the fields

Ask only what you need, and prefer one `AskUserQuestion` call with several questions over a long back-and-forth.

| Field | How to get it |
|---|---|
| `name` | Profile identifier. Must match `^[a-z0-9][a-z0-9-]{0,62}$` - lowercase letters, digits, hyphens. Suggest one derived from the endpoint (e.g. `work-gateway`). |
| `description` | Optional, one line, at most 200 characters. |
| `base_url` | The Anthropic-compatible endpoint. Must be `https://` unless the host is `localhost` or `127.0.0.1`. If other gateway profiles already exist, offer their endpoint as the default choice. |
| `auth type` | `credman` for a token in Windows Credential Manager (recommended); `env_var` for a token already in an environment variable. (`none` exists but belongs to the seeded `anthropic` profile - see above.) |
| `model` | Optional default model for new sessions. Ask only when a `base_url` was given, since gateway model names are specific to the gateway. |
| `ttl_ms` | Optional. Only worth asking about when the gateway issues short-lived tokens; 300000 (5 min) is a reasonable default. Skip otherwise. |
| `extras` | Optional extra environment variables as `KEY=VALUE`. Do not offer this unprompted. |

For `credman`, also ask for the **token itself**, and pick a target name of the form `claude-provider/<profile-name>` unless the user wants another.

For `env_var`, ask for the variable name (uppercase, `^[A-Z_][A-Z0-9_]*$`). Do not ask for the token - it is already in the environment.

### Step 2 - store the token first (credman only)

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "${CLAUDE_PLUGIN_ROOT}/scripts/set-credential.ps1" -Target "<target>" -Secret "<token>"
```

Never echo the token back to the user, never write it into any file, and never include it in a summary. If this fails (exit 1), stop and report - do not create a profile whose credential is missing.

### Step 3 - create the profile

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "${CLAUDE_PLUGIN_ROOT}/scripts/create-profile.ps1" -Name <name> -AuthType <none|credman|env_var> [-Description "<text>"] [-BaseUrl <url>] [-Model <name>] [-CredTarget <target>] [-EnvVar <VAR>] [-TtlMs <int>] [-Extra KEY=VALUE]
```

Repeat `-Extra KEY=VALUE` once per extra variable.

### Exit codes

- **0** - created. Relay the script's output.
- **1** - runtime error. Show stderr.
- **2** - usage error (missing required field for the chosen auth type). Fix the arguments and retry once.
- **4** - a profile with that name already exists. Ask whether to pick a different name or overwrite; only pass `-Force` if the user explicitly chooses to overwrite.
- **6** - the profile would fail validation. The script prints each violated rule and writes nothing. Show the rules, correct the input, and retry.

### After creating

The new profile is **not** active. State in plain text that `/provider:switch <name>` (plus a restart) activates it, then end the command. Do not ask whether to switch now, and do not present option menus - the wizard questions in Step 1 are the only questions this command asks.
