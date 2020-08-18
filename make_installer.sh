#!/bin/sh
DISTRO_NOVER=$1
DISTRO_VER=$2
#DISTRO_NOVER=centos
#DISTRO_VER=7
DISTRO=${DISTRO_NOVER}${DISTRO_VER}
INSTALLER_LABEL="MapGuide Open Source 4.0 Preview 2"
. ./fdo_version.sh
. ./mapguide_version.sh
echo "Prepare installer staging area"
mkdir -p staging/fdo-${FDO_VER_TRIPLE}
mkdir -p staging/mapguideopensource-${MG_VER_TRIPLE}
echo "Extract tarball contents to staging area"
tar -zxf artifacts/fdosdk-${FDO_VER}-${DISTRO}-amd64.tar.gz -C staging/fdo-${FDO_VER_TRIPLE}
tar -zxf artifacts/mapguideopensource-${MG_VER}-${DISTRO}-amd64.tar.gz -C staging/mapguideopensource-${MG_VER_TRIPLE}
cp templates/distros/${DISTRO_NOVER}/install.sh staging/
chmod +x staging/install.sh
echo "Create self-extracting archive"
~/makeself/makeself.sh --xz --quiet --needroot --sha256 staging/ mapguideopensource-${MG_VER}-${DISTRO}-install.run "${INSTALLER_LABEL}" ./install.sh
rm -rf staging/
mv *.run artifacts/