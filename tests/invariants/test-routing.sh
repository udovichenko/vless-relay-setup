#!/bin/bash
set -euo pipefail

REPO_ROOT=$(cd "$(dirname "$0")/../.." && pwd)
TEST_STATE=$(mktemp -d)
trap 'rm -rf "$TEST_STATE"' EXIT

export ROUTING_STATE_DIR="$TEST_STATE/state"
export ROUTING_SOURCE_FILE="$ROUTING_STATE_DIR/routing-source"
export ROUTING_CACHE_FILE="$ROUTING_STATE_DIR/routing-profile.deeplink"
export ROUTING_BUNDLED_PROFILE="$REPO_ROOT/scripts/lib/templates/happ-routing-ru.json"

source "$REPO_ROOT/scripts/lib/routing.sh"

deeplink=$(routing_normalize_payload "$(<"$ROUTING_BUNDLED_PROFILE")")
[[ "$deeplink" == happ://routing/onadd/* ]]
decoded=$(printf '%s' "${deeplink#happ://routing/onadd/}" | base64 -d)
[[ $(printf '%s' "$decoded" | jq -r .Name) == "RoscomVPN" ]]

invalid='{"Name":"bad","LastUpdated":"1","Geoipurl":"http://unsafe/geoip.dat"}'
if routing_normalize_payload "$invalid" >/dev/null 2>&1; then
    echo "invalid routing profile was accepted" >&2
    exit 1
fi

# A network failure must fall back to a validated last-known-good profile.
install -d -m 0700 "$ROUTING_STATE_DIR"
printf '%s\n' "$deeplink" > "$ROUTING_CACHE_FILE"
routing_fetch_profile() { return 1; }
routing_resolve_profile "$ROUTING_DEFAULT_SOURCE"
[[ "$ROUTING_RESOLVED_DEEPLINK" == "$deeplink" ]]
routing_commit_profile_state
[[ $(<"$ROUTING_SOURCE_FILE") == "$ROUTING_DEFAULT_SOURCE" ]]

echo "test-routing: ok"
