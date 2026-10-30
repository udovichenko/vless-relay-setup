#!/bin/bash
set -euo pipefail

REPO_ROOT=$(cd "$(dirname "$0")/../.." && pwd)
source "$REPO_ROOT/scripts/lib/3xui.sh"

disabled=$(relay_routing_config false)
enabled=$(relay_routing_config true)
jq -e '.rules | length == 2' <<< "$disabled" >/dev/null
! relay_ru_routing_enabled "$(jq -nc --argjson r "$disabled" '{routing:$r}')"
relay_ru_routing_enabled "$(jq -nc --argjson r "$enabled" '{routing:$r}')"
if relay_routing_config invalid >/dev/null 2>&1; then
    echo "invalid relay routing mode accepted" >&2
    exit 1
fi

# API and private-network protection precede direct rules; catch-all stays last.
# IPIfNonMatch would never reach GeoIP because the inbound catch-all matches.
jq -e '
    .domainStrategy == "IPOnDemand" and
    .rules[0].outboundTag == "api" and
    .rules[1] == {type:"field", ip:["geoip:private"], outboundTag:"block"} and
    .rules[2].outboundTag == "direct" and
    (.rules[2].domain | index("domain:xn--p1ai") != null) and
    .rules[3] == {type:"field", ip:["geoip:ru"], outboundTag:"direct"} and
    .rules[-1] == {type:"field", inboundTag:["inbound-443"], outboundTag:"proxy-exit"}
' <<< "$enabled" >/dev/null

# Render the real template without writing a DB or system directories.
mkdir() { :; }
xui_db_set() { [[ "$1" == xrayTemplateConfig ]]; printf '%s\n' "$2" > "$TEST_TEMPLATE"; }
TEST_TEMPLATE=$(mktemp)
trap 'rm -f "$TEST_TEMPLATE"' EXIT
configure_3xui_relay_template 192.0.2.1 443 00000000-0000-4000-8000-000000000001 \
    public-key abcd exit.example.com firefox 12345 true >/dev/null
relay_ru_routing_enabled "$(<"$TEST_TEMPLATE")"
jq -e '.outbounds[0].tag == "proxy-exit" and .inbounds[0].port == 12345' "$TEST_TEMPLATE" >/dev/null
jq -e '
    .dns.servers == ["https+local://1.1.1.1/dns-query", "https+local://8.8.8.8/dns-query"] and
    any(.outbounds[]; .tag == "direct" and .settings.domainStrategy == "UseIP")
' "$TEST_TEMPLATE" >/dev/null
configure_3xui_relay_template 192.0.2.1 443 00000000-0000-4000-8000-000000000001 \
    public-key abcd exit.example.com firefox 12345 >/dev/null
! relay_ru_routing_enabled "$(<"$TEST_TEMPLATE")"
echo "test-relay-routing: ok"
