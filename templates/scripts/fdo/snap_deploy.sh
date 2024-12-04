#!/usr/bin/env bash
ORIG=$(pwd)                                                                                                       
DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"                                                           

indent(){
    sed 's/^/    /'
}

echo "Taking 'build' snapshot (required for 'deploy')"
"$DIR/../build/snap.sh" | indent

. $DIR/../../../../../docker_or_podman.sh

printf "\nExtracting binaries from hellobuild\n"
# start a container on the build image
build_container="$($DOCKER run -d hellobuild:latest /bin/bash)"

# copy the binary from the container
$DOCKER cp "$build_container:/usr/local/src/hello/build/hello.deb" "$DIR/"

# clean up the container
$DOCKER rm "$build_container" 1> /dev/null

printf "\n"

cd "$DIR"
$DOCKER build . -t "hello" && printf "Done building 'build'\n\n"

# clean up binary
rm "$DIR/hello.deb"

echo "Things to try:"
echo "docker run --rm -it --entrypoint=/bin/bash hello"
echo "docker run --rm hello --whale --message \"Containers are cool\""

cd "$ORIG"
