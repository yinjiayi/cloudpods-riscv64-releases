#!/usr/bin/env bash

set -euo pipefail

lab_dir=${LAB_DIR:-/var/lib/cloudpods-openruyi-rva23-lab}
openruyi_version=2026.07
qemu_version=11.1.0
release_url=https://releases.openruyi.cn/creek/${openruyi_version}/rva23
image=openRuyi-${openruyi_version}-Server-cloud.qcow2

if [[ ${EUID} -ne 0 ]]; then
    echo "Run as root" >&2
    exit 1
fi
if [[ $(uname -m) != x86_64 ]]; then
    echo "The RVA23 validation host must be x86_64" >&2
    exit 1
fi

apt-get update
DEBIAN_FRONTEND=noninteractive apt-get install -y \
    build-essential \
    cloud-image-utils \
    curl \
    genisoimage \
    libaio-dev \
    libcap-ng-dev \
    libepoxy-dev \
    libfdt-dev \
    libglib2.0-dev \
    libpixman-1-dev \
    libseccomp-dev \
    libslirp-dev \
    libssh-dev \
    liburing-dev \
    libusb-1.0-0-dev \
    netcat-openbsd \
    ninja-build \
    openssh-client \
    pkg-config \
    qemu-utils \
    socat \
    xz-utils \
    zlib1g-dev

install -d -m 0700 "${lab_dir}/downloads" "${lab_dir}/src"
cd "${lab_dir}/downloads"

download() {
    local url=$1
    local output=$2
    curl --fail --location --retry 5 --continue-at - \
        --output "${output}" "${url}"
}

download "${release_url}/${image}" "${image}"
download "${release_url}/RISCV_VIRT_CODE.fd" RISCV_VIRT_CODE.fd
download "${release_url}/RISCV_VIRT_VARS.fd" RISCV_VIRT_VARS.fd
printf '%s  %s\n' \
    3be81cc72e2100c0e67573a3c99aaa103a40aeaf795875a9e44533632e660604 "${image}" \
    b7d0885ecae9dee5e9267bc285933c92ed9e689a12f61b72742d7ff333c957e0 RISCV_VIRT_CODE.fd \
    ea8094e953b1215444bd001ee1cf22818f1f7f8abcb158e62180cbaa6c1f70af RISCV_VIRT_VARS.fd \
    | sha256sum --check

qemu_prefix=/opt/qemu-${qemu_version}
qemu_source=qemu-${qemu_version}.tar.xz
if [[ ! -x ${qemu_prefix}/bin/qemu-system-riscv64 ]]; then
    download "https://download.qemu.org/${qemu_source}" "${qemu_source}"
    printf '%s  %s\n' \
        6ee1d1a61f68212476b27108c26da5f449dc09b626d42f8279ba0dc2e08fa858 \
        "${qemu_source}" | sha256sum --check
    cd "${lab_dir}/src"
    rm -rf "qemu-${qemu_version}"
    tar -xJf "${lab_dir}/downloads/${qemu_source}"
    cd "qemu-${qemu_version}"
    mkdir build
    cd build
    ../configure \
        --prefix="${qemu_prefix}" \
        --target-list=riscv64-softmmu \
        --enable-slirp \
        --enable-tools \
        --disable-werror
    ninja -j "$(nproc)"
    ninja install
fi

qemu_bin=${qemu_prefix}/bin/qemu-system-riscv64
"${qemu_bin}" --version | grep -F "version ${qemu_version}"
"${qemu_bin}" -M virt -cpu help 2>&1 | grep -qx '  rva23s64'
test "$(stat -c %s "${lab_dir}/downloads/RISCV_VIRT_CODE.fd")" -eq 33554432
test "$(stat -c %s "${lab_dir}/downloads/RISCV_VIRT_VARS.fd")" -eq 33554432
echo OPENRUYI_QEMU_RVA23_HOST_OK
