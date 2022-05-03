# Meterian Docker Scanner Engine

Meterian offers a set of scanners and solutions to perform a security, stability and licensing assessment of a given Docker image. Refer to the following available options for what suits you best:

- [server](server/README.md)
- [inline](inline/README.md)

## Linux users
As the above offerings use Docker, here are some considerations to ensure they function properly.

You can ensure that you can use Docker as non-root user by running this command:

```bash
    sudo setfacl --modify user:<user name or ID>:rw /var/run/docker.sock
```

Please note that this is effective until the machine is restarted: after a restart you will have to re-issue the command.

