#!/bin/sh
DISTRO_NOVER=$1
DISTRO_VER=$2
BUILD_CONF=$3
DISTRO=${DISTRO_NOVER}${DISTRO_VER}
INSTALLER_LABEL="MapGuide Open Source 4.0 Beta 2"
if [ "$BUILD_CONF" = "Debug" ]; then
    INSTALLER_LABEL="$INSTALLER_LABEL - Debug"
fi
which ~/makeself/makeself.sh
if [ $? -eq 1 ]; then
    echo "Could not find the required makeself.sh"
    abs_location=$(realpath ~)
    clone_location=$(dirname "$abs_location/makeself")
    echo "Make sure that the git repo (https://github.com/megastep/makeself) is cloned into $clone_location"
    exit 1
fi
. ./fdo_version.sh
. ./mapguide_version.sh
echo "Prepare installer staging area (${DISTRO} - ${BUILD_CONF})"
case "$DISTRO" in
    *ubuntu*)
        mkdir -p staging
        echo "Load deb packages into staging area"
        cp artifacts/${BUILD_CONF}/${DISTRO}/*.deb staging
        ;;
    *)
        mkdir -p staging/fdo-${FDO_VER_TRIPLE}
        mkdir -p staging/mapguideopensource-${MG_VER_TRIPLE}
        echo "Extract tarball contents to staging area"
        tar -zxf artifacts/${BUILD_CONF}/fdosdk-${FDO_VER}-${DISTRO}-amd64.tar.gz -C staging/fdo-${FDO_VER_TRIPLE}
        tar -zxf artifacts/${BUILD_CONF}/mapguideopensource-${MG_VER}-${DISTRO}-amd64.tar.gz -C staging/mapguideopensource-${MG_VER_TRIPLE}
        ;;
esac
if [ -f "templates/distros/${DISTRO_NOVER}/install_$DISTRO.sh" ];
then
    echo "Copying distro override install script"
    cp "templates/distros/${DISTRO_NOVER}/install_$DISTRO.sh" staging/install.sh
else
    cp "templates/distros/${DISTRO_NOVER}/install.sh" staging/
fi
chmod +x staging/install.sh
echo "Create self-extracting archive"
~/makeself/makeself.sh --quiet --needroot --nochown --keep-umask --sha256 staging/ mapguideopensource-${MG_VER}-${DISTRO}-install.run "${INSTALLER_LABEL}" ./install.sh
rm -rf staging/
mv *.run artifacts/${BUILD_CONF}/
