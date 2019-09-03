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

echo "Generating temporary .dockerignore"
rm -f "$ROOT/.dockerignore"
echo ".git/modules/fdo" >> "$ROOT/.dockerignore"
echo "artifacts" >> "$ROOT/.dockerignore"
echo "caches/x64/fdo" >> "$ROOT/.dockerignore"
# Ignore all non-current-distro MapGuide ccache output
for test_distro in ubuntu18 ubuntu16 ubuntu14 centos7 centos6
do
    if [ "$DISTRO" != "$test_distro" ]; then
        echo "caches/x64/mapguide/$test_distro" >> "$ROOT/.dockerignore"
    fi
done
# In case this is a svn checkout, and not a git clone/submodule
echo ".svn" >> "$ROOT/.dockerignore"
echo "fdo" >> "$ROOT/.dockerignore"
# SDKs are only for FDO, so ignore as well
echo "sdks" >> "$ROOT/.dockerignore"
echo "mapguide/Installer" >> "$ROOT/.dockerignore"
echo "mapguide/Tools" >> "$ROOT/.dockerignore"
echo "logs" >> "$ROOT/.dockerignore"
echo "patches" >> "$ROOT/.dockerignore"
echo "templates" >> "$ROOT/.dockerignore"
echo "Contents are:"
cat "$ROOT/.dockerignore" | indent

cd "$ROOT"
docker build . -t "$CONTAINER_NAME:latest"

rm "$ROOT/Dockerfile"
rm "$ROOT/.dockerignore"

echo "To explore '$CONTAINER_NAME' run:"
echo "docker run --rm -it $CONTAINER_NAME /bin/bash"
echo
