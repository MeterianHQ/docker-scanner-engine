#!/bin/bash

set -e
set -u
set -o pipefail

PRG_NAME="Docker Scanner Engine"
VERSION="0.9.4"
DC_PROJECT_NAME="dse" # Docker Compose Project Name
if [[ -z "${METERIAN_ENV:-}" ]]; then
    export METERIAN_ENV="www"
fi
METERIAN_ENV="${METERIAN_ENV}"
METERIAN_API_TOKEN="${METERIAN_API_TOKEN:-}"
DEV_MODE=${DSE_DEV_MODE:-}

ISO_LOCAL_DATE_TIME="%Y-%m-%dT%H:%M:%S"
ISO_LOCAL_DATE="%Y-%m-%d"

METERIAN_USER_DIR="${HOME}/.meterian/dse"
DIAGNOSIS_FILE="${METERIAN_USER_DIR}/system.log"
MAX_SYSLOG_FILE_SIZE=1000000

DOCKER_COMPOSE_YML_FILENAME="docker-compose.yml"
DOCKER_COMPOSE_YML="${METERIAN_USER_DIR}/${DOCKER_COMPOSE_YML_FILENAME}"
ANCHORE_YML_FILENAME="anchore-engine-configuration.yml"
ANCHORE_YML="${METERIAN_USER_DIR}/${ANCHORE_YML_FILENAME}"

## function for running other functions with a timeout
function run_cmd {
    cmd="$1"; timeout="$2";
    grep -qP '^\d+$' <<< $timeout || timeout=10

    (
        eval "$cmd" &
        child=$!
        trap -- "" SIGTERM
        (
                sleep $timeout
                kill $child 2> /dev/null
        ) &
        wait $child
    )
}

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

_date() {
    format=${1:-$ISO_LOCAL_DATE_TIME}
    date +${format}
}

log() {
    txt="${1:-}"
    options="${2:-}"
    echo ${options} "$(_date) - ${txt}" >> "${DIAGNOSIS_FILE}"
}

printAndLog() {
    txt="${1:-}"
    options="${2:-}"
    log "${txt}" "${options}"
    echo ${options} "${txt}"
}

execAndLog() {
    eval "${*}" 2>&1 | tee -a "${DIAGNOSIS_FILE}"
}

checkIfCurlIsInstalled() {
    log "Checking if curl is installed..."
    set +e
    curl --version >>/dev/null 2>&1
    exitCode=$?
    if [[ "${exitCode}" != "0" ]]; then
        echo "Error: curl is not installed"
        exit -1
    fi
    log "curl is installed"
}

checkThatDockerAndDockerComposeAreInstalled() {
    log "Checking if docker and docker-compose are installed..."
    set +e
    docker --version >>/dev/null 2>&1
    exitCode=$?
    if [[ "${exitCode}" != "0" ]]; then
        echo "Error: docker is not installed"
        exit -1
    fi

    docker-compose --version >>/dev/null 2>&1
    exitCode=$?
    if [[ "${exitCode}" != "0" ]]; then
        echo "Error: docker-compose is not installed"
        exit -1
    fi
    log "Both are installed!"
}

truncateSysLog() {
    tail -c ${MAX_SYSLOG_FILE_SIZE} "${DIAGNOSIS_FILE}" > "${DIAGNOSIS_FILE}.tmp"
    mv "${DIAGNOSIS_FILE}.tmp" ${DIAGNOSIS_FILE}
    rm -f "${DIAGNOSIS_FILE}.tmp"
}

prepareDiagnosisFile() {
    mkdir -p "${METERIAN_USER_DIR}"
    if [[ ! -f ${DIAGNOSIS_FILE} ]]; then
        touch "${DIAGNOSIS_FILE}"
    fi

    truncateSysLog
    execAndLog checkThatDockerAndDockerComposeAreInstalled
    execAndLog checkIfCurlIsInstalled
    echo -ne "\n----\n\n" >> ${DIAGNOSIS_FILE}

    hostDockerVersion="$(docker --version)"
    hostDockerComposeVersion="$(docker-compose --version)"
    echo "$(_date) - Docker version: ${hostDockerVersion}" >> "${DIAGNOSIS_FILE}"
    echo "$(_date) - Docker Compose version: ${hostDockerComposeVersion}" >> "${DIAGNOSIS_FILE}"
    echo -ne "\n----\n\n" >> "${DIAGNOSIS_FILE}"
}
prepareDiagnosisFile

