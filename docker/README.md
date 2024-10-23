# Codex Docker Image

 Codex provides pre-built docker images and they are stored in the [codexstorage/nim-codex](https://hub.docker.com/repository/docker/codexstorage/nim-codex) repository.


## Run

 We can run Codex Docker image using CLI
 ```shell
 # Default run
 docker run --rm codexstorage/nim-codex

 # Mount local datadir
 docker run -v ./datadir:/datadir --rm codexstorage/nim-codex codex --data-dir=/datadir
 ```

 And Docker Compose
 ```shell
 # Run in detached mode
 docker-compose up -d
 ```


## Arguments

 Docker image is based on the [codex.Dockerfile](codex.Dockerfile) and there is
  ```
  ENTRYPOINT ["/docker-entrypoint.sh"]
  CMD ["codex"]
  ```

 It means that at the image run it will just run `codex` application without any arguments and we can pass them as a regular arguments, by overriding command
 ```shell
 docker run codexstorage/nim-codex codex --api-bindaddr=0.0.0.0 --api-port=8080
 ```


## Environment variables

 We can configure Codex using [Environment variables](../README#environment-variables) and [docker-compose.yaml](docker-compose.yaml) file can be useful as an example.

 We also added a temporary environment variable `NAT_IP_AUTO` to the entrypoint which is set as `false` for releases and ` true` for regular builds. That approach is useful for Dist-Tests.
 ```shell
 # Disable NAT_IP_AUTO for regular builds
 docker run -e NAT_IP_AUTO=false codexstorage/nim-codex
 ```


## Slim
 1. Build the image using `docker build -t codexstorage/codexsetup:latest -f codex.Dockerfile ..`
 2. The docker image can then be minified using [slim](https://github.com/slimtoolkit/slim). Install slim on your path and then run:
    ```shell
    slim # brings up interactive prompt
    >>> build --target status-im/codexsetup --http-probe-off true
    ```
 3. This should output an image with name `status-im/codexsetup.slim`
 4. We can then bring up the image using `docker-compose up -d`.
