#!/bin/bash
set -euo pipefail

LOG_FILE="/usr/local/UniVPN/log/sidecar.log"
READY_FILE="/tmp/univpn-proxy-ready"
PACKAGED_SYS_CONFIG_PATH="/usr/local/UniVPN/sysconfig.ini"

export LD_LIBRARY_PATH=/usr/local/UniVPN/lib:/usr/local/UniVPN/serviceclient

CONNECT_TIMEOUT="${UNIVPN_CONNECT_TIMEOUT:-120}"
MICROSOCKS_PORT="${MICROSOCKS_PORT:-1080}"

VPN_PORT="${VPN_PORT:-443}"
VPN_PROFILE_NAME="${VPN_PROFILE_NAME:-${VPN_SERVER:-vpn1}}"
VPN_PROFILE_NAME="$(printf "%s" "$VPN_PROFILE_NAME" | tr -c "A-Za-z0-9._" "_" | cut -c1-127)"

VPN2_PORT="${VPN2_PORT:-443}"
VPN2_PROFILE_NAME="${VPN2_PROFILE_NAME:-${VPN2_SERVER:-vpn2}}"
VPN2_PROFILE_NAME="$(printf "%s" "$VPN2_PROFILE_NAME" | tr -c "A-Za-z0-9._" "_" | cut -c1-127)"

mkdir -p /usr/local/UniVPN/log
exec 1> >(tee -a "$LOG_FILE")
exec 2>&1

log() { echo "[$(date '+%H:%M:%S')] $*"; }

XV_PID=""
VPN1_PID=""
VPN2_PID=""
MICROSOCKS_PID=""

cleanup() {
    local exit_code=$?
    for pid_var in MICROSOCKS_PID VPN2_PID VPN1_PID XV_PID; do
        local pid="${!pid_var:-}"
        if [[ -n "$pid" ]] && kill -0 "$pid" 2>/dev/null; then
            kill "$pid" 2>/dev/null || true
        fi
    done
    exit "$exit_code"
}
trap cleanup EXIT INT TERM

start_xvfb() {
    mkdir -p /tmp/.X11-unix
    chmod 1777 /tmp/.X11-unix

    Xvfb :99 -screen 0 1024x768x24 -ac +extension GLX +render -noreset > /tmp/xvfb.log 2>&1 &
    XV_PID=$!
    export DISPLAY=:99

    sleep 2

    if ! kill -0 "$XV_PID" 2>/dev/null; then
        log "ERROR: Xvfb failed to start"
        cat /tmp/xvfb.log
        exit 1
    fi

    log "Xvfb started (PID: $XV_PID)"
}

ensure_tun_device() {
    if [[ ! -e /dev/net/tun ]]; then
        mkdir -p /dev/net
        mknod /dev/net/tun c 10 200
        chmod 600 /dev/net/tun
    fi
    log "TUN device ready"
}

setup_vpn_home() {
    local home_dir="$1"
    local univpn_dir="${home_dir}/UniVPN"
    local config_dir="${univpn_dir}/config"
    local sysconfig="${univpn_dir}/sysconfig.ini"

    mkdir -p "${config_dir}" "${home_dir}/.config"
    chmod 755 "${home_dir}" "${univpn_dir}" 2>/dev/null || true
    chmod a+rwX "${config_dir}" 2>/dev/null || true

    if [[ ! -s "${sysconfig}" ]] && [[ -f "${PACKAGED_SYS_CONFIG_PATH}" ]]; then
        cp -f "${PACKAGED_SYS_CONFIG_PATH}" "${sysconfig}"
    fi
    chmod 664 "${sysconfig}" 2>/dev/null || true
}

