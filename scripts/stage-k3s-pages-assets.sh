#!/usr/bin/env bash
set -Eeuo pipefail

if (( $# != 1 )); then
    echo "Usage: $0 SITE_ROOT" >&2
    exit 2
fi

repo_root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
site_root=$1

source "${repo_root}/versions.env"
: "${K3S_VERSION:?}"
: "${K3S_PAGES_VERSION:?}"
: "${K3S_RISCV64_CHECKSUM_MANIFEST_SHA256:?}"

release_tag=${K3S_VERSION//+/%2B}
release_base="https://github.com/yinjiayi/k3s/releases/download/${release_tag}"
target_dir="${site_root}/k3s/${K3S_PAGES_VERSION}"
assets=(
    sha256sum-riscv64.txt
    install.sh
    k3s-riscv64
    k3s-airgap-images-riscv64.tar.zst
)

install -d -m 0755 "${target_dir}"
for asset in "${assets[@]}"; do
    temporary_file="${target_dir}/${asset}.part"
    curl --fail --location --retry 10 --retry-all-errors --retry-delay 5 \
        --connect-timeout 20 --max-time 1800 --speed-limit 1024 \
        --speed-time 60 "${release_base}/${asset}" \
        --output "${temporary_file}"
    mv "${temporary_file}" "${target_dir}/${asset}"
done

echo "${K3S_RISCV64_CHECKSUM_MANIFEST_SHA256}  ${target_dir}/sha256sum-riscv64.txt" |
    sha256sum --check
(
    cd "${target_dir}"
    sha256sum --check sha256sum-riscv64.txt
)
cp "${repo_root}/pages/k3s-index.html" "${target_dir}/index.html"
