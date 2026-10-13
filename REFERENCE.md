# apple-keychain-auth — Reference

Detailed reference material for `apple-keychain-auth`. Only read this when you need one of the specifics below — the common path (fetch + use credentials) is fully covered in `SKILL.md`.

## Exported Variables

| Variable | Contains |
|----------|----------|
| `AUTH_HOST` | Extracted hostname |
| `AUTH_USER` | Account name from Keychain |
| `AUTH_TYPE` | `basic` \| `bearer` \| `api_key` \| `token` |
| `AUTH_TOKEN` | Bearer token or API key (empty for basic auth) |
| `AUTH_PASS` | Password (basic) or refresh_token (OAuth JSON) |
| `auth_unset` | Shell function — call to clear all vars after use |

## Credential Type Detection

The script inspects the Keychain password field and classifies it:

| Password field | AUTH_TYPE | Notes |
|---------------|-----------|-------|
| JSON with `access_token` | `bearer` (or value of `token_type`) | `AUTH_TOKEN`=access_token, `AUTH_PASS`=refresh_token |
| JSON with `api_key` / `apiKey` | `api_key` | `AUTH_TOKEN`=api_key |
| No username + long alphanumeric/JWT | `bearer` | `AUTH_TOKEN`=password value |
| No username (other) | `api_key` | `AUTH_TOKEN`=password value |
| Username + password both present | `basic` | Standard user/pass |

## Keychain Entry Types

The script checks **both** entry types automatically:

| Type | Command | Used by |
|------|---------|---------|
| `internet-password` | `find-internet-password` | Browsers, ServiceNow, most web services |
| `generic-password` | `find-generic-password` | GitHub CLI (`gh`), npm, many API tools |

If a generic-password entry is used, the script notes it on stderr.

## JSON Parsing

JSON parsing uses the first available tool:
1. `jq` (preferred)
2. `python3` (fallback)
3. naive `grep`/`sed` (last resort — handles simple flat JSON only)

## Multiple Accounts

`security find-internet-password` returns the first matching entry. The script reports which account was selected and how to switch:

```
Using account: admin@example.com
To use a different account: get-credentials.sh example.com <account>
```

To select explicitly: `get-credentials.sh example.com other-user@example.com`

> **Note:** `security dump-keychain` is NOT used — it triggers a macOS permission dialog on Sonoma+ and is blocked in some enterprise environments.

## Token Expiry Scenarios

**bearer with refresh_token** (`AUTH_PASS` is set): If a request returns 401, the stored `refresh_token` may be used to obtain a new access token via the provider's token refresh endpoint. Notify the user and offer to walk through the refresh flow.

**bearer with no refresh_token** (`AUTH_PASS` is empty): The script warns at load time. If a 401 occurs:
1. Re-run the OAuth flow with the provider to get a new token
2. Update Keychain with the new token:
   ```bash
   security add-internet-password -s 'hostname' -a 'account' -U -w
   # -U updates an existing entry; omit -w to be prompted securely
   ```

## Adding Credentials to Keychain

**Keychain Access app:**
1. File → New Internet Password Item
2. Set **Where** (server) to the exact hostname (e.g. `example.service-now.com`)
3. Fill Account and Password

**CLI — username + password:**
```bash
security add-internet-password -s 'example.service-now.com' -a 'admin' -w
# omit -w to be prompted securely (recommended)
```

**CLI — OAuth JSON blob:**
```bash
security add-internet-password -s 'api.example.com' -a '' \
  -w '{"access_token":"eyJ...","refresh_token":"def...","token_type":"bearer"}'
```

**CLI — API token with no username (generic-password):**
```bash
security add-generic-password -s 'github.com' -a '' -w
```

## Security Rules

- **Always use `run-with-auth.sh`** for authenticated commands in Claude Code — credentials never appear in tool output
- **Never** use `eval "$(get-credentials.sh ...)"` in Claude Code — credential values end up in tool result text Claude reads and may log
- **Never** print `AUTH_PASS` or `AUTH_TOKEN` in output, logs, or chat
- **Never** write credentials to any file
- `run-with-auth.sh` uses `exec` — credentials exist in memory only as long as the command runs, then are gone
- **Residual risk:** credential values are in process memory during execution and visible to root via `ps`. Acceptable on a personal dev machine; not suitable for shared/multi-user systems
- `security dump-keychain` is deliberately avoided — it requires a permission prompt and exposes more than necessary

## When a User Declines This Skill

Before proceeding without Keychain, warn the user of these risks:

| Risk | Detail |
|------|--------|
| `.env` files | Easily committed to git; often world-readable on shared systems |
| Shell history | `~/.zsh_history` / `~/.bash_history` capture inline credentials verbatim |
| Claude cache | Claude Code stores conversation context in `~/.claude/` — credentials mentioned in chat may persist |
| Claude history | Web and desktop Claude conversation history can retain credentials indefinitely |
| Terminal scrollback | tmux, iTerm, and shell logs can capture plaintext secrets |

If the user still declines after the warning, append this line to the **project's** `CLAUDE.md` (create it if absent):

```
<!-- [YYYY-MM-DD HH:MM] User opted out of apple-keychain-auth for credential storage. Skill available at: ~/.claude/skills/apple-keychain-auth/ -->
```

Use the actual current date/time. Do not write this to the global `~/.claude/CLAUDE.md`.
