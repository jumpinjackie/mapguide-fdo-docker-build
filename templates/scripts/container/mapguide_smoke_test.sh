#!/bin/sh

PACKAGE=
DISTRO=

while [ $# -gt 0 ]; do    # Until you run out of parameters...
    case "$1" in
        --package)
            PACKAGE="$2"
            shift
            ;;
        --distro)
            DISTRO="$2"
            shift
            ;;
        --help)
            echo "Usage: $0 (options)"
            echo "Options:"
            echo "  --package [Installer package name]"
            echo "  --distro [Installer package name]"
            echo "  --help [Display usage]"
            exit
            ;;
    esac
    shift   # Check next set of parameters.
done

install_prereqs()
{
    case "$DISTRO" in
        ubuntu)
            echo "No prereqs required to be installed"
            ;;
        debian)
            apt-get update && apt-get install -y procps
            ;;
        fedora)
            yum install -y initscripts redhat-lsb libnsl procps libxcrypt-compat
            ;;
        opensuse/leap)
            zypper install -y gzip tar libnsl1
            groupadd daemon
            useradd -g daemon daemon
            # This is needed to avoid httpd complaining about not being able to find a transcoding service
            export LANG=en_US.UTF-8
            ;;
        archlinux)
            pacman -Sy libxcrypt-compat
            ;;
        oraclelinux)
            microdnf install -y gzip procps libxcrypt-compat
            ;;
        *)
            echo "FATAL: I don't know what your distro is"
            exit 1
            ;;
    esac
}

#install_nodejs()
#{
#    curl -o- https://raw.githubusercontent.com/nvm-sh/nvm/v0.40.1/install.sh | bash
#    . ~/.bashrc
#    nvm install 22
#    nvm use 22
#}

# Pre-flight checks
install_prereqs
#if ! command -v npx 2>&1 >/dev/null
#then
#    echo "INFO: npx could not be found. Performing node.js install"
#    install_nodejs
#fi
#
#if ! command -v npx 2>&1 >/dev/null
#then
#    echo "FATAL: npx could not be found. Ensure node.js is installed"
#    exit 1
#fi

# Run installer package
cp /artifacts/"$PACKAGE" /tmp/installer.run
/tmp/installer.run -- --no-mgserver-start --headless --with-sdf --with-shp --with-sqlite --with-gdal --with-ogr --with-wfs --with-wms
cd /usr/local/mapguideopensource-4.0.0/server/bin || exit
./mgserver.sh
