#!/usr/bin/env bash

set -euo pipefail

lab_dir=${LAB_DIR:-/var/lib/cloudpods-openruyi-rva23-lab}
node_name=${NODE_NAME:-cloudpods-openruyi-cp}
node_index=${NODE_INDEX:-1}
node_ip=${NODE_IP:-192.168.123.10}
ssh_port=${SSH_PORT:-2302}
http_port=${HTTP_PORT:-2180}
https_port=${HTTPS_PORT:-2543}
apiserver_port=${APISERVER_PORT:-27443}
vcpus=${VCPUS:-12}
memory_mib=${MEMORY_MIB:-24576}
disk_size=${DISK_SIZE:-160G}
cpu_model=${CPU_MODEL:-rva23s64}
cluster_socket_mode=${CLUSTER_SOCKET_MODE:-mcast}
cluster_socket_address=${CLUSTER_SOCKET_ADDRESS:-230.0.0.2:12346}
qemu_prefix=${QEMU_PREFIX:-/opt/qemu-11.1.0}

base_image=${BASE_IMAGE:-${lab_dir}/downloads/openRuyi-2026.07-Server-cloud.qcow2}
firmware_code=${FIRMWARE_CODE:-${lab_dir}/downloads/RISCV_VIRT_CODE.fd}
firmware_vars_template=${FIRMWARE_VARS:-${lab_dir}/downloads/RISCV_VIRT_VARS.fd}
qemu_bin=${qemu_prefix}/bin/qemu-system-riscv64
qemu_img=${qemu_prefix}/bin/qemu-img
qemu_nbd=${qemu_prefix}/bin/qemu-nbd
node_dir=${lab_dir}/${node_name}

if [[ ${EUID} -ne 0 ]]; then
    echo "Run as root" >&2
    exit 1
fi
if [[ ! ${node_index} =~ ^[0-9]+$ ]] || (( node_index < 1 || node_index > 254 )); then
    echo "NODE_INDEX must be between 1 and 254" >&2
    exit 1
fi

case ${cluster_socket_mode} in
    mcast|listen|connect)
        cluster_netdev="socket,id=cluster,${cluster_socket_mode}=${cluster_socket_address}"
        ;;
    *)
        echo "CLUSTER_SOCKET_MODE must be mcast, listen, or connect" >&2
        exit 1
        ;;
esac

for path in "${qemu_bin}" "${qemu_img}" "${qemu_nbd}"; do
    test -x "${path}"
done
"${qemu_bin}" -M virt -cpu help 2>&1 | grep -qx '  rva23s64'
test -s "${base_image}"
test "$(stat -c %s "${firmware_code}")" -eq 33554432
test "$(stat -c %s "${firmware_vars_template}")" -eq 33554432

install -d -m 0700 "${node_dir}" "${lab_dir}/keys"
pid_file=${node_dir}/qemu.pid
if [[ -s ${pid_file} ]] && kill -0 "$(<"${pid_file}")" 2>/dev/null; then
    echo "${node_name} is already running with PID $(<"${pid_file}")" >&2
    exit 1
fi

private_key=${lab_dir}/keys/lab_ed25519
if [[ ! -s ${private_key} ]]; then
    ssh-keygen -q -t ed25519 -N '' -C cloudpods-openruyi-rva23-lab \
        -f "${private_key}"
fi

disk_image=${node_dir}/root.qcow2
disk_created=false
if [[ ! -s ${disk_image} ]]; then
    "${qemu_img}" create -f qcow2 -F qcow2 -b "${base_image}" "${disk_image}" "${disk_size}"
    disk_created=true
fi

firmware_vars=${node_dir}/RISCV_VIRT_VARS.fd
if [[ ! -s ${firmware_vars} ]]; then
    cp --reflink=auto "${firmware_vars_template}" "${firmware_vars}"
fi

wan_mac=$(printf '52:54:00:26:20:%02x' "${node_index}")
cluster_mac=$(printf '52:54:00:26:10:%02x' "${node_index}")

