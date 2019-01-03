#!/bin/bash

write_fdo_run()
{
    path=$1
    distro=$2
    tag=$3

    #prepare_cmd="apt-get clean && apt-get update"
    prepare_cmd=$(cat templates/distros/$distro/cmd_prepare_run.txt)

    cat > $path/Dockerfile <<EOF
# This dockerfile defines the expected runtime environment before the project is installed
FROM ${distro}:${tag}

# Be sure to install any runtime dependencies
RUN ${prepare_cmd}
EOF

    echo "Wrote: $path/Dockerfile"
}

write_fdo_develop()
{
    path=$1
    distro_label=$2
    cpu=$3
    distro=$4

    #install_cmd="apt-get install -y"
    #deplist="lsb-release ccache build-essential bison lintian dos2unix libssl-dev libcurl4-openssl-dev libexpat-dev libmysqlclient-dev \
#unixodbc-dev libpq-dev libcppunit-dev libxalan-c-dev libxerces-c-dev libgdal-dev cmake ninja-build"
    prepare_cmd=$(cat templates/distros/$distro/cmd_prepare_fdo_develop.txt)

    cat > $path/Dockerfile <<EOF
# This dockerfile makes a snapshot of the development environment
FROM fdo_${distro_label}_run_${cpu}

# Install build dependencies
RUN ${prepare_cmd}

# include the code
COPY fdo/ /usr/local/src/fdo

# include our last collected cache
COPY caches/${cpu}/fdo/${distro_label}/.ccache /root/.ccache

# remove intermediate files (to ensure a clean build later)
RUN rm -rf /usr/local/src/fdo/build

# since fdo is a submodule on the local machine
# git relocated .git/ to the parent repo, un-submodule it in the image
RUN rm /usr/local/src/fdo/.git
COPY .git/modules/fdo /usr/local/src/fdo/.git/
EOF

    echo "Wrote: $path/Dockerfile"
}

write_fdo_build()
{
    path=$1
    distro_label=$2
    cpu=$3
    distro=$4

    want_generator=$(cat templates/distros/$distro/cmake_generator.txt)

    cat > $path/Dockerfile <<EOF
# This dockerfile executes the build, it starts from the dev environment
FROM fdo_${distro_label}_develop_${cpu}

# These are the build steps
RUN BUILD_DIR=/usr/local/src/fdo/build \\
&& ccache -s \\
&& mkdir \$BUILD_DIR \\
&& mkdir \$BUILD_DIR/artifacts \\
&& cd \$BUILD_DIR \\
&& cmake ${want_generator} .. -DWITH_SDF=TRUE -DWITH_SHP=TRUE -DWITH_SQLITE=TRUE -DWITH_WFS=TRUE -DWITH_WMS=TRUE -DWITH_OGR=TRUE -DWITH_GDAL=TRUE -DWITH_GENERICRDBMS=TRUE \\
&& cmake --build . \\
&& ccache -s \\
&& cmake --build . --target package \\
&& mv fdosdk*.tar.gz \$BUILD_DIR/artifacts
EOF

    echo "Wrote: $path/Dockerfile"
}

build_fdo_env()
{
    distro=$1
    cpu=$2
    tag=$3

    if [ ! -d "templates/distros/$distro" ]; then
        echo "No template confiugrations found for $distro"
        exit 1
    fi

    echo "Setting FDO environment for"
    echo "Distro: $distro"
    echo "CPU: $cpu"
    echo "Docker base image tag: $tag"

    ver_major=$(echo $tag | cut -d. -f1)
    distro_label="${distro}${ver_major}"

    echo "Distro label will be: $distro_label"

    path_base="docker/${cpu}/fdo/${distro_label}"
    echo "Base path for environment is: $path_base"

    current_path="${path_base}/run"
    mkdir -p $current_path
    write_fdo_run $current_path $distro $tag $distro_label
    cp -f templates/scripts/snap_run.sh $current_path/snap.sh

    current_path="${path_base}/develop"
    mkdir -p $current_path
    write_fdo_develop $current_path $distro_label $cpu $distro
    cp -f templates/scripts/snap_develop.sh $current_path/snap.sh

    current_path="${path_base}/build"
    mkdir -p $current_path
    write_fdo_build $current_path $distro_label $cpu $distro
    cp -f templates/scripts/snap_build.sh $current_path/snap.sh
}

TARGET=fdo
DISTRO=ubuntu
CPU=x64
TAG=14.04
while [ $# -gt 0 ]; do    # Until you run out of parameters...
    case "$1" in
        --target)
            TARGET="$2"
            shift
            ;;
        --distro)
            DISTRO="$2"
            shift
            ;;
        --tag)
            TAG="$2"
            shift
            ;;
        --cpu)
            CPU="$2"
            shift
            ;;
        --help)
            echo "Usage: $0 (options)"
            echo "Options:"
            echo "  --target [mapguide|fdo]"
            echo "  --distro [the distro you are targeting, ubuntu|centos]"
            echo "  --tag [the version tag]"
            echo "  --cpu [x86|x64]"
            echo "  --help [Display usage]"
            exit
            ;;
    esac
    shift   # Check next set of parameters.
done

case "$TARGET" in
    fdo)
        build_fdo_env $DISTRO $CPU $TAG
        ;;
    mapguide)
        echo "MapGuide env generation not supported yet. Check back later"
        exit 1
        ;;
    *)
        echo "Unknown target: $TARGET"
        exit 1
        ;;
esac