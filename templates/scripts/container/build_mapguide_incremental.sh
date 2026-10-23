#!/bin/bash

# Incremental MapGuide build for the dev inner loop.
#
# Unlike build_mapguide.sh this does not run cmake_bootstrap.sh/cmake_linuxapt.sh, does not
# build the web tier and does not package anything. It makes sure the FDO SDK that the build
# tree was configured against is installed in this container - that install lives in the
# container, so it has to be repeated for each new one - and then builds only the targets the
# MapGuide server and its unit tests need.
#
# The CMake build tree has to exist already: a full ./build_thin.sh run creates it (and the
# OEM dependency tree it is configured against). After that, ninja re-runs CMake by itself
# whenever a CMakeLists.txt changes, so a source edit only costs the recompile.

BUILD_DIR=/tmp/work/build_area/mapguide
ARTIFACTS_DIR=/tmp/work/artifacts
PATCHES_DIR=/tmp/work/patches
DEFAULT_TARGETS="mgserver MgUnitTesting"
TARGETS=
DO_INSTALL=0
PREPARE_ONLY=0
SKIP_PREPARE=0
FORCE_SDK=0
JOBS=
FDO_SDK=

check_step()
{
    if [ "$?" -ne 0 ]; then
        echo "FATAL: $1 failed"
        exit 1
    fi
}

require_build_tree()
{
    if [ ! -f "$BUILD_DIR/CMakeCache.txt" ]; then
        echo "FATAL: $BUILD_DIR is not a configured MapGuide build tree"
        echo "Run a full build once so the tree and the OEM dependencies it links against exist:"
        echo "    ./build_thin.sh --target mapguide --distro ubuntu --tag 22 --cpu x64"
        exit 1
    fi
}

fdo_root()
{
    # The build tree records exactly which FDO installation it was configured against
    fdo_lib_dir=$(sed -n 's/^FDO_LIBRARY_DIR:PATH=//p' "$BUILD_DIR/CMakeCache.txt")
    if [ -z "$fdo_lib_dir" ]; then
        echo "FATAL: $BUILD_DIR/CMakeCache.txt records no FDO_LIBRARY_DIR"
        exit 1
    fi
    dirname "$fdo_lib_dir"
}

fdo_sdk_tarball()
{
    if [ -n "$FDO_SDK" ]; then
        echo "$FDO_SDK"
        return
    fi
    # build_thin.sh --interactive sets both of these
    if [ -n "$FDOSDK" ] && [ -f "$ARTIFACTS_DIR/$FDOSDK" ]; then
        echo "$ARTIFACTS_DIR/$FDOSDK"
        return
    fi
    if [ -n "$MG_DISTRO" ]; then
        # Never fall back to "any SDK": the tarball for another distro links a different set
        # of thirdparty libraries.
        ls -t "$ARTIFACTS_DIR"/fdosdk-*-"$MG_DISTRO"-*.tar.gz 2>/dev/null | head -1
    fi
}

sdk_stamp()
{
    echo "$(basename "$1") $(stat -c '%s' "$1") $(stat -c '%Y' "$1")"
}

prepare()
{
    require_build_tree
    install_root=$(fdo_root)
    if [ -n "$FDO_SDK" ] && [ ! -f "$FDO_SDK" ]; then
        echo "FATAL: --fdo-sdk $FDO_SDK does not exist"
        exit 1
    fi
    sdk=$(fdo_sdk_tarball)
    if [ -z "$sdk" ] || [ ! -f "$sdk" ]; then
        echo "FATAL: could not work out which FDO SDK tarball to install"
        echo "Pass one explicitly with --fdo-sdk, or run inside the build container"
        echo "(--interactive) where FDOSDK and MG_DISTRO are already set."
        echo "Build FDO first if the tarball does not exist yet:"
        echo "    ./build_thin.sh --target fdo --distro ubuntu --tag 22 --cpu x64"
        exit 1
    fi
    case "$install_root" in
        /usr/local/fdo-*) ;;
        *)
            echo "FATAL: refusing to install the FDO SDK into '$install_root'"
            exit 1
            ;;
    esac
    # Guard against installing the tarball built for a different FDO version than the one
    # the build tree was configured against.
    tree_fdo_ver=${install_root##*/}
    tree_fdo_ver=${tree_fdo_ver#fdo-}
    case "$(basename "$sdk")" in
        fdosdk-"$tree_fdo_ver".*) ;;
        *)
            echo "FATAL: $(basename "$sdk") is not an FDO $tree_fdo_ver SDK"
            echo "The build tree in $BUILD_DIR is configured against $install_root"
            exit 1
            ;;
    esac

    want=$(sdk_stamp "$sdk")
    have=
    if [ -f "$install_root/.fdosdk-stamp" ]; then
        have=$(cat "$install_root/.fdosdk-stamp")
    fi
    if [ "$FORCE_SDK" -eq 0 ] && [ "$want" = "$have" ] && [ -f "$install_root/lib64/libFDO.so" ]; then
        echo "FDO SDK already installed in $install_root ($(basename "$sdk"))"
    else
        echo "Installing FDO SDK into $install_root ($(basename "$sdk"))"
        rm -rf "$install_root"
        mkdir -p "$install_root"
        tar -zxf "$sdk" -C "$install_root"
        check_step "extracting $(basename "$sdk")"
        # Stamped so a later run can tell whether the tarball has been rebuilt since
        echo "$want" > "$install_root/.fdosdk-stamp"
    fi

    echo "Copying atomic.h to /usr/include/asm"
    mkdir -p /usr/include/asm
    # Only touch it when it changed: rewriting it re-stamps the file and rebuilds every
    # translation unit that includes it, which is the opposite of what an inner loop wants.
    if ! cmp -s "$PATCHES_DIR/atomic.h" /usr/include/asm/atomic.h; then
        cp "$PATCHES_DIR/atomic.h" /usr/include/asm/
        check_step "copying atomic.h"
    fi
}

