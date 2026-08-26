# Cloudpods RISC-V 原生 Kubernetes 部署手册（openRuyi）

文档版本：1.0  
发布日期：2026-08-26  
适用系统：openRuyi Creek 2026.07 `riscv64`  
部署方式：先安装原生 Kubernetes，再安装 Cloudpods；不使用 K3s、ocboot

## 1. 交付版本

| 组件 | 固定版本 |
| --- | --- |
| openRuyi | Creek 2026.07，内核 7.1.4-545.1.or |
| Kubernetes | v1.36.4 |
| containerd | v2.3.4 |
| etcd | v3.7.1 |
| cri-tools | v1.36.0 |
| CNI plugins | v1.9.1 |
| QEMU | v11.1.0，RISC-V 原生构建，支持 KVM/RVA23 |
| Cloudpods | v4.0.3-riscv64.7 |
| Dashboard | v4.0.3-riscv64-ui2 |
| Cloudpods Operator | v4.0.3-riscv64.4 |

交付源码固定使用标签 `openruyi-native-k8s-v4.0.3-riscv64.2`。脚本下载的二进制均校验 SHA-256。

## 2. 部署规划

示例使用一个主节点和一个计算节点。主节点同时作为第一台计算宿主。

| 项目 | 主节点示例 | 计算节点示例 |
| --- | --- | --- |
| hostname | `cloudpods-openruyi-master01` | `cloudpods-openruyi-compute01` |
| 管理 IP | `192.168.50.10` | `192.168.50.11` |
| 节点 PodCIDR | `10.244.0.0/24` | `10.244.1.0/24` |
| 管理网卡 | `eth0` | `eth0` |

全局参数：PodCIDR `10.244.0.0/16`，ServiceCIDR `10.96.0.0/12`，Cloudpods Host 管理池示例为 `192.168.50.10-192.168.50.29/24`。

部署前必须确认：

- 每台服务器建议至少 16 核、32 GiB 内存、200 GiB 可用磁盘；存在 `/dev/kvm` 和 `/dev/net/tun`。
- hostname、管理 IP 固定且唯一，所有节点二层互通，DNS、时间同步和互联网访问正常。
- PodCIDR、ServiceCIDR 不与现场网络重叠。
- Host 管理池覆盖全部宿主 IP，并从现场 DHCP 池排除。
- 虚拟机地址池另行规划；如使用现场 DHCP，不要创建重叠的 Cloudpods 静态地址池。
- 交换机端口允许虚拟机使用多个 MAC 地址。

节点间放通 TCP 6443、2379-2380、10250、10256、8885、32241-32242，UDP 6081；客户端到主节点放通 TCP 80、443。

## 3. 所有节点预检查

以 root 执行：

```bash
set -euo pipefail
test "$(uname -m)" = riscv64
grep -Eq '^ID="?openruyi"?$' /etc/os-release
grep -Eq '^VERSION_ID="?Creek"?$' /etc/os-release
test -c /dev/kvm
test -c /dev/net/tun
! systemctl is-active --quiet k3s
! test -s /etc/kubernetes/kubelet.conf
hostnamectl hostname
ip -brief address
df -h /
```

任一检查失败时先修复，不要继续安装。

## 4. 安装主节点

### 4.1 获取交付文件

```bash
dnf install -y git openssl
cd /root
git clone --depth 1 --branch openruyi-native-k8s-v4.0.3-riscv64.2 \
  https://github.com/yinjiayi/cloudpods-riscv64-releases.git
cd /root/cloudpods-riscv64-releases
cp native-k8s-openruyi/install.env.example \
  /etc/cloudpods-openruyi-native-k8s.env
chmod 600 /etc/cloudpods-openruyi-native-k8s.env
```

编辑 `/etc/cloudpods-openruyi-native-k8s.env`。主节点示例：

