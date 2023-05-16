#!/bin/bash

set -e
set -o pipefail

METERIAN_API_TOKEN=${METERIAN_API_TOKEN:?'Required METERIAN_API_TOKEN environment variable is unset.'}

exportDockerBin() {
    dockerBin="$(which docker)"
    reg='snap'
    if [[ "${dockerBin}" =~ $reg ]]; then
        export DSE_DOCKER_BIN="/snap/docker/current/bin/docker"
    else
        export DSE_DOCKER_BIN="${dockerBin}"
    fi
}
exportDockerBin

IMAGE_NAME="meterian/cs-engine:latest"
if [[ "$*" =~ "--canary" ]];
then
    CLIENT_CANARY_FLAG=on
    IMAGE_NAME="meterian/cs-engine-canary:latest"
fi

docker run --rm -v /tmp:/tmp \
    -v /var/run/docker.sock:/var/run/docker.sock \
    -v $DSE_DOCKER_BIN:$DSE_DOCKER_BIN \
    -v $(pwd):/workspace \
    -e METERIAN_API_TOKEN=$METERIAN_API_TOKEN \
    -e METERIAN_ENV=${METERIAN_ENV:-} \
    -e METERIAN_DOMAIN=${METERIAN_DOMAIN:-} \
    -e METERIAN_PROTO=${METERIAN_PROTO:-} \
    -e DSE_SCAN_TIMEOUT_MINUTES=$DSE_SCAN_TIMEOUT_MINUTES \
    -e HOST_UID=$(id -u) \
    -e HOST_GID=$(id -g) \
    -e http_proxy="${http_proxy}" \
   -e https_proxy="${https_proxy}" \
    $IMAGE_NAME $*
