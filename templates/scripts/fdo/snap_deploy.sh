#!/usr/bin/env bash
ORIG=$(pwd)                                                                                                       
DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"                                                           
ROOT="$(realpath $DIR/../../../../..)"

# Determine container command (podman preferred)
. "$ROOT"/container_engine.sh

indent(){
    sed 's/^/    /'
}

echo "Taking 'build' snapshot (required for 'deploy')"
"$DIR/../build/snap.sh" | indent

printf "\nExtracting binaries from hellobuild\n"
# start a container on the build image
build_container="$($DOCKER_CMD run -d hellobuild:latest /bin/bash)"

# copy the binary from the container
"$DOCKER_CMD" cp "$build_container:/usr/local/src/hello/build/hello.deb" "$DIR/"

# clean up the container
"$DOCKER_CMD" rm "$build_container" 1> /dev/null

printf "\n"

cd "$DIR"
"$DOCKER_CMD" build . -t "hello" && printf "Done building 'build'\n\n"

# clean up binary
rm "$DIR/hello.deb"

echo "Things to try:"
echo "$DOCKER_CMD run --rm -it --entrypoint=/bin/bash hello"
echo "$DOCKER_CMD run --rm hello --whale --message \"Containers are cool\""

cd "$ORIG"