```bash
NODE_NAME=cloudpods-openruyi-master01
NODE_IP=192.168.50.10
POD_CIDR=10.244.0.0/16
POD_NODE_CIDR=10.244.0.0/24
SERVICE_CIDR=10.96.0.0/12
CLUSTER_DNS=10.96.0.10
CLUSTER_NAME=cloudpods-openruyi
GHCR_NAMESPACE=ghcr.io/yinjiayi
ARTIFACT_BASE_URL=https://github.com/yinjiayi/cloudpods-riscv64-releases/releases/download/openruyi-native-k8s-v4.0.3-riscv64.1
CONTROL_PLANE_IP=192.168.50.10
HOST_NETWORK_INTERFACE=eth0
HOST_NETWORK_NAME=cloudpods-host-mgmt
HOST_NETWORK_START=192.168.50.10
HOST_NETWORK_END=192.168.50.29
HOST_NETWORK_PREFIX=24
HOST_NETWORK_GATEWAY=192.168.50.1
HOST_DISK_PATH=/opt/cloud/workspace/disks
MYSQL_PASSWORD=替换为openssl_rand_hex_24生成的值
ADMIN_PASSWORD=替换为openssl_rand_hex_24生成的值
LAB_TCG_FALLBACK=false
```

密码仅允许字母、数字、点、下划线和连字符，长度为 16-128。可分别执行 `openssl rand -hex 24` 生成。确认管理网卡承载管理 IP：

```bash
source /etc/cloudpods-openruyi-native-k8s.env
ip -4 address show dev "$HOST_NETWORK_INTERFACE" | grep -F "$NODE_IP/"
```

### 4.2 安装并验收 Kubernetes

```bash
cd /root/cloudpods-riscv64-releases/native-k8s-openruyi
chmod +x ./*.sh qemu-rva23-openruyi-lab/*.sh
./00-install-packages.sh
./10-runtime.sh
./20-control-plane.sh

kubectl get --raw=/readyz
kubectl get nodes -o wide
kubectl -n kube-system get pods -o wide
systemctl is-active etcd kube-apiserver kube-controller-manager \
  kube-scheduler kubelet kube-proxy containerd
```

必须满足：API 输出 `ok`，主节点为 `Ready/riscv64`，两个 CoreDNS Pod 为 `Running`，`kube-proxy` 日志显示使用 nftables。openRuyi 当前内核缺少旧 iptables REDIRECT 兼容项，脚本仅对该项使用 kubeadm `SystemVerification` 例外，并使用持久化原生 nftables 规则替代；不要改回 iptables 模式。

### 4.3 安装 Cloudpods

```bash
./30-cloudpods-host.sh
./35-pull-cloudpods-images.sh
./40-install-cloudpods.sh
```

`30-cloudpods-host.sh` 会安装 QEMU 11.1.0 并执行真实 `/dev/kvm` 内核启动测试；`40-install-cloudpods.sh` 会部署控制面、创建 Host 管理网络并启用首台 Host。启用 Host 时，管理 IP 会从物理网卡迁移到 `br0`，SSH 可能短暂断开；等待约一分钟后仍用原 IP 登录。

脚本最终必须输出 `CLOUDPODS_HOST_PREREQUISITES_OK`、`CLOUDPODS_IMAGES_OK` 和 `CLOUDPODS_INSTALL_OK`。

## 5. 添加计算节点

### 5.1 准备节点

在计算节点执行第 3 节预检查，并按第 4.1 节获取同一交付标签。配置文件中至少修改：

```bash
NODE_NAME=cloudpods-openruyi-compute01
NODE_IP=192.168.50.11
POD_NODE_CIDR=10.244.1.0/24
CONTROL_PLANE_IP=192.168.50.10
HOST_NETWORK_INTERFACE=eth0
```

其余集群、Host 管理池和密码参数与主节点一致，然后执行：

```bash
cd /root/cloudpods-riscv64-releases/native-k8s-openruyi
chmod +x ./*.sh
./00-install-packages.sh
./10-runtime.sh
```

