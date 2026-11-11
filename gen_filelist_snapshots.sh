#!/bin/bash

# Regenerate the Linux filelist snapshots in the MapGuide source tree from the MapGuide tarballs
# the docker build produced. This is the scripted form of the "Generating linux filelist
# snapshots" section in mapguide/MgDev/Bindings/src/ApiDump/README.txt.

ROOT=$(realpath "$(dirname "$0")")
ARTIFACTS_BASE=$ROOT/artifacts
API_DUMP_DIR=$ROOT/mapguide/MgDev/Bindings/src/ApiDump
BUILD_CONF=Release
ARTIFACTS_DIR=
OUTPUT_DIR=
VERSION=
UBUNTU_VER=

indent()
{
    sed 's/^/    /'
}

die()
{
    echo "ERROR: $*" >&2
    exit 1
}

usage()
{
    cat <<EOF
Regenerate the ApiDump filelist snapshots from the MapGuide tarballs in artifacts/.

Usage: ./gen_filelist_snapshots.sh [options]

Options:
  --conf <Release|Debug>  Build configuration whose artifacts are used (default: Release)
  --version <ver>         MapGuide version in the tarball names (default: detected from the
                          tarballs present in the artifacts directory)
  --ubuntu <NN>           Ubuntu major version for the ubuntu snapshot (default: detected from
                          the tarballs present in the artifacts directory)
  --artifacts-dir <dir>   Directory holding the tarballs (default: artifacts/<conf>)
  --output-dir <dir>      Directory the snapshots are written to (default:
                          mapguide/MgDev/Bindings/src/ApiDump)
  -h, --help              Show this help

Snapshots written (overwriting the existing ones):
  filelist.linux.generic.txt         <- mapguideopensource-<version>-generic-amd64.tar.gz
  filelist.linux.generic-common.txt  <- mapguideopensource-common-<version>-generic-linux-amd64.tar.gz
  filelist.linux.ubuntu.txt          <- mapguideopensource-<version>-ubuntu<NN>-amd64.tar.gz

The snapshots belong to the MapGuide SVN working copy, so review them with svn diff before
committing them; this script only regenerates the files.

Entries are written in byte order (LC_ALL=C sort), never in the order tar happens to store them:
the archive order is the staging directory's readdir order, so it changes from one build to the
next and would turn a one-line content change into a whole-file diff.
EOF
}

while [ $# -gt 0 ]; do
    case "$1" in
        --conf)
            [ $# -ge 2 ] || die "--conf requires a value"
            BUILD_CONF=$2
            shift 2
            ;;
        --version)
            [ $# -ge 2 ] || die "--version requires a value"
            VERSION=$2
            shift 2
            ;;
        --ubuntu)
            [ $# -ge 2 ] || die "--ubuntu requires a value"
            UBUNTU_VER=$2
            shift 2
            ;;
        --artifacts-dir)
            [ $# -ge 2 ] || die "--artifacts-dir requires a value"
            ARTIFACTS_DIR=$2
            shift 2
            ;;
        --output-dir)
            [ $# -ge 2 ] || die "--output-dir requires a value"
            OUTPUT_DIR=$2
            shift 2
            ;;
        -h|--help)
            usage
            exit 0
            ;;
        *)
            usage >&2
            die "Unknown option: $1"
            ;;
    esac
done

case "$BUILD_CONF" in
    Release|Debug)
        ;;
    *)
        die "--conf must be Release or Debug"
        ;;
esac

if [ -z "$ARTIFACTS_DIR" ]; then
    ARTIFACTS_DIR=$ARTIFACTS_BASE/$BUILD_CONF
fi
[ -d "$ARTIFACTS_DIR" ] || die "Artifacts directory not found: $ARTIFACTS_DIR"

if [ -z "$OUTPUT_DIR" ]; then
    OUTPUT_DIR=$API_DUMP_DIR
fi
[ -d "$OUTPUT_DIR" ] || die "Output directory not found: $OUTPUT_DIR (is the MapGuide source tree checked out? run ./svn_checkout.sh)"
[ -w "$OUTPUT_DIR" ] || die "Output directory is not writable: $OUTPUT_DIR"

