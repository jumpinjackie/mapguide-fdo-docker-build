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
MG_VER_TRIPLE=${MG_VER_MAJOR}.${MG_VER_MINOR}.${MG_VER_REL}
MG_VER=${MG_VER_TRIPLE}.${MG_VER_REV}

echo "Building MapGuide ${MG_VER_TRIPLE} (v${MG_VER} - ${MG_BUILD_CONFIG})"
echo "Using FDO SDK at: ${ARTIFACTS_DIR}/${FDOSDK}"
ccache -s

if [ ! -f "${ARTIFACTS_DIR}/${FDOSDK}" ]; then
    echo "FATAL: FDO SDK (${ARTIFACTS_DIR}/${FDOSDK}) not found"
    exit 1
fi

echo "Installing FDO SDK"
mkdir -p /usr/local/fdo-${FDO_VER_TRIPLE}
tar -zxf ${ARTIFACTS_DIR}/${FDOSDK} -C /usr/local/fdo-${FDO_VER_TRIPLE}

# Centos 7 special
. scl_source enable devtoolset-9
mkdir -p $OEM_BUILD_DIR
mkdir -p $BUILD_DIR
cd $SRC_DIR || exit
# For Centos 7, we're building all internal thirdparty libs
./cmake_bootstrap.sh --config $MG_BUILD_CONFIG --oem-working-dir $OEM_BUILD_DIR --build 64 --with-ccache --with-all-internal
check_build
./cmake_linuxapt.sh --prefix /usr/local/mapguideopensource-${MG_VER_TRIPLE} --oem-working-dir $OEM_BUILD_DIR --working-dir $LINUXAPT_BUILD
check_build
./cmake_build.sh --oem-working-dir $OEM_BUILD_DIR --cmake-build-dir $BUILD_DIR --mg-ver-major $MG_VER_MAJOR --mg-ver-minor $MG_VER_MINOR --mg-ver-rel $MG_VER_REL --mg-ver-rev $MG_VER_REV --ninja
check_build
cd $BUILD_DIR || exit
cmake --build . --target install
check_build
cd /usr/local/mapguideopensource-${MG_VER_TRIPLE} || exit
tar -zcf $ARTIFACTS_DIR/mapguideopensource-$MG_VER-$MG_DISTRO-amd64.tar.gz *
check_build
ccache -s