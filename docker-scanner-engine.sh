#!/bin/bash

set -e
set -u
set -o pipefail

PRG_NAME="Docker Scanner Engine"
VERSION="0.1"
DC_PROJECT_NAME="dse" # Docker Compose Project Name

showUsageText() {
    cat << HEREDOC
        Usage: $0 <command> [<args>]

        Commands:
        scan            Scan a specific docker image,
                        e.g. $0 scan image:tag
        startup         Start up all services needed for ${PRG_NAME} to function
        shutdown        Stop all services associated to ${PRG_NAME}
        listServices    List all services
        logService      Allows to view the logs of a specific service
                          e.g. $0 logService service_name
        scanStatus      View the status of running scan
                          e.g. $0 scanStatus image:tag
        help            Print usage manual
HEREDOC
}

validateDockerImageName() {
    image="${1:-}"
    if [[ -z "${image}" ]]; then
        echo "Docker image name cannot be empty"
        exit 1
    elif [[ -z "$(echo ${image} | grep '^[^:]\+:\{1\}[^:]\+$')" ]]; then
        echo "Docker image '${image}' does not match a valid format"
        echo "valid Docker image name: image:tag"
        exit 1;
    fi
}

imageScan() {
    image=$1
    validateDockerImageName $image
    checkServicesAreUp

    echo
    echo "Scan for ${image} has started"
    curl -X POST localhost:8765/v1/docker/scans?name=${image}
    echo
    echo "To check the scan status run:"
    echo "  $0 scanStatus ${image}"
}

checkServicesAreUp() {
    echo "~~~ Checking if services are up"

    expected_services=10
    services_count=$(docker-compose -f docker-compose.yml -f anchore-engine-configuration.yml --project-name ${DC_PROJECT_NAME} ps -q | wc -l)
    if [[ ${expected_services} -ne ${services_count} ]]; then
        echo "Services are not up and running"
        echo "  to start up services run:"
        echo "      $0 startup"
        exit 1
    else
        echo "All services are up and running"
    fi
}

checkIfVulnerabilityDBsAreDoneUpdating() {
    echo "The vulnerability databases are being updated. Waiting on completion"
    echo "Note: this operation could take up to 20-30 minutes if it's your first time"
    echo "To check the progress, view logs for service: 'dse_scanner-engine_1'" 

    echo
    retryCount=0
    while [[ true ]]; do
        curl_output=$(curl -s -L -I -X GET localhost:8765/admin/version || true)
        if [[ -z "${curl_output}" ]]; then
            if [[ ${retryCount} -eq 60 ]]; then #TODO the db update operation is incremental; how long do we want to wait for this?
                echo "Something went wrong updating the databases (retry count: ${retryCount})"
                echo "Please view logs for the 'dse_scanner-engine_1' service:"
                echo "  $0 logService dse_scanner-engine_1"
                exit 1
            fi
            sleep 5
            retryCount=$((retryCount + 1))
        else
            echo "~~~ The vulnerability databases were successfully updated"
            break
        fi
    done 
}

healthCheck() {
    result=""
    curl_output=$(curl -s -L -I -X GET localhost:8765/admin/healthcheck)
    if [[ "$(echo ${curl_output} | head -n 1)" =~ "200" ]]; then
        result="OK"
    else
        result="NOT OK"
    fi

    echo ${result}
}

install() {
    #TODO wget of the needed docker compose yml files
}

startupServices() {
    echo "~~~ Starting up all services"
    docker-compose -f docker-compose.yml -f anchore-engine-configuration.yml --project-name ${DC_PROJECT_NAME} pull &>/dev/null \
    && docker-compose -f docker-compose.yml -f anchore-engine-configuration.yml --project-name ${DC_PROJECT_NAME} up -d &>/dev/null
    
    checkIfVulnerabilityDBsAreDoneUpdating

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
        echo "  e.g. $0 logService service_name"
    fi
}

shutdownServices() {
    exitCode=${1:-"0"}
    echo "~~~ Shutting down all services"
    docker-compose -f docker-compose.yml -f anchore-engine-configuration.yml --project-name ${DC_PROJECT_NAME} down &>/dev/null
    echo "Done."
    exit ${exitCode}
}

logService() {
    service="${1}"
    docker logs -f -t ${service}
}

checkScanStatus() {
    image=$1
    curl -X GET localhost:8765/v1/docker/scans?name=${image}
}

listServices() {
    docker-compose -f docker-compose.yml -f anchore-engine-configuration.yml --project-name ${DC_PROJECT_NAME} ps
}

echo "~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~"
echo "  ${PRG_NAME} v${VERSION}  "
echo "~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~-"

echo

if [[ $# -eq 0 ]]; then
    showUsageText
    exit 0;
fi

while [[ "$#" -gt 0 ]]; do case $1 in
  help)           showUsageText; exit 0 ;;
  scan)           imageScan "${2:-}"; exit 0 ;;
  startup)        startupServices "${2:-}"; exit 0 ;;
  shutdown)       shutdownServices "${2:-}"; exit 0 ;;
  logService)     logService "${2:-}"; exit 0 ;;
  scanStatus)     checkScanStatus "${2:-}"; exit 0 ;;
  listServices)   listServices "${2:-}"; exit 0 ;;
  install)        install "${2:-}"; exit 0 ;;
  *) echo "Unknown command: $1"; exit 1 ;;
esac; shift; done