#!/bin/bash
# Use podman if available, otherwise docker
. ./container_engine.sh

DISTRO=ubuntu22
DOCKER_IMAGE=ubuntu:22.04
PORT_MAPPINGS=""
VOLUME_MOUNTS=()
MOUNT_PACKAGES=1
# The SELinux label to add to mounts, as a bare option name (":z" -> "z"), empty when not needed
SELINUX_LABEL="${DOCKER_VOLUME_OPT#:}"

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
        --volume)
            case "$2" in
                *:*:*)
                    # A third field already carries mount options, and the engine parses those
                    # comma-separated, so the SELinux label has to be appended with a comma
                    VOLUME_MOUNTS+=(-v "$2${SELINUX_LABEL:+,$SELINUX_LABEL}")
                    ;;
                *)
                    VOLUME_MOUNTS+=(-v "$2${DOCKER_VOLUME_OPT}")
                    ;;
            esac
            shift
            ;;
        --no-packages)
            MOUNT_PACKAGES=0
            ;;
        --help)
            echo "Usage: $0 (options)"
            echo "Options:"
            echo "  --distro [The installer to install into image. Default: $DISTRO]"
            echo "  --docker-image [The docker image to use. Default: $DOCKER_IMAGE]"
            echo "  --port-mappings [Extra port mappings for docker run, e.g. 1234:5678]"
            echo "  --volume [Extra volume mount for docker run, in host:container[:opts] form, e.g. \$PWD/my-data:/tmp/my-data]"
            echo "  --no-packages [Do not mount \$PWD/packages into the installed server's Packages directory]"
            echo "  --help [Display usage]"
            exit
            ;;
    esac
    shift   # Check next set of parameters.
done

. mapguide_version.sh
INSTALL_PKG="mapguideopensource-${MG_VER}-${DISTRO}-install.run"
# Same install prefix the MapGuide tree is built with (MG_INSTALL_PREFIX: major.minor.rel, not the full version)
MG_INSTALL_ROOT="/usr/local/mapguideopensource-${MG_VER_TRIPLE}"
if [ ! -f "$PWD/artifacts/Release/$INSTALL_PKG" ]; then
    echo "[error]: Installer package not found"
    exit 1
fi

if [ -z "$("$DOCKER_CMD" images -q "$DOCKER_IMAGE" 2> /dev/null)" ]; then
    echo "[error]: No such container image found ($DOCKER_IMAGE)"
    exit 1
fi

# Mount the host packages dir into the installed server's Packages dir, so packages (.mgp) can be
# dropped in from either side. Mounted ahead of any --volume so an explicit mount for the same
# container path takes precedence.
PACKAGES_DIR="$PWD/packages"
PACKAGES_MOUNTS=()
if [ "$MOUNT_PACKAGES" = "1" ]; then
    if [ -d "$PACKAGES_DIR" ]; then
        PACKAGES_MOUNTS=(-v "$PACKAGES_DIR:$MG_INSTALL_ROOT/server/Packages${DOCKER_VOLUME_OPT}")
    else
        echo "[warn]: No packages directory found ($PACKAGES_DIR), not mounting any MapGuide packages"
    fi
fi

echo "Setting up container from image ($DOCKER_IMAGE)"
if [ "${#PACKAGES_MOUNTS[@]}" -gt 0 ]; then
    echo "MapGuide packages in $PACKAGES_DIR will be available at $MG_INSTALL_ROOT/server/Packages inside the container"
fi
echo "To run the installer package from within the container, execute the following inside the container:"
echo "    /tmp/artifacts/$INSTALL_PKG"
echo "NOTE: Depending on the distro, you may need to install some prerequiste packages first"
"$DOCKER_CMD" run -p 8008:8008 $PORT_MAPPINGS "${PACKAGES_MOUNTS[@]}" "${VOLUME_MOUNTS[@]}" -v "$PWD/artifacts/Release:/tmp/artifacts${DOCKER_VOLUME_OPT}" $DOCKER_RUN_EX_ARGS $DOCKER_RUN_AS_ROOT_ARGS -it "$DOCKER_IMAGE" "/bin/bash"