# openRuyi 2026.08 物理 RISC-V 集群验证记录

验证日期：2026-09-02

交付标签：`openruyi-native-k8s-v4.0.3-riscv64.3`

## 验证环境

| 角色 | 管理 IP | 架构/系统 | Kubernetes PodCIDR |
| --- | --- | --- | --- |
| 控制与计算节点 | `10.213.6.187` | `riscv64` / openRuyi Creek 2026.08 | `10.244.0.0/24` |
| 计算节点 1 | `10.213.6.183` | `riscv64` / openRuyi Creek 2026.08 | `10.244.1.0/24` |
| 计算节点 2 | `10.213.6.188` | `riscv64` / openRuyi Creek 2026.08 | `10.244.2.0/24` |

三台均为物理 RISC-V K3 服务器。软件安装优先使用 openRuyi 仓库：Kubernetes
1.35.5、containerd 2.3.3、etcd 3.6.6、QEMU 11.0.1；仓库缺少的 cri-tools
1.36.0 和 CNI plugins 1.9.1 使用官方 RISC-V 发行物。三台节点均加载 `kvm`
和 `tun`，并通过 `/etc/modules-load.d/cloudpods-openruyi-native.conf` 持久化。

## Cloudpods 验证

- 三台 Kubernetes Node 均为 `Ready/riscv64`，CoreDNS 两副本运行；
- Cloudpods 核心 Pod 正常，七个 Host 相关 DaemonSet 均为 3/3；
- 三台 Cloudpods Host 均为在线、启用状态；
- Web 入口为 `https://10.213.6.187/`；
- `60-verify.sh` 输出 `CLOUDPODS_NATIVE_K8S_ACCEPTANCE_OK`；
- Host 与 Region 均来自 Cloudpods 提交 `6359b60d0b5cad7d337990ba966c7e2d106cabb8`，运行镜像为 `v4.0.3-riscv64.9`。

openRuyi QEMU RPM 缺少 Cloudpods VirtIO 网卡需要的 `efi-virtio.rom`。部署脚本保留
QEMU 11.0.1 可执行文件和 RPM 归属，只从已发布 fallback RPM 补齐 option ROM，
并在 `/usr/local/qemu-11.0.1/bin` 建立版本化链接。补齐后磁盘创建和 QEMU 启动成功。

## 真实虚机验收

| 项目 | 结果 |
| --- | --- |
| 虚机 | `openruyi-riscv64-smoke`，UUID `0c74f4ac-a6f6-4cff-8894-64d8a055f5ea` |
| 计算节点 | `10.213.6.183` / `cloudpods-openruyi-compute01` |
| 规格 | 2 vCPU、4 GiB 内存、25 GiB 本地系统盘 |
| 镜像 | openRuyi Creek 2026.08，qcow2、`riscv64`、UEFI |
| 网络 | `10.213.15.231/20`，管理网络 SSH 可达 |
| 虚拟化 | QEMU 11.0.1 + KVM；虚机内 `systemd-detect-virt` 返回 `kvm` |
| 重启 | 虚机 Boot ID 变化，重启后 SSH、根盘和网络恢复 |

openRuyi 2026.08 云镜像不带 cloud-init。此次验收通过离线注入公钥启用 SSH；客户
生产镜像应预装 cloud-init，或在上传前植入受控公钥，不能依赖明文默认密码。

## 网络与重启恢复

Cloudpods Host 将管理 IP 迁移到 OVS `br0`。脚本新增持久化 DNS 服务，将 DNS 和
默认 DNS 路由从物理网卡迁移到 `br0`，避免 Host 启用后解析失败。节点使用网关
`10.213.0.1` 作为 NTP；containerd 和 kubelet 在时间同步门禁通过后启动。

计算节点重启验收项目：`kvm` 模块与 `/dev/kvm`、`br0` 管理地址、路由、DNS、
Kubernetes Node Ready、Cloudpods Host online。现场访问链路恢复后补录最终结果。
