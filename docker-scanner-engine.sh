#!/bin/bash

set -e
set -u
set -o pipefail

PRG_NAME="Docker Scanner Engine"
VERSION="0.9.10"
DC_PROJECT_NAME="dse" # Docker Compose Project Name
if [[ -z "${METERIAN_ENV:-}" ]]; then
    export METERIAN_ENV="www"
fi
METERIAN_ENV="${METERIAN_ENV}"
METERIAN_API_TOKEN="${METERIAN_API_TOKEN:-}"
DEV_MODE=${DSE_DEV_MODE:-}

ISO_LOCAL_DATE_TIME="%Y-%m-%dT%H:%M:%S"
ISO_LOCAL_DATE="%Y-%m-%d"
FILE_FRIENDLY_LOCAL_DATE_TIME_FORMAT="%d-%m-%Y-%H-%M-%S"

METERIAN_USER_DIR="${HOME}/.meterian/dse"
SCANNER_ENGINE_LOG_FILE_PREFIX="scanner_engine_scan_"
MAX_SYSLOG_FILE_SIZE="1MB"

DOCKER_COMPOSE_YML_FILENAME="docker-compose.yml"
DOCKER_COMPOSE_YML="${METERIAN_USER_DIR}/${DOCKER_COMPOSE_YML_FILENAME}"
ANCHORE_YML_FILENAME="anchore-engine-configuration.yml"
ANCHORE_YML="${METERIAN_USER_DIR}/${ANCHORE_YML_FILENAME}"

DSE_COMPOSEFILE_BRANCH="${DSE_COMPOSEFILE_BRANCH:-master}"

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

DIAGNOSIS_FILE="${METERIAN_USER_DIR}/${RANDOM}_system.log"

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
    set -e
    log "curl is installed"
}

checkThatDockerAndDockerComposeAreInstalled() {
    log "Checking if docker and docker-compose are installed..."
    set +e

    docker-compose --version >>/dev/null 2>&1
    exitCode=$?
    if [[ "${exitCode}" != "0" ]]; then
        echo "Error: docker-compose is not installed"
        exit -1
    fi

    docker --version >>/dev/null 2>&1
    exitCode=$?
    if [[ "${exitCode}" != "0" ]]; then
        echo "Error: docker is not installed"
        exit -1
    else
        docker ps -a >>${DIAGNOSIS_FILE} 2>&1
        exitCode=$?
        if [[ "${exitCode}" != "0" ]]; then
            echo "Error: docker is not setto be used as non-root user"
            echo "Please ensure docker can be used non-root user:"
            echo "  e.g. 'sudo setfacl --modify user:<user name or ID>:rw /var/run/docker.sock'"
            exit -1
        fi
    fi

    set -e
    log "Both are installed!"
}

