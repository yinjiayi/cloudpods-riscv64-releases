#!/usr/bin/env bash

set -euo pipefail

lab_dir=${LAB_DIR:-/var/lib/cloudpods-rva23-lab}
node_name=${NODE_NAME:-cloudpods-rva23-cp}
node_index=${NODE_INDEX:-1}
node_ip=${NODE_IP:-192.168.123.10}
ssh_port=${SSH_PORT:-2202}
http_port=${HTTP_PORT:-2080}
https_port=${HTTPS_PORT:-2443}
apiserver_port=${APISERVER_PORT:-26443}
vcpus=${VCPUS:-12}
memory_mib=${MEMORY_MIB:-24576}
disk_size=${DISK_SIZE:-160G}
cpu_model=${CPU_MODEL:-rva23s64,sv39=on}
cluster_socket_mode=${CLUSTER_SOCKET_MODE:-mcast}
cluster_socket_address=${CLUSTER_SOCKET_ADDRESS:-230.0.0.1:12345}

base_image=${BASE_IMAGE:-${lab_dir}/openEuler-24.03-LTS-SP3-RVA23-riscv64.qcow2}
firmware_code=${FIRMWARE_CODE:-${lab_dir}/RISCV_VIRT_CODE_RVA23.fd}
firmware_vars_template=${FIRMWARE_VARS:-${lab_dir}/RISCV_VIRT_VARS_RVA23.fd}
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

for command_name in cloud-localds qemu-img qemu-nbd qemu-system-riscv64 ssh-keygen; do
    command -v "${command_name}" >/dev/null
done

qemu-system-riscv64 -M virt -cpu help 2>&1 | grep -qx '  rva23s64'
test -s "${base_image}"
test "$(stat -c %s "${firmware_code}")" -eq 33554432
test "$(stat -c %s "${firmware_vars_template}")" -eq 33554432

install -d -m 0700 "${node_dir}"

pid_file=${node_dir}/qemu.pid
if [[ -s ${pid_file} ]] && kill -0 "$(<"${pid_file}")" 2>/dev/null; then
    echo "${node_name} is already running with PID $(<"${pid_file}")" >&2
    exit 1
fi

private_key=${lab_dir}/lab_ed25519
if [[ ! -s ${private_key} ]]; then
    ssh-keygen -q -t ed25519 -N '' -C cloudpods-rva23-lab -f "${private_key}"
fi
public_key=$(<"${private_key}.pub")

disk_image=${node_dir}/root.qcow2
disk_created=false
if [[ ! -s ${disk_image} ]]; then
    qemu-img create -f qcow2 -F qcow2 -b "${base_image}" "${disk_image}"
    qemu-img resize "${disk_image}" "${disk_size}"
    disk_created=true
fi

firmware_vars=${node_dir}/RISCV_VIRT_VARS_RVA23.fd
if [[ ! -s ${firmware_vars} ]]; then
    cp --reflink=auto "${firmware_vars_template}" "${firmware_vars}"
fi

wan_mac=$(printf '52:54:00:23:20:%02x' "${node_index}")
cluster_mac=$(printf '52:54:00:23:10:%02x' "${node_index}")

user_data=${node_dir}/user-data
meta_data=${node_dir}/meta-data
network_config=${node_dir}/network-config
seed_image=${node_dir}/seed.iso

cat >"${user_data}" <<EOF
#cloud-config
hostname: ${node_name}
manage_etc_hosts: true
disable_root: false
ssh_pwauth: false
users:
  - default
  - name: root
    lock_passwd: true
    ssh_authorized_keys:
      - ${public_key}
growpart:
  mode: auto
  devices:
    - /
  ignore_growroot_disabled: false
resize_rootfs: true
runcmd:
  - [systemctl, enable, --now, sshd]
  - [touch, /var/lib/cloud/cloudpods-rva23-ready]
EOF

cat >"${meta_data}" <<EOF
instance-id: ${node_name}-1
local-hostname: ${node_name}
EOF

cat >"${network_config}" <<EOF
version: 2
ethernets:
  wan:
    match:
      macaddress: "${wan_mac}"
    set-name: eth0
    dhcp4: true
    dhcp6: false
  cluster:
    match:
      macaddress: "${cluster_mac}"
    set-name: eth1
    dhcp4: false
    dhcp6: false
    addresses:
      - ${node_ip}/24
EOF

cloud-localds --network-config="${network_config}" \
    "${seed_image}" "${user_data}" "${meta_data}"

# The official openEuler RVA23 image currently has no cloud-init package.  The
# NoCloud seed is kept for images that add cloud-init later; for the published
# SP3 image, install the lab key and hostname offline on first creation.
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

    qemu-nbd --connect="${nbd_device}" --format=qcow2 "${disk_image}"
    udevadm settle
    root_partition=${nbd_device}p2
    test -b "${root_partition}"
    mount "${root_partition}" "${mount_dir}"
    install -d -m 0700 "${mount_dir}/root/.ssh"
    printf '%s\n' "${public_key}" >"${mount_dir}/root/.ssh/authorized_keys"
    chmod 0600 "${mount_dir}/root/.ssh/authorized_keys"
    printf '%s\n' "${node_name}" >"${mount_dir}/etc/hostname"
    install -d -m 0755 "${mount_dir}/etc/ssh/sshd_config.d"
    cat >"${mount_dir}/etc/ssh/sshd_config.d/99-cloudpods-rva23-lab.conf" <<'EOF'
PermitRootLogin prohibit-password
PubkeyAuthentication yes
EOF
    install -d -m 0755 "${mount_dir}/etc/sysconfig/network-scripts"
    cat >"${mount_dir}/etc/sysconfig/network-scripts/ifcfg-cloudpods-cluster" <<EOF
TYPE=Ethernet
BOOTPROTO=none
IPADDR=${node_ip}
PREFIX=24
DEFROUTE=no
IPV4_FAILURE_FATAL=no
IPV6_DISABLED=yes
IPV6INIT=no
NAME=cloudpods-cluster
DEVICE=eth1
ONBOOT=yes
EOF
    chmod 0600 "${mount_dir}/etc/sysconfig/network-scripts/ifcfg-cloudpods-cluster"
    sync
    cleanup_nbd
    trap - EXIT
fi

console_log=${node_dir}/console.log
serial_socket=${node_dir}/serial.sock
monitor_socket=${node_dir}/monitor.sock
rm -f "${serial_socket}" "${monitor_socket}"

qemu-system-riscv64 \
    -name "${node_name}" \
    -machine virt,pflash0=pflash0,pflash1=pflash1,acpi=off \
    -accel tcg,thread=multi \
    -cpu "${cpu_model}" \
    -smp "${vcpus}" \
    -m "${memory_mib}" \
    -blockdev node-name=pflash0,driver=file,read-only=on,filename="${firmware_code}" \
    -blockdev node-name=pflash1,driver=file,filename="${firmware_vars}" \
    -drive file="${disk_image}",format=qcow2,id=hd0,if=none,cache=writeback \
    -device virtio-blk-device,drive=hd0 \
    -drive file="${seed_image}",format=raw,id=seed,if=none,readonly=on \
    -device virtio-blk-device,drive=seed \
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
echo "SERIAL_SOCKET=${serial_socket}"
