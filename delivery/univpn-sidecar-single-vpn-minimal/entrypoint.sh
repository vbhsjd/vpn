#!/bin/bash
set -euo pipefail

LOG_FILE="/usr/local/UniVPN/log/sidecar.log"
READY_FILE="/tmp/univpn-ready"
PACKAGED_SYS_CONFIG_PATH="/usr/local/UniVPN/sysconfig.ini"

DEFAULT_HOME="$(getent passwd "$(id -u)" 2>/dev/null | cut -d: -f6 | head -n 1 || true)"
if [[ -z "$DEFAULT_HOME" ]]; then
    DEFAULT_HOME="/root"
fi

export HOME="${HOME:-$DEFAULT_HOME}"
if [[ ! -d "$HOME" ]]; then
    mkdir -p "$HOME" 2>/dev/null || true
fi
if [[ ! -d "$HOME" || ! -w "$HOME" ]]; then
    export HOME="/tmp/univpn-home"
fi

export USER="${USER:-$(id -un 2>/dev/null || echo root)}"
export LOGNAME="${LOGNAME:-$USER}"
export XDG_CONFIG_HOME="${XDG_CONFIG_HOME:-$HOME/.config}"
export LD_LIBRARY_PATH=/usr/local/UniVPN/lib:/usr/local/UniVPN/serviceclient

UNIVPN_HOME_DIR="${UNIVPN_HOME_DIR:-$HOME/UniVPN}"
UNIVPN_SYS_CONFIG_PATH="${UNIVPN_SYS_CONFIG_PATH:-$UNIVPN_HOME_DIR/sysconfig.ini}"
RUNTIME_CONFIG_DIR="${UNIVPN_RUNTIME_CONFIG_DIR:-$UNIVPN_HOME_DIR/config}"
PERSISTED_CONFIG_DIR="${UNIVPN_PERSISTED_CONFIG_DIR:-/usr/local/UniVPN/config}"
CERT_DIR="${UNIVPN_CERT_DIR:-/usr/local/UniVPN/certificate}"
CONNECT_TIMEOUT="${UNIVPN_CONNECT_TIMEOUT:-120}"
DISCONNECT_TIMEOUT="${UNIVPN_DISCONNECT_TIMEOUT:-15}"
READY_POLL_INTERVAL="${UNIVPN_READY_POLL_INTERVAL:-1}"
BOOTSTRAP_PROFILE_SETTLE_SECONDS="${UNIVPN_PROFILE_SETTLE_SECONDS:-2}"
IMPORTED_PROFILE_SETTLE_SECONDS="${UNIVPN_IMPORTED_PROFILE_SETTLE_SECONDS:-0}"
VPN_PORT="${VPN_PORT:-443}"
VPN_PROFILE_NAME="${VPN_PROFILE_NAME:-${VPN_SERVER:-default}}"
VPN_PROFILE_NAME="$(printf '%s' "$VPN_PROFILE_NAME" | tr -c 'A-Za-z0-9._-' '_' | cut -c1-127)"

mkdir -p /usr/local/UniVPN/log "$CERT_DIR" "$UNIVPN_HOME_DIR" "$RUNTIME_CONFIG_DIR" "$PERSISTED_CONFIG_DIR" "$XDG_CONFIG_HOME"
exec 1> >(tee -a "$LOG_FILE")
exec 2>&1

log() {
    printf '[%s] %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$*"
}

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
            printf '%s\n' "$iface"
            return 0
        fi
    done

    iface="$(ip -o link show 2>/dev/null | awk -F': ' '{print $2}' | grep -E '^cnem' | head -n 1 || true)"
    if [[ -n "$iface" ]] && ip addr show "$iface" >/dev/null 2>&1; then
        printf '%s\n' "$iface"
        return 0
    fi

    return 1
}

UNIVPN_REQUIRE_TUN="$(normalize_bool "${UNIVPN_REQUIRE_TUN:-true}")"
UNIVPN_BOOTSTRAP_PROFILE="$(normalize_bool "${UNIVPN_BOOTSTRAP_PROFILE:-true}")"
UNIVPN_AUTOGENERATE_PROFILE="$(normalize_bool "${UNIVPN_AUTOGENERATE_PROFILE:-true}")"
PROFILE_PREPARED="false"
PROFILE_PREPARED_SOURCE=""

