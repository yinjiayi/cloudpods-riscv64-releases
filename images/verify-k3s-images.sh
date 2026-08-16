#!/usr/bin/env bash
set -Eeuo pipefail

repo_root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
lock_file=${repo_root}/images/k3s-images.lock
output_dir=${repo_root}/dist
output_file=${output_dir}/k3s-images-riscv64.digests

command -v skopeo >/dev/null
command -v jq >/dev/null
install -d -m 0755 "${output_dir}"
: > "${output_file}"

while read -r image; do
    [[ -n ${image} ]]
    metadata=$(skopeo inspect --override-os linux --override-arch riscv64 \
        "docker://${image}")
    digest=$(jq -r .Digest <<<"${metadata}")
    platform=$(jq -r '.Architecture + "/" + .Os' <<<"${metadata}")
    [[ ${digest} == sha256:* ]]
    [[ ${platform} == riscv64/linux ]]
    printf '%s@%s\n' "${image}" "${digest}" | tee -a "${output_file}"
done < "${lock_file}"

[[ $(wc -l < "${output_file}") == $(wc -l < "${lock_file}") ]]
sha256sum "${output_file}" > "${output_file}.sha256"
