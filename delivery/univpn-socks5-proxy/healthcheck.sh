#!/bin/bash
set -euo pipefail

# Check microsocks is running
if ! pgrep -x microsocks > /dev/null 2>&1; then
    echo "UNHEALTHY: microsocks not running"
    exit 1
fi

# Check at least one VPN interface exists
vpn_iface="$(ip -o link show 2>/dev/null | awk -F': ' '{print $2}' | grep -E '^cnem' | head -n 1 || true)"
if [[ -z "$vpn_iface" ]]; then
    echo "UNHEALTHY: no cnem* VPN interface found"
    exit 1
fi

echo "OK: microsocks running, VPN interface: $vpn_iface"
exit 0
