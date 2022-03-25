#!/bin/bash

set -u
set -o pipefail

METERIAN_API_BASE_URL=${METERIAN_API_BASE_URL:-"https://www.meterian.com"}
METERIAN_API_TOKEN=${METERIAN_API_TOKEN:?'Required METERIAN_API_TOKEN environment variable is unset.'}
R_SCRIPT_NAME="ls-user-packages.R"

onExit() {
    rm curl*.mlog > /dev/null 2>&1
    rm $R_SCRIPT_NAME > /dev/null 2>&1
}
trap onExit EXIT

function prepRscript() {
    printf '#!/usr/bin/env Rscript
    ip = as.data.frame(installed.packages()[,c(1,3:4)])
    ip = ip[is.na(ip$Priority),1:2,drop=FALSE]
    ip
    ' > $R_SCRIPT_NAME
    chmod +x $R_SCRIPT_NAME
}
prepRscript

function createBuild() {
    DATA="$1"

    output="$(curl -v -sS -X POST "$METERIAN_API_BASE_URL/api/v1/builds" \
    -H  "accept: */*" \
    -H  "Authorization: Token $METERIAN_API_TOKEN" \
    -H  "Content-Type: application/json" \
    -d "$DATA"  2>&1)"

    build_id="$(echo "$output" | grep -oE "builds\/[-a-zA-Z0-9]*")"
    build_id="${build_id:7}"
    echo $build_id
}

function getStatusCodeLine() {
    echo "$(echo "$output" | grep -E "<\s+HTTP\/")"
}

function uploadDependenciesToBuild() {
    build_id="$1"
    dependencies="$2"

    DATA=$(printf '{
        "content": "%s",
        "language": "r",
        "path": "/?format=csv"
    }' ${dependencies})

    output="$(curl -v -sS -X PUT "$METERIAN_API_BASE_URL/api/v1/builds/$build_id/dependencies" \
    -H "accept: */*" \
    -H "Authorization: Token $METERIAN_API_TOKEN" \
    -H "Content-Type: application/json" \
    -d "$DATA" 2>&1)"

    status_code_line="$(getStatusCodeLine "$output")"

    if [[ -n "$(echo "$status_code_line" | grep -o 200)" ]]; then
        echo "Done."
    else
        echo "Unexpected error encountered uploading dependencies."
        exit -1
    fi
}

function startBuild() {
    curl_log_file="curl${RANDOM}.mlog"
    response="$(curl -v -sS -X POST "$METERIAN_API_BASE_URL/api/v1/builds/${1}/start?force=false&scopes=prod" \
    -H "accept: */*" \
    -H "Authorization: Token $METERIAN_API_TOKEN" 2> $curl_log_file)"
    curl_logs="$(cat $curl_log_file)"
    rm $curl_log_file > /dev/null 2>&1

    status_code_line="$(getStatusCodeLine "$curl_logs")"
    if [[ -n "$(echo "$status_code_line" | grep -o 200)" ]]; then
        echo "The build has started."
    else
        echo "Unexpected error encountered, the build could not be started."
        exit -1
    fi
}

function getBuildStatus() {
    response="$(curl -sS -X GET "$METERIAN_API_BASE_URL/api/v1/builds/${1}" \
        -H "accept: */*" \
        -H "Authorization: Token $METERIAN_API_TOKEN" 2> /dev/null )"

    echo "$response"
}

function jsonAttrToConsoleLine() {
    attr="$1"
    line="$(echo "$attr" | tr -d '"')"
    line="$(echo "$line" | tr -d ',')"
    line="${line//:/: }"

    echo "$line"
}

