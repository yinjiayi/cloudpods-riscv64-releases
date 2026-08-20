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
rpm_identity=$(rpm -qp --qf \
    '%{NAME} %{EPOCHNUM} %{VERSION} %{RELEASE} %{ARCH}' "${rpm_path}")

rpm_sha256=$(sha256sum "${rpm_path}" | awk '{print $1}')
if rpm -q --qf '%{NAME} %{EPOCHNUM} %{VERSION} %{RELEASE} %{ARCH}\n' \
        "${rpm_name}" 2>/dev/null | grep -Fxq "${rpm_identity}"; then
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
qemu_img=/usr/local/qemu-10.0.7/bin/qemu-img
bundled_loader=/usr/local/qemu-10.0.7/lib/ld-linux-riscv64-lp64d.so.1
[[ -x ${qemu_bin} ]]
[[ -x ${qemu_img} && -x ${bundled_loader} ]]
[[ $(head -n 1 "${qemu_bin}") == '#!/bin/bash' ]]
"${qemu_bin}" --version | grep -F 'version 10.0.7'
"${qemu_img}" --version | grep -F 'qemu-img version 10.0.7'
"${qemu_bin}" -machine help | grep -Eq '^virt[[:space:]]'
"${qemu_bin}" -accel help | grep -Fxq kvm
qmp_output=$(
    printf '%s\n' \
        '{"execute":"qmp_capabilities"}' \
        '{"execute":"query-machines","id":"query_machines"}' \
        '{"execute":"quit"}' |
        "${qemu_bin}" -qmp stdio -vnc none -machine none -display none
)
grep -Fq '"QMP"' <<<"${qmp_output}"
grep -Fq '"id": "query_machines"' <<<"${qmp_output}"

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
