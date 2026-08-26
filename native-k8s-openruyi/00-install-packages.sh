#!/usr/bin/env bash

set -euo pipefail

config_file=${CONFIG_FILE:-/etc/cloudpods-openruyi-native-k8s.env}
test -s "${config_file}"
# shellcheck source=/dev/null
source "${config_file}"

: "${ARTIFACT_BASE_URL:=https://github.com/yinjiayi/cloudpods-riscv64-releases/releases/download/openruyi-native-k8s-v4.0.3-riscv64.1}"

kubernetes_version=v1.36.4
containerd_version=2.3.4
etcd_version=v3.7.1
crictl_version=v1.36.0
cni_version=v1.9.1

if [[ ${EUID} -ne 0 ]]; then
    echo "Run as root" >&2
    exit 1
fi
[[ $(uname -m) == riscv64 ]]
grep -q '^ID="\?openruyi"\?$' /etc/os-release
grep -q '^VERSION_ID="\?Creek"\?$' /etc/os-release

dnf install -y \
    chrony \
    conntrack-tools \
    curl \
    ethtool \
    iproute2 \
    iptables-nft \
    iputils \
    jq \
    nftables \
    openssl \
    procps-ng \
    psmisc \
    python3 \
    rsync \
    runc \
    socat \
    tar \
    unzip \
    wget \
    xz

work_dir=$(mktemp -d)
cleanup() {
    rm -rf "${work_dir}"
}
trap cleanup EXIT

download_and_check() {
    local url=$1
    local output=$2
    local sha256=$3
    curl --fail --location --retry 5 --output "${work_dir}/${output}" "${url}"
    printf '%s  %s\n' "${sha256}" "${work_dir}/${output}" | sha256sum --check
}

kubernetes_archive=kubernetes-${kubernetes_version}-linux-riscv64.tar.gz
download_and_check \
    "${ARTIFACT_BASE_URL}/${kubernetes_archive}" \
    "${kubernetes_archive}" \
    68938df789c1f341df8d2acd8fd99cc1ff8d82a0998677f12eca4fd21b23ff62
tar -xzf "${work_dir}/${kubernetes_archive}" -C "${work_dir}"
install -m 0755 \
    "${work_dir}/kubernetes-${kubernetes_version}-linux-riscv64/"* \
    /usr/local/bin/

etcd_archive=etcd-${etcd_version}-linux-riscv64.tar.gz
download_and_check \
    "${ARTIFACT_BASE_URL}/${etcd_archive}" \
    "${etcd_archive}" \
    58240fb5926bbe0f9e2f65706104ee50362dd38cf7f6964d330f3165b4c9725f
tar -xzf "${work_dir}/${etcd_archive}" -C "${work_dir}"
install -m 0755 \
    "${work_dir}/etcd-${etcd_version}-linux-riscv64/"* \
    /usr/local/bin/

containerd_archive=containerd-${containerd_version}-linux-riscv64.tar.gz
download_and_check \
    "https://github.com/containerd/containerd/releases/download/v${containerd_version}/${containerd_archive}" \
    "${containerd_archive}" \
    18e3ec3d2b79cbc5fdf8df04e1e25d0e64949958e8f213dd80692c9f38eba492
tar -xzf "${work_dir}/${containerd_archive}" -C /usr/local

crictl_archive=crictl-${crictl_version}-linux-riscv64.tar.gz
download_and_check \
    "https://github.com/kubernetes-sigs/cri-tools/releases/download/${crictl_version}/${crictl_archive}" \
    "${crictl_archive}" \
    28c1dd55f507b053482fbc001e971dd00fcd2b6758bd1a7222a3db494478a2bb
tar -xzf "${work_dir}/${crictl_archive}" -C /usr/local/bin crictl

cni_archive=cni-plugins-linux-riscv64-${cni_version}.tgz
download_and_check \
    "https://github.com/containernetworking/plugins/releases/download/${cni_version}/${cni_archive}" \
    "${cni_archive}" \
    8ae4f284805187106596678959807df8c61a2f7bd12d323b45c5f0c1f51d41cd
install -d -m 0755 /opt/cni/bin
tar -xzf "${work_dir}/${cni_archive}" -C /opt/cni/bin

for command_name in \
    containerd containerd-shim-runc-v2 crictl ctr etcd etcdctl kubeadm \
    kubelet kubectl kube-apiserver kube-controller-manager kube-scheduler \
    kube-proxy runc; do
    command -v "${command_name}" >/dev/null
done

kubelet --version | grep -F "Kubernetes ${kubernetes_version}"
containerd --version | grep -F "v${containerd_version}"
ETCD_UNSUPPORTED_ARCH=riscv64 etcd --version \
    | grep -F "etcd Version: ${etcd_version#v}"
crictl --version | grep -F "crictl version ${crictl_version}"
echo OPENRUYI_NATIVE_K8S_PACKAGES_OK
