# Cloudpods RISC-V release sources

Reproducible release source for running Cloudpods `v4.0.3` on openEuler
24.03 LTS SP3 `riscv64` with a self-built K3s distribution.

This repository publishes two classes of deliverables:

- OCI images under `ghcr.io/yinjiayi`
- RPM repository metadata through GitHub Pages

K3s itself is built from the `yinjiayi/k3s` fork. ocboot consumes the K3s
release assets, the GHCR image names, and the RPM repository from the
`yinjiayi/ocboot` RISC-V branch. Native Kubernetes is intentionally not part
of this delivery.

## Release layout

| Deliverable | Location |
| --- | --- |
| K3s binary and air-gap bundle | `github.com/yinjiayi/k3s/releases` |
| Pinned native-build source archives | `yinjiayi.github.io/cloudpods-riscv64-releases/source-assets/` |
| K3s system images | `ghcr.io/yinjiayi/k3s-*` |
| Cloudpods runtime images | `ghcr.io/yinjiayi/*` |
| ocboot build image | `ghcr.io/yinjiayi/ocboot` |
| openEuler RISC-V RPMs | `yinjiayi.github.io/cloudpods-riscv64-releases/rpm/openEuler/24.03-LTS-SP3/riscv64/` |

The complete version and provenance lock is in `versions.env`. Build commands
run natively on a self-hosted RISC-V machine labelled
`openeuler-24.03-riscv64`, except for the cross-compiled K3s binary in the K3s
fork.

## Required runner

The native runner must provide:

- openEuler 24.03 LTS SP3 on `riscv64`
- Buildah, CNI plugins, Skopeo, Git, RPM build tools, createrepo_c, GPG, GCC
  and Ninja
- at least 16 GiB RAM and 60 GiB free disk

GitHub does not publish a native RISC-V Actions Runner. On a dedicated build
machine, install the pinned official x64 Runner control process with:

```bash
sudo ./scripts/install-riscv64-actions-runner-runtime.sh
```

The installer builds signed QEMU `11.1.0` as `x86_64-linux-user` only, verifies
the signed Ubuntu 22.04 OCI root filesystem, adds the pinned ICU runtime, and
registers a binfmt handler. Runner and JavaScript action control processes are
emulated; workflow shell commands and all actual builds remain native
`riscv64`. This QEMU is isolated below `/opt` and is independent of the QEMU
`10.0.7` RPM used by Cloudpods guests.

The official Runner's .NET 8 dynamic-code paths are not reliable under x64
user-mode translation on RISC-V. The installer downloads a fixed-hash Json.NET
compatibility DLL built by `runner-compat.yml`, then applies the official .NET
`Switch.System.Reflection.ForceInterpretedInvoke` and
`System.Runtime.CompilerServices.RuntimeFeature.IsDynamicCodeSupported=false`
AppContext settings to Listener, Worker, and PluginHost. Reflection invokes and
compiled regular expressions therefore use their interpreter paths. This keeps
W^X enabled and does not modify Cloudpods.

Obtain a one-time repository registration token immediately before use, then
run `scripts/register-riscv64-actions-runner.sh` with it in the
`ACTIONS_RUNNER_TOKEN` environment variable. Never put the token in a file,
commit, workflow, or shell history.

The build runner may be a nested VM without `/dev/kvm`. In that case the RPM
build explicitly sets `QEMU_KVM_SMOKE=skip`; the exact QEMU RPM must then pass
`rpm/verify-qemu-kvm-rpm.sh` on the physical RISC-V virtualization host before
the Pages publishing workflow accepts it.

The workflows use the repository-scoped `GITHUB_TOKEN`; no personal access
token is stored in repository secrets.

## Release order

1. Run `Publish Actions Runner RISC-V compatibility asset` once for the pinned
   Runner version, then install and register the RISC-V build runner.
2. Export the pinned Cloudpods and ocboot commits, verify
   `source-assets/SHA256SUMS`, and publish them under the source-asset release
   tag recorded in `versions.env`; then run `Publish native-build source assets
   to Pages` so the RISC-V runner uses the resumable Pages mirror.
3. Run `Build K3s RISC-V images`.
4. Confirm each new package is Public in GitHub package settings; change it if
   the package did not inherit visibility from the public source repository.
5. Run `scripts/verify-ghcr-public.sh images/k3s-images.lock` without credentials.
6. Tag the K3s fork with `v1.28.5+k3s1-riscv64.3`.
7. Run `Build and publish Cloudpods RISC-V images`, make any new packages
   public, and verify `images/cloudpods-images.lock` the same way.
8. Run `Build openEuler RISC-V RPMs` and note its workflow run ID.
9. Download that run's RPM artifact to the physical RISC-V host and run
   `sudo rpm/verify-qemu-kvm-rpm.sh PATH_TO_QEMU_RPM`.
10. Copy `rpm/kvm-validation.env.example` to `rpm/kvm-validation.env`, record the
   original build run ID and emitted `KVM_VALIDATION_SHA256`, commit it, then
   push an `rpm-pages-riscv64-*` tag. The publisher downloads and checks that
   exact artifact; it does not rebuild it. Manual dispatch remains available.
11. Tag the ocboot RISC-V branch, run `Build and publish ocboot RISC-V image`
    from this release repository, then verify its GHCR package is public.

Packages linked to this public source repository currently inherit Public
visibility. Always confirm the package settings and run the anonymous
`verify-ghcr-public.sh` check anyway. If a package is Private, changing it to
Public is a one-time GitHub UI action; later versions keep that visibility.

Every workflow verifies the architecture and emits SHA-256 checksums before
publishing.

## Source checks

Before committing release-source changes, run:

```bash
bash -n images/*.sh rpm/*.sh scripts/*.sh
git diff --check
```

GitHub Actions workflow files must also parse as YAML. Full image and RPM
builds are acceptance tests and run only on the labelled RISC-V runner.
