#!/usr/bin/env bash
set -Eeuo pipefail

repo_root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
source "${repo_root}/versions.env"
[[ $(uname -m) == riscv64 ]]

work_root=$(mktemp -d "${RUNNER_TEMP:-/tmp}/openvswitch-rpm.XXXXXX")
trap 'rm -rf -- "${work_root}"' EXIT
rpmbuild_root=${work_root}/rpmbuild
source_rpm=${work_root}/openvswitch.src.rpm
output_dir=${repo_root}/dist/rpm/riscv64

curl --fail --location --retry 5 --retry-all-errors \
    --output "${source_rpm}" "${OPENVSWITCH_SRPM_URL}"
echo "${OPENVSWITCH_SRPM_SHA256}  ${source_rpm}" | sha256sum --check

install -d -m 0755 \
    "${rpmbuild_root}"/{BUILD,BUILDROOT,RPMS,SOURCES,SPECS,SRPMS}
rpm --define "_topdir ${rpmbuild_root}" -ivh "${source_rpm}"
spec=${rpmbuild_root}/SPECS/openvswitch.spec
sed -i \
    -e 's/^Release:[[:space:]]*5$/Release: 5.cloudpods1/' \
    -e '/^Patch0004:/a Patch0005:      openvswitch-gcc14-clang-atomic-detection.patch' \
    "${spec}"
install -m 0644 \
    "${repo_root}/rpm/SOURCES/openvswitch-gcc14-clang-atomic-detection.patch" \
    "${rpmbuild_root}/SOURCES/"
rpmbuild --define "_topdir ${rpmbuild_root}" -ba "${spec}"

install -d -m 0755 "${output_dir}"
install -m 0644 "${rpmbuild_root}/RPMS/riscv64/"*.rpm "${output_dir}/"
install -m 0644 "${rpmbuild_root}/RPMS/noarch/"*.rpm "${output_dir}/" 2>/dev/null || true
install -m 0644 "${rpmbuild_root}/SRPMS/"*.src.rpm "${output_dir}/"
