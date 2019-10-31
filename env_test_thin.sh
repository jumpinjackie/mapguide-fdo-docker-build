#!/bin/bash

ROOT=$(realpath .)
SCRIPT_ROOT=$ROOT/templates/scripts/container
INTERACTIVE=0

test_fdo_env()
{
    distro=$1
    cpu=$2

    container_root="/tmp/work"
    src_dir="$PWD/fdo"
    build_area_dir="$PWD/build_area/$cpu/$distro/fdo"
    container_name="fdo_${distro}_develop_thin_${cpu}"
    ccache_dir="$PWD/caches/${cpu}/fdo/${distro}/.ccache"
    log_path=$ROOT/logs/test/$container_name
    if [ "$INTERACTIVE" == "1" ];
    then
        echo "Entering FDO build container: ${container_name}"
        docker run -e NLSPATH="/tmp/work/build_area/fdo/nls/linux/en_US/%N" --rm -it -e FDO_VER_MAJOR=${FDO_VER_MAJOR} -e FDO_VER_MINOR=${FDO_VER_MINOR} -e FDO_VER_REL=${FDO_VER_REL} -e FDO_VER_REV=${FDO_VER_REV} -e FDO_VER=$FDO_VER -e FDO_VER_TRIPLE=$FDO_VER_TRIPLE -v $ccache_dir:/root/.ccache -v $build_area_dir:$container_root/build_area -v ${log_path}:/logs -v $src_dir:$container_root/src -v ${SCRIPT_ROOT}:/scripts $container_name /bin/bash
    else
        echo "Running FDO tests within container: ${container_name}"
        docker run -e NLSPATH="/tmp/work/build_area/fdo/nls/linux/en_US/%N" --rm -it -e FDO_VER_MAJOR=${FDO_VER_MAJOR} -e FDO_VER_MINOR=${FDO_VER_MINOR} -e FDO_VER_REL=${FDO_VER_REL} -e FDO_VER_REV=${FDO_VER_REV} -e FDO_VER=$FDO_VER -e FDO_VER_TRIPLE=$FDO_VER_TRIPLE -v $ccache_dir:/root/.ccache -v $build_area_dir:$container_root/build_area -v ${log_path}:/logs -v $src_dir:$container_root/src -v ${SCRIPT_ROOT}:/scripts $container_name /scripts/run_fdo_tests.sh --log-path /logs --fdo-build-dir $container_root/build_area/fdo
    fi
}

test_mapguide_env()
{
    distro=$1
    cpu=$2

    container_name="mapguide_${distro}_develop_thin_${cpu}"
    log_path=$ROOT/logs/test/$container_name
    echo "Running MapGuide tests within container: ${container_name}"
    if [ "$INTERACTIVE" == "1" ];
    then
        docker run --rm -it -v ${log_path}:/logs -v ${SCRIPT_ROOT}:/scripts $container_name /bin/bash
    else
        docker run --rm -it -v ${log_path}:/logs -v ${SCRIPT_ROOT}:/scripts $container_name /scripts/run_mapguide_tests.sh --log-path /logs --mapguide-build-dir /usr/local/src/mapguide/build
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
        --help)
            echo "Usage: $0 (options)"
            echo "Options:"
            echo "  --target [mapguide|fdo]"
            echo "  --distro [the distro you are targeting, ubuntu|centos]"
            echo "  --cpu [x86|x64]"
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