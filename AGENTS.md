# Repository Guidelines

## Project Structure & Module Organization
This repository is delivery-oriented. Keep runnable assets in the owning variant directory under `delivery/`, not at the repo root.

- `delivery/univpn-socks5-proxy/`: active container variant with Docker build files, runtime scripts, and Kubernetes examples.
- `docs/superpowers/`: design specs and implementation plans that explain why the delivery files look the way they do.

Inside `delivery/univpn-socks5-proxy/`, keep runtime control in `entrypoint.sh`, health checks in `healthcheck.sh`, interactive automation in `configure.exp` and `connect.exp`, and operator examples in `examples/`.

## Build, Test, and Development Commands
Run commands from `delivery/univpn-socks5-proxy/`.

- `cp examples/.env.example .env`: create a local env file before testing.
- `./build.sh dev`: build the container image with the local tag `dev`.
- `docker run -d --privileged --cap-add NET_ADMIN --device /dev/net/tun --env-file .env -p 1080:1080 univpn-socks5-proxy:dev`: smoke test the proxy locally.
- `kubectl apply --dry-run=client -f k8s-res-univpn-socks5-proxy.yaml -n res`: validate the Kubernetes manifest before applying it.

## Coding Style & Naming Conventions
Use Bash-first conventions: `#!/bin/bash`, `set -euo pipefail`, 4-space indentation in shell scripts, and uppercase names for env vars such as `VPN_SERVER` or `UNIVPN_CONNECT_TIMEOUT`. Use 2-space indentation in YAML. Prefer descriptive kebab-case file names.

## Testing Guidelines
There is no formal unit-test suite. Validate changes with:

- `bash -n build.sh entrypoint.sh healthcheck.sh`
- a local container smoke test
- a `kubectl apply --dry-run=client` check for any YAML you touched

## Commit & Pull Request Guidelines
Follow Conventional Commits, for example `feat(socks5-proxy): ...` or `fix(socks5-proxy): ...`. Keep PRs scoped to one delivery variant, describe behavior changes, and list the commands you used for validation.

## Security & Configuration Tips
Do not commit real `.env` files, VPN credentials, generated `.ini` profiles, vendor installers, or local test tarballs. Keep templates in `examples/`, and assume anything under `stringData` must be sanitized before review.