function pollBuildStatus() {
    build_id="${1}"
    max_retries=240
    sleep_interval=5
    retries=0

    status=""
    while [[ -z "$status" && $retries -lt $max_retries ]]; do
        sleep $sleep_interval

        response="$(getBuildStatus "$build_id")"
        status="$(echo $response | grep -oE '\s*"status"\s*:\s*"success"')"

        status_msg="$(jsonAttrToConsoleLine "$status")"
        echo "Checking build status..."
        echo "${status_msg}"

        retries=$(( $retries+1 ))
    done

    if [[ $retries -eq $max_retries && -z "$status" ]]; then
        echo "Unexpected error, build status polling timed out"
        exit -1
    fi
}

function printFinalResults() {
    pid="${1:-}"
    security="${2:-}"
    stability="${3:-}"
    licensing="${4:-}"

    echo "Final results:"
    echo "- security: $security"
    echo "- stability $stability"
    if [[ -n "$licensing" ]]; then
        echo "- licensing $licensing"
    fi
    echo

    echo "Full report available at:"
    echo "$METERIAN_API_BASE_URL/projects/?pid=$pid&mode=eli"
}

function processFinalResults() {
    response="$1"
    project_branch="$2"

    accountUuid="$(echo "${response:-}" | grep -oE '\s*"account_uuid"\s*:\s*"[a-z0-9-]*"')"
    accountUuid="$(jsonAttrToConsoleLine "$accountUuid")"
    accountUuid=${accountUuid:14}

    if [[ -z "$accountUuid" ]]; then
        echo "Unable to process final results, account ID was found unset"
        echo
        exit -1
    fi

    # registering outcome

    config_response="$(getConfiguration "$accountUuid")"
    min_security="$(echo "${config_response:-}" | grep -oE '\s*"security"\s*:\s*[0-9]*,')"
    min_security="$(jsonAttrToConsoleLine "$min_security")"
    min_security=${min_security:10}
    min_security=${min_security:-90}

    min_stability="$(echo "${config_response:-}" | grep -oE '\s*"stability"\s*:\s*[0-9]*,')"
    min_stability="$(jsonAttrToConsoleLine "$min_stability")"
    min_stability=${min_stability:11}
    min_stability=${min_stability:-80}

    min_licensing="$(echo "${config_response:-}" | grep -oE '\s*"licensing"\s*:\s*[0-9]*,')"
    min_licensing="$(jsonAttrToConsoleLine "$min_licensing")"
    min_licensing=${min_licensing:11}
    min_licensing=${min_licensing:-95}

    pid="$(echo "${response:-}" | grep -oE '\s*"uuid"\s*:\s*"[a-z0-9-]*"')"
    pid="$(jsonAttrToConsoleLine "$pid")"
    pid="${pid//uuid: /}"

    security_score="$(echo "${response:-}" | grep -oE '\s*"security"\s*:\s*"[0-9]*"')"
    security_score="$(jsonAttrToConsoleLine "$security_score")"
    security_score=${security_score:10}

    stability_score="$(echo "${response:-}" | grep -oE '\s*"stability"\s*:\s*"[0-9]*"')"
    stability_score="$(jsonAttrToConsoleLine "$stability_score")"
    stability_score=${stability_score:11}

    licensing_score="$(echo "${response:-}" | grep -oE '\s*"licensing"\s*:\s*"[0-9]*"')"
    licensing_score="$(jsonAttrToConsoleLine "$licensing_score")"
    licensing_score=${licensing_score:11}

    if [[ -z "$pid" || -z "$security_score" || -z "$stability_score" ]]; then
        echo "Unable to process final results, final results data was found unset"
        echo
        exit -1
    fi

    outcome=0
    if [[ $min_security -gt $security_score ]];then
        outcome=$(( $outcome + 1 ))
    fi

    if [[ $min_stability -gt $stability_score ]];then
        outcome=$(( $outcome + 2 ))
    fi

    if [[ -n "$licensing_score" && -n "$min_licensing" ]];then
        if [[ $min_licensing -gt $licensing_score ]]; then
            outcome=$(( $outcome + 4 ))
        fi
    fi

    if [[ $outcome -eq 0 ]];then
        recordOutcome "$pid" "$project_branch" "PASS"
    else
        recordOutcome "$pid" "$project_branch" "FAIL"
    fi

    # print final results
    printFinalResults "$pid" "$security_score" "$stability_score" "$licensing_score"
    echo

    exit $outcome
}

