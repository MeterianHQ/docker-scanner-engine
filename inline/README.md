# Meterian Docker Scanner (inline)

Employ a compact images scanner to perform a one-time analysis on a given Docker image.

## Prerequisites
- [Docker](https://docs.docker.com/install/linux/docker-ce/ubuntu/#install-using-the-convenience-script) (v1.12.0+)

## How to use

### Installation
Download the `docker-inline-scan.sh` script from here [here](https://raw.githubusercontent.com/MeterianHQ/docker-scanner-engine/master//inline/docker-inline-scan.sh) and make it executable. Later invocation of the script will ensure, through Docker, that the inline scanner image is pulled.


### Operation
The inline scanner container is specifically packaged to include all the requisites to support a full image scan. It's fully integrated with the [Meterian Dashboard](https://www.meterian.com/dashboard/): every scan will be recorded and managed there.

### Executing a scan

You can perform a scan by simply specifying the target image to the `docker-inline-scan.sh` script

    $ ./docker-inline-scanner.sh <image:tag>

Note that to perform a scan a valid Meterian API token must be set as environment variable on your system. To gain a token, create one from your account at https://meterian.com/account/#tokens

Once you have a token populate a `METERIAN_API_TOKEN` environment variable with its value as shown below

```bash
export METERIAN_API_TOKEN=12345678-90ab-cdef-1234-567890abcdef
```

Operational overrides are available through the environment variables

| Name | Description |
|------|-------------|
| `DSE_SCAN_TIMEOUT_MINUTES` | Set this variable to override the time limit for single image scans. The default time limit is 10 minutes |

### Opensource scanners used:

This products uses these opensource scanners:
- [Anchore Engine](https://github.com/anchore/anchore-engine) 