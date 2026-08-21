#!/usr/bin/env bash

set -euo pipefail

config_file=${CONFIG_FILE:-/etc/cloudpods-native-k8s.env}
test -s "${config_file}"
# shellcheck source=/dev/null
source "${config_file}"

: "${NODE_NAME:?}"
: "${NODE_IP:?}"
: "${POD_CIDR:?}"
: "${SERVICE_CIDR:?}"
: "${CLUSTER_DNS:?}"
: "${CLUSTER_NAME:?}"

if [[ ${EUID} -ne 0 ]]; then
    echo "Run as root" >&2
    exit 1
fi

ip -4 address show | grep -Fq "${NODE_IP}/"

bootstrap_dir=/opt/cloudpods-native-k8s
kubeadm_config=${bootstrap_dir}/kubeadm.yaml
kubeconfig=/etc/kubernetes/admin.conf

install -d -m 0700 /etc/kubernetes/pki
install -d -m 0755 \
    "${bootstrap_dir}" \
    /etc/kubernetes/manifests \
    /var/lib/etcd \
    /var/lib/kubelet \
    /var/lib/kube-proxy
install -d -m 0755 \
    /etc/systemd/system/etcd.service.d \
    /etc/systemd/system/kube-apiserver.service.d \
    /etc/systemd/system/kube-controller-manager.service.d \
    /etc/systemd/system/kube-scheduler.service.d \
    /etc/systemd/system/kubelet.service.d \
    /etc/systemd/system/kube-proxy.service.d

cat >"${kubeadm_config}" <<EOF
apiVersion: kubeadm.k8s.io/v1beta3
kind: InitConfiguration
localAPIEndpoint:
  advertiseAddress: ${NODE_IP}
  bindPort: 6443
nodeRegistration:
  name: ${NODE_NAME}
  criSocket: unix:///run/containerd/containerd.sock
---
apiVersion: kubeadm.k8s.io/v1beta3
kind: ClusterConfiguration
clusterName: ${CLUSTER_NAME}
kubernetesVersion: v1.29.1
controlPlaneEndpoint: ${NODE_IP}:6443
certificatesDir: /etc/kubernetes/pki
networking:
  dnsDomain: cluster.local
  podSubnet: ${POD_CIDR}
  serviceSubnet: ${SERVICE_CIDR}
apiServer:
  certSANs:
    - ${NODE_IP}
    - 127.0.0.1
    - ${NODE_NAME}
controllerManager:
  extraArgs:
    allocate-node-cidrs: "true"
    cluster-cidr: ${POD_CIDR}
    node-cidr-mask-size: "24"
scheduler: {}
---
apiVersion: kubelet.config.k8s.io/v1beta1
kind: KubeletConfiguration
authentication:
  anonymous:
    enabled: false
  webhook:
    enabled: true
  x509:
    clientCAFile: /etc/kubernetes/pki/ca.crt
authorization:
  mode: Webhook
cgroupDriver: systemd
clusterDNS:
  - ${CLUSTER_DNS}
clusterDomain: cluster.local
failSwapOn: false
resolvConf: /etc/resolv.conf
rotateCertificates: true
serverTLSBootstrap: false
staticPodPath: /etc/kubernetes/manifests
EOF

if [[ ! -s /etc/kubernetes/pki/ca.crt ]]; then
    kubeadm init phase certs all --config "${kubeadm_config}"
fi

if [[ ! -s /etc/kubernetes/admin.conf ]]; then
    kubeadm init phase kubeconfig all --config "${kubeadm_config}"
fi

if [[ ! -s /etc/kubernetes/pki/kube-proxy.crt ]]; then
    openssl genrsa -out /etc/kubernetes/pki/kube-proxy.key 2048
    openssl req -new \
        -key /etc/kubernetes/pki/kube-proxy.key \
        -out /etc/kubernetes/pki/kube-proxy.csr \
        -subj '/CN=system:kube-proxy/O=system:node-proxier'
    openssl x509 -req \
        -in /etc/kubernetes/pki/kube-proxy.csr \
        -CA /etc/kubernetes/pki/ca.crt \
        -CAkey /etc/kubernetes/pki/ca.key \
        -CAcreateserial \
        -out /etc/kubernetes/pki/kube-proxy.crt \
        -days 3650 \
        -sha256
    rm -f /etc/kubernetes/pki/kube-proxy.csr
fi

