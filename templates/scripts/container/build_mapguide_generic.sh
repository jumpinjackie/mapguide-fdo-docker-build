#!/bin/bash

check_build()
{
    error=$?
    if [ $error -ne 0 ]; then
        echo "$LIB_NAME: Error build failed ($error)................."
        # Return back to this dir before bailing
        cd "$SOURCE_DIR" || exit
        exit $error
    fi
}

OEM_BUILD_DIR=/tmp/work/build_area/oem
BUILD_DIR=/tmp/work/build_area/mapguide
SRC_DIR=/tmp/work/src
ARTIFACTS_DIR=/tmp/work/artifacts
MG_VER=${MG_VER_TRIPLE}.${MG_VER_REV}

echo "Building MapGuide Common Libs ${MG_VER_TRIPLE} (v${MG_VER})"

# Centos 6 special
. scl_source enable devtoolset-7
mkdir -p $OEM_BUILD_DIR
mkdir -p $BUILD_DIR
cd $SRC_DIR || exit
# For Centos 6, we're building all internal thirdparty libs that are required by the common libs subset
./cmake_bootstrap.sh --oem-working-dir $OEM_BUILD_DIR --build 64 --with-ccache --with-all-internal --common-subset-only
check_build
./cmake_build.sh --oem-working-dir $OEM_BUILD_DIR --cmake-build-dir $BUILD_DIR --ninja --common-subset-only
check_build
cd $BUILD_DIR || exit
cmake --build . --target install
check_build
cd /usr/local/mapguideopensource-common-${MG_VER_TRIPLE} || exit
tar -zcf $ARTIFACTS_DIR/mapguideopensource-common-$MG_VER-generic-linux-amd64.tar.gz *
check_build
ccache -s