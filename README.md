# UniVPN Sidecar Container

This repository packages a UniVPN Linux client into a container image for
Kubernetes workloads that need a VPN tunnel before the main workload starts.
The public source focuses on the single-VPN sidecar/initContainer flow that is
used in production-like Kubernetes Jobs.

## What It Provides

- A lightweight UniVPN CLI container with no desktop, VNC, or multi-VPN logic.
- Fast profile startup from `VPN_SERVER`, `VPN_PORT`, and `VPN_PROFILE_NAME`.
- Optional profile preload via mounted `.ini` files or `VPN_CONFIG_B64`.
- Kubernetes sidecar initContainer examples for workloads that need the tunnel.
- Graceful shutdown support: when Kubernetes stops the container, the wrapper
  sends `q` to `UniVPNCS` before falling back to process termination.

## Layout

- `delivery/univpn-sidecar-single-vpn-minimal/`: Docker build files, runtime
  scripts, health checks, and Kubernetes examples for the sidecar image.

## Third-Party Binary Notice

The UniVPN Linux installer is a third-party binary and is not redistributed in
this repository. To build the image, place the vendor-provided installer at:

```text
delivery/univpn-sidecar-single-vpn-minimal/univpn-linux-64-10781.18.1.0512.run
```

The MIT license in this repository applies to the scripts, manifests, and
documentation here. It does not grant rights to redistribute the UniVPN client.

## Quick Start

```bash
cd delivery/univpn-sidecar-single-vpn-minimal
cp examples/.env.example .env
./build.sh dev
docker run -d --name univpn-sidecar-test \
  --privileged \
  --cap-add NET_ADMIN \
  --cap-add NET_RAW \
  --cap-add SYS_MODULE \
  --device /dev/net/tun:/dev/net/tun \
  --env-file .env \
  univpn-sidecar:dev
```

For Kubernetes examples, see:

- `delivery/univpn-sidecar-single-vpn-minimal/k8s-res-univpn.yaml`
- `delivery/univpn-sidecar-single-vpn-minimal/k8s-sidecar-initcontainer-example.yaml`

## Safety Notes

Do not commit real VPN credentials, generated profiles, vendor installers,
runtime logs, or local image tarballs. Keep real configuration in Kubernetes
Secrets, private `.env` files, or your own secret manager.
