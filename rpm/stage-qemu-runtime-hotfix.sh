#!/usr/bin/env bash
set -Eeuo pipefail

repo_root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
hotfix_env=${repo_root}/rpm/qemu-runtime-hotfix.env
validated_root=$(realpath -e "${1:?usage: stage-qemu-runtime-hotfix.sh VALIDATED_ROOT}")
[[ -f ${hotfix_env} ]] || exit 0
source "${hotfix_env}"

: "${QEMU_RUNTIME_RELEASE_TAG:?}"
: "${QEMU_RUNTIME_RPM:?}"
: "${QEMU_RUNTIME_RPM_SHA256:?}"
: "${QEMU_RUNTIME_SRPM:?}"
: "${QEMU_RUNTIME_SRPM_SHA256:?}"
[[ ${QEMU_RUNTIME_RPM_SHA256} =~ ^[0-9a-f]{64}$ ]]
[[ ${QEMU_RUNTIME_SRPM_SHA256} =~ ^[0-9a-f]{64}$ ]]
[[ ${QEMU_RUNTIME_RPM} == qemu-riscv-cloudpods-*.riscv64.rpm ]]
[[ ${QEMU_RUNTIME_SRPM} == qemu-riscv-cloudpods-*.src.rpm ]]

download_dir=$(mktemp -d "${RUNNER_TEMP:-/tmp}/qemu-runtime-hotfix.XXXXXX")
trap 'rm -rf -- "${download_dir}"' EXIT
repository=${GITHUB_REPOSITORY:-yinjiayi/cloudpods-riscv64-releases}
release_base=https://github.com/${repository}/releases/download/${QEMU_RUNTIME_RELEASE_TAG}
for asset in "${QEMU_RUNTIME_RPM}" "${QEMU_RUNTIME_SRPM}"; do
    curl --fail --location --retry 10 --retry-all-errors \
        --connect-timeout 20 --max-time 1800 \
        "${release_base}/${asset}" --output "${download_dir}/${asset}"
done
echo "${QEMU_RUNTIME_RPM_SHA256}  ${download_dir}/${QEMU_RUNTIME_RPM}" |
    sha256sum --check
echo "${QEMU_RUNTIME_SRPM_SHA256}  ${download_dir}/${QEMU_RUNTIME_SRPM}" |
    sha256sum --check

repository_dirs=(
    "${validated_root}/dist/rpm/riscv64"
    "${validated_root}/site/rpm/openEuler/24.03-LTS-SP3/riscv64"
)
for repository_dir in "${repository_dirs[@]}"; do
    [[ -d ${repository_dir} ]]
    find "${repository_dir}" -maxdepth 1 -type f \
        \( -name 'qemu-riscv-cloudpods-*.riscv64.rpm' \
        -o -name 'qemu-riscv-cloudpods-*.src.rpm' \) -delete
    install -m 0644 \
        "${download_dir}/${QEMU_RUNTIME_RPM}" \
        "${download_dir}/${QEMU_RUNTIME_SRPM}" \
        "${repository_dir}/"
    rm -rf -- "${repository_dir}/repodata"
    createrepo_c --checksum sha256 "${repository_dir}"
    (
        cd "${repository_dir}"
        sha256sum ./*.rpm | sed 's#  \./#  #' > SHA256SUMS
        sha256sum --check SHA256SUMS
    )
done
