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
| K3s system images | `ghcr.io/yinjiayi/k3s-*` |
| Cloudpods runtime images | `ghcr.io/yinjiayi/*` |
| openEuler RISC-V RPMs | `yinjiayi.github.io/cloudpods-riscv64-releases/rpm/openEuler/24.03-LTS-SP3/riscv64/` |

The complete version and provenance lock is in `versions.env`. Build commands
run natively on a self-hosted RISC-V machine labelled
`openeuler-24.03-riscv64`, except for the cross-compiled K3s binary in the K3s
fork.

## Required runner

The native runner must provide:

- openEuler 24.03 LTS SP3 on `riscv64`
- Buildah, Skopeo, Git, RPM build tools, createrepo_c, GPG, GCC and Ninja
- at least 16 GiB RAM and 60 GiB free disk

GitHub does not publish a native RISC-V Actions Runner. On a dedicated build
machine, install the pinned official x64 Runner control process with:

```bash
sudo ./scripts/install-riscv64-actions-runner-runtime.sh
```

The installer builds only QEMU `x86_64-linux-user`, verifies the signed Ubuntu
22.04 OCI root filesystem, adds the pinned ICU runtime, and registers a binfmt
handler. Runner and JavaScript action control processes are emulated; workflow
shell commands and all actual builds remain native `riscv64`.

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

1. Run `Build K3s RISC-V images`.
2. In each new package's GitHub package settings, change visibility to Public.
3. Run `scripts/verify-ghcr-public.sh images/k3s-images.lock` without credentials.
4. Tag the K3s fork with `v1.28.5+k3s1-riscv64.1`.
5. Run `Build and publish Cloudpods RISC-V images`, make any new packages
   public, and verify `images/cloudpods-images.lock` the same way.
6. Run `Build openEuler RISC-V RPMs` and note its workflow run ID.
7. Download that run's RPM artifact to the physical RISC-V host and run
   `sudo rpm/verify-qemu-kvm-rpm.sh PATH_TO_QEMU_RPM`.
8. Run `Publish KVM-validated RISC-V RPMs to Pages` with the original build run
   ID and the emitted `KVM_VALIDATION_SHA256`. The publisher downloads and
   checks that exact artifact; it does not rebuild it.
9. Tag and publish the ocboot RISC-V branch, then make its GHCR package public.

GitHub creates a newly published personal-account GHCR package as private.
Changing it to public is a one-time GitHub UI action and cannot be performed by
the documented Packages REST API. Later versions keep the package visibility.

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