kubectl config set-cluster "${CLUSTER_NAME}" \
    --certificate-authority=/etc/kubernetes/pki/ca.crt \
    --embed-certs=true \
    --server="https://${NODE_IP}:6443" \
    --kubeconfig=/etc/kubernetes/kube-proxy.conf
kubectl config set-credentials system:kube-proxy \
    --client-certificate=/etc/kubernetes/pki/kube-proxy.crt \
    --client-key=/etc/kubernetes/pki/kube-proxy.key \
    --embed-certs=true \
    --kubeconfig=/etc/kubernetes/kube-proxy.conf
kubectl config set-context default \
    --cluster="${CLUSTER_NAME}" \
    --user=system:kube-proxy \
    --kubeconfig=/etc/kubernetes/kube-proxy.conf
kubectl config use-context default --kubeconfig=/etc/kubernetes/kube-proxy.conf

cat >/etc/systemd/system/etcd.service.d/10-cloudpods-riscv.conf <<EOF
[Service]
User=root
EnvironmentFile=
ExecStart=
ExecStart=/usr/bin/etcd --name=${NODE_NAME} --data-dir=/var/lib/etcd --listen-client-urls=https://127.0.0.1:2379,https://${NODE_IP}:2379 --advertise-client-urls=https://${NODE_IP}:2379 --listen-peer-urls=https://${NODE_IP}:2380 --initial-advertise-peer-urls=https://${NODE_IP}:2380 --initial-cluster=${NODE_NAME}=https://${NODE_IP}:2380 --initial-cluster-state=new --client-cert-auth=true --trusted-ca-file=/etc/kubernetes/pki/etcd/ca.crt --cert-file=/etc/kubernetes/pki/etcd/server.crt --key-file=/etc/kubernetes/pki/etcd/server.key --peer-client-cert-auth=true --peer-trusted-ca-file=/etc/kubernetes/pki/etcd/ca.crt --peer-cert-file=/etc/kubernetes/pki/etcd/peer.crt --peer-key-file=/etc/kubernetes/pki/etcd/peer.key
EOF

cat >/etc/systemd/system/kube-apiserver.service.d/10-cloudpods-riscv.conf <<EOF
[Service]
User=root
EnvironmentFile=
ExecStart=
ExecStart=/usr/bin/kube-apiserver --advertise-address=${NODE_IP} --bind-address=0.0.0.0 --secure-port=6443 --allow-privileged=true --authorization-mode=Node,RBAC --enable-admission-plugins=NodeRestriction --enable-bootstrap-token-auth=true --etcd-servers=https://127.0.0.1:2379 --etcd-cafile=/etc/kubernetes/pki/etcd/ca.crt --etcd-certfile=/etc/kubernetes/pki/apiserver-etcd-client.crt --etcd-keyfile=/etc/kubernetes/pki/apiserver-etcd-client.key --client-ca-file=/etc/kubernetes/pki/ca.crt --tls-cert-file=/etc/kubernetes/pki/apiserver.crt --tls-private-key-file=/etc/kubernetes/pki/apiserver.key --kubelet-client-certificate=/etc/kubernetes/pki/apiserver-kubelet-client.crt --kubelet-client-key=/etc/kubernetes/pki/apiserver-kubelet-client.key --kubelet-preferred-address-types=InternalIP,Hostname,ExternalIP --service-cluster-ip-range=${SERVICE_CIDR} --service-node-port-range=30000-32767 --service-account-issuer=https://kubernetes.default.svc.cluster.local --service-account-key-file=/etc/kubernetes/pki/sa.pub --service-account-signing-key-file=/etc/kubernetes/pki/sa.key --requestheader-client-ca-file=/etc/kubernetes/pki/front-proxy-ca.crt --requestheader-allowed-names=front-proxy-client --requestheader-extra-headers-prefix=X-Remote-Extra- --requestheader-group-headers=X-Remote-Group --requestheader-username-headers=X-Remote-User --proxy-client-cert-file=/etc/kubernetes/pki/front-proxy-client.crt --proxy-client-key-file=/etc/kubernetes/pki/front-proxy-client.key
EOF