function recordOutcome() {
    curl -sS -X POST "$METERIAN_API_BASE_URL/api/v1/reports/${1}/outcome?branch=${2}&outcome=${3}" \
    -H  "accept: application/json" -H  "Authorization: Token $METERIAN_API_TOKEN" > /dev/null 2>&1
}

function getConfiguration() {
    response="$(curl -sS -X GET "$METERIAN_API_BASE_URL/api/v1/accounts/${1}/configuration" \
    -H "accept: */*" \
    -H "Authorization: Token $METERIAN_API_TOKEN" 2> /dev/null )"

    echo "$response"
}

function getRdependencyList() {
    image="$1"
    installed_packages_list="$(docker run --rm -v $(pwd)/ls-user-packages.R:/ls-user-packages.R --entrypoint "/ls-user-packages.R" $image | tail -n +2)"
    installed_packages_list="$(echo "$installed_packages_list" | awk -F' ' '{ printf "%s %s\n", $2, $3 }')"
    rm $R_SCRIPT_NAME > /dev/null 2>&1 
    echo "$installed_packages_list"
}

function getDependencyList() {
    image="$1"
    echo "$(getRdependencyList "$image")"
}

function packagesToCSV() {
    csv="$(echo "$1" | awk -F' ' '{ printf "%s,%s\\n", $1, $2 }')"
    echo $csv
}

function imageExist() {
    docker_id="$(docker images "$1" -q)"
    if [[ -n "$docker_id" ]]; then
        echo "true"
    else
        echo "false"
    fi
}

# check that required tools are installed
if ! which docker > /dev/null 2>&1; then
    echo "Required tool `docker` is not installed!"
fi

if ! which curl > /dev/null 2>&1; then
    echo "Required tool `curl` is not installed!"
fi

IMAGE=${1:?'Provide the name of a Docker image to scan.'}
IMAGE_NAME="$(echo "$IMAGE" | awk -F':' '{ printf $1 }')"
IMAGE_TAG="$(echo "$IMAGE" | awk -F':' '{ printf $2 }')"
IMAGE_NAME=${IMAGE_NAME:-$IMAGE}
IMAGE_TAG="${IMAGE_TAG:-latest}"

if [[ "false" == "$(imageExist "$IMAGE_NAME:$IMAGE_TAG")" ]]; then
    echo "Scan aborted as docker image $IMAGE_NAME:$IMAGE_TAG does not exist"
    exit -1
fi

# Create build
CREATE_BUILD_DATA_JSON=$(printf '{
  "branch": "%s",
  "url": "docker:%s"
}' ${IMAGE_TAG} ${IMAGE_NAME})

echo "Creating build with data"
echo "${CREATE_BUILD_DATA_JSON}"
echo

build_id="$(createBuild "$CREATE_BUILD_DATA_JSON")" 
if [[ -z "$build_id" ]]; then
    echo "Unexpected error occurred, unable to create build."
    exit -1
else
    echo "Build successfully created: ${build_id}"
    echo
fi

# load dependencies
echo "Loading dependencies from $IMAGE_NAME:$IMAGE_TAG..."
dependency_list="$(getDependencyList "$IMAGE_NAME:$IMAGE_TAG")"
echo "Dependencies loaded: $(echo "$dependency_list" | wc -l)"
echo

# upload dependencies
echo "Uploading dependencies..."
dependencies_csv="$(packagesToCSV "$dependency_list")"
uploadDependenciesToBuild "$build_id" "$dependencies_csv"
echo

# start build
startBuild "$build_id"
echo

# poll build status, and view results when done
pollBuildStatus "$build_id"

echo
processFinalResults "$(getBuildStatus "$build_id")" $IMAGE_TAG
echo