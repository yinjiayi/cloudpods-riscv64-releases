#!/usr/bin/env bash
set -Eeuo pipefail

[[ ${EUID} -eq 0 ]] || {
    echo 'run as root on a dedicated openEuler RISC-V build machine' >&2
    exit 1
}
[[ $(uname -m) == riscv64 ]]

repo_root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
source "${repo_root}/versions.env"

bootstrap_root=${ACTION_RUNNER_BOOTSTRAP_ROOT:-/opt/actions-runner-bootstrap}
cache_dir=${bootstrap_root}/cache
qemu_source_dir=${bootstrap_root}/src/qemu-${QEMU_VERSION}
qemu_build_dir=${bootstrap_root}/build-qemu-x86_64
qemu_prefix=/opt/qemu-user-${QEMU_VERSION}
sysroot_suffix=${UBUNTU_RUNNER_OCI_SHA256:0:16}
source_sysroot=/opt/x86_64-sysroot-ubuntu-${UBUNTU_RUNNER_RELEASE}-${sysroot_suffix}
runner_sysroot=/opt/x86_64-sysroot-github-runner-${UBUNTU_RUNNER_RELEASE}-${sysroot_suffix}
runner_sysroot_link=/opt/x86_64-runner-sysroot
runner_root=/opt/actions-runner
ubuntu_oci_base=https://partner-images.canonical.com/oci/jammy/${UBUNTU_RUNNER_OCI_SERIAL}

download_checked() {
    local url=$1
    local output=$2
    local expected=$3
    local temporary

    if [[ -f ${output} ]]; then
        echo "${expected}  ${output}" | sha256sum --check
        return
    fi
    temporary=$(mktemp "${output}.part.XXXXXX")
    curl --fail --location --retry 5 --retry-all-errors \
        --output "${temporary}" "${url}"
    echo "${expected}  ${temporary}" | sha256sum --check
    install -m 0644 "${temporary}" "${output}"
    rm -f -- "${temporary}"
}

dnf install -y \
    binutils curl file gcc gcc-c++ glib2-devel gnupg2 libffi-devel make \
    ninja-build pkgconf-pkg-config python3 tar xz zlib-devel zstd
install -d -m 0755 "${cache_dir}" "${bootstrap_root}/src"

qemu_archive=${cache_dir}/qemu-${QEMU_VERSION}.tar.xz
qemu_signature=${qemu_archive}.sig
qemu_key=${cache_dir}/qemu-release-key.asc
download_checked \
    "https://download.qemu.org/qemu-${QEMU_VERSION}.tar.xz" \
    "${qemu_archive}" "${QEMU_SOURCE_SHA256}"
curl --fail --location --retry 5 --retry-all-errors \
    --output "${qemu_signature}" \
    "https://download.qemu.org/qemu-${QEMU_VERSION}.tar.xz.sig"
curl --fail --location --retry 5 --retry-all-errors \
    --output "${qemu_key}" \
    "https://keys.openpgp.org/vks/v1/by-fingerprint/${QEMU_RELEASE_KEY_FINGERPRINT}"

qemu_gpg_home=${bootstrap_root}/gnupg-qemu
install -d -m 0700 "${qemu_gpg_home}"
gpg --batch --homedir "${qemu_gpg_home}" --import "${qemu_key}" >/dev/null 2>&1
qemu_verify_status=$(gpg --batch --homedir "${qemu_gpg_home}" --status-fd 1 \
    --verify "${qemu_signature}" "${qemu_archive}" 2>/dev/null)
grep -Fq "[GNUPG:] VALIDSIG ${QEMU_RELEASE_KEY_FINGERPRINT} " <<<"${qemu_verify_status}"

