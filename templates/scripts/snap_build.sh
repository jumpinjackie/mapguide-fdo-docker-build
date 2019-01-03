#!/usr/bin/env bash
ORIG=$(pwd)                                                                                                       
DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"                                                           
ROOT="$(realpath $DIR/../../../../..)"
PROJ="$ROOT/fdo/"
STAGE="$ROOT/artifacts"

. $ROOT/fdo_version.sh
echo "FDO Version is: $FDO_VER"

CPU=`basename $(dirname $(dirname $(dirname $DIR)))`
COMPONENT=`basename $(dirname $(dirname $DIR))`
DISTRO=`basename $(dirname $DIR)`
THIS_DIR=`basename $DIR`
CONTAINER_NAME="${COMPONENT}_${DISTRO}_${THIS_DIR}_${CPU}"
CCACHE_LOCATION="${ROOT}/caches/${CPU}/${COMPONENT}/${DISTRO}"

indent(){
    sed 's/^/    /'
}

echo "Taking a 'develop' snapshot first (required for '$CONTAINER_NAME')"
"$DIR/../develop/snap.sh" | indent

cd "$DIR"
docker build . -t "$CONTAINER_NAME:latest"
if [ "$?" -ne 0 ] ; then
    exit 1
fi
echo "Copying SDK tarball to artifacts"
docker run --rm -it -v ${ROOT}:/artifacts $CONTAINER_NAME cp -r /usr/local/src/fdo/build/artifacts /artifacts
if [ "$?" -ne 0 ] ; then
    exit 1
fi
echo "Copying ccache output to: ${CCACHE_LOCATION}"
docker run --rm -it -v ${CCACHE_LOCATION}:/tmp/cache $CONTAINER_NAME cp -r /root/.ccache /tmp/cache
if [ "$?" -ne 0 ] ; then
    exit 1
fi

echo "things to try:"
echo "docker run --rm -it $CONTAINER_NAME /bin/bash"
echo "docker run --rm -it $CONTAINER_NAME ls /usr/local/src/fdo/build"
echo

cd "$ORIG"
