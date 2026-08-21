#!/usr/bin/env bash

set -euo pipefail

config_file=${CONFIG_FILE:-/etc/cloudpods-native-k8s.env}
test -s "${config_file}"
# shellcheck source=/dev/null
source "${config_file}"

: "${NODE_IP:?}"

export KUBECONFIG=/etc/kubernetes/admin.conf
kubectl version --client=true
kubectl get --raw=/readyz | grep -qx ok

bad_nodes=$(kubectl get nodes -o json | jq '[
  .items[] |
  select(.status.nodeInfo.architecture != "riscv64" or
    any(.status.conditions[]; .type == "Ready" and .status != "True"))
] | length')
test "${bad_nodes}" -eq 0
kubectl --namespace kube-system rollout status deployment/coredns --timeout=300s

mapfile -t netcheck_nodes < <(kubectl get nodes \
    -o jsonpath='{range .items[*]}{.metadata.name}{"\n"}{end}')
netcheck_pods=()
cleanup_netcheck() {
    if (( ${#netcheck_pods[@]} > 0 )); then
        kubectl delete pod "${netcheck_pods[@]}" \
            --ignore-not-found --wait=false >/dev/null 2>&1 || true
    fi
}
trap cleanup_netcheck EXIT
for index in "${!netcheck_nodes[@]}"; do
    pod_name="cloudpods-native-netcheck-${index}"
    kubectl delete pod "${pod_name}" --ignore-not-found --wait=true >/dev/null
    overrides=$(jq -nc --arg node "${netcheck_nodes[${index}]}" \
        '{spec:{nodeName:$node}}')
    kubectl run "${pod_name}" \
        --image=localhost/cloudpods/busybox:1.37.0-glibc \
        --image-pull-policy=Never \
        --restart=Never \
        --overrides="${overrides}" \
        --command -- sh -c 'sleep 600' >/dev/null
    netcheck_pods+=("${pod_name}")
done
kubectl wait pod "${netcheck_pods[@]}" \
    --for=condition=Ready --timeout=300s >/dev/null
for source_pod in "${netcheck_pods[@]}"; do
    for target_pod in "${netcheck_pods[@]}"; do
        target_ip=$(kubectl get pod "${target_pod}" -o jsonpath='{.status.podIP}')
        kubectl exec "${source_pod}" -- ping -c 2 -W 3 "${target_ip}" >/dev/null
    done
done
cleanup_netcheck
trap - EXIT

bad_pods=$(kubectl --namespace onecloud get pods -o json | jq '[
  .items[] |
  select(.metadata.deletionTimestamp == null) |
  select(.status.phase != "Running" or
    any(.status.containerStatuses[]?; .ready != true))
] | length')
test "${bad_pods}" -eq 0

bad_daemonsets=$(kubectl --namespace onecloud get daemonsets -o json | jq '[
  .items[] |
  select(.status.desiredNumberScheduled != .status.numberReady)
] | length')
test "${bad_daemonsets}" -eq 0

test -S /var/run/onecloud/exec.sock
test -c /dev/kvm
/usr/local/qemu-10.0.7/bin/qemu-system-riscv64 --version | grep -F 'version 10.0.7'
grep -F 'Linux version' /var/log/cloudpods-riscv64-kvm-smoke.log
grep -F 'Detected architecture riscv64' /var/log/cloudpods-riscv64-kvm-smoke.log

kubectl --namespace onecloud get service default-web \
    -o jsonpath='{.spec.type}' | grep -qx NodePort
curl --retry 10 --retry-delay 3 --retry-connrefused \
    --fail --silent --show-error --insecure \
    --output /dev/null "https://${NODE_IP}/"

kubectl get nodes -o wide
kubectl --namespace onecloud get pods -o wide
kubectl --namespace onecloud get daemonsets
kubectl --namespace onecloud exec deployment/default-climc -- climc host-list
kubectl --namespace onecloud exec deployment/default-climc -- \
    climc host-list --enabled --access-ip "${NODE_IP}" --field id --limit 1 \
    | grep -Eq '[0-9a-f]{8}-[0-9a-f-]{27}'
echo CLOUDPODS_NATIVE_K8S_ACCEPTANCE_OK
