#!/bin/bash

echo "Building FDO ${FDO_VER_TRIPLE} (v${FDO_VER})"
echo " vMajor - ${FDO_VER_MAJOR}"
echo " vMinor - ${FDO_VER_MINOR}"
echo " vRel - ${FDO_VER_REL}"
echo " vRev - ${FDO_VER_REV}"
echo " Config - ${FDO_BUILD_CONFIG}"

# FDO is a library that uses dlopen, so we cannot have static libstdc++ linked in
export LIBCHECK_ALLOW='libstdc\+\+'

# Activate holy build box (shared library mode)
source /hbb_shlib/activate

# Activation will insert -static-libstdc++ to various link vars, remove that flag
export LDFLAGS=$(echo $LDFLAGS | sed 's/\-static\-libstdc++//')
export SHLIB_LDFLAGS=$(echo $SHLIB_LDFLAGS | sed 's/\-static\-libstdc++//')

# Activation will also insert -fvisiblity=hidden FDO and various internal thirdparty libs we use are not ready for this flag, so remove as well
export CFLAGS=$(echo $CFLAGS | sed 's/ \-fvisibility=hidden//')
export CXXFLAGS=$(echo $CXXFLAGS | sed 's/ \-fvisibility=hidden//')
export SHLIB_CFLAGS=$(echo $SHLIB_CFLAGS | sed 's/ \-fvisibility=hidden//')
export SHLIB_CXXFLAGS=$(echo $SHLIB_CXXFLAGS | sed 's/ \-fvisibility=hidden//')
export STATICLIB_CFLAGS=$(echo $STATICLIB_CFLAGS | sed 's/ \-fvisibility=hidden//')
export STATICLIB_CXXFLAGS=$(echo $STATICLIB_CXXFLAGS | sed 's/ \-fvisibility=hidden//')

ccache -s
PGSQL_VER=16.1
UNIXODBC_VER=2.3.12
MARIADB_CONNECTOR_VER=3.3.8
THIRDPARTY_BUILD_DIR=/tmp/work/build_area/fdo_thirdparty
BUILD_DIR=/tmp/work/build_area/fdo
SRC_DIR=/tmp/work/src
ARTIFACTS_DIR=/tmp/work/artifacts
SDKS_DIR=/tmp/work/sdks

# Install ninja if required
if [ ! -f /usr/bin/ninja ]; then
    echo "Adding ninja binary to /usr/bin"
    cp $SDKS_DIR/tools/ninja /usr/bin
    if [ ! -f /usr/bin/ninja-build ]; then
        echo "Symlinking ninja-build"
        ln -s /usr/bin/ninja /usr/bin/ninja-build
    fi
fi

# For CentOS-based distros, we build against MySQL/PostgreSQL in /sdks
# Setting MYSQL_DIR is enough for FindMySQL.cmake to pick it up
export ORACLE_SDK_HOME=$SDKS_DIR/oracle/x64/instantclient_12_2/sdk
PG_BUILD_ROOT=/tmp/work/build_area/pgbuild
MARIADB_BUILD_ROOT=/tmp/work/build_area/mariadb
UNIXODBC_BUILD_ROOT=/tmp/work/build_area/unixodbc

cd $SRC_DIR || exit
# HBB provides OpenSSL and curl, so these can be system-provided. Everything else is internal.
./cmake_bootstrap.sh --config $FDO_BUILD_CONFIG --working-dir $THIRDPARTY_BUILD_DIR --internal-gdal --internal-cppunit --internal-xerces --internal-xalan --build 64 --with-ccache || exit

# Build UnixODBC if required
if [ ! -f /usr/local/lib/libodbccr.a ]; then
    if [ ! -d $UNIXODBC_BUILD_ROOT ]; then
        mkdir -p $UNIXODBC_BUILD_ROOT
        echo "Extracting UnixODBC tarball"
        tar -zxf $SDKS_DIR/unixODBC-${UNIXODBC_VER}.tar.gz -C $UNIXODBC_BUILD_ROOT
    fi
    cd $UNIXODBC_BUILD_ROOT/unixODBC-${UNIXODBC_VER} || exit
    ./configure --enable-static --enable-silent-rules --with-pic
    make && make install
fi
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
    CFLAGS="-fPIC" ./configure --with-openssl --without-icu --without-readline --enable-silent-rules --with-pic
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
