#!/bin/bash

FDO_VER=4.2.0
FDO_REV=0
MG_VER=4.0.0
MG_REV=0

indent(){
    sed 's/^/    /'
}

write_fdo_run()
{
    path=$1
    distro=$2
    tag=$3

    prepare_cmd=$(cat "templates/distros/$distro/cmd_prepare_run.txt")

    cat > $path/Dockerfile <<EOF
# This dockerfile defines the expected runtime environment before the project is installed
FROM ${distro}:${tag}

# Be sure to install any runtime dependencies
RUN ${prepare_cmd}
EOF

    echo "Wrote: $path/Dockerfile" | indent
}

write_fdo_develop()
{
    path=$1
    distro_label=$2
    cpu=$3
    distro=$4

    if [ -f "templates/distros/$distro/cmd_prepare_fdo_develop_${distro_label}.txt" ]; then
        echo ">>> Using ${distro_label} args override for prepare_fdo_develop" | indent
        prepare_cmd=$(cat "templates/distros/$distro/cmd_prepare_fdo_develop_${distro_label}.txt")
    else
        prepare_cmd=$(cat "templates/distros/$distro/cmd_prepare_fdo_develop.txt")
    fi

    cat > $path/Dockerfile <<EOF
# This dockerfile makes a snapshot of the development environment
FROM fdo_${distro_label}_run_${cpu}

# Install build dependencies
RUN ${prepare_cmd}

# include the code
COPY fdo/ /usr/local/src/fdo

# include our last collected cache
COPY caches/${cpu}/fdo/${distro_label}/.ccache /root/.ccache

# remove intermediate files (to ensure a clean build later)
RUN rm -rf /usr/local/src/fdo/build

# since fdo is a submodule on the local machine
# git relocated .git/ to the parent repo, un-submodule it in the image
RUN rm /usr/local/src/fdo/.git
COPY .git/modules/fdo /usr/local/src/fdo/.git/
EOF

    echo "Wrote: $path/Dockerfile" | indent
}

write_fdo_develop_thin()
{
    path=$1
    distro_label=$2
    cpu=$3
    distro=$4

    if [ -f "templates/distros/$distro/cmd_prepare_fdo_develop_${distro_label}.txt" ]; then
        echo ">>> Using ${distro_label} args override for prepare_fdo_develop" | indent
        prepare_cmd=$(cat "templates/distros/$distro/cmd_prepare_fdo_develop_${distro_label}.txt")
    else
        prepare_cmd=$(cat "templates/distros/$distro/cmd_prepare_fdo_develop.txt")
    fi

    cat > $path/Dockerfile <<EOF
# This dockerfile makes a snapshot of the development environment
FROM fdo_${distro_label}_run_${cpu}

# Install build dependencies
RUN ${prepare_cmd}
EOF

    echo "Wrote: $path/Dockerfile" | indent
}

write_fdo_build()
{
    path=$1
    distro_label=$2
    cpu=$3
    distro=$4

    build_bits=
    case "$cpu" in
        x86)
            build_bits=32
            ;;
        x64)
            build_bits=64
            ;;
        *)
            echo "Unknown CPU" | indent
            exit 1
            ;;
    esac

    # Sometimes a given distro just may not be able to fit in the normal dockerfile template
    # we have, so such distros have the opportunity to completely override the dockerfile body
    # if the provide a file with the right name
    if [ -f "templates/distros/$distro/dockerfile_${cpu}_fdo_build_${distro_label}.txt" ]; then
        echo ">>> Using custom dockerfile content for ${distro_label} FDO build" | indent
        dockerfile_body=$(cat "templates/distros/$distro/dockerfile_${cpu}_fdo_build_${distro_label}.txt")
        cat > $path/Dockerfile <<EOF
# This dockerfile executes the build, it starts from the dev environment
FROM fdo_${distro_label}_develop_${cpu}

${dockerfile_body}
EOF
    else
        if [ -f "templates/distros/$distro/args_fdo_thirdparty_build_${distro_label}.txt" ]; then
            echo ">>> Using ${distro_label} args override for fdo_thirdparty_build" | indent
            fdo_thirdparty_args=$(cat "templates/distros/$distro/args_fdo_thirdparty_build_${distro_label}.txt")
        else
            fdo_thirdparty_args=$(cat "templates/distros/$distro/args_fdo_thirdparty_build.txt")
        fi
        if [ -f "templates/distros/$distro/args_fdo_build_${distro_label}.txt" ]; then
            echo ">>> Using ${distro_label} args override for fdo_build" | indent
            fdo_args=$(cat "templates/distros/$distro/args_fdo_build_${distro_label}.txt")
        else
            fdo_args=$(cat "templates/distros/$distro/args_fdo_build.txt")
        fi

        cat > $path/Dockerfile <<EOF
