#!/bin/bash

echo "Building MapGuide ${MG_VER_TRIPLE} (v${MG_VER})"
echo "Using FDO SDK at: /tmp/work/artifacts/${FDOSDK}"
ccache -s

OEM_BUILD_DIR=/tmp/work/build_area/oem
LINUXAPT_BUILD=/tmp/work/build_area/linuxapt
BUILD_DIR=/tmp/work/build_area/mapguide
SRC_DIR=/tmp/work/src
ARTIFACTS_DIR=/tmp/work/artifacts

. scl_source enable devtoolset-7
mkdir -p $OEM_BUILD_DIR
mkdir -p $BUILD_DIR
cd $SRC_DIR || exit
./cmake_bootstrap.sh --oem-working-dir $OEM_BUILD_DIR --build 64 --with-ccache --with-all-internal
./cmake_linuxapt.sh --prefix /usr/local/mapguideopensource-${MG_VER_TRIPLE} --oem-working-dir $OEM_BUILD_DIR --working-dir $LINUXAPT_BUILD
./cmake_build.sh --oem-working-dir $OEM_BUILD_DIR --cmake-build-dir $BUILD_DIR --ninja
cmake --build . --target install
cd /usr/local/mapguideopensource-${MG_VER_TRIPLE} || exit
tar -zcf $ARTIFACTS_DIR/mapguideopensource-$MG_VER-centos6-amd64.tar.gz *
ccache -s