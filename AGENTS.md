# Repository Guidelines

## Project Structure & Module Organization

This repository is delivery-oriented. Keep runnable assets in the owning
variant directory under `delivery/`, not at the repo root.

- `delivery/univpn-sidecar-single-vpn-minimal/`: active UniVPN sidecar image
  used for Kubernetes sidecar/initContainer workflows.

Inside the delivery directory, keep runtime control in `entrypoint.sh`, health
checks in `healthcheck.sh`, interactive automation in `configure.exp` and
`connect.exp`, and operator examples in `examples/`.

## Build, Test, and Development Commands

Run commands from `delivery/univpn-sidecar-single-vpn-minimal/`.

- `cp examples/.env.example .env`: create a local env file before testing.
- `./build.sh dev`: build the container image as `univpn-sidecar:dev`.
- `docker run -d --privileged --cap-add NET_ADMIN --cap-add NET_RAW --cap-add SYS_MODULE --device /dev/net/tun:/dev/net/tun --env-file .env univpn-sidecar:dev`: smoke test locally.
- `kubectl apply --dry-run=client -f k8s-res-univpn.yaml`: validate the standalone Kubernetes example.
- `kubectl apply --dry-run=client -f k8s-sidecar-initcontainer-example.yaml`: validate the sidecar initContainer example.

## Coding Style & Naming Conventions

Use Bash-first conventions: `#!/bin/bash`, `set -euo pipefail`, 4-space
indentation in shell scripts, and uppercase names for env vars such as
`VPN_SERVER` or `UNIVPN_CONNECT_TIMEOUT`. Use 2-space indentation in YAML.
Prefer descriptive kebab-case file names.

## Testing Guidelines

There is no formal unit-test suite. Validate changes with:

- `bash -n build.sh entrypoint.sh healthcheck.sh`
- `expect -n configure.exp` and `expect -n connect.exp`
- a local container smoke test when the vendor installer is available
- `kubectl apply --dry-run=client` for any YAML you touched

## Commit & Pull Request Guidelines

Follow Conventional Commits, for example `feat(sidecar): ...` or
`fix(sidecar): ...`. Keep PRs scoped to the delivery variant, describe behavior
changes, and list the commands you used for validation.

## Security & Configuration Tips

Do not commit real `.env` files, VPN credentials, generated `.ini` profiles,
vendor installers, runtime logs, or local image tarballs. Keep templates in
`examples/`, and assume anything under `stringData` must be sanitized before
review.