### 5.2 加入 Kubernetes

在主节点执行：

```bash
JOIN_COMMAND=$(kubeadm token create --ttl 2h --print-join-command)
JOIN_TOKEN=$(awk '{for(i=1;i<=NF;i++)if($i=="--token")print $(i+1)}' <<<"$JOIN_COMMAND")
JOIN_HASH=$(awk '{for(i=1;i<=NF;i++)if($i=="--discovery-token-ca-cert-hash")print $(i+1)}' <<<"$JOIN_COMMAND")
printf './25-worker-join.sh %q %q\n' "$JOIN_TOKEN" "$JOIN_HASH"
scp /etc/kubernetes/kube-proxy.conf \
  root@192.168.50.11:/etc/kubernetes/kube-proxy.conf
```

在计算节点执行主节点刚打印的完整命令，参数不要照抄示例：

```bash
cd /root/cloudpods-riscv64-releases/native-k8s-openruyi
./25-worker-join.sh 实际TOKEN sha256:实际CA哈希
```

脚本必须输出 `OPENRUYI_NATIVE_K8S_WORKER_OK`。在主节点执行 `kubectl get nodes -o wide`，确认两个节点均为 `Ready/riscv64`。

### 5.3 配置 Pod 路由和计算服务

主节点执行：

```bash
./50-pod-routes.sh 10.244.1.0/24=192.168.50.11
```

计算节点执行：

```bash
cd /root/cloudpods-riscv64-releases/native-k8s-openruyi
./50-pod-routes.sh 10.244.0.0/24=192.168.50.10
./30-cloudpods-host.sh
./35-pull-cloudpods-images.sh
```

主节点启用计算 Host：

```bash
kubectl label node cloudpods-openruyi-compute01 \
  onecloud.yunion.io/host=enable --overwrite
kubectl -n onecloud get pods -o wide --watch
```

计算节点 IP 迁移到 `br0` 后，在计算节点执行：

```bash
systemctl restart cloudpods-native-k8s-routes.service
ip route show 10.244.0.0/24
```

三台及以上节点时，每台节点都要配置到其余所有节点 Pod `/24` 的路由。

## 6. 最终验收

在主节点执行：

```bash
cd /root/cloudpods-riscv64-releases/native-k8s-openruyi
./60-verify.sh
```

必须输出 `CLOUDPODS_NATIVE_K8S_ACCEPTANCE_OK`。浏览器访问 `https://主节点IP/`，账号 `admin`，密码为配置文件中的 `ADMIN_PASSWORD`。

再完成一台真实 RISC-V 虚机验收：

1. 上传 openRuyi Creek 2026.07 RISC-V QCOW2 镜像，架构选择 `riscv64`。
2. 创建 2 vCPU、4 GiB 内存、至少 45 GiB 本地系统盘的临时虚机。
3. 网络使用独立静态地址池，或使用现场已确认可分配的 DHCP 网络。
4. 确认虚机状态为运行、UEFI 控制台出现 openRuyi 登录提示。
5. 确认虚机获得地址，管理网能够 ping 和 SSH 到该地址。
6. 重启两台宿主机，确认 Kubernetes、Cloudpods、两台 Host 和虚机能够恢复。

只有上述项目全部通过，才视为交付完成。

## 7. 故障信息收集

失败时不要清空数据库或重装，先收集：

```bash
systemctl status etcd kube-apiserver kube-controller-manager \
  kube-scheduler kubelet kube-proxy containerd cloudpods-executor --no-pager
journalctl -u kubelet -u kube-proxy -u containerd \
  -u cloudpods-executor -n 300 --no-pager
kubectl get nodes -o wide
kubectl -n kube-system get pods -o wide
kubectl -n onecloud get pods -o wide
kubectl -n onecloud get events --sort-by=.lastTimestamp
ovs-vsctl show
ip -brief address
nft list ruleset
```

将失败脚本最后 200 行输出与上述结果一并提供给技术支持。
