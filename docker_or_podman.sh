#!/bin/bash

# Check if we have docker or podman
# aliases won't work for us here so variable-ize the relevant executable
export DOCKER=docker
export DOCKER_COMPOSE=docker-compose
which docker
if [ $? -eq 1 ]; then
    echo "Docker not found. Checking if we have podman"
    which podman
    if [ $? -eq 1 ]; then
        echo "FATAL: Docker or podman not found on system. Install one or the other"
        exit 1
    else
        echo "Podman found. Aliasing docker commands to podman"
        export DOCKER=podman
        export DOCKER_COMPOSE="podman compose"
    fi
else
    echo "Docker found. Using its CLI tools"
fi