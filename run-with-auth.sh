#!/usr/bin/env bash
# apple-keychain-auth: run-with-auth.sh
#
# Fetches credentials from macOS Keychain internally and executes a command
# with auth injected. This script itself never prints credential values. The
# command it runs does receive them, so it must not echo them: curl flags that
# print request headers (-v, --trace) are refused, and so are commands that
# only dump their environment (env, printenv, echo, printf).
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
# curl requests must go to the credential's host: every URL must be https and
# its host must equal <hostname> or be a subdomain of it. There is no flag to
# widen this.
#
# For all other commands, credentials are available as env vars in the
# subprocess only: AUTH_HOST, AUTH_USER, AUTH_TYPE, AUTH_PASS, AUTH_TOKEN
# They reach Claude's tool output only if that command prints them.
#
# Examples:
#   run-with-auth.sh example.service-now.com -- \
#     curl https://example.service-now.com/api/now/table/incident
#
#   run-with-auth.sh github.com -- \
#     curl -s https://api.github.com/user     # subdomain of the credential host
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

# Start clean so a failed lookup can never fall back to AUTH_* values that were
# already in the environment.
unset AUTH_HOST AUTH_USER AUTH_TYPE AUTH_PASS AUTH_TOKEN

# Capture first so a failing lookup stops here; eval of an empty string succeeds.
# stderr (account name, warnings, errors) passes through to the terminal unaffected.
if [[ -n "$ACCOUNT" ]]; then
    CRED_EXPORTS="$("$CRED_SCRIPT" "$HOSTNAME_OR_URL" "$ACCOUNT")" || exit 1
else
    CRED_EXPORTS="$("$CRED_SCRIPT" "$HOSTNAME_OR_URL")" || exit 1
fi

# eval into THIS script's shell only — these vars stay here, never go to stdout.
eval "$CRED_EXPORTS"
unset CRED_EXPORTS

if [[ -z "${AUTH_TYPE:-}" || -z "${AUTH_HOST:-}" ]]; then
    echo "Error: Failed to load credentials for '$HOSTNAME_OR_URL'" >&2
    exit 1
fi

# ── Build the command with auth injected ─────────────────────────────────────

COMMAND="${CMD_ARGS[0]}"
COMMAND_BASE="$(basename "$COMMAND")"

refuse() {
    echo "Error: $1" >&2
    exit 1
}

if [[ "$COMMAND_BASE" == "curl" ]]; then
    # ── Bind the request to the credential's host ────────────────────────────
    CRED_HOST="$(printf '%s' "$AUTH_HOST" | tr '[:upper:]' '[:lower:]')"
    URL_COUNT=0
    for arg in "${CMD_ARGS[@]:1}"; do
        case "$arg" in
            -K|--config|--location-trusted|--proto|--proto-redir|--proto-default)
                refuse "curl option '$arg' is not allowed with injected credentials." ;;
            --verbose|--trace|--trace-ascii|--trace-config)
                refuse "curl option '$arg' prints request headers, which would expose the credential." ;;
            --location)
                [[ "$AUTH_TYPE" == "api_key" ]] && refuse "redirects are not followed with an API-key header; curl would resend it to another host." ;;
        esac
        # Short-option clusters such as -sv or -sL
        if [[ "$arg" =~ ^-[A-Za-z0-9]+$ ]]; then
            [[ "$arg" == *v* ]] && refuse "curl -v prints request headers, which would expose the credential."
            [[ "$arg" == *K* ]] && refuse "curl -K is not allowed with injected credentials."
            [[ "$arg" == *L* && "$AUTH_TYPE" == "api_key" ]] && refuse "redirects are not followed with an API-key header; curl would resend it to another host."
        fi
        if [[ "$arg" =~ ^[A-Za-z][A-Za-z0-9+.-]*:// ]]; then
            URL_COUNT=$((URL_COUNT + 1))
            [[ "$arg" =~ ^[Hh][Tt][Tt][Pp][Ss]:// ]] || refuse "only https URLs are allowed with injected credentials."
            authority="${arg#*://}"
            authority="${authority%%[/?#]*}"
            [[ "$authority" == *@* ]] && refuse "URLs with embedded user info are not allowed."
            url_host="$(printf '%s' "${authority%%:*}" | tr '[:upper:]' '[:lower:]')"
            if [[ "$url_host" != "$CRED_HOST" && "$url_host" != *".$CRED_HOST" ]]; then
                refuse "URL host '$url_host' does not match the credential host '$CRED_HOST'."
            fi
        fi
    done
    [[ $URL_COUNT -gt 0 ]] || refuse "no https:// URL found in the curl command; write the URL with its scheme."

    # --proto pins every request, including scheme-less URLs and redirects, to
    # https. Auth flags follow. Values are in process memory, not in the command
    # string Claude sees, and gone when exec exits.
    set -- --proto '=https' --proto-redir '=https'
    case "$AUTH_TYPE" in
        basic)
            exec "$COMMAND" "$@" \
                --user "${AUTH_USER}:${AUTH_PASS}" \
                "${CMD_ARGS[@]:1}"
            ;;
        bearer)
            exec "$COMMAND" "$@" \
                -H "Authorization: Bearer ${AUTH_TOKEN}" \
                "${CMD_ARGS[@]:1}"
            ;;
        api_key)
            exec "$COMMAND" "$@" \
                -H "X-API-Key: ${AUTH_TOKEN}" \
                "${CMD_ARGS[@]:1}"
            ;;
        token)
            exec "$COMMAND" "$@" \
                -H "Authorization: Token ${AUTH_TOKEN}" \
                "${CMD_ARGS[@]:1}"
            ;;
        *)
            refuse "unknown AUTH_TYPE '$AUTH_TYPE'; refusing to send the request without auth."
            ;;
    esac
else
    # Non-curl: export credentials as env vars into the subprocess only. The
    # child can read them, so refuse commands whose only job is to print.
    case "$COMMAND_BASE" in
        env|printenv|echo|printf)
            refuse "'$COMMAND_BASE' would print the credential into captured output." ;;
    esac
    exec env \
        AUTH_HOST="$AUTH_HOST" \
        AUTH_USER="$AUTH_USER" \
        AUTH_TYPE="$AUTH_TYPE" \
        AUTH_PASS="$AUTH_PASS" \
        AUTH_TOKEN="$AUTH_TOKEN" \
        "${CMD_ARGS[@]}"
fi
