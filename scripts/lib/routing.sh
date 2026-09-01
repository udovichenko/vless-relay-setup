#!/bin/bash
# Happ/Incy routing profile download, validation, caching, and 3X-UI settings.

source "$(dirname "${BASH_SOURCE[0]}")/common.sh"

ROUTING_DEFAULT_SOURCE="https://raw.githubusercontent.com/hydraponique/roscomvpn-routing/main/HAPP/DEFAULT.DEEPLINK"
ROUTING_STATE_DIR="${ROUTING_STATE_DIR:-/etc/vpn-cli}"
ROUTING_SOURCE_FILE="${ROUTING_SOURCE_FILE:-$ROUTING_STATE_DIR/routing-source}"
ROUTING_CACHE_FILE="${ROUTING_CACHE_FILE:-$ROUTING_STATE_DIR/routing-profile.deeplink}"
ROUTING_BUNDLED_PROFILE="${ROUTING_BUNDLED_PROFILE:-$REPO_ROOT/scripts/lib/templates/happ-routing-ru.json}"
ROUTING_MAX_BYTES=65536

# Populated by routing_resolve_profile.
ROUTING_RESOLVED_SOURCE=""
ROUTING_RESOLVED_DEEPLINK=""

routing_validate_source_url() {
    local source="${1:-}"
    [[ "$source" =~ ^https://[^[:space:]]+$ ]]
}

# Accept a Happ onadd deeplink or a JSON profile and emit one canonical deeplink.
routing_normalize_payload() {
    local input="${1:-}" payload decoded compact encoded
    [[ -n "$input" ]] || return 1

    if printf '%s' "$input" | jq -e . >/dev/null 2>&1; then
        decoded="$input"
    else
        input=$(printf '%s' "$input" | tr -d '\r\n' | \
            sed 's/^[[:space:]]*//; s/[[:space:]]*$//')
        [[ "$input" == happ://routing/onadd/* ]] || return 1
        payload="${input#happ://routing/onadd/}"
        [[ -n "$payload" && ${#payload} -le "$ROUTING_MAX_BYTES" ]] || return 1
        decoded=$(printf '%s' "$payload" | base64 -d 2>/dev/null) || return 1
    fi

    [[ ${#decoded} -le "$ROUTING_MAX_BYTES" ]] || return 1
    printf '%s' "$decoded" | jq -e '
        type == "object" and
        (.Name | type == "string" and length > 0) and
        (.LastUpdated | type == "string" and test("^[0-9]+$")) and
        (.Geoipurl | type == "string" and startswith("https://")) and
        (.Geositeurl | type == "string" and startswith("https://")) and
        (.DirectSites | type == "array") and
        (.DirectIp | type == "array") and
        (.ProxySites | type == "array") and
        (.ProxyIp | type == "array") and
        (.BlockSites | type == "array") and
        (.BlockIp | type == "array")
    ' >/dev/null 2>&1 || return 1

    compact=$(printf '%s' "$decoded" | jq -c .) || return 1
    encoded=$(printf '%s' "$compact" | base64 -w 0) || return 1
    printf 'happ://routing/onadd/%s' "$encoded"
}

# Download a source without following redirects into non-HTTP schemes.
# Supports JSON/deeplink response bodies and routing.help-style Location headers.
routing_fetch_profile() {
    local url="$1" headers body code location raw normalized
    routing_validate_source_url "$url" || return 1

    for _ in 1 2 3 4 5; do
        headers=$(mktemp)
        body=$(mktemp)
        code=$(curl -sS --connect-timeout 5 --max-time 20 --retry 2 --retry-delay 1 \
            --max-filesize "$ROUTING_MAX_BYTES" -D "$headers" -o "$body" \
            -w '%{http_code}' "$url") || {
            rm -f "$headers" "$body"
            return 1
        }

        case "$code" in
            200)
                if [[ $(wc -c < "$body") -gt "$ROUTING_MAX_BYTES" ]]; then
                    rm -f "$headers" "$body"
                    return 1
                fi
                raw=$(<"$body")
                rm -f "$headers" "$body"
                normalized=$(routing_normalize_payload "$raw") || return 1
                printf '%s' "$normalized"
                return 0
                ;;
            301|302|303|307|308)
                location=$(awk 'BEGIN { IGNORECASE=1 }
                    /^Location:[[:space:]]*/ {
                        sub(/\r$/, ""); sub(/^[^:]+:[[:space:]]*/, ""); print; exit
                    }' "$headers")
                rm -f "$headers" "$body"
                if [[ "$location" == happ://routing/onadd/* ]]; then
                    normalized=$(routing_normalize_payload "$location") || return 1
                    printf '%s' "$normalized"
                    return 0
                fi
                routing_validate_source_url "$location" || return 1
                url="$location"
                ;;
            *)
                rm -f "$headers" "$body"
                return 1
                ;;
        esac
    done
    return 1
}

routing_saved_source() {
    local source=""
    if [[ -r "$ROUTING_SOURCE_FILE" ]]; then
        source=$(tr -d '\r\n' < "$ROUTING_SOURCE_FILE")
    fi
    if ! routing_validate_source_url "$source"; then
        source="$ROUTING_DEFAULT_SOURCE"
    fi
    printf '%s' "$source"
}

# Resolve without changing persistent state. Call routing_commit_profile_state only
# after the 3X-UI database change has been applied successfully.
routing_resolve_profile() {
    local requested_source="${1:-}" source fetched cached bundled
    source="${requested_source:-$(routing_saved_source)}"
    if ! routing_validate_source_url "$source"; then
        log_error "Routing source must be an HTTPS URL: $source"
        return 1
    fi

    ROUTING_RESOLVED_SOURCE="$source"
    ROUTING_RESOLVED_DEEPLINK=""
    log_info "Refreshing Happ/Incy routing profile..."

    if fetched=$(routing_fetch_profile "$source"); then
        ROUTING_RESOLVED_DEEPLINK="$fetched"
        log_ok "Routing profile downloaded and validated"
        return 0
    fi

    log_warn "Routing source unavailable or invalid; trying last known good profile"
    if [[ -r "$ROUTING_CACHE_FILE" ]]; then
        cached=$(routing_normalize_payload "$(<"$ROUTING_CACHE_FILE")") || cached=""
        if [[ -n "$cached" ]]; then
            ROUTING_RESOLVED_DEEPLINK="$cached"
            log_ok "Using cached routing profile"
            return 0
        fi
    fi

    if [[ -r "$ROUTING_BUNDLED_PROFILE" ]]; then
        bundled=$(routing_normalize_payload "$(<"$ROUTING_BUNDLED_PROFILE")") || bundled=""
        if [[ -n "$bundled" ]]; then
            ROUTING_RESOLVED_DEEPLINK="$bundled"
            log_warn "Using bundled routing profile"
            return 0
        fi
    fi

    log_error "No valid routing profile is available"
    return 1
}

routing_commit_profile_state() {
    [[ -n "$ROUTING_RESOLVED_SOURCE" && -n "$ROUTING_RESOLVED_DEEPLINK" ]] || return 1

    install -d -m 0700 "$ROUTING_STATE_DIR"
    local source_tmp cache_tmp
    source_tmp=$(mktemp "$ROUTING_STATE_DIR/.routing-source.XXXXXX")
    cache_tmp=$(mktemp "$ROUTING_STATE_DIR/.routing-profile.XXXXXX")
    printf '%s\n' "$ROUTING_RESOLVED_SOURCE" > "$source_tmp"
    printf '%s\n' "$ROUTING_RESOLVED_DEEPLINK" > "$cache_tmp"
    chmod 0600 "$source_tmp" "$cache_tmp"
    mv "$source_tmp" "$ROUTING_SOURCE_FILE"
    mv "$cache_tmp" "$ROUTING_CACHE_FILE"
}

# Caller must stop x-ui before invoking this function.
routing_apply_xui_settings() {
    [[ -n "$ROUTING_RESOLVED_DEEPLINK" ]] || return 1
    if ! declare -F xui_db_set >/dev/null; then
        log_error "xui_db_set is unavailable; source lib/3xui.sh first"
        return 1
    fi
    xui_db_set "subEnableRouting" "true"
    xui_db_set "subRoutingRules" "$ROUTING_RESOLVED_DEEPLINK"
    log_ok "Happ/Incy routing enabled for all subscriptions"
}

routing_xui_settings_current() {
    [[ -f "$XUI_DB" && -n "$ROUTING_RESOLVED_DEEPLINK" ]] || return 1
    local enabled rules
    enabled=$(sqlite3 "$XUI_DB" "SELECT value FROM settings WHERE key='subEnableRouting';" 2>/dev/null) || true
    rules=$(sqlite3 "$XUI_DB" "SELECT value FROM settings WHERE key='subRoutingRules';" 2>/dev/null) || true
    [[ "$enabled" == "true" && "$rules" == "$ROUTING_RESOLVED_DEEPLINK" ]]
}
