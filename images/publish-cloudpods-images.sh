#!/usr/bin/env bash
set -Eeuo pipefail

repo_root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
source "${repo_root}/images/lib-riscv64-image-mirror.sh"
map_file=${repo_root}/images/cloudpods-source-map.tsv
lock_file=${repo_root}/images/cloudpods-images.lock
output_dir=${repo_root}/dist
output_file=${output_dir}/cloudpods-images-riscv64.digests

host_arch=$(uname -m)
case "${host_arch}" in
    riscv64)
        ;;
    x86_64)
        [[ ${QEMU_USER_RISCV64:-0} == 1 ]]
        binfmt_file=/proc/sys/fs/binfmt_misc/qemu-riscv64
        [[ -r ${binfmt_file} ]]
        grep -qx enabled "${binfmt_file}"
        ;;
    *)
        echo "unsupported publish host architecture: ${host_arch}" >&2
        exit 1
        ;;
esac
: "${GITHUB_ACTOR:?GITHUB_ACTOR is required}"
: "${GHCR_TOKEN:?GHCR_TOKEN is required}"
printf '%s' "${GHCR_TOKEN}" | buildah login \
    --username "${GITHUB_ACTOR}" --password-stdin ghcr.io
install -d -m 0755 "${output_dir}"
: > "${output_file}"

while IFS=$'\t' read -r source_image target_image; do
    [[ -n ${source_image} && -n ${target_image} ]]
    if [[ ${source_image} != localhost/* ]] && \
        riscv64_mirror_is_current "${source_image}" "${target_image}"; then
        echo "Reusing verified dependency mirror: ${target_image}"
    else
        if ! buildah inspect "${source_image}" >/dev/null 2>&1; then
            buildah pull --arch riscv64 "${source_image}"
        fi
        [[ $(buildah inspect --format '{{.OCIv1.Architecture}}' \
            "${source_image}") == riscv64 ]]
        buildah tag "${source_image}" "${target_image}"
        buildah push "${target_image}" "docker://${target_image}"
    fi
    digest=$(skopeo inspect --override-os linux --override-arch riscv64 \
        "docker://${target_image}" | jq -r .Digest)
    [[ ${digest} == sha256:* ]]
    printf '%s@%s\n' "${target_image}" "${digest}" | tee -a "${output_file}"
done < "${map_file}"

while read -r required_image; do
    grep -Fq "${required_image}@sha256:" "${output_file}"
done < "${lock_file}"
sha256sum "${output_file}" > "${output_file}.sha256"
