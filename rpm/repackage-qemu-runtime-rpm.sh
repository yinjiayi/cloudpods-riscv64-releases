#!/usr/bin/env bash
set -Eeuo pipefail

repo_root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
source "${repo_root}/versions.env"
[[ $(uname -m) == riscv64 ]]

base_nevra=qemu-riscv-cloudpods-${QEMU_VERSION}-${QEMU_RUNTIME_BASE_RELEASE}.riscv64
[[ $(rpm -q qemu-riscv-cloudpods) == "${base_nevra}" ]]

# The wrapper can be the one-line field hotfix being replaced.  Every other
# file must still match the physically KVM-validated base RPM.
verification_output=$(rpm -V qemu-riscv-cloudpods 2>&1 || true)
unexpected_verification=$(printf '%s\n' "${verification_output}" |
    grep -v -F '/usr/local/qemu-10.0.7/bin/qemu-system-riscv64' || true)
[[ -z ${unexpected_verification} ]]

work_root=$(mktemp -d "${RUNNER_TEMP:-/tmp}/qemu-runtime-rpm.XXXXXX")
trap 'rm -rf -- "${work_root}"' EXIT
package_root=${work_root}/package-root
prefix=/usr/local/qemu-${QEMU_VERSION}
installed_prefix=${prefix}
package_prefix=${package_root}${prefix}
runtime_dir=${package_prefix}/lib
package_archive=qemu-${QEMU_VERSION}-openEuler24.03-riscv64.tar.xz
rpmbuild_root=${work_root}/rpmbuild
output_dir=${repo_root}/dist/rpm/riscv64

# Copy only paths owned by the validated base RPM.  This deliberately excludes
# local backups and any previous diagnostic files below the same prefix.
while IFS= read -r installed_path; do
    [[ ${installed_path} == ${installed_prefix}* ]] || continue
    relative_path=${installed_path#/}
    target_path=${package_root}/${relative_path}
    if [[ -d ${installed_path} ]]; then
        install -d -m "$(stat -c '%a' "${installed_path}")" "${target_path}"
    elif [[ -L ${installed_path} ]]; then
        install -d -m 0755 "$(dirname "${target_path}")"
        cp -a "${installed_path}" "${target_path}"
    elif [[ -f ${installed_path} ]]; then
        install -d -m 0755 "$(dirname "${target_path}")"
        cp -a "${installed_path}" "${target_path}"
    fi
done < <(rpm -ql qemu-riscv-cloudpods)

rm -f "${package_prefix}/bin/qemu-system-riscv64"
mv "${package_prefix}/bin/qemu-system-riscv64.real" \
    "${package_prefix}/bin/qemu-system-riscv64"
if [[ -f ${package_prefix}/bin/qemu-img.real ]]; then
    rm -f "${package_prefix}/bin/qemu-img"
    mv "${package_prefix}/bin/qemu-img.real" \
        "${package_prefix}/bin/qemu-img"
fi
real_qemu=${package_prefix}/bin/qemu-system-riscv64
qemu_img=${package_prefix}/bin/qemu-img
[[ -x ${real_qemu} && -x ${qemu_img} ]]

install -d -m 0755 "${runtime_dir}"
mapfile -t runtime_libraries < <(
    {
        ldd "${installed_prefix}/bin/qemu-system-riscv64.real"
        if [[ -x ${installed_prefix}/bin/qemu-img.real ]]; then
            ldd "${installed_prefix}/bin/qemu-img.real"
        else
            ldd "${installed_prefix}/bin/qemu-img"
        fi
    } | awk '
        /=> \/[^ ]+/ { print $3 }
        /^[[:space:]]*\/[^ ]+[[:space:]]+\(0x/ { print $1 }
    ' | sort -u
)
(( ${#runtime_libraries[@]} > 10 ))
for runtime_library in "${runtime_libraries[@]}"; do
    [[ -f ${runtime_library} ]]
    cp -L --preserve=mode,timestamps \
        "${runtime_library}" "${runtime_dir}/$(basename "${runtime_library}")"
done
for optional_runtime_library in /usr/lib64/libnss_*.so.2; do
    [[ -f ${optional_runtime_library} ]] || continue
    cp -L --preserve=mode,timestamps \
        "${optional_runtime_library}" \
        "${runtime_dir}/$(basename "${optional_runtime_library}")"
done

bundled_loader=${runtime_dir}/ld-linux-riscv64-lp64d.so.1
[[ -x ${bundled_loader} ]]
"${bundled_loader}" --library-path "${runtime_dir}" \
    "${real_qemu}" --version | grep -F "version ${QEMU_VERSION}"
"${bundled_loader}" --library-path "${runtime_dir}" \
    "${qemu_img}" --version | grep -F "qemu-img version ${QEMU_VERSION}"

tar -C "${package_root}" -cJf "${work_root}/${package_archive}" .
install -d -m 0755 \
    "${rpmbuild_root}"/{BUILD,BUILDROOT,RPMS,SOURCES,SPECS,SRPMS} \
    "${output_dir}"
install -m 0644 "${work_root}/${package_archive}" "${rpmbuild_root}/SOURCES/"
install -m 0755 \
    "${repo_root}/rpm/SOURCES/qemu-system-riscv64-cloudpods" \
    "${repo_root}/rpm/SOURCES/qemu-img-cloudpods" \
    "${rpmbuild_root}/SOURCES/"
install -m 0644 "${repo_root}/rpm/SPECS/qemu-riscv-cloudpods.spec" \
    "${rpmbuild_root}/SPECS/"
rpmbuild --define "_topdir ${rpmbuild_root}" -ba \
    "${rpmbuild_root}/SPECS/qemu-riscv-cloudpods.spec"

mapfile -t qemu_rpms < <(
    find "${rpmbuild_root}/RPMS/riscv64" -maxdepth 1 -type f \
        -name 'qemu-riscv-cloudpods-*.riscv64.rpm' | sort
)
[[ ${#qemu_rpms[@]} -eq 1 ]]
rpm -qp --qf '%{VERSION}-%{RELEASE}.%{ARCH}\n' "${qemu_rpms[0]}" |
    grep -Fx "${QEMU_VERSION}-${QEMU_RELEASE}.riscv64"
if rpm -qp --requires "${qemu_rpms[0]}" | grep -Eq '^libr(bd|ados)\.so'; then
    echo 'QEMU RPM unexpectedly depends on unavailable Ceph RBD libraries' >&2
    exit 1
fi

install -m 0644 "${qemu_rpms[0]}" "${output_dir}/"
install -m 0644 "${rpmbuild_root}/SRPMS/"*.src.rpm "${output_dir}/"
(
    cd "${output_dir}"
    sha256sum qemu-riscv-cloudpods-*.rpm > qemu-runtime-SHA256SUMS
)
printf 'BASE_QEMU_RPM_SHA256=%s\n' "${QEMU_RUNTIME_BASE_RPM_SHA256}"
printf 'OUTPUT_DIR=%s\n' "${output_dir}"
