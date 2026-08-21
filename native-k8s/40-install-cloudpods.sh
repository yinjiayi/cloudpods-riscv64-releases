#!/usr/bin/env bash

set -euo pipefail

config_file=${CONFIG_FILE:-/etc/cloudpods-native-k8s.env}
script_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
test -s "${config_file}"
# shellcheck source=/dev/null
source "${config_file}"

: "${NODE_NAME:?}"
: "${NODE_IP:?}"
: "${POD_CIDR:?}"
: "${MYSQL_PASSWORD:?}"
: "${ADMIN_PASSWORD:?}"
: "${HOST_DISK_PATH:=/opt/cloud/workspace/disks}"
: "${HOST_NETWORK_NAME:?}"
: "${HOST_NETWORK_START:?}"
: "${HOST_NETWORK_END:?}"
: "${HOST_NETWORK_PREFIX:?}"
: "${HOST_NETWORK_GATEWAY:?}"

if [[ ${EUID} -ne 0 ]]; then
    echo "Run as root" >&2
    exit 1
fi

if [[ ! ${MYSQL_PASSWORD} =~ ^[A-Za-z0-9._-]{16,128}$ \
    || ! ${ADMIN_PASSWORD} =~ ^[A-Za-z0-9._-]{16,128}$ ]]; then
    echo "MYSQL_PASSWORD and ADMIN_PASSWORD must contain 16-128 safe characters: A-Z a-z 0-9 . _ -" >&2
    exit 1
fi
if [[ ${ADMIN_PASSWORD} == CHANGE_ME_* || ${MYSQL_PASSWORD} == CHANGE_ME_* ]]; then
    echo "Replace both password placeholders" >&2
    exit 1
fi

python3 - \
    "${NODE_IP}" \
    "${HOST_NETWORK_START}" \
    "${HOST_NETWORK_END}" \
    "${HOST_NETWORK_PREFIX}" \
    "${HOST_NETWORK_GATEWAY}" <<'PY'
import ipaddress
import sys

node, start, end, prefix, gateway = sys.argv[1:]
network = ipaddress.ip_network(f"{node}/{prefix}", strict=False)
node_ip = ipaddress.ip_address(node)
start_ip = ipaddress.ip_address(start)
end_ip = ipaddress.ip_address(end)
gateway_ip = ipaddress.ip_address(gateway)
if not start_ip <= node_ip <= end_ip:
    raise SystemExit("NODE_IP must be inside HOST_NETWORK_START..HOST_NETWORK_END")
if start_ip not in network or end_ip not in network or gateway_ip not in network:
    raise SystemExit("host network addresses must be in the NODE_IP subnet")
PY

export KUBECONFIG=/etc/kubernetes/admin.conf
kubectl get node "${NODE_NAME}" >/dev/null
test -S /var/run/onecloud/exec.sock

install -d -m 0755 \
    /opt/cloudpods-native-k8s/data/glance \
    /opt/cloudpods-native-k8s/data/victoria-metrics \
    "${HOST_DISK_PATH}"

cat >/etc/my.cnf.d/cloudpods.cnf <<EOF
[mysqld]
bind-address=${NODE_IP}
max_connections=500
character-set-server=utf8mb4
collation-server=utf8mb4_unicode_ci
skip-name-resolve
EOF
systemctl enable --now mariadb
systemctl restart mariadb

mysql --protocol=socket <<SQL
CREATE USER IF NOT EXISTS 'cloudpods_root'@'10.244.%' IDENTIFIED BY '${MYSQL_PASSWORD}';
ALTER USER 'cloudpods_root'@'10.244.%' IDENTIFIED BY '${MYSQL_PASSWORD}';
GRANT ALL PRIVILEGES ON *.* TO 'cloudpods_root'@'10.244.%' WITH GRANT OPTION;
CREATE USER IF NOT EXISTS 'cloudpods_root'@'${NODE_IP}' IDENTIFIED BY '${MYSQL_PASSWORD}';
ALTER USER 'cloudpods_root'@'${NODE_IP}' IDENTIFIED BY '${MYSQL_PASSWORD}';
GRANT ALL PRIVILEGES ON *.* TO 'cloudpods_root'@'${NODE_IP}' WITH GRANT OPTION;
FLUSH PRIVILEGES;
SQL
mysql --host "${NODE_IP}" --user cloudpods_root --password="${MYSQL_PASSWORD}" \
    --execute 'SELECT VERSION();' >/dev/null

cat >/opt/cloudpods-native-k8s/storage.yaml <<EOF
apiVersion: storage.k8s.io/v1
kind: StorageClass
metadata:
  name: cloudpods-local
