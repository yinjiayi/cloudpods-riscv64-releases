#!/usr/bin/env bash
set -Eeuo pipefail

repo_root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
source "${repo_root}/versions.env"

host_arch=$(uname -m)
case "${host_arch}" in
    riscv64)
        ;;
    x86_64)
        [[ ${QEMU_USER_RISCV64:-0} == 1 ]]
        binfmt_file=/proc/sys/fs/binfmt_misc/qemu-riscv64
        [[ -r ${binfmt_file} ]]
        grep -qx enabled "${binfmt_file}"
        ;;
    *)
        echo "unsupported verification host architecture: ${host_arch}" >&2
        exit 1
        ;;
esac

for command_name in buildah grep mapfile; do
    command -v "${command_name}" >/dev/null 2>&1 || {
        echo "missing command: ${command_name}" >&2
        exit 1
    }
done

cloudpods_image=localhost/cloudpods/cloudpods:${CLOUDPODS_IMAGE_VERSION}
operator_image=localhost/cloudpods/onecloud-operator:${ONECLOUD_OPERATOR_IMAGE_VERSION}
web_image=localhost/cloudpods/web:${CLOUDPODS_WEB_IMAGE_VERSION}
etcd_image=localhost/cloudpods/etcd:3.5.24
kubeserver_image=localhost/cloudpods/kubeserver:${KUBESERVER_IMAGE_VERSION}
kube_builder_image=localhost/cloudpods/cloudpods-kube-build:${CLOUDPODS_KUBE_BUILD_IMAGE_VERSION}

assert_metadata() {
    local image=$1
    local expected_revision=$2
    local expected_version=$3
    local actual_arch actual_revision actual_version

    buildah inspect "${image}" >/dev/null
    actual_arch=$(buildah inspect --format '{{.OCIv1.Architecture}}' "${image}")
    actual_revision=$(buildah inspect --format \
        '{{ index .OCIv1.Config.Labels "org.opencontainers.image.revision" }}' \
        "${image}")
    actual_version=$(buildah inspect --format \
        '{{ index .OCIv1.Config.Labels "org.opencontainers.image.version" }}' \
        "${image}")
    [[ ${actual_arch} == riscv64 ]]
    [[ ${actual_revision} == "${expected_revision}" ]]
    [[ ${actual_version} == "${expected_version}" ]]
}

assert_metadata "${cloudpods_image}" \
    "${CLOUDPODS_SOURCE_COMMIT}" "${CLOUDPODS_IMAGE_VERSION}"
assert_metadata "${etcd_image}" \
    "${CLOUDPODS_SOURCE_COMMIT}" "${CLOUDPODS_IMAGE_VERSION}"
assert_metadata "${operator_image}" \
    "${ONECLOUD_OPERATOR_SOURCE_COMMIT}" "${ONECLOUD_OPERATOR_IMAGE_VERSION}"
assert_metadata "${web_image}" \
    "${DASHBOARD_SOURCE_COMMIT}" "${CLOUDPODS_WEB_IMAGE_VERSION}"
assert_metadata "${kubeserver_image}" \
    "${KUBECOMPS_SOURCE_COMMIT}" "${KUBESERVER_IMAGE_VERSION}"
[[ $(buildah inspect --format '{{.OCIv1.Architecture}}' \
    "${kube_builder_image}") == riscv64 ]]

mapfile -t cloudpods_binaries < "${repo_root}/images/cloudpods-binaries.txt"
[[ ${#cloudpods_binaries[@]} -eq 30 ]]
cloudpods_binary_list=${cloudpods_binaries[*]}

builder_suffix=$$
active_builders=()
cleanup() {
    local builder
    for builder in "${active_builders[@]}"; do
        buildah rm "${builder}" >/dev/null 2>&1 || true
    done
}
trap cleanup EXIT

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

new_builder cached-cloudpods-verifier "${cloudpods_image}"
cloudpods_verifier=${BUILDER_NAME}
buildah run --env "CLOUDPODS_BINARIES=${cloudpods_binary_list}" \
    "${cloudpods_verifier}" -- sh -ec '
    test "$(uname -m)" = riscv64
    test "$(etcd --version | awk "/etcd Version/{print \$3}")" = 3.5.24
    for binary in qemu-system-riscv64 qemu-img ovs-vsctl etcd etcdctl kubectl; do
        command -v "${binary}"
    done
    for binary in ${CLOUDPODS_BINARIES} sdnagent sdncli; do
        test -x "/opt/yunion/bin/${binary}"
    done
    test -d /opt/yunion/share/template/title@cn
    test -d /opt/yunion/share/local-templates/content@cn
    test "$(find /opt/yunion/share/saml/sp-metadata -maxdepth 1 -type f -name "*.xml" | wc -l)" -eq 9
    test -f /opt/yunion/share/saml/sp-metadata/gcp.xml
    kubectl version --client=true
'
remove_builder "${cloudpods_verifier}"

new_builder cached-kubeserver-verifier "${kubeserver_image}"
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
    version_output=$(/opt/yunion/bin/kubeserver --version 2>&1)
    printf "%s\n" "${version_output}" | grep -F gitVersion | grep -F v4.0.3
    printf "%s\n" "${version_output}" | grep -F platform | grep -F linux/riscv64
'
remove_builder "${kubeserver_verifier}"

new_builder cached-operator-verifier "${operator_image}"
operator_verifier=${BUILDER_NAME}
buildah run "${operator_verifier}" -- \
    /bin/onecloud-controller-manager --help >/dev/null
remove_builder "${operator_verifier}"

new_builder cached-web-verifier "${web_image}"
web_verifier=${BUILDER_NAME}
buildah run "${web_verifier}" -- sh -ec \
    'test -f /usr/share/nginx/html/web/index.html; grep -R -q riscv64 /usr/share/nginx/html/web/js'
remove_builder "${web_verifier}"

new_builder cached-kube-builder-verifier "${kube_builder_image}"
kube_builder_verifier=${BUILDER_NAME}
buildah run "${kube_builder_verifier}" -- sh -ec '
    test "$(uname -m)" = riscv64
    ld.lld --version | grep -F "LLD 20.1.8"
    printf "int main(void) { return 0; }\n" >/tmp/lld-smoke.c
    gcc -fuse-ld=lld /tmp/lld-smoke.c -o /tmp/lld-smoke
    /tmp/lld-smoke
'
remove_builder "${kube_builder_verifier}"

echo "Verified cached Cloudpods RISC-V images and runtime contents."
