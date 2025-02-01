#!/bin/bash

echo "Building FDO ${FDO_VER_TRIPLE} (v${FDO_VER})"
echo " vMajor - ${FDO_VER_MAJOR}"
echo " vMinor - ${FDO_VER_MINOR}"
echo " vRel - ${FDO_VER_REL}"
echo " vRev - ${FDO_VER_REV}"
echo " Config - ${FDO_BUILD_CONFIG}"

#############################################################
# Current assumed base distro for generic build: rockylinux 8
#############################################################

ccache -s
ZLIB_VER=1.2.12
PGSQL_VER=16.1
UNIXODBC_VER=2.3.12
MARIADB_CONNECTOR_VER=3.3.8
THIRDPARTY_BUILD_DIR=/tmp/work/build_area/fdo_thirdparty
THIRDPARTY_BUILD_DIR_OSSL=/tmp/work/build_area/fdo_thirdparty_openssl
BUILD_DIR=/tmp/work/build_area/fdo
SRC_DIR=/tmp/work/src
ARTIFACTS_DIR=/tmp/work/artifacts
SDKS_DIR=/tmp/work/sdks
cd $SRC_DIR || exit
# Install ninja if required
if [ ! -f /usr/bin/ninja ]; then
    echo "Adding ninja binary to /usr/bin"
    cp $SDKS_DIR/tools/ninja /usr/bin
    if [ ! -f /usr/bin/ninja-build ]; then
        echo "Symlinking ninja-build"
        ln -s /usr/bin/ninja /usr/bin/ninja-build
    fi
fi

# For generic, we build against MySQL/PostgreSQL in /sdks
# Setting MYSQL_DIR is enough for FindMySQL.cmake to pick it up
export ORACLE_SDK_HOME=$SDKS_DIR/oracle/x64/instantclient_12_2/sdk
PG_BUILD_ROOT=/tmp/work/build_area/pgbuild
MARIADB_BUILD_ROOT=/tmp/work/build_area/mariadb
ZLIB_BUILD_ROOT=/tmp/work/build_area/zlib
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
UNIXODBC_BUILD_ROOT=/tmp/work/build_area/unixodbc
# Build UnixODBC if required
if [ ! -f /usr/local/lib/libodbccr.a ]; then
    if [ ! -d $UNIXODBC_BUILD_ROOT ]; then
        mkdir -p $UNIXODBC_BUILD_ROOT
        echo "Extracting UnixODBC tarball"
        tar -zxf $SDKS_DIR/unixODBC-${UNIXODBC_VER}.tar.gz -C $UNIXODBC_BUILD_ROOT
    fi
    cd $UNIXODBC_BUILD_ROOT/unixODBC-${UNIXODBC_VER} || exit
    ./configure --disable-shared --enable-static --enable-silent-rules --with-pic
    make && make install
fi

# For generic, build FDO thirdparty in 2 phases
# Phase 1: Internal OpenSSL/libcurl as *globally-installed* libraries, so the subsequent libs that depend on this can use
# standard configure arguments without extensive/invasive path hacking
cd $SRC_DIR || exit
./cmake_bootstrap.sh --config $FDO_BUILD_CONFIG --working-dir $THIRDPARTY_BUILD_DIR_OSSL --internal-openssl-curl-as-global --build 64 --with-ccache || exit
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
    CFLAGS="-pthread" cmake ../mariadb-connector-c-${MARIADB_CONNECTOR_VER}-src -DCMAKE_BUILD_TYPE=Release -DCMAKE_INSTALL_PREFIX=/usr/local -DWITH_SSL=OPENSSL
    cmake --build . && cmake --build . --target install
fi
# Build PostgreSQL client if required
if [ ! -f /usr/local/pgsql/lib/libpq.a ]; then
    if [ ! -d $PG_BUILD_ROOT ]; then
        mkdir -p $PG_BUILD_ROOT
        echo "Extracting PostgreSQL tarball"
        tar -zxf $SDKS_DIR/postgresql-${PGSQL_VER}.tar.gz -C $PG_BUILD_ROOT    
    fi
    cd $PG_BUILD_ROOT/postgresql-${PGSQL_VER} || exit
    # Note the LIBS="-lpthread" at the end, without it configure can't "detect" static openssl
    # Ref: https://github.com/kvic-z/pixelserv-tls/issues/22
    #
    # Also static build does not add -fPIC, so pass that in through CFLAGS
    CFLAGS="-fPIC" ./configure --with-openssl --without-icu --without-readline --enable-silent-rules --with-pic --enable-static --disable-shared
    # Based on this: https://stackoverflow.com/a/29810073
    # We should be able to build only libpq by building everything inside src/interfaces/libpq
    cd $PG_BUILD_ROOT/postgresql-${PGSQL_VER}/src/interfaces/libpq || exit
    make && make install
    # Our CMake detection module will be looking for this lib too, so build/install it too
    cd $PG_BUILD_ROOT/postgresql-${PGSQL_VER}/src/port || exit
    make && make install
    # Our CMake detection module will be looking for this lib too, so build/install it too
    cd $PG_BUILD_ROOT/postgresql-${PGSQL_VER}/src/common || exit
    make && make install
    # There are dependent headers here that need installation too
    cd $PG_BUILD_ROOT/postgresql-${PGSQL_VER}/src/include || exit
    make install
    # Need the pg_config util
    cd $PG_BUILD_ROOT/postgresql-${PGSQL_VER}/src/bin/pg_config || exit
    make && make install
fi
# FDO Thirdparty Phase 2: Build remaining internal libs (in a separate build root)
cd $SRC_DIR || exit
./cmake_bootstrap.sh --config $FDO_BUILD_CONFIG --working-dir $THIRDPARTY_BUILD_DIR --internal-gdal --internal-cppunit --internal-xalan --internal-xerces --build 64 --with-ccache || exit
# Now for the main build
cd $SRC_DIR || exit
CMDEX=
if [ "$FDO_BUILD_CONFIG" = "Debug" ]; then
    echo "Building with ASAN instrumentation"
    CMDEX="--with-asan"
fi
./cmake_build.sh --fdo-ver-major ${FDO_VER_MAJOR} --fdo-ver-minor ${FDO_VER_MINOR} --fdo-ver-rel ${FDO_VER_REL} --fdo-ver-rev ${FDO_VER_REV} --build 64 --thirdparty-working-dir $THIRDPARTY_BUILD_DIR --cmake-build-dir $BUILD_DIR --with-sdf --with-shp --with-sqlite --with-ogr --with-gdal --with-wfs --with-wms --with-genericrdbms --with-mariadb-static --with-libpq-static --with-kingoracle --with-oci-version 120 --ninja $CMDEX || exit
cd $BUILD_DIR || exit
cmake --build . --target package
mv fdosdk*.tar.gz $ARTIFACTS_DIR
ccache -s