list_targets()
{
    require_build_tree
    if [ -f "$BUILD_DIR/build.ninja" ]; then
        # CMake emits one order-only marker per buildable target; that set is exactly what
        # --target accepts.
        ninja -C "$BUILD_DIR" -t targets all 2>/dev/null \
            | sed -n 's/^cmake_object_order_depends_target_\(.*\): phony$/\1/p' \
            | sort -u
    else
        make -C "$BUILD_DIR" help 2>/dev/null
    fi
}

build()
{
    require_build_tree
    cd "$BUILD_DIR" || exit 1

    echo "Building in $BUILD_DIR: ${TARGETS}"
    start=$SECONDS
    if [ -n "$JOBS" ]; then
        cmake --build . --target $TARGETS --parallel "$JOBS"
    else
        cmake --build . --target $TARGETS
    fi
    check_step "build"
    echo "Build completed in $((SECONDS - start))s"

    if [ "$DO_INSTALL" -eq 1 ]; then
        # Installs whatever is already built, without pulling the web tier back in the way
        # the install target's dependency on "all" would.
        echo "Installing from the current build state"
        cmake --install .
        check_step "install"
    fi
}

while [ $# -gt 0 ]; do    # Until you run out of parameters...
    case "$1" in
        --build-dir)
            BUILD_DIR="$2"
            shift
            ;;
        --target)
            if [ -z "$TARGETS" ]; then
                TARGETS="$2"
            else
                TARGETS="$TARGETS $2"
            fi
            shift
            ;;
        --install)
            DO_INSTALL=1
            ;;
        --prepare)
            PREPARE_ONLY=1
            ;;
        --skip-prepare)
            SKIP_PREPARE=1
            ;;
        --reinstall-fdo)
            FORCE_SDK=1
            ;;
        --fdo-sdk)
            FDO_SDK="$2"
            shift
            ;;
        --jobs)
            JOBS="$2"
            shift
            ;;
        --list-targets)
            list_targets
            exit
            ;;
        --help)
            echo "Usage: $0 [options]"
            echo "Options:"
            echo "  --build-dir [MapGuide CMake build dir, default: $BUILD_DIR]"
            echo "  --target [CMake target to build, repeatable, default: $DEFAULT_TARGETS]"
            echo "  --install [Install the built tree afterwards (cmake --install)]"
            echo "  --prepare [Install the FDO SDK and atomic.h, then stop without building]"
            echo "  --skip-prepare [Do not install the FDO SDK/atomic.h, just build]"
            echo "  --reinstall-fdo [Re-extract the FDO SDK even if it is already installed]"
            echo "  --fdo-sdk [FDO SDK tarball to install, default: the one build_thin.sh picks]"
            echo "  --jobs [Parallel build jobs, default: the generator's own default]"
            echo "  --list-targets [List the CMake targets and exit]"
            echo "  --help [Display usage]"
            exit
            ;;
        *)
            echo "Unknown option: $1"
            exit 1
            ;;
    esac
    shift   # Check next set of parameters.
done

if [ -z "$TARGETS" ]; then
    TARGETS="$DEFAULT_TARGETS"
fi

if [ "$SKIP_PREPARE" -eq 0 ]; then
    prepare
fi

if [ "$PREPARE_ONLY" -eq 1 ]; then
    exit 0
fi

build
