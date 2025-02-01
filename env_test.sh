#!/bin/bash

ROOT=$(realpath .)
SCRIPT_ROOT=$ROOT/templates/scripts/container

test_fdo_env()
{
    distro=$1
    cpu=$2

    container_name="fdo_${distro}_build_${cpu}"
    log_path=$ROOT/logs/test/$container_name

    docker run -e NLSPATH="/usr/local/src/fdo/build/nls/linux/en_US/%N" --rm -it -v ${log_path}:/logs -v ${SCRIPT_ROOT}:/scripts $container_name /scripts/run_fdo_tests.sh --log-path /logs --fdo-build-dir /usr/local/src/fdo/build
}

test_mapguide_env()
{
    distro=$1
    cpu=$2

    container_name="mapguide_${distro}_build_${cpu}"
    log_path=$ROOT/logs/test/$container_name

    docker run --rm -it -v ${log_path}:/logs -v ${SCRIPT_ROOT}:/scripts $container_name /scripts/run_mapguide_tests.sh --log-path /logs --mapguide-build-dir /usr/local/src/mapguide/build
}

TARGET=fdo
DISTRO=ubuntu14
CPU=x64
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
        --cpu)
            CPU="$2"
            shift
            ;;
        --help)
            echo "Usage: $0 (options)"
            echo "Options:"
            echo "  --target [mapguide|fdo]"
            echo "  --distro [the distro you are targeting, ubuntu|generic]"
            echo "  --cpu [x86|x64]"
            echo "  --help [Display usage]"
            exit
            ;;
    esac
    shift   # Check next set of parameters.
done

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