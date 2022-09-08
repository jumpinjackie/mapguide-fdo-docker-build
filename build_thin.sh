#!/bin/bash

TARGET=fdo
DISTRO=ubuntu
CPU=x64
TAG=14.04
BUILD_THIN_IMAGE=0
INTERACTIVE=0
BUILD_CONF=Release

check_build()
{
    if [ "$?" -ne 0 ] ; then
        echo "ERROR building for $BUILD_DISTRO"
        exit 1
    fi
}

indent(){
    sed 's/^/    /'
}

build_fdo_thin()
{
    distro=$1
    cpu=$2
    tag=$3
    build_image_only=$4
    build_config=$5

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

    echo "Building FDO for: ${distro_label}"

    if [ "$build_image_only" -eq "1" ]; then
        pushd "docker/${cpu}/fdo/${distro_label}/develop_thin" || exit
        ./snap.sh
        popd || exit
    else
        build_area_dir="$PWD/build_area/$cpu/$build_config/$distro_label/fdo"
        mkdir -p "$build_area_dir"
        src_dir="$PWD/fdo"
        scripts_dir="$PWD/templates/scripts/container"
        artifacts_dir="$PWD/artifacts/$build_config"
        sdks_dir="$PWD/sdks"
        download_tmp_dir="$sdks_dir/container_download/fdo/$distro_label"
        mkdir -p "$download_tmp_dir"
        ccache_dir="$PWD/caches/${cpu}/$build_config/fdo/${distro_label}/.ccache"
        container_name="fdo_${distro_label}_develop_thin_${cpu}"

        container_root="/tmp/work"
        if [ "$INTERACTIVE" == "1" ]; then
            docker run --rm -it -e FDO_BUILD_CONFIG=$build_config -e FDO_DISTRO=$distro_label -e FDO_VER_MAJOR=${FDO_VER_MAJOR} -e FDO_VER_MINOR=${FDO_VER_MINOR} -e FDO_VER_REL=${FDO_VER_REL} -e FDO_VER_REV=${FDO_VER_REV} -e FDO_VER=$FDO_VER -e FDO_VER_TRIPLE=$FDO_VER_TRIPLE -v $ccache_dir:/root/.ccache -v $download_tmp_dir:/tmp/download -v $scripts_dir:$container_root/scripts -v $build_area_dir:$container_root/build_area -v $src_dir:$container_root/src -v $artifacts_dir:$container_root/artifacts -v $sdks_dir:$container_root/sdks $container_name /bin/bash
            check_build
        else
            # If a distro-specific override build script exists, use that instead
            if [ -f "${scripts_dir}/build_fdo_${distro_label}.sh" ]; then
                echo "Building with override build_fdo_${distro_label}.sh"
                docker run --rm -it -e FDO_BUILD_CONFIG=$build_config -e FDO_DISTRO=$distro_label -e FDO_VER_MAJOR=${FDO_VER_MAJOR} -e FDO_VER_MINOR=${FDO_VER_MINOR} -e FDO_VER_REL=${FDO_VER_REL} -e FDO_VER_REV=${FDO_VER_REV} -e FDO_VER=$FDO_VER -e FDO_VER_TRIPLE=$FDO_VER_TRIPLE -v $ccache_dir:/root/.ccache -v $download_tmp_dir:/tmp/download -v $scripts_dir:$container_root/scripts -v $build_area_dir:$container_root/build_area -v $src_dir:$container_root/src -v $artifacts_dir:$container_root/artifacts -v $sdks_dir:$container_root/sdks $container_name $container_root/scripts/build_fdo_${distro_label}.sh
                check_build
            else
                echo "Building with standard container build script"
                docker run --rm -it -e FDO_BUILD_CONFIG=$build_config -e FDO_DISTRO=$distro_label -e FDO_VER_MAJOR=${FDO_VER_MAJOR} -e FDO_VER_MINOR=${FDO_VER_MINOR} -e FDO_VER_REL=${FDO_VER_REL} -e FDO_VER_REV=${FDO_VER_REV} -e FDO_VER=$FDO_VER -e FDO_VER_TRIPLE=$FDO_VER_TRIPLE -v $ccache_dir:/root/.ccache -v $download_tmp_dir:/tmp/download -v $scripts_dir:$container_root/scripts -v $build_area_dir:$container_root/build_area -v $src_dir:$container_root/src -v $artifacts_dir:$container_root/artifacts -v $sdks_dir:$container_root/sdks $container_name $container_root/scripts/build_fdo.sh
                check_build
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
    build_config=$5

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

    if [ "$build_image_only" -eq "1" ]; then
        pushd "docker/${cpu}/mapguide/${distro_label}/develop_thin" || exit
        ./snap.sh
        popd || exit
    else
        build_area_dir="$PWD/build_area/$cpu/$build_config/$distro_label/mapguide"
        mkdir -p "$build_area_dir"
        src_dir="$PWD/mapguide/MgDev"
        scripts_dir="$PWD/templates/scripts/container"
        artifacts_dir="$PWD/artifacts/$build_config"
        container_name="mapguide_${distro_label}_develop_thin_${cpu}"
        ccache_dir="$PWD/caches/${cpu}/$build_config/mapguide/${distro_label}/.ccache"
        patches_dir="$PWD/patches"
        sdks_dir="$PWD/sdks"
        download_tmp_dir="$sdks_dir/container_download/mapguide/$distro_label"
        mkdir -p "$download_tmp_dir"
        fdosdk="fdosdk-${FDO_VER}-${distro_label}-${cpu_label}.tar.gz"

        container_root="/tmp/work"
        if [ "$INTERACTIVE" == "1" ]; then
            docker run --rm -it -e MG_BUILD_CONFIG=$build_config -e MG_DISTRO=$distro_label -e FDO_VER=$FDO_VER -e FDO_VER_TRIPLE=$FDO_VER_TRIPLE -e MG_VER_REV=$MG_VER_REV -e MG_VER_TRIPLE=$MG_VER_TRIPLE -e FDOSDK=$fdosdk -v $patches_dir:$container_root/patches -v $ccache_dir:/root/.ccache -v $download_tmp_dir:/tmp/download -v $scripts_dir:$container_root/scripts -v $build_area_dir:$container_root/build_area -v $src_dir:$container_root/src -v $artifacts_dir:$container_root/artifacts -v $sdks_dir:$container_root/sdks $container_name /bin/bash
            check_build
        else
            # If a distro-specific override build script exists, use that instead
            if [ -f "${scripts_dir}/build_mapguide_${distro_label}.sh" ]; then
                echo "Building with override build_mapguide_${distro_label}.sh"
                docker run --rm -it -e MG_BUILD_CONFIG=$build_config -e MG_DISTRO=$distro_label -e FDO_VER=$FDO_VER -e FDO_VER_TRIPLE=$FDO_VER_TRIPLE -e MG_VER_REV=$MG_VER_REV -e MG_VER_TRIPLE=$MG_VER_TRIPLE -e FDOSDK=$fdosdk -v $patches_dir:$container_root/patches -v $ccache_dir:/root/.ccache -v $download_tmp_dir:/tmp/download -v $scripts_dir:$container_root/scripts -v $build_area_dir:$container_root/build_area -v $src_dir:$container_root/src -v $artifacts_dir:$container_root/artifacts -v $sdks_dir:$container_root/sdks $container_name $container_root/scripts/build_mapguide_${distro_label}.sh
                check_build
            else
                echo "Building with standard container build script"
                docker run --rm -it -e MG_BUILD_CONFIG=$build_config -e MG_DISTRO=$distro_label -e FDO_VER=$FDO_VER -e FDO_VER_TRIPLE=$FDO_VER_TRIPLE -e MG_VER_REV=$MG_VER_REV -e MG_VER_TRIPLE=$MG_VER_TRIPLE -e FDOSDK=$fdosdk -v $patches_dir:$container_root/patches -v $ccache_dir:/root/.ccache -v $download_tmp_dir:/tmp/download -v $scripts_dir:$container_root/scripts -v $build_area_dir:$container_root/build_area -v $src_dir:$container_root/src -v $artifacts_dir:$container_root/artifacts -v $sdks_dir:$container_root/sdks $container_name $container_root/scripts/build_mapguide.sh
                check_build
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
        --debug)
            BUILD_CONF=Debug
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
            echo "  --debug [Build for debug mode]"
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
        build_fdo_thin $DISTRO $CPU $TAG $BUILD_THIN_IMAGE $BUILD_CONF
        ;;
    mapguide)
        build_mapguide_thin $DISTRO $CPU $TAG $BUILD_THIN_IMAGE $BUILD_CONF
        ;;
    *)
        echo "Unknown target: $TARGET"
        exit 1
        ;;
esac