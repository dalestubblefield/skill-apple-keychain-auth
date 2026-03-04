#!/usr/bin/env bash
# apple-keychain-auth - Retrieve and classify credentials from macOS Keychain
#
# Usage:
#   eval "$(~/.claude/skills/apple-keychain-auth/get-credentials.sh <hostname-or-url> [account])"
#
# Sets: AUTH_HOST, AUTH_USER, AUTH_PASS, AUTH_TOKEN, AUTH_TYPE
#
#   AUTH_TYPE values: basic | bearer | api_key | token
#
# To unset all exported vars after use:
#   auth_unset  (exported as a shell function alongside the vars)
#
# Examples:
#   eval "$(get-credentials.sh gpinst01.service-now.com)"
#   eval "$(get-credentials.sh https://api.example.com admin@example.com)"
#   eval "$(get-credentials.sh github.com)"   # checks generic password too

set -euo pipefail

INPUT="${1:-}"
REQUESTED_ACCOUNT="${2:-}"

if [[ -z "$INPUT" ]]; then
    echo "Usage: eval \"\$(~/.claude/skills/apple-keychain-auth/get-credentials.sh <hostname-or-url> [account])\"" >&2
    exit 1
fi

# Strip protocol prefix, path, port to isolate hostname
HOSTNAME=$(echo "$INPUT" | sed 's|^[a-zA-Z][a-zA-Z0-9+.-]*://||' | sed 's|[/:?#].*||')

if [[ -z "$HOSTNAME" ]]; then
    echo "Error: Could not parse hostname from '$INPUT'" >&2
    exit 1
fi

# ── JSON parsing: jq preferred, python3 fallback, naive grep last resort ─────

parse_json_field() {
    local json="$1" field="$2"
    if command -v jq &>/dev/null; then
        echo "$json" | jq -r --arg f "$field" '.[$f] // empty' 2>/dev/null || echo ""
    elif command -v python3 &>/dev/null; then
        echo "$json" | python3 -c "
import sys, json
try:
    d = json.load(sys.stdin)
    v = d.get('$field', '')
    print(v if v else '', end='')
except Exception:
    pass
" 2>/dev/null || echo ""
    else
        # Naive: extract "field":"value" or "field": "value"
        echo "$json" | grep -oE "\"${field}\"[[:space:]]*:[[:space:]]*\"[^\"]*\"" \
            | sed 's/.*":[[:space:]]*"//' | tr -d '"' || echo ""
    fi
}

is_valid_json() {
    local val="$1"
    if command -v jq &>/dev/null; then
        echo "$val" | jq empty 2>/dev/null
    elif command -v python3 &>/dev/null; then
        echo "$val" | python3 -c "import sys,json; json.load(sys.stdin)" 2>/dev/null
    else
        # Naive: starts with { and ends with }
        [[ "$val" =~ ^\{.*\}$ ]]
    fi
}

# ── Keychain lookup helpers ──────────────────────────────────────────────────

# Attempt internet-password lookup; returns entry attributes (no password)
lookup_internet() {
    local host="$1" acct="${2:-}"
    if [[ -n "$acct" ]]; then
        security find-internet-password -s "$host" -a "$acct" 2>/dev/null
    else
        security find-internet-password -s "$host" 2>/dev/null
    fi
}

# Attempt generic-password lookup (GitHub CLI, npm, many API tools store here)
lookup_generic() {
    local host="$1" acct="${2:-}"
    if [[ -n "$acct" ]]; then
        security find-generic-password -s "$host" -a "$acct" 2>/dev/null
    else
        security find-generic-password -s "$host" 2>/dev/null
    fi
}

get_internet_password() {
    local host="$1" acct="${2:-}"
    if [[ -n "$acct" ]]; then
        security find-internet-password -s "$host" -a "$acct" -w 2>/dev/null
    else
        security find-internet-password -s "$host" -w 2>/dev/null
    fi
}

