#!/usr/bin/env bash
set -Eeuo pipefail

repo_root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
map_file=${repo_root}/images/cloudpods-source-map.tsv
lock_file=${repo_root}/images/cloudpods-images.lock
output_dir=${repo_root}/dist
output_file=${output_dir}/cloudpods-images-riscv64.digests

[[ $(uname -m) == riscv64 ]]
: "${GITHUB_ACTOR:?GITHUB_ACTOR is required}"
: "${GHCR_TOKEN:?GHCR_TOKEN is required}"
printf '%s' "${GHCR_TOKEN}" | buildah login \
    --username "${GITHUB_ACTOR}" --password-stdin ghcr.io
install -d -m 0755 "${output_dir}"
: > "${output_file}"

while IFS=$'\t' read -r source_image target_image; do
    [[ -n ${source_image} && -n ${target_image} ]]
    if ! buildah image exists "${source_image}"; then
        buildah pull --arch riscv64 "${source_image}"
    fi
    [[ $(buildah inspect --format '{{.OCIv1.Architecture}}' "${source_image}") == riscv64 ]]
    buildah tag "${source_image}" "${target_image}"
    buildah push "${target_image}" "docker://${target_image}"
    digest=$(skopeo inspect --override-os linux --override-arch riscv64 \
        "docker://${target_image}" | jq -r .Digest)
    [[ ${digest} == sha256:* ]]
    printf '%s@%s\n' "${target_image}" "${digest}" | tee -a "${output_file}"
done < "${map_file}"

while read -r required_image; do
    grep -Fq "${required_image}@sha256:" "${output_file}"
done < "${lock_file}"
sha256sum "${output_file}" > "${output_file}.sha256"
