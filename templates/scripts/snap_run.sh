#!/usr/bin/env bash
DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"
CPU=`basename $(dirname $(dirname $(dirname $DIR)))`
COMPONENT=`basename $(dirname $(dirname $DIR))`
DISTRO=`basename $(dirname $DIR)`
THIS_DIR=`basename $DIR`
CONTAINER_NAME="${COMPONENT}_${DISTRO}_${THIS_DIR}_${CPU}"
echo "Taking snapshot '$CONTAINER_NAME'"

docker build "$DIR" -t "$CONTAINER_NAME:latest"

echo "To explore '$CONTAINER_NAME' use:"
echo "docker run --rm -it $CONTAINER_NAME /bin/bash"
echo
