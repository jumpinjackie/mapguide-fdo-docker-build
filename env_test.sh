#!/bin/bash

# Use podman if available, otherwise docker
. ./container_engine.sh

ROOT=$(realpath .)
SCRIPT_ROOT=$ROOT/templates/scripts/container
# Extra arguments for run_mapguide_tests.sh (--tier, --web-suite, --portable-suite)
RUN_ARGS=

test_fdo_env()
{
    distro=$1
    cpu=$2

    container_name="fdo_${distro}_build_${cpu}"
    log_path=$ROOT/logs/test/$container_name
    # podman will not create a missing bind mount source for us
    mkdir -p "${log_path}"

    "$DOCKER_CMD" run -e NLSPATH="/usr/local/src/fdo/build/nls/linux/en_US/%N" --rm -it -v ${log_path}:/logs${DOCKER_VOLUME_OPT} -v ${SCRIPT_ROOT}:/scripts${DOCKER_VOLUME_OPT} $DOCKER_RUN_EX_ARGS $DOCKER_RUN_AS_ROOT_ARGS $container_name /scripts/run_fdo_tests.sh --log-path /logs --fdo-build-dir /usr/local/src/fdo/build
}

test_mapguide_env()
{
    distro=$1
    cpu=$2

    container_name="mapguide_${distro}_build_${cpu}"
    log_path=$ROOT/logs/test/$container_name
    # podman will not create a missing bind mount source for us
    mkdir -p "${log_path}"

    "$DOCKER_CMD" run --rm -it -v ${log_path}:/logs${DOCKER_VOLUME_OPT} -v ${SCRIPT_ROOT}:/scripts${DOCKER_VOLUME_OPT} $DOCKER_RUN_EX_ARGS $DOCKER_RUN_AS_ROOT_ARGS $container_name /scripts/run_mapguide_tests.sh --log-path /logs --mapguide-build-dir /usr/local/src/mapguide/build $RUN_ARGS
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
        --tier)
            RUN_ARGS="$RUN_ARGS --tier $2"
            shift
            ;;
        --web-suite)
            RUN_ARGS="$RUN_ARGS --web-suite $2"
            shift
            ;;
        --portable-suite)
            RUN_ARGS="$RUN_ARGS --portable-suite $2"
            shift
            ;;
        --help)
            echo "Usage: $0 (options)"
            echo "Options:"
            echo "  --target [mapguide|fdo]"
            echo "  --distro [the distro you are targeting, ubuntu|generic]"
            echo "  --cpu [x86|x64]"
            echo "  --tier [server|web|portable|all - MapGuide only, forwarded to run_mapguide_tests.sh]"
            echo "  --web-suite [Web tier suite for --tier web, repeatable, MapGuide only]"
            echo "  --portable-suite [MgPortable suite for --tier portable, repeatable, MapGuide only]"
            echo "  --help [Display usage]"
            exit
            ;;
    esac
    shift   # Check next set of parameters.
done

if [ -n "$RUN_ARGS" ] && [ "$TARGET" != "mapguide" ]; then
    echo "FATAL: --tier, --web-suite and --portable-suite only apply to --target mapguide"
    exit 1
fi

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