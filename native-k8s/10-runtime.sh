#!/usr/bin/env bash

set -euo pipefail

config_file=${CONFIG_FILE:-/etc/cloudpods-native-k8s.env}
test -s "${config_file}"
# shellcheck source=/dev/null
source "${config_file}"

: "${NODE_NAME:?}"
: "${NODE_IP:?}"
: "${POD_NODE_CIDR:?}"
: "${GHCR_NAMESPACE:=ghcr.io/yinjiayi}"

if [[ ${EUID} -ne 0 ]]; then
    echo "Run as root" >&2
    exit 1
fi

if [[ ! ${NODE_NAME} =~ ^[a-z0-9][a-z0-9.-]*$ ]]; then
    echo "NODE_NAME must be a lowercase DNS hostname" >&2
    exit 1
fi

awk -v node="${NODE_NAME}" '
    {
        found = 0
        for (field = 2; field <= NF; field++) {
            if ($field == node) {
                found = 1
            }
        }
        if (!found) {
            print
        }
    }
' /etc/hosts >/etc/hosts.cloudpods-native-k8s
install -m 0644 /etc/hosts.cloudpods-native-k8s /etc/hosts
rm -f /etc/hosts.cloudpods-native-k8s
printf '%s %s\n' "${NODE_IP}" "${NODE_NAME}" >>/etc/hosts

[[ $(uname -m) == riscv64 ]]
grep -q '24.03' /etc/openEuler-release
grep -q 'LTS-SP3' /etc/openEuler-release

# Kubernetes and the privileged Cloudpods host agent require permissive mode.
# This also avoids the SP3 RVA23 image booting early services in kernel_t after
# an enforcing reboot, which prevents sshd from creating user sessions.
setenforce 0 2>/dev/null || true
if [[ -f /etc/selinux/config ]]; then
    sed -i -E 's/^SELINUX=.*/SELINUX=permissive/' /etc/selinux/config
fi

swapoff -a
sed -i.bak-cloudpods-native-k8s -E '/^[^#].+[[:space:]]swap[[:space:]]/s/^/# cloudpods-native-k8s: /' /etc/fstab

cat >/etc/modules-load.d/cloudpods-native-k8s.conf <<'EOF'
overlay
br_netfilter
kvm
EOF

modprobe overlay
modprobe br_netfilter
modprobe kvm

rm -f /etc/sysctl.d/90-cloudpods-native-k8s.conf
cat >/etc/sysctl.d/99-z-cloudpods-native-k8s.conf <<'EOF'
net.ipv4.ip_forward = 1
net.bridge.bridge-nf-call-iptables = 1
net.bridge.bridge-nf-call-ip6tables = 1
EOF
# openEuler's `sysctl --system` also applies /etc/sysctl.conf after the files
# under sysctl.d.  Override its shipped ip_forward=0 value as well.
if grep -Eq '^[[:space:]]*net\.ipv4\.ip_forward[[:space:]]*=' /etc/sysctl.conf; then
    sed -i -E 's/^[[:space:]]*net\.ipv4\.ip_forward[[:space:]]*=.*/net.ipv4.ip_forward = 1/' /etc/sysctl.conf
else
    printf '\nnet.ipv4.ip_forward = 1\n' >>/etc/sysctl.conf
fi
sysctl --system >/dev/null

install -d -m 0755 /etc/containerd /etc/cni/net.d /var/lib/containerd
containerd config default >/etc/containerd/config.toml.new
sed -i \
    -e "s#sandbox_image = \".*\"#sandbox_image = \"${GHCR_NAMESPACE}/k3s-pause:3.10-riscv64.1\"#" \
    -e 's#SystemdCgroup = false#SystemdCgroup = true#' \
    -e 's#bin_dir = "/opt/cni/bin"#bin_dir = "/usr/libexec/cni"#' \
    /etc/containerd/config.toml.new
install -m 0644 /etc/containerd/config.toml.new /etc/containerd/config.toml
rm -f /etc/containerd/config.toml.new

cat >/etc/cni/net.d/10-cloudpods-native.conflist <<EOF
{
  "cniVersion": "0.4.0",
  "name": "cloudpods-native",
  "plugins": [
    {
      "type": "bridge",
      "bridge": "cni0",
      "isGateway": true,
      "ipMasq": true,
      "hairpinMode": true,
      "ipam": {
        "type": "host-local",
        "ranges": [[{"subnet": "${POD_NODE_CIDR}"}]],
        "routes": [{"dst": "0.0.0.0/0"}]
      }
    },
    {
      "type": "portmap",
      "capabilities": {"portMappings": true}
    }
  ]
}
EOF

systemctl enable --now chronyd
systemctl enable --now containerd

pause_image=${GHCR_NAMESPACE}/k3s-pause:3.10-riscv64.1
coredns_source=${GHCR_NAMESPACE}/k3s-coredns:1.11.1-riscv64.1
coredns_target=registry.k8s.io/coredns/coredns:v1.11.1

ctr --namespace k8s.io images pull --platform linux/riscv64 "${pause_image}"
ctr --namespace k8s.io images pull --platform linux/riscv64 "${coredns_source}"
if ! ctr --namespace k8s.io images list -q | grep -Fxq "${coredns_target}"; then
    ctr --namespace k8s.io images tag "${coredns_source}" "${coredns_target}"
fi

systemctl is-active --quiet containerd
ctr plugins list | awk '
    $1 == "io.containerd.grpc.v1" && $2 == "cri" && $4 == "ok" { found = 1 }
    END { exit !found }
'
test -c /dev/kvm
test "$(sysctl -n net.ipv4.ip_forward)" = 1
test -x /usr/libexec/cni/bridge
test -x /usr/libexec/cni/host-local
test -x /usr/libexec/cni/portmap

echo NATIVE_K8S_RUNTIME_OK
