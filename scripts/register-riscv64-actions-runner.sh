#!/usr/bin/env bash
set -Eeuo pipefail

[[ ${EUID} -eq 0 ]] || {
    echo 'run as root after install-riscv64-actions-runner-runtime.sh' >&2
    exit 1
}
: "${ACTIONS_RUNNER_TOKEN:?set a one-time repository runner registration token}"

runner_root=/opt/actions-runner
runner_sysroot=/opt/x86_64-runner-sysroot
runner_url=${ACTIONS_RUNNER_URL:-https://github.com/yinjiayi/cloudpods-riscv64-releases}
runner_name=${ACTIONS_RUNNER_NAME:-$(hostname -s)}
runner_labels=${ACTIONS_RUNNER_LABELS:-riscv64,openeuler-24.03-riscv64}
runner_work=${ACTIONS_RUNNER_WORK:-_work}
runner_env=(
    RUNNER_ALLOW_RUNASROOT=1
    QEMU_LD_PREFIX=${runner_sysroot}
    QEMU_CPU=qemu64
    DOTNET_gcServer=0
    DOTNET_gcConcurrent=0
    DOTNET_GCHeapHardLimit=0x40000000
)

[[ -x ${runner_root}/bin/Runner.Listener ]]
[[ -r /proc/sys/fs/binfmt_misc/qemu-x86_64-cloudpods ]]
for network_file in resolv.conf hosts; do
    [[ -r /etc/${network_file} ]]
    install -m 0644 "/etc/${network_file}" \
        "${runner_sysroot}/etc/${network_file}"
done
cd "${runner_root}"

replace_arg=()
if [[ -e .runner ]]; then
    [[ ${ACTIONS_RUNNER_REPLACE:-0} == 1 ]] || {
        echo 'runner is already configured; set ACTIONS_RUNNER_REPLACE=1 to replace it' >&2
        exit 1
    }
    replace_arg=(--replace)
fi

env "${runner_env[@]}" ./bin/Runner.Listener configure \
    --unattended \
    --url "${runner_url}" \
    --token "${ACTIONS_RUNNER_TOKEN}" \
    --name "${runner_name}" \
    --labels "${runner_labels}" \
    --work "${runner_work}" \
    --disableupdate \
    "${replace_arg[@]}"
unset ACTIONS_RUNNER_TOKEN

./svc.sh install root
service_name=$(<.service)
[[ ${service_name} =~ ^[A-Za-z0-9_.@-]+$ ]]
dropin_dir=/etc/systemd/system/${service_name}.d
install -d -m 0755 "${dropin_dir}"
dropin_tmp=$(mktemp "${dropin_dir}/.10-riscv64-runtime.XXXXXX")
printf '%s\n' \
    '[Service]' \
    'Environment=RUNNER_ALLOW_RUNASROOT=1' \
    "Environment=QEMU_LD_PREFIX=${runner_sysroot}" \
    'Environment=QEMU_CPU=qemu64' \
    'Environment=DOTNET_gcServer=0' \
    'Environment=DOTNET_gcConcurrent=0' \
    'Environment=DOTNET_GCHeapHardLimit=0x40000000' \
    "ExecStartPre=/usr/bin/install -m 0644 /etc/resolv.conf ${runner_sysroot}/etc/resolv.conf" \
    "ExecStartPre=/usr/bin/install -m 0644 /etc/hosts ${runner_sysroot}/etc/hosts" \
    > "${dropin_tmp}"
chmod 0644 "${dropin_tmp}"
mv "${dropin_tmp}" "${dropin_dir}/10-riscv64-runtime.conf"
systemctl daemon-reload
./svc.sh start
systemctl is-active --quiet "${service_name}"
printf 'registered service: %s\n' "${service_name}"
