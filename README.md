# apple-keychain-auth · v0.1.0

A Claude Code skill that retrieves and classifies credentials from macOS Keychain for use in API calls, database connections, and service authentication.

> **Private skill** — This skill is maintained by Dale Stubblefield for personal use and trusted friends. It is not intended for general public consumption.

## Install from the marketplace

Install this skill through [dales-claude-marketplace](https://github.com/dalestubblefield/dales-claude-marketplace) rather than directly from this repo. The marketplace manages versioning, dependencies, and updates across all skills as a single install.

```bash
claude plugin add dalestubblefield/dales-claude-marketplace
```

Installing directly from this repo is not recommended — you'll miss updates and won't get the rest of the marketplace skills.

## What it does

- Looks up credentials in macOS Keychain using the `security` CLI
- Classifies them automatically (basic auth, bearer token, API key, OAuth JSON)
- Exports shell variables (`AUTH_HOST`, `AUTH_USER`, `AUTH_TYPE`, `AUTH_TOKEN`, `AUTH_PASS`) for immediate use in `curl`, REST calls, and similar commands
- Never stores, logs, or displays credentials in plaintext
