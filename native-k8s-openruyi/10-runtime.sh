#!/usr/bin/env bash

set -euo pipefail

config_file=${CONFIG_FILE:-/etc/cloudpods-openruyi-native-k8s.env}
test -s "${config_file}"
# shellcheck source=/dev/null
source "${config_file}"

: "${NODE_NAME:?}"
: "${NODE_IP:?}"
: "${POD_NODE_CIDR:?}"
: "${GHCR_NAMESPACE:=ghcr.io/yinjiayi}"
: "${NTP_POOLS:=pool.ntp.org}"
: "${NTP_SERVERS:=}"

if [[ ${EUID} -ne 0 ]]; then
    echo "Run as root" >&2
    exit 1
fi
if [[ ! ${NODE_NAME} =~ ^[a-z0-9][a-z0-9.-]*$ ]]; then
    echo "NODE_NAME must be a lowercase DNS hostname" >&2
    exit 1
fi

containerd_bin=$(command -v containerd)
kubelet_bin=$(command -v kubelet)
kube_proxy_bin=$(command -v kube-proxy)

[[ $(uname -m) == riscv64 ]]
grep -q '^ID="\?openruyi"\?$' /etc/os-release
grep -q '^VERSION_ID="\?Creek"\?$' /etc/os-release
hostnamectl set-hostname "${NODE_NAME}"

awk -v node="${NODE_NAME}" '
    {
        found = 0
        for (field = 2; field <= NF; field++) {
            if ($field == node) found = 1
        }
        if (!found) print
    }
' /etc/hosts >/etc/hosts.cloudpods-openruyi-native
install -m 0644 /etc/hosts.cloudpods-openruyi-native /etc/hosts
rm -f /etc/hosts.cloudpods-openruyi-native
printf '%s %s\n' "${NODE_IP}" "${NODE_NAME}" >>/etc/hosts

setenforce 0 2>/dev/null || true
if [[ -f /etc/selinux/config ]]; then
    sed -i -E 's/^SELINUX=.*/SELINUX=permissive/' /etc/selinux/config
fi

swapoff -a
sed -i.bak-cloudpods-openruyi-native -E \
    '/^[^#].+[[:space:]]swap[[:space:]]/s/^/# cloudpods-openruyi-native: /' \
    /etc/fstab

install -d -m 0755 /etc/modules-load.d /etc/sysctl.d /etc/sysconfig
cat >/etc/modules-load.d/cloudpods-openruyi-native.conf <<'EOF'
overlay
br_netfilter
kvm
tun
nf_conntrack
nf_nat
nft_masq
EOF
modprobe overlay
modprobe br_netfilter
modprobe tun
modprobe kvm
modprobe nf_conntrack
modprobe nf_nat
modprobe nft_masq

cat >/etc/sysctl.d/99-cloudpods-openruyi-native.conf <<'EOF'
net.ipv4.ip_forward = 1
net.bridge.bridge-nf-call-iptables = 1
net.bridge.bridge-nf-call-ip6tables = 1
EOF
sysctl --system >/dev/null

install -d -m 0755 \
    /etc/containerd \
    /etc/containerd/conf.d \
    /etc/cni/net.d \
    /etc/kubernetes \
    /var/lib/containerd
containerd config default >/etc/containerd/config.toml.new
sed -i \
    -e "s#sandbox = '.*'#sandbox = '${GHCR_NAMESPACE}/k8s-pause:3.10.2-riscv64.1'#" \
    -e 's/SystemdCgroup = false/SystemdCgroup = true/' \
    /etc/containerd/config.toml.new
install -m 0644 /etc/containerd/config.toml.new /etc/containerd/config.toml
rm -f /etc/containerd/config.toml.new

