#!/usr/bin/env bash
DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"                                                           
ROOT="$(realpath $DIR/../../../../..)"
PROJ="$ROOT/mapguide/"
CPU=`basename $(dirname $(dirname $(dirname $DIR)))`
COMPONENT=`basename $(dirname $(dirname $DIR))`
DISTRO=`basename $(dirname $DIR)`
THIS_DIR=`basename $DIR`
CONTAINER_NAME="${COMPONENT}_${DISTRO}_${THIS_DIR}_${CPU}"

indent(){
    sed 's/^/    /'
}

echo "Taking a 'run' snapshot first (required for '$CONTAINER_NAME')"
"$DIR/../run/snap.sh" | indent

echo "Taking snapshot: '$CONTAINER_NAME'"

# If this is a build server, you might do something like this here:
##build the latest version, not the current version
# cd $PROJ
# git clean -df
# git reset --hard
# git pull origin master

# copy the dockerfile to the project root so it can be a parent of the source
# (necessary because docker hashes children to see if rebuilding a layer is needed)
cp -p "$DIR/Dockerfile" "$ROOT"

cd "$ROOT"
docker build . -t "$CONTAINER_NAME:latest"

rm "$ROOT/Dockerfile"

echo "To explore '$CONTAINER_NAME' run:"
echo "docker run --rm -it $CONTAINER_NAME /bin/bash"
echo
