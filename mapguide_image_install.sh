#!/bin/bash

ROOT=$(realpath .)
ARTIFACTS_ROOT=$ROOT/artifacts/Release
SCRIPT_ROOT=$ROOT/templates/scripts/container
TEST_ROOT=$ROOT/test
INTERACTIVE=0
UBUNTU_VERSION=ubuntu22

install_mapguide_env()
{
    package="mapguideopensource-$MG_VER-$1-install.run"
    target_distro=$2
    target_distro_tag=$3

    if [ ! -f "$ARTIFACTS_ROOT/$package" ];
    then
        echo "ERROR: Installer package [$package] not found"
        exit 1
    fi

    container_name="$target_distro:$target_distro_tag"
    echo "Running MapGuide tests within container: ${container_name}"
    echo "With package: $package"

    if [ "$INTERACTIVE" == "1" ];
    then
        docker run --rm -it -p 8008:8008 -v ${TEST_ROOT}:/tests -v ${SCRIPT_ROOT}:/scripts -v ${ARTIFACTS_ROOT}:/artifacts $container_name /bin/bash
    else
        docker run --rm -it -p 8008:8008 -v ${TEST_ROOT}:/tests -v ${SCRIPT_ROOT}:/scripts -v ${ARTIFACTS_ROOT}:/artifacts $container_name /scripts/mapguide_smoke_test.sh --package $package --distro $target_distro
    fi
}

TARGET=generic
TARGET_DISTRO=ubuntu
TARGET_DISTRO_TAG=latest
while [ $# -gt 0 ]; do    # Until you run out of parameters...
    case "$1" in
        --interactive)
            INTERACTIVE=1
            ;;
        --target)
            TARGET="$2"
            shift
            ;;
        --target-distro)
            TARGET_DISTRO="$2"
            shift
            ;;
        --tag)
            TARGET_DISTRO_TAG="$2"
            shift
            ;;
        --help)
            echo "Usage: $0 (options)"
            echo "Options:"
            echo "  --target [generic|$UBUNTU_VERSION]"
            echo "  --target-distro [distro image to use]"
            echo "  --tag [distro image tag to use, default: latest]"
            echo "  --help [Display usage]"
            exit
            ;;
    esac
    shift   # Check next set of parameters.
done

. fdo_version.sh
. mapguide_version.sh

install_mapguide_env "$TARGET" "$TARGET_DISTRO" "$TARGET_DISTRO_TAG"