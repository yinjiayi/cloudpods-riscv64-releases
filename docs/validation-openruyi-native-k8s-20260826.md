# openRuyi 原生 Kubernetes + Cloudpods RISC-V 验证记录

验证日期：2026-08-26
交付标签：`openruyi-native-k8s-v4.0.3-riscv64.2`

## 验证范围

本次在 x86_64 物理宿主上使用 QEMU system 模拟两台支持 RVA23 的 RISC-V
服务器。两台服务器均安装 openRuyi Creek 2026.07，先独立部署原生
Kubernetes，再部署 Cloudpods；未使用 K3s 或 ocboot。

| 角色 | 架构 | 操作系统 | Kubernetes | 容器运行时 |
| --- | --- | --- | --- | --- |
| 控制与计算节点 | `riscv64` | openRuyi Creek 2026.07 | v1.36.4 | containerd v2.3.4 |
| 计算节点 | `riscv64` | openRuyi Creek 2026.07 | v1.36.4 | containerd v2.3.4 |

Cloudpods 使用 `v4.0.3-riscv64.8`，Operator 使用
`v4.0.3-riscv64.4`，Dashboard 使用 `v4.0.3-riscv64-ui2`。两台 Host
运行同一 Cloudpods 提交构建的 Host 与 Region，Host 直接识别
containerd 的镜像文件系统，不依赖 Docker 兼容脚本。

## QEMU 验证

QEMU 11.1.0 在 openRuyi RISC-V 节点上原生构建，配置包含 KVM、
`rva23s64` CPU、slirp、VNC 和 Nettle。发布前执行以下检查：

- RISC-V ELF、动态库闭包和版本检查；
- `/dev/kvm` 启动 openRuyi 内核并识别 `riscv-virtio,qemu`；
- `efi-virtio.rom`、PXE ROM 和 `keymaps/en-us` 完整性检查；
- 带密码 VNC 的 DES-RFB 加密后端存活检查。

## Cloudpods 虚机验收

| 项目 | 结果 |
| --- | --- |
| 测试虚机 | `openruyi-native-k8s-smoke` |
| 虚机架构与系统 | `riscv64`，openRuyi Creek 2026.07 |
| 系统盘 | 本地存储，45 GiB，创建与扩容成功 |
| 虚拟化 | QEMU 11.1.0 + KVM，RVA23 CPU |
| 网络 | Cloudpods 静态地址池，`192.168.123.117`，管理网络可达 |
| SSH | 通过；识别为 `riscv64/openRuyi/KVM` |
| 虚机重启恢复 | 通过；Boot ID 变化，SSH 恢复 |
| 计算节点重启恢复 | 通过；时钟门禁、Kubernetes 和 Host 自动恢复，虚机可重新启动 |
| 控制节点重启恢复 | 通过；API、Cloudpods、两台 Host 及虚机访问恢复 |

测试虚机 ID 为 `06de8fae-ea3f-4746-88ae-c76b04d95919`。QEMU 进程确认
使用 `-enable-kvm -cpu host`、UEFI pflash、VirtIO 本地盘、VirtIO 网络及带密码
VNC。官方云镜像完成首次根分区扩展后，重复执行 `systemd-repart` 会因没有剩余
空间返回失败；确认根分区已为 45 GiB 后屏蔽该一次性服务，系统状态恢复为
`running`，不影响 Cloudpods 磁盘创建、扩容或启动。

两台 openRuyi 宿主均启用 `chronyd` 和 `cloudpods-time-sync.service`，并在
containerd/kubelet 启动前通过 `Leap status: Normal` 门禁。该修复消除了 RVA23
QEMU 宿主重启后 RTC 回退导致的 containerd 容器状态冲突。

## 最终门禁

交付前必须同时满足：

- 两台 Kubernetes 节点均为 `Ready/riscv64`；
- kube-system 与 onecloud 命名空间所有必需 Pod 就绪；
- Operator 运行且 OnecloudCluster 与 Host/Region 镜像版本一致；
- 两台 Cloudpods Host 为在线、启用状态；
- HTTPS Web 页面可访问；
- 测试虚机可由管理网络 SSH 登录，虚机及两台宿主重启后可恢复；
- `60-verify.sh` 输出 `CLOUDPODS_NATIVE_K8S_ACCEPTANCE_OK`。

最终执行结果：上述门禁全部通过，`60-verify.sh` 输出
`CLOUDPODS_NATIVE_K8S_ACCEPTANCE_OK`。
