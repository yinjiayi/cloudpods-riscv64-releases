#!/usr/bin/env bash
set -Eeuo pipefail

repo_root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
source "${repo_root}/versions.env"
[[ $(uname -m) == riscv64 ]]

work_root=$(mktemp -d "${RUNNER_TEMP:-/tmp}/qemu-rpm.XXXXXX")
trap 'rm -rf -- "${work_root}"' EXIT
source_archive=${work_root}/qemu-${QEMU_VERSION}.tar.xz
source_signature=${source_archive}.sig
release_key=${work_root}/qemu-release-key.asc
gpg_home=${work_root}/gnupg
source_dir=${work_root}/qemu-${QEMU_VERSION}
build_dir=${work_root}/build
package_root=${work_root}/package-root
package_archive=qemu-${QEMU_VERSION}-openEuler24.03-riscv64.tar.xz
prefix=/usr/local/qemu-${QEMU_VERSION}
rpmbuild_root=${work_root}/rpmbuild
output_dir=${repo_root}/dist/rpm/riscv64

install -d -m 0700 "${gpg_home}"
curl --fail --location --retry 5 --retry-all-errors \
    --output "${source_archive}" \
    "https://download.qemu.org/qemu-${QEMU_VERSION}.tar.xz"
curl --fail --location --retry 5 --retry-all-errors \
    --output "${source_signature}" \
    "https://download.qemu.org/qemu-${QEMU_VERSION}.tar.xz.sig"
curl --fail --location --retry 5 --retry-all-errors \
    --output "${release_key}" \
    "https://keys.openpgp.org/vks/v1/by-fingerprint/${QEMU_RELEASE_KEY_FINGERPRINT}"
echo "${QEMU_SOURCE_SHA256}  ${source_archive}" | sha256sum --check
xz -t "${source_archive}"

gpg --batch --homedir "${gpg_home}" --import "${release_key}" >/dev/null 2>&1
verify_status=$(gpg --batch --homedir "${gpg_home}" --status-fd 1 \
    --verify "${source_signature}" "${source_archive}" 2>/dev/null)
grep -Fq "[GNUPG:] VALIDSIG ${QEMU_RELEASE_KEY_FINGERPRINT} " <<<"${verify_status}"

tar -C "${work_root}" -xJf "${source_archive}"
[[ $(<"${source_dir}/VERSION") == ${QEMU_VERSION} ]]
install -d -m 0755 "${build_dir}"
(
    cd "${build_dir}"
    "${source_dir}/configure" \
        --prefix="${prefix}" \
        --target-list=riscv64-softmmu \
        --enable-kvm \
        --enable-vnc \
        --enable-slirp \
        --disable-docs \
        --disable-gtk \
        --disable-sdl \
        --disable-spice \
        --disable-opengl \
        --disable-werror
)
ninja -C "${build_dir}" -j "$(nproc)"
# QEMU's qtest and qcow2 suites use short defaults tuned for mainstream
# architectures.  They complete successfully on native RISC-V but a few need
# more than 120/180 seconds on the release VM, so retain the full suite with a
# larger timeout instead of skipping those tests.
"${build_dir}/pyvenv/bin/meson" test \
    -C "${build_dir}" \
    --no-rebuild \
    --no-stdsplit \
    --print-errorlogs \
    --timeout-multiplier 4

install -d -m 0755 "${package_root}"
DESTDIR="${package_root}" ninja -C "${build_dir}" install
real_qemu=${package_root}${prefix}/bin/qemu-system-riscv64
qemu_img=${package_root}${prefix}/bin/qemu-img
[[ -x ${real_qemu} && -x ${qemu_img} ]]
"${real_qemu}" --version | grep -F "version ${QEMU_VERSION}"
"${real_qemu}" -machine help | grep -Eq '^virt[[:space:]]'
"${real_qemu}" -accel help | grep -Fxq kvm

case ${QEMU_KVM_SMOKE:-require} in
    require)
        [[ -c /dev/kvm ]] || {
            echo 'QEMU KVM smoke test requires /dev/kvm' >&2
            exit 1
        }
        smoke_dir=$(mktemp -d "${work_root}/kvm-smoke.XXXXXX")
        "${real_qemu}" \
            -machine virt,accel=kvm -cpu host -smp 1 -m 128M \
            -nodefaults -display none -S \
            -pidfile "${smoke_dir}/qemu.pid" -daemonize
        smoke_pid=$(<"${smoke_dir}/qemu.pid")
        kill -0 "${smoke_pid}"
        kill "${smoke_pid}"
        wait "${smoke_pid}" 2>/dev/null || true
        ;;
    skip)
        echo 'QEMU_KVM_SMOKE=skip: deferring runtime KVM validation to a physical RISC-V host'
        ;;
    *)
        echo 'QEMU_KVM_SMOKE must be require or skip' >&2
        exit 2
        ;;
esac

tar -C "${package_root}" -cJf "${work_root}/${package_archive}" .
sha256sum "${work_root}/${package_archive}"

install -d -m 0755 \
    "${rpmbuild_root}"/{BUILD,BUILDROOT,RPMS,SOURCES,SPECS,SRPMS} \
    "${output_dir}"
install -m 0644 "${work_root}/${package_archive}" "${rpmbuild_root}/SOURCES/"
install -m 0755 "${repo_root}/rpm/SOURCES/qemu-system-riscv64-cloudpods" "${rpmbuild_root}/SOURCES/"
install -m 0644 "${repo_root}/rpm/SPECS/qemu-riscv-cloudpods.spec" "${rpmbuild_root}/SPECS/"
rpmbuild --define "_topdir ${rpmbuild_root}" -ba \
    "${rpmbuild_root}/SPECS/qemu-riscv-cloudpods.spec"

install -m 0644 "${rpmbuild_root}/RPMS/riscv64/"*.rpm "${output_dir}/"
install -m 0644 "${rpmbuild_root}/SRPMS/"*.src.rpm "${output_dir}/"
