# Meterian Docker Scanner Engine

Meterian offers a set of scanners and solutions to perform a security, stability and licensing assessment of a given Docker image. Refer to the following available options for what suits you best:

- **[server](server/README.md)**: runs as an application server, including multiple OSS engines, exposes APIs supporting concurrent executions but still has the convenience of a CLI script; it requires docker and docker-compose
- **[inline](inline/README.md)**: a docker image that can be easily embedded in your CI/CD pipeline, with simple companion script to execute the analysis; it requires only docker.

If you are using the scanner occasionally or in a specific CI/CD integration/pipeline. the **inline** version is certainly more suitable. If however you plan an extensive use on premises of the scanner the **server** version is preferable. See the details in the corresponding pages.
<br/><br/>



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

