#!/usr/bin/env bash
ORIG=$(pwd)                                                                                                       
DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"                                                           
ROOT="$(realpath $DIR/../../../../..)"

. $ROOT/fdo_version.sh
echo "FDO Version is: $FDO_VER"

CPU=`basename $(dirname $(dirname $(dirname $DIR)))`
COMPONENT=`basename $(dirname $(dirname $DIR))`
DISTRO=`basename $(dirname $DIR)`
THIS_DIR=`basename $DIR`
CONTAINER_NAME="${COMPONENT}_${DISTRO}_${THIS_DIR}_${CPU}"
HOST_LOG_PATH=${ROOT}/logs/$CONTAINER_NAME

SKIP_BASE=0

while [ $# -gt 0 ]; do    # Until you run out of parameters...
    case "$1" in
        --skip-base-image-build)
            SKIP_BASE=1
            ;;
    esac
    shift   # Check next set of parameters.
done

indent(){
    sed 's/^/    /'
}

if [ $SKIP_BASE -eq 0 ];
then
    echo "Taking a 'build' snapshot first (required for '$CONTAINER_NAME')"
    "$DIR/../build/snap.sh" | indent
else
    echo "Skipping building base image (assuming it is already built and present)"
fi

. $DIR/../../../../../docker_or_podman.sh

cd "$DIR"
$DOCKER build . -t "$CONTAINER_NAME:latest"
if [ "$?" -ne 0 ] ; then
    exit 1
fi
echo "Run tests and copy logs"
$DOCKER run --rm -it -v ${HOST_LOG_PATH}:/logs $CONTAINER_NAME cp -r /usr/local/src/fdo/build/logs /logs
if [ "$?" -ne 0 ] ; then
    exit 1
fi

cd "$ORIG"
