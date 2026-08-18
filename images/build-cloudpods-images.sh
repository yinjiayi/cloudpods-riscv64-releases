#!/usr/bin/env bash
set -Eeuo pipefail

repo_root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
source "${repo_root}/versions.env"

[[ $(uname -m) == riscv64 ]] || {
    echo "this build requires a native riscv64 runner" >&2
    exit 1
}
: "${GITHUB_ACTOR:?GITHUB_ACTOR is required}"
: "${GHCR_TOKEN:?GHCR_TOKEN is required}"
: "${DASHBOARD_DIST_DIR:?DASHBOARD_DIST_DIR is required}"
: "${K3S_RELEASE_DIR:?K3S_RELEASE_DIR is required}"

for command_name in buildah curl file git jq sha256sum skopeo; do
    command -v "${command_name}" >/dev/null 2>&1 || {
        echo "missing command: ${command_name}" >&2
        exit 1
    }
done
[[ -f ${DASHBOARD_DIST_DIR}/index.html ]]
grep -R -q riscv64 "${DASHBOARD_DIST_DIR}/js"
[[ -f ${K3S_RELEASE_DIR}/k3s-riscv64 ]]
[[ -f ${K3S_RELEASE_DIR}/sha256sum-riscv64.txt ]]

work_root=$(mktemp -d "${RUNNER_TEMP:-/tmp}/cloudpods-images.XXXXXX")
source_dir=${work_root}/src
stage_dir=${work_root}/stage
builder_suffix=$$
active_builders=()

cleanup() {
    local builder
    for builder in "${active_builders[@]}"; do
        buildah rm "${builder}" >/dev/null 2>&1 || true
    done
    rm -rf -- "${work_root}"
}
trap cleanup EXIT

install -d -m 0755 "${source_dir}" "${stage_dir}"
printf '%s' "${GHCR_TOKEN}" | buildah login \
    --username "${GITHUB_ACTOR}" --password-stdin ghcr.io

