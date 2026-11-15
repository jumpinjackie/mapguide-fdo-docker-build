#!/bin/sh
DISTRO_NOVER=$1
DISTRO_VER=$2
BUILD_CONF=$3
DISTRO=${DISTRO_NOVER}${DISTRO_VER}
INSTALLER_LABEL="MapGuide Open Source 4.0.1 Test"
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
# Leftovers from a previous run must not end up in this installer: staging is keyed by distro, and
# an interrupted run leaves another distro's payload (or another version's tree) behind.
rm -rf staging
mkdir -p staging
case "$DISTRO" in
    *ubuntu*)
        echo "Load deb packages into staging area"
        if [ -z "$(ls artifacts/${BUILD_CONF}/${DISTRO}/*.deb 2>/dev/null)" ]; then
            echo "ERROR: no deb packages in artifacts/${BUILD_CONF}/${DISTRO}"
            echo "The ubuntu installer installs both FDO and MapGuide from those packages."
            exit 1
        fi
        cp artifacts/${BUILD_CONF}/${DISTRO}/*.deb staging
        # The ubuntu installer finds MapGuide's packages by component name, so a missing set installs
        # nothing at all for MapGuide and leaves /usr/local/mapguideopensource-<ver> unpopulated.
        for component in coordsys common server webextensions httpd; do
            if [ -z "$(ls staging/mapguideopensource-${component}_*.deb 2>/dev/null)" ]; then
                echo "ERROR: no mapguideopensource-${component} deb package in artifacts/${BUILD_CONF}/${DISTRO}"
                echo "The MapGuide build generates them; see build_mapguide_${DISTRO}.sh"
                rm -rf staging
                exit 1
            fi
        done
        ;;
    *)
        echo "Extract tarball contents to staging area"
        for tarball in \
            "artifacts/${BUILD_CONF}/fdosdk-${FDO_VER}-${DISTRO}-amd64.tar.gz" \
            "artifacts/${BUILD_CONF}/mapguideopensource-${MG_VER}-${DISTRO}-amd64.tar.gz"
        do
            if [ ! -f "$tarball" ]; then
                echo "ERROR: '$tarball' not found"
                rm -rf staging
                exit 1
            fi
        done
        mkdir -p staging/fdo-${FDO_VER_TRIPLE}
        mkdir -p staging/mapguideopensource-${MG_VER_TRIPLE}
        tar -zxf artifacts/${BUILD_CONF}/fdosdk-${FDO_VER}-${DISTRO}-amd64.tar.gz -C staging/fdo-${FDO_VER_TRIPLE}
        tar -zxf artifacts/${BUILD_CONF}/mapguideopensource-${MG_VER}-${DISTRO}-amd64.tar.gz -C staging/mapguideopensource-${MG_VER_TRIPLE}
        # Both trees are copied wholesale into their install prefixes, so a tarball that is missing
        # either one produces an installer that fails at post_install with no servers installed.
        if [ ! -f "staging/mapguideopensource-${MG_VER_TRIPLE}/server/bin/serverconfig.ini" ]; then
            echo "ERROR: mapguideopensource-${MG_VER}-${DISTRO}-amd64.tar.gz has no server/bin/serverconfig.ini"
            rm -rf staging
            exit 1
        fi
        if [ ! -d "staging/fdo-${FDO_VER_TRIPLE}/lib64" ]; then
            echo "ERROR: fdosdk-${FDO_VER}-${DISTRO}-amd64.tar.gz has no lib64"
            rm -rf staging
            exit 1
        fi
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
