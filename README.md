# Meterian Docker Scanner Engine

The docker scanner engine is a docker compose application that allows you to perform a security, stability and licensing assessment of a given docker image, fully integrated in the Meterian tools suite.

## Prerequisites
- [Docker](https://docs.docker.com/install/linux/docker-ce/ubuntu/#install-using-the-convenience-script) (v1.12.0+)
- [Docker Compose](https://docs.docker.com/compose/install/#install-compose-on-linux-systems) (v1.9.0+)
- [curl](https://curl.se/) command line tool, required by the script and usually available out-of-the box in modern operating systems

## How to use this application

### Installation
Using the Docker Scanner Engine is very straightforward. First download the [`docker-scanner-engine.sh`](https://raw.githubusercontent.com/MeterianHQ/docker-scanner-engine/master/docker-scanner-engine.sh) script and make it executable

    $ chmod +x docker-scanner-engine.sh

After that start the installation by running

    $ ./docker-scanner-engine.sh install

This will download all required files needed and will install them using docker and docker-compose. 


### Operation
The scanner is a server-side system which exposes APIs that can be called to invoke, control and collect information from scans. It's fully integrated with the [Meterian Dashboard](https://www.meterian.com/dashboard/): every scan will be recorded and managed there. 

Once installed, the server must be started:

    $ ./docker-scanner-engine.sh startup

Once the server is running, it's ready to receive scan requests either via APIs or from the script. You can shutdown the server:

    $ ./docker-scanner-engine.sh shutdown
    
As some of the opensource scanners use their own local database, we suggest to periodically update them (preferabily daily via a cron-like scheduler) using this command:

    $ ./docker-scanner-engine.sh update    

### Executing a scan (via CLI)
Once installed you can run a vulnerability scan of a docker image in the following way

    $ ./docker-scanner-engine.sh scan <image:tag>

Note that to perform a scan a valid Meterian API token must be set as environment variable on your system. To gain a token, create one from your account at https://meterian.com/account/#tokens

Once you have a token populate a `METERIAN_API_TOKEN` environment variable with its value as shown below

```bash
export METERIAN_API_TOKEN=12345678-90ab-cdef-1234-567890abcdef
```

### Executing a scan (via API)
As this is a server side application, all functions are obvioulsy also available via APIs, which are accessible via HTTP at port 8765.
To start a scan you can simply use curl:

    $ curl -X POST "http://localhost:8765/v1/docker/scans?name=image:tag"

A JSON response will be displayed, returning information about the scan. The scan of course continues asynchronously, and its status can be queried:

    $ curl "http://localhost:8765/v1/docker/scans?name=image:tag&what=status"

Once the status is "success", the full outcome of the status can be queried:

    $ curl "http://localhost:8765/v1/docker/scans?name=image:tag&what=result"
    
The full JSON scan result is returned, including the link to the web report on Meterian. Please note that it can also be downloaded directly from the web report or via the [Meterian APIs](http://api.meterian.com/)   

Please note that while you can execute the API call from anywhere in your network (assuming traffic is allowed, of course) the image will be pulled from the server, so from the machine where the script was initially installed.

### Design
The scanner is design to run on your premises, where it can actually access images locally. It is a meta-scanner that integrates:
- three open source scanners 
- Meterian own container scanner
- a final validation stage in the cloud

The final validation in the cloud, which is based on the Meterian curated NVD/MITRE database, minimizes the occurrence of false positives.  Moreover, the results from the Meterian meta-scanner include the full list of licences for each discovered component and the full upgrade path, where available. The Meterian scanner also offers pre-validated bindings to let customers add other non-open source scanners inside the cycle. 


### All available script commands

Executing the script with no parameters prints a mini user manual with all supported commands as shown below

```bash
        Usage: $0 <command> [<args>] [options...]

        Commands:
        install           Installs the application required components
        scan              Scan a specific docker image,
                            e.g. $0 scan bash:latest [--min-security 90 --min-stability 80 --min-licensing 70] [--pull]
        startup           Start up all application services needed 
        shutdown          Stop all application services
        restart           Restart the application services
        update            Update application files and databases
        diagnose          Diagnose the application
        status            Check the application status
        version           Shows the current application version
        help              Print usage manual
```
### Opensource scanners used:

This products uses these opensource scanners:
- [Dagda](https://github.com/eliasgranderubio/dagda)
- [Anchore Engine](https://github.com/anchore/anchore-engine) 
- [Clair](https://github.com/quay/clair) 

Optional bindings for non-opensource scanners are also available: please drop an email to support@meterian.io

## Linux users
You can ensure that you can use Docker as non-root user by running this command:

```bash
    sudo setfacl --modify user:<user name or ID>:rw /var/run/docker.sock
```

Please note that this is effective until the machine is restarted.

