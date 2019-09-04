#!/bin/bash
mkdir -p logs

BUILD_DISTRO=

check_build()
{
    if [ "$?" -ne 0 ] ; then
        echo "ERROR building MapGuide for $BUILD_DISTRO"
        exit 1
    fi
}

# Ubuntu 14
BUILD_DISTRO=ubuntu14
./build_thin.sh --target fdo --distro ubuntu --tag 14 --cpu x64 2>&1 | tee logs/fdo_thin_ubuntu14.log
check_build
./build_thin.sh --target mapguide --distro ubuntu --tag 14 --cpu x64 2>&1 | tee logs/mapguide_thin_ubuntu14.log
check_build
# Ubuntu 16
BUILD_DISTRO=ubuntu16
./build_thin.sh --target fdo --distro ubuntu --tag 16 --cpu x64 2>&1 | tee logs/fdo_thin_ubuntu16.log
check_build
./build_thin.sh --target mapguide --distro ubuntu --tag 16 --cpu x64 2>&1 | tee logs/mapguide_thin_ubuntu16.log
check_build
# Ubuntu 18
BUILD_DISTRO=ubuntu18
./build_thin.sh --target fdo --distro ubuntu --tag 18 --cpu x64 2>&1 | tee logs/fdo_thin_ubuntu18.log
check_build
# CentOS 6
BUILD_DISTRO=centos6
./build_thin.sh --target fdo --distro centos --tag 6 --cpu x64 2>&1 | tee logs/fdo_thin_centos6.log
check_build
./build_thin.sh --target mapguide --distro centos --tag 6 --cpu x64 2>&1 | tee logs/mapguide_thin_centos6.log
check_build
# CentOS 7
BUILD_DISTRO=centos7
./build_thin.sh --target fdo --distro centos --tag 7 --cpu x64 2>&1 | tee logs/fdo_thin_centos7.log
check_build
./build_thin.sh --target mapguide --distro centos --tag 7 --cpu x64 2>&1 | tee logs/mapguide_thin_centos7.log
check_build
docker system prune