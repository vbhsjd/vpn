#!/bin/bash
set -euo pipefail

DEFAULT_IMAGE_NAME="${IMAGE_NAME:-univpn-sidecar}"
INPUT_REF="${1:-latest}"
BASE_IMAGE="${BASE_IMAGE:-ubuntu:22.04}"
APT_MIRROR="${APT_MIRROR:-}"
DOCKER_BUILDKIT_MODE="${DOCKER_BUILDKIT:-1}"
IMAGE_PLATFORM="${IMAGE_PLATFORM:-linux/amd64}"
APT_MIRROR_LABEL="${APT_MIRROR:-default Ubuntu repositories}"

if [[ "$INPUT_REF" == *"/"* || "$INPUT_REF" == *":"* ]]; then
    IMAGE_REF="$INPUT_REF"
else
    IMAGE_REF="${DEFAULT_IMAGE_NAME}:${INPUT_REF}"
fi

echo "========================================"
echo "Building UniVPN single-VPN minimal image"
echo "Image: ${IMAGE_REF}"
echo "Base image: ${BASE_IMAGE}"
echo "APT mirror: ${APT_MIRROR_LABEL}"
echo "DOCKER_BUILDKIT: ${DOCKER_BUILDKIT_MODE}"
echo "Platform: ${IMAGE_PLATFORM}"
echo "========================================"

if [[ ! -f "univpn-linux-64-10781.18.1.0512.run" ]]; then
    echo "Missing installer: univpn-linux-64-10781.18.1.0512.run"
    exit 1
fi

bash -n entrypoint.sh healthcheck.sh
expect -n configure.exp >/dev/null 2>&1 || true
expect -n connect.exp >/dev/null 2>&1 || true

DOCKER_BUILDKIT="${DOCKER_BUILDKIT_MODE}" docker buildx build \
    --load \
    --platform "${IMAGE_PLATFORM}" \
    --provenance=false \
    --sbom=false \
    --build-arg "BASE_IMAGE=${BASE_IMAGE}" \
    --build-arg "APT_MIRROR=${APT_MIRROR}" \
    -t "${IMAGE_REF}" \
    .

echo ""
echo "Build complete: ${IMAGE_REF}"
echo "Run example:"
echo "  docker run -d --name univpn-sidecar --privileged --cap-add NET_ADMIN --cap-add NET_RAW --cap-add SYS_MODULE --device /dev/net/tun:/dev/net/tun --env-file .env -v \$PWD/config:/usr/local/UniVPN/config -v \$PWD/logs:/usr/local/UniVPN/log ${IMAGE_REF}"
