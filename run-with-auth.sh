#!/usr/bin/env bash
# apple-keychain-auth: run-with-auth.sh
#
# Fetches credentials from macOS Keychain internally and executes a command
# with auth injected. This script itself never prints credential values. The
# command it runs does receive them, so it must not echo them. For curl only a
# fixed list of options is accepted, which excludes everything that prints
# request headers. For other commands nothing can stop the child printing its
# own environment; the check for env/printenv/echo/printf catches slips, it is
# not a security boundary.
#
# Usage:
#   run-with-auth.sh <hostname-or-url> [account] -- <command> [args...]
#
# For curl commands, auth is injected automatically based on credential type,
# through a config stream rather than the command line:
#   basic  → user:pass
#   bearer → Authorization: Bearer <token>
#   api_key→ X-API-Key: <token>
#   token  → Authorization: Token <token>
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
    # ── Allowlist the curl command line ──────────────────────────────────────
    # Only the options below are accepted, spelled exactly. A denylist cannot
    # work here: curl accepts any unambiguous abbreviation of a long option.
    # Every argument that is not an option or an option's value must be an
    # https URL on the credential's host.
    CRED_HOST="$(printf '%s' "$AUTH_HOST" | tr '[:upper:]' '[:lower:]')"
    case "$AUTH_TYPE" in
        basic|bearer) REDIRECT_OK=1 ;;   # curl does not resend these to another host
        api_key|token) REDIRECT_OK=0 ;;  # plain headers would follow the redirect
        *) refuse "unknown AUTH_TYPE '$AUTH_TYPE'; refusing to send the request without auth." ;;
    esac

    check_url() {
        local url="$1" authority host
        [[ "$url" =~ ^[Hh][Tt][Tt][Pp][Ss]:// ]] || refuse "'$url' is not an https:// URL. Write URLs with their scheme; only https is allowed with injected credentials."
        authority="${url#*://}"
        authority="${authority%%[/?#]*}"
        [[ "$authority" == *@* ]] && refuse "URLs with embedded user info are not allowed."
        host="$(printf '%s' "${authority%%:*}" | tr '[:upper:]' '[:lower:]')"
        [[ "$host" =~ ^[a-z0-9]([a-z0-9.-]*[a-z0-9])?$ ]] || refuse "could not read a plain hostname from '$url'."
        if [[ "$host" != "$CRED_HOST" && "$host" != *".$CRED_HOST" ]]; then
            refuse "URL host '$host' does not match the credential host '$CRED_HOST'."
        fi
        URL_COUNT=$((URL_COUNT + 1))
    }

    need_redirect_ok() {
        [[ $REDIRECT_OK -eq 1 ]] || refuse "redirects are not followed with this credential type; curl would resend the header to another host."
    }

    URL_COUNT=0
    # --write-out can print parts of the URL and request; keep it to plain
    # status fields.
    check_format() {
        case "$1" in *'%{url'*|*'%{json'*|*'%{stderr'*|*'%output'*|@*)
            refuse "that --write-out format is not allowed with injected credentials." ;;
        esac
    }

    EXPECT=""   # "", "value", "format" or "url": what the next argument is
    for arg in "${CMD_ARGS[@]:1}"; do
        if [[ -n "$EXPECT" ]]; then
            [[ "$EXPECT" == "url" ]] && check_url "$arg"
            [[ "$EXPECT" == "format" ]] && check_format "$arg"
            EXPECT=""
            continue
        fi
        case "$arg" in
            --silent|--show-error|--fail|--fail-with-body|--include|--globoff|--get|--head|--compressed|--no-progress-meter) ;;
            --location) need_redirect_ok ;;
            --request|--header|--data|--data-raw|--data-binary|--data-urlencode|--json|--output|--max-time|--connect-timeout|--form|--user-agent|--retry) EXPECT="value" ;;
            --write-out) EXPECT="format" ;;
            --url) EXPECT="url" ;;
            --*) refuse "curl option '$arg' is not on the allowed list for injected credentials." ;;
            -?*)
                cluster="${arg#-}"
                while [[ -n "$cluster" ]]; do
                    c="${cluster:0:1}"
                    cluster="${cluster:1}"
                    case "$c" in
                        s|S|f|i|g|G|I) ;;
                        L) need_redirect_ok ;;
                        X|H|d|o|m|F|A)
                            # rest of the cluster is the value; otherwise the next argument is
                            [[ -z "$cluster" ]] && EXPECT="value"
                            cluster="" ;;
                        w)
                            if [[ -z "$cluster" ]]; then EXPECT="format"; else check_format "$cluster"; fi
                            cluster="" ;;
                        *) refuse "curl option '-$c' is not on the allowed list for injected credentials." ;;
                    esac
                done ;;
            *) check_url "$arg" ;;
        esac
    done
    [[ -z "$EXPECT" ]] || refuse "the last curl option is missing its value."
    [[ $URL_COUNT -gt 0 ]] || refuse "no URL found in the curl command."

    # Hand the credential to curl through a config stream, not the command
    # line, so it never shows up in the process list.
    cfg_quote() {
        local s="$1"
        s=${s//\\/\\\\}
        s=${s//\"/\\\"}
        printf '%s' "$s"
    }
    auth_config() {
        case "$AUTH_TYPE" in
            basic)   printf 'user = "%s:%s"\n' "$(cfg_quote "$AUTH_USER")" "$(cfg_quote "$AUTH_PASS")" ;;
            bearer)  printf 'oauth2-bearer = "%s"\n' "$(cfg_quote "$AUTH_TOKEN")" ;;
            api_key) printf 'header = "X-API-Key: %s"\n' "$(cfg_quote "$AUTH_TOKEN")" ;;
            token)   printf 'header = "Authorization: Token %s"\n' "$(cfg_quote "$AUTH_TOKEN")" ;;
        esac
    }
    # A line break would start a new config line. Check in this shell, since
    # auth_config runs in a subshell and cannot stop the script.
    for v in "${AUTH_USER:-}" "${AUTH_PASS:-}" "${AUTH_TOKEN:-}"; do
        case "$v" in *$'\n'*|*$'\r'*) refuse "credential contains a line break; cannot pass it to curl safely." ;; esac
    done

    # -q ignores ~/.curlrc so it cannot switch tracing on. --proto pins every
    # request, redirects included, to https.
    exec "$COMMAND" -q --proto '=https' --proto-redir '=https' \
        --config <(auth_config) \
        "${CMD_ARGS[@]:1}"
else
    # Non-curl: export credentials as env vars into the subprocess only. The
    # child can read them. Refusing the obvious printers catches slips; it is
    # not a security boundary.
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