dockerCompose() {
    log "Running docker compose command"
    log "docker-compose '${*}'"
    anchore_engine_conf=""
    reg='pull'
    log "Checking if main command ${1} equals to ${reg}..."
    if [[ "${1}" =~ $reg ]]; then
        log "${reg} is the main docker-compose command, populatin anchore_engine_conf..."
        anchore_engine_conf="-f ${METERIAN_USER_DIR}/${ANCHORE_YML_FILENAME}"
    fi

    if [[ "${DEV_MODE}" != "on" ]]; then
        docker-compose -f ${METERIAN_USER_DIR}/${DOCKER_COMPOSE_YML_FILENAME} ${anchore_engine_conf} --project-name ${DC_PROJECT_NAME} ${*}
    else
        docker-compose -f ${METERIAN_USER_DIR}/docker-compose-dev.yml ${anchore_engine_conf} --project-name ${DC_PROJECT_NAME} ${*}
    fi
}

onExit() {
    # on exit routine
    log "onExit routine taking place..."
    log "Removing all remaining temporary files..."
    rm -f ${METERIAN_USER_DIR}/*.tmp
    # truncate system log file
    log "Truncating system log file..."
    truncateSysLog

    # save service scanner engine logs
    scanner_engine_log_file="${METERIAN_USER_DIR}/scanner_engine_$(_date "${ISO_LOCAL_DATE}").log"
    log "Trying to save scanner-engine service logs to file: ${scanner_engine_log_file}"
    run_cmd "dockerCompose logs -t -f scanner-engine" 1 >> "${scanner_engine_log_file}" || true
    if [[ -s ${scanner_engine_log_file} ]];then
        log "Successfully saved ${scanner_engine_log_file}"
    else
        log "Could not save ${scanner_engine_log_file}"
    fi
}
trap onExit EXIT

#TODO properly implement update
showUsageText() {
    cat << HEREDOC
Usage: $0 <command> [<args>] [options...]

Commands:
install           Install $PRG_NAME
scan              Scan a specific docker image,
                    e.g. $0 scan image:tag [--min-security 90 --min-stability 80 --min-licensing 70]
startup           Start up all services needed for ${PRG_NAME} to function
shutdown          Stop all services associated to ${PRG_NAME}
list-services     List all services
log-service       Allows to view the logs of a specific service
                    e.g. $0 log-service service_name
scan-status       View the status of running scan
                    e.g. $0 scan-status image:tag
version           Shows the current ${PRG_NAME} version
restart           Restart ${PRG_NAME}
update            Update program files and databases
diagnose          Diagnose the application
system-cleanup    Perform an application system clean up
help              Print usage manual

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
    log "Requesting scan for ${image}..."
    curl -sS -X POST "http://localhost:8765/v1/docker/scans?name=${image}" >> ${DIAGNOSIS_FILE} 2>&1
}

apiScanProgressMessage() {
    image=${1}
    outputFile="${METERIAN_USER_DIR}/scan-status-msg.tmp"

    rm --force "${outputFile}"
    log "Requesting scan progress message for ${image}..."
    curl -sS -o "${outputFile}" "http://localhost:8765/v1/docker/scans?name=${image}&what=message&fmt=txt" 2>> ${DIAGNOSIS_FILE}
    progressMessage="$(cat ${outputFile})"
    log "\"${progressMessage}\""
    rm --force "${outputFile}"

    echo "${progressMessage}"
}

getScanStatus() {
    image=${1}
    outputFile="${METERIAN_USER_DIR}/scan-status.tmp"

    rm --force "${outputFile}"
    log "Requesting scan status for ${image}..."
    curl -sS -o "${outputFile}" "http://localhost:8765/v1/docker/scans?name=${image}&what=status&fmt=txt" 2>> ${DIAGNOSIS_FILE}
    status=$(cat ${outputFile})
    log "\"${status}\""
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

MIN_SECURITY=""
MIN_STABILITY=""
MIN_LICENSING=""

isNumeric() {
    maybeNumber="${1}"
    reg='^[+-]?[0-9]+([.][0-9]+)?$'
    if ! [[ ${maybeNumber} =~ $reg ]] ; then
        return 1
    fi

    return 0
}

validateScanOptions() {
    maybeUnknownOption=${1:-}
    # here I'm gonna check if any of the global MIN_... scores has been set at all
    # if at least one is set we proceed normally
    if [[ -z "${MIN_SECURITY}" && -z "${MIN_STABILITY}" && -z "${MIN_LICENSING}" ]];then
        if [[ -n "${maybeUnknownOption}" ]]; then
            printAndLog "Unknown option passed for scan: "${maybeUnknownOption}""
            exit -1
        fi
    elif [[ -n "${MIN_SECURITY}" ]]; then
        exitCode=0
        isNumeric ${MIN_SECURITY} || exitCode=$?
        if [[ "${exitCode}" != "0" ]]; then
            printAndLog "Non-numeric values for the minimum score options are not valid"
        else
            if ((MIN_SECURITY < 0 && MIN_SECURITY > 100)); then
                printAndLog "Acceptable values must be between 0 and 100"
            fi
        fi
    elif [[ -n "${MIN_STABILITY}" ]]; then
        exitCode=0
        isNumeric ${MIN_STABILITY} || exitCode=$?
        if [[ "${exitCode}" != "0" ]]; then
            printAndLog "Non-numeric values for the minimum stability score options are not valid"
        else
            if ((MIN_STABILITY < 0 && MIN_STABILITY > 100)); then
                printAndLog "Acceptable values must be between 0 and 100"
            fi
        fi
    elif [[ -n "${MIN_LICENSING}" ]]; then
        exitCode=0
        isNumeric ${MIN_LICENSING} || exitCode=$?
        if [[ "${exitCode}" != "0" ]]; then
            printAndLog "Non-numeric values for the minimum score options are not valid"
        else
            if ((MIN_LICENSING < 0 && MIN_LICENSING > 100)); then
                printAndLog "Acceptable values must be between 0 and 100"
            fi
        fi
    fi
}

retrieveMinScoresForRemoteAnalysis() {
    shift 2
    if [[ -n "${*:-}" ]];then
        log "Trying to parse options..."
        while [[ "$#" -gt 0 ]]; do case $1 in
            --min-security)    MIN_SECURITY=${2:-}; shift;;
            --min-stability)   MIN_STABILITY=${2:-}; shift;;
            --min-licensing)   MIN_LICENSING=${2:-}; shift;;
            *)                 validateScanOptions; exit 0;;
        esac; shift; done
        log "Now exporting MIN_SECURITY (${MIN_SECURITY}), MIN_STABILITY (${MIN_STABILITY}) and MIN_LICENSING (${MIN_LICENSING}) scores as environment variables for docker compose to pick them up..."
        export MIN_SECURITY=${MIN_SECURITY}
        export MIN_STABILITY=${MIN_STABILITY}
        export MIN_LICENSING=${MIN_LICENSING}
    else 
        log "No options passed for scan"
    fi
}

getAnalysisResultText() {
    outputFile="${METERIAN_USER_DIR}/analysis-result.tmp"

    rm --force "${outputFile}"
    log "Requesting analysis result text for ${image}..."
    curl -sS -o "${outputFile}" "http://localhost:8765/v1/docker/scans?name=${image}&what=result&fmt=txt" 2>> ${DIAGNOSIS_FILE}
    result="$(cat ${outputFile})"
    log "$(echo "${result}")"
    rm --force "${outputFile}"

    echo "${result}"
}

getAnalysisExitCode() {
    outputFile="${METERIAN_USER_DIR}/analysis-exitcode-result.tmp"
    
    rm --force "${outputFile}"
    log "Requesting analysis exitcode for ${image}..."
    curl -sS -o "${outputFile}" "http://localhost:8765/v1/docker/scans?name=${image}&what=exitcode&fmt=txt" 2>> ${DIAGNOSIS_FILE}
    result="$(cat ${outputFile})"
    log "$(echo "${result}")"
    rm --force "${outputFile}"

    echo "${result}"
}

imageScan() {
    log "Scanning image: \"${1}\"..."
    image=$1
    execAndLog validateDockerImageName $image
    checkIfInstalled
    execAndLog checkIfAllServicesAreUp

    log "Trying to retrieve min security, stability, and licensing scores parameters for scan remote analysis..."
    retrieveMinScoresForRemoteAnalysis ${2}
    log "Reloading services to update tied environment variables..."
    echo "Reloading services..."
    dockerCompose up -d >> ${DIAGNOSIS_FILE} 2>&1

    printAndLog
    printAndLog "Pulling \"${image}\"..."
    docker pull "${image}" 2>> ${DIAGNOSIS_FILE}
    printAndLog
    apiScan ${image}
    printAndLog "$(_date) - Scan for \"${image}\" has started"
    execAndLog periodicScanStatusUpdate "${image}" 2
    printAndLog "$(apiScanProgressMessage "${image}")"
    if [[ "$(getScanStatus "${image}")" != "success" ]]; then
        log "Scan was unsuccessful, exiting with code: 255"
        exit -1
    fi

    log "Scan was successful"
    log "Printing remote analysis results..."
    
    printAndLog
    printAndLog "$(getAnalysisResultText)"
    printAndLog

    log "Retrieving analysis exit code..."
    exitCode="$(getAnalysisExitCode)"
    log "Got: \"${exitCode}\""
    exit $exitCode
}

getServicesCount() {
    downloadComposeFilesIfMissing
    # gather full images names from docker compose files in a file
    serviceImagesFile="${METERIAN_USER_DIR}/images.tmp"
    grep -oP "image:\s+\K.*" ${DOCKER_COMPOSE_YML} | tr '"' " " >> ${serviceImagesFile}
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
    reg='200'
    if [[ "$(echo ${curl_output} | head -n 1)" =~ $reg ]]; then
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
    curl -sS -L -I ${domain} --connect-timeout ${timeOut} >> ${DIAGNOSIS_FILE} 2>&1 || exitCode=$?
    echo "${exitCode}"
}

authenticate() {
    if [[ -n "${METERIAN_API_TOKEN}" ]]; then
        echo "~~~ Authentication in progress"

        domainUrl="${METERIAN_ENV}.meterian.com"
        if [[ "$(checkDomainIsReachable ${domainUrl})" != "0" ]]; then
            echo "Authentication failed"
            echo "The domain \"$domainUrl\" is unreachable"
            exit -1
        fi

        exitCode=0
        apiEndpointUrl="${domainUrl}/api/v1/accounts/really-me"
        log "Attempting authentication through API ${apiEndpointUrl} with token ${METERIAN_API_TOKEN}"
        response=$(curl -s -L -I -H 'Authorization: token '${METERIAN_API_TOKEN}''  "${apiEndpointUrl}") || exitCode=$?
        if [[ "${exitCode}" != "0" ]];then
            echo "Authentication error"
            exit -1
        fi

        statusCode=$(echo ${response} | head -n 1)
        reg='200'
        if [[ "${statusCode}" =~ $reg ]]; then
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
    if [[ "${exitCode}" != "255" ]];then
        printAndLog "Services are already up"
        exit ${exitCode}
    fi

    execAndLog authenticate

    log "Starting up all services..."
    printAndLog "~~~ Starting up all services"
    printAndLog "Updating services..."
    if [[ "${DEV_MODE}" != "on" ]]; then
        execAndLog dockerCompose pull scanner-engine clair-scanner
    else
        execAndLog dockerCompose build scanner-engine clair-scanner
    fi

    printAndLog "Done."
    printAndLog "Updating the database..."
    execAndLog dockerCompose pull clair-db inline-scan
    printAndLog "Done."
    execAndLog dockerCompose up -d

    sleep 10

    printAndLog "Services startup completed."
    printAndLog "~~~ Performing a health check on the services"
    result=$(healthCheck)
    log "Health check returned: ${result}"
    if [[ "${result}" == "OK" ]]; then
        printAndLog "The services are up and healthy\n\n" "-ne"
        printAndLog "Image scans are allowed!"
    else
        # TODO change bit below to invite the user to use the diagnose command
        printAndLog "The services are up but unhealthy"
        printAndLog "Cannot allow scans to run at this moment"
        printAndLog ""
        listServices
        printAndLog "\nTo view logs for a specific service run:" "-ne"
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
    if [[ ! -f "${DOCKER_COMPOSE_YML}" ]]; then
        wget -O "${DOCKER_COMPOSE_YML}" -q https://raw.githubusercontent.com/MeterianHQ/docker-scanner-engine/master/${DOCKER_COMPOSE_YML_FILENAME}
        log "Downloaded ${DOCKER_COMPOSE_YML_FILENAME}\nfolder content:\n$(ls -l ${DOCKER_COMPOSE_YML})\n" "-ne"
    fi

    if [[ ! -f "${ANCHORE_YML}" ]]; then
        wget -O "${ANCHORE_YML}" -q https://raw.githubusercontent.com/MeterianHQ/docker-scanner-engine/master/${ANCHORE_YML_FILENAME}
        log "Downloaded ${DOCKER_COMPOSE_YML_FILENAME}\nfolder content:\n$(ls -l ${ANCHORE_YML})\n" "-ne"
    fi
}

areAllServiceImagesInstalled() {
    downloadComposeFilesIfMissing
    # gather full images names from docker compose files in a file
    serviceImagesFile="${METERIAN_USER_DIR}/images.tmp"
    grep -oP "image:\s+\K.*" ${DOCKER_COMPOSE_YML} | tr '"' " " >> ${serviceImagesFile} \
    && grep -oP "image:\s+\K.*" ${ANCHORE_YML} | tr '"' " " >> ${serviceImagesFile}

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
        execAndLog dockerCompose pull
        printAndLog "All service were successfully installed"
        printAndLog "The installation was successful."
    else
        printAndLog "$PRG_NAME is already installed"
    fi
}

restart() {
    printAndLog "Restarting ${PRG_NAME}..."
    shutdownServices
    startupServices
}

updatePrgFilesAndDb() {
    printAndLog "Updating program files and database..."
    downloadComposeFilesIfMissing
    execAndLog dockerCompose pull clair-db inline-scan
}

diagnose() {
# (to grep everything but debug logs  docker logs -f -t dse_scanner-engine_1 | grep -P '^(?!.*DEBUG).*$')
# TODO print diagnosis relevant to last execution ??
: '
    - ideally save last exit code to file (in ~/.meterian/dse) and when asked for diagnosis print relevant message
    related to last execution exit code and save all logs in a zip file and tell user in the same message that
    the latter was saved
    - Do health check in here too
    - restart command
'
    echo "${PRG_NAME} v${VERSION}" # TODO se if we keeping this print here or moving under below line (What looks better pretty much)
    echo "Diagnosing..."
    echo -ne "Are all services installed? "
    if [[ "$(areAllServiceImagesInstalled)" == "0" ]];then
        echo "YES"
        echo "Services health is: "$(healthCheck)""
        echo "Displaying running services..."
        echo
        dockerCompose ps
        echo

        # here we could maybe provide info on last execution by retrieving the last exit code
        echo "Last execution finished with exit code: x"
        echo "x: \"Something something something\""
        # here is some instances we could suggest to restart the $0 restart
        echo

        scanner_engine_log_file="${METERIAN_USER_DIR}/scanner_engine_$(_date "${ISO_LOCAL_DATE}").log"
        diagnosisDumpDir="${HOME}/.$(echo ${PRG_NAME} | tr '[:upper:]' '[:lower:]' |tr ' ' '_')"
        mkdir -p "${diagnosisDumpDir}"
        rm -f ${diagnosisDumpDir}/*

        cp ${DIAGNOSIS_FILE} "${diagnosisDumpDir}/"
        cp ${scanner_engine_log_file} "${diagnosisDumpDir}/"

        zipExitCode=0
        ( cd ${diagnosisDumpDir} ; zip -r "system-logs.zip" . * >> /dev/null 2>&1 ) || zipExitCode=${?}

        if [[ "${zipExitCode}" != "0" ]]; then
            echo "System log files available here: ${diagnosisDumpDir}/"
        else
            rm -f ${diagnosisDumpDir}/*.log
            echo "zip file with system logs available here: ${diagnosisDumpDir}/system-logs.zip"
        fi

    else
        echo "NO"
    fi
}

sysCleanUp() {
    printAndLog "Application system clean up in progress..."
    downloadComposeFilesIfMissing
    log "Removing all one-off containers"
    dockerCompose rm --force >> ${DIAGNOSIS_FILE} 2>&1
    log "Removing all related docker containers"
    dockerCompose rm --stop --force -v scanner-engine clair-db clair-server clair-scanner >> ${DIAGNOSIS_FILE} 2>&1
    printAndLog "Done."
}

# echo "~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~"
# echo "  ${PRG_NAME} v${VERSION}  "
# echo "~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~-"

if [[ $# -eq 0 ]]; then
    showUsageText
    exit 0;
fi

while [[ "$#" -gt 0 ]]; do case $1 in
  help)             showUsageText; exit 0 ;;
  scan)             imageScan "${2:-}" "${*}"; exit 0 ;;
  startup)          startupServices; exit 0 ;;
  shutdown)         shutdownServices; exit 0 ;;
  log-service)      logService "${2:-}"; exit 0 ;;
  scan-status)      checkScanStatus "${2:-}"; exit 0 ;;
  list-services)    listServices; exit 0 ;;
  install)          install; exit 0 ;;
  version)          echo "${PRG_NAME} v${VERSION}"; ;;
  restart)          restart; exit 0 ;;
  update)           updatePrgFilesAndDb; exit 0 ;;
  diagnose)         diagnose; exit 0 ;;
  system-cleanup)   sysCleanUp; exit 0;;
  *) echo "Unknown command: $1"; exit -1 ;;
esac; shift; done
