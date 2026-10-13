# apple-keychain-auth

This repo contains a single Claude Code skill. The skill files are:

- `SKILL.md` — skill definition loaded by Claude Code (frontmatter + core usage path only)
- `REFERENCE.md` — detail material split out of SKILL.md to keep per-invocation context cost low: credential-type detection, Keychain entry types, JSON parsing fallback, multi-account handling, token expiry recovery, adding credentials, full security rules, decline-handling. SKILL.md points here; only load it when a task needs one of those specifics.
- `get-credentials.sh` — bash implementation of the credential lookup logic
- `run-with-auth.sh` — wrapper that injects credentials into a single command without printing them
- `README.md` — human-facing documentation

## Development guidelines

- `get-credentials.sh` must remain standalone with no required dependencies beyond `security` (macOS built-in). `jq` and `python3` are used when available but must degrade gracefully.
- `run-with-auth.sh` is the **preferred path for Claude Code** — use it instead of `eval "$(get-credentials.sh ...)"` to keep credential values out of tool output and session logs.
- Never add logic that prints, logs, or returns credential values in plaintext to stdout. All diagnostic output goes to stderr.
- The `auth_unset` function is emitted by `get-credentials.sh` for human interactive use; it does not apply to `run-with-auth.sh`.
- Test changes against both `internet-password` and `generic-password` Keychain entry types.
- `SKILL.md` description field must stay under 1024 characters total and must NOT summarize the skill workflow — only triggering conditions.

## Alternative credential store

If credentials are in **1Password** rather than macOS Keychain, use `use-1password-cli` (`~/.claude/skills/use-1password-cli/`). Both skills export identical `AUTH_*` variables.

## run-with-auth.sh guarantees

- curl requests go only to the credential host or a subdomain of it, over https. There is no flag or environment variable to widen this; do not add one.
- Inherited `AUTH_*` values are cleared before the lookup, and a failed lookup or unknown `AUTH_TYPE` stops the run.
- curl flags that print request headers are refused. For non-curl commands the child process still receives the credentials and can print them; only `env`, `printenv`, `echo` and `printf` are refused outright.

## Known limitation

Credential values exist in process memory during `run-with-auth.sh` execution and are visible to root via `ps`. Acceptable on a personal dev machine; not appropriate for shared/multi-user systems.

## Testing

```bash
# Preferred: test via run-with-auth.sh (safe — no credentials in output)
./run-with-auth.sh <your-hostname> -- curl -s -o /dev/null -w "HTTP %{http_code}" https://<your-hostname>/

# Interactive test (human terminal only — do not run via Claude Code Bash tool)
eval "$(./get-credentials.sh <your-hostname>)"
echo "Type: $AUTH_TYPE | User: $AUTH_USER"
auth_unset
```

## Versioning

Version is tracked in the badge at the top of `README.md` and in its Version Milestones section. For behavior changes, bump the badge and add a milestone line.
