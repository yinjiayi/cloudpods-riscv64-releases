#!/bin/sh

set -eu

usage() {
    echo "usage: $0 ghcr.io/OWNER/IMAGE:TAG OUTPUT.tar" >&2
    exit 2
}

[ "$#" -eq 2 ] || usage

image_ref=$1
output=$2

case "${image_ref}" in
    ghcr.io/*:*) ;;
    *) usage ;;
esac

command -v curl >/dev/null
command -v jq >/dev/null
command -v tar >/dev/null

repository_and_tag=${image_ref#ghcr.io/}
repository=${repository_and_tag%:*}
tag=${repository_and_tag##*:}

[ -n "${repository}" ]
[ -n "${tag}" ]

if command -v sha256sum >/dev/null 2>&1; then
    sha256_file() {
        sha256sum "$1" | awk '{print $1}'
    }
else
    sha256_file() {
        shasum -a 256 "$1" | awk '{print $1}'
    }
fi

work_dir=$(mktemp -d "${TMPDIR:-/tmp}/ghcr-oci.XXXXXX")
trap 'rm -rf -- "${work_dir}"' EXIT HUP INT TERM

layout_dir=${work_dir}/layout
manifest_file=${work_dir}/manifest.json
headers_file=${work_dir}/manifest.headers
mkdir -p "${layout_dir}/blobs/sha256"

token=$(curl --fail --silent --show-error --location --get \
    --connect-timeout 20 --retry 5 --retry-all-errors --retry-delay 2 \
    --data-urlencode "scope=repository:${repository}:pull" \
    https://ghcr.io/token | jq -er '.token')

curl --fail --silent --show-error --location \
    --connect-timeout 20 --retry 5 --retry-all-errors --retry-delay 2 \
    --header "Authorization: Bearer ${token}" \
    --header 'Accept: application/vnd.oci.image.manifest.v1+json' \
    --dump-header "${headers_file}" \
    "https://ghcr.io/v2/${repository}/manifests/${tag}" \
    --output "${manifest_file}"

media_type=$(jq -er '.mediaType' "${manifest_file}")
[ "${media_type}" = 'application/vnd.oci.image.manifest.v1+json' ] || {
    echo "expected an OCI image manifest, got ${media_type}" >&2
    exit 1
}

manifest_sha=$(sha256_file "${manifest_file}")
manifest_digest=sha256:${manifest_sha}
registry_digest=$(awk 'BEGIN {IGNORECASE=1} /^Docker-Content-Digest:/ {gsub("\r", "", $2); print $2}' "${headers_file}" | tail -n 1)
if [ -n "${registry_digest}" ] && [ "${registry_digest}" != "${manifest_digest}" ]; then
    echo "manifest digest mismatch: registry=${registry_digest} local=${manifest_digest}" >&2
    exit 1
fi

cp "${manifest_file}" "${layout_dir}/blobs/sha256/${manifest_sha}"

jq -r '.config.digest, .layers[].digest' "${manifest_file}" | while IFS= read -r digest; do
    algorithm=${digest%%:*}
    value=${digest#*:}
    [ "${algorithm}" = sha256 ] || {
        echo "unsupported blob digest: ${digest}" >&2
        exit 1
    }
    destination=${layout_dir}/blobs/sha256/${value}
    curl --fail --silent --show-error --location \
        --connect-timeout 20 --retry 5 --retry-all-errors --retry-delay 2 \
        --header "Authorization: Bearer ${token}" \
        "https://ghcr.io/v2/${repository}/blobs/${digest}" \
        --output "${destination}"
    actual=$(sha256_file "${destination}")
    [ "${actual}" = "${value}" ] || {
        echo "blob digest mismatch: expected=${value} actual=${actual}" >&2
        exit 1
    }
done

printf '{"imageLayoutVersion":"1.0.0"}\n' >"${layout_dir}/oci-layout"
manifest_size=$(wc -c <"${manifest_file}" | tr -d ' ')
jq -n \
    --arg digest "${manifest_digest}" \
    --arg ref "${image_ref}" \
    --argjson size "${manifest_size}" \
    '{schemaVersion: 2, manifests: [{mediaType: "application/vnd.oci.image.manifest.v1+json", digest: $digest, size: $size, annotations: {"org.opencontainers.image.ref.name": $ref}}]}' \
    >"${layout_dir}/index.json"

mkdir -p "$(dirname "${output}")"
tar -C "${layout_dir}" -cf "${output}" oci-layout index.json blobs

archive_sha=$(sha256_file "${output}")
printf '%s  %s\n' "${archive_sha}" "${output}"