stop_process() {
    local name="$1"
    local pid="${2:-}"
    local timeout_secs="${3:-$DISCONNECT_TIMEOUT}"
    local deadline

    if [[ -z "$pid" ]] || ! kill -0 "$pid" 2>/dev/null; then
        return 0
    fi

    log "stopping ${name} (pid=${pid})"
    kill -TERM "$pid" 2>/dev/null || true

    deadline=$((SECONDS + timeout_secs))
    while (( SECONDS < deadline )); do
        if ! kill -0 "$pid" 2>/dev/null; then
            wait "$pid" 2>/dev/null || true
            return 0
        fi
        sleep 1
    done

    if kill -0 "$pid" 2>/dev/null; then
        log "warning: ${name} did not exit within ${timeout_secs}s, forcing stop"
        kill -KILL "$pid" 2>/dev/null || true
        wait "$pid" 2>/dev/null || true
    fi
}

cleanup() {
    local exit_code="${1:-$?}"
    rm -f "$READY_FILE"

    trap - EXIT INT TERM
    stop_process "UniVPNCS/connect.exp" "${CLI_PID:-}" "$DISCONNECT_TIMEOUT"

    exit "$exit_code"
}

trap 'cleanup $?' EXIT
trap 'cleanup 0' INT TERM

sanitize_profile_file() {
    local file="$1"
    local tmp_file

    if [[ ! -f "$file" ]]; then
        return 0
    fi

    tmp_file="${file}.normalized"
    awk 'NR == 1 { sub(/^\xef\xbb\xbf/, "") } { sub(/\r$/, ""); print }' "$file" > "$tmp_file"
    mv "$tmp_file" "$file"
}

sanitize_profile_directory() {
    local dir="$1"
    local file

    if [[ ! -d "$dir" ]]; then
        return 0
    fi

    shopt -s nullglob
    for file in "$dir"/*.ini "$dir"/*.vpn; do
        sanitize_profile_file "$file"
    done
    shopt -u nullglob
}

normalize_profile_extensions() {
    local dir="$1"
    local src
    local dst

    if [[ ! -d "$dir" ]]; then
        return 0
    fi

    shopt -s nullglob
    for src in "$dir"/*.vpn; do
        dst="${src%.vpn}.ini"
        if [[ ! -e "$dst" ]]; then
            cp -f "$src" "$dst" 2>/dev/null || true
            sanitize_profile_file "$dst"
        fi
    done
    shopt -u nullglob
}

ensure_univpn_home() {
    mkdir -p "$HOME" "$XDG_CONFIG_HOME" "$UNIVPN_HOME_DIR" "$RUNTIME_CONFIG_DIR" "$PERSISTED_CONFIG_DIR" "$CERT_DIR" /usr/local/UniVPN/log
    chmod 755 "$HOME" "$XDG_CONFIG_HOME" "$UNIVPN_HOME_DIR" "$CERT_DIR" 2>/dev/null || true
    chmod a+rwX "$RUNTIME_CONFIG_DIR" "$PERSISTED_CONFIG_DIR" /usr/local/UniVPN/log 2>/dev/null || true

    if [[ ! -s "$UNIVPN_SYS_CONFIG_PATH" ]]; then
        if [[ -f "$PACKAGED_SYS_CONFIG_PATH" ]]; then
            cp -f "$PACKAGED_SYS_CONFIG_PATH" "$UNIVPN_SYS_CONFIG_PATH"
        else
            : > "$UNIVPN_SYS_CONFIG_PATH"
        fi
    fi
    chmod 664 "$UNIVPN_SYS_CONFIG_PATH" 2>/dev/null || true

    normalize_profile_extensions "$RUNTIME_CONFIG_DIR"
    normalize_profile_extensions "$PERSISTED_CONFIG_DIR"
    sanitize_profile_directory "$RUNTIME_CONFIG_DIR"
    sanitize_profile_directory "$PERSISTED_CONFIG_DIR"
}

has_runtime_profile() {
    normalize_profile_extensions "$RUNTIME_CONFIG_DIR"
    sanitize_profile_directory "$RUNTIME_CONFIG_DIR"
    find "$RUNTIME_CONFIG_DIR" -maxdepth 1 -type f \( -name '*.ini' -o -name '*.vpn' \) | grep -q .
}

sync_persisted_config_to_runtime() {
    mkdir -p "$RUNTIME_CONFIG_DIR" "$PERSISTED_CONFIG_DIR"
    normalize_profile_extensions "$PERSISTED_CONFIG_DIR"
    sanitize_profile_directory "$PERSISTED_CONFIG_DIR"
    cp -a "$PERSISTED_CONFIG_DIR"/. "$RUNTIME_CONFIG_DIR"/ 2>/dev/null || true
    normalize_profile_extensions "$RUNTIME_CONFIG_DIR"
    sanitize_profile_directory "$RUNTIME_CONFIG_DIR"
}

sync_runtime_config_to_persisted() {
    mkdir -p "$RUNTIME_CONFIG_DIR" "$PERSISTED_CONFIG_DIR"
    normalize_profile_extensions "$RUNTIME_CONFIG_DIR"
    sanitize_profile_directory "$RUNTIME_CONFIG_DIR"
    cp -a "$RUNTIME_CONFIG_DIR"/. "$PERSISTED_CONFIG_DIR"/ 2>/dev/null || true
    normalize_profile_extensions "$PERSISTED_CONFIG_DIR"
    sanitize_profile_directory "$PERSISTED_CONFIG_DIR"
}

import_profile_from_env() {
    local target_profile="$RUNTIME_CONFIG_DIR/${VPN_PROFILE_NAME}.ini"

    if [[ -n "${VPN_CONFIG_PATH:-}" ]]; then
        if [[ ! -f "$VPN_CONFIG_PATH" ]]; then
            log "configured VPN_CONFIG_PATH does not exist: $VPN_CONFIG_PATH"
            return 1
        fi
        cp -f "$VPN_CONFIG_PATH" "$target_profile"
        sanitize_profile_file "$target_profile"
        sync_runtime_config_to_persisted
        log "imported profile from VPN_CONFIG_PATH into $(basename "$target_profile")"
        return 0
    fi

    if [[ -n "${VPN_CONFIG_B64:-}" ]]; then
        printf '%s' "$VPN_CONFIG_B64" | base64 -d > "$target_profile"
        sanitize_profile_file "$target_profile"
        sync_runtime_config_to_persisted
        log "imported profile from VPN_CONFIG_B64 into $(basename "$target_profile")"
        return 0
    fi

    return 1
}

profile_value() {
    local file="$1"
    local key="$2"

    awk -v key="$key" '
        $0 ~ "^[[:space:]]*" key "[[:space:]]*=" {
            sub(/^[^=]*=[[:space:]]*/, "")
            sub(/[[:space:]]*$/, "")
            print
            exit
        }
    ' "$file" 2>/dev/null || true
}

