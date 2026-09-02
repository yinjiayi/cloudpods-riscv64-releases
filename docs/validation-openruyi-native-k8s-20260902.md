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

计算节点 2 首次重启后，内核记录 `spacemit-dwmac` 的 `NETDEV WATCHDOG` 发送
队列超时并自动复位 `eth1`。系统、KVM、OVS、地址和路由均正常，但上游交换机在
节点主动发包前无法重新学习管理 MAC。部署脚本因此关闭该接口的 TSO/GSO/GRO 和
EEE，并用 systemd timer 每分钟发送 gratuitous ARP、探测管理网关。

计算节点 2 经断电启动后，在串口未主动发送网络流量前，同网段节点即可访问其管理
地址；启动 ID 由 `a7009ccc-a23f-42b6-85a9-08bb0deb96c5` 变为
`626c9d42-e1ad-49a7-93de-290aa963f797`。TSO/GSO/GRO 与 EEE 保持关闭，本次启动
日志未再次出现 `NETDEV WATCHDOG`；Kubernetes Node 为 Ready，Cloudpods Host 为
running/online。

计算节点 1 的历史日志显示 `st_gmac` 曾约每 11 秒触发一次 `NETDEV WATCHDOG`
并复位网卡。断电后有一次 initramfs 未枚举到 UFS 根分区，停留在等待正确根 UUID
`b134f93b-3ed4-4f31-a1c3-d10211eaa4b9`；再次物理复位后，Kingston UFS 盘在约
10 秒内被识别，实际 `/dev/sda2` UUID 与引导配置一致，排除 `fstab` 配置错误。
EXT4 日志恢复完成且文件系统状态为 clean。`/boot` FAT 脏位在完整备份后使用
openRuyi `dosfstools` 修复，复查无错误；备份文件保存在计算节点 1 的
`/root/boot-backup-before-fsck-20260902.tar`。

三台节点现均启用相同规避方案，timer 执行结果为 success，当前启动周期没有新的
`NETDEV WATCHDOG`、I/O 或 EXT4 错误。三台 Kubernetes Node 均为 Ready，三台
Cloudpods Host 均为 running/online；计算节点 1 上的真实虚机自动恢复为 running，
管理网可达并再次确认 `riscv64`、openRuyi、KVM、根盘与 SSH 正常。最终执行
`60-verify.sh` 输出 `CLOUDPODS_NATIVE_K8S_ACCEPTANCE_OK`。
