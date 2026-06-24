# UniVPN SOCKS5 Proxy Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Create `delivery/univpn-socks5-proxy/` — a persistent K8s Deployment that maintains two UniVPN connections and exposes a single SOCKS5 proxy (port 1080) for Ansible Jobs in the `res` namespace.

**Architecture:** Two UniVPN instances run via `unshare --mount` (private `/run` per instance, shared network namespace). Both VPN interfaces appear in the pod's kernel routing table; a single microsocks process proxies all SOCKS5 traffic and the kernel routes each connection to the correct VPN interface by destination IP.

**Tech Stack:** Ubuntu 22.04, UniVPN CLI (expect automation), microsocks (compiled from source, multi-stage Docker build), Kubernetes (Deployment + ClusterIP Service + Secret), Ansible ssh ProxyCommand via `nc`.

---

## File Map

| File | Purpose |
|------|---------|
| `delivery/univpn-socks5-proxy/Dockerfile` | Multi-stage: build microsocks, install UniVPN + deps |
| `delivery/univpn-socks5-proxy/entrypoint.sh` | Dual-VPN startup + microsocks start + hold |
| `delivery/univpn-socks5-proxy/configure.exp` | VPN profile creation (HOME-parameterized via `UNIVPN_HOME` env) |
| `delivery/univpn-socks5-proxy/connect.exp` | VPN login/keepalive (HOME-parameterized via `UNIVPN_HOME` env) |
| `delivery/univpn-socks5-proxy/healthcheck.sh` | Check microsocks alive + ≥1 cnem* interface |
| `delivery/univpn-socks5-proxy/build.sh` | Parameterized docker build |
| `delivery/univpn-socks5-proxy/k8s-res-univpn-socks5-proxy.yaml` | Deployment + Service + Secret |
| `delivery/univpn-socks5-proxy/examples/.env.example` | VPN1+VPN2 env vars |
| `delivery/univpn-socks5-proxy/examples/ansible-inventory-example.ini` | ProxyCommand usage |
| `delivery/univpn-socks5-proxy/.dockerignore` | Exclude logs, .env, etc |

---

### Task 1: Scaffold directory and Dockerfile

**Files:**
- Create: `delivery/univpn-socks5-proxy/Dockerfile`
- Create: `delivery/univpn-socks5-proxy/.dockerignore`

- [ ] **Step 1.1: Create directory**

```bash
mkdir -p delivery/univpn-socks5-proxy/examples
```

- [ ] **Step 1.2: Create .dockerignore**

Create `delivery/univpn-socks5-proxy/.dockerignore`:

```
.env
*.log
logs/
config/
*.tar
*.zip
```

- [ ] **Step 1.3: Write Dockerfile**

Create `delivery/univpn-socks5-proxy/Dockerfile`:

