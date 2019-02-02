#!/bin/bash

indent(){
    sed 's/^/    /'
}

build_fdo_thin()
{
    distro=$1
    cpu=$2
    tag=$3
    build_image_only=$4

    ver_major=$(echo $tag | cut -d. -f1)
    distro_label="${distro}${ver_major}"

    cpu_label=
    case "$cpu" in
        x86)
            cpu_label=i386
            ;;
        x64)
            cpu_label=amd64
            ;;
        *)
            echo "Unknown CPU" | indent
            exit 1
            ;;
    esac

    if [ $build_image_only -eq 1 ]; then
        pushd docker/${cpu}/fdo/${distro_label}/develop_thin
        ./snap.sh
        popd
    else
        build_area_dir="$PWD/build_area/$cpu/$distro/fdo"
        mkdir -p "$build_area_dir"
        src_dir="$PWD/fdo"
        scripts_dir="$PWD/templates/scripts/container"
        artifacts_dir="$PWD/artifacts"
        ccache_dir="$PWD/caches/${cpu}/fdo/${distro_label}/.ccache"
        container_name="fdo_${distro_label}_develop_thin_${cpu}"

        container_root="/tmp/work"
        docker run --rm -it -e FDO_VER=$FDO_VER -v $ccache_dir:/root/.ccache -v $scripts_dir:$container_root/scripts -v $build_area_dir:$container_root/build_area -v $src_dir:$container_root/src -v $artifacts_dir:$container_root/artifacts $container_name $container_root/scripts/build_fdo.sh
    fi
}

build_mapguide_thin()
{
    distro=$1
    cpu=$2
    tag=$3
    build_image_only=$4

    ver_major=$(echo $tag | cut -d. -f1)
    distro_label="${distro}${ver_major}"

    cpu_label=
    case "$cpu" in
        x86)
            cpu_label=i386
            ;;
        x64)
            cpu_label=amd64
            ;;
        *)
            echo "Unknown CPU" | indent
            exit 1
            ;;
    esac

    if [ $build_image_only -eq 1 ]; then
        pushd docker/${cpu}/mapguide/${distro_label}/develop_thin
        ./snap.sh
        popd
    else
        build_area_dir="$PWD/build_area/$cpu/$distro/mapguide"
        mkdir -p "$build_area_dir"
        src_dir="$PWD/mapguide/MgDev"
        scripts_dir="$PWD/templates/scripts/container"
        artifacts_dir="$PWD/artifacts"
        container_name="mapguide_${distro_label}_develop_thin_${cpu}"
        ccache_dir="$PWD/caches/${cpu}/mapguide/${distro_label}/.ccache"
        fdosdk="fdosdk-${FDO_VER}-${distro_label}-${cpu_label}.tar.gz"

        container_root="/tmp/work"
        docker run --rm -it -e MG_VER=$MG_VER -e FDOSDK=$fdosdk -v $ccache_dir:/root/.ccache -v $scripts_dir:$container_root/scripts -v $build_area_dir:$container_root/build_area -v $src_dir:$container_root/src -v $artifacts_dir:$container_root/artifacts $container_name $container_root/scripts/build_mapguide.sh
    fi
}

TARGET=fdo
DISTRO=ubuntu
CPU=x64
TAG=14.04
BUILD_THIN_IMAGE=0
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
        --build-image-only)
            BUILD_THIN_IMAGE=1
            ;;
        --help)
            echo "Usage: $0 (options)"
            echo "Options:"
            echo "  --target [mapguide|fdo]"
            echo "  --distro [the distro you are targeting, ubuntu|centos]"
            echo "  --tag [the version tag]"
            echo "  --cpu [x86|x64]"
            echo "  --build-image-only [Only build the develop_thin image]"
            echo "  --help [Display usage]"
            exit
            ;;
    esac
    shift   # Check next set of parameters.
done

. fdo_version.sh
. mapguide_version.sh

case "$TARGET" in
    fdo)
        build_fdo_thin $DISTRO $CPU $TAG $BUILD_THIN_IMAGE
        ;;
    mapguide)
        build_mapguide_thin $DISTRO $CPU $TAG $BUILD_THIN_IMAGE
        ;;
    *)
        echo "Unknown target: $TARGET"
        exit 1
        ;;
esac