if [[ ! -x ${qemu_prefix}/bin/qemu-x86_64 ]]; then
    if [[ ! -d ${qemu_source_dir} ]]; then
        tar -C "${bootstrap_root}/src" -xJf "${qemu_archive}"
    fi
    [[ $(<"${qemu_source_dir}/VERSION") == ${QEMU_VERSION} ]]
    install -d -m 0755 "${qemu_build_dir}"
    (
        cd "${qemu_build_dir}"
        "${qemu_source_dir}/configure" \
            --prefix="${qemu_prefix}" \
            --target-list=x86_64-linux-user \
            --disable-system \
            --enable-linux-user \
            --disable-tools \
            --disable-guest-agent \
            --disable-docs \
            --disable-werror
    )
    ninja -C "${qemu_build_dir}" -j "$(nproc)"
    ninja -C "${qemu_build_dir}" install
fi
"${qemu_prefix}/bin/qemu-x86_64" --version | grep -F "version ${QEMU_VERSION}"

ubuntu_checksums=${cache_dir}/ubuntu-jammy-${UBUNTU_RUNNER_OCI_SERIAL}-SHA256SUMS
ubuntu_signature=${ubuntu_checksums}.gpg
ubuntu_key=${cache_dir}/ubuntu-cloud-image-key.asc
curl --fail --location --retry 5 --retry-all-errors \
    --output "${ubuntu_checksums}" "${ubuntu_oci_base}/SHA256SUMS"
curl --fail --location --retry 5 --retry-all-errors \
    --output "${ubuntu_signature}" "${ubuntu_oci_base}/SHA256SUMS.gpg"
curl --fail --location --retry 5 --retry-all-errors \
    --output "${ubuntu_key}" \
    "https://keyserver.ubuntu.com/pks/lookup?op=get&search=0x${UBUNTU_CLOUD_IMAGE_KEY_FINGERPRINT}"

ubuntu_gpg_home=${bootstrap_root}/gnupg-ubuntu
install -d -m 0700 "${ubuntu_gpg_home}"
gpg --batch --homedir "${ubuntu_gpg_home}" --import "${ubuntu_key}" >/dev/null 2>&1
gpg --batch --homedir "${ubuntu_gpg_home}" --with-colons --fingerprint \
    "${UBUNTU_CLOUD_IMAGE_KEY_FINGERPRINT}" \
    | grep -Fq "fpr:::::::::${UBUNTU_CLOUD_IMAGE_KEY_FINGERPRINT}:"
ubuntu_verify_status=$(gpg --batch --homedir "${ubuntu_gpg_home}" --status-fd 1 \
    --verify "${ubuntu_signature}" "${ubuntu_checksums}" 2>/dev/null)
grep -Fq "[GNUPG:] VALIDSIG ${UBUNTU_CLOUD_IMAGE_KEY_FINGERPRINT} " \
    <<<"${ubuntu_verify_status}"
grep -Fq "${UBUNTU_RUNNER_OCI_SHA256} *ubuntu-jammy-oci-amd64-root.tar.gz" \
    "${ubuntu_checksums}"

ubuntu_rootfs=${cache_dir}/ubuntu-jammy-oci-amd64-root.tar.gz
download_checked \
    "${ubuntu_oci_base}/ubuntu-jammy-oci-amd64-root.tar.gz" \
    "${ubuntu_rootfs}" "${UBUNTU_RUNNER_OCI_SHA256}"
if [[ ! -d ${source_sysroot}/etc ]]; then
    test ! -e "${source_sysroot}"
    install -d -m 0755 "${source_sysroot}"
    tar -C "${source_sysroot}" -xzf "${ubuntu_rootfs}"
fi
if [[ ! -d ${runner_sysroot}/etc ]]; then
    test ! -e "${runner_sysroot}"
    install -d -m 0755 "${runner_sysroot}"
    cp -a "${source_sysroot}/." "${runner_sysroot}/"
    loader_link=${runner_sysroot}/usr/lib64/ld-linux-x86-64.so.2
    [[ $(readlink "${loader_link}") == /lib/x86_64-linux-gnu/ld-linux-x86-64.so.2 ]]
    unlink "${loader_link}"
    ln -s ../lib/x86_64-linux-gnu/ld-linux-x86-64.so.2 "${loader_link}"
