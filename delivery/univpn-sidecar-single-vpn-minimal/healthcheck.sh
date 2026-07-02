#!/bin/bash
set -euo pipefail

normalize_bool() {
    case "${1,,}" in
        1|true|yes|on) echo "true" ;;
        *) echo "false" ;;
    esac
}

detect_vpn_interface() {
    local iface
    local candidates="${UNIVPN_TUNNEL_IFACES:-tun0}"

    for iface in $candidates; do
        if ip addr show "$iface" >/dev/null 2>&1; then
            return 0
        fi
    done

    iface="$(ip -o link show 2>/dev/null | awk -F': ' '{print $2}' | grep -E '^cnem' | head -n 1 || true)"
    if [[ -n "$iface" ]] && ip addr show "$iface" >/dev/null 2>&1; then
        return 0
    fi

    return 1
}

if [[ "$(normalize_bool "${UNIVPN_REQUIRE_TUN:-true}")" == "true" ]]; then
    detect_vpn_interface
    exit $?
fi

pgrep -f 'UniVPNCS|connect.exp' >/dev/null 2>&1
