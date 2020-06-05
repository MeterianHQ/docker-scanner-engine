# Docker Scanner Engine

The docker scanner engine is a docker compose application that allows you to perform a vulnerability scan of a given docker image.

## Prerequisites
- [Docker](https://docs.docker.com/install/linux/docker-ce/ubuntu/#install-using-the-convenience-script)
- [Docker Compose](https://docs.docker.com/compose/install/#install-compose-on-linux-systems)

## How to use it

### Installation
Using the Docker Scanner Engine is very straightforward. First download the [`docker-scanner-engine.sh`](https://raw.githubusercontent.com/MeterianHQ/docker-scanner-engine/master/docker-scanner-engine.sh) script and make it executable

    $ chmod +x docker-scanner-engine.sh

After that start the installation by running

    $ ./docker-scanner-engine.sh install

This will simply download required file needed to make the application function.

## Scan
One installed you can run a vulnerability scan of a docker image in the following way

    $ ./docker-scanner-engine.sh scan <image:tag>

## Further commands

Executing the script with no parameters prints a mini user manual with all supported commands as shown below

```bash
        Usage: ./docker-scanner-engine.sh <command> [<args>]

        Commands:
        install         Install Docker Scanner Engine
        scan            Scan a specific docker image,
                        e.g. ./docker-scanner-engine.sh scan image:tag
        startup         Start up all services needed for Docker Scanner Engine to function
        shutdown        Stop all services associated to Docker Scanner Engine
        listServices    List all services
        logService      Allows to view the logs of a specific service
                          e.g. ./docker-scanner-engine.sh logService service_name
        scanStatus      View the status of running scan
                          e.g. ./docker-scanner-engine.sh scanStatus image:tag
        version         Shows the current Docker Scanner Engine version
        help            Print usage manual

```
