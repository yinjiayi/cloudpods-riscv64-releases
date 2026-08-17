#!/usr/bin/env bash
set -Eeuo pipefail

repo_root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
source "${repo_root}/versions.env"
[[ $(uname -m) == riscv64 ]]

output_dir=${repo_root}/dist/rpm/riscv64
site_dir=${repo_root}/site/${RPM_REPOSITORY_PATH}
rm -rf -- "${repo_root}/dist/rpm" "${repo_root}/site"
install -d -m 0755 "${output_dir}"

"${repo_root}/rpm/build-qemu-rpm.sh"
"${repo_root}/rpm/build-openvswitch-rpm.sh"
"${repo_root}/rpm/build-cloudpods-executor-rpm.sh"
"${repo_root}/rpm/build-riscv-firmware-rpm.sh"

rpm_count=$(find "${output_dir}" -maxdepth 1 -type f -name '*.rpm' | wc -l)
(( rpm_count >= 8 ))
(
    cd "${output_dir}"
    sha256sum ./*.rpm | sed 's#  \./#  #' > SHA256SUMS
)
createrepo_c --checksum sha256 "${output_dir}"

install -d -m 0755 "${site_dir}"
cp -a "${output_dir}/." "${site_dir}/"
printf '%s\n' \
    '[cloudpods-riscv64]' \
    'name=Cloudpods RISC-V packages for openEuler 24.03 LTS SP3' \
    'baseurl=https://yinjiayi.github.io/cloudpods-riscv64-releases/rpm/openEuler/24.03-LTS-SP3/riscv64/' \
    'enabled=1' \
    'gpgcheck=0' \
    'repo_gpgcheck=0' \
    > "${repo_root}/site/cloudpods-riscv64.repo"

test -s "${site_dir}/repodata/repomd.xml"
xmllint --noout "${site_dir}/repodata/repomd.xml"
repo_id=cloudpods-riscv64-build-verify
repo_packages=$(
    dnf -q --refresh \
        --disablerepo='*' \
        --repofrompath="${repo_id},file://${site_dir}" \
        --enablerepo="${repo_id}" \
        repoquery --available --qf '%{name}' \
        cloudpods-executor \
        cloudpods-riscv-firmware \
        openvswitch \
        qemu-riscv-cloudpods | sort -u
)
for package_name in \
    cloudpods-executor \
    cloudpods-riscv-firmware \
    openvswitch \
    qemu-riscv-cloudpods; do
    grep -Fxq "${package_name}" <<<"${repo_packages}"
done
(
    cd "${site_dir}"
    sha256sum --check SHA256SUMS
)
