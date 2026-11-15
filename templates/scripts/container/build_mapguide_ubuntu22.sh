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

export PATH=$PATH:$HOME/.dotnet
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

echo "Copying atomic.h"
mkdir -p /usr/include/asm
cp $PATCHES_DIR/atomic.h /usr/include/asm

mkdir -p $OEM_BUILD_DIR
mkdir -p $BUILD_DIR
cd $SRC_DIR || exit
./cmake_bootstrap.sh --config $MG_BUILD_CONFIG --oem-working-dir $OEM_BUILD_DIR --build 64 --with-ccache --have-system-xerces --with-internal-geos
check_build
./cmake_linuxapt.sh --prefix /usr/local/mapguideopensource-${MG_VER_TRIPLE} --oem-working-dir $OEM_BUILD_DIR --working-dir $LINUXAPT_BUILD
check_build
CMDEX=
if [ "$MG_BUILD_CONFIG" = "Debug" ]; then
    echo "Building with ASAN instrumentation"
    CMDEX="--with-asan"
fi
./cmake_build.sh --oem-working-dir $OEM_BUILD_DIR --cmake-build-dir $BUILD_DIR --mg-ver-major $MG_VER_MAJOR --mg-ver-minor $MG_VER_MINOR --mg-ver-rel $MG_VER_REL --mg-ver-rev $MG_VER_REV --ninja $CMDEX
check_build
cd $BUILD_DIR || exit
cmake --build . --target install
check_build
cd $SRC_DIR || exit
echo "Preparing test pack"
./prepare_test_pack.sh --output /tmp/mgtest --install-dir "/usr/local/mapguideopensource-${MG_VER_TRIPLE}"
check_build
cd /tmp/mgtest || exit
tar -zcf $ARTIFACTS_DIR/mapguide-test-pack-"$MG_DISTRO".tar.gz .
check_build
cd /usr/local/mapguideopensource-${MG_VER_TRIPLE} || exit
tar -zcf $ARTIFACTS_DIR/mapguideopensource-$MG_VER-$MG_DISTRO-amd64.tar.gz *
check_build
case "$MG_DISTRO" in
    *ubuntu*)
        echo "Generating deb packages"
        cd $SRC_DIR || exit
        CMDEX=
        if [ "$MG_BUILD_CONFIG" = "Debug" ]; then
            CMDEX="--debug"  
        fi
        # Package the tarball that was just cut rather than the live install tree, so the debs and
        # the generic installer carry the same content. The version has to be named because
        # cmake_package.sh lays the packages out under the install prefix for the version it is
        # told, and its own default silently lags a baseline bump.
        ./cmake_package.sh --format deb --working-dir $BUILD_DIR/mg_deb --output-dir $ARTIFACTS_DIR/$MG_DISTRO --build-number "$MG_VER_REV" --tarball $ARTIFACTS_DIR/mapguideopensource-$MG_VER-$MG_DISTRO-amd64.tar.gz --mg-ver "$MG_VER_TRIPLE" --fdo-ver "$FDO_VER_TRIPLE" $CMDEX
        check_build
        # The package name carries the version cmake_package.sh was told, so this is also the check
        # that the packaging ran against this build's version rather than a default.
        for component in common coordsys server webextensions httpd; do
            deb=$ARTIFACTS_DIR/$MG_DISTRO/mapguideopensource-${component}_${MG_VER_TRIPLE}-${MG_VER_REV}_amd64.deb
            if [ ! -f "$deb" ]; then
                echo "FATAL: no $(basename $deb) in $ARTIFACTS_DIR/$MG_DISTRO"
                exit 1
            fi
        done
        # The packages must also install into the prefix the installer configures, which is the one
        # this build installs to: one laid out for another version installs a tree nothing can find,
        # and the only symptom at install time is an empty install directory.
        if ! dpkg-deb -c $ARTIFACTS_DIR/$MG_DISTRO/mapguideopensource-server_${MG_VER_TRIPLE}-${MG_VER_REV}_amd64.deb | grep "mapguideopensource-${MG_VER_TRIPLE}/server/bin/serverconfig.ini" > /dev/null; then
            echo "FATAL: the mapguideopensource-server package does not install into mapguideopensource-${MG_VER_TRIPLE}"
            exit 1
        fi
        ;;
#    *centos*)
#        echo "Generating rpm packages"
#        cd $SRC_DIR || exit
#        ./cmake_package.sh --format rpm --working-dir $BUILD_DIR/mg_rpm --output-dir $ARTIFACTS_DIR/$MG_DISTRO --build-number "$MG_VER_REV"
#        ;;
esac
ccache -s