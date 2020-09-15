#!/bin/bash

TARGET=fdo
DISTRO=ubuntu
CPU=x64
TAG=14.04
BUILD_THIN_IMAGE=0
INTERACTIVE=0

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

    echo "Building FDO for: ${distro_label}"

    if [ $build_image_only -eq 1 ]; then
        pushd docker/${cpu}/fdo/${distro_label}/develop_thin
        ./snap.sh
        popd
    else
        build_area_dir="$PWD/build_area/$cpu/$distro_label/fdo"
        mkdir -p "$build_area_dir"
        src_dir="$PWD/fdo"
        scripts_dir="$PWD/templates/scripts/container"
        artifacts_dir="$PWD/artifacts"
        sdks_dir="$PWD/sdks"
        ccache_dir="$PWD/caches/${cpu}/fdo/${distro_label}/.ccache"
        container_name="fdo_${distro_label}_develop_thin_${cpu}"

        container_root="/tmp/work"
        if [ "$INTERACTIVE" == "1" ]; then
            docker run --rm -it -e FDO_DISTRO=$distro_label -e FDO_VER_MAJOR=${FDO_VER_MAJOR} -e FDO_VER_MINOR=${FDO_VER_MINOR} -e FDO_VER_REL=${FDO_VER_REL} -e FDO_VER_REV=${FDO_VER_REV} -e FDO_VER=$FDO_VER -e FDO_VER_TRIPLE=$FDO_VER_TRIPLE -v $ccache_dir:/root/.ccache -v $scripts_dir:$container_root/scripts -v $build_area_dir:$container_root/build_area -v $src_dir:$container_root/src -v $artifacts_dir:$container_root/artifacts -v $sdks_dir:$container_root/sdks $container_name /bin/bash
        else
            # If a distro-specific override build script exists, use that instead
            if [ -f "${scripts_dir}/build_fdo_${distro_label}.sh" ]; then
                echo "Building with override build_fdo_${distro_label}.sh"
                docker run --rm -it -e FDO_DISTRO=$distro_label -e FDO_VER_MAJOR=${FDO_VER_MAJOR} -e FDO_VER_MINOR=${FDO_VER_MINOR} -e FDO_VER_REL=${FDO_VER_REL} -e FDO_VER_REV=${FDO_VER_REV} -e FDO_VER=$FDO_VER -e FDO_VER_TRIPLE=$FDO_VER_TRIPLE -v $ccache_dir:/root/.ccache -v $scripts_dir:$container_root/scripts -v $build_area_dir:$container_root/build_area -v $src_dir:$container_root/src -v $artifacts_dir:$container_root/artifacts -v $sdks_dir:$container_root/sdks $container_name $container_root/scripts/build_fdo_${distro_label}.sh
            else
                echo "Building with standard container build script"
                docker run --rm -it -e FDO_DISTRO=$distro_label -e FDO_VER_MAJOR=${FDO_VER_MAJOR} -e FDO_VER_MINOR=${FDO_VER_MINOR} -e FDO_VER_REL=${FDO_VER_REL} -e FDO_VER_REV=${FDO_VER_REV} -e FDO_VER=$FDO_VER -e FDO_VER_TRIPLE=$FDO_VER_TRIPLE -v $ccache_dir:/root/.ccache -v $scripts_dir:$container_root/scripts -v $build_area_dir:$container_root/build_area -v $src_dir:$container_root/src -v $artifacts_dir:$container_root/artifacts -v $sdks_dir:$container_root/sdks $container_name $container_root/scripts/build_fdo.sh
            fi
        fi
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

    if [ "$distro" = "generic" ]; then
        distro_label="generic"
    fi

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

    echo "Building MapGuide for: ${distro_label}"

    if [ $build_image_only -eq 1 ]; then
        pushd docker/${cpu}/mapguide/${distro_label}/develop_thin
        ./snap.sh
        popd
    else
        build_area_dir="$PWD/build_area/$cpu/$distro_label/mapguide"
        mkdir -p "$build_area_dir"
        src_dir="$PWD/mapguide/MgDev"
        scripts_dir="$PWD/templates/scripts/container"
        artifacts_dir="$PWD/artifacts"
        container_name="mapguide_${distro_label}_develop_thin_${cpu}"
        ccache_dir="$PWD/caches/${cpu}/mapguide/${distro_label}/.ccache"
        patches_dir="$PWD/patches"
        fdosdk="fdosdk-${FDO_VER}-${distro_label}-${cpu_label}.tar.gz"

        container_root="/tmp/work"
        if [ "$INTERACTIVE" == "1" ]; then
            docker run --rm -it -e MG_DISTRO=$distro_label -e FDO_VER=$FDO_VER -e FDO_VER_TRIPLE=$FDO_VER_TRIPLE -e MG_VER_REV=$MG_VER_REV -e MG_VER_TRIPLE=$MG_VER_TRIPLE -e FDOSDK=$fdosdk -v $patches_dir:$container_root/patches -v $ccache_dir:/root/.ccache -v $scripts_dir:$container_root/scripts -v $build_area_dir:$container_root/build_area -v $src_dir:$container_root/src -v $artifacts_dir:$container_root/artifacts $container_name /bin/bash
        else
            # If a distro-specific override build script exists, use that instead
            if [ -f "${scripts_dir}/build_mapguide_${distro_label}.sh" ]; then
                echo "Building with override build_mapguide_${distro_label}.sh"
                docker run --rm -it -e MG_DISTRO=$distro_label -e FDO_VER=$FDO_VER -e FDO_VER_TRIPLE=$FDO_VER_TRIPLE -e MG_VER_REV=$MG_VER_REV -e MG_VER_TRIPLE=$MG_VER_TRIPLE -e FDOSDK=$fdosdk -v $patches_dir:$container_root/patches -v $ccache_dir:/root/.ccache -v $scripts_dir:$container_root/scripts -v $build_area_dir:$container_root/build_area -v $src_dir:$container_root/src -v $artifacts_dir:$container_root/artifacts $container_name $container_root/scripts/build_mapguide_${distro_label}.sh
            else
                echo "Building with standard container build script"
                docker run --rm -it -e MG_DISTRO=$distro_label -e FDO_VER=$FDO_VER -e FDO_VER_TRIPLE=$FDO_VER_TRIPLE -e MG_VER_REV=$MG_VER_REV -e MG_VER_TRIPLE=$MG_VER_TRIPLE -e FDOSDK=$fdosdk -v $patches_dir:$container_root/patches -v $ccache_dir:/root/.ccache -v $scripts_dir:$container_root/scripts -v $build_area_dir:$container_root/build_area -v $src_dir:$container_root/src -v $artifacts_dir:$container_root/artifacts $container_name $container_root/scripts/build_mapguide.sh
            fi
        fi
    fi
}

while [ $# -gt 0 ]; do    # Until you run out of parameters...
    case "$1" in
        --interactive)
            INTERACTIVE=1
            ;;
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
            echo "  --interactive [Enter the build container with an interactive bash prompt]"
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