# apple-keychain-auth · v0.1.0

A Claude Code skill that retrieves credentials from macOS Keychain and classifies them for immediate use in API calls — no `.env` files, no shell history exposure, no plaintext secrets in chat.

## What it does

- Accepts any hostname or full URL as input
- Searches both `internet-password` and `generic-password` Keychain entries
- Detects the credential type (basic auth, bearer token, API key, OAuth JSON blob)
- Exports ready-to-use environment variables
- Warns when a bearer token has no refresh token and may be expired

## Exported variables

| Variable | Contains |
|----------|----------|
| `AUTH_HOST` | Extracted hostname |
| `AUTH_USER` | Account name from Keychain |
| `AUTH_TYPE` | `basic` \| `bearer` \| `api_key` \| `token` |
| `AUTH_TOKEN` | Bearer token or API key |
| `AUTH_PASS` | Password (basic) or refresh_token (OAuth) |
| `auth_unset` | Shell function to clear all vars after use |

## Installation

```bash
# Clone into your Claude Code skills directory
git clone https://github.com/dalestubblefield/skill-apple-keychain-auth.git \
  ~/.claude/skills/apple-keychain-auth
```

Claude Code will automatically discover the skill via `SKILL.md`.

## Usage

```bash
# Load credentials into current shell
eval "$(~/.claude/skills/apple-keychain-auth/get-credentials.sh <hostname-or-url> [account])"

# Use with curl
curl -u "$AUTH_USER:$AUTH_PASS" "https://$AUTH_HOST/api/..."           # basic
curl -H "Authorization: Bearer $AUTH_TOKEN" "https://$AUTH_HOST/..."  # bearer
curl -H "X-API-Key: $AUTH_TOKEN" "https://$AUTH_HOST/..."             # api_key

# Clean up after use
auth_unset
```

## Adding credentials to Keychain

**Via Keychain Access app:**
1. File → New Internet Password Item
2. Set **Where** to the hostname (e.g. `gpinst01.service-now.com`)
3. Fill Account and Password

**Via CLI:**
```bash
# Username + password
security add-internet-password -s 'example.com' -a 'your-username' -w

# OAuth JSON blob
security add-internet-password -s 'api.example.com' -a '' \
  -w '{"access_token":"eyJ...","refresh_token":"def...","token_type":"bearer"}'

# API token with no username (generic-password)
security add-generic-password -s 'github.com' -a '' -w
```

Omitting `-w` will prompt for the password securely without it appearing in shell history.

## JSON parsing

Uses the first available tool: `jq` → `python3` → naive `grep`/`sed`. No hard dependencies.

## Requirements

- macOS (uses `security` CLI)
- Claude Code
