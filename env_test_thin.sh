#!/bin/bash

# Use podman if available, otherwise docker
. ./container_engine.sh

ROOT=$(realpath .)
SCRIPT_ROOT=$ROOT/templates/scripts/container
INTERACTIVE=0
BUILD_CONF=Release

test_fdo_env()
{
    distro=$1
    cpu=$2

    container_root="/tmp/work"
    src_dir="$PWD/fdo"
    # The build area and the ccache are per build configuration, exactly as build_thin.sh lays them out
    build_area_dir="$PWD/build_area/$cpu/$BUILD_CONF/$distro/fdo"
    container_name="fdo_${distro}_develop_thin_${cpu}"
    ccache_dir="$PWD/caches/${cpu}/$BUILD_CONF/fdo/${distro}/.ccache"
    # The FDO install step links the Oracle provider against the client libraries here
    sdks_dir="$PWD/sdks"
    log_path=$ROOT/logs/test/$container_name
    # podman will not create a missing bind mount source for us
    mkdir -p "${log_path}"
    if [ "$INTERACTIVE" == "1" ];
    then
        echo "Entering FDO build container: ${container_name}"
        "$DOCKER_CMD" run -e NLSPATH="/tmp/work/build_area/fdo/nls/linux/en_US/%N" --rm -it -e FDO_VER_MAJOR=${FDO_VER_MAJOR} -e FDO_VER_MINOR=${FDO_VER_MINOR} -e FDO_VER_REL=${FDO_VER_REL} -e FDO_VER_REV=${FDO_VER_REV} -e FDO_VER=$FDO_VER -e FDO_VER_TRIPLE=$FDO_VER_TRIPLE -v $ccache_dir:/root/.ccache${DOCKER_VOLUME_OPT} -v $build_area_dir:$container_root/build_area${DOCKER_VOLUME_OPT} -v ${log_path}:/logs${DOCKER_VOLUME_OPT} -v $src_dir:$container_root/src${DOCKER_VOLUME_OPT} -v $sdks_dir:$container_root/sdks${DOCKER_VOLUME_OPT} -v ${SCRIPT_ROOT}:/scripts${DOCKER_VOLUME_OPT} $DOCKER_RUN_EX_ARGS $DOCKER_RUN_AS_ROOT_ARGS $container_name /bin/bash
    else
        echo "Running FDO tests within container: ${container_name}"
        "$DOCKER_CMD" run -e NLSPATH="/tmp/work/build_area/fdo/nls/linux/en_US/%N" --rm -it -e FDO_VER_MAJOR=${FDO_VER_MAJOR} -e FDO_VER_MINOR=${FDO_VER_MINOR} -e FDO_VER_REL=${FDO_VER_REL} -e FDO_VER_REV=${FDO_VER_REV} -e FDO_VER=$FDO_VER -e FDO_VER_TRIPLE=$FDO_VER_TRIPLE -v $ccache_dir:/root/.ccache${DOCKER_VOLUME_OPT} -v $build_area_dir:$container_root/build_area${DOCKER_VOLUME_OPT} -v ${log_path}:/logs${DOCKER_VOLUME_OPT} -v $src_dir:$container_root/src${DOCKER_VOLUME_OPT} -v $sdks_dir:$container_root/sdks${DOCKER_VOLUME_OPT} -v ${SCRIPT_ROOT}:/scripts${DOCKER_VOLUME_OPT} $DOCKER_RUN_EX_ARGS $DOCKER_RUN_AS_ROOT_ARGS $container_name /scripts/run_fdo_tests.sh --log-path /logs --fdo-build-dir $container_root/build_area/fdo
    fi
}

