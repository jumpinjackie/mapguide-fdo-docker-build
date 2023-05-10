#!/bin/bash
#./env_setup.sh --target fdo --distro ubuntu --tag 16.04 --cpu x64
#./env_setup.sh --target fdo --distro ubuntu --tag 18.04 --cpu x64
./env_setup.sh --target fdo --distro ubuntu --tag 22.04 --cpu x64
#./env_setup.sh --target mapguide --distro ubuntu --tag 16.04 --cpu x64
#./env_setup.sh --target mapguide --distro ubuntu --tag 18.04 --cpu x64
./env_setup.sh --target mapguide --distro ubuntu --tag 22.04 --cpu x64
./env_setup.sh --target fdo --distro centos --tag 7 --cpu x64
./env_setup.sh --target mapguide --distro centos --tag 7 --cpu x64

# Generic is an image based on centos7 for building the common libs subset
./env_setup.sh --target fdo --distro generic --cpu x64
./env_setup.sh --target mapguide --distro generic --cpu x64
docker system prune