clone_exact() {
    local repository=$1
    local source_ref=$2
    local source_commit=$3
    local source_sha256=$4
    local destination=$5
    local cache_archive
    local cache_dir=${CLOUDPODS_SOURCE_CACHE_DIR:-}
    local repository_path
    local source_archive
    local source_asset
    local source_name
    local source_page_url

    repository_path=${repository#https://github.com/}
    repository_path=${repository_path%.git}
    [[ ${repository_path} != "${repository}" && ${repository_path} == */* ]]
    [[ -n ${source_ref} ]]
    [[ ${source_sha256} =~ ^[0-9a-f]{64}$ ]]
    source_name=$(basename "${repository_path}")
    source_asset=${source_name}-${source_commit}.tar.gz
    source_archive=${work_root}/${source_asset}
    source_page_url=${SOURCE_ASSET_PAGE_BASE_URL}/${source_asset}
    cache_archive=${cache_dir:+${cache_dir}/${source_name}-${source_commit}.tar.gz}
    if [[ -n ${cache_archive} && -f ${cache_archive} ]] && \
        echo "${source_sha256}  ${cache_archive}" | sha256sum --check --status; then
        echo "Using verified source cache: ${cache_archive}"
        install -m 0644 "${cache_archive}" "${source_archive}"
    else
        if ! curl --fail --location --retry 5 --retry-all-errors \
            --continue-at - --connect-timeout 20 --max-time 1800 \
            "${source_page_url}" --output "${source_archive}"; then
            rm -f "${source_archive}"
            curl --fail --location --retry 10 --retry-all-errors \
                --connect-timeout 20 --max-time 600 \
                "https://codeload.github.com/${repository_path}/tar.gz/${source_commit}" \
                --output "${source_archive}"
        fi
    fi
    echo "${source_sha256}  ${source_archive}" | sha256sum --check
    if [[ -n ${cache_archive} ]]; then
        install -d -m 0755 "${cache_dir}"
        install -m 0644 "${source_archive}" "${cache_archive}.tmp.${builder_suffix}"
        mv -f "${cache_archive}.tmp.${builder_suffix}" "${cache_archive}"
    fi
    install -d -m 0755 "${destination}"
    tar -C "${destination}" --strip-components=1 -xzf "${source_archive}"
    rm -f "${source_archive}"
}

extract_cloudpods_source_asset() {
    local destination=$1
    local cache_archive
    local cache_dir=${CLOUDPODS_SOURCE_CACHE_DIR:-}
    local source_archive=${work_root}/${CLOUDPODS_SOURCE_ARCHIVE}
    local source_url=${SOURCE_ASSET_PAGE_BASE_URL}/${CLOUDPODS_SOURCE_ARCHIVE}

    cache_archive=${cache_dir:+${cache_dir}/${CLOUDPODS_SOURCE_ARCHIVE}}
    if [[ -n ${cache_archive} && -f ${cache_archive} ]] && \
        echo "${CLOUDPODS_SOURCE_ARCHIVE_SHA256}  ${cache_archive}" | \
            sha256sum --check --status; then
        echo "Using verified Cloudpods source cache: ${cache_archive}"
        install -m 0644 "${cache_archive}" "${source_archive}"
    else
        curl --fail --location --retry 10 --retry-all-errors \
            --continue-at - --connect-timeout 20 --max-time 1800 \
            "${source_url}" --output "${source_archive}"
    fi
    echo "${CLOUDPODS_SOURCE_ARCHIVE_SHA256}  ${source_archive}" | \
        sha256sum --check
    if [[ -n ${cache_archive} ]]; then
        install -d -m 0755 "${cache_dir}"
        install -m 0644 "${source_archive}" "${cache_archive}.tmp.${builder_suffix}"
        mv -f "${cache_archive}.tmp.${builder_suffix}" "${cache_archive}"
    fi
    install -d -m 0755 "${destination}"
    tar -C "${destination}" --strip-components=1 -xzf "${source_archive}"
    rm -f "${source_archive}"
}

apply_source_patch() {
    local tree=$1
    local patch_file=$2

    git -C "${tree}" apply --check "${patch_file}"
    git -C "${tree}" apply "${patch_file}"
}

mirror_dependencies() {
    local source_image target_image
    while IFS=$'\t' read -r source_image target_image; do
        [[ -n ${source_image} && -n ${target_image} ]]
        [[ ${source_image} != localhost/* ]] || continue
        buildah pull --arch riscv64 "${source_image}"
        [[ $(buildah inspect --format '{{.OCIv1.Architecture}}' "${source_image}") == riscv64 ]]
        buildah tag "${source_image}" "${target_image}"
        buildah push "${target_image}" "docker://${target_image}"
    done < "${repo_root}/images/cloudpods-source-map.tsv"
}

new_builder() {
    local logical_name=$1
    local image=$2
    BUILDER_NAME=${logical_name}-${builder_suffix}

    buildah from --name "${BUILDER_NAME}" "${image}" >/dev/null
    active_builders+=("${BUILDER_NAME}")
}

remove_builder() {
    buildah rm "$1" >/dev/null
}

mirror_dependencies

extract_cloudpods_source_asset "${source_dir}/cloudpods"
clone_exact \
    https://github.com/yinjiayi/cloudpods-operator.git \
    "${ONECLOUD_OPERATOR_SOURCE_REF}" "${ONECLOUD_OPERATOR_SOURCE_COMMIT}" \
    "${ONECLOUD_OPERATOR_SOURCE_ARCHIVE_SHA256}" \
    "${source_dir}/onecloud-operator"
clone_exact \
    https://github.com/yunionio/kubecomps.git \
    "${KUBECOMPS_SOURCE_REF}" "${KUBECOMPS_SOURCE_COMMIT}" \
    "${KUBECOMPS_SOURCE_ARCHIVE_SHA256}" \
    "${source_dir}/kubecomps"
clone_exact \
    https://github.com/zexi/kubespray.git \
    "${KUBESPRAY_LEGACY_SOURCE_COMMIT}" "${KUBESPRAY_LEGACY_SOURCE_COMMIT}" \
    "${KUBESPRAY_LEGACY_SOURCE_ARCHIVE_SHA256}" \
    "${source_dir}/kubecomps/manifests/ansible/kubespray"
clone_exact \
    https://github.com/zexi/kubespray.git \
    "${KUBESPRAY_2_17_SOURCE_COMMIT}" "${KUBESPRAY_2_17_SOURCE_COMMIT}" \
    "${KUBESPRAY_2_17_SOURCE_ARCHIVE_SHA256}" \
    "${source_dir}/kubecomps/manifests/ansible/kubespray_2_17_0"
clone_exact \
    https://github.com/zexi/kubespray.git \
    "${KUBESPRAY_2_19_SOURCE_COMMIT}" "${KUBESPRAY_2_19_SOURCE_COMMIT}" \
    "${KUBESPRAY_2_19_SOURCE_ARCHIVE_SHA256}" \
    "${source_dir}/kubecomps/manifests/ansible/kubespray_2_19_1"
clone_exact \
    https://github.com/yunionio/sdnagent.git \
    "${SDNAGENT_SOURCE_REF}" "${SDNAGENT_SOURCE_COMMIT}" \
    "${SDNAGENT_SOURCE_ARCHIVE_SHA256}" \
    "${source_dir}/sdnagent"

apply_source_patch \
    "${source_dir}/cloudpods" \
    "${repo_root}/rpm/SOURCES/cloudpods-executor-parse-flags.patch"
apply_source_patch \
    "${source_dir}/onecloud-operator" \
    "${repo_root}/images/patches/onecloud-operator-disable-probe-kubelet.patch"

builder_image=${GHCR_NAMESPACE}/cloudpods-alpine-build:3.22.2-go-1.24.9-0-riscv64.1

new_builder cloudpods-operator-builder "${builder_image}"
operator_builder=${BUILDER_NAME}
buildah run \
    --env GOPROXY=https://goproxy.cn,direct \
    --volume "${source_dir}/onecloud-operator:/src:rw" \
    "${operator_builder}" -- \
    sh -ec 'cd /src; install -d _output/alpine-build/bin; make VERSION=v4.0.3 GOARCH=riscv64 BIN_DIR=/src/_output/alpine-build/bin onecloud-operator; test -x _output/alpine-build/bin/onecloud-controller-manager'
remove_builder "${operator_builder}"

helm_packager_image=${GHCR_NAMESPACE}/cloudpods-helm:v4.0.0-1-riscv64.1
new_builder kubecomps-helm-packager "${helm_packager_image}"
helm_packager=${BUILDER_NAME}
buildah run \
    --volume "${source_dir}/kubecomps:/src:rw" \
    "${helm_packager}" -- \
    /bin/bash -ec 'cd /src; ./scripts/embed-helm-pkgs.sh; test -f static/monitor-stack-8.12.13.tgz; test -f static/minio-8.0.6.tgz; test -f static/linux-server_rev1.json'
remove_builder "${helm_packager}"

kube_builder_image=${GHCR_NAMESPACE}/cloudpods-kube-build:3.22.2-go-1.24.9-0-riscv64.1
new_builder kubeserver-builder "${kube_builder_image}"
kubeserver_builder=${BUILDER_NAME}
buildah run \
    --env GOPROXY=https://goproxy.cn,direct \
    --volume "${source_dir}/kubecomps:/src:rw" \
    "${kubeserver_builder}" -- \
    sh -ec "cd /src; go generate -mod vendor ./pkg/kubeserver/embed; install -d _output/alpine-build/bin; make GOARCH=riscv64 BIN_DIR=/src/_output/alpine-build/bin GIT_BRANCH=${KUBECOMPS_SOURCE_REF} GIT_COMMIT=${KUBECOMPS_SOURCE_COMMIT} GIT_VERSION=v4.0.3 GIT_TREE_STATE=clean BUILD_DATE=${KUBECOMPS_SOURCE_DATE} cmd/kubeserver; test -x _output/alpine-build/bin/kubeserver"
remove_builder "${kubeserver_builder}"

new_builder cloudpods-core-builder "${builder_image}"
cloudpods_builder=${BUILDER_NAME}
cloudpods_binaries=(
    ansibleserver
    apigateway
    baremetal-agent
    climc
    cloudevent
    cloudid
    cloudmon
    cloudnet
    cloudproxy
    devtool
    esxi-agent
    executor-server
    glance
    host
    host-deployer
    keystone
    lbagent
    llm
    logger
    mcp-server
    monitor
    notify
    region
    region-dns
    scheduledtask
    scheduler
    torrent
    vpcagent
    webconsole
    yunionconf
)
cloudpods_binary_list=${cloudpods_binaries[*]}
buildah run \
    --env GOPROXY=https://goproxy.cn,direct \
    --env "CLOUDPODS_BINARIES=${cloudpods_binary_list}" \
    --volume "${source_dir}/cloudpods:/src:rw" \
    "${cloudpods_builder}" -- \
    sh -ec "cd /src; install -d _output/alpine-build/bin; targets=; for binary in \${CLOUDPODS_BINARIES}; do targets=\"\${targets} cmd/\${binary}\"; done; make -j\$(nproc) ONECLOUD_CI_BUILD=1 GIT_VERSION=v4.0.3 GIT_COMMIT=${CLOUDPODS_SOURCE_COMMIT} GIT_BRANCH=${CLOUDPODS_SOURCE_REF} GIT_TREE_STATE=dirty BIN_DIR=/src/_output/alpine-build/bin \${targets}; for binary in \${CLOUDPODS_BINARIES}; do test -x \"_output/alpine-build/bin/\${binary}\"; done"
remove_builder "${cloudpods_builder}"

new_builder cloudpods-sdn-builder "${builder_image}"
sdn_builder=${BUILDER_NAME}
buildah run \
    --env GOPROXY=https://goproxy.cn,direct \
    --volume "${source_dir}/sdnagent:/src:rw" \
    "${sdn_builder}" -- \
    sh -ec 'cd /src; install -d _output/alpine-build/bin; GOOS=linux GOARCH=riscv64 CGO_ENABLED=0 go build -mod vendor -trimpath -o _output/alpine-build/bin/sdnagent ./cmd/sdnagent; GOOS=linux GOARCH=riscv64 CGO_ENABLED=0 go build -mod vendor -trimpath -o _output/alpine-build/bin/sdncli ./cmd/sdncli'
remove_builder "${sdn_builder}"

cp "${K3S_RELEASE_DIR}/k3s-riscv64" "${work_root}/k3s-riscv64"
cp "${K3S_RELEASE_DIR}/sha256sum-riscv64.txt" \
    "${work_root}/sha256sum-riscv64.txt"
k3s_sha256=$(awk '$2 == "k3s-riscv64" || $2 == "*k3s-riscv64" {print $1}' \
    "${work_root}/sha256sum-riscv64.txt")
[[ ${k3s_sha256} =~ ^[0-9a-f]{64}$ ]]
printf '%s  %s\n' "${k3s_sha256}" "${work_root}/k3s-riscv64" | sha256sum --check
chmod 0755 "${work_root}/k3s-riscv64"

cloudpods_stage=${stage_dir}/cloudpods
operator_stage=${stage_dir}/operator
web_stage=${stage_dir}/web
kubeserver_stage=${stage_dir}/kubeserver
install -d -m 0755 \
    "${cloudpods_stage}/rootfs/opt/yunion/bin" \
    "${cloudpods_stage}/rootfs/usr/bin" \
    "${operator_stage}/rootfs/bin" \
    "${web_stage}/dist" \
    "${kubeserver_stage}/rootfs/opt/yunion/ansible" \
    "${kubeserver_stage}/rootfs/opt/yunion/bin" \
    "${kubeserver_stage}/rootfs/usr/bin"

cp "${source_dir}/cloudpods/_output/alpine-build/bin/"* \
    "${cloudpods_stage}/rootfs/opt/yunion/bin/"
install -m 0755 \
    "${source_dir}/sdnagent/_output/alpine-build/bin/sdnagent" \
    "${source_dir}/sdnagent/_output/alpine-build/bin/sdncli" \
    "${cloudpods_stage}/rootfs/opt/yunion/bin/"
install -m 0755 "${work_root}/k3s-riscv64" \
    "${cloudpods_stage}/rootfs/usr/bin/kubectl"
install -m 0755 "${work_root}/k3s-riscv64" \
    "${kubeserver_stage}/rootfs/usr/bin/kubectl"
install -m 0755 \
    "${source_dir}/kubecomps/_output/alpine-build/bin/kubeserver" \
    "${kubeserver_stage}/rootfs/opt/yunion/bin/kubeserver"
cp -a "${source_dir}/kubecomps/manifests/ansible/." \
    "${kubeserver_stage}/rootfs/opt/yunion/ansible/"
cp -a "${source_dir}/cloudpods/build/region/root/opt/." \
    "${cloudpods_stage}/rootfs/opt/"
cp -a "${source_dir}/cloudpods/build/climc/root/opt/." \
    "${cloudpods_stage}/rootfs/opt/"
cp -a "${source_dir}/cloudpods/build/monitor/root/opt/." \
    "${cloudpods_stage}/rootfs/opt/"
cp -a "${source_dir}/cloudpods/build/notify/root/opt/." \
    "${cloudpods_stage}/rootfs/opt/"
rm -f "${cloudpods_stage}/rootfs/opt/yunion/share/sqlite/inet.so"
install -m 0755 \
    "${source_dir}/onecloud-operator/_output/alpine-build/bin/onecloud-controller-manager" \
    "${operator_stage}/rootfs/bin/onecloud-controller-manager"
cp -a "${DASHBOARD_DIST_DIR}/." "${web_stage}/dist/"

cloudpods_image=localhost/cloudpods/cloudpods:${CLOUDPODS_IMAGE_VERSION}
operator_image=localhost/cloudpods/onecloud-operator:${ONECLOUD_OPERATOR_IMAGE_VERSION}
web_image=localhost/cloudpods/web:${CLOUDPODS_WEB_IMAGE_VERSION}
etcd_image=localhost/cloudpods/etcd:3.5.24
kubeserver_image=localhost/cloudpods/kubeserver:${KUBESERVER_IMAGE_VERSION}

buildah bud --arch riscv64 --layers \
    --build-arg "SOURCE_COMMIT=${CLOUDPODS_SOURCE_COMMIT}" \
    --build-arg "VERSION=${CLOUDPODS_IMAGE_VERSION}" \
    --tag "${cloudpods_image}" \
    --file "${repo_root}/images/Containerfile.cloudpods" \
    "${cloudpods_stage}"
buildah bud --arch riscv64 --layers \
    --build-arg "SOURCE_COMMIT=${ONECLOUD_OPERATOR_SOURCE_COMMIT}" \
    --build-arg "VERSION=${ONECLOUD_OPERATOR_IMAGE_VERSION}" \
    --tag "${operator_image}" \
    --file "${repo_root}/images/Containerfile.onecloud-operator" \
    "${operator_stage}"
buildah bud --arch riscv64 --layers \
    --build-arg "SOURCE_COMMIT=${DASHBOARD_SOURCE_COMMIT}" \
    --build-arg "VERSION=${CLOUDPODS_WEB_IMAGE_VERSION}" \
    --tag "${web_image}" \
    --file "${repo_root}/images/Containerfile.web" \
    "${web_stage}"
buildah bud --arch riscv64 --layers \
    --build-arg "BASE_IMAGE=${GHCR_NAMESPACE}/cloudpods-onecloud-base:v3.22.2-0-riscv64.1" \
    --build-arg "SOURCE_COMMIT=${KUBECOMPS_SOURCE_COMMIT}" \
    --build-arg "VERSION=${KUBESERVER_IMAGE_VERSION}" \
    --tag "${kubeserver_image}" \
    --file "${repo_root}/images/Containerfile.kubeserver" \
    "${kubeserver_stage}"
buildah tag "${cloudpods_image}" "${etcd_image}"

for image in "${cloudpods_image}" "${operator_image}" "${web_image}" \
    "${etcd_image}" "${kubeserver_image}"; do
    [[ $(buildah inspect --format '{{.OCIv1.Architecture}}' "${image}") == riscv64 ]]
done

new_builder cloudpods-image-verifier "${cloudpods_image}"
verify_builder=${BUILDER_NAME}
buildah run --env "CLOUDPODS_BINARIES=${cloudpods_binary_list}" \
    "${verify_builder}" -- sh -ec '
    test "$(uname -m)" = riscv64
    test "$(etcd --version | awk "/etcd Version/{print \$3}")" = 3.5.24
    for binary in qemu-system-riscv64 qemu-img ovs-vsctl etcd etcdctl kubectl; do command -v "${binary}"; done
    for binary in ${CLOUDPODS_BINARIES} sdnagent sdncli; do test -x "/opt/yunion/bin/${binary}"; done
    test -d /opt/yunion/share/template/title@cn
    test -d /opt/yunion/share/local-templates/content@cn
    kubectl version --client=true
'
remove_builder "${verify_builder}"

new_builder kubeserver-image-verifier "${kubeserver_image}"
kubeserver_verifier=${BUILDER_NAME}
buildah run "${kubeserver_verifier}" -- sh -ec '
    test "$(uname -m)" = riscv64
    test -x /opt/yunion/bin/kubeserver
    test -L /opt/yunion/bin/kube-server
    test -f /opt/yunion/ansible/ansible.cfg
    command -v ansible-playbook
    command -v kubectl
    ansible-playbook --version
    kubectl version --client=true
    /opt/yunion/bin/kubeserver --help >/dev/null
'
remove_builder "${kubeserver_verifier}"

new_builder cloudpods-operator-verifier "${operator_image}"
operator_verifier=${BUILDER_NAME}
buildah run "${operator_verifier}" -- /bin/onecloud-controller-manager --help >/dev/null
remove_builder "${operator_verifier}"

new_builder cloudpods-web-verifier "${web_image}"
web_verifier=${BUILDER_NAME}
buildah run "${web_verifier}" -- \
    sh -ec 'test -f /usr/share/nginx/html/web/index.html; grep -R -q riscv64 /usr/share/nginx/html/web/js'
remove_builder "${web_verifier}"

"${repo_root}/images/publish-cloudpods-images.sh"
