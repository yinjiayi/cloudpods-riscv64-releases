#!/usr/bin/env bash

set -euo pipefail

lab_dir=${LAB_DIR:-/var/lib/cloudpods-rva23-lab}
node_name=${NODE_NAME:-cloudpods-rva23-cp}
ssh_port=${SSH_PORT:-2202}
node_dir=${lab_dir}/${node_name}
pid_file=${node_dir}/qemu.pid

if [[ ${EUID} -ne 0 ]]; then
    echo "Run as root" >&2
    exit 1
fi
if [[ ! -s ${pid_file} ]]; then
    echo "${node_name} is not running"
    exit 0
fi
qemu_pid=$(<"${pid_file}")
if ! kill -0 "${qemu_pid}" 2>/dev/null; then
    echo "${node_name} is not running"
    exit 0
fi

monitor_socket=${node_dir}/monitor.sock
test -S "${monitor_socket}"
if [[ -s ${lab_dir}/lab_ed25519 ]]; then
    ssh -i "${lab_dir}/lab_ed25519" \
        -p "${ssh_port}" \
        -o BatchMode=yes \
        -o ConnectTimeout=10 \
        -o StrictHostKeyChecking=no \
        root@127.0.0.1 systemctl poweroff >/dev/null 2>&1 || true
else
    printf 'system_powerdown\n' | timeout 3 nc -U "${monitor_socket}" >/dev/null 2>&1 || true
fi
for _ in {1..60}; do
    if ! kill -0 "${qemu_pid}" 2>/dev/null; then
        echo "${node_name} stopped"
        exit 0
    fi
    sleep 2
done

echo "Guest did not power off; stop it from the serial console before retrying" >&2
exit 1
