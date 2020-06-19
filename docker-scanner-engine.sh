#!/bin/bash

set -e
set -u
set -o pipefail

PRG_NAME="Docker Scanner Engine"
VERSION="0.1"
DC_PROJECT_NAME="dse" # Docker Compose Project Name
if [[ -z "${METERIAN_ENV:-}" ]]; then
    export METERIAN_ENV="www"
fi
METERIAN_ENV="${METERIAN_ENV}"
METERIAN_API_TOKEN="${METERIAN_API_TOKEN:-}"
DEV_MODE=${DSE_DEV_MODE:-}
ISO_LOCAL_DATE_TIME="%Y-%m-%dT%H:%M:%S"

dockerCompose() {
    if [[ "${DEV_MODE}" != "on" ]]; then
        docker-compose -f docker-compose.yml -f anchore-engine-configuration.yml --project-name ${DC_PROJECT_NAME} ${*}
    else
        docker-compose -f docker-compose-dev.yml -f anchore-engine-configuration.yml --project-name ${DC_PROJECT_NAME} ${*}
    fi
}

showUsageText() {
    cat << HEREDOC
        Usage: $0 <command> [<args>]

        Commands:
        install         Install $PRG_NAME
        scan            Scan a specific docker image,
                        e.g. $0 scan image:tag
        startup         Start up all services needed for ${PRG_NAME} to function
        shutdown        Stop all services associated to ${PRG_NAME}
        list-services    List all services
        log-service      Allows to view the logs of a specific service
                          e.g. $0 log-service service_name
        scan-status      View the status of running scan
                          e.g. $0 scan-status image:tag
        version         Shows the current ${PRG_NAME} version
        help            Print usage manual
HEREDOC
}

validateDockerImageName() {
    image="${1:-}"
    if [[ -z "${image}" ]]; then
        echo "Docker image name cannot be empty"
        exit -1
    elif [[ -z "$(echo ${image} | grep '^[^:]\+:\{1\}[^:]\+$')" ]]; then
        echo "Docker image '${image}' does not match a valid format"
        echo "valid Docker image name: image:tag"
        exit -1;
    fi
}

getDateTime() {
    format=${1:-$ISO_LOCAL_DATE_TIME}
    date +${format}
}

apiScan() {
    image=${1}

    curl -X POST "http://localhost:8765/v1/docker/scans?name=${image}" &>/dev/null
}

apiScanProgressMessage() {
    image=${1}

    outputFile="scan-status-msg.tmp"
    rm --force "${outputFile}"
    curl -o "${outputFile}" "http://localhost:8765/v1/docker/scans?name=${image}&fmt=txt" &>/dev/null
    progressMessage="$(cat ${outputFile})"
    rm --force "${outputFile}"

    echo "${progressMessage}"
}

getScanStatus() {
    image=${1}
    outputFile="scan-status.tmp"

    rm --force "${outputFile}"
    curl -o "${outputFile}" "http://localhost:8765/v1/docker/scans?name=${image}&status=true" &>/dev/null
    status=$(cat ${outputFile})
    rm --force "${outputFile}"

    echo "${status}"
}

periodicScanStatusUpdate() {
    image=${1}
    interval=${2:-"1"}

    previousMsg=""
    scanStatus=$(getScanStatus "${image}")
    while [[ "${scanStatus}" == "scanning" || "${scanStatus}" == "analyzing" ]]; do # change to regex check with ~= (success|failure|scan_failure)
        currentMsg="$(apiScanProgressMessage "${image}")"
        if [[ "${previousMsg}" != "${currentMsg}" ]]; then
            echo "${currentMsg}"
            previousMsg="${currentMsg}"
        fi
        sleep ${interval}
        scanStatus=$(getScanStatus "${image}")
    done
}

imageScan() {
    image=$1
    validateDockerImageName $image
    checkIfInstalled
    checkIfAllServicesAreUp

    echo
    echo "$(getDateTime) - Pulling \"${image}\"..."
    docker pull --quiet "${image}" &>/dev/null
    apiScan ${image}
    echo "$(getDateTime) - Scan for \"${image}\" has started"
    periodicScanStatusUpdate "${image}" 3
    echo "$(apiScanProgressMessage "${image}")"
    if [[ "$(getScanStatus "${image}")" != "success" ]]; then
        exit -1
    fi
}

getServicesCount() {
    downloadComposeFilesIfMissing
    # gather full images names from docker compose files in a file
    serviceImagesFile="images.tmp"
    grep -oP "image:\s+\K.*" docker-compose.yml >> ${serviceImagesFile} \
    && grep -oP "image:\s+\K.*" anchore-engine-configuration.yml >> ${serviceImagesFile}
    result=$(cat ${serviceImagesFile} | wc -l)
    rm --force ${serviceImagesFile}

    echo ${result}
}

