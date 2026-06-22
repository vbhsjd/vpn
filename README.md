# UniVPN SOCKS5 Proxy Container

This repository packages a UniVPN client into a container that exposes a local SOCKS5 proxy. It is intended for Kubernetes sidecar or standalone proxy scenarios where outbound traffic must traverse UniVPN.

## Layout

- `delivery/univpn-socks5-proxy/`: Docker build files, runtime scripts, health checks, and Kubernetes examples.
- `docs/superpowers/`: design notes and implementation history.

## Third-Party Binary Notice

The UniVPN Linux installer is a third-party binary and is not redistributed in this repository. To build the image, place the vendor-provided installer at:

```text
delivery/univpn-socks5-proxy/univpn-linux-64-10781.18.1.0512.run
```

## Quick Start

```bash
cd delivery/univpn-socks5-proxy
cp examples/.env.example .env
./build.sh dev
docker run -d --name univpn-proxy-test \
  --privileged \
  --cap-add NET_ADMIN \
  --device /dev/net/tun \
  --env-file .env \
  -p 1080:1080 \
  univpn-socks5-proxy:dev
```

## Notes

- The current delivery flow targets `linux/amd64`.
- Kubernetes deployments require `/dev/net/tun` plus `NET_ADMIN`.
- Do not commit real VPN credentials, generated profiles, vendor installers, or runtime logs.

## Status

The current public focus is the single-container SOCKS5 proxy flow under `delivery/univpn-socks5-proxy`. Local-only tarballs and other packaging artifacts are intentionally excluded from version control.
