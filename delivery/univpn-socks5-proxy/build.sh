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
echo "Building UniVPN SOCKS5 proxy image"
echo "Image: ${IMAGE_REF}"
echo "Base image: ${BASE_IMAGE}"
echo "APT mirror: ${APT_MIRROR}"
echo "Note: Stage 1 clones microsocks from https://github.com/rofl0r/microsocks"
echo "      Configure network access or an outbound proxy before building if GitHub is blocked."
echo "========================================"

if [[ ! -f "univpn-linux-64-10781.18.1.0512.run" ]]; then
    echo "Missing installer: univpn-linux-64-10781.18.1.0512.run"
    exit 1
fi

DOCKER_BUILDKIT="${DOCKER_BUILDKIT_MODE}" docker build \
    --build-arg "BASE_IMAGE=${BASE_IMAGE}" \
    --build-arg "APT_MIRROR=${APT_MIRROR}" \
    -t "${IMAGE_REF}" .

echo ""
echo "========================================"
echo "Build complete: ${IMAGE_REF}"
echo ""
echo "Smoke test:"
echo "  cp examples/.env.example .env  # Fill in real credentials"
echo "  docker run -d --name univpn-proxy-test \\"
echo "    --privileged --cap-add NET_ADMIN --device /dev/net/tun \\"
echo "    --env-file .env -p 1080:1080 ${IMAGE_REF}"
echo "========================================"
