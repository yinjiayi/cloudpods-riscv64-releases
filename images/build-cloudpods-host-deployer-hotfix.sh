#!/usr/bin/env bash
set -Eeuo pipefail

repo_root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
source "${repo_root}/versions.env"

[[ $(uname -m) == x86_64 ]]
[[ ${QEMU_USER_RISCV64:-0} == 1 ]]
binfmt_file=/proc/sys/fs/binfmt_misc/qemu-riscv64
[[ -r ${binfmt_file} ]]
grep -qx enabled "${binfmt_file}"

for command_name in buildah curl file grep jq sha256sum skopeo tar; do
    command -v "${command_name}" >/dev/null 2>&1 || {
        echo "missing command: ${command_name}" >&2
        exit 1
    }
done
: "${GITHUB_ACTOR:?GITHUB_ACTOR is required}"
: "${GHCR_TOKEN:?GHCR_TOKEN is required}"

work_root=$(mktemp -d "${RUNNER_TEMP:-/tmp}/cloudpods-host-deployer.XXXXXX")
source_archive=${work_root}/${CLOUDPODS_SOURCE_ARCHIVE}
source_dir=${work_root}/src
stage_dir=${work_root}/stage
builder=cloudpods-host-deployer-builder-$$
verifier=cloudpods-host-deployer-verifier-$$

cleanup() {
    buildah rm "${builder}" "${verifier}" >/dev/null 2>&1 || true
    rm -rf -- "${work_root}"
}
trap cleanup EXIT

install -d -m 0755 "${source_dir}" "${stage_dir}"
cache_archive=${CLOUDPODS_SOURCE_CACHE_DIR:-/var/cache/cloudpods-build}/${CLOUDPODS_SOURCE_ARCHIVE}
if [[ -f ${cache_archive} ]] && \
    echo "${CLOUDPODS_SOURCE_ARCHIVE_SHA256}  ${cache_archive}" | \
        sha256sum --check --status; then
    echo "Using verified source cache: ${cache_archive}"
    install -m 0644 "${cache_archive}" "${source_archive}"
else
    pages_url=${SOURCE_ASSET_PAGE_BASE_URL}/${CLOUDPODS_SOURCE_ARCHIVE}
    release_url=https://github.com/yinjiayi/cloudpods-riscv64-releases/releases/download/${CLOUDPODS_SOURCE_ASSET_TAG}/${CLOUDPODS_SOURCE_ARCHIVE}
    if ! curl --fail --location --retry 10 --retry-all-errors \
        --connect-timeout 20 --max-time 1800 \
        "${pages_url}" --output "${source_archive}"; then
        rm -f "${source_archive}"
        curl --fail --location --retry 10 --retry-all-errors \
            --connect-timeout 20 --max-time 900 \
            "${release_url}" --output "${source_archive}"
    fi
    echo "${CLOUDPODS_SOURCE_ARCHIVE_SHA256}  ${source_archive}" | \
        sha256sum --check
    install -d -m 0755 "$(dirname "${cache_archive}")"
    install -m 0644 "${source_archive}" "${cache_archive}.tmp.$$"
    mv -f "${cache_archive}.tmp.$$" "${cache_archive}"
fi
echo "${CLOUDPODS_SOURCE_ARCHIVE_SHA256}  ${source_archive}" | sha256sum --check
tar -C "${source_dir}" --strip-components=1 -xzf "${source_archive}"

printf '%s' "${GHCR_TOKEN}" | buildah login ghcr.io \
    --username "${GITHUB_ACTOR}" --password-stdin
