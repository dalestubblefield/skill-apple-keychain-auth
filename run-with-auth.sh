#!/usr/bin/env bash
# apple-keychain-auth: run-with-auth.sh
#
# Fetches credentials from macOS Keychain internally and executes a command
# with auth injected — credential values never appear in stdout, stderr, or
# any text Claude Code can capture or log.
#
# Usage:
#   run-with-auth.sh <hostname-or-url> [account] -- <command> [args...]
#
# For curl commands, auth flags are injected automatically based on credential type:
#   basic  → -u "user:pass"
#   bearer → -H "Authorization: Bearer <token>"
#   api_key→ -H "X-API-Key: <token>"
#   token  → -H "Authorization: Token <token>"
#
# For all other commands, credentials are available as env vars in the
# subprocess only: AUTH_HOST, AUTH_USER, AUTH_TYPE, AUTH_PASS, AUTH_TOKEN
# These never appear in Claude's tool output.
#
# Examples:
#   run-with-auth.sh example.service-now.com -- \
#     curl https://example.service-now.com/api/now/table/incident
#
#   run-with-auth.sh github.com -- \
#     curl -s https://api.github.com/user
#
#   run-with-auth.sh example.service-now.com admin -- \
#     now-sdk deploy

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# ── Parse arguments ───────────────────────────────────────────────────────────
# Accept: <hostname-or-url> [account] -- <command> [args...]

if [[ $# -lt 3 ]]; then
    echo "Usage: run-with-auth.sh <hostname-or-url> [account] -- <command> [args...]" >&2
    echo "" >&2
    echo "Examples:" >&2
    echo "  run-with-auth.sh host.example.com -- curl https://host.example.com/api" >&2
    echo "  run-with-auth.sh host.example.com admin@example.com -- curl https://host.example.com/api" >&2
    exit 1
fi

HOSTNAME_OR_URL="$1"
shift

# Check if second arg is an account or the -- separator
ACCOUNT=""
if [[ "$1" != "--" ]]; then
    ACCOUNT="$1"
    shift
fi

if [[ "${1:-}" != "--" ]]; then
    echo "Error: Expected '--' separator before command. Got: ${1:-<nothing>}" >&2
    echo "Usage: run-with-auth.sh <hostname-or-url> [account] -- <command> [args...]" >&2
    exit 1
fi
shift   # consume --

if [[ $# -eq 0 ]]; then
    echo "Error: No command specified after --" >&2
    exit 1
fi

CMD_ARGS=("$@")

# ── Load credentials into local vars (never printed to stdout) ────────────────

CRED_SCRIPT="$SCRIPT_DIR/get-credentials.sh"
if [[ ! -x "$CRED_SCRIPT" ]]; then
    echo "Error: get-credentials.sh not found or not executable at: $CRED_SCRIPT" >&2
    exit 1
fi

# eval into THIS script's shell only — these vars stay here, never go to stdout.
# stderr (account name, warnings, errors) passes through to the terminal unaffected.
if [[ -n "$ACCOUNT" ]]; then
    eval "$("$CRED_SCRIPT" "$HOSTNAME_OR_URL" "$ACCOUNT")" || exit 1
else
    eval "$("$CRED_SCRIPT" "$HOSTNAME_OR_URL")" || exit 1
fi

if [[ -z "${AUTH_TYPE:-}" ]]; then
    echo "Error: Failed to load credentials for '$HOSTNAME_OR_URL'" >&2
    exit 1
fi

# ── Build the command with auth injected ─────────────────────────────────────

COMMAND="${CMD_ARGS[0]}"
COMMAND_BASE="$(basename "$COMMAND")"

if [[ "$COMMAND_BASE" == "curl" ]]; then
    # Inject auth flags right after 'curl'. Values are in process memory —
    # not in the command string Claude sees — and gone when exec exits.
    case "$AUTH_TYPE" in
        basic)
            exec "$COMMAND" \
                --user "${AUTH_USER}:${AUTH_PASS}" \
                "${CMD_ARGS[@]:1}"
            ;;
        bearer)
            exec "$COMMAND" \
                -H "Authorization: Bearer ${AUTH_TOKEN}" \
                "${CMD_ARGS[@]:1}"
            ;;
        api_key)
            exec "$COMMAND" \
                -H "X-API-Key: ${AUTH_TOKEN}" \
                "${CMD_ARGS[@]:1}"
            ;;
        token)
            exec "$COMMAND" \
                -H "Authorization: Token ${AUTH_TOKEN}" \
                "${CMD_ARGS[@]:1}"
            ;;
        *)
            echo "Warning: Unknown AUTH_TYPE '$AUTH_TYPE' for curl — no auth injected." >&2
            exec "$COMMAND" "${CMD_ARGS[@]:1}"
            ;;
    esac
else
    # Non-curl: export credentials as env vars into the subprocess only.
    # Values exist in child process environment, not in Claude's captured output,
    # and are gone when the process exits.
    exec env \
        AUTH_HOST="$AUTH_HOST" \
        AUTH_USER="$AUTH_USER" \
        AUTH_TYPE="$AUTH_TYPE" \
        AUTH_PASS="$AUTH_PASS" \
        AUTH_TOKEN="$AUTH_TOKEN" \
        "${CMD_ARGS[@]}"
fi
