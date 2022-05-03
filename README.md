# Meterian Docker Scanner Engine

Meterian offers a set of scanners and solutions to perform a security, stability and licensing assessment of a given Docker image. Refer to the following available options for what suits you best:

- [server](server/README.md): runs as an application server, including multiple OSS engines, exposes APIs supporting concurrent executions but still has the convenience of a CLI script; it requires docker and docker-compose
- [inline](inline/README.md): a docker image that can be easily embedded in your CI/CD pipeline, with simple companion script to excute the analysis; it requires only docker.

## Linux users
As the above offerings use Docker, here are some considerations to ensure they function properly.

You can ensure that you can use Docker as non-root user by running this command:

```bash
    sudo setfacl --modify user:<user name or ID>:rw /var/run/docker.sock
```

Please note that this is effective until the machine is restarted: after a restart you will have to re-issue the command.

