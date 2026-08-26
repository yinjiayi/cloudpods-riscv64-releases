#!/usr/bin/env bash

set -euo pipefail

if [[ ${EUID} -ne 0 ]]; then
    echo "Run as root" >&2
    exit 1
fi

images=(
    ghcr.io/yinjiayi/cloudpods:v4.0.3-riscv64.6
    ghcr.io/yinjiayi/onecloud-operator:v4.0.3-riscv64.3
    ghcr.io/yinjiayi/cloudpods-web:v4.0.3-riscv64-ui2
    ghcr.io/yinjiayi/etcd:3.5.24-riscv64.1
    ghcr.io/yinjiayi/host-image:v1.0.8-riscv64.1
    ghcr.io/yinjiayi/host-health:v0.0.4-riscv64.1
    ghcr.io/yinjiayi/guacd:1.6.0-riscv64.1
    ghcr.io/yinjiayi/openvswitch:2.12.4-20260415-riscv64.1
    ghcr.io/yinjiayi/busybox:1.35.0-riscv64.1
    ghcr.io/yinjiayi/victoria-metrics:v1.129.1-1-riscv64.1
)

for image in "${images[@]}"; do
    ctr --namespace k8s.io images pull --platform linux/riscv64 "${image}"
done

tag_image() {
    ctr --namespace k8s.io images tag --force "$1" "$2" >/dev/null
}

tag_image ghcr.io/yinjiayi/cloudpods:v4.0.3-riscv64.6 \
    localhost/cloudpods/cloudpods:v4.0.3-riscv64.6
tag_image ghcr.io/yinjiayi/onecloud-operator:v4.0.3-riscv64.3 \
    localhost/cloudpods/onecloud-operator:v4.0.3-riscv64.3
tag_image ghcr.io/yinjiayi/cloudpods-web:v4.0.3-riscv64-ui2 \
    localhost/cloudpods/web:v4.0.3-riscv64-ui2
tag_image ghcr.io/yinjiayi/etcd:3.5.24-riscv64.1 \
    localhost/cloudpods/etcd:3.5.24
tag_image ghcr.io/yinjiayi/busybox:1.35.0-riscv64.1 \
    localhost/cloudpods/busybox:1.37.0-glibc
tag_image ghcr.io/yinjiayi/guacd:1.6.0-riscv64.1 \
    localhost/cloudpods/guacd:1.6.0
tag_image ghcr.io/yinjiayi/host-health:v0.0.4-riscv64.1 \
    localhost/cloudpods/host-health:v0.0.4
tag_image ghcr.io/yinjiayi/host-image:v1.0.8-riscv64.1 \
    localhost/cloudpods/host-image:v1.0.8
tag_image ghcr.io/yinjiayi/openvswitch:2.12.4-20260415-riscv64.1 \
    localhost/cloudpods/openvswitch:2.12.4-20260415
tag_image ghcr.io/yinjiayi/victoria-metrics:v1.129.1-1-riscv64.1 \
    localhost/cloudpods/victoria-metrics:v1.129.1-1

tag_image ghcr.io/yinjiayi/host-image:v1.0.8-riscv64.1 \
    'registry.cn-beijing.aliyuncs.com/yunionio/host-image:v1.0.8@sha256:378a587207a688e3addc0768aebaaf685e6c2aa244206453119f20b958e7e0eb'
tag_image ghcr.io/yinjiayi/host-health:v0.0.4-riscv64.1 \
    'registry.cn-beijing.aliyuncs.com/yunionio/host-health:v0.0.4@sha256:02831fd0af1fdd0ba313af1227fc841656a090c915d68b66b9d24e49a556923f'
tag_image ghcr.io/yinjiayi/guacd:1.6.0-riscv64.1 \
    'registry.cn-beijing.aliyuncs.com/yunionio/guacd:1.6.0@sha256:e38e07aabe5db7949b76c2990d98e7773fef4c304fdcdaa1fea8b5a0967376e6'
tag_image ghcr.io/yinjiayi/openvswitch:2.12.4-20260415-riscv64.1 \
    'registry.cn-beijing.aliyuncs.com/yunionio/openvswitch:2.12.4-20260415@sha256:8af6807aafffc32674afc28cd3ab96108d871520ab28c44dd72c80e850586d46'
tag_image ghcr.io/yinjiayi/busybox:1.35.0-riscv64.1 \
    'registry.cn-beijing.aliyuncs.com/yunionio/busybox:1.35.0@sha256:98ad9d1a2be345201bb0709b0d38655eb1b370145c7d94ca1fe9c421f76e245a'
tag_image ghcr.io/yinjiayi/victoria-metrics:v1.129.1-1-riscv64.1 \
    'registry.cn-beijing.aliyuncs.com/yunionio/victoria-metrics:v1.129.1-1@sha256:dcc60e6b67a701db2e09350f357dbdf32ede557aaddf41818883ac412a19c01f'

for image in \
    localhost/cloudpods/cloudpods:v4.0.3-riscv64.6 \
    localhost/cloudpods/onecloud-operator:v4.0.3-riscv64.3 \
    localhost/cloudpods/web:v4.0.3-riscv64-ui2 \
    localhost/cloudpods/etcd:3.5.24; do
    ctr --namespace k8s.io images list -q | grep -Fx "${image}"
done

echo CLOUDPODS_IMAGES_OK
