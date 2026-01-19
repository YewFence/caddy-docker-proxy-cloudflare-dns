#!/bin/bash

set -e

docker buildx create --use
docker run --privileged --rm tonistiigi/binfmt --install all

find artifacts/binaries -type f -exec chmod +x {} \;

PLATFORMS="linux/amd64,linux/arm/v6,linux/arm/v7,linux/arm64"
OUTPUT="type=local,dest=local"
TAGS=
TAGS_ALPINE=
REGISTRY="ghcr.io"
IMAGE_NAME="ghcr.io/YewFence/caddy-docker-proxy-cloudflare-dns"
PUSH_IMAGES="${PUSH_IMAGES:-false}"

if [[ "${PUSH_IMAGES}" == "true" && "${GITHUB_REF}" == "refs/heads/master" ]]; then
    echo "Building and pushing CI images"

    docker login "${REGISTRY}" -u "${GITHUB_ACTOR}" -p "${GITHUB_TOKEN}"

    OUTPUT="type=registry"
    TAGS="-t ${IMAGE_NAME}:ci"
    TAGS_ALPINE="-t ${IMAGE_NAME}:ci-alpine"
fi

if [[ "${PUSH_IMAGES}" == "true" && "${GITHUB_REF}" =~ ^refs/tags/v[0-9]+\.[0-9]+\.[0-9]+(-.*)?$ ]]; then
    RELEASE_VERSION=$(echo $GITHUB_REF | cut -c11-)

    echo "Releasing version ${RELEASE_VERSION}..."

    docker login "${REGISTRY}" -u "${GITHUB_ACTOR}" -p "${GITHUB_TOKEN}"

    PATCH_VERSION=$(echo $RELEASE_VERSION | cut -c2-)
    MINOR_VERSION=$(echo $PATCH_VERSION | cut -d. -f-2)

    OUTPUT="type=registry"
    TAGS="-t ${IMAGE_NAME}:latest \
        -t ${IMAGE_NAME}:${PATCH_VERSION} \
        -t ${IMAGE_NAME}:${MINOR_VERSION}"
    TAGS_ALPINE="-t ${IMAGE_NAME}:alpine \
        -t ${IMAGE_NAME}:${PATCH_VERSION}-alpine \
        -t ${IMAGE_NAME}:${MINOR_VERSION}-alpine"
fi

docker buildx build -f Dockerfile . \
    -o $OUTPUT \
    --platform $PLATFORMS \
    $TAGS

docker buildx build -f Dockerfile-alpine . \
    -o $OUTPUT \
    --platform $PLATFORMS \
    $TAGS_ALPINE
