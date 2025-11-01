#!/bin/sh

# Load container engine selection (podman preferred, otherwise docker)
. ./container_engine.sh

# clean thin images first
"$DOCKER_CMD" images | grep _thin_ | awk '{print $3}' | xargs -r "$DOCKER_CMD" rmi --force

# then clean the run images
"$DOCKER_CMD" images | grep _run_ | awk '{print $3}' | xargs -r "$DOCKER_CMD" rmi --force