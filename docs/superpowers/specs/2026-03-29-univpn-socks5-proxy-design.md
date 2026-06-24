# UniVPN SOCKS5 Proxy — Design Spec

Date: 2026-03-29

## Problem

Ansible K8s Jobs currently spin up a UniVPN sidecar per job. VPN connection establishment
takes 60s+, making job startup slow. The goal is a persistent VPN proxy that Ansible Jobs
connect to instead, eliminating per-job VPN cold-start.

## Solution Overview

A long-running K8s Deployment in the `res` namespace maintains two UniVPN connections and
exposes a single SOCKS5 proxy (microsocks) on port 1080. Ansible Jobs set `ProxyCommand`
to route SSH through this proxy.

## Architecture

```
[Pod: univpn-socks5-proxy]  (namespace: res)
  │
  ├── microsocks (:1080)           single SOCKS5 proxy entry point
  │
  ├── unshare --mount --pid        VPN1 process isolation (shared net namespace)
  │     UniVPN → cnem_vnic
  │
  └── unshare --mount --pid        VPN2 process isolation (shared net namespace)
        UniVPN → cnem_vnic1

  kernel routing table:
    subnet_A → cnem_vnic   (set by VPN1 client automatically)
    subnet_B → cnem_vnic1  (set by VPN2 client automatically)

[K8s Service: univpn-socks5-proxy-svc]
  type: ClusterIP
  port: 1080

[Ansible Job]
  ansible_ssh_common_args: "-o ProxyCommand='nc -x univpn-socks5-proxy-svc:1080 %h %p'"
```

## Key Design Decisions

### Single SOCKS5 for Dual VPN

Both UniVPN instances run in the pod's shared network namespace (no `--net` in unshare).
Only mount/pid/ipc/uts namespaces are isolated to avoid the `univpncs.lock` conflict and
separate `$HOME`/config dirs. This allows the kernel routing table to accumulate routes
from both VPNs. microsocks proxies TCP connections; the kernel automatically picks the
correct VPN interface based on destination IP.

**Assumption**: UniVPN names the second VPN interface differently (e.g., `cnem_vnic1`)
when `cnem_vnic` already exists. This is the primary runtime risk.

**Fallback** (documented, not pre-implemented): If both instances compete for the same
interface name, switch to `--net` isolation per VPN + a socat/iptables bridge back to
the main namespace.

### microsocks

Chosen over dante/3proxy for simplicity: single binary, no config file, listens on a
port and proxies SOCKS5. Installed at build time via apt or compiled from source.

### Startup Order

1. Enable `ip_forward`
2. Launch VPN1 via `unshare` (private /run, private $HOME_VPN1) → background
3. Wait for first `cnem*` interface (VPN1 ready), write `/tmp/vpn1-ready`
4. Launch VPN2 via `unshare` (private /run2, private $HOME_VPN2) → background
5. Wait for second `cnem*` interface (VPN2 ready), write `/tmp/vpn2-ready`
6. Start microsocks on :1080
7. Write `/tmp/univpn-proxy-ready`
8. Hold (tail -f /dev/null)

### Healthcheck

Check:
- microsocks process alive (`pgrep microsocks`)
- At least one `cnem*` interface exists (VPN connectivity)

## Files

```
delivery/univpn-socks5-proxy/
  Dockerfile                         image build, installs microsocks
  entrypoint.sh                      startup logic per above
  configure.exp                      VPN profile creation (from fixed/)
  connect.exp                        VPN login automation (from fixed/)
  build.sh                           parameterized docker build
  healthcheck.sh                     microsocks + cnem* interface check
  k8s-res-univpn-socks5-proxy.yaml   Deployment + ClusterIP Service + Secret
  examples/
    .env.example                     VPN1+VPN2 env vars
    ansible-inventory-example.ini    ProxyCommand usage example
```

Existing `delivery/univpn-sidecar-fixed/` and `delivery/univpn-sidecar-job-dual-vpn/`
are **not modified**.

## K8s Resources

### Secret (`univpn-proxy-secret`)

```
VPN_SERVER, VPN_USER, VPN_PASSWORD, VPN_PORT
VPN2_SERVER, VPN2_USER, VPN2_PASSWORD, VPN2_PORT
```

### Deployment (`univpn-socks5-proxy`)

- `securityContext`: privileged, NET_ADMIN, NET_RAW, SYS_MODULE
- `volumeMounts`: `/dev/net/tun` device
- `readinessProbe`: checks `/tmp/univpn-proxy-ready` file
- `livenessProbe`: runs `healthcheck.sh`
- single replica (VPN sessions are stateful)

### Service (`univpn-socks5-proxy-svc`)

- type: ClusterIP
- port: 1080

## Ansible Usage

```ini
# inventory.ini
[internal]
host-A ansible_host=10.x.x.x

[internal:vars]
ansible_ssh_common_args='-o ProxyCommand="nc -x univpn-socks5-proxy-svc:1080 %h %p"'
```

Or in `ansible.cfg`:
```ini
[ssh_connection]
ssh_args = -o ProxyCommand="nc -x univpn-socks5-proxy-svc:1080 %h %p"
```

## Risk & Fallback

| Risk | Likelihood | Mitigation |
|------|-----------|------------|
| Both UniVPN instances create `cnem_vnic` (name conflict) | Medium | Fallback: --net isolation + socat bridge per namespace |
| VPN1 or VPN2 disconnects | Low | Healthcheck detects; K8s restarts pod |
| microsocks OOM | Very low | Single binary, negligible memory footprint |