seed_sysconfig() {
    local home_dir="$1"
    local profile_name="$2"
    local sysconfig="${home_dir}/UniVPN/sysconfig.ini"

    if grep -q '^\[Session0\]$' "${sysconfig}" 2>/dev/null; then
        sed -i "s/^ProfileName = .*/ProfileName = ${profile_name}.ini/" "${sysconfig}" 2>/dev/null || true
        return
    fi

    cat >> "${sysconfig}" <<EOF

[Session0]
ConnectType = 1
RemPwd = 0
AutoLogin = 0
LastLoginAddr =
ProfileName = ${profile_name}.ini
ProfileUser =
ProfileInfo =
EOF
}

generate_profile_b64() {
    local home_dir="$1"
    local profile_name="$2"
    local config_b64="$3"
    local target="${home_dir}/UniVPN/config/${profile_name}.ini"

    echo "${config_b64}" | base64 -d > "${target}"
    log "Profile loaded from base64: ${target}"
}

generate_profile_configure() {
    local home_dir="$1" server="$2" user="$3" pass="$4" port="$5" name="$6"

    log "Generating profile via configure.exp for ${name} (home: ${home_dir})"
    unshare --fork --mount /bin/bash -c "
        mount --make-rprivate / 2>/dev/null || true
        mount -t tmpfs tmpfs /run
        mkdir -p /run/lock /run/netns /run/secrets
        export HOME='${home_dir}'
        export XDG_CONFIG_HOME='${home_dir}/.config'
        export UNIVPN_HOME='${home_dir}'
        export LD_LIBRARY_PATH='${LD_LIBRARY_PATH}'
        /usr/local/bin/configure.exp '${server}' '${user}' '${pass}' '${port}' '${name}'
    " || { log "WARNING: configure.exp failed for ${name}, continuing"; return 1; }

    # Defensive copy: if UniVPNCS ignored UNIVPN_HOME and wrote to /root instead
    local default_config="/root/UniVPN/config/${name}.ini"
    local target_config="${home_dir}/UniVPN/config/${name}.ini"
    if [[ -f "${default_config}" ]] && [[ "${home_dir}" != "/root" ]]; then
        cp -f "${default_config}" "${target_config}" 2>/dev/null || true
    fi
}

start_vpn() {
    local home_dir="$1"
    local profile_name="$2"
    local user="$3"
    local pass="$4"
    local label="$5"

    log "Starting ${label} (home: ${home_dir}, profile: ${profile_name})"

    nohup unshare --fork --mount /bin/bash -c "
        mount --make-rprivate / 2>/dev/null || true
        mount -t tmpfs tmpfs /run
        mkdir -p /run/lock /run/netns /run/secrets
        export HOME='${home_dir}'
        export XDG_CONFIG_HOME='${home_dir}/.config'
        export UNIVPN_HOME='${home_dir}'
        export LD_LIBRARY_PATH='${LD_LIBRARY_PATH}'
        exec /usr/local/bin/connect.exp '${profile_name}' '${user}' '${pass}'
    " >"/tmp/${label}.log" 2>&1 &
    echo $!
}

count_cnem_interfaces() {
    ip -o link show 2>/dev/null | awk -F': ' '{print $2}' | grep -cE '^cnem' || echo 0
}

wait_for_cnem_count() {
    local target_count="$1"
    local timeout_secs="$2"
    local deadline=$(( SECONDS + timeout_secs ))
    local current=0

    while (( SECONDS < deadline )); do
        current="$(count_cnem_interfaces)"
        if (( current >= target_count )); then
            log "Detected ${current} cnem* interface(s) — reached target ${target_count}"
            return 0
        fi
        sleep 2
    done

    log "ERROR: timeout waiting for ${target_count} cnem* interfaces (got ${current})"
    return 1
}

# ─── Main ────────────────────────────────────────────────────────────────────

rm -f "${READY_FILE}"
log "========================================"
log "UniVPN SOCKS5 Proxy starting at $(date)"
log "VPN1: ${VPN_SERVER:-<unset>} / profile: ${VPN_PROFILE_NAME}"
log "VPN2: ${VPN2_SERVER:-<unset>} / profile: ${VPN2_PROFILE_NAME}"
log "SOCKS5 port: ${MICROSOCKS_PORT}"
log "========================================"

