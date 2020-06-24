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
METERIAN_USER_DIR="${HOME}/.meterian/dse"
DIAGNOSIS_FILE="${METERIAN_USER_DIR}/system.log"

exportDockerBin() {
    dockerBin="$(which docker)"
    if [[ "${dockerBin}" =~ snap ]]; then
        export DSE_DOCKER_BIN="/snap/docker/current/bin/docker"
    else
        export DSE_DOCKER_BIN="${dockerBin}"
    fi
}
exportDockerBin

getDateTime() {
    format=${1:-$ISO_LOCAL_DATE_TIME}
    date +${format}
}

log() {
    txt="${1:-}"
    options="${2:-}"
    echo ${options} "$(getDateTime) - ${txt}" >> "${DIAGNOSIS_FILE}"
}

printAndLog() {
    txt="${1:-}"
    options="${2:-}"
    log "${txt}" "${options}"
    echo ${options} "${txt}"
}

execAndLog() {
    eval "${*}" | tee -a "${DIAGNOSIS_FILE}"
}

checkThatDockerAndDockerComposeAreInstalled() {
    log "Checking if docker and docker-compose are installed..."
    set +e
    docker --version >>/dev/null 2>&1
    exitCode=$?
    if [[ "${exitCode}" != "0" ]]; then
        echo "Error: Docker is not installed"
        exit -1
    fi

    docker-compose --version >>/dev/null 2>&1
    exitCode=$?
    if [[ "${exitCode}" != "0" ]]; then
        echo "Error: Docker Compose is not installed"
        exit -1
    fi
    log "Both are installed!"
}

prepareDiagnosisFile() {
    rm --force "${DIAGNOSIS_FILE}"
    mkdir -p "${METERIAN_USER_DIR}"
    touch "${DIAGNOSIS_FILE}"

    execAndLog checkThatDockerAndDockerComposeAreInstalled
    echo -ne "\n----\n\n" >> ${DIAGNOSIS_FILE}

    hostDockerVersion="$(docker --version)"
    hostDockerComposeVersion="$(docker-compose --version)"
    echo "$(getDateTime) - Docker version: ${hostDockerVersion}" >> "${DIAGNOSIS_FILE}"
    echo "$(getDateTime) - Docker Compose version: ${hostDockerComposeVersion}" >> "${DIAGNOSIS_FILE}"
    echo -ne "\n----\n\n" >> "${DIAGNOSIS_FILE}"
}
prepareDiagnosisFile

dockerCompose() {
    anchore_engine_conf=""
    if [[ "${1}" =~ "pull" ]]; then
        anchore_engine_conf="-f anchore-engine-configuration.yml"
    fi

    if [[ "${DEV_MODE}" != "on" ]]; then
        docker-compose -f docker-compose.yml ${anchore_engine_conf} --project-name ${DC_PROJECT_NAME} ${*}
    else
        docker-compose -f docker-compose-dev.yml ${anchore_engine_conf} --project-name ${DC_PROJECT_NAME} ${*}
    fi
}

