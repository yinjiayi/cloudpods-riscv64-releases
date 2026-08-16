#!/usr/bin/env bash
set -euo pipefail

image="${1:-ghcr.io/yinjiayi/k3s-alpine:3.20-riscv64.1}"
container_name="cloudpods-cni-probe"

cleanup() {
    buildah rm "${container_name}" >/dev/null 2>&1 || true
}
trap cleanup EXIT

cleanup
buildah from --name "${container_name}" "${image}" >/dev/null
buildah run "${container_name}" -- \
    sh -ec 'wget -qO /tmp/network-probe https://goproxy.cn/ && test -s /tmp/network-probe'

printf '%s\n' 'CNI_HTTPS_PROBE_OK'