builder_image=${GHCR_NAMESPACE}/cloudpods-alpine-build:3.22.2-go-1.24.9-0-riscv64.1
buildah pull --arch riscv64 "${builder_image}"
buildah from --name "${builder}" "${builder_image}" >/dev/null
buildah run \
    --env GOPROXY=https://goproxy.cn,direct \
    --env GOFLAGS=-p=8 \
    --env GOMAXPROCS=1 \
    --volume "${source_dir}:/src:rw" \
    "${builder}" -- \
    sh -ec "cd /src; install -d _output/alpine-build/bin; make -j1 ONECLOUD_CI_BUILD=1 GIT_VERSION=v4.0.3 GIT_COMMIT=${CLOUDPODS_SOURCE_COMMIT} GIT_BRANCH=${CLOUDPODS_SOURCE_REF} GIT_TREE_STATE=clean BIN_DIR=/src/_output/alpine-build/bin cmd/host-deployer; test -x _output/alpine-build/bin/host-deployer"

install -m 0755 \
    "${source_dir}/_output/alpine-build/bin/host-deployer" \
    "${stage_dir}/host-deployer"
file "${stage_dir}/host-deployer" | grep -F 'UCB RISC-V'
grep -aFq '/usr/lib/rpm/openruyi' "${stage_dir}/host-deployer"
grep -aFq 'OpenRuyiRootFs' "${stage_dir}/host-deployer"

base_image=${GHCR_NAMESPACE}/cloudpods:${CLOUDPODS_IMAGE_BASE_VERSION}
cloudpods_image=localhost/cloudpods/cloudpods:${CLOUDPODS_IMAGE_VERSION}
buildah pull --arch riscv64 "${base_image}"
buildah bud --arch riscv64 --layers \
    --build-arg "BASE_IMAGE=${base_image}" \
    --build-arg "SOURCE_COMMIT=${CLOUDPODS_SOURCE_COMMIT}" \
    --build-arg "VERSION=${CLOUDPODS_IMAGE_VERSION}" \
    --tag "${cloudpods_image}" \
    --file "${repo_root}/images/Containerfile.cloudpods-host-deployer-hotfix" \
    "${stage_dir}"

[[ $(buildah inspect --format '{{.OCIv1.Architecture}}' \
    "${cloudpods_image}") == riscv64 ]]
[[ $(buildah inspect --format \
    '{{ index .OCIv1.Config.Labels "org.opencontainers.image.revision" }}' \
    "${cloudpods_image}") == "${CLOUDPODS_SOURCE_COMMIT}" ]]
[[ $(buildah inspect --format \
    '{{ index .OCIv1.Config.Labels "org.opencontainers.image.version" }}' \
    "${cloudpods_image}") == "${CLOUDPODS_IMAGE_VERSION}" ]]

buildah from --name "${verifier}" "${cloudpods_image}" >/dev/null
buildah run "${verifier}" -- sh -ec '
    test "$(uname -m)" = riscv64
    test -x /opt/yunion/bin/host-deployer
    grep -aFq /usr/lib/rpm/openruyi /opt/yunion/bin/host-deployer
    grep -aFq OpenRuyiRootFs /opt/yunion/bin/host-deployer
    test -x /opt/yunion/bin/host
    test -x /opt/yunion/bin/region
    test -d /opt/yunion/share/template/title@cn
    test -f /opt/yunion/share/saml/sp-metadata/gcp.xml
'

published=0
while IFS=$'\t' read -r source_image target_image; do
    [[ ${source_image} == "${cloudpods_image}" ]] || continue
    buildah tag "${cloudpods_image}" "${target_image}"
    buildah push "${target_image}" "docker://${target_image}"
    metadata=$(skopeo inspect --override-os linux --override-arch riscv64 \
        "docker://${target_image}")
    [[ $(jq -r .Architecture <<<"${metadata}") == riscv64 ]]
    [[ $(jq -r '.Labels["org.opencontainers.image.revision"]' \
        <<<"${metadata}") == "${CLOUDPODS_SOURCE_COMMIT}" ]]
    published=$((published + 1))
done < "${repo_root}/images/cloudpods-source-map.tsv"
[[ ${published} -eq 5 ]]

echo "Published Cloudpods RISC-V host-deployer hotfix to ${published} image names."
