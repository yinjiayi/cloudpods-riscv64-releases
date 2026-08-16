#!/usr/bin/env bash
set -Eeuo pipefail

repo_root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
source "${repo_root}/versions.env"

[[ $(uname -m) == riscv64 ]] || {
    echo "this workflow requires a native riscv64 runner" >&2
    exit 1
}
: "${GITHUB_ACTOR:?GITHUB_ACTOR is required}"
: "${GHCR_TOKEN:?GHCR_TOKEN is required}"

for command_name in buildah skopeo jq git; do
    command -v "${command_name}" >/dev/null 2>&1 || {
        echo "missing command: ${command_name}" >&2
        exit 1
    }
done

printf '%s' "${GHCR_TOKEN}" | buildah login \
    --username "${GITHUB_ACTOR}" --password-stdin ghcr.io

ensure_base_image() {
    local target_image=$1
    local source_image=${2:-$1}

    if ! buildah image exists "${target_image}"; then
        buildah pull --arch riscv64 "${source_image}"
        [[ $(buildah inspect --format '{{.OCIv1.Architecture}}' \
            "${source_image}") == riscv64 ]]
        if [[ ${source_image} != "${target_image}" ]]; then
            buildah tag "${source_image}" "${target_image}"
        fi
    fi
    [[ $(buildah inspect --format '{{.OCIv1.Architecture}}' \
        "${target_image}") == riscv64 ]]
}

build_image() {
    local name=$1
    local containerfile=$2
    shift 2

    local target_image=${GHCR_NAMESPACE}/${name}
    buildah bud \
        --arch riscv64 \
        --layers \
        --label org.opencontainers.image.source="${GITHUB_SERVER_URL}/${GITHUB_REPOSITORY}" \
        --file "${repo_root}/images/${containerfile}" \
        --tag "${target_image}" \
        "$@" \
        "${repo_root}/images"
    [[ $(buildah inspect --format '{{.OCIv1.Architecture}}' "${target_image}") == riscv64 ]]
    buildah push "${target_image}" "docker://${target_image}"
}

# Hosted GitHub infrastructure mirrors every digest-pinned build root into the
# release namespace. The native builder reuses the local GHCR-tagged cache; for
# the large Cloudpods Go toolchain it may seed that same tag from the pinned
# upstream registry digest to avoid a slow cross-border blob download.
ensure_base_image ${GHCR_NAMESPACE}/k3s-alpine:3.20-riscv64.1
ensure_base_image \
    ${GHCR_NAMESPACE}/cloudpods-alpine-build:3.22.2-go-1.24.9-0-riscv64.1 \
    registry.cn-beijing.aliyuncs.com/yunionio/alpine-build@${CLOUDPODS_ALPINE_BUILD_RISCV64_DIGEST}

build_image \
    k3s-coredns:${COREDNS_VERSION}-riscv64.1 \
    Containerfile.coredns \
    --build-arg SOURCE_REF=v${COREDNS_VERSION} \
    --build-arg SOURCE_COMMIT=${COREDNS_COMMIT}
build_image \
    k3s-traefik:${TRAEFIK_VERSION}-riscv64.1 \
    Containerfile.traefik \
    --build-arg SOURCE_REF=v${TRAEFIK_VERSION} \
    --build-arg SOURCE_COMMIT=${TRAEFIK_COMMIT}
build_image \
    k3s-metrics-server:${METRICS_SERVER_VERSION}-riscv64.1 \
    Containerfile.metrics-server \
    --build-arg SOURCE_REF=${METRICS_SERVER_VERSION} \
    --build-arg SOURCE_COMMIT=${METRICS_SERVER_COMMIT}
build_image \
    k3s-local-path-provisioner:${LOCAL_PATH_PROVISIONER_VERSION}-riscv64.1 \
    Containerfile.local-path-provisioner \
    --build-arg SOURCE_REF=${LOCAL_PATH_PROVISIONER_VERSION} \
    --build-arg SOURCE_COMMIT=${LOCAL_PATH_PROVISIONER_COMMIT}
build_image \
    k3s-pause:${PAUSE_VERSION}-riscv64.1 \
    Containerfile.pause \
    --build-arg KUBERNETES_REF=${KUBERNETES_PAUSE_COMMIT} \
    --build-arg PAUSE_VERSION=${PAUSE_VERSION}
build_image \
    k3s-klipper-lb:${KLIPPER_LB_VERSION}-riscv64.1 \
    Containerfile.klipper-lb \
    --build-arg SOURCE_COMMIT=${KLIPPER_LB_SOURCE_COMMIT} \
    --build-arg BUILDDATE="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
build_image \
    k3s-klipper-helm:${KLIPPER_HELM_VERSION}-riscv64.1 \
    Containerfile.klipper-helm \
    --build-arg SOURCE_COMMIT=${KLIPPER_HELM_SOURCE_COMMIT} \
    --build-arg HELM_VERSION=${HELM_VERSION} \
    --build-arg HELM_RISCV64_SHA256=${HELM_RISCV64_SHA256} \
    --build-arg HELM_SET_STATUS_COMMIT=${HELM_SET_STATUS_COMMIT} \
    --build-arg HELM_MAPKUBEAPIS_COMMIT=${HELM_MAPKUBEAPIS_COMMIT} \
    --build-arg BUILDDATE="$(date -u +%Y-%m-%dT%H:%M:%SZ)"

"${repo_root}/images/verify-k3s-images.sh"
