#!/bin/sh
./make_installer.sh generic "" Release
./make_installer.sh ubuntu 22 Release
./make_installer.sh generic "" Debug
./make_installer.sh ubuntu 22 Debug