test_mapguide_env()
{
    distro=$1
    cpu=$2

    # The develop_thin image carries no MapGuide build, so the test container has to mount the
    # same trees a build container does: the CMake build output, the FDO SDK tarball the tree
    # was configured against, and the patches/atomic.h the build needs. run_mapguide_tests.sh
    # installs the FDO SDK from the tarball if the container does not have it yet.
    container_root="/tmp/work"
    src_dir="$PWD/mapguide/MgDev"
    fdo_src_dir="$PWD/fdo"
    build_area_dir="$PWD/build_area/$cpu/$BUILD_CONF/$distro/mapguide"
    artifacts_dir="$PWD/artifacts/$BUILD_CONF"
    patches_dir="$PWD/patches"
    sdks_dir="$PWD/sdks"
    container_name="mapguide_${distro}_develop_thin_${cpu}"
    ccache_dir="$PWD/caches/${cpu}/$BUILD_CONF/mapguide/${distro}/.ccache"
    cpu_label=amd64
    if [ "$cpu" = "x86" ]; then
        cpu_label=i386
    fi
    fdosdk="fdosdk-${FDO_VER}-${distro}-${cpu_label}.tar.gz"
    log_path=$ROOT/logs/test/$container_name
    # podman will not create a missing bind mount source for us
    mkdir -p "${log_path}" "$ccache_dir"
    echo "Running MapGuide tests within container: ${container_name}"
    if [ "$INTERACTIVE" == "1" ];
    then
        "$DOCKER_CMD" run --rm -it -e MG_BUILD_CONFIG=$BUILD_CONF -e MG_DISTRO=$distro -e FDO_VER_TRIPLE=$FDO_VER_TRIPLE -e FDOSDK=$fdosdk -e CCACHE_DIR=/tmp/ccache -v $patches_dir:$container_root/patches${DOCKER_VOLUME_OPT} -v $ccache_dir:/tmp/ccache${DOCKER_VOLUME_OPT} -v $build_area_dir:$container_root/build_area${DOCKER_VOLUME_OPT} -v ${log_path}:/logs${DOCKER_VOLUME_OPT} -v $src_dir:$container_root/src${DOCKER_VOLUME_OPT} -v $fdo_src_dir:$container_root/fdo_src${DOCKER_VOLUME_OPT} -v $artifacts_dir:$container_root/artifacts${DOCKER_VOLUME_OPT} -v $sdks_dir:$container_root/sdks${DOCKER_VOLUME_OPT} -v ${SCRIPT_ROOT}:/scripts${DOCKER_VOLUME_OPT} $DOCKER_RUN_EX_ARGS $DOCKER_RUN_AS_ROOT_ARGS $container_name /bin/bash
    else
        "$DOCKER_CMD" run --rm -it -e MG_BUILD_CONFIG=$BUILD_CONF -e MG_DISTRO=$distro -e FDO_VER_TRIPLE=$FDO_VER_TRIPLE -e FDOSDK=$fdosdk -e CCACHE_DIR=/tmp/ccache -v $patches_dir:$container_root/patches${DOCKER_VOLUME_OPT} -v $ccache_dir:/tmp/ccache${DOCKER_VOLUME_OPT} -v $build_area_dir:$container_root/build_area${DOCKER_VOLUME_OPT} -v ${log_path}:/logs${DOCKER_VOLUME_OPT} -v $src_dir:$container_root/src${DOCKER_VOLUME_OPT} -v $fdo_src_dir:$container_root/fdo_src${DOCKER_VOLUME_OPT} -v $artifacts_dir:$container_root/artifacts${DOCKER_VOLUME_OPT} -v $sdks_dir:$container_root/sdks${DOCKER_VOLUME_OPT} -v ${SCRIPT_ROOT}:/scripts${DOCKER_VOLUME_OPT} $DOCKER_RUN_EX_ARGS $DOCKER_RUN_AS_ROOT_ARGS $container_name /scripts/run_mapguide_tests.sh --log-path /logs --mapguide-build-dir $container_root/build_area/mapguide
    fi
}

TARGET=fdo
DISTRO=ubuntu14
CPU=x64
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
        --cpu)
            CPU="$2"
            shift
            ;;
        --debug)
            BUILD_CONF=Debug
            ;;
        --help)
            echo "Usage: $0 (options)"
            echo "Options:"
            echo "  --target [mapguide|fdo]"
            echo "  --distro [the distro you are targeting, ubuntu|generic]"
            echo "  --cpu [x86|x64]"
            echo "  --debug [Test the debug build area and ccache]"
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
        test_fdo_env $DISTRO $CPU $TAG
        ;;
    mapguide)
        test_mapguide_env $DISTRO $CPU $TAG
        ;;
    *)
        echo "Unknown target: $TARGET"
        exit 1
        ;;
esac