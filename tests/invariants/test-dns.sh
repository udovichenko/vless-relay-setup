#!/bin/bash
set -euo pipefail

REPO_ROOT=$(cd "$(dirname "$0")/../.." && pwd)
source "$REPO_ROOT/scripts/lib/dns.sh"

work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
export VPN_DNS_BACKUP_DIR="$work/backups"
mkdir -p "$VPN_DNS_BACKUP_DIR" "$work/bin" "$work/etc/systemd/resolved.conf.d"

# No root, real services, /etc mutations or network queries in these tests.
cat > "$work/bin/systemctl" <<'STUB'
#!/bin/bash
echo "$*" >> "$TEST_SERVICE_LOG"
case "$1" in
    is-active|is-enabled) [[ "${TEST_SERVICE_RUNNING:-true}" == true ]] ;;
    *) exit 0 ;;
esac
STUB
cat > "$work/bin/resolvectl" <<'STUB'
#!/bin/bash
if [[ "$1" == query && "${TEST_DNS_FAIL:-false}" == true ]]; then exit 1; fi
STUB
cat > "$work/bin/getent" <<'STUB'
#!/bin/bash
[[ "${TEST_NSS_FAIL:-false}" != true ]]
STUB
cat > "$work/bin/timeout" <<'STUB'
#!/bin/bash
shift
exec "$@"
STUB
chmod +x "$work/bin/"*
export PATH="$work/bin:$PATH" TEST_SERVICE_LOG="$work/services.log"

for mode in default adguard; do
    xray_dns_config "$mode" | jq -e '
        (.servers | length >= 2) and
        all(.servers[]; test("^https\\+local://[0-9.]+/dns-query$"))
    ' >/dev/null
done

# Render the actual exit builder under the temporary root, preserving all
# generation logic while redirecting its two fixed filesystem destinations.
source "$REPO_ROOT/scripts/lib/xray.sh"
exit_builder=$(declare -f configure_xray_exit)
exit_builder=${exit_builder//\/usr\/local\/etc\/xray\/config.json/$work\/exit.json}
exit_builder=${exit_builder//\/var\/log\/xray/$work\/log}
eval "$exit_builder"
for mode in default adguard; do
    configure_xray_exit 443 00000000-0000-4000-8000-000000000001 \
        private-key abcd example.com:443 example.com 0 '' '' "$mode" >/dev/null
    jq -e --argjson expected "$(xray_dns_config "$mode")" '
        .dns == $expected and
        .inbounds[0].streamSettings.network == "raw" and
        .outbounds[0].settings.domainStrategy == "UseIP"
    ' "$work/exit.json" >/dev/null
done
if xray_dns_config invalid >/dev/null 2>&1; then
    echo "Invalid DNS mode accepted" >&2; exit 1
fi

printf 'nameserver 192.0.2.53\n' > "$work/etc/resolv.conf"
configure_system_dns "$work/etc" >/dev/null
[[ "$(readlink "$work/etc/resolv.conf")" == /run/systemd/resolve/stub-resolv.conf ]]
grep -qx 'DNSOverTLS=yes' "$work/etc/systemd/resolved.conf.d/99-vpn-dns.conf"
grep -qx 'Domains=~.' "$work/etc/systemd/resolved.conf.d/99-vpn-dns.conf"
grep -qx 'FallbackDNS=' "$work/etc/systemd/resolved.conf.d/99-vpn-dns.conf"
configure_system_dns "$work/etc" >/dev/null
[[ "$(readlink "$work/etc/resolv.conf")" == /run/systemd/resolve/stub-resolv.conf ]]

# Both the resolved query and libc/NSS query must succeed. Roll back the
# original symlink (even dangling), drop-in, and inactive/disabled service state.
for failure in TEST_DNS_FAIL TEST_NSS_FAIL; do
    rm "$work/etc/resolv.conf"
    ln -s "$work/provider-resolv.conf" "$work/etc/resolv.conf"
    printf 'original drop-in\n' > "$work/etc/systemd/resolved.conf.d/99-vpn-dns.conf"
    : > "$TEST_SERVICE_LOG"
    if env "$failure=true" TEST_SERVICE_RUNNING=false bash -c \
        'source "$1/scripts/lib/dns.sh"; configure_system_dns "$2"' _ "$REPO_ROOT" "$work/etc" >/dev/null; then
        echo "Failed DNS check accepted: $failure" >&2; exit 1
    fi
    [[ "$(readlink "$work/etc/resolv.conf")" == "$work/provider-resolv.conf" ]]
    grep -qx 'original drop-in' "$work/etc/systemd/resolved.conf.d/99-vpn-dns.conf"
    grep -qx 'stop systemd-resolved' "$TEST_SERVICE_LOG"
    grep -qx 'disable systemd-resolved' "$TEST_SERVICE_LOG"
done
echo 'test-dns: ok'