provisioner: kubernetes.io/no-provisioner
volumeBindingMode: WaitForFirstConsumer
reclaimPolicy: Retain
---
apiVersion: v1
kind: PersistentVolume
metadata:
  name: cloudpods-glance
spec:
  capacity:
    storage: 40Gi
  volumeMode: Filesystem
  accessModes: [ReadWriteOnce]
  persistentVolumeReclaimPolicy: Retain
  storageClassName: cloudpods-local
  local:
    path: /opt/cloudpods-native-k8s/data/glance
  nodeAffinity:
    required:
      nodeSelectorTerms:
        - matchExpressions:
            - key: kubernetes.io/hostname
              operator: In
              values: [${NODE_NAME}]
---
apiVersion: v1
kind: PersistentVolume
metadata:
  name: cloudpods-victoria-metrics
spec:
  capacity:
    storage: 20Gi
  volumeMode: Filesystem
  accessModes: [ReadWriteOnce]
  persistentVolumeReclaimPolicy: Retain
  storageClassName: cloudpods-local
  local:
    path: /opt/cloudpods-native-k8s/data/victoria-metrics
  nodeAffinity:
    required:
      nodeSelectorTerms:
        - matchExpressions:
            - key: kubernetes.io/hostname
              operator: In
              values: [${NODE_NAME}]
EOF

jq -n \
    --arg node_ip "${NODE_IP}" \
    --arg mysql_password "${MYSQL_PASSWORD}" \
    --arg admin_password "${ADMIN_PASSWORD}" \
    '{
      apiVersion:"onecloud.yunion.io/v1alpha1",
      kind:"OnecloudCluster",
      metadata:{name:"default",namespace:"onecloud",annotations:{"onecloud.yunion.io/edition":"ce"}},
      spec:{
        productVersion:"LightEdge",useHyperImage:true,disableLocalVpc:true,
        disableResourceManagement:false,imageRepository:"localhost/cloudpods",
        version:"v4.0.3-riscv64.6",region:"region0",zone:"zone0",
        loadBalancerEndpoint:$node_ip,
        mysql:{host:$node_ip,port:3306,username:"cloudpods_root",password:$mysql_password},
        etcd:{size:1,repository:"localhost/cloudpods",version:"3.5.24",
          pod:{busyboxImage:"localhost/cloudpods/busybox:1.37.0-glibc"},enableTls:true},
        keystone:{bootstrapPassword:$admin_password,imagePullPolicy:"Never",
          adminService:{nodePort:30357},publicService:{nodePort:30500}},
        logger:{imagePullPolicy:"Never",service:{nodePort:30999}},
        regionServer:{image:"localhost/cloudpods/cloudpods:v4.0.3-riscv64.6",
          repository:"localhost/cloudpods",imageName:"cloudpods",tag:"v4.0.3-riscv64.6",
          imagePullPolicy:"Never",service:{nodePort:30888}},
        scheduler:{imagePullPolicy:"Never",service:{nodePort:30887}},
        glance:{imagePullPolicy:"Never",storageClassName:"cloudpods-local",requests:{storage:"40Gi"},service:{nodePort:30292}},
        apiGateway:{imagePullPolicy:"Never",apiService:{nodePort:30300},wsService:{nodePort:30443}},
        climc:{imageName:"cloudpods",imagePullPolicy:"Never"},
        webconsole:{imagePullPolicy:"Never",service:{nodePort:30899},
          Guacd:{repository:"localhost/cloudpods",imageName:"guacd",tag:"1.6.0",imagePullPolicy:"Never"}},
        web:{image:"localhost/cloudpods/web:v4.0.3-riscv64-ui2",repository:"localhost/cloudpods",
          imageName:"web",tag:"v4.0.3-riscv64-ui2",imagePullPolicy:"Never",useHTTP:false},
        yunionconf:{imagePullPolicy:"Never",service:{nodePort:30889}},
        hostagent:{imageName:"cloudpods",imagePullPolicy:"Never",defaultQemuVersion:"10.0.7",
          hostCpuPassthrough:true,manageNtpConfiguration:false,disableProbeKubelet:true,
          SdnAgent:{imageName:"cloudpods",imagePullPolicy:"Never"},
          OvnController:{repository:"localhost/cloudpods",imageName:"openvswitch",tag:"2.12.4-20260415",imagePullPolicy:"Never"},
          HostHealth:{repository:"localhost/cloudpods",imageName:"host-health",tag:"v0.0.4",imagePullPolicy:"Never"}},
        hostdeployer:{imageName:"cloudpods",imagePullPolicy:"Never"},
        hostimage:{repository:"localhost/cloudpods",imageName:"host-image",tag:"v1.0.8",imagePullPolicy:"Never"},
        regionDNS:{disable:true},
        victoriaMetrics:{disable:false,replicas:1,storageClassName:"cloudpods-local"},
        yunionagent:{disable:true},kubeserver:{disable:true},
        notify:{disable:false,replicas:1},monitor:{disable:false,replicas:1},
        telegraf:{disable:true},autoupdate:{disable:true},ovnNorth:{disable:true},
        vpcAgent:{disable:true},monitorStack:{disable:true}
      }
    }' >/opt/cloudpods-native-k8s/onecloud-cluster.json