# This dockerfile executes the build, it starts from the dev environment
FROM fdo_${distro_label}_develop_${cpu}

# These are the build steps
RUN BUILD_DIR=/usr/local/src/fdo/build \\
&& THIRDPARTY_DIR=/usr/local/src/fdo/thirdparty_build \\
&& ccache -s \\
&& mkdir -p \$BUILD_DIR/artifacts \\
&& cd /usr/local/src/fdo \\
&& ./cmake_bootstrap.sh --working-dir \$THIRDPARTY_DIR --build ${build_bits} ${fdo_thirdparty_args} \\
&& ./cmake_build.sh --thirdparty-working-dir \$THIRDPARTY_DIR --cmake-build-dir \$BUILD_DIR ${fdo_args} \\
&& ccache -s \
&& cd \$BUILD_DIR \\
&& cmake --build . --target package \\
&& mv fdosdk*.tar.gz \$BUILD_DIR/artifacts
EOF
    fi

    echo "Wrote: $path/Dockerfile" | indent
}

build_fdo_env()
{
    distro=$1
    cpu=$2
    tag=$3

    if [ ! -d "templates/distros/$distro" ]; then
        echo "No template confiugrations found for $distro"
        exit 1
    fi

    echo "Setting FDO environment for"
    echo "Distro: $distro" | indent
    echo "CPU: $cpu" | indent
    echo "Docker base image tag: $tag" | indent

    ver_major=$(echo $tag | cut -d. -f1)
    distro_label="${distro}${ver_major}"

    echo "Distro label will be: $distro_label" | indent

    path_base="docker/${cpu}/fdo/${distro_label}"
    echo "Base path for environment is: $path_base" | indent

    mkdir -p "caches/${cpu}/fdo/${distro_label}/.ccache"

    current_path="${path_base}/run"
    mkdir -p $current_path
    write_fdo_run $current_path $distro $tag $distro_label
    cp -f templates/scripts/fdo/snap_run.sh $current_path/snap.sh

    current_path="${path_base}/develop"
    mkdir -p $current_path
    write_fdo_develop $current_path $distro_label $cpu $distro
    cp -f templates/scripts/fdo/snap_develop.sh $current_path/snap.sh

    current_path="${path_base}/develop_thin"
    mkdir -p $current_path
    write_fdo_develop_thin $current_path $distro_label $cpu $distro
    cp -f templates/scripts/fdo/snap_develop_thin.sh $current_path/snap.sh

    current_path="${path_base}/build"
    mkdir -p $current_path
    write_fdo_build $current_path $distro_label $cpu $distro
    cp -f templates/scripts/fdo/snap_build.sh $current_path/snap.sh

cat > fdo_version.sh <<EOF
#!/bin/sh
export FDO_VER_TRIPLE=${FDO_VER}
export FDO_VER=${FDO_VER}.${FDO_REV}
EOF
    echo "Wrote: fdo_version.sh" | indent
    chmod +x fdo_version.sh
}

write_mapguide_run()
{
    path=$1
    distro=$2
    tag=$3

    prepare_cmd=$(cat "templates/distros/$distro/cmd_prepare_run.txt")

    cat > $path/Dockerfile <<EOF
# This dockerfile defines the expected runtime environment before the project is installed
FROM ${distro}:${tag}

# Be sure to install any runtime dependencies
RUN ${prepare_cmd}
EOF

    echo "Wrote: $path/Dockerfile" | indent
}

