#!/usr/bin/env bash

set -euo pipefail

config_file=${CONFIG_FILE:-/etc/cloudpods-openruyi-native-k8s.env}
test -s "${config_file}"
# shellcheck source=/dev/null
source "${config_file}"

: "${HOST_DISK_PATH:=/opt/cloud/workspace/disks}"
: "${HOST_NETWORK_INTERFACE:?Set HOST_NETWORK_INTERFACE in ${config_file}}"
: "${NODE_IP:?Set NODE_IP in ${config_file}}"
: "${ARTIFACT_BASE_URL:=https://github.com/yinjiayi/cloudpods-riscv64-releases/releases/download/openruyi-native-k8s-v4.0.3-riscv64.1}"

qemu_version=11.1.0
qemu_archive=qemu-${qemu_version}-openruyi-2026.07-riscv64.tar.gz
qemu_sha256=2fdc2afd0ede5ea4daddf8a668744817d3105e6ea810a58e7ebbb0e979c304c9

if [[ ${EUID} -ne 0 ]]; then
    echo "Run as root" >&2
    exit 1
fi

[[ $(uname -m) == riscv64 ]]
grep -q '^ID="\?openruyi"\?$' /etc/os-release
grep -q '^VERSION_ID="\?Creek"\?$' /etc/os-release

test -c /dev/kvm
test -c /dev/net/tun
ip link show dev "${HOST_NETWORK_INTERFACE}" >/dev/null
if ! ip -4 addr show dev "${HOST_NETWORK_INTERFACE}" | grep -qw "${NODE_IP}" \
    && ! ip -4 addr show dev br0 2>/dev/null | grep -qw "${NODE_IP}"; then
    echo "${NODE_IP} is not configured on ${HOST_NETWORK_INTERFACE} or br0" >&2
    exit 1
fi

curl -fsSL \
    https://yinjiayi.github.io/cloudpods-riscv64-releases/cloudpods-riscv64.repo \
    -o /etc/yum.repos.d/cloudpods-riscv64.repo

dnf install -y \
    cloudpods-executor \
    cloudpods-riscv-firmware \
    glib \
    libaio \
    libcap-ng \
    libslirp \
    liburing \
    mariadb \
    nettle \
    openvswitch \
    pixman

# Remove the compatibility shim installed by early preview revisions.  The
# published Cloudpods image discovers containerd's image filesystem directly.
if [[ -L /usr/bin/docker ]] \
    && [[ $(readlink /usr/bin/docker) == /usr/local/sbin/cloudpods-container-runtime-info ]]; then
    unlink /usr/bin/docker
    rm -f /usr/local/sbin/cloudpods-container-runtime-info
fi

qemu_prefix=/usr/local/qemu-${qemu_version}
qemu_marker=${qemu_prefix}/.cloudpods-bundle-sha256
if [[ ! -x ${qemu_prefix}/bin/qemu-system-riscv64 ]] \
    || [[ ! -s ${qemu_marker} ]] \
    || [[ $(<"${qemu_marker}") != "${qemu_sha256}" ]]; then
    work_dir=$(mktemp -d)
    cleanup() {
        rm -rf "${work_dir}"
    }
    trap cleanup EXIT
    curl --fail --location --retry 5 \
        --output "${work_dir}/${qemu_archive}" \
        "${ARTIFACT_BASE_URL}/${qemu_archive}"
    printf '%s  %s\n' "${qemu_sha256}" "${work_dir}/${qemu_archive}" \
        | sha256sum --check
    tar -xzf "${work_dir}/${qemu_archive}" -C /usr/local
    printf '%s\n' "${qemu_sha256}" >"${qemu_marker}"
    cleanup
    trap - EXIT
fi

# mysql/openvswitch dependencies can install SELinux policy after
# 10-runtime.sh has already run.  Keep the supported permissive setting both
# immediately and across the next reboot.
if [[ -f /etc/selinux/config ]]; then
    sed -ri 's/^SELINUX=.*/SELINUX=permissive/' /etc/selinux/config
fi
if command -v getenforce >/dev/null && [[ $(getenforce) == Enforcing ]]; then
    setenforce 0
fi

