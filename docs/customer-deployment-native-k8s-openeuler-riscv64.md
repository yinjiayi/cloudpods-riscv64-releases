# Cloudpods RISC-V 原生 Kubernetes 部署手册

文档版本：1.0
发布日期：2026-08-21
适用系统：openEuler 24.03 LTS SP3 `riscv64`
部署方式：原生 Kubernetes + Cloudpods Operator

本手册用于在全新的 RISC-V 服务器上先安装原生 Kubernetes，再安装 Cloudpods，并可继续加入 RISC-V 计算节点。本方案不安装 K3s，也不使用 ocboot。

## 1. 交付版本

| 组件 | 版本 |
| --- | --- |
| Kubernetes | openEuler `1.29.1-14.oe2403sp3` |
| etcd | openEuler `3.4.14-18.oe2403sp3` |
| containerd | openEuler `1.6.22` 系列 |
| Cloudpods | `v4.0.3-riscv64.6` |
| Dashboard | `v4.0.3-riscv64-ui2` |
| Cloudpods Operator | `v4.0.3-riscv64.3` |
| QEMU | `10.0.7-6.oe2403sp3` |

交付仓库固定使用标签 `native-k8s-v4.0.3-riscv64.1`。

## 2. 部署规划

本手册默认首台服务器同时承担 Kubernetes 主节点、Cloudpods 控制节点和计算节点角色。

| 项目 | 示例 | 要求 |
| --- | --- | --- |
| 主节点 hostname | `cloudpods-rv-master01` | 小写、集群内唯一 |
| 主节点管理 IP | `192.168.50.10` | 固定 IP 或 DHCP 保留地址 |
| 首台计算节点 IP | `192.168.50.11` | 固定 IP 或 DHCP 保留地址 |
| 宿主管理网卡 | `eth0` | 当前承载管理 IP 的物理网卡 |
| Pod 总网段 | `10.244.0.0/16` | 不得与现场网段重叠 |
| 主节点 Pod 网段 | `10.244.0.0/24` | 每个节点独占一个 `/24` |
| 首台计算节点 Pod 网段 | `10.244.1.0/24` | 后续节点依次递增 |
| Service 网段 | `10.96.0.0/12` | 不得与现场网段重叠 |
| Host 管理地址池 | `192.168.50.10-192.168.50.29` | 必须覆盖全部宿主 IP，并从 DHCP 池排除 |
| 虚拟机磁盘目录 | `/opt/cloud/workspace/disks` | 建议至少 200 GiB 可用空间 |

Host 管理地址池只用于 Cloudpods 识别宿主网络。虚拟机地址池应另行规划，不得与 DHCP 或 Host 管理地址池重叠。

## 3. 环境要求

每台服务器建议不少于 16 核 CPU、32 GiB 内存和 200 GiB 可用磁盘，并满足：

- 操作系统必须为 openEuler 24.03 LTS SP3 `riscv64`。
- 必须存在 `/dev/kvm` 和 `/dev/net/tun`。
- hostname 和管理 IP 固定且唯一，DNS、时间同步正常。
- 服务器未加入其他 Kubernetes/K3s 集群。
- 所有节点能够访问 openEuler 软件源、`ghcr.io` 和 `yinjiayi.github.io`。
- 节点管理网二层互通；交换机端口允许虚拟机的多个 MAC 地址。
- 本交付的 Pod 网络使用 `bridge + host-local`，多节点必须执行第 8 节的静态 Pod 路由步骤。

节点间至少放通：

| 方向 | 协议/端口 | 用途 |
| --- | --- | --- |
| 所有节点到主节点 | TCP 6443 | Kubernetes API |
| 主节点本机 | TCP 2379-2380 | etcd |
| 节点之间 | TCP 10250、10256 | Kubelet、kube-proxy |
| 计算节点之间 | UDP 6081 | Cloudpods OVN Geneve |
| 计算节点到集群节点 | TCP 32241-32242 | OVN North/South DB |
| 管理网到主节点 | TCP 80、443 | Cloudpods Web |
| 管理端到计算节点 | TCP 8885 | Cloudpods Host API |

## 4. 所有节点预检查

在每台服务器以 root 执行：

```bash
set -euo pipefail
test "$(id -u)" -eq 0
test "$(uname -m)" = riscv64
grep -Fq '24.03 (LTS-SP3)' /etc/os-release
test -c /dev/kvm
test -c /dev/net/tun
! systemctl is-active --quiet k3s
! test -s /etc/kubernetes/kubelet.conf
hostnamectl hostname
ip -brief address
df -h /
```

任一检查失败时停止部署，先处理系统版本、KVM、网络、磁盘或已有集群冲突。

## 5. 获取交付文件并配置主节点

```bash
dnf install -y git
cd /root
git clone --depth 1 --branch native-k8s-v4.0.3-riscv64.1 \
  https://github.com/yinjiayi/cloudpods-riscv64-releases.git
cd /root/cloudpods-riscv64-releases
cp native-k8s/install.env.example /etc/cloudpods-native-k8s.env
chmod 600 /etc/cloudpods-native-k8s.env
vi /etc/cloudpods-native-k8s.env
```

