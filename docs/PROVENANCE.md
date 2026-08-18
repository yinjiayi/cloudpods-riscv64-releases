# Release provenance

All source tags are checked against full commits, and downloaded artifacts are
checked against SHA-256 digests before a release is published.

| Component | Source |
| --- | --- |
| K3s | `yinjiayi/k3s` RISC-V branch based on `k3s-io/k3s` tag `v1.28.5+k3s1` |
| ocboot | `yinjiayi/ocboot` RISC-V branch based on Cloudpods `v4.0.3`; its RISC-V image uses the measured reachable Aliyun Alpine and Huawei Cloud PyPI mirrors plus Alpine's native `py3-cryptography` and `py3-yaml` packages |
| Cloudpods operator | `yinjiayi/cloudpods-operator` commit `844387f47a91bc477b427449f98501b6b54eabc7`, based on upstream `v4.0.3`, with the configured etcd BusyBox image propagated to the local-storage helper pod |
| KubeServer | `yunionio/kubecomps` tag `v4.0.3`, commit `eb381ed38b587e2cabd081c69a0e6b0aa04a5360`, built natively on RISC-V with the three pinned kubespray submodule archives recorded in `versions.env` |
| Native-build source assets | exact Cloudpods, ocboot, operator, kubecomps, kubespray, and sdnagent commits exported once, published as release assets, mirrored through GitHub Pages, and pinned by SHA-256 so slow links can resume without changing source |
| K3s root filesystem | `k3s-io/k3s-root` release `v0.13.0` |
| CoreDNS | `coredns/coredns` tag `v1.11.1` |
| Traefik | `traefik/traefik` tag `v2.10.5` |
| Metrics Server | `kubernetes-sigs/metrics-server` tag `v0.7.2` |
| Local Path Provisioner | `rancher/local-path-provisioner` tag `v0.0.29` |
| klipper-helm | upstream source plus `k3s-io/klipper-helm` PR 64, commit `8a71d64` |
| klipper-lb | upstream source plus `k3s-io/klipper-lb` PR 56, commit `faaeca6` |
| K3s build bases | architecture-specific upstream digests mirrored by a hosted runner to `ghcr.io/yinjiayi` before native RISC-V builds |
| Cloudpods QEMU | signed `download.qemu.org` source `10.0.7` |
| Actions Runner QEMU | signed `download.qemu.org` source `11.1.0`, `x86_64-linux-user` only |
| GitHub Actions Runner | official `actions/runner` x64 release `2.336.0`, SHA-256 pinned |
| Runner .NET compatibility | deterministic Mono.Cecil `0.11.6` transform of the pinned Json.NET DLL plus the .NET 8 `ForceInterpretedInvoke` and `RuntimeFeature.IsDynamicCodeSupported=false` AppContext settings on Listener, Worker, and PluginHost; tiered compilation and dynamic PGO are disabled for the emulated control processes |
| Runner sysroot | signed Canonical Ubuntu 22.04 OCI build `20260810`, SHA-256 pinned |
| Runner ICU | Ubuntu Jammy `libicu70` package `70.1-2`, SHA-256 pinned |
| Open vSwitch | openEuler 24.03 LTS SP3 SRPM plus the checked-in GCC 14 patch |
| Cloudpods source asset | exact `yinjiayi/cloudpods` commit `819faf4e43c30ecb78eb3201abfd1212d99f7945` |
| Cloudpods executor | the pinned Cloudpods source asset plus the checked-in flag parser patch |
| RISC-V UEFI | openEuler 24.03 LTS SP3 `RISCV_VIRT_*_RVA20.fd`, pinned by SHA-256 |

`versions.env` contains the full source commits, SHA-256 checksums, and QEMU
release-key fingerprint. The Actions Runner bootstrap also verifies the
Canonical checksum signature against the pinned Ubuntu cloud-image key
fingerprint. The K3s fork additionally pins its generated root filesystem
checksum in `scripts/version.sh`. Workflows reject an architecture other than
`riscv64` and publish final RPM/image digest lists as build artifacts.
