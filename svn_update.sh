#!/bin/sh

. ./docker_or_podman.sh

HAVE_SVN=0
HAVE_SVNHELPER=0
which svn
if [ $? -eq 1 ]; then
    echo "svn client not found. Check if we have the svnhelper image"
    $DOCKER images | grep svnhelper
    if [ $? -eq 1 ]; then
        echo "FATAL: svnhelper image was not found. Build this image with build_svnhelper.sh"
        exit 1
    else
        HAVE_SVNHELPER=1
    fi
else
    HAVE_SVN=1
    echo "svn client found. Will use directly"
fi

if [ "$HAVE_SVN" = "0" ] && [ "$HAVE_SVNHELPER" = "0" ]; then
    echo "FATAL: Could not find the svn client or the svnhelper image"
    exit 1
fi

if [ "$HAVE_SVN" = "1" ];
then
    svn update fdo
    svn update mapguide/MgDev
fi
if [ "$HAVE_SVNHELPER" = "1" ];
then
    $DOCKER run -v $PWD/fdo:/tmp/src/fdo svnhelper svn update /tmp/src/fdo
    $DOCKER run -v $PWD/mapguide/MgDev:/tmp/src/mapguide svnhelper svn update /tmp/src/mapguide
fi