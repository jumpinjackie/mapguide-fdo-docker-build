#!/bin/bash

echo "Building FDO ${FDO_VER_TRIPLE} (v${FDO_VER})"
echo " vMajor - ${FDO_VER_MAJOR}"
echo " vMinor - ${FDO_VER_MINOR}"
echo " vRel - ${FDO_VER_REL}"
echo " vRev - ${FDO_VER_REV}"
echo " Distro - ${FDO_DISTRO}"
echo " Config - ${FDO_BUILD_CONFIG}"
ccache -s
THIRDPARTY_BUILD_DIR=/tmp/work/build_area/fdo_thirdparty
BUILD_DIR=/tmp/work/build_area/fdo
SRC_DIR=/tmp/work/src
ARTIFACTS_DIR=/tmp/work/artifacts
SDKS_DIR=/tmp/work/sdks
cd $SRC_DIR || exit
# Our standard default is to assume all thirdparty deps exist as system packages
./cmake_bootstrap.sh --config $FDO_BUILD_CONFIG --working-dir $THIRDPARTY_BUILD_DIR --build 64 --with-ccache
# Oracle Instant Client SDK setup
export ORACLE_SDK_HOME=$SDKS_DIR/oracle/x64/instantclient_12_2/sdk
# Main build
CMDEX=
if [ "$FDO_BUILD_CONFIG" = "Debug" ]; then
    echo "Building with ASAN instrumentation"
    CMDEX="--with-asan"
fi
./cmake_build.sh --fdo-ver-major ${FDO_VER_MAJOR} --fdo-ver-minor ${FDO_VER_MINOR} --fdo-ver-rel ${FDO_VER_REL} --fdo-ver-rev ${FDO_VER_REV} --build 64 --thirdparty-working-dir $THIRDPARTY_BUILD_DIR --cmake-build-dir $BUILD_DIR --with-sdf --with-shp --with-sqlite --with-ogr --with-gdal --with-wfs --with-wms --with-genericrdbms --with-kingoracle --with-oci-version 120 --ninja --filelist-output-dir $BUILD_DIR/filelists $CMDEX
case "$FDO_DISTRO" in
    *ubuntu*)
        echo "Generating deb packages"
        # Run root install target so we can package its contents
        cd $BUILD_DIR || exit
        cmake --build . --target install
        cd $SRC_DIR || exit
        CMDEX=
        if [ "$FDO_BUILD_CONFIG" = "Debug" ]; then
            CMDEX="--debug"
        fi
        ./cmake_package.sh --format deb --working-dir $BUILD_DIR/fdo_deb --output-dir $ARTIFACTS_DIR/$FDO_DISTRO --filelist-dir $BUILD_DIR/filelists --oracle-lib-dir ${ORACLE_SDK_HOME}/lib --build-number "$FDO_VER_REV" $CMDEX
        ;;
#    *centos*)
#        echo "Generating rpm packages"
#        # Run root install target so we can package its contents
#        cd $BUILD_DIR || exit
#        cmake --build . --target install
#        cd $SRC_DIR || exit
#        ./cmake_package.sh --format rpm --working-dir $BUILD_DIR/fdo_rpm --output-dir $ARTIFACTS_DIR/$FDO_DISTRO --filelist-dir $BUILD_DIR/filelists --oracle-lib-dir ${ORACLE_SDK_HOME}/lib --build-number "$FDO_VER_REV"
#        ;;
esac

# Now fall back to default CMake tarball packaging
cd $BUILD_DIR || exit
cmake --build . --target package
mv fdosdk*.tar.gz $ARTIFACTS_DIR
ccache -s