profile_matches_env() {
    local file="$1"
    local gateway_address
    local gateway_port
    local expected_address
    local expected_port

    if [[ ! -f "$file" || -z "${VPN_SERVER:-}" ]]; then
        return 1
    fi

    expected_address="$(printf '%s' "$VPN_SERVER" | tr -d '\r\n')"
    expected_port="$(printf '%s' "$VPN_PORT" | tr -cd '0-9')"
    gateway_address="$(profile_value "$file" GatewayAddress)"
    gateway_port="$(profile_value "$file" GatewayPort)"

    [[ "$gateway_address" == "$expected_address" && "$gateway_port" == "$expected_port" ]]
}

persisted_profile_exists() {
    [[ -f "$PERSISTED_CONFIG_DIR/${VPN_PROFILE_NAME}.ini" || -f "$PERSISTED_CONFIG_DIR/${VPN_PROFILE_NAME}.vpn" ]]
}

create_profile_from_env() {
    if [[ "$UNIVPN_BOOTSTRAP_PROFILE" != "true" ]]; then
        return 1
    fi
    if [[ -z "${VPN_SERVER:-}" || -z "${VPN_USER:-}" || -z "${VPN_PASSWORD:-}" ]]; then
        return 1
    fi

    log "no profile found, bootstrapping profile ${VPN_PROFILE_NAME} via UniVPNCS"
    /usr/local/bin/configure.exp "$VPN_SERVER" "$VPN_USER" "$VPN_PASSWORD" "$VPN_PORT" "$VPN_PROFILE_NAME"
    sync_runtime_config_to_persisted
    return 0
}