write_mapguide_develop()
{
    path=$1
    distro_label=$2
    cpu=$3
    distro=$4

    if [ -f "templates/distros/$distro/cmd_prepare_mapguide_develop_${distro_label}.txt" ]; then
        echo ">>> Using ${distro_label} args override for prepare_mapguide_develop" | indent
        prepare_cmd=$(cat "templates/distros/$distro/cmd_prepare_mapguide_develop_${distro_label}.txt")
    else
        prepare_cmd=$(cat "templates/distros/$distro/cmd_prepare_mapguide_develop.txt")
    fi

    cat > $path/Dockerfile <<EOF
# This dockerfile makes a snapshot of the development environment
FROM mapguide_${distro_label}_run_${cpu}

# Install build dependencies
RUN ${prepare_cmd}

# include the code
COPY mapguide/ /usr/local/src/mapguide

# include our last collected cache
COPY caches/${cpu}/mapguide/${distro_label}/.ccache /root/.ccache

# remove intermediate files (to ensure a clean build later)
RUN rm -rf /usr/local/src/mapguide/build

# since mapguide is a submodule on the local machine
# git relocated .git/ to the parent repo, un-submodule it in the image
RUN rm /usr/local/src/mapguide/.git
COPY .git/modules/mapguide /usr/local/src/mapguide/.git/
EOF

    echo "Wrote: $path/Dockerfile" | indent
}

write_mapguide_develop_thin()
{
    path=$1
    distro_label=$2
    cpu=$3
    distro=$4

    if [ -f "templates/distros/$distro/cmd_prepare_mapguide_develop_${distro_label}.txt" ]; then
        echo ">>> Using ${distro_label} args override for prepare_mapguide_develop" | indent
        prepare_cmd=$(cat "templates/distros/$distro/cmd_prepare_mapguide_develop_${distro_label}.txt")
    else
        prepare_cmd=$(cat "templates/distros/$distro/cmd_prepare_mapguide_develop.txt")
    fi

    cat > $path/Dockerfile <<EOF
# This dockerfile makes a snapshot of the development environment
FROM mapguide_${distro_label}_run_${cpu}

# Install build dependencies
RUN ${prepare_cmd}
EOF

    echo "Wrote: $path/Dockerfile" | indent
}

write_mapguide_build()
{
    path=$1
    distro_label=$2
    cpu=$3
    distro=$4

    if [ -f "templates/distros/$distro/args_mapguide_oem_build_${distro_label}.txt" ]; then
        echo ">>> Using ${distro_label} args override for mapguide_oem_build" | indent
        oem_build_args=$(cat "templates/distros/$distro/args_mapguide_oem_build_${distro_label}.txt")
    else
        oem_build_args=$(cat "templates/distros/$distro/args_mapguide_oem_build.txt")
    fi

    cpu_label=
    case "$cpu" in
        x86)
            cpu_label=i386
            ;;
        x64)
            cpu_label=amd64
            ;;
        *)
            echo "Unknown CPU" | indent
            exit 1
            ;;
    esac

    # Sometimes a given distro just may not be able to fit in the normal dockerfile template
    # we have, so such distros have the opportunity to completely override the dockerfile body
    # if the provide a file with the right name
    if [ -f "templates/distros/$distro/dockerfile_${cpu}_mapguide_build_${distro_label}.txt" ]; then
        echo ">>> Using custom dockerfile content for ${distro_label} MapGuide build" | indent
        dockerfile_body=$(cat "templates/distros/$distro/dockerfile_${cpu}_mapguide_build_${distro_label}.txt")
        cat > $path/Dockerfile <<EOF
# This dockerfile executes the build, it starts from the dev environment
FROM mapguide_${distro_label}_develop_${cpu}

${dockerfile_body}
EOF
    else
        cat > $path/Dockerfile <<EOF
# This dockerfile executes the build, it starts from the dev environment
FROM mapguide_${distro_label}_develop_${cpu}

# These are the build steps

# 1. Internal thirdparty
RUN BUILD_DIR=/usr/local/src/mapguide/build \\
&& OEM_BUILD_DIR=/usr/local/src/mapguide/build_oem \\
&& LINUXAPT_BUILD=/usr/local/src/mapguide/build_linuxapt \\
&& ccache -s \\
&& mkdir -p \$OEM_BUILD_DIR \\
&& mkdir -p \$BUILD_DIR \\
&& cd /usr/local/src/mapguide/MgDev \\
&& ./cmake_bootstrap.sh --oem-working-dir \$OEM_BUILD_DIR --build 64 ${oem_build_args} \\
&& ./cmake_linuxapt.sh --prefix /usr/local/mapguideopensource-${MG_VER} --oem-working-dir \$OEM_BUILD_DIR --working-dir \$LINUXAPT_BUILD \\
&& ccache -s

# 2. Add FDO sdk this should've been copied to the same directory by snap.sh
ADD fdosdk.tar.gz /usr/local/fdo-${FDO_VER}

# 3. Add atomic.h (needed to build DWF Toolkit)
ADD atomic.h /usr/include/asm/

