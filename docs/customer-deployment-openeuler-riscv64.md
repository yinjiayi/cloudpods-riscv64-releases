# Cloudpods RISC-V 客户部署手册

文档版本：1.0  
发布日期：2026-08-20  
适用系统：openEuler 24.03 LTS SP3 `riscv64`  
部署方式：ocboot + 自建 RISC-V K3s

本手册用于在全新的 RISC-V 服务器上安装一套 Cloudpods，并继续加入一台或多台 RISC-V 计算节点。部署使用自建 K3s，不安装原生 Kubernetes。

## 1. 交付版本

部署时保持以下版本不变：

| 组件 | 版本 |
| --- | --- |
| ocboot | `v4.0.3-riscv64.16` |
| K3s | `v1.28.5+k3s1-riscv64.4` |
| Cloudpods | `v4.0.3-riscv64.6` |
| Dashboard | `v4.0.3-riscv64-ui2` |
| Cloudpods Operator | `v4.0.3-riscv64.3` |
| KubeServer | `v4.0.3-riscv64.5` |
| QEMU | `10.0.7-6.oe2403sp3` |

## 2. 部署规划

部署前准备以下信息：

| 项目 | 示例 | 要求 |
| --- | --- | --- |
| 主节点 IP | `192.0.2.10` | 固定 IP 或 DHCP 保留地址 |
| 主节点 hostname | `cloudpods-master-01` | 集群内唯一 |
| 计算节点 IP | `192.0.2.11` | 固定 IP 或 DHCP 保留地址 |
| 计算节点 hostname | `cloudpods-compute-01` | 集群内唯一 |
| 计算节点物理网卡 | `eth0` | 当前承载计算节点管理 IP 的网卡 |
| 虚拟机磁盘目录 | `/opt/cloud/workspace/disks` | 本地文件系统，建议至少 200 GiB 可用空间 |
| 数据库密码 | 客户自定义 | 强密码，不得使用示例值 |
| Cloudpods admin 密码 | 客户自定义 | 强密码，不得使用示例值 |

本手册默认首台服务器同时承担主节点和计算节点角色，新增服务器作为计算节点。

## 3. 环境要求

每台服务器建议不少于 16 核 CPU、32 GiB 内存和 200 GiB 可用磁盘，并满足：

- 操作系统必须为 openEuler 24.03 LTS SP3 `riscv64`。
- 必须存在 `/dev/kvm` 和 `/dev/net/tun`。
- 服务器时间同步、DNS 正常，hostname 唯一。
- 服务器未安装或运行其他 Kubernetes/K3s 集群。
- Pod 网段 `10.40.0.0/16` 和 Service 网段 `10.96.0.0/12` 不得与现场网络重叠。
- 主节点的 root SSH 公钥已经加入主节点自身和所有计算节点的 `/root/.ssh/authorized_keys`。
- 计算节点接入交换机端口允许多个 MAC 地址；若虚拟机使用现场 DHCP，交换网络必须允许 DHCP 报文到达虚拟机。
- 所有节点能够访问 `github.com`、`raw.githubusercontent.com`、`codeload.github.com`、`ghcr.io`、GitHub 容器 CDN 和 `yinjiayi.github.io`。

节点间至少放通以下端口：

| 方向 | 协议/端口 | 用途 |
| --- | --- | --- |
| 主节点到所有节点 | TCP 22 | SSH |
| 所有节点到主节点 | TCP 6443 | K3s API |
| 节点之间 | TCP 10250、UDP 8472 | Kubelet、Flannel VXLAN |
| 计算节点之间 | UDP 6081 | OVN Geneve |
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
! systemctl is-active --quiet k3s-agent
hostnamectl hostname
ip -brief address
df -h /
```

任一检查失败时停止部署，先修复操作系统、KVM、网络或已有集群冲突。

如尚未配置 root 免密 SSH，在主节点上执行：

```bash
PRIMARY_IP=192.0.2.10
NODE_IP=192.0.2.11

