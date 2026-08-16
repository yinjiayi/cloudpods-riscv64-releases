#!/usr/bin/env bash
set -Eeuo pipefail

repo_root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
source "${repo_root}/versions.env"
[[ $(uname -m) == riscv64 ]]

work_root=$(mktemp -d "${RUNNER_TEMP:-/tmp}/cloudpods-firmware-rpm.XXXXXX")
trap 'rm -rf -- "${work_root}"' EXIT
rpmbuild_root=${work_root}/rpmbuild
output_dir=${repo_root}/dist/rpm/riscv64
code_file=${rpmbuild_root}/SOURCES/RISCV_VIRT_CODE_RVA20.fd
vars_file=${rpmbuild_root}/SOURCES/RISCV_VIRT_VARS_RVA20.fd

install -d -m 0755 \
    "${rpmbuild_root}"/{BUILD,BUILDROOT,RPMS,SOURCES,SPECS,SRPMS} \
    "${output_dir}"
curl --fail --location --retry 5 --retry-all-errors \
    --output "${code_file}" \
    "${RISCV_FIRMWARE_BASE_URL}/RISCV_VIRT_CODE_RVA20.fd"
curl --fail --location --retry 5 --retry-all-errors \
    --output "${vars_file}" \
    "${RISCV_FIRMWARE_BASE_URL}/RISCV_VIRT_VARS_RVA20.fd"

echo "${RISCV_FIRMWARE_CODE_SHA256}  ${code_file}" | sha256sum --check
echo "${RISCV_FIRMWARE_VARS_SHA256}  ${vars_file}" | sha256sum --check
[[ $(stat -c %s "${code_file}") == 33554432 ]]
[[ $(stat -c %s "${vars_file}") == 33554432 ]]

install -m 0644 \
    "${repo_root}/rpm/SPECS/cloudpods-riscv-firmware.spec" \
    "${rpmbuild_root}/SPECS/"
rpmbuild --define "_topdir ${rpmbuild_root}" -ba \
    "${rpmbuild_root}/SPECS/cloudpods-riscv-firmware.spec"

install -m 0644 "${rpmbuild_root}/RPMS/noarch/"*.rpm "${output_dir}/"
install -m 0644 "${rpmbuild_root}/SRPMS/"*.src.rpm "${output_dir}/"
