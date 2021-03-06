#!/bin/bash
./env_setup.sh --target fdo --distro ubuntu --tag 14.04 --cpu x64
./env_setup.sh --target fdo --distro ubuntu --tag 16.04 --cpu x64
./env_setup.sh --target fdo --distro ubuntu --tag 18.04 --cpu x64
./env_setup.sh --target mapguide --distro ubuntu --tag 14.04 --cpu x64
./env_setup.sh --target mapguide --distro ubuntu --tag 16.04 --cpu x64
#./env_setup.sh --target mapguide --distro ubuntu --tag 18.04 --cpu x64
./env_setup.sh --target fdo --distro centos --tag 7 --cpu x64
./env_setup.sh --target mapguide --distro centos --tag 7 --cpu x64
./env_setup.sh --target fdo --distro centos --tag 6 --cpu x64
./env_setup.sh --target mapguide --distro centos --tag 6 --cpu x64

# generic is a special centos6 image for building the common libs subset
./env_setup.sh --target mapguide --distro centos --tag 6 --cpu x64 --generic
docker system prune