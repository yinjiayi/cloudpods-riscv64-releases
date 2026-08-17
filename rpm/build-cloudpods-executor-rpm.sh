#!/usr/bin/env bash
set -Eeuo pipefail

repo_root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
source "${repo_root}/versions.env"
[[ $(uname -m) == riscv64 ]]

work_root=$(mktemp -d "${RUNNER_TEMP:-/tmp}/cloudpods-executor-rpm.XXXXXX")
trap 'buildah rm cloudpods-executor-builder >/dev/null 2>&1 || true; rm -rf -- "${work_root}"' EXIT
source_dir=${work_root}/cloudpods
rpmbuild_root=${work_root}/rpmbuild
output_dir=${repo_root}/dist/rpm/riscv64
builder_image=${GHCR_NAMESPACE}/cloudpods-alpine-build:3.22.2-go-1.24.9-0-riscv64.1

source_archive=${work_root}/${CLOUDPODS_SOURCE_ARCHIVE}
source_url=${SOURCE_ASSET_PAGE_BASE_URL}/${CLOUDPODS_SOURCE_ARCHIVE}
source_cache=${CLOUDPODS_SOURCE_CACHE_DIR:-}
if [[ -n ${source_cache} && -f ${source_cache}/${CLOUDPODS_SOURCE_ARCHIVE} ]] && \
    echo "${CLOUDPODS_SOURCE_ARCHIVE_SHA256}  ${source_cache}/${CLOUDPODS_SOURCE_ARCHIVE}" | \
        sha256sum --check --status; then
    echo "Using verified Cloudpods source cache: ${source_cache}/${CLOUDPODS_SOURCE_ARCHIVE}"
    install -m 0644 \
        "${source_cache}/${CLOUDPODS_SOURCE_ARCHIVE}" \
        "${source_archive}"
else
    curl --fail --location --retry 10 --retry-all-errors \
        --continue-at - --connect-timeout 20 --max-time 1800 \
        "${source_url}" \
        --output "${source_archive}"
fi
echo "${CLOUDPODS_SOURCE_ARCHIVE_SHA256}  ${source_archive}" | \
    sha256sum --check
if [[ -n ${source_cache} ]]; then
    install -d -m 0755 "${source_cache}"
    cache_tmp=$(mktemp "${source_cache}/.${CLOUDPODS_SOURCE_ARCHIVE}.XXXXXX")
    install -m 0644 "${source_archive}" "${cache_tmp}"
    mv "${cache_tmp}" "${source_cache}/${CLOUDPODS_SOURCE_ARCHIVE}"
fi
install -d -m 0755 "${source_dir}"
tar -C "${source_dir}" --strip-components=1 -xzf "${source_archive}"
git -C "${source_dir}" apply \
    "${repo_root}/rpm/SOURCES/cloudpods-executor-parse-flags.patch"

buildah rm cloudpods-executor-builder >/dev/null 2>&1 || true
for attempt in {1..5}; do
    if buildah from --name cloudpods-executor-builder "${builder_image}" >/dev/null; then
        break
    fi
    buildah rm cloudpods-executor-builder >/dev/null 2>&1 || true
    if (( attempt == 5 )); then
        echo "failed to pull ${builder_image} after ${attempt} attempts" >&2
        exit 1
    fi
    sleep $(( attempt * 2 ))
done
buildah run \
    --env GOPROXY=https://goproxy.cn,direct \
    --volume "${source_dir}:/src:rw" \
    cloudpods-executor-builder -- \
    sh -ec 'cd /src; install -d _output/alpine-build/bin; make ONECLOUD_CI_BUILD=1 GIT_VERSION=v4.0.3 GIT_BRANCH=release/4.0.3 GIT_TREE_STATE=dirty BIN_DIR=/src/_output/alpine-build/bin cmd/executor-server cmd/climc'
buildah rm cloudpods-executor-builder >/dev/null
executor=${source_dir}/_output/alpine-build/bin/executor-server
climc=${source_dir}/_output/alpine-build/bin/climc
[[ -x ${executor} && -x ${climc} ]]
file "${executor}" | grep -F 'UCB RISC-V'
file "${executor}" | grep -F 'statically linked'
file "${climc}" | grep -F 'UCB RISC-V'
file "${climc}" | grep -F 'statically linked'
"${executor}" --help 2>&1 | grep -F -- '-socket-path'

install -d -m 0755 \
    "${rpmbuild_root}"/{BUILD,BUILDROOT,RPMS,SOURCES,SPECS,SRPMS} \
    "${output_dir}"
install -m 0755 "${executor}" "${rpmbuild_root}/SOURCES/executor-server"
install -m 0755 "${climc}" "${rpmbuild_root}/SOURCES/climc"
install -m 0644 "${repo_root}/rpm/SOURCES/cloudpods-executor.service" "${rpmbuild_root}/SOURCES/"
install -m 0644 "${repo_root}/rpm/SPECS/cloudpods-executor.spec" "${rpmbuild_root}/SPECS/"
rpmbuild --define "_topdir ${rpmbuild_root}" -ba \
    "${rpmbuild_root}/SPECS/cloudpods-executor.spec"

install -m 0644 "${rpmbuild_root}/RPMS/riscv64/"*.rpm "${output_dir}/"
install -m 0644 "${rpmbuild_root}/SRPMS/"*.src.rpm "${output_dir}/"
