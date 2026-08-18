#!/usr/bin/env bash
set -Eeuo pipefail

repo_root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
source "${repo_root}/versions.env"

host_arch=$(uname -m)
case ${host_arch} in
    riscv64)
        ;;
    x86_64)
        [[ ${QEMU_USER_RISCV64:-0} == 1 ]]
        binfmt_file=/proc/sys/fs/binfmt_misc/qemu-riscv64
        [[ -r ${binfmt_file} ]]
        grep -qx enabled "${binfmt_file}"
        ;;
    *)
        echo "unsupported build host architecture: ${host_arch}" >&2
        exit 1
        ;;
esac

base_image=localhost/cloudpods/cloudpods:${CLOUDPODS_IMAGE_BASE_VERSION}
target_image=localhost/cloudpods/cloudpods:${CLOUDPODS_IMAGE_VERSION}
kubeserver_base_image=localhost/cloudpods/kubeserver:${KUBESERVER_IMAGE_BASE_VERSION}
kubeserver_target_image=localhost/cloudpods/kubeserver:${KUBESERVER_IMAGE_VERSION}

ensure_kubeserver_version_image() {
    local builder
    local public_base
    if buildah inspect "${kubeserver_target_image}" >/dev/null 2>&1; then
        [[ $(buildah inspect --format '{{.OCIv1.Architecture}}' \
            "${kubeserver_target_image}") == riscv64 ]]
        return
    fi
    if ! buildah inspect "${kubeserver_base_image}" >/dev/null 2>&1; then
        public_base=${GHCR_NAMESPACE}/kubeserver:${KUBESERVER_IMAGE_BASE_VERSION}
        buildah pull --arch riscv64 "docker://${public_base}"
        buildah tag "${public_base}" "${kubeserver_base_image}"
    fi
    builder=kubeserver-version-image-$$
    buildah from --name "${builder}" "${kubeserver_base_image}" >/dev/null
    buildah config \
        --label "org.opencontainers.image.source=https://github.com/yinjiayi/kubecomps" \
        --label "org.opencontainers.image.revision=${KUBECOMPS_SOURCE_COMMIT}" \
        --label "org.opencontainers.image.version=${KUBESERVER_IMAGE_VERSION}" \
        "${builder}"
    buildah commit --rm --format oci "${builder}" "${kubeserver_target_image}" >/dev/null
    [[ $(buildah inspect --format '{{.OCIv1.Architecture}}' \
        "${kubeserver_target_image}") == riscv64 ]]
}

verify_resource_layer() {
    local image=$1
    local verifier
    local verify_rc=0
    verifier=cloudpods-resource-verifier-$$
    buildah from --name "${verifier}" "${image}" >/dev/null || return 1
    buildah run "${verifier}" -- sh -ec '
        test "$(uname -m)" = riscv64
        metadata_dir=/opt/yunion/share/saml/sp-metadata
        test "$(find "${metadata_dir}" -maxdepth 1 -type f -name "*.xml" | wc -l)" -eq 9
        test -f "${metadata_dir}/gcp.xml"
        test -x /opt/yunion/bin/cloudid
    ' || verify_rc=$?
    buildah rm "${verifier}" >/dev/null
    return "${verify_rc}"
}

ensure_kubeserver_version_image

if buildah inspect "${target_image}" >/dev/null 2>&1 && \
    verify_resource_layer "${target_image}"; then
    buildah tag "${target_image}" localhost/cloudpods/etcd:3.5.24
    echo "Reusing verified cached resource-complete image: ${target_image}"
    exit 0
fi

if ! buildah inspect "${base_image}" >/dev/null 2>&1; then
    public_base=${GHCR_NAMESPACE}/cloudpods:${CLOUDPODS_IMAGE_BASE_VERSION}
    buildah pull --arch riscv64 "docker://${public_base}"
    buildah tag "${public_base}" "${base_image}"
fi
[[ $(buildah inspect --format '{{.OCIv1.Architecture}}' "${base_image}") == riscv64 ]]

work_root=$(mktemp -d "${RUNNER_TEMP:-/tmp}/cloudpods-resource-hotfix.XXXXXX")
trap 'rm -rf -- "${work_root}"' EXIT
source_root=${work_root}/cloudpods-source
source_archive=${work_root}/cloudpods-source.tar.gz
context_dir=${work_root}/context

if [[ -n ${CLOUDPODS_HOTFIX_SOURCE_DIR:-} ]]; then
    source_root=$(realpath -e "${CLOUDPODS_HOTFIX_SOURCE_DIR}")
    [[ $(git -C "${source_root}" rev-parse HEAD) == "${CLOUDPODS_SOURCE_COMMIT}" ]]
else
    install -d -m 0755 "${source_root}"
    curl --fail --location --retry 10 --retry-all-errors \
        --connect-timeout 20 --max-time 600 \
        --output "${source_archive}" \
        "https://codeload.github.com/yinjiayi/cloudpods/tar.gz/${CLOUDPODS_SOURCE_COMMIT}"
    tar -C "${source_root}" --strip-components=1 -xzf "${source_archive}"
fi

metadata_source=${source_root}/build/cloudid/root/opt/yunion/share/saml/sp-metadata
[[ $(find "${metadata_source}" -maxdepth 1 -type f -name '*.xml' | wc -l) -eq 9 ]]
install -d -m 0755 "${context_dir}/rootfs/opt"
cp -a "${source_root}/build/cloudid/root/opt/." "${context_dir}/rootfs/opt/"

buildah bud --arch riscv64 --layers --pull-never \
    --build-arg "BASE_IMAGE=${base_image}" \
    --build-arg "SOURCE_COMMIT=${CLOUDPODS_SOURCE_COMMIT}" \
    --build-arg "VERSION=${CLOUDPODS_IMAGE_VERSION}" \
    --tag "${target_image}" \
    --file "${repo_root}/images/Containerfile.cloudpods-resource-hotfix" \
    "${context_dir}"
[[ $(buildah inspect --format '{{.OCIv1.Architecture}}' "${target_image}") == riscv64 ]]
verify_resource_layer "${target_image}"
buildah tag "${target_image}" localhost/cloudpods/etcd:3.5.24