# The official openRuyi cloud image intentionally has no cloud-init metadata
# dependency. Seed the lab key, hostname and isolated cluster NIC offline.
if ${disk_created}; then
    modprobe nbd max_part=16
    nbd_device=
    for candidate in /dev/nbd{0..15}; do
        if [[ -b ${candidate} ]] && [[ ! -e /sys/block/${candidate##*/}/pid ]]; then
            nbd_device=${candidate}
            break
        fi
    done
    if [[ -z ${nbd_device} ]]; then
        echo "No free NBD device" >&2
        exit 1
    fi

    mount_dir=$(mktemp -d)
    cleanup_nbd() {
        mountpoint -q "${mount_dir}" && umount "${mount_dir}" || true
        qemu-nbd --disconnect "${nbd_device}" >/dev/null 2>&1 || true
        rmdir "${mount_dir}" 2>/dev/null || true
    }
    trap cleanup_nbd EXIT

    "${qemu_nbd}" --connect="${nbd_device}" --format=qcow2 "${disk_image}"
    udevadm settle
    test -b "${nbd_device}p2"
    mount "${nbd_device}p2" "${mount_dir}"
    install -d -m 0700 "${mount_dir}/root/.ssh"
    install -m 0600 "${private_key}.pub" "${mount_dir}/root/.ssh/authorized_keys"
    printf '%s\n' "${node_name}" >"${mount_dir}/etc/hostname"
    install -d -m 0755 "${mount_dir}/etc/ssh/sshd_config.d"
    cat >"${mount_dir}/etc/ssh/sshd_config.d/99-cloudpods-openruyi-lab.conf" <<'EOF'
PermitRootLogin prohibit-password
PubkeyAuthentication yes
EOF
    install -d -m 0700 "${mount_dir}/etc/NetworkManager/system-connections"
    cat >"${mount_dir}/etc/NetworkManager/system-connections/cloudpods-cluster.nmconnection" <<EOF
[connection]
id=cloudpods-cluster
type=ethernet
interface-name=eth1
autoconnect=true

[ethernet]
mac-address=${cluster_mac}

[ipv4]
address1=${node_ip}/24
method=manual
never-default=true

[ipv6]
method=disabled
EOF
    chmod 0600 "${mount_dir}/etc/NetworkManager/system-connections/cloudpods-cluster.nmconnection"
    sync
    cleanup_nbd
    trap - EXIT
fi

console_log=${node_dir}/console.log
serial_socket=${node_dir}/serial.sock
monitor_socket=${node_dir}/monitor.sock
rm -f "${serial_socket}" "${monitor_socket}" "${pid_file}"

"${qemu_bin}" \
    -name "${node_name}" \
    -machine virt,pflash0=pflash0,pflash1=pflash1 \
    -accel tcg,thread=multi \
    -cpu "${cpu_model}" \
    -smp "${vcpus}" \
    -m "${memory_mib}" \
    -blockdev node-name=pflash0,driver=file,read-only=on,filename="${firmware_code}" \
    -blockdev node-name=pflash1,driver=file,filename="${firmware_vars}" \
    -drive file="${disk_image}",format=qcow2,id=hd0,if=none,cache=writeback \
    -device virtio-blk-device,drive=hd0 \
    -object rng-random,filename=/dev/urandom,id=rng0 \
    -device virtio-rng-device,rng=rng0 \
    -device virtio-net-device,netdev=wan,mac="${wan_mac}" \
    -netdev "user,id=wan,hostfwd=tcp:0.0.0.0:${ssh_port}-:22,hostfwd=tcp:0.0.0.0:${http_port}-:80,hostfwd=tcp:0.0.0.0:${https_port}-:443,hostfwd=tcp:0.0.0.0:${apiserver_port}-:6443" \
    -device virtio-net-device,netdev=cluster,mac="${cluster_mac}" \
    -netdev "${cluster_netdev}" \
    -display none \
    -chardev "socket,id=serial0,path=${serial_socket},server=on,wait=off,logfile=${console_log},logappend=on" \
    -serial chardev:serial0 \
    -monitor "unix:${monitor_socket},server=on,wait=off" \
    -pidfile "${pid_file}" \
    -daemonize

echo "NODE_NAME=${node_name}"
echo "NODE_IP=${node_ip}"
echo "CLUSTER_NETDEV=${cluster_netdev}"
echo "SSH=root@127.0.0.1:${ssh_port}"
echo "PRIVATE_KEY=${private_key}"
echo "PID=$(<"${pid_file}")"
echo "CONSOLE_LOG=${console_log}"
