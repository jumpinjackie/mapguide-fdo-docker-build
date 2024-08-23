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
BUILD_DIR=/tmp/work/build_area/mapguide
SRC_DIR=/tmp/work/src
SDKS_DIR=/tmp/work/sdks
ARTIFACTS_DIR=/tmp/work/artifacts
MG_VER_TRIPLE=${MG_VER_MAJOR}.${MG_VER_MINOR}.${MG_VER_REL}
MG_VER=${MG_VER_TRIPLE}.${MG_VER_REV}

# Install ninja if required
if [ ! -f /usr/bin/ninja ]; then
    echo "Adding ninja binary to /usr/bin"
    cp $SDKS_DIR/tools/ninja /usr/bin
    if [ ! -f /usr/bin/ninja-build ]; then
        echo "Symlinking ninja-build"
        ln -s /usr/bin/ninja /usr/bin/ninja-build
    fi
fi

# Install OpenJDK if required
if [ ! -f /opt/java/openjdk/bin/java ] || [ ! -f /opt/java/openjdk/bin/javac ]; then
    mkdir -p /opt/java/openjdk
    tar -zxf $SDKS_DIR/openjdk8.tar.gz -C /opt/java/openjdk --strip-components 1
    check_build
fi

# Install ant if required
if [ ! -f /opt/ant/bin/ant ]; then
    mkdir -p /opt/ant
    tar -zxf $SDKS_DIR/ant.tar.gz -C /opt/ant --strip-components 1
    check_build
fi

export JAVA_HOME=/opt/java/openjdk
export ANT_HOME=/opt/ant

# MapGuide has code that uses dlopen, so we cannot have static libstdc++ linked in
export LIBCHECK_ALLOW='libstdc\+\+'

# Activate holy build box (shared library mode)
source /hbb_shlib/activate

# Activation will insert -static-libstdc++ to various link vars, remove that flag
export LDFLAGS=$(echo $LDFLAGS | sed 's/\-static\-libstdc++//')
export SHLIB_LDFLAGS=$(echo $SHLIB_LDFLAGS | sed 's/\-static\-libstdc++//')

# Activation will also insert -fvisiblity=hidden MapGuide and various internal thirdparty libs we use are not ready for this flag, so remove as well
export CFLAGS=$(echo $CFLAGS | sed 's/ \-fvisibility=hidden//')
export CXXFLAGS=$(echo $CXXFLAGS | sed 's/ \-fvisibility=hidden//')
export SHLIB_CFLAGS=$(echo $SHLIB_CFLAGS | sed 's/ \-fvisibility=hidden//')
export SHLIB_CXXFLAGS=$(echo $SHLIB_CXXFLAGS | sed 's/ \-fvisibility=hidden//')
export STATICLIB_CFLAGS=$(echo $STATICLIB_CFLAGS | sed 's/ \-fvisibility=hidden//')
export STATICLIB_CXXFLAGS=$(echo $STATICLIB_CXXFLAGS | sed 's/ \-fvisibility=hidden//')

# Install PCRE
PCRE_BUILD_ROOT=/tmp/work/build_area/pcre
mkdir -p $PCRE_BUILD_ROOT
tar -zxf $SDKS_DIR/pcre2.tar.gz -C $PCRE_BUILD_ROOT --strip-components 1
check_build
cd $PCRE_BUILD_ROOT || exit
./configure --disable-shared
check_build
make && make install
check_build

# Install expat
EXPAT_BUILD_ROOT=/tmp/work/build_area/expat
mkdir -p $EXPAT_BUILD_ROOT
tar -zxf $SDKS_DIR/expat.tar.gz -C $EXPAT_BUILD_ROOT --strip-components 1
check_build
cd $EXPAT_BUILD_ROOT || exit
./configure --disable-shared --with-pic --enable-silent-rules
check_build
make && make install
check_build

# Install libxml
LIBXML_BUILD_ROOT=/tmp/work/build_area/libxml
mkdir -p $LIBXML_BUILD_ROOT
mkdir -p $LIBXML_BUILD_ROOT/_build
tar -zxf $SDKS_DIR/libxml2.tar.gz -C $LIBXML_BUILD_ROOT --strip-components 1
check_build
cd $LIBXML_BUILD_ROOT/_build || exit
cmake -DBUILD_SHARED_LIBS=OFF ..
check_build
cmake --build . && cmake --build . --target install
check_build

# Install sqlite3
#SQLITE_BUILD_ROOT=/tmp/work/build_area/sqlite3
#mkdir -p $SQLITE_BUILD_ROOT
#tar -zxf $SDKS_DIR/sqlite.tar.gz -C $SQLITE_BUILD_ROOT --strip-components 1
#cd $SQLITE_BUILD_ROOT || exit
#./configure --enable-static --disable-shared --enable-silent-rules
#check_build
#make && make install
#check_build

# Install oniguruma
ONIG_BUILD_ROOT=/tmp/work/build_area/onig
mkdir -p $ONIG_BUILD_ROOT
tar -zxf $SDKS_DIR/onig.tar.gz -C $ONIG_BUILD_ROOT --strip-components 1
cd $ONIG_BUILD_ROOT || exit
./configure --enable-static --disable-shared --enable-silent-rules
check_build
make && make install
check_build