available_versions()
{
    for tarball in "$ARTIFACTS_DIR"/mapguideopensource-[0-9]*-generic-amd64.tar.gz; do
        [ -f "$tarball" ] || continue
        ver=${tarball##*/mapguideopensource-}
        echo "${ver%-generic-amd64.tar.gz}"
    done | sort -V -u
}

available=$(available_versions)

if [ -z "$VERSION" ]; then
    version_count=$(printf '%s' "$available" | grep -c .)
    if [ "$version_count" -eq 0 ]; then
        die "No mapguideopensource-<version>-generic-amd64.tar.gz in $ARTIFACTS_DIR; build the tarballs first or pass --version"
    elif [ "$version_count" -gt 1 ]; then
        echo "Multiple MapGuide versions found in $ARTIFACTS_DIR:" >&2
        printf '%s\n' "$available" | indent >&2
        die "Pass --version to choose one"
    fi
    VERSION=$available
fi

if [ ! -f "$ARTIFACTS_DIR/mapguideopensource-$VERSION-generic-amd64.tar.gz" ]; then
    echo "No mapguideopensource-$VERSION-*-amd64.tar.gz in $ARTIFACTS_DIR" >&2
    if [ -n "$available" ]; then
        echo "Versions present:" >&2
        printf '%s\n' "$available" | indent >&2
    fi
    die "Build the tarballs first or pass --version"
fi

if [ -z "$UBUNTU_VER" ]; then
    ubuntu_labels=
    for tarball in "$ARTIFACTS_DIR/mapguideopensource-$VERSION-ubuntu"*-amd64.tar.gz; do
        [ -f "$tarball" ] || continue
        label=${tarball##*/mapguideopensource-$VERSION-}
        label=${label%-amd64.tar.gz}
        ubuntu_labels="$ubuntu_labels$label"$'\n'
    done
    label_count=$(printf '%s' "$ubuntu_labels" | grep -c .)
    if [ "$label_count" -eq 0 ]; then
        die "No mapguideopensource-$VERSION-ubuntu<NN>-amd64.tar.gz in $ARTIFACTS_DIR; pass --ubuntu <NN>"
    fi
    # The snapshot records the baseline distro, so take the newest Ubuntu tarball if several exist
    UBUNTU_LABEL=$(printf '%s' "$ubuntu_labels" | sort -V -u | tail -1)
else
    case "$UBUNTU_VER" in
        ubuntu*)
            UBUNTU_LABEL=$UBUNTU_VER
            ;;
        *)
            UBUNTU_LABEL=ubuntu$UBUNTU_VER
            ;;
    esac
fi

generate_snapshot()
{
    tarball=$1
    snapshot=$2

    if [ ! -f "$tarball" ]; then
        die "Missing tarball: $tarball"
    fi
    # Stage the listing beside the snapshot so a tar failure cannot truncate the recorded one.
    # The listing is sorted because tar's order is the staging directory's readdir order, which
    # differs between builds of identical content.
    tmp=$OUTPUT_DIR/.$snapshot.tmp.$$
    if ! ( set -o pipefail; tar -tzf "$tarball" | LC_ALL=C sort > "$tmp" ); then
        rm -f "$tmp"
        die "Could not list the contents of $tarball"
    fi
    mv "$tmp" "$OUTPUT_DIR/$snapshot"
    printf "%-34s <- %s (%s entries)\n" "$snapshot" "$(basename "$tarball")" "$(wc -l < "$OUTPUT_DIR/$snapshot")"
}

echo "Artifacts directory: $ARTIFACTS_DIR"
echo "MapGuide version: $VERSION"
echo "Writing snapshots to: $OUTPUT_DIR"
generate_snapshot "$ARTIFACTS_DIR/mapguideopensource-$VERSION-generic-amd64.tar.gz" filelist.linux.generic.txt
generate_snapshot "$ARTIFACTS_DIR/mapguideopensource-common-$VERSION-generic-linux-amd64.tar.gz" filelist.linux.generic-common.txt
generate_snapshot "$ARTIFACTS_DIR/mapguideopensource-$VERSION-$UBUNTU_LABEL-amd64.tar.gz" filelist.linux.ubuntu.txt

echo
echo "Review the snapshot changes in the MapGuide working copy before committing them:"
echo "    (cd ${API_DUMP_DIR#$ROOT/} && svn diff filelist.linux.generic.txt filelist.linux.generic-common.txt filelist.linux.ubuntu.txt)"
