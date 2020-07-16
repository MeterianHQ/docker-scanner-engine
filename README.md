# Docker Scanner Engine

The docker scanner engine is a docker compose application that allows you to perform a vulnerability scan of a given docker image.

## Prerequisites
- [Docker](https://docs.docker.com/install/linux/docker-ce/ubuntu/#install-using-the-convenience-script) (v1.12.0+)
- [Docker Compose](https://docs.docker.com/compose/install/#install-compose-on-linux-systems) (v1.9.0+)

## How to use it

### Installation
Using the Docker Scanner Engine is very straightforward. First download the [`docker-scanner-engine.sh`](https://raw.githubusercontent.com/MeterianHQ/docker-scanner-engine/master/docker-scanner-engine.sh) script and make it executable

    $ chmod +x docker-scanner-engine.sh

After that start the installation by running

    $ ./docker-scanner-engine.sh install

This will simply download required files needed to make the application function.

## Scan
Once installed you can run a vulnerability scan of a docker image in the following way

    $ ./docker-scanner-engine.sh scan <image:tag>

Note that to perform a scan a valid Meterian API token must be set as environment variable on your system. To gain a token, create one from your account at https://meterian.com/account/#tokens

Once you have a token populate a `METERIAN_API_TOKEN` environment variable with its value as shown below

```bash
export METERIAN_API_TOKEN=12345678-90ab-cdef-1234-567890abcdef
```

## Further commands

Executing the script with no parameters prints a mini user manual with all supported commands as shown below

```bash
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
        help              Print usage manual
```
