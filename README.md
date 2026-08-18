# Cloudpods RISC-V release sources

Reproducible release source for running Cloudpods `v4.0.3` on openEuler
24.03 LTS SP3 `riscv64` with a self-built K3s distribution.

This repository publishes two classes of deliverables:

- OCI images under `ghcr.io/yinjiayi`
- source archives and RPM repository metadata through one atomic GitHub Pages
  site

K3s itself is built from the `yinjiayi/k3s` fork. ocboot consumes the K3s
release assets, the GHCR image names, and the RPM repository from the
`yinjiayi/ocboot` RISC-V branch. Native Kubernetes is intentionally not part
of this delivery.

Customer deployment steps are in the
[openEuler RISC-V single-node guide](https://github.com/yinjiayi/ocboot/blob/v4.0.3-riscv64.9/docs/customer-deployment-openeuler-riscv64.md).

## Release layout

| Deliverable | Location |
| --- | --- |
| K3s binary and air-gap bundle | `yinjiayi.github.io/cloudpods-riscv64-releases/k3s/v1.28.5-k3s1-riscv64.4/` |
| Pinned native-build source archives | `yinjiayi.github.io/cloudpods-riscv64-releases/source-assets/` |
| K3s system images | `ghcr.io/yinjiayi/k3s-*` |
| Cloudpods runtime images | `ghcr.io/yinjiayi/*` |
| ocboot build image | `ghcr.io/yinjiayi/ocboot` |
| openEuler RISC-V RPMs | `yinjiayi.github.io/cloudpods-riscv64-releases/rpm/openEuler/24.03-LTS-SP3/riscv64/` |

The complete version and provenance lock is in `versions.env`. Cloudpods OCI
images are built in pinned `riscv64` containers on an x86_64 self-hosted runner
labelled `cloudpods-riscv64-qemu`; Linux binfmt dispatches their processes to
QEMU user-mode. The K3s binary is cross-compiled in the K3s fork. RPM builds
and KVM acceptance remain on the openEuler RISC-V host labelled
`openeuler-24.03-riscv64`.

The dashboard distribution and K3s binary enter the native Cloudpods build
through a checksum-pinned RISC-V build-assets image. Its immutable manifest
digest is recorded in `versions.env`, so rebuilding release scripts does not
rebuild or redownload unchanged web/K3s inputs on the native runner.

## Required runners

The Cloudpods image runner must provide:

- x86_64 Linux with the `cloudpods-riscv64-qemu` Actions label
- an enabled `qemu-riscv64` binfmt handler with persistent-open flags
- Buildah, Skopeo, Git, Curl, jq, `file`, `createrepo_c`, and SHA-256 tools
- at least 32 GiB RAM and 120 GiB free disk

The workflow requires `QEMU_USER_RISCV64=1`, verifies the registered
interpreter, compiles and runs a RISC-V Go ELF before the full build, and then
checks every published image manifest and runtime binary as `riscv64`.
Existing dependency mirrors are reused only when the normalized RISC-V OCI
config SHA-256 matches the pinned source; that config includes the rootfs
DiffIDs, architecture, history, and runtime settings.
The core build uses four outer Make jobs, eight Go package jobs per target, and
one compiler thread per emulated process. This keeps at most 32 RISC-V package
compilers active on the 32-vCPU x86 runner instead of multiplying both layers
of parallelism.

The native RPM and KVM-validation runner must provide:

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
compiled regular expressions therefore use their interpreter paths. The
service also disables .NET tiered compilation and dynamic PGO so the long-lived
Worker does not switch to background-recompiled code while running under QEMU
user-mode translation. This keeps W^X enabled and does not modify Cloudpods.
The generated systemd drop-in uses `KillMode=control-group`, so stopping or
restarting the service also terminates native build children left behind by a
cancelled emulated Worker.

Obtain a one-time repository registration token immediately before use, then
run `scripts/register-riscv64-actions-runner.sh` with it in the
`ACTIONS_RUNNER_TOKEN` environment variable. Never put the token in a file,
commit, workflow, or shell history.

The build runner may be a nested VM without `/dev/kvm`. In that case the RPM
build explicitly sets `QEMU_KVM_SMOKE=skip`; the exact QEMU RPM must then pass
`rpm/verify-qemu-kvm-rpm.sh` on the physical RISC-V virtualization host before
the Pages publishing workflow accepts it.

The target openEuler 24.03 LTS SP3 RISC-V repositories do not publish the
`librbd1` and `librados2` runtime packages, so this QEMU build explicitly
disables optional Ceph RBD support and rejects an RPM that regains either
unresolvable library dependency. Local host storage remains supported.
The QEMU RPM also carries its exact glibc loader and runtime-library closure:
Cloudpods mounts `/usr/local/qemu-10.0.7` into an Alpine host pod, where a
host-linked openEuler ELF cannot otherwise start. Physical acceptance checks
the wrapper, `qemu-img`, the Cloudpods `-machine none` QMP query, and a real
`/dev/kvm` process before the RPM is eligible for Pages.

KubeServer itself keeps its required Ceph CGO support. Its native RISC-V link
uses the pinned Alpine `lld20` package from the published
`cloudpods-kube-build` derivative because GNU ld 2.44 crashes while processing
the generated RISC-V relocation stream. The workflow compiles and runs a small
LLD-linked RISC-V ELF before it builds KubeServer, then runs the finished
KubeServer binary again from the final runtime image.

The workflows use the repository-scoped `GITHUB_TOKEN`; no personal access
token is stored in repository secrets.

## Offline image recovery

Public GHCR images can be converted to a checksum-verified OCI archive on a
machine with registry access, then copied to an offline Cloudpods node:

```bash
./scripts/pull-ghcr-to-oci-archive.sh \
  ghcr.io/yinjiayi/cloudpods-web:v4.0.3-riscv64-ui2 \
  cloudpods-web-v4.0.3-riscv64-ui2.oci.tar
sudo ctr -n k8s.io images import cloudpods-web-v4.0.3-riscv64-ui2.oci.tar
```

The downloader uses anonymous GHCR pull tokens and verifies the manifest and
every blob against its SHA-256 digest. It accepts a single-platform OCI or
Docker v2 image manifest; use the architecture-specific tags recorded in the
image lock files.

## Release order

1. Run `Publish Actions Runner RISC-V compatibility asset` once for the pinned
   Runner version, then install and register the RISC-V build runner.
2. Export every pinned native-build source commit, verify
   `source-assets/SHA256SUMS`, and publish them under the source-asset release
   tag recorded in `versions.env`; then run `Publish native-build source assets
   to Pages` so the RISC-V runner uses the resumable Pages mirror. When a
   KVM-validated RPM build is already pinned, this workflow carries that exact
   repository into the same Pages artifact instead of replacing it.
3. Run `Build K3s RISC-V images`.
4. Confirm each new package is Public in GitHub package settings; change it if
   the package did not inherit visibility from the public source repository.
5. Run `scripts/verify-ghcr-public.sh images/k3s-images.lock` without credentials.
6. Tag the K3s fork with `v1.28.5+k3s1-riscv64.4`.
7. Run `Build and publish Cloudpods RISC-V images` on the labelled x86_64 QEMU
   user-mode runner, make any new packages public, and verify
   `images/cloudpods-images.lock` the same way.
   If the build has already produced all final local images but a post-build
   assertion or registry push fails, fix the assertion and push a
   `cloudpods-images-resume-riscv64-*` tag. The recovery workflow checks the
   exact source revision, version, architecture, binaries, and runtime content
   of every cached image before publishing; it never accepts or publishes an
   unverified partial build.
   The same workflow can assemble the pinned resource-only `.5` layer from the
   verified `.4` cache, restores CloudID's nine SAML metadata files from the
   exact Cloudpods source commit, and emits matching KubeServer version
   metadata without recompiling unchanged binaries.
8. Run `Build openEuler RISC-V RPMs` and note its workflow run ID.
9. Download that run's RPM artifact to the physical RISC-V host and run
   `sudo rpm/verify-qemu-kvm-rpm.sh PATH_TO_QEMU_RPM`.
10. Copy `rpm/kvm-validation.env.example` to `rpm/kvm-validation.env`, record the
   original build run ID and emitted `KVM_VALIDATION_SHA256`, commit it, then
   push an `rpm-pages-riscv64-*` tag. The publisher downloads and checks that
   exact artifact, adds the pinned source archives, and deploys the complete
   Pages site atomically; it does not rebuild it. Manual dispatch remains
   available.
   For a wrapper/runtime-only QEMU correction, run
   `rpm/repackage-qemu-runtime-rpm.sh` on the physical host, validate the
   result with `rpm/verify-qemu-kvm-rpm.sh`, publish both RPMs as the release
   named by `rpm/qemu-runtime-hotfix.env`, and record their hashes. The Pages
   workflow overlays only those two pinned packages on the previously
   validated repository and regenerates its metadata and checksums.

The Pages workflows also mirror the four checksum-verified RISC-V K3s release
assets. The `yinjiayi/k3s` GitHub Release remains the provenance source, while
ocboot uses the Pages mirror so installation does not depend on the separate
GitHub release-asset CDN path.
11. Tag the ocboot RISC-V branch, run `Build and publish ocboot RISC-V image`
    on the labelled x86_64 QEMU user-mode runner, then verify its GHCR package
    is public.

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
builds are acceptance tests and run on their respective labelled runners.
