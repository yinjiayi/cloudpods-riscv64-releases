#!/usr/bin/env bash
set -Eeuo pipefail

[[ ${EUID} -eq 0 ]] || {
    echo 'run as root on the physical RISC-V virtualization host' >&2
    exit 1
}
[[ $(uname -m) == riscv64 ]]
[[ -c /dev/kvm ]] || {
    echo '/dev/kvm is required' >&2
    exit 1
}

rpm_path=$(realpath -e "${1:?usage: verify-qemu-kvm-rpm.sh QEMU_RPM}")
rpm_name=$(rpm -qp --qf '%{NAME}' "${rpm_path}")
rpm_arch=$(rpm -qp --qf '%{ARCH}' "${rpm_path}")
[[ ${rpm_name} == qemu-riscv-cloudpods && ${rpm_arch} == riscv64 ]]

rpm_sha256=$(sha256sum "${rpm_path}" | awk '{print $1}')
if rpm -q "${rpm_name}" >/dev/null 2>&1; then
    # Reinstall even when the host already carries the same NEVRA.  Release
    # candidates can have identical package metadata while differing in their
    # exact payload, so a normal dnf install could otherwise leave an older
    # local build in place and attest the wrong binary.
    dnf reinstall -y "${rpm_path}"
else
    dnf install -y "${rpm_path}"
fi
rpm -V "${rpm_name}"

qemu_bin=/usr/local/qemu-10.0.7/bin/qemu-system-riscv64
[[ -x ${qemu_bin} ]]
"${qemu_bin}" --version | grep -F 'version 10.0.7'
"${qemu_bin}" -machine help | grep -Eq '^virt[[:space:]]'
"${qemu_bin}" -accel help | grep -Fxq kvm

smoke_dir=$(mktemp -d /tmp/cloudpods-qemu-kvm.XXXXXX)
smoke_pid=
cleanup() {
    if [[ -n ${smoke_pid} ]] && kill -0 "${smoke_pid}" 2>/dev/null; then
        kill "${smoke_pid}"
        wait "${smoke_pid}" 2>/dev/null || true
    fi
    rm -rf -- "${smoke_dir}"
}
trap cleanup EXIT

"${qemu_bin}" \
    -machine virt,accel=kvm -cpu host -smp 1 -m 128M \
    -nodefaults -display none -S \
    -pidfile "${smoke_dir}/qemu.pid" -daemonize
smoke_pid=$(<"${smoke_dir}/qemu.pid")
kill -0 "${smoke_pid}"
kill "${smoke_pid}"
wait "${smoke_pid}" 2>/dev/null || true
smoke_pid=

printf 'KVM_VALIDATION_SHA256=%s\n' "${rpm_sha256}"
