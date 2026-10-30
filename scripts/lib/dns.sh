#!/bin/bash
# Public encrypted DNS for the OS and Xray; never fall back to the hoster's DNS.

set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/common.sh"

xray_dns_config() {
    local mode="${1:-default}"
    case "$mode" in
        default)
            jq -nc '{servers: ["https+local://1.1.1.1/dns-query", "https+local://8.8.8.8/dns-query"]}'
            ;;
        adguard)
            jq -nc '{servers: ["https+local://94.140.14.14/dns-query", "https+local://94.140.15.15/dns-query", "https+local://1.1.1.1/dns-query"]}'
            ;;
        *)
            log_error "Unknown DNS mode: $mode (expected: adguard|default)" >&2
            return 1
            ;;
    esac
}

# A subshell confines rollback traps to this operation. The optional etc_dir
# supports isolated tests; production callers always use /etc.
configure_system_dns() (
    set -euo pipefail
    local etc_dir="${1:-/etc}"
    local dropin backup rc was_active=false was_enabled=false
    dropin="$etc_dir/systemd/resolved.conf.d/99-vpn-dns.conf"

    backup=$(mktemp -d "${VPN_DNS_BACKUP_DIR:-/var/backups}/vpn-dns.XXXXXXXX")
    chmod 700 "$backup"
    if [[ -e "$etc_dir/resolv.conf" || -L "$etc_dir/resolv.conf" ]]; then
        cp -a "$etc_dir/resolv.conf" "$backup/resolv.conf"
    fi
    if [[ -e "$dropin" ]]; then
        cp -a "$dropin" "$backup/resolved.conf"
    fi
    systemctl is-active --quiet systemd-resolved && was_active=true
    systemctl is-enabled --quiet systemd-resolved && was_enabled=true

    trap '
        rc=$?
        if [[ "$rc" != 0 ]]; then
            log_error "DNS configuration failed; restoring $backup"
            rm -f "$etc_dir/resolv.conf" "$dropin"
            if [[ -e "$backup/resolv.conf" || -L "$backup/resolv.conf" ]]; then
                cp -a "$backup/resolv.conf" "$etc_dir/resolv.conf"
            fi
            if [[ -e "$backup/resolved.conf" ]]; then
                cp -a "$backup/resolved.conf" "$dropin"
            fi
            if [[ "$was_active" == true ]]; then
                systemctl restart systemd-resolved || true
            else
                systemctl stop systemd-resolved || true
            fi
            if [[ "$was_enabled" != true ]]; then
                systemctl disable systemd-resolved || true
            fi
        fi
        exit "$rc"
    ' EXIT
    trap 'exit 130' INT
    trap 'exit 143' TERM

    if ! command -v resolvectl >/dev/null 2>&1; then
        apt-get install -y -qq systemd-resolved
    fi

    mkdir -p "$(dirname "$dropin")"
    cat > "$dropin" <<'RESOLVED'
[Resolve]
DNS=
DNS=1.1.1.1#cloudflare-dns.com 1.0.0.1#cloudflare-dns.com 8.8.8.8#dns.google
FallbackDNS=
Domains=
Domains=~.
DNSOverTLS=yes
DNSStubListener=yes
LLMNR=no
MulticastDNS=no
RESOLVED

    # Bypass resolvconf/DHCP-generated nameservers without restarting networking.
    # resolved's stub, unlike its uplink resolv.conf, preserves DNS-over-TLS.
    ln -sfn /run/systemd/resolve/stub-resolv.conf "$etc_dir/resolv.conf"
    systemctl enable systemd-resolved
    systemctl restart systemd-resolved
    resolvectl flush-caches
    timeout 30 resolvectl query example.com >/dev/null
    timeout 15 getent ahostsv4 example.com >/dev/null
    log_ok "System DNS: Cloudflare + Google over TLS (backup: $backup)"
)
