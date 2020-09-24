#!/bin/sh
./make_installer.sh centos 6 Release
./make_installer.sh centos 7 Release
./make_installer.sh ubuntu 14 Release
./make_installer.sh ubuntu 16 Release
./make_installer.sh centos 6 Debug
./make_installer.sh centos 7 Debug
./make_installer.sh ubuntu 14 Debug
./make_installer.sh ubuntu 16 Debug
