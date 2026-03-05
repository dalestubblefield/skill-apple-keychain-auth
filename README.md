# apple-keychain-auth · v0.1.0

> **Recommended:** Install this skill through the [AI Foundry Marketplace](https://github.com/Now-AI-Foundry/marketplace-cc-skills#installing-this-marketplace) — it bundles all AI Foundry skills together. Just tell Claude Code: _"Install the AI Foundry marketplace"_ and it will handle the rest.

**Keep credentials out of your codebase, your shell history, and your chat.**

A Claude Code skill that retrieves credentials from macOS Keychain and puts them to work immediately — no `.env` files, no plaintext secrets in chat, no tokens leaking into `~/.zsh_history`.

Every time credentials come up in a session, this skill nudges Claude toward Keychain. Over time, your Claude Code environment becomes progressively more secure without any single big migration effort. The `auth_unset` function clears exported vars from shell memory after use, minimizing even the in-session exposure window.

---

## How it works

```
You: "Deploy to gpinst01"
Claude: [invokes apple-keychain-auth for gpinst01.service-now.com]
        → finds internet-password in Keychain
        → exports AUTH_USER, AUTH_PASS, AUTH_TYPE
        → runs deployment
        → calls auth_unset to clear vars
```

1. Accepts any hostname or full URL
2. Searches `internet-password` and `generic-password` Keychain entries
3. Detects the credential type — basic auth, bearer token, API key, OAuth JSON blob
4. Exports ready-to-use environment variables
5. Warns when a bearer token has no refresh token and may be expired

---

## Exported variables

| Variable | Contains |
|----------|----------|
| `AUTH_HOST` | Extracted hostname |
| `AUTH_USER` | Account name from Keychain |
| `AUTH_TYPE` | `basic` · `bearer` · `api_key` · `token` |
| `AUTH_TOKEN` | Bearer token or API key |
| `AUTH_PASS` | Password (basic auth) or refresh_token (OAuth) |
| `auth_unset` | Shell function — call after use to wipe all vars |

---

## Installation

### Via AI Foundry Marketplace (recommended)

```
/plugin install apple-keychain-auth@marketplace-cc-skills
```

### Manual

```bash
git clone https://github.com/dalestubblefield/skill-apple-keychain-auth.git \
  ~/.claude/skills/apple-keychain-auth
```

Claude Code automatically discovers the skill via `SKILL.md`.

---

## Usage

```bash
# Load credentials into current shell
eval "$(~/.claude/skills/apple-keychain-auth/get-credentials.sh <hostname-or-url> [account])"

# basic auth
curl -u "$AUTH_USER:$AUTH_PASS" "https://$AUTH_HOST/api/..."

# bearer token
curl -H "Authorization: Bearer $AUTH_TOKEN" "https://$AUTH_HOST/..."

# API key
curl -H "X-API-Key: $AUTH_TOKEN" "https://$AUTH_HOST/..."

# Always clean up after sensitive operations
auth_unset
```

---

## Adding credentials to Keychain

**Via Keychain Access app:**
1. File → New Internet Password Item
2. Set **Where** to the hostname (e.g. `gpinst01.service-now.com`)
3. Fill in Account and Password

**Via terminal:**
```bash
# Username + password (omit -w to be prompted securely)
security add-internet-password -s 'example.com' -a 'your-username' -w

# OAuth JSON blob
security add-internet-password -s 'api.example.com' -a '' \
  -w '{"access_token":"eyJ...","refresh_token":"def...","token_type":"bearer"}'

# API token stored as generic-password
security add-generic-password -s 'github.com' -a '' -w
```

Omitting `-w` prompts for the password interactively — nothing appears in shell history.

---

## Why this matters

Claude Code caches conversation context in `~/.claude/projects/`. Any credential that appears in chat — even briefly — can persist in those files indefinitely. This skill keeps credentials in Keychain where they belong, so they never need to touch the conversation at all.

**Security hygiene tip:** Periodically delete Claude Code session files older than a week to shred any credentials that may have slipped through.

---

## Requirements

- macOS (uses the built-in `security` CLI)
- Claude Code

## JSON parsing

Uses the first available tool: `jq` → `python3` → naive `grep`/`sed`. No hard dependencies beyond what ships with macOS.
