#!/bin/bash
#./env_setup.sh --target fdo --distro ubuntu --tag 16.04 --cpu x64
#./env_setup.sh --target fdo --distro ubuntu --tag 18.04 --cpu x64
./env_setup.sh --target fdo --distro ubuntu --tag 22.04 --cpu x64
#./env_setup.sh --target mapguide --distro ubuntu --tag 16.04 --cpu x64
#./env_setup.sh --target mapguide --distro ubuntu --tag 18.04 --cpu x64
./env_setup.sh --target mapguide --distro ubuntu --tag 22.04 --cpu x64

# Generic is an image based on rockylinux
./env_setup.sh --target fdo --distro generic --cpu x64
./env_setup.sh --target mapguide --distro generic --cpu x64

# Use podman if available, otherwise docker
. ./container_engine.sh

"$DOCKER_CMD" system prune