truncateSysLog() {
    tempName="${RANDOM}_temp_syslog.tmp"
    tail -c ${MAX_SYSLOG_FILE_SIZE} "${DIAGNOSIS_FILE}" > "${tempName}"
    mv "${tempName}" ${DIAGNOSIS_FILE}
    rm -f "${tempName}"
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

scannerEngineLogFileName() {
    echo "${METERIAN_USER_DIR}/${RANDOM}_${SCANNER_ENGINE_LOG_FILE_PREFIX}$(_date "${FILE_FRIENDLY_LOCAL_DATE_TIME_FORMAT}").log"
}

onExit() {
    # on exit routine
    log "onExit routine taking place..."
    log "Removing all remaining temporary files..."
    rm -f ${METERIAN_USER_DIR}/*.tmp

    # truncate system log file
    log "Truncating system log file..."
    truncateSysLog

    # remove scan logs older than a week
    find "${METERIAN_USER_DIR}" -maxdepth 1 -mtime +7 -type f -name "*.log" -delete

    # save service scanner engine logs
    scanner_engine_log_file="$(scannerEngineLogFileName)"
    log "Trying to save scanner-engine service logs to file: ${scanner_engine_log_file}"
    run_cmd "dockerCompose logs -t -f scanner-engine" 1 > "${scanner_engine_log_file}" || true
    if [[ -s ${scanner_engine_log_file} ]];then
        log "Successfully saved ${scanner_engine_log_file}"
    else
        log "Could not save ${scanner_engine_log_file}"
    fi
}
trap onExit EXIT

showUsageText() {
    cat << HEREDOC
Usage: $0 <command> [<args>] [options...]

Commands:
install           Install $PRG_NAME
scan              Scan a specific docker image,
                    e.g. $0 scan bash:latest [--min-security 90 --min-stability 80 --min-licensing 70] [--pull]
startup           Start up all services needed for ${PRG_NAME} to function
shutdown          Stop all services associated to ${PRG_NAME}
version           Shows the current ${PRG_NAME} version
restart           Restart ${PRG_NAME}
update            Update program files and databases
diagnose          Diagnose the application
status            Check the application status
credits           Shows application credits
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
    outputFile="${METERIAN_USER_DIR}/${RANDOM}_scan-status-msg.tmp"

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
    outputFile="${METERIAN_USER_DIR}/${RANDOM}_scan-status.tmp"

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
            echo "$(_date) - ${currentMsg}"
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
    otherApprovedOptionsReg='(--pull)'
    if [[ "${1}" =~ $otherApprovedOptionsReg ]]; then
        return 0
    fi

    maybeUnknownOption=${1:-}
    # here I'm gonna check if any of the global MIN_... scores has been set at all
    # if at least one is set we proceed normally
    if [[ -z "${MIN_SECURITY}" && -z "${MIN_STABILITY}" && -z "${MIN_LICENSING}" ]];then
        if [[ -n "${maybeUnknownOption}" ]]; then
            printAndLog "Unknown option passed for scan: "${maybeUnknownOption}""
            printAndLog "Ensure the command is being executed correctly:"
            printAndLog "   e.g. $0 scan bash:latest [--min-security 90 --min-stability 80 --min-licensing 70] [--pull]"
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
        log "Checking parameters passed $1"
        while [[ "$#" -gt 0 ]]; do case $1 in
            --min-security)    MIN_SECURITY=${2:-}; shift;;
            --min-stability)   MIN_STABILITY=${2:-}; shift;;
            --min-licensing)   MIN_LICENSING=${2:-}; shift;;
            *)                 log "Non matching parameter $1, now calling validateScanOptions()"; validateScanOptions $1; ;;
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
    outputFile="${METERIAN_USER_DIR}/${RANDOM}_analysis-result.tmp"

    rm --force "${outputFile}"
    log "Requesting analysis result text for ${image}..."
    curl -sS -o "${outputFile}" "http://localhost:8765/v1/docker/scans?name=${image}&what=result&fmt=txt" 2>> ${DIAGNOSIS_FILE}
    result="$(cat ${outputFile})"
    log "$(echo "${result}")"
    rm --force "${outputFile}"

    echo "${result}"
}

getAnalysisExitCode() {
    outputFile="${METERIAN_USER_DIR}/${RANDOM}_analysis-exitcode-result.tmp"

    rm --force "${outputFile}"
    log "Requesting analysis exitcode for ${image}..."
    curl -sS -o "${outputFile}" "http://localhost:8765/v1/docker/scans?name=${image}&what=exitcode&fmt=txt" 2>> ${DIAGNOSIS_FILE}
    result="$(cat ${outputFile})"
    log "$(echo "${result}")"
    rm --force "${outputFile}"

    echo "${result}"
}

canPullImage() {
    log "Checking if $1 can be pulled from dockerHub"
    imageAndTagParsedForApiCall=$(echo "${1}" | sed "s/\:/\/tags\//")
    endpoints=(
        "https://hub.docker.com/v2/repositories/library/$imageAndTagParsedForApiCall"
        "https://hub.docker.com/v2/repositories/$imageAndTagParsedForApiCall"
    )

    reg='200'
    result=0;
    for endpoint in "${endpoints[@]}"
    do
        log "checking $endpoint"
        curl_output=$(curl -s -L -I -X GET "${endpoint}")
        if [[ "$(echo ${curl_output} | head -n 1)" =~ $reg ]]; then
            log "$1 can be pulled through endpoint $endpoint"
            result=0
            break
        else
            log "$1 cannot be pulled through endpoint $endpoint"
            result=1
            continue
        fi
    done

    return $result
}

isImageAvailableLocally() {
    result=0
    if [[ -n "$(docker images "${1}" -q)" ]]; then
        result=0
    else
        result=1
    fi

    return $result
}

checkImagePresenceAndPullIfRequested() {
    image=${1}

    reg='--pull'
    exitCode=0
    isImageAvailableLocally "${image}" || exitCode=$?
    if [[ "${exitCode}" == "1" ]];then
        log "$image is not available locally, checking if it can be pulled instead..."

        log "'\$*' at this point is ${2}"
        if [[ "${2}" =~ $reg ]];then
            log "Presented --pull flag, now checking if it can be pulled..."

            exitCode=0
            canPullImage "${image}" || exitCode=$?
            if [[ "${exitCode}" == "1" ]];then
                log "$image cannot be pulled either, aborting..."
                printAndLog "Image ${image} was not found"
                exit -1
            else
                printAndLog "Pulling \"${image}\"..."
                docker pull "${image}" 2>> ${DIAGNOSIS_FILE}
                printAndLog
            fi
        else
            log "No --pull flag present, checking if ${image} is present locally..."

            printAndLog "Image ${image} was not found locally"
            printAndLog "Specify the flag --pull if you want to pull it:"
            printAndLog "   $0 scan ${image} --pull"
            exit -1
        fi
    else
        log "Image ${image} was found locally"

        if [[ "${2}" =~ $reg ]];then
            log "Presented --pull flag, now checking if it can be pulled..."

            exitCode=0
            canPullImage "${image}" || exitCode=$?
            if [[ "${exitCode}" == "1" ]];then
                log "$image cannot be pulled, must've been built locally, proceeding with scan..."
            else
                printAndLog "Pulling \"${image}\"..."
                docker pull "${image}" 2>> ${DIAGNOSIS_FILE}
                printAndLog
            fi
        fi
    fi
}

wasScanCreated() {
    img="${1}"
    log "Checking if scan process for ${img} was created..."
    outputFile="${METERIAN_USER_DIR}/${RANDOM}_status_code.tmp"
    curl -sSI -o "${outputFile}" -X GET "http://localhost:8765/v1/docker/scans?name=${img}&what=status&fmt=txt"

    result="$(head -n 1 "${outputFile}")"
    rm -f "${outputFile}"
    if [[ "${result}" =~ '404' ]]; then
        log "Scan process for ${img} was not created"
        echo "NO"
    else
        log "Scan process for ${img} was created"
        echo "YES"
    fi

}

imageScan() {
    log "Scanning image: \"${1}\"..."
    image=$1
    execAndLog validateDockerImageName $image
    checkIfInstalled
    execAndLog checkIfAllServicesAreUp
    printAndLog

    log "Trying to retrieve min security, stability, and licensing scores parameters for scan remote analysis..."
    retrieveMinScoresForRemoteAnalysis ${2}
    log "Reloading services to update tied environment variables..."
    dockerCompose up --quiet-pull -d >> ${DIAGNOSIS_FILE} 2>&1

    checkImagePresenceAndPullIfRequested "${image}" "${2}"

    apiScan ${image}
    if [[ "$(wasScanCreated "${image}")" == "NO" ]]; then
        printAndLog "Error: cannot scan ${image}, unsupported image."
        exit -1
    fi
    printAndLog "$(_date) - Scan for \"${image}\" has started"
    execAndLog periodicScanStatusUpdate "${image}" 2
    printAndLog "$(apiScanProgressMessage "${image}")"
    if [[ "$(getScanStatus "${image}")" != "success" ]]; then
        log "Scan was unsuccessful, exiting with code: 255"
        echo "Unsuccessful scan!"
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
    downloadComposeFiles
    # gather full images names from docker compose files in a file
    serviceImagesFile="${METERIAN_USER_DIR}/${RANDOM}_image_names.tmp"
    grep -oP "image:\s+\K.*" ${DOCKER_COMPOSE_YML} | tr '"' " " >> ${serviceImagesFile}
    result=$(cat ${serviceImagesFile} | wc -l)
    rm --force ${serviceImagesFile}

    echo ${result}
}

checkIfAllServicesAreUp() {
    echo "~~~ Checking if services are up"

    expected_services=$(getServicesCount)
    services_count=$(dockerCompose ps --services --filter "status=running" | wc -l)
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
        execAndLog dockerCompose pull -q scanner-engine clair-scanner
    else
        execAndLog dockerCompose build scanner-engine clair-scanner
    fi

    printAndLog "Done."
    printAndLog "Updating the database..."
    execAndLog dockerCompose pull -q clair-db dagda-db inline-scan
    printAndLog "Done."
    execAndLog dockerCompose up --quiet-pull -d

    sleep 10

    printAndLog "Services startup completed."
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
        dockerCompose ps >> ${DIAGNOSIS_FILE} 2>&1
        printAndLog "To perform diagnosis run:"
        printAndLog "  e.g. $0 diagnose"
    fi
}

shutdownServices() {
    log "Shutting down all services"
    log "Checking if any service is up..."
    ( exit $(checkIfAnyServicesAreUp) ) # check if any services are up and exit if there's none
    log "Services are up - proceeding with shutdown"

    printAndLog "~~~ Shutting down all services"
    execAndLog dockerCompose down
    printAndLog "Done."
}

shutdownServicesAndExit() {
    shutdownServices

    exitCode=${1:-"0"}
    log "Exiting with code ${exitCode}"
    exit ${exitCode}
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

downloadComposeFiles() {
    wget -N -O "${DOCKER_COMPOSE_YML}" -q https://raw.githubusercontent.com/MeterianHQ/docker-scanner-engine/${DSE_COMPOSEFILE_BRANCH}/${DOCKER_COMPOSE_YML_FILENAME}
    log "Downloaded ${DOCKER_COMPOSE_YML_FILENAME}\nfolder content:\n$(ls -l ${DOCKER_COMPOSE_YML})\n" "-ne"

    wget -N -O "${ANCHORE_YML}" -q https://raw.githubusercontent.com/MeterianHQ/docker-scanner-engine/${DSE_COMPOSEFILE_BRANCH}/${ANCHORE_YML_FILENAME}
    log "Downloaded ${ANCHORE_YML_FILENAME}\nfolder content:\n$(ls -l ${ANCHORE_YML})\n" "-ne"
}

areAllServiceImagesInstalled() {
    downloadComposeFiles
    # gather full images names from docker compose files in a file
    serviceImagesFile="${METERIAN_USER_DIR}/${RANDOM}_images.tmp"
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
    credits
    # Download docker-compose yml files if not present
    downloadComposeFiles

    if [[ "$(areAllServiceImagesInstalled)" == 1 ]]; then
        printAndLog "~~~ Installing "
        # Pull images for services defined in the docker-compose config files
        printAndLog "Installing services..."
        execAndLog dockerCompose pull -q
        printAndLog "All service were successfully installed"
        printAndLog "The installation was successful."
    else
        printAndLog "$PRG_NAME is already installed"
    fi
}

restart() {
    printAndLog "Restarting ${PRG_NAME}..."
    exitCode=0
    checkIfAnyServicesAreUp || exitCode=$?
    if [[ "${exitCode}" == "0" ]]; then
        shutdownServices
    fi
    startupServices
}

updatePrgFilesAndDb() {
    printAndLog "Updating program files and database..."
    downloadComposeFiles
    execAndLog dockerCompose pull -q
    printAndLog "Done."
    restart
}

zipData() {
    # zipping logs to current folder
    diagnosisDumpDir="${METERIAN_USER_DIR}/archives-dir"
    mkdir -p "${diagnosisDumpDir}"
    rm -rf ${diagnosisDumpDir}/*

    log "Moving log files to dump dir for imminent archiving..."
    cp ${DIAGNOSIS_FILE} "${diagnosisDumpDir}/"
    # copying all scan logs created within the span of a week
    find "${METERIAN_USER_DIR}" -maxdepth 1 -mtime -7 -type f -name "${SCANNER_ENGINE_LOG_FILE_PREFIX}*" -exec cp '{}' "${diagnosisDumpDir}/" \;

    if [[ -n "$(docker volume ls | grep -o "dse_scanners-volume" || true)" ]]; then
        log "Docker volume exists, copying scanners scan data from it..."
        docker container create --name temp -v dse_scanners-volume:/data meterian/cs-engine >> ${DIAGNOSIS_FILE} 2>&1
        docker cp temp:/data/scanner-setups "${diagnosisDumpDir}/" >> ${DIAGNOSIS_FILE} 2>&1
        docker rm -f temp >> ${DIAGNOSIS_FILE} 2>&1
        log "Data successfully copied"

        #remove executables
        log "Removing executable from scan data before archiving..."
        find "${diagnosisDumpDir}/scanner-setups/" -type f -perm /a+x -delete >> ${DIAGNOSIS_FILE} 2>&1
        log "Done."
    fi

    zipExitCode=1
    ( cd ${diagnosisDumpDir} ; zip -r "system-logs.zip" . * >> /dev/null 2>&1 ) || zipExitCode=${?}
    if [[ -s "${diagnosisDumpDir}/system-logs.zip" ]]; then
        zipExitCode=0
    fi

    if [[ "${zipExitCode}" != "0" ]]; then
        cp ${diagnosisDumpDir}/* $(pwd)
        printAndLog "System log files available here: $(pwd)/"
    else
        rm -f ${diagnosisDumpDir}/*.log
        cp "${diagnosisDumpDir}/system-logs.zip" $(pwd)
        printAndLog "zip file with system logs available here: $(pwd)/system-logs.zip"
    fi
}

diagnose() {
# (to grep everything but debug logs  docker logs -f -t dse_scanner-engine_1 | grep -P '^(?!.*DEBUG).*$')
    log "Requested diagnosis:"
    printAndLog "${PRG_NAME} v${VERSION}"
    printAndLog "Diagnosing..."

    # general checks
    printAndLog "Are all services installed? " "-ne"
    if [[ "$(areAllServiceImagesInstalled)" == "0" ]];then
        printAndLog "YES"

        statusResult=$(status)
        printAndLog "Are services up? " "-ne"
        if [[ "${statusResult}" == "UP" ]]; then
            printAndLog "YES"

            log "Displaying running services..."
            dockerCompose ps >> ${DIAGNOSIS_FILE} 2>&1
            printAndLog "Are services healthy? " "-ne"
            if [[ "$(healthCheck)" == "OK" ]]; then
                printAndLog "YES"
            else
                printAndLog "NO"
                printAndLog "Try restarting $PRG_NAME:"
                printAndLog "   $0 restart"
                printAndLog "If this issue persists please reach out to Meterian's support line"
                zipData
            fi

        else
            printAndLog "NO"
            printAndLog "To startup run the following:"
            printAndLog "   $0 startup"
        fi

    else
        printAndLog "NO"
        printAndLog "Consider installing $PRG_NAME first by running the install command:"
        printAndLog "   $0 install"
    fi
}

status() {
    log "System status requested"
    expected_services=$(getServicesCount)
    services_count=$(dockerCompose ps --services --filter "status=running"  | wc -l)
    if [[ ${expected_services} -ne ${services_count} ]]; then
        log "All services are not up"
        dockerCompose ps >> ${DIAGNOSIS_FILE} 2>&1
        printAndLog "DOWN"
    else
        log "All services are up"
        if [[ "$(healthCheck)" == "OK" ]]; then
            log "All services are healthy"
            printAndLog "UP"
        else
            printAndLog "DOWN"
        fi
    fi
}

credits() {
    echo "Meterian Docker Scanner Engine v$VERSION"
    echo "© 2017-2021 Meterian Ltd - All rights reserved"
    echo
    echo "Also powered by:"
    echo "Anchore Inline Scan v0.7.1, Apache License 2.0"
    echo "Clair Scanner v2.0.6, Apache License 2.0"
    echo "Dagda v0.8.0, Apache License 2.0"
    echo
}

if [[ $# -eq 0 ]]; then
    showUsageText
    exit 0;
fi

while [[ "$#" -gt 0 ]]; do case $1 in
  help)             showUsageText; exit 0 ;;
  scan)             imageScan "${2:-}" "${*}"; exit 0 ;;
  startup)          startupServices; exit 0 ;;
  shutdown)         shutdownServicesAndExit; exit 0 ;;
  install)          install; exit 0 ;;
  version)          echo "${PRG_NAME} v${VERSION}"; ;;
  restart)          restart; exit 0 ;;
  update)           updatePrgFilesAndDb; exit 0 ;;
  diagnose)         diagnose; exit 0 ;;
  status)           status; exit 0;;
  credits)          credits; exit 0;;
  *) echo "Unknown command: $1"; exit -1 ;;
esac; shift; done
