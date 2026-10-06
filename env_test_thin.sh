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

    container_name="mapguide_${distro}_develop_thin_${cpu}"
    log_path=$ROOT/logs/test/$container_name
    # podman will not create a missing bind mount source for us
    mkdir -p "${log_path}"
    echo "Running MapGuide tests within container: ${container_name}"
    if [ "$INTERACTIVE" == "1" ];
    then
        "$DOCKER_CMD" run --rm -it -v ${log_path}:/logs${DOCKER_VOLUME_OPT} -v ${SCRIPT_ROOT}:/scripts${DOCKER_VOLUME_OPT} $DOCKER_RUN_EX_ARGS $DOCKER_RUN_AS_ROOT_ARGS $container_name /bin/bash
    else
        "$DOCKER_CMD" run --rm -it -v ${log_path}:/logs${DOCKER_VOLUME_OPT} -v ${SCRIPT_ROOT}:/scripts${DOCKER_VOLUME_OPT} $DOCKER_RUN_EX_ARGS $DOCKER_RUN_AS_ROOT_ARGS $container_name /scripts/run_mapguide_tests.sh --log-path /logs --mapguide-build-dir /usr/local/src/mapguide/build
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