test -f ~/.ssh/id_ed25519 || ssh-keygen -t ed25519 -N '' -f ~/.ssh/id_ed25519
ssh-copy-id root@"$PRIMARY_IP"
ssh-copy-id root@"$NODE_IP"
ssh root@"$PRIMARY_IP" hostnamectl hostname
ssh root@"$NODE_IP" hostnamectl hostname
```

有多台计算节点时，对每台计算节点重复 `ssh-copy-id` 和 SSH 检查。

## 5. 安装主节点

### 5.1 设置 hostname

在主节点执行，名称按现场规划替换：

```bash
hostnamectl set-hostname cloudpods-master-01
```

### 5.2 下载固定版本 ocboot

以下命令必须在 RISC-V 主节点以 root 执行。不要在 x86 部署机上执行，否则 ocboot 会按执行机架构选择错误的容器镜像。

```bash
dnf install -y git buildah curl
cd /root
git clone --depth 1 --branch v4.0.3-riscv64.16 \
  https://github.com/yinjiayi/ocboot.git
cd /root/ocboot
test "$(git rev-parse HEAD)" = fd5147e7f1dcd4075ea540c84067c32b3e900d48
cp config-example-openeuler-riscv64.yml config.yml
```

### 5.3 修改安装配置

编辑配置：

```bash
vi config.yml
```

完成以下修改：

1. 将文件中全部 `192.0.2.10` 替换为主节点实际固定 IP。
2. 将两处 `CHANGE_ME_DB_PASSWORD` 替换为同一个数据库强密码。
3. 将 `CHANGE_ME_ADMIN_PASSWORD` 替换为 Cloudpods `admin` 用户强密码。
4. 保持 `target_architecture: riscv64`、`image_repository: ghcr.io/yinjiayi` 和所有交付版本号不变。
5. 密码包含 `#`、冒号或空格时，必须使用 YAML 单引号包围，例如 `db_password: 'Strong#Password'`。

安装前确认示例值已全部替换：

```bash
! grep -Eq '192\.0\.2\.10|CHANGE_ME_' config.yml
grep -E 'onecloud_version|operator_version|target_architecture|image_repository' config.yml
```

### 5.4 执行安装

```bash
./ocboot.sh install config.yml
```

ocboot 会自动拉取固定版本的 RISC-V K3s、Cloudpods 镜像和 RPM。若安装程序为系统启用 cgroup v2，目标服务器会自动重启；重新登录后进入原来的 `ocboot` 目录，再次执行同一条安装命令即可。安装支持幂等重入，不要改用 kubeadm 或原生 Kubernetes。

首台服务器同时作为计算节点时，安装过程中管理 IP 会迁移到 OVS `br0`，SSH 可能短暂断开；等待网络恢复后仍使用原管理 IP 重新连接。

镜像下载和初始化可能需要较长时间，命令仍有输出时不要中断。

## 6. 主节点验收

在主节点执行：

```bash
systemctl is-active k3s
systemctl is-active cloudpods-executor
k3s --version
k3s kubectl get nodes -o wide
k3s kubectl -n onecloud get pods -o wide
k3s kubectl -n onecloud get daemonsets
source ~/.onecloud_rcadmin
climc host-list
curl -kI https://127.0.0.1/
```

主节点验收标准：

- K3s 版本包含 `v1.28.5+k3s1-riscv64.4`。
- 主节点状态为 `Ready`。
- `onecloud` 命名空间 Pod 正常，DaemonSet 的期望数与就绪数一致。
- Cloudpods Host 状态为 `running/online/enabled`。
- `https://主节点IP/` 可以打开；访问 HTTP 80 会跳转到 HTTPS 443。
- 使用用户名 `admin` 和 `config.yml` 中设置的管理员密码可以登录。

## 7. 添加 RISC-V 计算节点

以下步骤对每台新增计算节点逐台执行。

### 7.1 准备计算节点

在主节点设置变量，替换为实际值：