# 4. Add binary stripping script
ADD strip_mapguide_binaries.sh /usr/local/src/mapguide/MgDev

# 5. Main build
RUN BUILD_DIR=/usr/local/src/mapguide/build \\
&& OEM_BUILD_DIR=/usr/local/src/mapguide/build_oem \\
&& ccache -s \\
&& cd /usr/local/src/mapguide/MgDev \\
&& ./cmake_build.sh --oem-working-dir \$OEM_BUILD_DIR --cmake-build-dir \$BUILD_DIR --ninja \\
&& ccache -s \\
&& cd \$BUILD_DIR \\
&& cmake --build . --target install

# 6. Tar the installation
RUN BUILD_DIR=/usr/local/src/mapguide/build \\
&& mkdir -p \$BUILD_DIR/artifacts \\
&& /usr/local/src/mapguide/MgDev/strip_mapguide_binaries.sh /usr/local/mapguideopensource-${MG_VER} \\
&& cd /usr/local/mapguideopensource-${MG_VER} \\
&& tar -zcf \$BUILD_DIR/artifacts/mapguideopensource-${MG_VER}.${MG_REV}-${distro_label}-${cpu_label}.tar.gz *
EOF
    fi

    echo "Wrote: $path/Dockerfile" | indent
}

build_mapguide_env()
{
    distro=$1
    cpu=$2
    tag=$3

    if [ ! -d "templates/distros/$distro" ]; then
        echo "No template confiugrations found for $distro"
        exit 1
    fi

    echo "Setting MapGuide environment for"
    echo "Distro: $distro" | indent
    echo "CPU: $cpu" | indent
    echo "Docker base image tag: $tag" | indent

    ver_major=$(echo $tag | cut -d. -f1)
    distro_label="${distro}${ver_major}"

    echo "Distro label will be: $distro_label" | indent

    path_base="docker/${cpu}/mapguide/${distro_label}"
    echo "Base path for environment is: $path_base" | indent

    mkdir -p "caches/${cpu}/mapguide/${distro_label}/.ccache"

    current_path="${path_base}/run"
    mkdir -p $current_path
    write_mapguide_run $current_path $distro $tag $distro_label
    cp -f templates/scripts/mapguide/snap_run.sh $current_path/snap.sh

    current_path="${path_base}/develop"
    mkdir -p $current_path
    write_mapguide_develop $current_path $distro_label $cpu $distro
    cp -f templates/scripts/mapguide/snap_develop.sh $current_path/snap.sh

    current_path="${path_base}/develop_thin"
    mkdir -p $current_path
    write_mapguide_develop_thin $current_path $distro_label $cpu $distro
    cp -f templates/scripts/mapguide/snap_develop_thin.sh $current_path/snap.sh

    current_path="${path_base}/build"
    mkdir -p $current_path
    write_mapguide_build $current_path $distro_label $cpu $distro
    cp -f templates/scripts/mapguide/snap_build.sh $current_path/snap.sh
    cp -f templates/scripts/mapguide/strip_mapguide_binaries.sh $current_path/strip_mapguide_binaries.sh

    cat > mapguide_version.sh <<EOF
#!/bin/sh
export MG_VER_TRIPLE=${MG_VER}
export MG_VER=${MG_VER}.${MG_REV}
EOF
    echo "Wrote: mapguide_version.sh" | indent
    chmod +x mapguide_version.sh
}

TARGET=fdo
DISTRO=ubuntu
CPU=x64
TAG=14.04
while [ $# -gt 0 ]; do    # Until you run out of parameters...
    case "$1" in
        --target)
            TARGET="$2"
            shift
            ;;
        --distro)
            DISTRO="$2"
            shift
            ;;
        --tag)
            TAG="$2"
            shift
            ;;
        --cpu)
            CPU="$2"
            shift
            ;;
        --help)
            echo "Usage: $0 (options)"
            echo "Options:"
            echo "  --target [mapguide|fdo]"
            echo "  --distro [the distro you are targeting, ubuntu|centos]"
            echo "  --tag [the version tag]"
            echo "  --cpu [x86|x64]"
            echo "  --help [Display usage]"
            exit
            ;;
    esac
    shift   # Check next set of parameters.
done

case "$TARGET" in
    fdo)
        build_fdo_env $DISTRO $CPU $TAG
        ;;
    mapguide)
        build_mapguide_env $DISTRO $CPU $TAG
        ;;
    *)
        echo "Unknown target: $TARGET"
        exit 1
        ;;
esac