#!/bin/bash
mkdir -p logs

BUILD_DISTRO=

check_build()
{
    if [ "$?" -ne 0 ] ; then
        echo "ERROR building for $BUILD_DISTRO"
        exit 1
    fi
}

# # Ubuntu 16
# BUILD_DISTRO=ubuntu16
# ./build_thin.sh --target fdo --distro ubuntu --tag 16 --cpu x64 2>&1 | tee logs/fdo_thin_ubuntu16_release.log
# check_build
# ./build_thin.sh --target mapguide --distro ubuntu --tag 16 --cpu x64 2>&1 | tee logs/mapguide_thin_ubuntu16_release.log
# check_build
# ./build_thin.sh --target fdo --distro ubuntu --tag 16 --cpu x64 --debug 2>&1 | tee logs/fdo_thin_ubuntu16_debug.log
# check_build
# ./build_thin.sh --target mapguide --distro ubuntu --tag 16 --cpu x64 --debug 2>&1 | tee logs/mapguide_thin_ubuntu16_debug.log
# check_build
# # Ubuntu 18
# BUILD_DISTRO=ubuntu18
# ./build_thin.sh --target fdo --distro ubuntu --tag 18 --cpu x64 2>&1 | tee logs/fdo_thin_ubuntu18_release.log
# check_build
# ./build_thin.sh --target fdo --distro ubuntu --tag 18 --cpu x64 --debug 2>&1 | tee logs/fdo_thin_ubuntu18_debug.log
# check_build
# ./build_thin.sh --target mapguide --distro ubuntu --tag 18 --cpu x64 2>&1 | tee logs/mapguide_thin_ubuntu18_release.log
# check_build
# ./build_thin.sh --target mapguide --distro ubuntu --tag 18 --cpu x64 --debug 2>&1 | tee logs/mapguide_thin_ubuntu18_debug.log
# check_build
# Ubuntu 22
BUILD_DISTRO=ubuntu22
./build_thin.sh --target fdo --distro ubuntu --tag 22 --cpu x64 2>&1 | tee logs/fdo_thin_ubuntu22_release.log
check_build
./build_thin.sh --target fdo --distro ubuntu --tag 22 --cpu x64 --debug 2>&1 | tee logs/fdo_thin_ubuntu22_debug.log
check_build
./build_thin.sh --target mapguide --distro ubuntu --tag 22 --cpu x64 2>&1 | tee logs/mapguide_thin_ubuntu22_release.log
check_build
./build_thin.sh --target mapguide --distro ubuntu --tag 22 --cpu x64 --debug 2>&1 | tee logs/mapguide_thin_ubuntu22_debug.log
check_build
BUILD_DISTRO=generic
./build_thin.sh --target fdo --distro generic --cpu x64 2>&1 | tee logs/fdo_thin_generic_release.log
check_build
./build_thin.sh --target mapguide --distro generic --cpu x64 2>&1 | tee logs/mapguide_thin_generic_release.log
check_build
./build_thin.sh --target fdo --distro generic --cpu x64 --debug 2>&1 | tee logs/fdo_thin_generic_debug.log
check_build
./build_thin.sh --target mapguide --distro generic --cpu x64 --debug 2>&1 | tee logs/mapguide_thin_generic_debug.log
check_build
docker system prune --force