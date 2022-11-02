#!/bin/sh
./make_installer.sh centos 7 Release
./make_installer.sh ubuntu 22 Release
./make_installer.sh centos 7 Debug
./make_installer.sh ubuntu 22 Debug
