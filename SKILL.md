---
name: apple-keychain-auth
description: Use when any task requires credentials, API tokens, passwords, or authentication for a web service, API, or hostname. Use before checking .env files, hardcoded values, or asking the user for credentials. Applies to ServiceNow instances, GitHub, REST APIs, databases, or any URL-based service requiring auth.
---

# apple-keychain-auth

## Overview

Retrieves credentials from macOS Keychain using the `security` CLI, classifies them (basic auth, bearer token, API key, OAuth JSON blob), and exports the right variables for immediate use.

**Core rule:** Never store, echo, log, or display credentials in plaintext in files, terminal output, or chat messages.

## When to Use

- Any task requiring username/password, API token, or auth header for a remote host
- Before reading `.env` files, `~/.netrc`, or using hardcoded credential strings
- When `curl`, REST API calls, `now-sdk deploy`, or similar commands need auth

**Do NOT use when:**
- Credentials are already set in the current shell from this skill (`AUTH_HOST` is set)
- The task uses OAuth browser flow, SSO, or another explicit auth method

## Usage

```bash
# Load credentials into current shell
eval "$(~/.claude/skills/apple-keychain-auth/get-credentials.sh <hostname-or-url> [account])"

# Use the exported vars
curl -u "$AUTH_USER:$AUTH_PASS" "https://$AUTH_HOST/api/..."           # basic
curl -H "Authorization: Bearer $AUTH_TOKEN" "https://$AUTH_HOST/..."  # bearer
curl -H "X-API-Key: $AUTH_TOKEN" "https://$AUTH_HOST/..."             # api_key

# Clean up after sensitive operations
auth_unset
```

**Examples:**

```bash
# ServiceNow instance (basic auth)
eval "$(get-credentials.sh gpinst01.service-now.com)"

# Full URL — hostname extracted automatically
eval "$(get-credentials.sh https://aifoundrydev.service-now.com/)"

# Specific account when multiple exist for the same host
eval "$(get-credentials.sh api.example.com admin@example.com)"

# GitHub CLI / npm tokens (stored as generic-password, auto-detected)
eval "$(get-credentials.sh github.com)"
```

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
2. Set **Where** (server) to the exact hostname (e.g. `gpinst01.service-now.com`)
3. Fill Account and Password

**CLI — username + password:**
```bash
security add-internet-password -s 'gpinst01.service-now.com' -a 'admin' -w
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

- **Never** print `AUTH_PASS` or `AUTH_TOKEN` in output, logs, or chat
- **Never** write credentials to any file
- Variables are shell-scoped — they vanish when the terminal closes
- Call `auth_unset` after sensitive operations to clear vars immediately
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