chmod 0600 /opt/cloudpods-native-k8s/onecloud-cluster.json

kubectl label node "${NODE_NAME}" node-role.kubernetes.io/master= --overwrite
kubectl label node "${NODE_NAME}" onecloud.yunion.io/controller=enable --overwrite
kubectl apply -f /opt/cloudpods-native-k8s/storage.yaml
kubectl apply -f "${script_dir}/manifests/onecloud-operator.yaml"
kubectl --namespace onecloud rollout status deployment/onecloud-operator --timeout=600s
kubectl apply -f /opt/cloudpods-native-k8s/onecloud-cluster.json

climc_ready=false
for _ in {1..240}; do
    if kubectl --namespace onecloud get deployment default-climc \
        -o jsonpath='{.status.availableReplicas}' 2>/dev/null | grep -Eq '^[1-9][0-9]*$'; then
        climc_ready=true
        break
    fi
    sleep 5
done
${climc_ready}

if ! kubectl --namespace onecloud exec deployment/default-climc -- \
    climc network-show "${HOST_NETWORK_NAME}" >/dev/null 2>&1; then
    kubectl --namespace onecloud exec deployment/default-climc -- \
        climc network-create \
        --server-type baremetal \
        --gateway "${HOST_NETWORK_GATEWAY}" \
        bcast0 "${HOST_NETWORK_NAME}" \
        "${HOST_NETWORK_START}" "${HOST_NETWORK_END}" "${HOST_NETWORK_PREFIX}"
fi

kubectl label node "${NODE_NAME}" onecloud.yunion.io/host=enable --overwrite

for _ in {1..180}; do
    if kubectl --namespace onecloud get service default-web >/dev/null 2>&1; then
        break
    fi
    sleep 5
done
kubectl --namespace onecloud get service default-web >/dev/null
kubectl --namespace onecloud patch service default-web --type=json --patch '[
  {"op":"replace","path":"/spec/type","value":"NodePort"},
  {"op":"add","path":"/spec/ports/0/nodePort","value":30080},
  {"op":"add","path":"/spec/ports/1/nodePort","value":30444}
]'

cat >/etc/systemd/system/cloudpods-web-http.service <<EOF
[Unit]
Description=Cloudpods HTTP proxy
After=network-online.target kube-proxy.service

[Service]
ExecStart=/usr/bin/socat TCP-LISTEN:80,reuseaddr,fork TCP:${NODE_IP}:30080
Restart=always
RestartSec=2

[Install]
WantedBy=multi-user.target
EOF
cat >/etc/systemd/system/cloudpods-web-https.service <<EOF
[Unit]
Description=Cloudpods HTTPS proxy
After=network-online.target kube-proxy.service

[Service]
ExecStart=/usr/bin/socat TCP-LISTEN:443,reuseaddr,fork TCP:${NODE_IP}:30444
Restart=always
RestartSec=2

[Install]
WantedBy=multi-user.target
EOF
systemctl daemon-reload
systemctl enable --now cloudpods-web-http cloudpods-web-https

host_id=
for _ in {1..240}; do
    host_id=$(kubectl --namespace onecloud exec deployment/default-climc -- \
        sh -lc "climc host-list --access-ip '${NODE_IP}' --field id --limit 1" 2>/dev/null \
        | grep -Eo '[0-9a-f]{8}-[0-9a-f-]{27}' | head -n 1 || true)
    if [[ -n ${host_id} ]]; then
        break
    fi
    sleep 5
done
test -n "${host_id}"
kubectl --namespace onecloud exec deployment/default-climc -- \
    climc host-enable "${host_id}"

host_enabled=false
for _ in {1..120}; do
    if kubectl --namespace onecloud exec deployment/default-climc -- \
        climc host-list --enabled --access-ip "${NODE_IP}" --field id --limit 1 2>/dev/null \
        | grep -Fq "${host_id}"; then
        host_enabled=true
        break
    fi
    sleep 5
done
${host_enabled}

echo CLOUDPODS_INSTALL_OK
