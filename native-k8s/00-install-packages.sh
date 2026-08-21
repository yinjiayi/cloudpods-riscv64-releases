#!/usr/bin/env bash

set -euo pipefail

if [[ ${EUID} -ne 0 ]]; then
    echo "Run as root" >&2
    exit 1
fi

[[ $(uname -m) == riscv64 ]]
grep -q '24.03' /etc/openEuler-release
grep -q 'LTS-SP3' /etc/openEuler-release

dnf install -y \
    chrony \
    conntrack-tools \
    containerd \
    containernetworking-plugins \
    cri-tools-1.29.0-3.oe2403sp3 \
    curl \
    ebtables \
    ethtool \
    iproute \
    iptables \
    iputils \
    jq \
    kubernetes-client-1.29.1-14.oe2403sp3 \
    kubernetes-kubeadm-1.29.1-14.oe2403sp3 \
    kubernetes-kubelet-1.29.1-14.oe2403sp3 \
    kubernetes-master-1.29.1-14.oe2403sp3 \
    kubernetes-node-1.29.1-14.oe2403sp3 \
    etcd-3.4.14-18.oe2403sp3 \
    openssl \
    procps-ng \
    psmisc \
    python3 \
    rsync \
    socat \
    tar \
    unzip \
    wget \
    xz

for command_name in \
    containerd crictl ctr ebtables kubeadm kubelet kubectl kube-apiserver \
    kube-controller-manager kube-scheduler kube-proxy etcd; do
    command -v "${command_name}" >/dev/null
done

rpm -q \
    kubernetes-kubeadm-1.29.1-14.oe2403sp3 \
    kubernetes-kubelet-1.29.1-14.oe2403sp3 \
    kubernetes-master-1.29.1-14.oe2403sp3 \
    kubernetes-node-1.29.1-14.oe2403sp3 \
    cri-tools-1.29.0-3.oe2403sp3 \
    etcd-3.4.14-18.oe2403sp3 \
    containerd

echo NATIVE_K8S_PACKAGES_OK