按现场规划修改全部变量，主节点示例：

```bash
NODE_NAME=cloudpods-rv-master01
NODE_IP=192.168.50.10
POD_CIDR=10.244.0.0/16
POD_NODE_CIDR=10.244.0.0/24
SERVICE_CIDR=10.96.0.0/12
CLUSTER_DNS=10.96.0.10
CLUSTER_NAME=cloudpods-riscv
GHCR_NAMESPACE=ghcr.io/yinjiayi
CONTROL_PLANE_IP=192.168.50.10
HOST_NETWORK_INTERFACE=eth0
HOST_NETWORK_NAME=cloudpods-host-mgmt
HOST_NETWORK_START=192.168.50.10
HOST_NETWORK_END=192.168.50.29
HOST_NETWORK_PREFIX=24
HOST_NETWORK_GATEWAY=192.168.50.1
HOST_DISK_PATH=/opt/cloud/workspace/disks
MYSQL_PASSWORD=替换为至少16位随机字符串
ADMIN_PASSWORD=替换为至少16位随机字符串
```

两个密码只允许字母、数字、点、下划线和连字符，不要保留示例值。确认 `HOST_NETWORK_INTERFACE` 当前承载 `NODE_IP`：

```bash
source /etc/cloudpods-native-k8s.env
ip -4 address show dev "$HOST_NETWORK_INTERFACE" | grep -F "$NODE_IP/"
```

## 6. 第一步：安装并验收原生 Kubernetes

在主节点执行：

```bash
cd /root/cloudpods-riscv64-releases/native-k8s
chmod +x ./*.sh qemu-rva23-lab/*.sh
./00-install-packages.sh
./10-runtime.sh
./20-control-plane.sh
```

脚本会使用 openEuler 原生 Kubernetes RPM，生成 kubeadm PKI 和配置，并以 systemd 服务运行 etcd、API Server、Controller Manager、Scheduler、Kubelet 和 kube-proxy。脚本同时关闭 swap；系统装有 SELinux policy 时将其固定为 permissive，官方最小镜像原本为 Disabled 时保持 Disabled。

Kubernetes 验收：

```bash
kubectl version
kubectl get --raw=/readyz
kubectl get nodes -o wide
kubectl -n kube-system get pods -o wide
systemctl is-active etcd kube-apiserver kube-controller-manager \
  kube-scheduler kubelet kube-proxy containerd
```

必须满足：API 返回 `ok`，主节点为 `Ready`，架构为 `riscv64`，两个 CoreDNS Pod 为 `Running`。未满足时不要继续安装 Cloudpods。

## 7. 第二步：安装并验收 Cloudpods

继续在主节点执行：

```bash
cd /root/cloudpods-riscv64-releases/native-k8s
./30-cloudpods-host.sh
./35-pull-cloudpods-images.sh
./40-install-cloudpods.sh
```

安装脚本会按以下顺序完成初始化：

1. 安装 QEMU 10.0.7、Open vSwitch、Cloudpods executor 和固件 RPM，并持久维护 `brlocal` 链路本地地址；
2. 使用真实 `/dev/kvm` 启动一次 RISC-V 内核冒烟测试；
3. 拉取并校验 RISC-V Cloudpods 容器镜像；
4. 部署 Cloudpods Operator 和控制面；
5. 创建覆盖宿主管理 IP 的 baremetal 管理子网；
6. 最后启用 Host 角色，将管理 IP 从物理网卡迁移到 OVS `br0`；
7. 在主节点 TCP 80/443 提供 Web 入口。

管理 IP 迁移到 `br0` 时 SSH 可能短暂断开，等待约 1 分钟后仍使用原 IP 重连。镜像拉取和数据库初始化可能需要较长时间，不要中断仍有输出的命令。

完整验收：

```bash
cd /root/cloudpods-riscv64-releases/native-k8s
./60-verify.sh
```

安装脚本应先输出 `CLOUDPODS_INSTALL_OK`。随后运行验收脚本；多节点时脚本会在每个节点各启动一个临时 Pod，完成 Pod IP 全互通测试并自动删除，最后必须输出 `CLOUDPODS_NATIVE_K8S_ACCEPTANCE_OK`。浏览器访问 `https://主节点IP/`，用户名为 `admin`，密码为 `/etc/cloudpods-native-k8s.env` 中设置的 `ADMIN_PASSWORD`。

## 8. 添加 RISC-V 计算节点

以下步骤对每台新增计算节点逐台执行。示例使用 `192.168.50.11` 和 `10.244.1.0/24`。

### 8.1 准备计算节点

在计算节点设置唯一 hostname，获取同一交付版本并创建配置：

```bash
hostnamectl set-hostname cloudpods-rv-compute01
dnf install -y git
cd /root
git clone --depth 1 --branch native-k8s-v4.0.3-riscv64.1 \
  https://github.com/yinjiayi/cloudpods-riscv64-releases.git
cd /root/cloudpods-riscv64-releases
cp native-k8s/install.env.example /etc/cloudpods-native-k8s.env
chmod 600 /etc/cloudpods-native-k8s.env
vi /etc/cloudpods-native-k8s.env
```

