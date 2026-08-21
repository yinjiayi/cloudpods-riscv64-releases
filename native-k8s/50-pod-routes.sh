#!/usr/bin/env bash

set -euo pipefail

config_file=${CONFIG_FILE:-/etc/cloudpods-native-k8s.env}
test -s "${config_file}"
# shellcheck source=/dev/null
source "${config_file}"

: "${POD_NODE_CIDR:?}"

if [[ ${EUID} -ne 0 ]]; then
    echo "Run as root" >&2
    exit 1
fi
if (( $# == 0 )); then
    echo "Usage: $0 REMOTE_POD_CIDR=REMOTE_NODE_IP [...]" >&2
    exit 1
fi

route_file=/etc/cloudpods-native-k8s-routes.conf
: >"${route_file}.new"
for mapping in "$@"; do
    cidr=${mapping%%=*}
    gateway=${mapping#*=}
    if [[ ${cidr} == "${mapping}" || -z ${cidr} || -z ${gateway} ]]; then
        echo "Invalid route mapping: ${mapping}" >&2
        exit 1
    fi
    if [[ ${cidr} == "${POD_NODE_CIDR}" ]]; then
        echo "Do not add a route for this node's own Pod CIDR: ${cidr}" >&2
        exit 1
    fi
    ip route get "${gateway}" >/dev/null
    printf '%s %s\n' "${cidr}" "${gateway}" >>"${route_file}.new"
done
install -m 0600 "${route_file}.new" "${route_file}"
rm -f "${route_file}.new"

cat >/usr/local/sbin/cloudpods-native-k8s-routes <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
while read -r cidr gateway; do
    [[ -n ${cidr} && -n ${gateway} ]]
    ip route replace "${cidr}" via "${gateway}"
done </etc/cloudpods-native-k8s-routes.conf
EOF
chmod 0755 /usr/local/sbin/cloudpods-native-k8s-routes

cat >/etc/systemd/system/cloudpods-native-k8s-routes.service <<'EOF'
[Unit]
Description=Static routes for native Kubernetes Pod networks
Wants=network-online.target
After=network-online.target

[Service]
Type=oneshot
ExecStart=/usr/local/sbin/cloudpods-native-k8s-routes
RemainAfterExit=yes

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
systemctl enable cloudpods-native-k8s-routes.service
systemctl restart cloudpods-native-k8s-routes.service

while read -r cidr _; do
    ip route show "${cidr}"
done <"${route_file}"
echo NATIVE_K8S_POD_ROUTES_OK