checkIfAllServicesAreUp() {
    echo "~~~ Checking if services are up"

    expected_services=$(getServicesCount)
    services_count=$(dockerCompose ps -q | wc -l)
    if [[ ${expected_services} -ne ${services_count} ]]; then
        echo "Services are not up and running"
        echo "  to start up services run:"
        echo "      $0 startup"
        exit -1
    else
        echo "All services are up and running"
    fi
}

checkIfAnyServicesAreUp() {
    services_count=$(dockerCompose ps -q | wc -l)
    if [[ ${services_count} -gt 0 ]]; then
        return 0
    fi 
    return 1
}

healthCheck() {
    result=""
    curl_output=$(curl -s -L -I -X GET "localhost:8765/admin/healthcheck")
    if [[ "$(echo ${curl_output} | head -n 1)" =~ "200" ]]; then
        result="OK"
    else
        result="NOT OK"
    fi

    echo ${result}
}

syncAnchoreDatabase() {
    dockerCompose exec api anchore-cli system wait
}

checkDomainIsReachable () {
    domain=$1
    timeOut=${2:-"30"}

    exitCode=0
    curl -s -L -I ${domain} --connect-timeout ${timeOut} &>/dev/null || exitCode=$?
    echo "${exitCode}"
}

authenticate() {
    if [[ -n "${METERIAN_API_TOKEN}" ]]; then 
        echo "~~~ Authentication in progress"

        domainUrl="https://${METERIAN_ENV}.meterian.com"
        if [[ "$(checkDomainIsReachable ${domainUrl})" != "0" ]]; then
            echo "Authentication failed"
            echo "The domain \"$domainUrl\" is unreachable"
            exit -1
        fi

        exitCode=0
        apiEndpointUrl="${domainUrl}/api/v1/accounts/really-me"
        response=$(curl -s -L -I -H 'Authorization: token '${METERIAN_API_TOKEN}''  "${apiEndpointUrl}") || exitCode=$?
        if [[ "${exitCode}" != "0" ]];then
            echo "Authentication error"
            exit -1
        fi

        statusCode=$(echo ${response} | head -n 1)
        if [[ "${statusCode}" =~ "200" ]]; then
            echo "Successfully authenticated!"
        else
            echo "Authentication failed"
            exit -1
        fi
    else
        echo "~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~"
		echo " The METERIAN_API_TOKEN environment variable must be defined with an API token   "
		echo
		echo " Please create a token from your account at https://meterian.com/account/#tokens "
		echo " and populate the variable with the value of the token "
		echo
		echo " For example: "
		echo " export METERIAN_API_TOKEN=12345678-90ab-cdef-1234-567890abcdef "
		echo "~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~-"
		exit -1
    fi
}

startupServices() {
    checkIfInstalled
    authenticate
    # startup only when services are not up
    set +e
    result=$(checkIfAllServicesAreUp)
    exitCode=$?
    set -e
    test "${exitCode}" == "255" || exit ${exitCode}

    echo "~~~ Starting up all services"
    echo "Updating services..."
    if [[ "${DEV_MODE}" != "on" ]]; then
        dockerCompose pull --quiet scanner-engine clair-scanner
    else
        dockerCompose build scanner-engine clair-scanner &>/dev/null
    fi
    
    echo "Done."
    echo "Updating the database..."
    dockerCompose pull --quiet db clair-db
    dockerCompose up -d clair-scanner \
                                api \
                                queue \
                                policy-engine \
                                analyzer \
    &>/dev/null
    syncAnchoreDatabase &>/dev/null
    echo "Done."
    dockerCompose up -d scanner-engine &>/dev/null
    echo "Services startup completed."
    
    sleep 10

    echo "~~~ Performing a health check on the services"
    result=$(healthCheck)
    if [[ "${result}" == "OK" ]]; then
        echo -ne "The services are up and healthy\n\n"
        echo "Image scans are allowed!"
    else
        echo "The services are up but unhealthy"
        echo "Cannot allow scans to run at this moment"
        echo ""
        listServices
        echo -ne "\nTo view logs for a specific service run:"
        echo "  e.g. $0 log-service service_name"
    fi
}

shutdownServices() {
    ( exit $(checkIfAnyServicesAreUp) ) # check if any services are up and exit if there's none

    exitCode=${1:-"0"}
    echo "~~~ Shutting down all services"
    dockerCompose down
    echo "Done."
    exit ${exitCode}
}