fi
[[ $(readlink "${runner_sysroot}/usr/lib64/ld-linux-x86-64.so.2") == \
    ../lib/x86_64-linux-gnu/ld-linux-x86-64.so.2 ]]
if [[ -L ${runner_sysroot_link} ]]; then
    [[ $(readlink -f "${runner_sysroot_link}") == ${runner_sysroot} ]]
else
    test ! -e "${runner_sysroot_link}"
    ln -s "${runner_sysroot}" "${runner_sysroot_link}"
fi

libicu_deb=${cache_dir}/libicu70_${UBUNTU_RUNNER_LIBICU_VERSION}_amd64.deb
download_checked \
    "https://archive.ubuntu.com/ubuntu/pool/main/i/icu/libicu70_${UBUNTU_RUNNER_LIBICU_VERSION}_amd64.deb" \
    "${libicu_deb}" "${UBUNTU_RUNNER_LIBICU_SHA256}"
if [[ ! -r ${runner_sysroot}/usr/lib/x86_64-linux-gnu/libicuuc.so.70.1 ]]; then
    ar p "${libicu_deb}" data.tar.zst \
        | tar --zstd -x -C "${runner_sysroot}"
fi
[[ -r ${runner_sysroot}/usr/lib/x86_64-linux-gnu/libicuuc.so.70.1 ]]

runner_archive=${cache_dir}/actions-runner-linux-x64-${ACTION_RUNNER_VERSION}.tar.gz
download_checked \
    "https://github.com/actions/runner/releases/download/v${ACTION_RUNNER_VERSION}/actions-runner-linux-x64-${ACTION_RUNNER_VERSION}.tar.gz" \
    "${runner_archive}" "${ACTION_RUNNER_X64_SHA256}"
if [[ ! -x ${runner_root}/bin/Runner.Listener ]]; then
    test ! -e "${runner_root}"
    install -d -m 0755 "${runner_root}"
    tar -C "${runner_root}" -xzf "${runner_archive}"
fi

binfmt_conf=/etc/binfmt.d/qemu-x86_64-cloudpods.conf
binfmt_tmp=$(mktemp /etc/binfmt.d/.qemu-x86_64-cloudpods.XXXXXX)
printf '%s\n' \
    ":qemu-x86_64-cloudpods:M::\\x7fELF\\x02\\x01\\x01\\x00\\x00\\x00\\x00\\x00\\x00\\x00\\x00\\x00\\x02\\x00\\x3e\\x00:\\xff\\xff\\xff\\xff\\xff\\xff\\xff\\x00\\xff\\xff\\xff\\xff\\xff\\xff\\xff\\xff\\xfe\\xff\\xff\\xff:${qemu_prefix}/bin/qemu-x86_64:F" \
    > "${binfmt_tmp}"
chmod 0644 "${binfmt_tmp}"
mv "${binfmt_tmp}" "${binfmt_conf}"
systemctl restart systemd-binfmt.service
grep -Fq "interpreter ${qemu_prefix}/bin/qemu-x86_64" \
    /proc/sys/fs/binfmt_misc/qemu-x86_64-cloudpods

runner_env=(
    QEMU_LD_PREFIX=${runner_sysroot_link}
    QEMU_CPU=qemu64
    DOTNET_gcServer=0
    DOTNET_gcConcurrent=0
    DOTNET_GCHeapHardLimit=0x40000000
)
[[ $(env "${runner_env[@]}" "${runner_sysroot_link}/bin/uname" -m) == x86_64 ]]
[[ $(env "${runner_env[@]}" "${runner_root}/bin/Runner.Listener" --version) == ${ACTION_RUNNER_VERSION} ]]
env "${runner_env[@]}" "${runner_root}/externals/node20/bin/node" --version

echo 'RISC-V Actions Runner runtime is ready; registration token has not been used.'