get_generic_password() {
    local host="$1" acct="${2:-}"
    if [[ -n "$acct" ]]; then
        security find-generic-password -s "$host" -a "$acct" -w 2>/dev/null
    else
        security find-generic-password -s "$host" -w 2>/dev/null
    fi
}

extract_account_from_entry() {
    local entry="$1"
    local acct
    # macOS Ventura+ format:  "acct"<blob>="value"
    acct=$(echo "$entry" | grep '"acct"<blob>=' | sed 's/.*"acct"<blob>="//' | sed 's/"$//')
    if [[ -z "$acct" ]]; then
        # Fallback: last quoted value on the acct line
        acct=$(echo "$entry" | grep '"acct"' | grep -oE '"[^"]{1,128}"$' | tr -d '"' || true)
    fi
    echo "$acct"
}

# ── Multi-account enumeration (no dump-keychain) ─────────────────────────────
# security dump-keychain triggers a macOS permission dialog on Sonoma+ and is
# blocked in some enterprise environments. Instead, we probe known accounts by
# re-running find-*-password until it stops returning new results.
# This is limited to accounts we already know about; for unknown accounts the
# user must pass the account name explicitly as a second argument.
#
# Practical approach: try the default (first) match, report the account found,
# and tell the user how to switch if they need a different one.

# ── Credential type classification ──────────────────────────────────────────

classify_credential() {
    local user="$1" pass="$2"
    local auth_type="" auth_token="" auth_pass=""

    # 1. JSON blob — OAuth token response or structured API credential
    if is_valid_json "$pass" 2>/dev/null; then
        local access_token refresh_token api_key token_type
        access_token=$(parse_json_field "$pass" "access_token")
        refresh_token=$(parse_json_field "$pass" "refresh_token")
        api_key=$(parse_json_field "$pass" "api_key")
        [[ -z "$api_key" ]] && api_key=$(parse_json_field "$pass" "apiKey")
        token_type=$(parse_json_field "$pass" "token_type" | tr '[:upper:]' '[:lower:]')

        if [[ -n "$access_token" ]]; then
            auth_token="$access_token"
            auth_type="${token_type:-bearer}"
            auth_pass="$refresh_token"   # stash refresh_token in AUTH_PASS for caller use
        elif [[ -n "$api_key" ]]; then
            auth_token="$api_key"
            auth_type="api_key"
            auth_pass=""
        else
            auth_token="$pass"
            auth_type="token"
            auth_pass=""
        fi

    # 2. Bearer-looking token: long alphanumeric/JWT, no username
    elif [[ -z "$user" ]] && echo "$pass" | grep -qE '^[A-Za-z0-9_\-\.]{20,}$'; then
        auth_token="$pass"
        auth_type="bearer"
        auth_pass=""

    # 3. No username — treat as opaque API key
    elif [[ -z "$user" ]]; then
        auth_token="$pass"
        auth_type="api_key"
        auth_pass=""

    # 4. Username + password — basic auth
    else
        auth_type="basic"
        auth_token=""
        auth_pass="$pass"
    fi

    printf '%s\t%s\t%s' "$auth_type" "$auth_token" "$auth_pass"
}

# ── Main ─────────────────────────────────────────────────────────────────────

ENTRY=""
KEYCHAIN_TYPE=""   # "internet" or "generic"

# Try internet-password first, then generic-password
if ENTRY=$(lookup_internet "$HOSTNAME" "$REQUESTED_ACCOUNT"); [[ -n "$ENTRY" ]]; then
    KEYCHAIN_TYPE="internet"
elif ENTRY=$(lookup_generic "$HOSTNAME" "$REQUESTED_ACCOUNT"); [[ -n "$ENTRY" ]]; then
    KEYCHAIN_TYPE="generic"
    echo "Note: Found entry under generic-password (not internet-password) for '$HOSTNAME'." >&2
