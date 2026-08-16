#!/usr/bin/env bash
set -Eeuo pipefail

repo_root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)

if (( $# == 0 )); then
    set -- \
        "${repo_root}/images/k3s-cross-build-images.lock" \
        "${repo_root}/images/k3s-images.lock" \
        "${repo_root}/images/cloudpods-images.lock"
fi

for lock_file in "$@"; do
    while read -r image; do
        architecture=riscv64
        if [[ ${lock_file} == *cross-build* ]]; then
            architecture=amd64
        fi
        skopeo inspect --no-creds --override-os linux \
            --override-arch "${architecture}" "docker://${image}" >/dev/null
        printf 'PUBLIC %s\n' "${image}"
    done < "${lock_file}"
done