# Append /usr/local/lib[64]/pkgconfig to PKG_CONFIG_PATH
export PKG_CONFIG_PATH=$PKG_CONFIG_PATH:/usr/local/lib64/pkgconfig:/usr/local/lib/pkgconfig
# HACK: Our internal libjpeg doesn't provide a pkg-config file, so provide this for PHP's configure
# TODO: 
export JPEG_CFLAGS=-I/usr/local/include
export JPEG_LIBS="-L/usr/local/lib -ljpeg"
export PNG_CFLAGS=-I/usr/local/include
export PNG_LIBS="-L/usr/local/lib -lpng"

echo "Building MapGuide ${MG_VER_TRIPLE} (v${MG_VER} - ${MG_BUILD_CONFIG})"
echo "Using FDO SDK at: ${ARTIFACTS_DIR}/${FDOSDK}"
ccache -s

if [ ! -f "${ARTIFACTS_DIR}/${FDOSDK}" ]; then
    echo "FATAL: FDO SDK (${ARTIFACTS_DIR}/${FDOSDK}) not found"
    exit 1
fi

echo "Installing FDO SDK"
mkdir -p "/usr/local/fdo-${FDO_VER_TRIPLE}"
tar -zxf "${ARTIFACTS_DIR}/${FDOSDK}" -C "/usr/local/fdo-${FDO_VER_TRIPLE}"

mkdir -p $OEM_BUILD_DIR
mkdir -p $BUILD_DIR
cd $SRC_DIR || exit
# For generic, we're building all internal thirdparty libs (except zlib as that is already provided by hbb)
./cmake_bootstrap.sh --config "$MG_BUILD_CONFIG" --oem-working-dir $OEM_BUILD_DIR --build 64 --with-ccache --with-all-internal --without-internal-zlib
check_build
./cmake_linuxapt.sh --prefix "/usr/local/mapguideopensource-${MG_VER_TRIPLE}" --oem-working-dir $OEM_BUILD_DIR --working-dir "$LINUXAPT_BUILD"
check_build
./cmake_build.sh --oem-working-dir $OEM_BUILD_DIR --cmake-build-dir $BUILD_DIR --mg-ver-major "$MG_VER_MAJOR" --mg-ver-minor "$MG_VER_MINOR" --mg-ver-rel "$MG_VER_REL" --mg-ver-rev "$MG_VER_REV" --ninja
check_build
cd $BUILD_DIR || exit
cmake --build . --target install
check_build
cd "/usr/local/mapguideopensource-${MG_VER_TRIPLE}" || exit
if [ "$MG_BUILD_CONFIG" = "Release" ]; then
    LIBDIRS="lib server/lib webserverextensions/lib lib64 server/lib64 webserverextensions/lib64 webserverextensions/apache2/modules" 
    echo "Stripping symbols from binaries"
    for libdir in ${LIBDIRS}
    do
        # Remove unneeded symbols from files in the lib directories
        strip_list=$(find ${libdir}/*.so* -type f -print)
        for file in $strip_list
        do
            strip --strip-unneeded "${file}"
            chmod a-x "${file}"
        done
    done
    # Server binaries
    strip_list=$(find server/bin/* -type f -executable -print)
    for file in $strip_list
    do
        strip --strip-unneeded "${file}"
    done
    # mgdevhttpserver
    strip_list=$(find webserverextensions/bin/* -type f -executable -print)
    for file in $strip_list
    do
        strip --strip-unneeded "${file}"
    done
    # apache2
    strip_list=$(find webserverextensions/apache2/bin/* -type f -executable -print)
    for file in $strip_list
    do
        strip --strip-unneeded "${file}"
    done
else
    echo "Skip symbol stripping"
fi
tar -zcf "$ARTIFACTS_DIR/mapguideopensource-$MG_VER-$MG_DISTRO-amd64.tar.gz" *
check_build
ccache -s

#echo "Building MapGuide Common Libs ${MG_VER_TRIPLE} (v${MG_VER} - ${MG_BUILD_CONFIG})"

# For generic, we're building all internal thirdparty libs that are required by the common libs subset
#./cmake_bootstrap.sh --config $MG_BUILD_CONFIG --oem-working-dir $OEM_BUILD_DIR --build 64 --with-ccache --with-all-internal --common-subset-only
#check_build
#./cmake_build.sh --oem-working-dir $OEM_BUILD_DIR --cmake-build-dir $BUILD_DIR --mg-ver-major $MG_VER_MAJOR --mg-ver-minor $MG_VER_MINOR --mg-ver-rel $MG_VER_REL --mg-ver-rev $MG_VER_REV --ninja --common-subset-only
#check_build
#cd $BUILD_DIR || exit
#cmake --build . --target install
#check_build
#cd /usr/local/mapguideopensource-common-${MG_VER_TRIPLE} || exit
#tar -zcf $ARTIFACTS_DIR/mapguideopensource-common-$MG_VER-generic-linux-amd64.tar.gz *
#check_build
#ccache -s