else
    echo "Error: No Keychain entry found for '$HOSTNAME'" >&2
    echo "" >&2
    echo "Checked both internet-password and generic-password entries." >&2
    echo "" >&2
    echo "Add credentials via Keychain Access:" >&2
    echo "  Open 'Keychain Access' → File → New Internet Password Item" >&2
    echo "  Set 'Where' (server) to: $HOSTNAME" >&2
    echo "" >&2
    echo "Or via CLI:" >&2
    echo "  security add-internet-password -s '$HOSTNAME' -a 'your-username' -w" >&2
    echo "  (omit -w to be prompted securely for the password)" >&2
    echo "" >&2
    echo "For API tokens with no username:" >&2
    echo "  security add-generic-password -s '$HOSTNAME' -a '' -w" >&2
    exit 1
fi

# Extract account name from the entry we found
CHOSEN_ACCOUNT="$REQUESTED_ACCOUNT"
if [[ -z "$CHOSEN_ACCOUNT" ]]; then
    CHOSEN_ACCOUNT=$(extract_account_from_entry "$ENTRY")
fi

# If multiple accounts may exist, report which one was selected and how to switch
if [[ -n "$CHOSEN_ACCOUNT" ]]; then
    echo "Using account: $CHOSEN_ACCOUNT" >&2
    echo "To use a different account: get-credentials.sh $HOSTNAME <account>" >&2
fi

# Retrieve password (in-memory only; never written to disk)
RAW_PASS=""
if [[ "$KEYCHAIN_TYPE" == "internet" ]]; then
    RAW_PASS=$(get_internet_password "$HOSTNAME" "$CHOSEN_ACCOUNT" 2>/dev/null || echo "")
else
    RAW_PASS=$(get_generic_password "$HOSTNAME" "$CHOSEN_ACCOUNT" 2>/dev/null || echo "")
fi

if [[ -z "$RAW_PASS" ]]; then
    echo "Error: Found account '$CHOSEN_ACCOUNT' at '$HOSTNAME' but could not retrieve password." >&2
    echo "macOS may have blocked access. In Keychain Access, select the entry → Access Control → Allow." >&2
    exit 1
fi

# Classify credential type
CLASSIFICATION=$(classify_credential "$CHOSEN_ACCOUNT" "$RAW_PASS" "$HOSTNAME")
AUTH_TYPE=$(echo "$CLASSIFICATION" | cut -f1)
AUTH_TOKEN=$(echo "$CLASSIFICATION" | cut -f2)
AUTH_PASS_OUT=$(echo "$CLASSIFICATION" | cut -f3)

# Warn on bearer with no refresh token — likely expired with no recovery path
if [[ "$AUTH_TYPE" == "bearer" && -z "$AUTH_PASS_OUT" ]]; then
    echo "" >&2
    echo "Warning: AUTH_TYPE=bearer with no refresh_token stored." >&2
    echo "If this token is expired and a request returns 401, you will need to:" >&2
    echo "  1. Re-run your OAuth flow to get a new token" >&2
    echo "  2. Update Keychain: security add-internet-password -s '$HOSTNAME' -a '$CHOSEN_ACCOUNT' -U -w" >&2
    echo "" >&2
fi

# ── Emit eval-safe exports (%q handles all special characters) ──────────────
printf "export AUTH_HOST=%q\n"  "$HOSTNAME"
printf "export AUTH_USER=%q\n"  "$CHOSEN_ACCOUNT"
printf "export AUTH_TYPE=%q\n"  "$AUTH_TYPE"
printf "export AUTH_PASS=%q\n"  "$AUTH_PASS_OUT"
printf "export AUTH_TOKEN=%q\n" "$AUTH_TOKEN"

# Export a cleanup function so the caller can unset all vars after use
printf "auth_unset() { unset AUTH_HOST AUTH_USER AUTH_TYPE AUTH_PASS AUTH_TOKEN; unset -f auth_unset; }\n"