start_xvfb
ensure_tun_device
echo 1 > /proc/sys/net/ipv4/ip_forward 2>/dev/null || true

# ─── VPN1 setup ──────────────────────────────────────────────────────────────
VPN1_HOME="/tmp/vpn1-home"
setup_vpn_home "${VPN1_HOME}"

if [[ -n "${VPN_CONFIG_B64:-}" ]]; then
    generate_profile_b64 "${VPN1_HOME}" "${VPN_PROFILE_NAME}" "${VPN_CONFIG_B64}"
elif [[ -n "${VPN_SERVER:-}" ]]; then
    generate_profile_configure "${VPN1_HOME}" "${VPN_SERVER}" "${VPN_USER}" "${VPN_PASSWORD}" "${VPN_PORT}" "${VPN_PROFILE_NAME}" || true
else
    log "ERROR: VPN_SERVER or VPN_CONFIG_B64 required for VPN1"
    exit 1
fi

seed_sysconfig "${VPN1_HOME}" "${VPN_PROFILE_NAME}"

# ─── VPN2 setup ──────────────────────────────────────────────────────────────
VPN2_HOME="/tmp/vpn2-home"
setup_vpn_home "${VPN2_HOME}"

if [[ -n "${VPN2_CONFIG_B64:-}" ]]; then
    generate_profile_b64 "${VPN2_HOME}" "${VPN2_PROFILE_NAME}" "${VPN2_CONFIG_B64}"
elif [[ -n "${VPN2_SERVER:-}" ]]; then
    generate_profile_configure "${VPN2_HOME}" "${VPN2_SERVER}" "${VPN2_USER}" "${VPN2_PASSWORD}" "${VPN2_PORT}" "${VPN2_PROFILE_NAME}" || true
else
    log "ERROR: VPN2_SERVER or VPN2_CONFIG_B64 required for VPN2"
    exit 1
fi

seed_sysconfig "${VPN2_HOME}" "${VPN2_PROFILE_NAME}"

# ─── Start VPNs ──────────────────────────────────────────────────────────────
VPN1_PID="$(start_vpn "${VPN1_HOME}" "${VPN_PROFILE_NAME}" "${VPN_USER}" "${VPN_PASSWORD}" "vpn1")"
log "VPN1 process PID: ${VPN1_PID}"

log "Waiting for VPN1 interface..."
wait_for_cnem_count 1 "${CONNECT_TIMEOUT}"

log "Starting VPN2..."
VPN2_PID="$(start_vpn "${VPN2_HOME}" "${VPN2_PROFILE_NAME}" "${VPN2_USER}" "${VPN2_PASSWORD}" "vpn2")"
log "VPN2 process PID: ${VPN2_PID}"

log "Waiting for VPN2 interface..."
wait_for_cnem_count 2 "${CONNECT_TIMEOUT}"

# ─── Start microsocks ────────────────────────────────────────────────────────
log "Starting microsocks on port ${MICROSOCKS_PORT}..."
microsocks -p "${MICROSOCKS_PORT}" &
MICROSOCKS_PID=$!
log "microsocks PID: ${MICROSOCKS_PID}"

sleep 1
if ! kill -0 "${MICROSOCKS_PID}" 2>/dev/null; then
    log "ERROR: microsocks failed to start"
    exit 1
fi

touch "${READY_FILE}"
log "========================================"
log "UniVPN SOCKS5 Proxy READY"
log "SOCKS5: 0.0.0.0:${MICROSOCKS_PORT}"
log "VPN interfaces: $(ip -o link show 2>/dev/null | awk -F': ' '{print $2}' | grep '^cnem' | tr '\n' ' ')"
log "========================================"

# Monitor: exit if microsocks dies
while true; do
    if ! kill -0 "${MICROSOCKS_PID}" 2>/dev/null; then
        log "ERROR: microsocks exited unexpectedly"
        exit 1
    fi
    sleep 10
done
