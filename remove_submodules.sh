#!/bin/sh
git submodule deinit fdo
git submodule deinit mapguide
rm -rf fdo
rm -rf mapguide
rm -rf .git/modules/fdo
rm -rf .git/modules/mapguide
rm .gitmodules