cat >/etc/cni/net.d/10-cloudpods-openruyi-native.conflist <<EOF
{
  "cniVersion": "1.0.0",
  "name": "cloudpods-openruyi-native",
  "plugins": [
    {
      "type": "bridge",
      "bridge": "cni0",
      "isGateway": true,
      "ipMasq": false,
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

install -d -m 0755 /etc/nftables
cat >/etc/nftables/cloudpods-openruyi-native.nft <<EOF
table ip cloudpods_openruyi_native {
  chain postrouting {
    type nat hook postrouting priority srcnat; policy accept;
    ip saddr ${POD_NODE_CIDR} ip daddr != ${POD_CIDR} masquerade
  }
}
EOF

cat >/etc/systemd/system/cloudpods-openruyi-nftables.service <<'EOF'
[Unit]
Description=Cloudpods openRuyi Pod egress nftables rules
After=network-online.target
Wants=network-online.target

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStartPre=-/usr/sbin/nft delete table ip cloudpods_openruyi_native
ExecStart=/usr/sbin/nft -f /etc/nftables/cloudpods-openruyi-native.nft
ExecStop=-/usr/sbin/nft delete table ip cloudpods_openruyi_native

[Install]
WantedBy=multi-user.target
EOF

cat >/etc/systemd/system/containerd.service <<EOF
[Unit]
Description=containerd container runtime
Documentation=https://containerd.io
After=network.target local-fs.target cloudpods-time-sync.service
Requires=cloudpods-time-sync.service

[Service]
ExecStartPre=-/sbin/modprobe overlay
ExecStart=${containerd_bin}
Type=notify
Delegate=yes
KillMode=process
Restart=always
RestartSec=5
LimitNPROC=infinity
LimitCORE=infinity
LimitNOFILE=1048576
TasksMax=infinity
OOMScoreAdjust=-999

[Install]
WantedBy=multi-user.target
EOF

cat >/etc/chrony.conf <<EOF
driftfile /var/lib/chrony/drift
makestep 1.0 3
rtcsync
$(for ntp_pool in ${NTP_POOLS}; do printf 'pool %s iburst\n' "${ntp_pool}"; done)
$(for ntp_server in ${NTP_SERVERS}; do printf 'server %s iburst\n' "${ntp_server}"; done)
EOF

cat >/etc/systemd/system/cloudpods-time-sync.service <<'EOF'
[Unit]
Description=Synchronize time before Kubernetes and containerd start
After=network-online.target chronyd.service
Wants=network-online.target
Requires=chronyd.service
Before=containerd.service kubelet.service kube-proxy.service

[Service]
Type=oneshot
ExecStart=/usr/bin/chronyc -a online
ExecStart=/usr/bin/chronyc -a burst 4/4
ExecStart=/usr/bin/chronyc -a makestep
ExecStart=/usr/bin/chronyc waitsync 120 1.0 1000000 1
RemainAfterExit=yes

[Install]
WantedBy=multi-user.target
EOF

cat >/etc/systemd/system/kubelet.service <<EOF
[Unit]
Description=Kubernetes Kubelet
After=containerd.service network-online.target
Wants=network-online.target
Requires=containerd.service

[Service]
EnvironmentFile=-/etc/sysconfig/kubelet
ExecStart=${kubelet_bin} --config=/var/lib/kubelet/config.yaml \$KUBELET_EXTRA_ARGS
Restart=always
RestartSec=5
StartLimitInterval=0

[Install]
WantedBy=multi-user.target
EOF

# The openRuyi kubernetes RPM ships a vendor drop-in that replaces ExecStart.
# Override it at the administrator level so this deployment consistently uses
# the generated kubelet configuration, including the non-stub resolver file.
install -d -m 0755 /etc/systemd/system/kubelet.service.d
rm -f /etc/systemd/system/kubelet.service.d/00-cloudpods-openruyi.conf
cat >/etc/systemd/system/kubelet.service.d/99-cloudpods-openruyi.conf <<EOF
[Service]
ExecStart=
ExecStart=${kubelet_bin} --config=/var/lib/kubelet/config.yaml \$KUBELET_EXTRA_ARGS
EOF

cat >/etc/systemd/system/kube-proxy.service <<EOF
[Unit]
Description=Kubernetes Kube Proxy
After=network-online.target
Wants=network-online.target

[Service]
ExecStart=${kube_proxy_bin} --config=/var/lib/kube-proxy/config.conf
Restart=always
RestartSec=5
StartLimitInterval=0

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
install -d -o chrony -g chrony -m 0750 /var/lib/chrony
systemctl enable chronyd cloudpods-time-sync containerd cloudpods-openruyi-nftables
systemctl restart chronyd
systemctl start cloudpods-time-sync containerd cloudpods-openruyi-nftables

pause_source=${GHCR_NAMESPACE}/k8s-pause:3.10.2-riscv64.1
coredns_source=${GHCR_NAMESPACE}/k8s-coredns:1.14.2-riscv64.1
coredns_target=registry.k8s.io/coredns/coredns:v1.14.2

ctr --namespace k8s.io images pull --platform linux/riscv64 "${pause_source}"
ctr --namespace k8s.io images pull --platform linux/riscv64 "${coredns_source}"
ctr --namespace k8s.io images tag --force \
    "${coredns_source}" "${coredns_target}" >/dev/null

systemctl is-active --quiet containerd
ctr plugins list | awk '
    $1 == "io.containerd.cri.v1" && $2 == "runtime" && $4 == "ok" { found = 1 }
    END { exit !found }
'
test -c /dev/kvm
test -c /dev/net/tun
test "$(sysctl -n net.ipv4.ip_forward)" = 1
test -x /opt/cni/bin/bridge
test -x /opt/cni/bin/host-local
test -x /opt/cni/bin/portmap
echo OPENRUYI_NATIVE_K8S_RUNTIME_OK
