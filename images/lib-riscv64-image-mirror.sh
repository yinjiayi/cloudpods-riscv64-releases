#!/usr/bin/env bash

riscv64_image_config_sha256() {
    local image=$1
    local digest
    local repository

    if [[ ${image} == *@sha256:* ]]; then
        digest=sha256:${image##*@sha256:}
        repository=${image%@sha256:*}
        if [[ ${repository##*/} == *:* ]]; then
            repository=${repository%:*}
        fi
        image=${repository}@${digest}
    fi

    skopeo inspect --config --override-os linux --override-arch riscv64 \
        "docker://${image}" | jq -S -c . | sha256sum | awk '{print $1}'
}

riscv64_mirror_is_current() {
    local source_image=$1
    local target_image=$2
    local source_config_sha256
    local target_config_sha256

    source_config_sha256=$(riscv64_image_config_sha256 "${source_image}" \
        2>/dev/null) || return 1
    target_config_sha256=$(riscv64_image_config_sha256 "${target_image}" \
        2>/dev/null) || return 1
    [[ -n ${source_config_sha256} && \
       ${source_config_sha256} == "${target_config_sha256}" ]]
}
