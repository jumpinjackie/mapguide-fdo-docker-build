#!/bin/bash
DISTRO=ubuntu22
DOCKER_IMAGE=ubuntu:22.04
PORT_MAPPINGS=""

while [ $# -gt 0 ]; do    # Until you run out of parameters...
    case "$1" in
        --distro)
            DISTRO="$2"
            shift
            ;;
        --docker-image)
            DOCKER_IMAGE="$2"
            shift
            ;;
        --port-mappings)
            PORT_MAPPINGS="$PORT_MAPPINGS -p $2"
            shift
            ;;
        --help)
            echo "Usage: $0 (options)"
            echo "Options:"
            echo "  --distro [The installer to install into image. Default: $DISTRO]"
            echo "  --docker-image [The docker image to use. Default: $DOCKER_IMAGE]"
            echo "  --port-mappings [Extra port mappings for docker run, e.g. 1234:5678]"
            echo "  --help [Display usage]"
            exit
            ;;
    esac
    shift   # Check next set of parameters.
done

. mapguide_version.sh
INSTALL_PKG="mapguideopensource-${MG_VER}-${DISTRO}-install.run"
if [ ! -f "$PWD/artifacts/Release/$INSTALL_PKG" ]; then
    echo "[error]: Installer package not found"
    exit 1
fi

if [ -z "$(docker images -q "$DOCKER_IMAGE" 2> /dev/null)" ]; then
    echo "[error]: No such docker image found ($DOCKER_IMAGE)"
    exit 1
fi

echo "Setting up container from image ($DOCKER_IMAGE)"
echo "To run the installer package from within the container, execute the following inside the container:"
echo "    /tmp/artifacts/$INSTALL_PKG"
echo "NOTE: Depending on the distro, you may need to install some prerequiste packages first"
docker run -p 8008:8008 $PORT_MAPPINGS -v "$PWD/artifacts/Release:/tmp/artifacts" -it "$DOCKER_IMAGE" "/bin/bash"