```dockerfile
ARG BASE_IMAGE=swr.cn-north-4.myhuaweicloud.com/ddn-k8s/docker.io/ubuntu:22.04

# Stage 1: build microsocks
FROM ${BASE_IMAGE} AS microsocks-builder
ARG APT_MIRROR=http://repo.huaweicloud.com/ubuntu

RUN set -eux; \
    if [ -n "${APT_MIRROR}" ]; then \
        if [ -f /etc/apt/sources.list ]; then \
            sed -i "s@http://[^ ]*archive.ubuntu.com/ubuntu@${APT_MIRROR}@g; s@http://[^ ]*security.ubuntu.com/ubuntu@${APT_MIRROR}@g" /etc/apt/sources.list; \
        fi; \
        if [ -f /etc/apt/sources.list.d/ubuntu.sources ]; then \
            sed -i "s@http://[^ ]*archive.ubuntu.com/ubuntu@${APT_MIRROR}@g; s@http://[^ ]*security.ubuntu.com/ubuntu@${APT_MIRROR}@g" /etc/apt/sources.list.d/ubuntu.sources; \
        fi; \
    fi; \
    apt-get update && apt-get install -y gcc make git ca-certificates \
    && rm -rf /var/lib/apt/lists/*

RUN git clone --depth 1 https://github.com/rofl0r/microsocks /tmp/microsocks \
    && cd /tmp/microsocks && make

# Stage 2: runtime image
FROM ${BASE_IMAGE}
ARG APT_MIRROR=http://repo.huaweicloud.com/ubuntu

RUN set -eux; \
    if [ -n "${APT_MIRROR}" ]; then \
        if [ -f /etc/apt/sources.list ]; then \
            sed -i "s@http://[^ ]*archive.ubuntu.com/ubuntu@${APT_MIRROR}@g; s@http://[^ ]*security.ubuntu.com/ubuntu@${APT_MIRROR}@g" /etc/apt/sources.list; \
        fi; \
        if [ -f /etc/apt/sources.list.d/ubuntu.sources ]; then \
            sed -i "s@http://[^ ]*archive.ubuntu.com/ubuntu@${APT_MIRROR}@g; s@http://[^ ]*security.ubuntu.com/ubuntu@${APT_MIRROR}@g" /etc/apt/sources.list.d/ubuntu.sources; \
        fi; \
    fi; \
    apt-get update && apt-get install -y \
    libxcb-xinerama0 libxcb-xinput0 libxcb-icccm4 libxcb-image0 \
    libxcb-keysyms1 libxcb-randr0 libxcb-render-util0 libxcb-shape0 \
    libxcb-xfixes0 libxcb-sync1 libxcb-util1 libxcb-xkb1 \
    libxkbcommon-x11-0 libfontconfig1 libfreetype6 libglib2.0-0 \
    libdbus-1-3 libssl3 ca-certificates \
    iproute2 iptables net-tools procps kmod psmisc \
    expect util-linux \
    netcat-openbsd \
    xvfb x11-utils xz-utils libxcb1 libx11-xcb1 libxrender1 libxi6 libxext6 libxkbcommon0 \
    && rm -rf /var/lib/apt/lists/*

COPY --from=microsocks-builder /tmp/microsocks/microsocks /usr/local/bin/microsocks
RUN chmod +x /usr/local/bin/microsocks

WORKDIR /opt/univpn

COPY univpn-linux-64-10781.18.1.0512.run /tmp/
RUN chmod +x /tmp/univpn-linux-64-10781.18.1.0512.run \
    && mkdir -p /usr/local/UniVPN \
    && cd /tmp \
    && tail -n +258 univpn-linux-64-10781.18.1.0512.run > UniVPN.tar.gz \
    && tar -xzf UniVPN.tar.gz -C /usr/local/UniVPN \
    && rm -f /tmp/*.run /tmp/*.tar.gz

RUN mkdir -p /usr/local/UniVPN/log /usr/local/UniVPN/config /usr/local/UniVPN/certificate \
    /root/UniVPN/config /dev/net \
    && chmod a+w /usr/local/UniVPN/log /root/UniVPN/config /usr/local/UniVPN/config \
    && chmod 755 /usr/local/UniVPN/certificate \
    && chmod u+s /usr/local/UniVPN/serviceclient/UniVPNCS \
    && mv /usr/local/UniVPN/serviceclient/libgmcrypto.so /lib/ \
    && mknod /dev/net/tun c 10 200 2>/dev/null || true \
    && chmod 600 /dev/net/tun 2>/dev/null || true

COPY entrypoint.sh healthcheck.sh configure.exp connect.exp /usr/local/bin/
RUN chmod +x /usr/local/bin/entrypoint.sh /usr/local/bin/healthcheck.sh \
    /usr/local/bin/configure.exp /usr/local/bin/connect.exp

ENV HOME=/root
ENV USER=root
ENV LOGNAME=root
ENV XDG_CONFIG_HOME=/root/.config
ENV LD_LIBRARY_PATH=/usr/local/UniVPN/lib:/usr/local/UniVPN/serviceclient

EXPOSE 1080

HEALTHCHECK --interval=30s --timeout=10s --start-period=90s --retries=3 \
    CMD ["/usr/local/bin/healthcheck.sh"]

ENTRYPOINT ["/usr/local/bin/entrypoint.sh"]
```