showUsageText() {
    cat << HEREDOC
        Usage: $0 <command> [<args>]

        Commands:
        install          Install $PRG_NAME
        scan             Scan a specific docker image,
                         e.g. $0 scan image:tag
        startup          Start up all services needed for ${PRG_NAME} to function
        shutdown         Stop all services associated to ${PRG_NAME}
        list-services    List all services
        log-service      Allows to view the logs of a specific service
                          e.g. $0 log-service service_name
        scan-status      View the status of running scan
                          e.g. $0 scan-status image:tag
        version          Shows the current ${PRG_NAME} version
        help             Print usage manual
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

apiScan() {
    image=${1}

    curl -X POST "http://localhost:8765/v1/docker/scans?name=${image}" >> ${DIAGNOSIS_FILE} 2>&1
}

apiScanProgressMessage() {
    image=${1}

    outputFile="scan-status-msg.tmp"
    rm --force "${outputFile}"
    curl -o "${outputFile}" "http://localhost:8765/v1/docker/scans?name=${image}&fmt=txt" >> ${DIAGNOSIS_FILE} 2>&1
    progressMessage="$(cat ${outputFile})"
    rm --force "${outputFile}"

    echo "${progressMessage}"
}

getScanStatus() {
    image=${1}
    outputFile="scan-status.tmp"

    rm --force "${outputFile}"
    curl -o "${outputFile}" "http://localhost:8765/v1/docker/scans?name=${image}&status=true" >> ${DIAGNOSIS_FILE} 2>&1
    status=$(cat ${outputFile})
    rm --force "${outputFile}"

    echo "${status}"
}

periodicScanStatusUpdate() {
    image=${1}
    interval=${2:-"1"}

    previousMsg=""
    scanStatus="$(getScanStatus "${image}")"
    while [[ "${scanStatus}" != "success" && "${scanStatus}" != "failure" && "${scanStatus}" != "scan_failure" ]]; do
        currentMsg="$(apiScanProgressMessage "${image}")"
        if [[ "${previousMsg}" != "${currentMsg}" ]]; then
            echo "${currentMsg}"
            previousMsg="${currentMsg}"
        fi
        sleep ${interval}
        scanStatus="$(getScanStatus "${image}")"
    done
}

imageScan() {
    log "Scanning image: \"${1}\"..."
    image=$1
    execAndLog validateDockerImageName $image
    checkIfInstalled
    execAndLog checkIfAllServicesAreUp

    printAndLog
    printAndLog "$(getDateTime) - Pulling \"${image}\"..."
    docker pull "${image}" >> ${DIAGNOSIS_FILE} 2>&1
    apiScan ${image}
    printAndLog "$(getDateTime) - Scan for \"${image}\" has started"
    execAndLog periodicScanStatusUpdate "${image}" 2
    printAndLog "$(apiScanProgressMessage "${image}")"
    if [[ "$(getScanStatus "${image}")" != "success" ]]; then
        log "Scan was unsuccessful, exiting with code: 255"
        exit -1
    fi
    log "Scan was successful, exiting with code: 0"
}

getServicesCount() {
    downloadComposeFilesIfMissing
    # gather full images names from docker compose files in a file
    serviceImagesFile="images.tmp"
    grep -oP "image:\s+\K.*" docker-compose.yml | tr '"' " " >> ${serviceImagesFile}
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

checkDomainIsReachable () {
    domain=$1
    timeOut=${2:-"30"}

    exitCode=0
    curl -s -L -I ${domain} --connect-timeout ${timeOut} >> ${DIAGNOSIS_FILE} 2>&1 || exitCode=$?
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
    # startup only when services are not up
    log "Checking if services are down..."
    set +e
    result=$(checkIfAllServicesAreUp)
    exitCode=$?
    set -e
    log "Check completed with exit code: ${exitCode}"
    test "${exitCode}" == "255" || exit ${exitCode}

    execAndLog authenticate

    log "Starting up all services..."
    printAndLog "~~~ Starting up all services"
    printAndLog "Updating services..."
    if [[ "${DEV_MODE}" != "on" ]]; then
        dockerCompose pull scanner-engine clair-scanner >> ${DIAGNOSIS_FILE} 2>&1
    else
        dockerCompose build scanner-engine clair-scanner >> ${DIAGNOSIS_FILE} 2>&1
    fi
    
    printAndLog "Done."
    printAndLog "Updating the database..."
    dockerCompose pull clair-db inline-scan >> ${DIAGNOSIS_FILE} 2>&1
    printAndLog "Done."
    dockerCompose up -d >> ${DIAGNOSIS_FILE} 2>&1
    printAndLog "Services startup completed."
    
    sleep 10

    printAndLog "~~~ Performing a health check on the services"
    result=$(healthCheck)
    log "Health check returned: ${result}"
    if [[ "${result}" == "OK" ]]; then
        printAndLog "The services are up and healthy\n\n" "-ne"
        printAndLog "Image scans are allowed!"
    else
        printAndLog "The services are up but unhealthy"
        printAndLog "Cannot allow scans to run at this moment"
        printAndLog ""
        listServices
        printAndLog -ne "\nTo view logs for a specific service run:"
        printAndLog "  e.g. $0 log-service service_name"
    fi
}

shutdownServices() {
    log "Shutting down all services"
    log "Checking if any service is up..."
    ( exit $(checkIfAnyServicesAreUp) ) # check if any services are up and exit if there's none
    log "Services are up - proceeding with shutdown"

    exitCode=${1:-"0"}
    printAndLog "~~~ Shutting down all services"
    execAndLog dockerCompose down
    printAndLog "Done."

    log "Exiting with code ${exitCode}"
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
    log "Requested list of all running services"
    execAndLog dockerCompose ps
}

checkIfInstalled() {
    log "Checking if all services are installed..."
    if [[ "$(areAllServiceImagesInstalled)" == 1 ]]; then

        log "Not all services are installed
$(docker images --format "table {{.Repository}}:{{.Tag}}\t{{.ID}}" | grep -P "(anchore|meterian)")"

        echo "${PRG_NAME} is not installed"
        echo "To install run:"
        echo "  $0 install"
        exit -1
    fi
    log "All services are installed"
}

downloadComposeFilesIfMissing() {
    if [[ ! -f "docker-compose.yml" ]]; then
        wget -q https://raw.githubusercontent.com/MeterianHQ/docker-scanner-engine/master/docker-compose.yml
        log "Downloaded docker-compose.yml\nfolder content:\n$(ls -l docker-compose.yml)\n" "-ne"
    fi

    if [[ ! -f "anchore-engine-configuration.yml" ]]; then
        wget -q https://raw.githubusercontent.com/MeterianHQ/docker-scanner-engine/master/anchore-engine-configuration.yml
        log "Downloaded docker-compose.yml\nfolder content:\n$(ls -l docker-compose.yml)\n" "-ne"    
    fi
}

areAllServiceImagesInstalled() {
    downloadComposeFilesIfMissing
    # gather full images names from docker compose files in a file
    serviceImagesFile="images.tmp"
    grep -oP "image:\s+\K.*" docker-compose.yml | tr '"' " " >> ${serviceImagesFile} \
    && grep -oP "image:\s+\K.*" anchore-engine-configuration.yml | tr '"' " " >> ${serviceImagesFile}

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
        printAndLog "~~~ Installing "
        # Pull images for services defined in the docker-compose config files
        printAndLog "Installing services..."
        dockerCompose pull >> ${DIAGNOSIS_FILE} 2>&1
        printAndLog "All service were successfully installed"
        printAndLog "The installation was successful."
    else
        printAndLog "$PRG_NAME is already installed"
    fi
}

getDiagnosis() {
    cp ${DIAGNOSIS_FILE} .
    echo "diagnosis file available here: $(pwd)/system.log"
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
  diagnose)        getDiagnosis; exit 0 ;;
  version)         echo ${VERSION}; ;;
  *) echo "Unknown command: $1"; exit -1 ;;
esac; shift; done