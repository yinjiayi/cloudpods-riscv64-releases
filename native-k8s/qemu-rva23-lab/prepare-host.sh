#!/usr/bin/env bash

set -euo pipefail

lab_dir=${LAB_DIR:-/var/lib/cloudpods-rva23-lab}
base_url=https://repo.openeuler.org/openEuler-24.03-LTS-SP3/virtual_machine_img/riscv64
image_xz=openEuler-24.03-LTS-SP3-RVA23-riscv64.qcow2.xz

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
    cloud-image-utils \
    curl \
    genisoimage \
    netcat-openbsd \
    openssh-client \
    opensbi \
    qemu-efi-riscv64 \
    qemu-system-misc \
    qemu-utils \
    u-boot-qemu \
    xz-utils

install -d -m 0700 "${lab_dir}"
cd "${lab_dir}"

curl --fail --location --retry 5 --continue-at - \
    --output "${image_xz}" "${base_url}/${image_xz}"
curl --fail --location --retry 5 \
    --output "${image_xz}.sha256sum" "${base_url}/${image_xz}.sha256sum"
sha256sum --check "${image_xz}.sha256sum"

for firmware in RISCV_VIRT_CODE_RVA23.fd RISCV_VIRT_VARS_RVA23.fd; do
    curl --fail --location --retry 5 --continue-at - \
        --output "${firmware}" "${base_url}/${firmware}"
done
printf '%s  %s\n' \
    32f4379f78c76f01aa6198120ca73123f5c0ba65c6dced50a009092655fa3a8d \
    RISCV_VIRT_CODE_RVA23.fd \
    ea8094e953b1215444bd001ee1cf22818f1f7f8abcb158e62180cbaa6c1f70af \
    RISCV_VIRT_VARS_RVA23.fd | sha256sum --check

if [[ ! -s ${image_xz%.xz} ]]; then
    xz --decompress --keep "${image_xz}"
fi

qemu-system-riscv64 --version
qemu-system-riscv64 -M virt -cpu help 2>&1 | grep -qx '  rva23s64'
test "$(stat -c %s RISCV_VIRT_CODE_RVA23.fd)" -eq 33554432
test "$(stat -c %s RISCV_VIRT_VARS_RVA23.fd)" -eq 33554432
echo QEMU_RVA23_HOST_OK
