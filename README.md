# Meterian Docker Scanner

Employ a compact images scanner to perform a one-time analysis on a given Docker image.

## Prerequisites
- [Docker](https://docs.docker.com/install/linux/docker-ce/ubuntu/#install-using-the-convenience-script) (v1.12.0+)

## How to use

### Installation
Download the `docker-scan.sh` script from here [here](https://raw.githubusercontent.com/MeterianHQ/docker-scanner-engine/master/docker-scan.sh) and make it executable. A later invocation of the script will ensure, through Docker, that the scanner image [`meterian/cs-engine:latest`](https://hub.docker.com/r/meterian/cs-engine) is pulled. Subsequent invocations of the script will not ensure this, so newer versions of the image can be accessed through docker pull. 


### Operation
The Docker scanner container is specifically packaged to include all the requisites to support a full image scan. It's fully integrated with the [Meterian Dashboard](https://www.meterian.com/dashboard/): every scan will be recorded and managed there.

### Executing a scan

You can perform a scan by simply specifying the target image to the `docker-scan.sh` script

    $ ./docker-scan.sh <image:tag>

Note that to perform a scan a valid Meterian API token must be set as environment variable on your system. To gain a token, create one from your account at https://meterian.com/account/#tokens

Once you have a token populate a `METERIAN_API_TOKEN` environment variable with its value as shown below

```bash
export METERIAN_API_TOKEN=12345678-90ab-cdef-1234-567890abcdef
```

### Operational overrides and options

Operational overrides are available through the environment variables

| Name | Description |
|------|-------------|
| `DSE_SCAN_TIMEOUT_MINUTES` | Set this variable to override the time limit for single image scans. The default time limit is 10 minutes |
| `METERIAN_ENV` | For on-premises instances of Meterian set this variable to target the right subdomain of the site where your instance runs |
| `METERIAN_PROTO` | For on-premises instances of Meterian set this variable to target the right HTTP protocol of the site where your instance runs |
| `METERIAN_DOMAIN` | For on-premises instances of Meterian set this variable to target the right domain of the site where your instance runs |

A list of the supported option is listed below and can be consulted by invoking the script with `--help`
```
./docker-scan.sh --help

usage: [command] DOCKER_IMAGE_NAME [OPTIONS] i.e.
./docker-scan.sh redis:latest [--min-score=95]

OPTIONS:
    --debug                     Display the DEBUG logs
    --fail-gracefully           The system will fail gracefully in case of network errors
    --help                      Displays this help and exits(0)
    --info                      Display the INFO logs
    --min-licensing <SCORE>     Specifies the minimum licensing level to pass the build (default: --min-licensing=95 or as set in the account)
    --min-security <SCORE>      Specifies the minimum security level to pass the build (default: --min-security=90 or as set in the account)
    --min-stability <SCORE>     Specifies the minimum stability level to pass the build (default: --min-stability=80 or as set in the account)
    --project-branch <BRANCH>   Specifies project branch, by default the tag of the image is used (example: --project-branch=latest)
    --project-commit <COMMIT>   Specifies project commit, by default the digest of the image is used (example: --project-commit=9460cabbf623945495e6108c9d1979a9e7b5d8e7)
    --project-tags <TAGS>       Allows to add a set of user defined tags (comme separated) to the project (example: --project-tags=production,platform)
    --project-url <URL>         Specifies project url, by default the repository name of the image is used (example: --project-url=registry.redhat.io/openshift3/ose-pod)
    --report-console            Ouputs the scan report on the console (default: color if not specified - options color|nocolor|security|stability|licensing) 
                                (example: --report-console=nocolor,security)
    --report-json <FILENAME>    Produces an JSON report file (example: --report-json=report.json)
    --report-junit <FILENAME>   Produces a JUNIT XML report file (example: --report-junit=report.xml)
    --report-pdf <FILENAME>     Produces an PDF report file (example: --report-pdf=report.pdf)
    --report-sbom <FILENAME>    Produces a Software Bill Of Meterials report file, format can be specified (see the doc)  (example: --report-sbom=sbom.csv)
    --report-tree               Produces a dependency tree, optionally on file where format can be specified (txt/json) (example: --report-tree=tree.txt)
    --tpn                       Displays the third party notice for this application and exits(0)
    --version                   Show the version

```

## Linux users
As the above offerings use Docker, here are some considerations to ensure they function properly.

### Option A - giving access to the docker socket
You can ensure that you can use Docker as non-root user by running this command:

```bash
    sudo setfacl --modify user:<user name or ID>:rw /var/run/docker.sock
```

Please note that this is effective only until the machine is restarted. **After a restart you will have to re-issue the command.**

### Option B - using a custom 'docker' group for your docker enabled users

Create the docker group.
```bash
sudo groupadd docker
```

Add your user to the docker group.
```bash
sudo usermod -aG docker $USER
```

Log out and log back in so that your group membership is re-evaluated. **This setup will be permanent and will work across restarts.**


## Opensource scanners used:

This product uses these opensource scanners:
- [Trivy](https://github.com/aquasecurity/trivy)
- [Grype](https://github.com/anchore/grype)
- [Syft](https://github.com/anchore/syft)