generate_profile_from_env() {
    local target_profile="$RUNTIME_CONFIG_DIR/${VPN_PROFILE_NAME}.ini"
    local gateway_address
    local gateway_port

    if [[ "$UNIVPN_AUTOGENERATE_PROFILE" != "true" ]]; then
        return 1
    fi
    if [[ -z "${VPN_SERVER:-}" ]]; then
        return 1
    fi

    gateway_address="$(printf '%s' "$VPN_SERVER" | tr -d '\r\n')"
    gateway_port="$(printf '%s' "$VPN_PORT" | tr -cd '0-9')"
    if [[ -z "$gateway_address" || -z "$gateway_port" ]]; then
        log "cannot autogenerate profile: invalid VPN_SERVER or VPN_PORT"
        return 1
    fi

    log "no profile found, generating profile ${VPN_PROFILE_NAME} from VPN_SERVER/VPN_PORT"
    cat > "$target_profile" <<EOF
[GLOBAL]
sign_certificate =
encryp_certificate =
iConnectionType = 1
Description =
GatewayAddress = ${gateway_address}
GatewayPort = ${gateway_port}
TunnelMode = 2
PreflinkEnable = 1
DefaultGateway = 0
iroutecoverEnable = 0
icertificateEnable = 0
igmalgorithmEnable = 0
PreflinkTotal = 0
EOF
    sanitize_profile_file "$target_profile"
    sync_runtime_config_to_persisted
    return 0
}

ensure_generated_profile_matches_env() {
    local target_profile="$RUNTIME_CONFIG_DIR/${VPN_PROFILE_NAME}.ini"

    if [[ "$UNIVPN_AUTOGENERATE_PROFILE" != "true" ]]; then
        return 1
    fi
    if [[ -z "${VPN_SERVER:-}" ]]; then
        return 1
    fi

    # A profile mounted into /usr/local/UniVPN/config is caller-owned. Do not
    # overwrite it; only synthesize or replace image-baked/runtime defaults.
    if persisted_profile_exists; then
        return 1
    fi

    if profile_matches_env "$target_profile"; then
        return 1
    fi

    generate_profile_from_env
}

seed_sysconfig_session_profile() {
    local selected_profile="${VPN_PROFILE_NAME}.ini"

    if [[ ! -f "$RUNTIME_CONFIG_DIR/$selected_profile" ]]; then
        selected_profile="$(find "$RUNTIME_CONFIG_DIR" -maxdepth 1 -type f -name '*.ini' | head -n 1 | xargs -r basename || true)"
    fi

    if [[ -z "$selected_profile" ]]; then
        return 0
    fi

    if grep -q '^\[Session0\]$' "$UNIVPN_SYS_CONFIG_PATH" 2>/dev/null; then
        if grep -q '^ProfileName = ' "$UNIVPN_SYS_CONFIG_PATH" 2>/dev/null; then
            sed -i "s/^ProfileName = .*/ProfileName = ${selected_profile}/" "$UNIVPN_SYS_CONFIG_PATH"
        else
            printf '\nProfileName = %s\n' "$selected_profile" >> "$UNIVPN_SYS_CONFIG_PATH"
        fi
        return 0
    fi

    cat >> "$UNIVPN_SYS_CONFIG_PATH" <<EOF

[Session0]
ConnectType = 1
RemPwd = 0
AutoLogin = 0
LastLoginAddr =
ProfileName = ${selected_profile}
ProfileUser =
ProfileInfo =
EOF
}

print_profiles() {
    local profile

    normalize_profile_extensions "$RUNTIME_CONFIG_DIR"
    sanitize_profile_directory "$RUNTIME_CONFIG_DIR"
    if ! has_runtime_profile; then
        log "no runtime profile found in $RUNTIME_CONFIG_DIR"
        return 0
    fi

    log "runtime profiles:"
    while IFS= read -r profile; do
        log "  - $(basename "$profile")"
    done < <(find "$RUNTIME_CONFIG_DIR" -maxdepth 1 -type f -name '*.ini' | sort)
}

ensure_tun_device() {
    if [[ ! -e /dev/net/tun ]]; then
        mkdir -p /dev/net
        mknod /dev/net/tun c 10 200
        chmod 600 /dev/net/tun
    fi

    if [[ ! -e /dev/net/tun ]]; then
        log "failed to create /dev/net/tun"
        exit 1
    fi
}

