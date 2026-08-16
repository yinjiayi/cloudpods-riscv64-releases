#!/usr/bin/env bash
set -Eeuo pipefail

repo_root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
exec "${repo_root}/scripts/write-image-digests.sh" \
    "${repo_root}/images/k3s-images.lock" \
    "${repo_root}/dist/k3s-images-riscv64.digests" \
    riscv64