- [ ] **Step 1.4: Copy installer binary into new directory**

```bash
cp delivery/univpn-sidecar-fixed/univpn-linux-64-10781.18.1.0512.run \
   delivery/univpn-socks5-proxy/
```

- [ ] **Step 1.5: Verify build succeeds**

```bash
cd delivery/univpn-socks5-proxy
docker build -t univpn-socks5-proxy:test .
```

Expected: `Successfully built` (no errors). microsocks binary should be present:

```bash
docker run --rm univpn-socks5-proxy:test microsocks --help 2>&1 | head -5
```

Expected output contains: `microsocks` usage info or exits with code 1 (it prints usage to stderr and exits 1 when no args given — that's fine).

- [ ] **Step 1.6: Commit**

```bash
git add delivery/univpn-socks5-proxy/Dockerfile delivery/univpn-socks5-proxy/.dockerignore
git commit -m "feat(socks5-proxy): add Dockerfile with microsocks multi-stage build"
```

---

### Task 2: configure.exp and connect.exp (HOME-parameterized)

**Files:**
- Create: `delivery/univpn-socks5-proxy/configure.exp`
- Create: `delivery/univpn-socks5-proxy/connect.exp`

These are adapted from `delivery/univpn-sidecar-fixed/` with one change: `set env(HOME)` reads `UNIVPN_HOME` environment variable instead of hardcoding `/root`. This allows two instances to use separate home directories without sed-patching the scripts at runtime.

- [ ] **Step 2.1: Write configure.exp**

Create `delivery/univpn-socks5-proxy/configure.exp`:

```tcl
#!/usr/bin/expect -f

set timeout 20

if {[llength $argv] < 3} {
    puts "Usage: $argv0 <server> <username> <password> ?port? ?profile_name?"
    exit 1
}

set server [lindex $argv 0]
set user [lindex $argv 1]
set pass [lindex $argv 2]
set port [lindex $argv 3]
set profile [lindex $argv 4]

if {$port eq ""} {
    set port "443"
}

if {$profile eq ""} {
    set profile $server
}

proc fail {message} {
    puts $message
    exit 1
}

if {[info exists env(UNIVPN_HOME)] && $env(UNIVPN_HOME) ne ""} {
    set env(HOME) $env(UNIVPN_HOME)
} else {
    set env(HOME) /root
}
set env(LD_LIBRARY_PATH) /usr/local/UniVPN/lib:/usr/local/UniVPN/serviceclient

spawn /usr/local/UniVPN/serviceclient/UniVPNCS

expect {
    "Welcome to UniVPN!" {}
    timeout { fail "UniVPNCS 启动超时" }
}

expect {
    "1:New Connection" { send "1\r" }
    timeout { fail "未进入连接创建菜单" }
}

expect {
    "Please choose Connection Type" { send "1\r" }
    timeout { fail "未进入连接类型菜单" }
}

expect {
    "SSL Configuration" {}
    timeout { fail "未进入 SSL 配置菜单" }
}

expect {
    -re {1:Connection Name\(Required\):.*} {}
    -re {1:Connection Name\(can not modify\):.*} {}
    timeout { fail "未找到连接名称字段" }
}
send "1\r"

expect {
    "Please Input Connection Name" { send "$profile\r" }
    "Connection Name can not modify" {}
    timeout { fail "设置连接名称失败" }
}

expect {
    -re {3:Gateway Address\(Required\):.*} {}
    timeout { fail "未找到网关地址字段" }
}
send "3\r"

expect {
    "Please Input Gateway Address" { send "$server\r" }
    timeout { fail "设置网关地址失败" }
}

if {$port ne "443"} {
    expect {
        -re {4:.*} { send "4\r" }
        timeout {}
    }

    expect {
        "Please Input Port(1-65535)" { send "$port\r" }
        timeout {}
    }
}

expect {
    "7:Save" { send "7\r" }
    timeout { fail "未找到保存入口" }
}

expect {
    "Error:Save error." { fail "保存配置失败" }
    "Welcome to UniVPN!" {}
    timeout { fail "保存配置超时" }
}

expect {
    "Please input the login user name" {
        send "$user\r"
        exp_continue
    }
    "Please input the login user password" {
        send "$pass\r"
        exp_continue
    }
    "Authentication failed." { fail "UniVPN 认证失败" }
    "Connection attempts timed out due to a configuration or network fault." { fail "UniVPN 连接超时" }
    "Welcome to UniVPN!" {
        send "2\r"
        exp_continue
    }
    eof {}
    timeout {}
}
```

- [ ] **Step 2.2: Write connect.exp**

Create `delivery/univpn-socks5-proxy/connect.exp`:

```tcl
#!/usr/bin/expect -f

set timeout 20

if {[llength $argv] < 3} {
    puts "Usage: $argv0 <profile_name> <username> <password>"
    exit 1
}

set profile [lindex $argv 0]
set user [lindex $argv 1]
set pass [lindex $argv 2]
set profile_menu_index ""
set profile_candidate_indexes {}
set user_sent 0
set pass_sent 0
set connect_success 0
set menu_scan_timeout 10

proc fail {message} {
    puts $message
    exit 1
}

if {[info exists env(UNIVPN_HOME)] && $env(UNIVPN_HOME) ne ""} {
    set env(HOME) $env(UNIVPN_HOME)
} else {
    set env(HOME) /root
}
set env(USER) root
set env(LOGNAME) root
if {[info exists env(UNIVPN_HOME)] && $env(UNIVPN_HOME) ne ""} {
    set env(XDG_CONFIG_HOME) "$env(UNIVPN_HOME)/.config"
} else {
    set env(XDG_CONFIG_HOME) /root/.config
}
set env(LD_LIBRARY_PATH) /usr/local/UniVPN/lib:/usr/local/UniVPN/serviceclient

if {[info exists env(UNIVPN_MENU_SCAN_TIMEOUT)] && $env(UNIVPN_MENU_SCAN_TIMEOUT) ne ""} {
    set menu_scan_timeout $env(UNIVPN_MENU_SCAN_TIMEOUT)
}

set univpncs_bin "/usr/local/UniVPN/serviceclient/UniVPNCS"
if {[info exists env(UNIVPNCS_BIN)] && $env(UNIVPNCS_BIN) ne ""} {
    set univpncs_bin $env(UNIVPNCS_BIN)
}

spawn $univpncs_bin

expect {
    "Welcome to UniVPN!" {}
    timeout { fail "UniVPNCS 启动超时" }
    eof { fail "UniVPNCS 启动异常退出" }
}

set timeout $menu_scan_timeout
expect {
    -re {([0-9]+):([^\r\n]+)} {
        set menu_index $expect_out(1,string)
        set menu_label [string trim $expect_out(2,string)]
        if {$menu_label eq $profile} {
            set profile_menu_index $menu_index
        } elseif {$menu_index > 2} {
            lappend profile_candidate_indexes $menu_index
        }
        exp_continue
    }
    timeout {}
    eof {}
}
set timeout 20

if {$profile_menu_index eq ""} {
    set unique_profile_candidates [lsort -unique $profile_candidate_indexes]
    if {[llength $unique_profile_candidates] == 1} {
        set profile_menu_index [lindex $unique_profile_candidates 0]
    } else {
        fail "未找到连接配置: $profile"
    }
}

send "$profile_menu_index\r"

expect {
    "1:Connect" { send "1\r" }
    timeout { fail "未进入连接菜单" }
    eof { fail "连接菜单异常退出" }
}

expect {
    "Connect success." { exp_continue }
    "Please input the login user name" {
        send "$user\r"
        set user_sent 1
        exp_continue
    }
    "Please input the login user password" {
        send "$pass\r"
        set pass_sent 1
        exp_continue
    }
    "Successful login." { exp_continue }
    "Succeeded in enabling network extension." {
        set connect_success 1
        set timeout -1
        exp_continue
    }
    "Connect Success,Enjoy!(^_^)" {
        set connect_success 1
        set timeout -1
        exp_continue
    }
    "q:Disconnect" {
        set connect_success 1
        set timeout -1
        exp_continue
    }
    "Authentication failed." { fail "UniVPN 认证失败" }
    "ssl connect failed! reason: login failed" { fail "UniVPN 认证失败" }
    "Connection attempts timed out due to a configuration or network fault." { fail "UniVPN 连接超时" }
    "Welcome to UniVPN!" {
        if {$connect_success} {
            exit 0
        }
        exp_continue
    }
    eof {
        if {$connect_success} {
            exit 0
        }
        fail "UniVPNCS 连接流程异常退出"
    }
    timeout {
        fail "UniVPNCS 连接流程超时"
    }
}
```

- [ ] **Step 2.3: Verify diff from fixed/**

```bash
diff delivery/univpn-sidecar-fixed/configure.exp delivery/univpn-socks5-proxy/configure.exp
diff delivery/univpn-sidecar-fixed/connect.exp   delivery/univpn-socks5-proxy/connect.exp
```

Expected: only the `set env(HOME)` block differs — no other changes.

- [ ] **Step 2.4: Commit**

```bash
git add delivery/univpn-socks5-proxy/configure.exp delivery/univpn-socks5-proxy/connect.exp
git commit -m "feat(socks5-proxy): add HOME-parameterized configure.exp and connect.exp"
```

---

### Task 3: healthcheck.sh

**Files:**
- Create: `delivery/univpn-socks5-proxy/healthcheck.sh`

- [ ] **Step 3.1: Write healthcheck.sh**

Create `delivery/univpn-socks5-proxy/healthcheck.sh`:

```bash
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
```

- [ ] **Step 3.2: Verify syntax**

```bash
bash -n delivery/univpn-socks5-proxy/healthcheck.sh && echo "syntax OK"
```

Expected: `syntax OK`

- [ ] **Step 3.3: Commit**

```bash
git add delivery/univpn-socks5-proxy/healthcheck.sh
git commit -m "feat(socks5-proxy): add healthcheck.sh"
```

---

### Task 4: entrypoint.sh

**Files:**
- Create: `delivery/univpn-socks5-proxy/entrypoint.sh`

This is the core of the new delivery. Key design:
- `setup_vpn_home DIR` — creates dirs, copies sysconfig.ini template
- `generate_vpn_profile DIR SERVER USER PASS PORT NAME [CONFIG_B64]` — creates `.ini` profile via configure.exp or decodes b64, runs INSIDE unshare (because configure.exp also triggers UniVPNCS which grabs the lock)
- `seed_sysconfig DIR PROFILE_NAME` — writes `[Session0]` block to sysconfig.ini
- `start_vpn DIR PROFILE USER PASS` — `unshare --mount` → private /run → connect.exp (background)
- `count_cnem_interfaces` — returns number of `cnem*` interfaces
- `wait_for_cnem_count N TIMEOUT` — polls until N interfaces exist

- [ ] **Step 4.1: Write entrypoint.sh**

Create `delivery/univpn-socks5-proxy/entrypoint.sh`:

```bash
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

VPN1_PID=""
VPN2_PID=""
MICROSOCKS_PID=""

cleanup() {
    local exit_code=$?
    for pid_var in MICROSOCKS_PID VPN2_PID VPN1_PID; do
        local pid="${!pid_var:-}"
        if [[ -n "$pid" ]] && kill -0 "$pid" 2>/dev/null; then
            kill "$pid" 2>/dev/null || true
        fi
    done
    exit "$exit_code"
}
trap cleanup EXIT INT TERM

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
    # Must run inside unshare context (UniVPNCS needs private /run)
    # Called as: generate_profile_configure HOME SERVER USER PASS PORT NAME
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

    # Copy generated profile from UniVPN default config dir to our home
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
```

- [ ] **Step 4.2: Verify syntax**

```bash
bash -n delivery/univpn-socks5-proxy/entrypoint.sh && echo "syntax OK"
```

Expected: `syntax OK`

- [ ] **Step 4.3: Commit**

```bash
git add delivery/univpn-socks5-proxy/entrypoint.sh
git commit -m "feat(socks5-proxy): add dual-VPN entrypoint with microsocks"
```

---

### Task 5: build.sh

**Files:**
- Create: `delivery/univpn-socks5-proxy/build.sh`

- [ ] **Step 5.1: Write build.sh**

Create `delivery/univpn-socks5-proxy/build.sh`:

```bash
#!/bin/bash
set -euo pipefail

DEFAULT_IMAGE_NAME="${IMAGE_NAME:-univpn-socks5-proxy}"
INPUT_REF="${1:-latest}"
BASE_IMAGE="${BASE_IMAGE:-swr.cn-north-4.myhuaweicloud.com/ddn-k8s/docker.io/ubuntu:22.04}"
APT_MIRROR="${APT_MIRROR:-http://repo.huaweicloud.com/ubuntu}"
DOCKER_BUILDKIT_MODE="${DOCKER_BUILDKIT:-1}"

if [[ "$INPUT_REF" == *"/"* || "$INPUT_REF" == *":"* ]]; then
    IMAGE_REF="$INPUT_REF"
else
    IMAGE_REF="${DEFAULT_IMAGE_NAME}:${INPUT_REF}"
fi

echo "========================================"
echo "构建 UniVPN SOCKS5 Proxy 镜像"
echo "镜像: ${IMAGE_REF}"
echo "基础镜像: ${BASE_IMAGE}"
echo "APT 镜像源: ${APT_MIRROR}"
echo "========================================"

if [[ ! -f "univpn-linux-64-10781.18.1.0512.run" ]]; then
    echo "错误: 未找到安装文件 univpn-linux-64-10781.18.1.0512.run"
    exit 1
fi

DOCKER_BUILDKIT="${DOCKER_BUILDKIT_MODE}" docker build \
    --build-arg "BASE_IMAGE=${BASE_IMAGE}" \
    --build-arg "APT_MIRROR=${APT_MIRROR}" \
    -t "${IMAGE_REF}" .

echo ""
echo "========================================"
echo "构建完成: ${IMAGE_REF}"
echo ""
echo "测试运行:"
echo "  cp examples/.env.example .env  # 填入真实凭据"
echo "  docker run -d --name univpn-proxy-test \\"
echo "    --privileged --cap-add NET_ADMIN --device /dev/net/tun \\"
echo "    --env-file .env -p 1080:1080 ${IMAGE_REF}"
echo "========================================"
```

- [ ] **Step 5.2: Make executable and verify**

```bash
chmod +x delivery/univpn-socks5-proxy/build.sh
bash -n delivery/univpn-socks5-proxy/build.sh && echo "syntax OK"
```

- [ ] **Step 5.3: Commit**

```bash
git add delivery/univpn-socks5-proxy/build.sh
git commit -m "feat(socks5-proxy): add build.sh"
```

---

### Task 6: K8s manifest

**Files:**
- Create: `delivery/univpn-socks5-proxy/k8s-res-univpn-socks5-proxy.yaml`

- [ ] **Step 6.1: Write k8s-res-univpn-socks5-proxy.yaml**

Create `delivery/univpn-socks5-proxy/k8s-res-univpn-socks5-proxy.yaml`:

```yaml
# UniVPN SOCKS5 Proxy — K8s resources (namespace: res)
# Secret values must be base64-encoded.
# Usage: kubectl apply -f k8s-res-univpn-socks5-proxy.yaml -n res

---
apiVersion: v1
kind: Secret
metadata:
  name: univpn-proxy-secret
  namespace: res
type: Opaque
stringData:
  VPN_SERVER: "vpn1.example.com"
  VPN_PORT: "443"
  VPN_USER: "user1"
  VPN_PASSWORD: "password1"
  VPN2_SERVER: "vpn2.example.com"
  VPN2_PORT: "443"
  VPN2_USER: "user2"
  VPN2_PASSWORD: "password2"

---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: univpn-socks5-proxy
  namespace: res
  labels:
    app: univpn-socks5-proxy
spec:
  replicas: 1
  selector:
    matchLabels:
      app: univpn-socks5-proxy
  template:
    metadata:
      labels:
        app: univpn-socks5-proxy
    spec:
      containers:
        - name: univpn-socks5-proxy
          image: univpn-socks5-proxy:latest
          imagePullPolicy: IfNotPresent
          ports:
            - name: socks5
              containerPort: 1080
              protocol: TCP
          envFrom:
            - secretRef:
                name: univpn-proxy-secret
          env:
            - name: UNIVPN_CONNECT_TIMEOUT
              value: "120"
          securityContext:
            privileged: true
            capabilities:
              add:
                - NET_ADMIN
                - NET_RAW
                - SYS_MODULE
          volumeMounts:
            - name: tun-device
              mountPath: /dev/net/tun
          readinessProbe:
            exec:
              command: ["test", "-f", "/tmp/univpn-proxy-ready"]
            initialDelaySeconds: 30
            periodSeconds: 5
            failureThreshold: 24
          livenessProbe:
            exec:
              command: ["/usr/local/bin/healthcheck.sh"]
            initialDelaySeconds: 90
            periodSeconds: 30
            failureThreshold: 3
          resources:
            requests:
              memory: "256Mi"
              cpu: "100m"
            limits:
              memory: "512Mi"
              cpu: "500m"
      volumes:
        - name: tun-device
          hostPath:
            path: /dev/net/tun
            type: CharDevice

---
apiVersion: v1
kind: Service
metadata:
  name: univpn-socks5-proxy-svc
  namespace: res
  labels:
    app: univpn-socks5-proxy
spec:
  type: ClusterIP
  selector:
    app: univpn-socks5-proxy
  ports:
    - name: socks5
      port: 1080
      targetPort: 1080
      protocol: TCP
```

- [ ] **Step 6.2: Validate YAML syntax**

```bash
kubectl apply --dry-run=client -f delivery/univpn-socks5-proxy/k8s-res-univpn-socks5-proxy.yaml -n res
```

Expected: `...configured (dry run)` for each resource, no errors.

- [ ] **Step 6.3: Commit**

```bash
git add delivery/univpn-socks5-proxy/k8s-res-univpn-socks5-proxy.yaml
git commit -m "feat(socks5-proxy): add K8s Deployment + Service + Secret manifest"
```

---

### Task 7: Examples

**Files:**
- Create: `delivery/univpn-socks5-proxy/examples/.env.example`
- Create: `delivery/univpn-socks5-proxy/examples/ansible-inventory-example.ini`

- [ ] **Step 7.1: Write .env.example**

Create `delivery/univpn-socks5-proxy/examples/.env.example`:

```bash
# VPN1 credentials
VPN_SERVER=vpn1.example.com
VPN_PORT=443
VPN_USER=your_username
VPN_PASSWORD=your_password
VPN_PROFILE_NAME=vpn1

# VPN2 credentials
VPN2_SERVER=vpn2.example.com
VPN2_PORT=443
VPN2_USER=your_username2
VPN2_PASSWORD=your_password2
VPN2_PROFILE_NAME=vpn2

# Optional: provide pre-built profile as base64 (skips configure.exp)
# VPN_CONFIG_B64=<base64 of .ini profile>
# VPN2_CONFIG_B64=<base64 of .ini profile>

# Optional tuning
# UNIVPN_CONNECT_TIMEOUT=120
# MICROSOCKS_PORT=1080
```

- [ ] **Step 7.2: Write ansible-inventory-example.ini**

Create `delivery/univpn-socks5-proxy/examples/ansible-inventory-example.ini`:

```ini
# Ansible inventory example for use with univpn-socks5-proxy
#
# Prerequisites (in Ansible Job container):
#   apt-get install -y netcat-openbsd
#
# The ProxyCommand routes SSH through the SOCKS5 proxy.
# The kernel routing table inside the proxy pod routes traffic
# to the correct VPN interface automatically by destination IP.

[internal_vpn1]
host-a ansible_host=10.1.0.10
host-b ansible_host=10.1.0.11

[internal_vpn2]
host-c ansible_host=10.2.0.10

[internal_vpn1:vars]
ansible_ssh_common_args='-o StrictHostKeyChecking=no -o ProxyCommand="nc -x univpn-socks5-proxy-svc:1080 %h %p"'

[internal_vpn2:vars]
ansible_ssh_common_args='-o StrictHostKeyChecking=no -o ProxyCommand="nc -x univpn-socks5-proxy-svc:1080 %h %p"'
```

- [ ] **Step 7.3: Commit**

```bash
git add delivery/univpn-socks5-proxy/examples/
git commit -m "feat(socks5-proxy): add examples (.env + ansible inventory)"
```

---

### Task 8: Deploy and smoke test

- [ ] **Step 8.1: Build image**

```bash
cd delivery/univpn-socks5-proxy
IMAGE_NAME=univpn-socks5-proxy ./build.sh latest
```

Expected: `构建完成: univpn-socks5-proxy:latest`

- [ ] **Step 8.2: Update Secret with real credentials, then apply**

Edit the `stringData` section of `k8s-res-univpn-socks5-proxy.yaml` with real VPN credentials, then:

```bash
kubectl apply -f delivery/univpn-socks5-proxy/k8s-res-univpn-socks5-proxy.yaml -n res
```

Expected: `secret/univpn-proxy-secret created`, `deployment.apps/univpn-socks5-proxy created`, `service/univpn-socks5-proxy-svc created`

- [ ] **Step 8.3: Watch pod come up**

```bash
kubectl rollout status deployment/univpn-socks5-proxy -n res --timeout=300s
```

Expected: `deployment "univpn-socks5-proxy" successfully rolled out`

- [ ] **Step 8.4: Verify VPN interfaces inside pod**

```bash
kubectl exec -n res deployment/univpn-socks5-proxy -- \
    ip -o link show | grep cnem
```

Expected: at least two `cnem*` lines (one per VPN). If only one line — shared network namespace interface naming conflict; see Fallback section.

- [ ] **Step 8.5: Verify microsocks is listening**

```bash
kubectl exec -n res deployment/univpn-socks5-proxy -- \
    ss -tlnp | grep 1080
```

Expected: a line showing `0.0.0.0:1080` LISTEN with `microsocks`.

- [ ] **Step 8.6: Smoke test proxy from an Ansible Job**

Deploy a test pod in `res` namespace:

```bash
kubectl run socks-test --rm -it --image=ubuntu:22.04 -n res -- bash -c "
    apt-get install -y netcat-openbsd -q &&
    nc -x univpn-socks5-proxy-svc:1080 -zv <internal-host-A-ip> 22
"
```

Expected: `Connection to <ip> 22 port [tcp/ssh] succeeded!`

- [ ] **Step 8.7: If Step 8.4 shows only one cnem* interface (fallback note)**

This means both UniVPN instances competed for the same interface name. Document this in the README and implement the `--net` + socat bridge fallback in a follow-up task. The proxy still works for VPN1 traffic.

- [ ] **Step 8.8: Final commit**

```bash
git add -A
git commit -m "feat(socks5-proxy): complete delivery — dual VPN SOCKS5 proxy for Ansible Jobs"
```