cat >/etc/systemd/system/kube-controller-manager.service.d/10-cloudpods-riscv.conf <<EOF
[Service]
User=root
EnvironmentFile=
ExecStart=
ExecStart=/usr/bin/kube-controller-manager --bind-address=127.0.0.1 --kubeconfig=/etc/kubernetes/controller-manager.conf --authentication-kubeconfig=/etc/kubernetes/controller-manager.conf --authorization-kubeconfig=/etc/kubernetes/controller-manager.conf --client-ca-file=/etc/kubernetes/pki/ca.crt --cluster-name=${CLUSTER_NAME} --cluster-cidr=${POD_CIDR} --allocate-node-cidrs=true --node-cidr-mask-size=24 --cluster-signing-cert-file=/etc/kubernetes/pki/ca.crt --cluster-signing-key-file=/etc/kubernetes/pki/ca.key --controllers=*,bootstrap-signer-controller,token-cleaner-controller --root-ca-file=/etc/kubernetes/pki/ca.crt --service-account-private-key-file=/etc/kubernetes/pki/sa.key --service-cluster-ip-range=${SERVICE_CIDR} --use-service-account-credentials=true --leader-elect=true
EOF

cat >/etc/systemd/system/kube-scheduler.service.d/10-cloudpods-riscv.conf <<'EOF'
[Service]
User=root
EnvironmentFile=
ExecStart=
ExecStart=/usr/bin/kube-scheduler --bind-address=127.0.0.1 --kubeconfig=/etc/kubernetes/scheduler.conf --authentication-kubeconfig=/etc/kubernetes/scheduler.conf --authorization-kubeconfig=/etc/kubernetes/scheduler.conf --leader-elect=true
EOF

cat >/var/lib/kubelet/config.yaml <<EOF
apiVersion: kubelet.config.k8s.io/v1beta1
kind: KubeletConfiguration
authentication:
  anonymous:
    enabled: false
  webhook:
    enabled: true
  x509:
    clientCAFile: /etc/kubernetes/pki/ca.crt
authorization:
  mode: Webhook
cgroupDriver: systemd
clusterDNS:
  - ${CLUSTER_DNS}
clusterDomain: cluster.local
failSwapOn: false
resolvConf: /etc/resolv.conf
rotateCertificates: true
serverTLSBootstrap: false
staticPodPath: /etc/kubernetes/manifests
EOF

rm -f /etc/systemd/system/kubelet.service.d/10-cloudpods-riscv.conf
cat >/etc/sysconfig/kubelet <<EOF
KUBELET_EXTRA_ARGS=--hostname-override=${NODE_NAME} --node-ip=${NODE_IP} --container-runtime-endpoint=unix:///run/containerd/containerd.sock
EOF

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
systemctl enable --now etcd
systemctl enable --now kube-apiserver

api_ready=false
for _ in {1..90}; do
    if kubectl --kubeconfig="${kubeconfig}" get --raw=/readyz >/dev/null 2>&1; then
        api_ready=true
        break
    fi
    sleep 2
done
${api_ready}

systemctl enable --now kube-controller-manager kube-scheduler
kubeadm init phase upload-config kubeadm --config "${kubeadm_config}"
kubeadm init phase bootstrap-token --config "${kubeadm_config}"
systemctl enable kubelet kube-proxy
systemctl restart kubelet kube-proxy

node_registered=false
for _ in {1..120}; do
    if kubectl --kubeconfig="${kubeconfig}" get node "${NODE_NAME}" >/dev/null 2>&1; then
        node_registered=true
        break
    fi
    sleep 2
done
${node_registered}

kubectl --kubeconfig="${kubeconfig}" label node "${NODE_NAME}" \
    node-role.kubernetes.io/control-plane= --overwrite
kubectl --kubeconfig="${kubeconfig}" taint node "${NODE_NAME}" \
    node-role.kubernetes.io/control-plane- 2>/dev/null || true
kubeadm init phase upload-config kubelet --config "${kubeadm_config}"
kubeadm init phase addon coredns --config "${kubeadm_config}"

install -d -m 0700 /root/.kube
install -m 0600 "${kubeconfig}" /root/.kube/config

node_ready=false
for _ in {1..180}; do
    if kubectl --kubeconfig="${kubeconfig}" get node "${NODE_NAME}" \
        -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}' | grep -qx True; then
        node_ready=true
        break
    fi
    sleep 2
done
${node_ready}

coredns_ready=false
for _ in {1..180}; do
    if kubectl --kubeconfig="${kubeconfig}" -n kube-system rollout status \
        deployment/coredns --timeout=2s >/dev/null 2>&1; then
        coredns_ready=true
        break
    fi
    sleep 2
done
${coredns_ready}

kubectl --kubeconfig="${kubeconfig}" get nodes -o wide
kubectl --kubeconfig="${kubeconfig}" get pods -A -o wide
echo NATIVE_KUBERNETES_OK
