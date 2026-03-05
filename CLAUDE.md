# apple-keychain-auth

This repo contains a single Claude Code skill. The skill files are:

- `SKILL.md` — skill definition loaded by Claude Code (frontmatter + usage reference)
- `get-credentials.sh` — bash implementation of the credential lookup logic
- `README.md` — human-facing documentation

## Development guidelines

- `get-credentials.sh` must remain a standalone bash script with no required dependencies beyond `security` (macOS built-in). `jq` and `python3` are used when available but must degrade gracefully.
- Never add logic that prints, logs, or returns credential values in plaintext to stdout. All diagnostic output goes to stderr.
- The `auth_unset` function must always be emitted as part of `eval` output so callers can clean up.
- Test changes against both `internet-password` and `generic-password` Keychain entry types.
- `SKILL.md` description field must stay under 1024 characters total and must NOT summarize the skill workflow — only triggering conditions.

## Testing

```bash
# Verify script is executable
ls -la get-credentials.sh

# Dry-run parse (no Keychain lookup)
bash -n get-credentials.sh

# Live test against a known Keychain entry
eval "$(./get-credentials.sh <your-hostname>)"
echo "Type: $AUTH_TYPE | User: $AUTH_USER"
auth_unset
```

## Versioning

Version is tracked as `vX.Y.Z` in the `# Title · vX.Y.Z` line of `README.md`. Bump manually when making meaningful changes.