install -d -m 0755 \
    "${HOST_DISK_PATH}" \
    "${HOST_DISK_PATH}/image_cache" \
    /opt/cloud/workspace/memory_snapshots \
    /opt/cloud/workspace/servers \
    /etc/yunion \
    /etc/openvswitch \
    /var/run/openvswitch

cat >/etc/yunion/host.conf <<EOF
listen_interface: br0
networks:
- ${HOST_NETWORK_INTERFACE}/br0/${NODE_IP}
local_image_path:
- ${HOST_DISK_PATH}
EOF
cat >/etc/yunion/host_local.conf <<'EOF'
default_qemu_version: 11.1.0
EOF

# The Cloudpods local-only OVS bridge must keep an IPv4 link-local address.
# A small reconciler is used because the bridge is created by the Host
# DaemonSet and can be recreated during boot before hostman starts.
cat >/usr/local/sbin/cloudpods-brlocal-address <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
while true; do
    if [[ -S /var/run/openvswitch/db.sock ]] && ! ip link show dev brlocal >/dev/null 2>&1; then
        ovs-vsctl --may-exist add-br brlocal
    fi
    if ip link show dev brlocal >/dev/null 2>&1; then
        ip link set dev brlocal up
        if ! ip -4 address show dev brlocal | grep -Eq 'inet 169\.254\.'; then
            ip address add 169.254.0.1/16 dev brlocal
        fi
    fi
    sleep 5
done
EOF
chmod 0755 /usr/local/sbin/cloudpods-brlocal-address

cat >/etc/systemd/system/cloudpods-brlocal-address.service <<'EOF'
[Unit]
Description=Keep the Cloudpods brlocal IPv4 link-local address
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
ExecStart=/usr/local/sbin/cloudpods-brlocal-address
Restart=always
RestartSec=2

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
systemctl enable --now cloudpods-brlocal-address.service
systemctl enable cloudpods-executor
systemctl restart cloudpods-executor

for _ in {1..30}; do
    [[ -S /var/run/onecloud/exec.sock ]] && break
    sleep 1
done

test -S /var/run/onecloud/exec.sock
qemu_bin=${qemu_prefix}/bin/qemu-system-riscv64
test -x "${qemu_bin}"
"${qemu_bin}" --version | grep -F 'version 11.1.0'
ldd "${qemu_bin}" | grep -F 'libnettle.so'

# Cloudpods configures a password-protected VNC endpoint for every guest.  A
# timeout proves that QEMU stayed alive instead of rejecting the DES-RFB
# cipher because the crypto backend was omitted from the build.
set +e
timeout 2 "${qemu_bin}" \
    -machine virt \
    -nodefaults \
    -S \
    -bios none \
    -vnc :99,password \
    >/dev/null 2>&1
vnc_test_rc=$?
set -e
if [[ ${vnc_test_rc} -ne 124 ]]; then
    echo "QEMU VNC DES-RFB self-test failed with status ${vnc_test_rc}" >&2
    exit 1
fi

kernel=/boot/vmlinuz-$(uname -r)
initramfs=/boot/initramfs-$(uname -r).img
if [[ ! -s ${kernel} ]]; then
    kernel=/boot/efi/openruyi/$(uname -r)/linux
    initramfs=/boot/efi/openruyi/$(uname -r)/initrd
fi
test -s "${kernel}"
test -s "${initramfs}"
kvm_log=/var/log/cloudpods-riscv64-kvm-smoke.log
set +e
timeout 30 "${qemu_bin}" \
    -machine virt,accel=kvm \
    -cpu host \
    -smp 1 \
    -m 1024 \
    -bios none \
    -kernel "${kernel}" \
    -initrd "${initramfs}" \
    -append 'console=ttyS0 rd.break' \
    -nographic \
    -no-reboot \
    >"${kvm_log}" 2>&1
kvm_status=$?
set -e
if [[ ${kvm_status} -ne 124 ]]; then
    cat "${kvm_log}" >&2
    echo "KVM smoke test exited before the 30-second acceptance window (status ${kvm_status})" >&2
    exit 1
fi
grep -F 'Linux version' "${kvm_log}"
grep -F 'Machine model: riscv-virtio,qemu' "${kvm_log}"

echo CLOUDPODS_HOST_PREREQUISITES_OK
