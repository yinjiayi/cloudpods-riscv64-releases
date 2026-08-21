#!/usr/bin/env bash

set -euo pipefail

config_file=${CONFIG_FILE:-/etc/cloudpods-native-k8s.env}
test -s "${config_file}"
# shellcheck source=/dev/null
source "${config_file}"

: "${NODE_NAME:?}"
: "${NODE_IP:?}"
: "${POD_CIDR:?}"
: "${POD_NODE_CIDR:?}"
: "${CONTROL_PLANE_IP:?}"

token=${1:-}
ca_hash=${2:-}
if [[ ! ${token} =~ ^[a-z0-9]{6}\.[a-z0-9]{16}$ ]]; then
    echo "Usage: $0 KUBEADM_TOKEN sha256:DISCOVERY_HASH" >&2
    exit 1
fi
if [[ ! ${ca_hash} =~ ^sha256:[0-9a-f]{64}$ ]]; then
    echo "Usage: $0 KUBEADM_TOKEN sha256:DISCOVERY_HASH" >&2
    exit 1
fi
if [[ ${EUID} -ne 0 ]]; then
    echo "Run as root" >&2
    exit 1
fi

ip -4 address show | grep -Fq "${NODE_IP}/"
test -s /etc/kubernetes/kube-proxy.conf

install -d -m 0755 \
    /etc/kubernetes \
    /etc/systemd/system/kube-proxy.service.d \
    /var/lib/kube-proxy

cat >/etc/sysconfig/kubelet <<EOF
KUBELET_EXTRA_ARGS=--hostname-override=${NODE_NAME} --node-ip=${NODE_IP} --container-runtime-endpoint=unix:///run/containerd/containerd.sock
EOF

if [[ ! -s /etc/kubernetes/kubelet.conf ]]; then
    kubeadm join "${CONTROL_PLANE_IP}:6443" \
        --token "${token}" \
        --discovery-token-ca-cert-hash "${ca_hash}" \
        --node-name "${NODE_NAME}" \
        --cri-socket unix:///run/containerd/containerd.sock
fi

cat >/var/lib/kube-proxy/config.conf <<EOF
apiVersion: kubeproxy.config.k8s.io/v1alpha1
kind: KubeProxyConfiguration
bindAddress: 0.0.0.0
clientConnection:
  kubeconfig: /etc/kubernetes/kube-proxy.conf
clusterCIDR: ${POD_CIDR}
mode: iptables
EOF

cat >/etc/systemd/system/kube-proxy.service.d/10-cloudpods-riscv.conf <<'EOF'
[Service]
EnvironmentFile=
ExecStart=
ExecStart=/usr/bin/kube-proxy --config=/var/lib/kube-proxy/config.conf
EOF

systemctl daemon-reload
systemctl enable kubelet kube-proxy
systemctl restart kubelet kube-proxy

node_ready=false
for _ in {1..180}; do
    if kubectl --kubeconfig=/etc/kubernetes/kubelet.conf get node "${NODE_NAME}" \
        -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}' 2>/dev/null \
        | grep -qx True; then
        node_ready=true
        break
    fi
    sleep 2
done
${node_ready}

allocated_cidr=$(kubectl --kubeconfig=/etc/kubernetes/kubelet.conf \
    get node "${NODE_NAME}" -o jsonpath='{.spec.podCIDR}')
if [[ ${allocated_cidr} != "${POD_NODE_CIDR}" ]]; then
    echo "Controller allocated ${allocated_cidr}; configure POD_NODE_CIDR=${allocated_cidr} and rerun 10-runtime.sh" >&2
    exit 1
fi

kubectl --kubeconfig=/etc/kubernetes/kubelet.conf get node "${NODE_NAME}" -o wide
echo NATIVE_K8S_WORKER_OK