```bash
PRIMARY_IP=192.0.2.10
NODE_IP=192.0.2.11
NODE_NAME=cloudpods-compute-01
NODE_NIC=eth0
```

确认 `NODE_NIC` 是计算节点当前承载管理 IP 的物理网卡：

```bash
ssh root@"$NODE_IP" "ip route get $PRIMARY_IP"
ssh root@"$NODE_IP" 'ip -brief address'
```

设置唯一 hostname 并创建虚拟机磁盘目录：

```bash
ssh root@"$NODE_IP" "hostnamectl set-hostname $NODE_NAME"
ssh root@"$NODE_IP" 'mkdir -p /opt/cloud/workspace/disks'
```

### 7.2 执行 add-node

在主节点保存固定版本 ocboot 的目录中执行：

```bash
cd /root/ocboot

./ocboot.sh add-node \
  --runtime qemu \
  --host-network "$NODE_NIC" \
  --disk-path /opt/cloud/workspace/disks \
  --enable-host-after-ready \
  "$PRIMARY_IP" "$NODE_IP"
```

ocboot 会等待以下项目全部就绪后再启用计算节点：

- Kubernetes Node 为 `Ready`；
- Cloudpods Host DaemonSet、executor 和 lbagent 就绪；
- OVS `br0` 创建完成；
- QEMU 10.0.7 和 KVM 可用；
- Cloudpods Host 为 `running/online`。

执行期间，计算节点管理 IP 会从物理网卡迁移到 OVS `br0`，SSH 可能短暂断开。等待网络恢复后仍使用原管理 IP 重新连接。正常部署不要使用 `--skip-postflight`。

## 8. 计算节点验收

在主节点执行：

```bash
k3s kubectl get nodes -o wide
k3s kubectl -n onecloud get daemonsets
source ~/.onecloud_rcadmin
climc host-list
```

在新增计算节点执行：

```bash
systemctl is-active k3s-agent
systemctl is-active cloudpods-executor
ovs-vsctl br-exists br0
ip -brief address show br0
test -c /dev/kvm
/usr/local/qemu-10.0.7/bin/qemu-system-riscv64 --version
```

计算节点验收标准：

- 新节点在 Kubernetes 中为 `Ready`。
- 新 Host 在 Cloudpods 中为 `running/online/enabled`。
- 管理 IP 位于 `br0`，原 IP 可以正常 SSH。
- QEMU 显示 10.0.7，`/dev/kvm` 可用。
- 所有相关 DaemonSet 的期望数与就绪数一致。

## 9. 虚拟机网络和首台虚拟机验收

- 不要把仅包含宿主机管理 IP 的管理网络地址池直接分配给虚拟机。
- 如使用现场 DHCP，交换机端口必须允许多个 MAC，计算节点所在二层网络必须能收到 DHCP；不要再创建与 DHCP 地址池重叠的 Cloudpods 静态 IP 池。
- 如由 Cloudpods 管理静态地址，必须先由网络管理员从 DHCP 中排除或保留一段地址，再将该地址段配置为 Cloudpods 子网。
- 上传 openEuler 24.03 LTS SP3 RISC-V QCOW2 镜像时，将镜像架构选择为 `riscv64`。
- 创建一台测试虚拟机，确认状态为运行中、获得预期地址，并从同一网络通过 ping/SSH 访问。SSH 用户名和密码由所使用的客户机镜像决定。

## 10. 故障信息收集

部署失败时不要重装或清空数据，先执行以下命令收集信息：

```bash
systemctl status k3s k3s-agent cloudpods-executor --no-pager
journalctl -u k3s -u k3s-agent -u cloudpods-executor -n 300 --no-pager
k3s kubectl get nodes -o wide
k3s kubectl -n onecloud get pods -o wide
k3s kubectl -n onecloud get events --sort-by=.lastTimestamp
ovs-vsctl show
ip -brief address
```

将 ocboot 终端最后 200 行输出和上述结果一并提供给技术支持。