logService() {
    checkIfInstalled

    service="${1}"
    docker logs -f -t ${service}
}

#TODO deprecate
checkScanStatus() {
    checkIfInstalled
    result=$(checkIfAllServicesAreUp) # silently check if services are up

    image=$1
    curl -X GET "localhost:8765/v1/docker/scans?name=${image}"
}

listServices() {
    checkIfInstalled
    dockerCompose ps
}

checkIfInstalled() {
     if [[ "$(areAllServiceImagesInstalled)" == 1 ]]; then
        echo "${PRG_NAME} is not installed"
        echo "To install run:"
        echo "  $0 install"
        exit -1
    fi
}

downloadComposeFilesIfMissing() {
    if [[ ! -f "docker-compose.yml" ]]; then
        wget -q https://raw.githubusercontent.com/MeterianHQ/docker-scanner-engine/master/docker-compose.yml
    fi

    if [[ ! -f "anchore-engine-configuration.yml" ]]; then
        wget -q https://raw.githubusercontent.com/MeterianHQ/docker-scanner-engine/master/anchore-engine-configuration.yml
    fi
}

areAllServiceImagesInstalled() {
    downloadComposeFilesIfMissing
    # gather full images names from docker compose files in a file
    serviceImagesFile="images.tmp"
    grep -oP "image:\s+\K.*" docker-compose.yml >> ${serviceImagesFile} \
    && grep -oP "image:\s+\K.*" anchore-engine-configuration.yml >> ${serviceImagesFile}

    # check that each image results installed - hence has an image id
    result=0
    while read -r image
    do
        imageId=$(docker images --format {{.ID}} ${image})
        if [[ -z "${imageId}" ]]; then
            result=1
            break
        fi
    done < "${serviceImagesFile}"

    rm --force ${serviceImagesFile}
    echo $result
}

install() {
    # Download docker-compose yml files if not present
    downloadComposeFilesIfMissing

    if [[ "$(areAllServiceImagesInstalled)" == 1 ]]; then
        echo "~~~ Installing "
        # Pull images for services defined in the docker-compose config files
        echo "Installing services..."
        dockerCompose pull &>/dev/null
        echo "All service were successfully installed"

        # Initialise the database 
        echo "Initialising database..."
        echo "Note: this operation can take up to 10 minutes or more to complete"
        anchoreInitialization
        echo "Initialisation completed"

        echo "The installation was successful."
    else
        echo "$PRG_NAME is already installed"
    fi
}

removeDockerImage() {
    imageId=${1}
    docker rmi --force ${imageId}
}

teardownDb() {
    anchoreDbImageId=$(dockerCompose images --quiet db)
    dockerCompose stop db
    dockerCompose rm --force db
    removeDockerImage ${anchoreDbImageId}
}

anchoreInitialization() {
    # Bringing up anchore services - this brings up the db as it's required by these service definition in the docker compose config.
    dockerCompose up -d api queue policy-engine analyzer &>/dev/null

    # Once the db is done initialising anchore API will be reachable on port 8228 
    # Code below checks this periodically for a set amount of time
    captureCurlResults="curl-results.tmp"
    retryCount=0
    while [[ true ]]; do
        curl -X GET "http://localhost:8228" &> ${captureCurlResults} || true
        if [[ -z "$(grep "\"v1\"" ${captureCurlResults})" ]]; then
            rm --force ${captureCurlResults}
            if [[ ${retryCount} -eq 90 ]]; then
                teardownDb &>/dev/null
                echo "Something went wrong initialising the databases (retry count: ${retryCount})"
                shutdownServices 1 &>/dev/null
            fi
            sleep 10
            retryCount=$((retryCount + 1))
        else
            break
        fi
    done

    rm --force ${captureCurlResults}
    dockerCompose down &>/dev/null
}

# echo "~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~"
# echo "  ${PRG_NAME} v${VERSION}  "
# echo "~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~-"

if [[ $# -eq 0 ]]; then
    showUsageText
    exit 0;
fi

while [[ "$#" -gt 0 ]]; do case $1 in
  help)            showUsageText; exit 0 ;;
  scan)            imageScan "${2:-}"; exit 0 ;;
  startup)         startupServices; exit 0 ;;
  shutdown)        shutdownServices; exit 0 ;;
  log-service)     logService "${2:-}"; exit 0 ;;
  scan-status)     checkScanStatus "${2:-}"; exit 0 ;;
  list-services)   listServices; exit 0 ;;
  install)         install; exit 0 ;;
  version)         echo ${VERSION}; ;;
  *) echo "Unknown command: $1"; exit -1 ;;
esac; shift; done