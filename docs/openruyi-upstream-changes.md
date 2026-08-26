# openRuyi Cloudpods 上游适配变更

openRuyi 发行、依赖构建和部署脚本保存在本仓库；Cloudpods 与 Operator
代码变更按问题拆分为独立提交和独立上游 PR，便于分别评审与合并。

| 仓库 | 提交 / PR | 说明 |
| --- | --- | --- |
| `yunionio/cloudpods` | [`5b89200b`](https://github.com/yinjiayi/cloudpods/commit/5b89200b769be36a09660bb4f31f19cb90ae30ab) / [PR #25435](https://github.com/yunionio/cloudpods/pull/25435) | 增加 openRuyi GuestFS 驱动、系统识别和初始化测试 |
| `yunionio/cloudpods` | [`7be5309c`](https://github.com/yinjiayi/cloudpods/commit/7be5309cff8e6a1ad7cb109265e5566fb98a506b) / [PR #25436](https://github.com/yunionio/cloudpods/pull/25436) | 在 RISC-V Host 注册 QEMU 11.1.0 驱动并增加单元测试 |
| `yunionio/cloudpods` | [`21da5ae1`](https://github.com/yinjiayi/cloudpods/commit/21da5ae14493170d0a973b4bc0312c47aa99b114) / [PR #25437](https://github.com/yunionio/cloudpods/pull/25437) | Host 原生识别 containerd 的镜像文件系统，不再要求 Docker 兼容命令 |
| `yunionio/cloudpods-operator` | [`00aa81e`](https://github.com/yinjiayi/cloudpods-operator/commit/00aa81ee5bf49adc7d9b3e1943ccff053c76caad) / [PR #1565](https://github.com/yunionio/cloudpods-operator/pull/1565) | CronJob API 从已移除的 `batch/v1beta1` 升级到 `batch/v1`，兼容 Kubernetes 1.36 |
| `yinjiayi/cloudpods-riscv64-releases` | [`27ca63a`](https://github.com/yinjiayi/cloudpods-riscv64-releases/commit/27ca63a) | Host 和 Region 使用同一 Cloudpods 源码构建，避免 API/驱动版本不一致 |
| `yinjiayi/cloudpods-riscv64-releases` | [`611c387`](https://github.com/yinjiayi/cloudpods-riscv64-releases/commit/611c387) | openRuyi 原生 QEMU 构建启用 Nettle，并加入 Cloudpods VNC DES-RFB 门禁 |

Cloudpods fork 的 `master` 已包含上述 3 项 Cloudpods 变更；Operator fork 的
`master` 已包含 Kubernetes `batch/v1` 变更。上游 PR 合并前，交付镜像固定
使用 fork 的已验证提交构建，不能混用上游旧版 Host 与 fork 的 Region。
