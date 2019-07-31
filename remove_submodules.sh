#!/bin/sh
if [ -d fdo ];
then
    echo "De-init and remove FDO"
    git submodule deinit -f fdo
    rm -rf fdo
fi
if [ -d mapguide ];
then
    echo "De-init and remove MapGuide"
    git submodule deinit -f mapguide
    rm -rf mapguide
fi
if [ -d .git/modules/fdo ];
then
    rm -rf .git/modules/fdo
fi
if [ -d .git/modules/mapguide ];
then
    rm -rf .git/modules/mapguide
fi
if [ -f .gitmodules ];
then
    rm .gitmodules
fi