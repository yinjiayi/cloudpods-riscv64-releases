# Cloudpods RISC-V 客户部署手册（openRuyi）

文档版本：2.0

发布日期：2026-09-02

适用系统：openRuyi Creek 2026.08 `riscv64`

部署方式：openRuyi 原生 Kubernetes + Cloudpods，不使用 K3s、ocboot

## 1. 交付版本

安装脚本优先使用 openRuyi 软件仓库；仅在仓库没有对应软件包时，下载并校验官方 RISC-V 发行物。

| 组件 | 本次验证版本 | 来源 |
| --- | --- | --- |
| openRuyi | Creek 2026.08，内核 7.2.0-3.1_551.1.or | openRuyi |
| Kubernetes | v1.35.5 | openRuyi RPM |
| containerd | v2.3.3 | openRuyi RPM |
| etcd | v3.6.6 | openRuyi RPM |
| cri-tools | v1.36.0 | 官方发行物 |
| CNI plugins | v1.9.1 | 官方发行物 |
| QEMU | v11.0.1 | openRuyi RPM |
| Cloudpods | v4.0.3-riscv64.9 | GHCR |
| Dashboard | v4.0.3-riscv64-ui2 | GHCR |
| Cloudpods Operator | v4.0.3-riscv64.4 | GHCR |

交付源码标签：`openruyi-native-k8s-v4.0.3-riscv64.3`。

## 2. 部署规划

以下三节点地址是已经验证的现场示例。其他环境部署时，替换为客户实际地址、网卡、网关、DNS 和 NTP。

| 角色 | hostname | 管理 IP | PodCIDR |
| --- | --- | --- | --- |
| 主节点/计算节点 | `cloudpods-openruyi-master01` | `10.213.6.187` | `10.244.0.0/24` |
| 计算节点 1 | `cloudpods-openruyi-compute01` | `10.213.6.183` | `10.244.1.0/24` |
| 计算节点 2 | `cloudpods-openruyi-compute02` | `10.213.6.188` | `10.244.2.0/24` |

集群 PodCIDR 为 `10.244.0.0/16`，ServiceCIDR 为 `10.96.0.0/12`。现场示例使用：

- Host 管理池：`10.213.6.180-10.213.6.199/20`，网关 `10.213.0.1`；
- 虚机地址池：`10.213.15.230-10.213.15.249/20`，网关 `10.213.0.1`；
- NTP：`10.213.0.1`；DNS：`10.200.0.5 10.200.0.4`。

地址池必须从 DHCP 可分配范围排除。交换机端口必须允许多个虚机 MAC 地址。节点间放通 TCP 6443、2379-2380、10250、10256、8885、32241-32242 和 UDP 6081；客户端到主节点放通 TCP 80、443。

## 3. 所有节点预检查

以 root 执行：

```bash
set -euo pipefail
test "$(uname -m)" = riscv64
grep -Eq '^ID="?openruyi"?$' /etc/os-release
grep -Eq '^VERSION_ID="?Creek"?$' /etc/os-release
modprobe kvm
modprobe tun
test -c /dev/kvm
test -c /dev/net/tun
! systemctl is-active --quiet k3s
! test -s /etc/kubernetes/kubelet.conf
hostnamectl hostname
ip -brief address
df -h /
```

建议每台服务器不少于 16 核、32 GiB 内存、200 GiB 可用磁盘。PodCIDR、ServiceCIDR 和现场网络不得重叠。任一检查失败时先修复，不要继续安装。

## 4. 安装主节点

获取交付文件并生成配置：

```bash
dnf install -y git openssl
cd /root
git clone --depth 1 --branch openruyi-native-k8s-v4.0.3-riscv64.3 \
  https://github.com/yinjiayi/cloudpods-riscv64-releases.git
cd cloudpods-riscv64-releases
cp native-k8s-openruyi/install.env.example \
  /etc/cloudpods-openruyi-native-k8s.env
chmod 600 /etc/cloudpods-openruyi-native-k8s.env
```

编辑 `/etc/cloudpods-openruyi-native-k8s.env`。现场主节点配置如下，密码值由客户自行生成，不得照抄：

```bash
NODE_NAME=cloudpods-openruyi-master01
NODE_IP=10.213.6.187
POD_CIDR=10.244.0.0/16
POD_NODE_CIDR=10.244.0.0/24
SERVICE_CIDR=10.96.0.0/12
CLUSTER_DNS=10.96.0.10
CLUSTER_NAME=cloudpods-openruyi
GHCR_NAMESPACE=ghcr.io/yinjiayi
NTP_POOLS=
NTP_SERVERS=10.213.0.1
DNS_SERVERS="10.200.0.5 10.200.0.4"
ARTIFACT_BASE_URL=https://github.com/yinjiayi/cloudpods-riscv64-releases/releases/download/openruyi-native-k8s-v4.0.3-riscv64.1
CONTROL_PLANE_IP=10.213.6.187
HOST_NETWORK_INTERFACE=eth1
HOST_NETWORK_NAME=cloudpods-host-mgmt
HOST_NETWORK_START=10.213.6.180
HOST_NETWORK_END=10.213.6.199
HOST_NETWORK_PREFIX=20
HOST_NETWORK_GATEWAY=10.213.0.1
HOST_DISK_PATH=/opt/cloud/workspace/disks
MYSQL_PASSWORD=替换为openssl_rand_hex_24生成的值
ADMIN_PASSWORD=替换为openssl_rand_hex_24生成的值
LAB_TCG_FALLBACK=false
```

