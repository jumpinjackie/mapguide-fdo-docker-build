#!/bin/bash
pushd svnhelper
echo "Building svnhelper image"
podman build -t svnhelper .
popd 