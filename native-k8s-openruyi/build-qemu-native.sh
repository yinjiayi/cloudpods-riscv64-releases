#!/usr/bin/env bash

set -euo pipefail

qemu_version=11.1.0
qemu_source=qemu-${qemu_version}.tar.xz
qemu_source_sha256=6ee1d1a61f68212476b27108c26da5f449dc09b626d42f8279ba0dc2e08fa858
qemu_prefix=/usr/local/qemu-${qemu_version}
output_dir=${OUTPUT_DIR:-/root}

if [[ ${EUID} -ne 0 ]]; then
    echo "Run as root" >&2
    exit 1
fi
[[ $(uname -m) == riscv64 ]]
grep -q '^ID="\?openruyi"\?$' /etc/os-release
grep -q '^VERSION_ID="\?Creek"\?$' /etc/os-release

dnf install -y \
    diffutils \
    gcc \
    gcc-c++ \
    git \
    glib-devel \
    libaio-devel \
    libcap-ng-devel \
    libslirp-devel \
    liburing-devel \
    make \
    ninja-build \
    pixman-devel \
    pkgconf-pkg-config \
    python3 \
    python3-pip \
    tar \
    xz \
    zlib-devel

work_dir=$(mktemp -d)
cleanup() {
    rm -rf "${work_dir}"
}
trap cleanup EXIT

curl --fail --location --retry 5 \
    --output "${work_dir}/${qemu_source}" \
    "https://download.qemu.org/${qemu_source}"
printf '%s  %s\n' "${qemu_source_sha256}" "${work_dir}/${qemu_source}" \
    | sha256sum --check
tar -xJf "${work_dir}/${qemu_source}" -C "${work_dir}"

cd "${work_dir}/qemu-${qemu_version}"
./configure \
    --prefix="${qemu_prefix}" \
    --target-list=riscv64-softmmu \
    --enable-kvm \
    --enable-slirp \
    --disable-docs
ninja -C build -j "$(nproc)" \
    qemu-system-riscv64 qemu-img qemu-io qemu-nbd
install -d -m 0755 "${qemu_prefix}/bin"
install -m 0755 \
    build/qemu-system-riscv64 \
    build/qemu-img \
    build/qemu-io \
    build/qemu-nbd \
    "${qemu_prefix}/bin/"
install -d -m 0755 "${qemu_prefix}/share/qemu"
install -m 0644 \
    pc-bios/efi-virtio.rom \
    pc-bios/pxe-virtio.rom \
    "${qemu_prefix}/share/qemu/"
cp -a pc-bios/keymaps "${qemu_prefix}/share/qemu/"

"${qemu_prefix}/bin/qemu-system-riscv64" --version \
    | grep -F "version ${qemu_version}"
"${qemu_prefix}/bin/qemu-system-riscv64" -machine virt -cpu help 2>&1 \
    | grep -qx '  rva23s64'
test -s "${qemu_prefix}/share/qemu/efi-virtio.rom"
test -s "${qemu_prefix}/share/qemu/pxe-virtio.rom"
test -s "${qemu_prefix}/share/qemu/keymaps/en-us"

archive=qemu-${qemu_version}-openruyi-2026.07-riscv64.tar.gz
install -d -m 0755 "${output_dir}"
tar -C /usr/local -czf "${output_dir}/${archive}" "qemu-${qemu_version}"
sha256sum "${output_dir}/${archive}"
echo OPENRUYI_QEMU_NATIVE_BUILD_OK
