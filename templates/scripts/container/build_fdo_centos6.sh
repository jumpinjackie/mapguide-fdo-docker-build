#!/bin/bash

echo "Building FDO ${FDO_VER_TRIPLE} (v${FDO_VER})"
echo " vMajor - ${FDO_VER_MAJOR}"
echo " vMinor - ${FDO_VER_MINOR}"
echo " vRel - ${FDO_VER_REL}"
echo " vRev - ${FDO_VER_REV}"
ccache -s
THIRDPARTY_BUILD_DIR=/tmp/work/build_area/fdo_thirdparty
BUILD_DIR=/tmp/work/build_area/fdo
SRC_DIR=/tmp/work/src
ARTIFACTS_DIR=/tmp/work/artifacts
SDKS_DIR=/tmp/work/sdks
# Centos 6 special
. scl_source enable devtoolset-7
cd $SRC_DIR || exit
# For Centos 6, we're building all internal thirdparty libs
./cmake_bootstrap.sh --working-dir $THIRDPARTY_BUILD_DIR --all-internal --build 64 --with-ccache
# For CentOS-based distros, we build against MySQL/PostgreSQL in /sdks
# Setting MYSQL_DIR is enough for FindMySQL.cmake to pick it up
export ORACLE_SDK_HOME=$SDKS_DIR/oracle/x64/instantclient_12_2/sdk
PG_BUILD_ROOT=/tmp/work/build_area/pgbuild
MARIADB_BUILD_ROOT=/tmp/work/build_area/mariadb
OPENSSL_LOCAL_DIR=/tmp/work/build_area/fdo_thirdparty/Thirdparty/openssl/_install
# Build MariaDB client if required
if [ ! -f /usr/local/lib/mariadb/libmariadbclient.a ]; then
    if [ ! -d $MARIADB_BUILD_ROOT ]; then
        mkdir -p $MARIADB_BUILD_ROOT
        echo "Extracting MariaDB tarball"
        tar -zxf $SDKS_DIR/mariadb-connector-c-3.1.9-src.tar.gz -C $MARIADB_BUILD_ROOT
    fi 
    cd $MARIADB_BUILD_ROOT/mariadb-connector-c-3.1.9-src || exit
    if [ -d ../_build ]; then
        rm -rf ../_build
    fi
    mkdir -p ../_build
    cd ../_build || exit
    # The FindOpenSSL.cmake in CMake 2.8 is not flexible enough to pick up our custom built OpenSSL so 
    # we have to invasively set all the "private" variables that this module looks for up front
    #
    # Also, possibly because of this, we need to manually set -pthread/-lpthread to avoid a linker error
    LIBS="-lpthread" CFLAGS="-pthread" cmake ../mariadb-connector-c-3.1.9-src -DCMAKE_BUILD_TYPE=Release -DCMAKE_INSTALL_PREFIX=/usr/local -DWITH_SSL=OPENSSL -D_OPENSSL_INCLUDEDIR=/tmp/work/build_area/fdo_thirdparty/Thirdparty/openssl/_install/include -D_OPENSSL_LIBDIR=/tmp/work/build_area/fdo_thirdparty/Thirdparty/openssl/_install/lib -D_OPENSSL_VERSION=1.1.1
    make && make install
fi
# Build PostgreSQL client if required
if [ ! -f /usr/local/pgsql/lib/libpq.a ]; then
    if [ ! -d $PG_BUILD_ROOT ]; then
        mkdir -p $PG_BUILD_ROOT
        echo "Extracting PostgreSQL tarball"
        tar -zxf $SDKS_DIR/postgresql-12.4.tar.gz -C $PG_BUILD_ROOT    
    fi

    cd $PG_BUILD_ROOT/postgresql-12.4 || exit
    # We sadly have to build everything even though we only want libpq. Fortunately, PostgreSQL
    # is written in C (not C++), so even a full build of everything is fast in the grand scheme.
    #
    # Note the LIBS="-lpthread" at the end, without it configure can't "detect" static openssl
    # Ref: https://github.com/kvic-z/pixelserv-tls/issues/22
    #
    # Also static build does not add -fPIC, so pass that in through CFLAGS
    ./configure --with-openssl --without-readline --with-includes=$OPENSSL_LOCAL_DIR/include --with-libraries=$OPENSSL_LOCAL_DIR/lib LIBS="-lpthread" CFLAGS="-fPIC"
    make && make install
fi
# Now for the main build
cd $SRC_DIR || exit
./cmake_build.sh --fdo-ver-major ${FDO_VER_MAJOR} --fdo-ver-minor ${FDO_VER_MINOR} --fdo-ver-rel ${FDO_VER_REL} --fdo-ver-rev ${FDO_VER_REV} --build 64 --thirdparty-working-dir $THIRDPARTY_BUILD_DIR --cmake-build-dir $BUILD_DIR --with-sdf --with-shp --with-sqlite --with-ogr --with-gdal --with-wfs --with-wms --with-genericrdbms --with-mariadb-static --with-libpq-static --with-kingoracle --with-oci-version 120 --ninja
cd $BUILD_DIR || exit
cmake --build . --target package
mv fdosdk*.tar.gz $ARTIFACTS_DIR
ccache -s