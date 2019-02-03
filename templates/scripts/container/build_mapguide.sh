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
LINUXAPT_BUILD=/tmp/work/build_area/linuxapt
BUILD_DIR=/tmp/work/build_area/mapguide
SRC_DIR=/tmp/work/src
ARTIFACTS_DIR=/tmp/work/artifacts
PATCHES_DIR=/tmp/work/patches

echo "Building MapGuide ${MG_VER_TRIPLE} (v${MG_VER})"
echo "Using FDO SDK at: ${ARTIFACTS_DIR}/${FDOSDK}"
ccache -s

echo "Installing FDO SDK"
mkdir -p /usr/local/fdo-${FDO_VER_TRIPLE}
tar -zxf ${ARTIFACTS_DIR}/${FDOSDK} -C /usr/local/fdo-${FDO_VER_TRIPLE}

echo "Copying atomic.h"
mkdir -p /usr/include/asm
cp $PATCHES_DIR/atomic.h /usr/include/asm

. scl_source enable devtoolset-7
mkdir -p $OEM_BUILD_DIR
mkdir -p $BUILD_DIR
cd $SRC_DIR || exit
./cmake_bootstrap.sh --oem-working-dir $OEM_BUILD_DIR --build 64 --with-ccache --with-all-internal
check_build
./cmake_linuxapt.sh --prefix /usr/local/mapguideopensource-${MG_VER_TRIPLE} --oem-working-dir $OEM_BUILD_DIR --working-dir $LINUXAPT_BUILD
check_build
./cmake_build.sh --oem-working-dir $OEM_BUILD_DIR --cmake-build-dir $BUILD_DIR --ninja
check_build
cmake --build . --target install
check_build
cd /usr/local/mapguideopensource-${MG_VER_TRIPLE} || exit
tar -zcf $ARTIFACTS_DIR/mapguideopensource-$MG_VER-centos6-amd64.tar.gz *
check_build
ccache -s