计算节点至少修改：

```bash
NODE_NAME=cloudpods-rv-compute01
NODE_IP=192.168.50.11
POD_NODE_CIDR=10.244.1.0/24
CONTROL_PLANE_IP=192.168.50.10
HOST_NETWORK_INTERFACE=eth0
```

其他集群、Host 管理子网和密码变量与主节点保持一致。然后执行：

```bash
cd /root/cloudpods-riscv64-releases/native-k8s
chmod +x ./*.sh
./00-install-packages.sh
./10-runtime.sh
```

### 8.2 加入 Kubernetes

在主节点生成两小时有效的加入参数：

```bash
JOIN_COMMAND=$(kubeadm token create --ttl 2h --print-join-command)
JOIN_TOKEN=$(awk '{for (i=1;i<=NF;i++) if ($i=="--token") print $(i+1)}' <<<"$JOIN_COMMAND")
JOIN_HASH=$(awk '{for (i=1;i<=NF;i++) if ($i=="--discovery-token-ca-cert-hash") print $(i+1)}' <<<"$JOIN_COMMAND")
printf './25-worker-join.sh %q %q\n' "$JOIN_TOKEN" "$JOIN_HASH"
scp /etc/kubernetes/kube-proxy.conf root@192.168.50.11:/etc/kubernetes/kube-proxy.conf
```

在计算节点执行主节点刚打印的完整命令。以下值仅为格式示例，不得照抄：

```bash
cd /root/cloudpods-riscv64-releases/native-k8s
./25-worker-join.sh abcdef.0123456789abcdef sha256:替换为主节点打印的64位哈希
```

脚本必须输出 `NATIVE_K8S_WORKER_OK`。在主节点确认：

```bash
kubectl get node cloudpods-rv-compute01 \
  -o custom-columns=NAME:.metadata.name,READY:.status.conditions[-1].status,IP:.status.addresses[0].address,POD_CIDR:.spec.podCIDR
```

`POD_CIDR` 必须与计算节点配置的 `POD_NODE_CIDR` 一致。

### 8.3 配置节点间 Pod 路由

两节点示例：

在主节点执行：

```bash
cd /root/cloudpods-riscv64-releases/native-k8s
./50-pod-routes.sh 10.244.1.0/24=192.168.50.11
```

在计算节点执行：

```bash
cd /root/cloudpods-riscv64-releases/native-k8s
./50-pod-routes.sh 10.244.0.0/24=192.168.50.10
```

有三台及以上节点时，每台节点都必须配置到其余每个节点 Pod `/24` 的路由。

### 8.4 安装计算服务并启用 Host

在计算节点执行：

```bash
cd /root/cloudpods-riscv64-releases/native-k8s
./30-cloudpods-host.sh
./35-pull-cloudpods-images.sh
```

在主节点启用计算节点：

```bash
kubectl label node cloudpods-rv-compute01 \
  onecloud.yunion.io/host=enable --overwrite
kubectl -n onecloud get pods -o wide --watch
```

等待该节点的 Host、SDN、OVS、Host Image 和 Host Deployer Pod 就绪。计算节点管理 IP 迁移到 `br0` 后仍使用原 IP 登录。

管理 IP 完成迁移后，在计算节点重新应用一次 Pod 路由，使路由出口从物理网卡更新到 `br0`：

```bash
systemctl restart cloudpods-native-k8s-routes.service
ip route show 10.244.0.0/24
```

再退出 `--watch`，在主节点执行 `./60-verify.sh`，并确认新增 Host 为 `running/online/enabled`。

## 9. 首台 RISC-V 虚拟机验收

1. 在 `网络/二层网络` 中另建一个 `guest` 类型虚拟机子网，地址池必须由网络管理员从现场 DHCP 中排除；如直接使用现场 DHCP，不要再创建重叠的静态地址池。
2. 上传 openEuler RISC-V QCOW2 镜像，架构选择 `riscv64`。
3. 创建 2 vCPU、4 GiB 内存、45 GiB 系统盘的临时虚拟机；系统盘不得小于镜像显示的最小磁盘容量。
4. 确认虚拟机状态为运行中，控制台出现 openEuler 启动画面。
5. 确认虚拟机获得预期 IP，并从宿主管理网完成 ping 和 SSH。

只有 Kubernetes、Cloudpods Host、Web/API 和真实 RISC-V 虚拟机均通过，才视为部署完成。

## 10. 故障信息收集

部署失败时不要清空数据库或重装，先收集：

```bash
systemctl status etcd kube-apiserver kube-controller-manager \
  kube-scheduler kubelet kube-proxy containerd cloudpods-executor --no-pager
journalctl -u kubelet -u containerd -u cloudpods-executor -n 300 --no-pager
kubectl get nodes -o wide
kubectl -n kube-system get pods -o wide
kubectl -n onecloud get pods -o wide
kubectl -n onecloud get events --sort-by=.lastTimestamp
ovs-vsctl show
ip -brief address
```

将失败脚本最后 200 行输出和上述结果一并提供给技术支持。
