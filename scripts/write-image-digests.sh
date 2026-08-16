#!/usr/bin/env bash
set -Eeuo pipefail

lock_file=$(realpath -e "${1:?usage: write-image-digests.sh LOCK_FILE OUTPUT_FILE [ARCH]}")
output_file=$2
architecture=${3:-riscv64}

for command_name in jq skopeo; do
    command -v "${command_name}" >/dev/null 2>&1 || {
        echo "missing command: ${command_name}" >&2
        exit 1
    }
done

install -d -m 0755 "$(dirname "${output_file}")"
: > "${output_file}"

while read -r image; do
    [[ -n ${image} ]]
    metadata=$(skopeo inspect --no-creds --override-os linux \
        --override-arch "${architecture}" "docker://${image}")
    digest=$(jq -r .Digest <<<"${metadata}")
    platform=$(jq -r '.Architecture + "/" + .Os' <<<"${metadata}")
    [[ ${digest} == sha256:* ]]
    [[ ${platform} == "${architecture}/linux" ]]
    printf '%s@%s\n' "${image}" "${digest}" | tee -a "${output_file}"
done < "${lock_file}"

[[ $(wc -l < "${output_file}") == $(wc -l < "${lock_file}") ]]
sha256sum "${output_file}" > "${output_file}.sha256"
