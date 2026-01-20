#!/bin/bash

set -e

REGISTRY="ghcr.io"
IMAGE_NAME="ghcr.io/yewfence/caddy-docker-proxy-cloudflare-dns"
PUSH_IMAGES="${PUSH_IMAGES:-false}"
DO_PUSH="false"
RELEASE_VERSION=""

if [[ "${PUSH_IMAGES}" == "true" ]]; then
    echo "Logging in to ${REGISTRY}..."
    docker login "${REGISTRY}" -u "${GITHUB_ACTOR}" -p "${GITHUB_TOKEN}"

    if [[ "${GITHUB_REF}" == "refs/heads/fork-main" ]]; then
        echo "Building and pushing CI images"
        DO_PUSH="true"
    elif [[ "${GITHUB_REF}" =~ ^refs/tags/v[0-9]+\.[0-9]+\.[0-9]+(-.*)?$ ]]; then
        RELEASE_VERSION=$(echo $GITHUB_REF | cut -c11-)
        echo "Releasing version ${RELEASE_VERSION}..."
        DO_PUSH="true"
    else
        echo "::warning::PUSH_IMAGES=true, but GITHUB_REF '${GITHUB_REF}' does not match fork-main or a version tag. Falling back to local build."
    fi
fi

TAG_1809="-t ${IMAGE_NAME}:ci-nanoserver-1809"
TAG_LTS="-t ${IMAGE_NAME}:ci-nanoserver-ltsc2022"

docker build -f Dockerfile-nanoserver . \
    --build-arg TARGETPLATFORM=windows/amd64 \
    --build-arg SERVERCORE_VERSION=1809 \
    --build-arg NANOSERVER_VERSION=1809 \
    ${TAG_1809}

docker build -f Dockerfile-nanoserver . \
    --build-arg TARGETPLATFORM=windows/amd64 \
    --build-arg SERVERCORE_VERSION=ltsc2022 \
    --build-arg NANOSERVER_VERSION=ltsc2022 \
    ${TAG_LTS}

if [[ "${DO_PUSH}" == "true" ]]; then
    if [[ "${GITHUB_REF}" == "refs/heads/fork-main" ]]; then
        docker push ${IMAGE_NAME}:ci-nanoserver-1809
        docker push ${IMAGE_NAME}:ci-nanoserver-ltsc2022
    elif [[ -n "${RELEASE_VERSION}" ]]; then
        PATCH_VERSION=$(echo $RELEASE_VERSION | cut -c2-)
        MINOR_VERSION=$(echo $PATCH_VERSION | cut -d. -f-2)

        # nanoserver-1809
        docker tag ${IMAGE_NAME}:ci-nanoserver-1809 ${IMAGE_NAME}:nanoserver-1809
        docker tag ${IMAGE_NAME}:ci-nanoserver-1809 ${IMAGE_NAME}:${PATCH_VERSION}-nanoserver-1809
        docker tag ${IMAGE_NAME}:ci-nanoserver-1809 ${IMAGE_NAME}:${MINOR_VERSION}-nanoserver-1809
        docker push ${IMAGE_NAME}:nanoserver-1809
        docker push ${IMAGE_NAME}:${PATCH_VERSION}-nanoserver-1809
        docker push ${IMAGE_NAME}:${MINOR_VERSION}-nanoserver-1809

        # nanoserver-ltsc2022
        docker tag ${IMAGE_NAME}:ci-nanoserver-ltsc2022 ${IMAGE_NAME}:nanoserver-ltsc2022
        docker tag ${IMAGE_NAME}:ci-nanoserver-ltsc2022 ${IMAGE_NAME}:${PATCH_VERSION}-nanoserver-ltsc2022
        docker tag ${IMAGE_NAME}:ci-nanoserver-ltsc2022 ${IMAGE_NAME}:${MINOR_VERSION}-nanoserver-ltsc2022
        docker push ${IMAGE_NAME}:nanoserver-ltsc2022
        docker push ${IMAGE_NAME}:${PATCH_VERSION}-nanoserver-ltsc2022
        docker push ${IMAGE_NAME}:${MINOR_VERSION}-nanoserver-ltsc2022
    fi
fi
