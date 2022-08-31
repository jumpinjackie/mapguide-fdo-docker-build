#!/bin/bash

echo "Building FDO ${FDO_VER_TRIPLE} (v${FDO_VER})"
echo " vMajor - ${FDO_VER_MAJOR}"
echo " vMinor - ${FDO_VER_MINOR}"
echo " vRel - ${FDO_VER_REL}"
echo " vRev - ${FDO_VER_REV}"
echo " Config - ${FDO_BUILD_CONFIG}"
ccache -s
ZLIB_VER=1.2.11
PGSQL_VER=12.6
MARIADB_CONNECTOR_VER=3.1.12
THIRDPARTY_BUILD_DIR=/tmp/work/build_area/fdo_thirdparty
BUILD_DIR=/tmp/work/build_area/fdo
SRC_DIR=/tmp/work/src
ARTIFACTS_DIR=/tmp/work/artifacts
SDKS_DIR=/tmp/work/sdks
cd $SRC_DIR || exit
# For CentOS-based distros, we build against MySQL/PostgreSQL in /sdks
# Setting MYSQL_DIR is enough for FindMySQL.cmake to pick it up
export ORACLE_SDK_HOME=$SDKS_DIR/oracle/x64/instantclient_12_2/sdk
PG_BUILD_ROOT=/tmp/work/build_area/pgbuild
MARIADB_BUILD_ROOT=/tmp/work/build_area/mariadb
ZLIB_BUILD_ROOT=/tmp/work/build_area/zlib
OPENSSL_LOCAL_DIR=/tmp/work/build_area/fdo_thirdparty/Thirdparty/openssl/_install
# Build zlib if required
if [ ! -f /usr/local/lib/libz.a ]; then
    if [ ! -d $ZLIB_BUILD_ROOT/zlib-${ZLIB_VER} ]; then
        mkdir -p $ZLIB_BUILD_ROOT
        echo "Extracting zlib tarball"
        tar -zxf $SDKS_DIR/zlib-${ZLIB_VER}.tar.gz -C $ZLIB_BUILD_ROOT
    fi
    cd $ZLIB_BUILD_ROOT/zlib-${ZLIB_VER} || exit
    # zlib doesn't add the -fPIC flag by default so we have to CFLAGS hack it in
    CFLAGS="-fPIC -O3" ./configure --static
    make && make install
fi
# For Centos 7, we're building all internal thirdparty libs
cd $SRC_DIR || exit
./cmake_bootstrap.sh --config $FDO_BUILD_CONFIG --working-dir $THIRDPARTY_BUILD_DIR --all-internal --build 64 --with-ccache || exit
# Build MariaDB client if required
if [ ! -f /usr/local/lib/mariadb/libmariadbclient.a ]; then
    if [ ! -d $MARIADB_BUILD_ROOT ]; then
        mkdir -p $MARIADB_BUILD_ROOT
        echo "Extracting MariaDB tarball"
        tar -zxf $SDKS_DIR/mariadb-connector-c-${MARIADB_CONNECTOR_VER}-src.tar.gz -C $MARIADB_BUILD_ROOT
    fi 
    cd $MARIADB_BUILD_ROOT/mariadb-connector-c-${MARIADB_CONNECTOR_VER}-src || exit
    if [ -d ../_build ]; then
        rm -rf ../_build
    fi
    mkdir -p ../_build
    cd ../_build || exit
    # The FindOpenSSL.cmake in CMake 2.8 is not flexible enough to pick up our custom built OpenSSL so 
    # we have to invasively set all the "private" variables that this module looks for up front
    #
    # Also, possibly because of this, we need to manually set -pthread/-lpthread to avoid a linker error
    LIBS="-lpthread" CFLAGS="-pthread" cmake ../mariadb-connector-c-${MARIADB_CONNECTOR_VER}-src -DCMAKE_BUILD_TYPE=Release -DCMAKE_INSTALL_PREFIX=/usr/local -DWITH_SSL=OPENSSL -D_OPENSSL_INCLUDEDIR=/tmp/work/build_area/fdo_thirdparty/Thirdparty/openssl/_install/include -D_OPENSSL_LIBDIR=/tmp/work/build_area/fdo_thirdparty/Thirdparty/openssl/_install/lib -D_OPENSSL_VERSION=1.1.1
    make && make install
fi
# Build PostgreSQL client if required
if [ ! -f /usr/local/pgsql/lib/libpq.a ]; then
    if [ ! -d $PG_BUILD_ROOT ]; then
        mkdir -p $PG_BUILD_ROOT
        echo "Extracting PostgreSQL tarball"
        tar -zxf $SDKS_DIR/postgresql-${PGSQL_VER}.tar.gz -C $PG_BUILD_ROOT    
    fi

    cd $PG_BUILD_ROOT/postgresql-${PGSQL_VER} || exit
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
CMDEX=
if [ "$FDO_BUILD_CONFIG" = "Debug" ]; then
    echo "Building with ASAN instrumentation"
    CMDEX="--with-asan"
fi
./cmake_build.sh --fdo-ver-major ${FDO_VER_MAJOR} --fdo-ver-minor ${FDO_VER_MINOR} --fdo-ver-rel ${FDO_VER_REL} --fdo-ver-rev ${FDO_VER_REV} --build 64 --thirdparty-working-dir $THIRDPARTY_BUILD_DIR --cmake-build-dir $BUILD_DIR --with-sdf --with-shp --with-sqlite --with-ogr --with-gdal --with-wfs --with-wms --with-genericrdbms --with-mariadb-static --with-libpq-static --with-kingoracle --with-oci-version 120 --ninja $CMDEX
cd $BUILD_DIR || exit
cmake --build . --target package
mv fdosdk*.tar.gz $ARTIFACTS_DIR
ccache -s
