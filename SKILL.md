---
name: apple-keychain-auth
description: Use on macOS before reading .env files, hardcoded secrets, or asking the user for a password, API token, or auth header needed to call a specific hostname/API (e.g. curl, now-sdk deploy, a REST call). Skip for OAuth/SSO browser login flows, credentials the user already supplied inline, or non-macOS environments.
---

# apple-keychain-auth

## Overview

Retrieves credentials from macOS Keychain using the `security` CLI, classifies them (basic auth, bearer token, API key, OAuth JSON blob), and executes commands with auth injected — without exposing credential values to Claude Code or log files.

**Core rule:** Always use `run-with-auth.sh` when calling authenticated commands from Claude Code. Never use `get-credentials.sh` with `eval` in an agent context — that pattern exposes credential values in Claude's tool result text, which may be stored in `~/.claude/projects/` session files.

## Alternative credential store

If credentials are stored in **1Password** instead of macOS Keychain, use the `use-1password-cli` skill instead (`~/.claude/skills/use-1password-cli/`). Both skills export the same `AUTH_*` variables and the `run-with-auth.sh` pattern applies identically to both.

## Known limitation: process memory

Even with `run-with-auth.sh`, credential values exist briefly in process memory while the command executes. On macOS they are visible to root via `ps` or memory inspection for that short window. This is unavoidable without OS-level secret injection. Acceptable on a personal development machine; not appropriate for shared or multi-user systems.

## When to Use

- Any task requiring username/password, API token, or auth header for a remote host
- Before reading `.env` files, `~/.netrc`, or using hardcoded credential strings
- When `curl`, REST API calls, `now-sdk deploy`, or similar commands need auth

**Do NOT use when:**
- The task uses OAuth browser flow, SSO, or another explicit auth method

## Usage

### Preferred: `run-with-auth.sh` (safe for Claude Code)

Fetches credentials internally and executes the command directly. Credential values never appear in Claude's tool output, tool results, or session log files.

```bash
~/.claude/skills/apple-keychain-auth/run-with-auth.sh <hostname-or-url> [account] -- <command> [args...]
```

**For `curl`**, auth flags are injected automatically — do not include `-u` or `-H Authorization`:

```bash
# ServiceNow REST API (basic auth injected automatically)
~/.claude/skills/apple-keychain-auth/run-with-auth.sh example.service-now.com -- \
  curl -s https://example.service-now.com/api/now/table/incident?sysparm_limit=1

# GitHub API (bearer token injected automatically)
~/.claude/skills/apple-keychain-auth/run-with-auth.sh github.com -- \
  curl -s https://api.github.com/user

# Any other tool: credentials available as AUTH_PASS / AUTH_TOKEN in subprocess env
~/.claude/skills/apple-keychain-auth/run-with-auth.sh example.service-now.com -- \
  now-sdk deploy
```

### Alternative: `get-credentials.sh` with `eval` (interactive / human use only)

**Do not use this pattern in Claude Code** — the credential values appear in Claude's tool result text and may be stored in `~/.claude/projects/` session files.

```bash
# Human interactive terminal only
eval "$(~/.claude/skills/apple-keychain-auth/get-credentials.sh <hostname-or-url> [account])"
curl -u "$AUTH_USER:$AUTH_PASS" "https://$AUTH_HOST/api/..."
auth_unset
```

## Exported Variables

`AUTH_HOST`, `AUTH_USER`, `AUTH_TYPE` (`basic`|`bearer`|`api_key`|`token`), `AUTH_TOKEN`, `AUTH_PASS`, and an `auth_unset` cleanup function. See `REFERENCE.md` for the full table and how each `AUTH_TYPE` is detected.

## Further Reference

See `REFERENCE.md` (same directory) for: exported-variable details, credential-type detection rules, Keychain entry types, JSON parsing fallback order, handling multiple accounts, token expiry/refresh recovery, how to add credentials to Keychain, the full security rules list, and what to do when a user declines this skill. Only read it when the task actually needs one of those specifics.
