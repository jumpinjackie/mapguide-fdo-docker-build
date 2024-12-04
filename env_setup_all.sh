#!/bin/bash

# Check if we have docker or podman
# aliases won't work for us here so variable-ize the relevant executable
DOCKER=docker
DOCKER_COMPOSE=docker-compose
which docker
if [ $? -eq 1 ]; then
    echo "Docker not found. Checking if we have podman"
    which podman
    if [ $? -eq 1 ]; then
        echo "FATAL: Docker or podman not found on system. Install one or the other"
        exit 1
    else
        echo "Podman found. Aliasing docker commands to podman"
        DOCKER=podman
        DOCKEER_COMPOSE="podman compose"
    fi
else
    echo "Docker found. Using its CLI tools"
fi

#./env_setup.sh --target fdo --distro ubuntu --tag 16.04 --cpu x64
#./env_setup.sh --target fdo --distro ubuntu --tag 18.04 --cpu x64
./env_setup.sh --target fdo --distro ubuntu --tag 22.04 --cpu x64
#./env_setup.sh --target mapguide --distro ubuntu --tag 16.04 --cpu x64
#./env_setup.sh --target mapguide --distro ubuntu --tag 18.04 --cpu x64
./env_setup.sh --target mapguide --distro ubuntu --tag 22.04 --cpu x64
#./env_setup.sh --target fdo --distro centos --tag 7 --cpu x64
#./env_setup.sh --target mapguide --distro centos --tag 7 --cpu x64

# Generic is an image based on holy-build-box
./env_setup.sh --target fdo --distro generic --cpu x64
./env_setup.sh --target mapguide --distro generic --cpu x64
$DOCKER system prune