wait_for_tunnel() {
    local started_at="$1"
    local deadline=$((SECONDS + CONNECT_TIMEOUT))
    local vpn_iface=""
    local cli_exit_code=0
    local elapsed=0

    while (( SECONDS < deadline )); do
        if [[ -n "${CLI_PID:-}" ]] && ! kill -0 "$CLI_PID" 2>/dev/null; then
            wait "$CLI_PID" || cli_exit_code=$?
            log "UniVPNCS/connect.exp exited before tunnel was ready (exit=${cli_exit_code})"
            return 1
        fi

        vpn_iface="$(detect_vpn_interface || true)"
        if [[ -n "$vpn_iface" ]]; then
            elapsed=$((SECONDS - started_at))
            touch "$READY_FILE"
            log "VPN tunnel ready on ${vpn_iface} after ${elapsed}s"
            return 0
        fi

        sleep "$READY_POLL_INTERVAL"
    done

    log "timed out after ${CONNECT_TIMEOUT}s waiting for tunnel interface"
    return 1
}

rm -f "$READY_FILE"
log "starting UniVPN single-VPN minimal entrypoint"
log "profile=${VPN_PROFILE_NAME} server=${VPN_SERVER:-unset} port=${VPN_PORT}"

ensure_univpn_home
ensure_tun_device
echo 1 > /proc/sys/net/ipv4/ip_forward 2>/dev/null || true
sync_persisted_config_to_runtime

if import_profile_from_env; then
    PROFILE_PREPARED="true"
    PROFILE_PREPARED_SOURCE="imported"
fi

if [[ "$PROFILE_PREPARED_SOURCE" != "imported" ]]; then
    if ensure_generated_profile_matches_env; then
        PROFILE_PREPARED="true"
        PROFILE_PREPARED_SOURCE="generated"
    fi
fi

if ! has_runtime_profile; then
    if generate_profile_from_env; then
        PROFILE_PREPARED="true"
        PROFILE_PREPARED_SOURCE="generated"
    fi
fi

if ! has_runtime_profile; then
    if create_profile_from_env; then
        PROFILE_PREPARED="true"
        PROFILE_PREPARED_SOURCE="bootstrapped"
    fi
fi

if ! has_runtime_profile; then
    log "no usable profile found; provide config/*.ini, VPN_CONFIG_PATH, VPN_CONFIG_B64, or enable bootstrap with VPN_SERVER/VPN_USER/VPN_PASSWORD"
    exit 1
fi

if [[ "$PROFILE_PREPARED" == "true" ]]; then
    sync_persisted_config_to_runtime
fi

seed_sysconfig_session_profile

if [[ "$PROFILE_PREPARED_SOURCE" == "imported" && "$IMPORTED_PROFILE_SETTLE_SECONDS" != "0" ]]; then
    log "waiting ${IMPORTED_PROFILE_SETTLE_SECONDS}s for imported UniVPN profile state to settle"
    sleep "$IMPORTED_PROFILE_SETTLE_SECONDS"
fi

if [[ "$PROFILE_PREPARED_SOURCE" == "bootstrapped" && "$BOOTSTRAP_PROFILE_SETTLE_SECONDS" != "0" ]]; then
    log "waiting ${BOOTSTRAP_PROFILE_SETTLE_SECONDS}s for bootstrapped UniVPN profile state to settle"
    sleep "$BOOTSTRAP_PROFILE_SETTLE_SECONDS"
fi

print_profiles

if [[ -z "${VPN_USER:-}" || -z "${VPN_PASSWORD:-}" ]]; then
    log "VPN_USER and VPN_PASSWORD are required for CLI login"
    exit 1
fi

START_TS="$SECONDS"
log "launching UniVPNCS CLI login"
/usr/local/bin/connect.exp "$VPN_PROFILE_NAME" "$VPN_USER" "$VPN_PASSWORD" &
CLI_PID=$!

if [[ "$UNIVPN_REQUIRE_TUN" == "true" ]]; then
    wait_for_tunnel "$START_TS"
else
    touch "$READY_FILE"
    log "UNIVPN_REQUIRE_TUN=false, skipping tunnel wait"
fi

wait "$CLI_PID"
CLI_EXIT_CODE=$?
rm -f "$READY_FILE"
log "UniVPNCS/connect.exp exited with code ${CLI_EXIT_CODE}"
exit "$CLI_EXIT_CODE"
