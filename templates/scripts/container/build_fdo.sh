#!/bin/bash

echo "Building FDO ${FDO_VER_TRIPLE} (v${FDO_VER})"
ccache -s
THIRDPARTY_BUILD_DIR=/tmp/work/build_area/fdo_thirdparty
BUILD_DIR=/tmp/work/build_area/fdo
SRC_DIR=/tmp/work/src
ARTIFACTS_DIR=/tmp/work/artifacts
cd $SRC_DIR || exit
# Our standard default is to assume all thirdparty deps exist as system packages
./cmake_bootstrap.sh --working-dir $THIRDPARTY_BUILD_DIR --build 64 --with-ccache
./cmake_build.sh --build 64 --thirdparty-working-dir $THIRDPARTY_BUILD_DIR --cmake-build-dir $BUILD_DIR --with-sdf --with-shp --with-sqlite --with-ogr --with-gdal --with-wfs --with-wms --with-genericrdbms --ninja
cd $BUILD_DIR || exit
cmake --build . --target package
mv fdosdk*.tar.gz $ARTIFACTS_DIR
ccache -s