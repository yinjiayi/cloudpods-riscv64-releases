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

The complete version and provenance lock is in `versions.env`. Workflows run
only on a native self-hosted RISC-V runner labelled
`openeuler-24.03-riscv64`, except for the cross-compiled K3s binary in the K3s
fork.

## Required runner

The native runner must provide:

- openEuler 24.03 LTS SP3 on `riscv64`
- Buildah, Skopeo, Git, RPM build tools, createrepo_c, GPG, GCC and Ninja
- at least 16 GiB RAM and 60 GiB free disk
- `/dev/kvm` for the QEMU smoke test

The workflows use the repository-scoped `GITHUB_TOKEN`; no personal access
token is stored in repository secrets.

## Release order

1. Run `Build K3s RISC-V images`.
2. In each new package's GitHub package settings, change visibility to Public.
3. Run `scripts/verify-ghcr-public.sh images/k3s-images.lock` without credentials.
4. Tag the K3s fork with `v1.28.5+k3s1-riscv64.1`.
5. Run `Build and publish Cloudpods RISC-V images`, make any new packages
   public, and verify `images/cloudpods-images.lock` the same way.
6. Run `Build and publish openEuler RISC-V RPMs`.
7. Tag and publish the ocboot RISC-V branch, then make its GHCR package public.

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