分别执行两次 `openssl rand -hex 24` 生成 MySQL 和 admin 密码。确认 `HOST_NETWORK_INTERFACE` 是承载管理 IP 的物理网卡后执行：

```bash
cd /root/cloudpods-riscv64-releases/native-k8s-openruyi
chmod +x ./*.sh qemu-rva23-openruyi-lab/*.sh
./00-install-packages.sh
./10-runtime.sh
./20-control-plane.sh
./30-cloudpods-host.sh
./35-pull-cloudpods-images.sh
./40-install-cloudpods.sh
```

脚本启用 Host 时会把管理 IP 迁移到 OVS `br0`，SSH 可能短暂断开，恢复后仍使用原管理 IP 登录。

## 5. 添加计算节点

每台计算节点获取相同交付标签和配置文件。配置与主节点保持一致，只修改 `NODE_NAME`、`NODE_IP` 和 `POD_NODE_CIDR`；例如：

```bash
# 10.213.6.183
NODE_NAME=cloudpods-openruyi-compute01
NODE_IP=10.213.6.183
POD_NODE_CIDR=10.244.1.0/24

# 10.213.6.188
NODE_NAME=cloudpods-openruyi-compute02
NODE_IP=10.213.6.188
POD_NODE_CIDR=10.244.2.0/24
```

每台计算节点先执行：

```bash
cd /root/cloudpods-riscv64-releases/native-k8s-openruyi
chmod +x ./*.sh
./00-install-packages.sh
./10-runtime.sh
```

主节点为每台计算节点生成有效期两小时的加入参数：

```bash
JOIN_COMMAND=$(kubeadm token create --ttl 2h --print-join-command)
JOIN_TOKEN=$(awk '{for(i=1;i<=NF;i++)if($i=="--token")print $(i+1)}' <<<"$JOIN_COMMAND")
JOIN_HASH=$(awk '{for(i=1;i<=NF;i++)if($i=="--discovery-token-ca-cert-hash")print $(i+1)}' <<<"$JOIN_COMMAND")
printf './25-worker-join.sh %q %q\n' "$JOIN_TOKEN" "$JOIN_HASH"
```

将主节点 `/etc/kubernetes/kube-proxy.conf` 复制到计算节点，在该节点运行上一步打印的 `25-worker-join.sh` 命令。然后配置每台节点到其余节点 Pod `/24` 的静态路由：

```bash
# 主节点
./50-pod-routes.sh \
  10.244.1.0/24=10.213.6.183 \
  10.244.2.0/24=10.213.6.188

# 计算节点 1
./50-pod-routes.sh \
  10.244.0.0/24=10.213.6.187 \
  10.244.2.0/24=10.213.6.188

# 计算节点 2
./50-pod-routes.sh \
  10.244.0.0/24=10.213.6.187 \
  10.244.1.0/24=10.213.6.183
```

每台计算节点安装 Cloudpods Host 依赖：

```bash
./30-cloudpods-host.sh
./35-pull-cloudpods-images.sh
```

主节点启用计算 Host：

```bash
kubectl label node cloudpods-openruyi-compute01 onecloud.yunion.io/host=enable --overwrite
kubectl label node cloudpods-openruyi-compute02 onecloud.yunion.io/host=enable --overwrite
kubectl get nodes -o wide
kubectl -n onecloud get pods -o wide
```

## 6. 验收

主节点执行：

```bash
cd /root/cloudpods-riscv64-releases/native-k8s-openruyi
./60-verify.sh
```

必须输出 `CLOUDPODS_NATIVE_K8S_ACCEPTANCE_OK`，三台节点均为 `Ready/riscv64`，三台 Cloudpods Host 均为在线且启用。浏览器访问 `https://10.213.6.187/`，账号为 `admin`，密码是配置文件中的 `ADMIN_PASSWORD`。

最后创建一台真实 RISC-V 虚机并完成以下验收：

1. 上传 openRuyi Creek 2026.08 RISC-V QCOW2 镜像，架构选择 `riscv64`、启动方式选择 UEFI。
2. 创建 2 vCPU、4 GiB 内存、至少 25 GiB 本地系统盘的临时虚机。
3. 选择已确认不与 DHCP 冲突的虚机地址池，确认管理网可 ping 和 SSH 到虚机。
4. 虚机内确认 `uname -m` 为 `riscv64`、`systemd-detect-virt` 为 `kvm`，并执行一次重启复测 SSH。
5. 依次重启计算节点，确认 `/dev/kvm`、Kubernetes Node、Cloudpods Host、`br0` 路由和 DNS 自动恢复。

openRuyi 2026.08 云镜像默认不带 cloud-init。需要自动注入 SSH 密钥时，应先制作包含 cloud-init 的标准镜像；否则通过镜像离线注入密钥。不要依赖明文默认密码。

## 7. 故障信息收集

失败时不要清库或重装，先收集：

```bash
systemctl status etcd kube-apiserver kube-controller-manager \
  kube-scheduler kubelet kube-proxy containerd cloudpods-executor --no-pager
journalctl -u kubelet -u kube-proxy -u containerd \
  -u cloudpods-executor -n 300 --no-pager
kubectl get nodes -o wide
kubectl -n kube-system get pods -o wide
kubectl -n onecloud get pods -o wide
kubectl -n onecloud get events --sort-by=.lastTimestamp
cat /etc/cloudpods-openruyi-component-sources.env
lsmod | grep '^kvm'
ls -l /dev/kvm /dev/net/tun
ovs-vsctl show
ip -brief address
resolvectl status br0
```

将失败脚本最后 200 行输出与上述结果一并提供给技术支持。
