#!/bin/bash

# Run the MapGuide server unit suites (mgserver test <component>) out of a CMake build tree.
#
# A suite is judged by the assertion summary it prints, not by the process exit code: a Debug
# (ASan/LSan) build exits non-zero to report leaks after every test has passed, and a passing
# run can also die or wedge in exit-time teardown (see docs/fdo-exit-teardown.md).
#
# The component names are the ones `mgserver test list` reports.

COMPONENTS_ALL="CoordinateSystem DrawingService FeatureService Geometry KmlService LogManager MappingService MdfModel Misc Performance RenderingService RasterStylization ResourceService ServerAdminService ServerManager ServiceManager SiteManager SiteService Stylization TileService ProfilingService TransformMesh"

SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd)
TEST_LOG_PATH=$(pwd)
MG_BUILD_DIR=
COMPONENTS=
SUITE_TIMEOUT=5m
LIST_COMPONENTS=0
FAILED_SUITES=0
FAILED_COMPONENTS=
RUN_SUITES=0
TOTAL_START=$SECONDS

usage()
{
    echo "Usage: $0 (options)"
    echo "Options:"
    echo "  --mapguide-build-dir [MapGuide CMake build dir]"
    echo "  --log-path [Unit test log path]"
    echo "  --component [Component to run, repeatable, default: every component]"
    echo "  --timeout [Per-suite timeout, default: $SUITE_TIMEOUT, or 'none' to disable]"
    echo "  --list-components [List the component names and exit]"
    echo "  --help [Display usage]"
}

is_known_component()
{
    case " $COMPONENTS_ALL " in
        *" $1 "*) return 0 ;;
    esac
    return 1
}

# Pass/fail is decided from the Catch2 summary, never from the exit code. LeakSanitizer makes
# a clean Debug run exit non-zero, and a run that passed can still die or wedge in exit-time
# teardown. A suite whose cases assert nothing (ProfilingService) prints no "All tests passed"
# line at all - Catch2 reports "test cases: 2 | 2 passed" and "assertions: - none -" instead.
suite_passed()
{
    if grep -q 'All tests passed' "$1"; then
        return 0
    fi
    if grep -qE '^test cases:' "$1" && ! grep -qE '^test cases:.*failed' "$1"; then
        return 0
    fi
    return 1
}

add_component()
{
    if ! is_known_component "$1"; then
        echo "FATAL: unknown component '$1'"
        echo "Valid components: $COMPONENTS_ALL"
        exit 1
    fi
    if [ -z "$COMPONENTS" ]; then
        COMPONENTS="$1"
    else
        COMPONENTS="$COMPONENTS $1"
    fi
}

while [ $# -gt 0 ]; do    # Until you run out of parameters...
    case "$1" in
        --mapguide-build-dir)
            MG_BUILD_DIR="$2"
            shift
            ;;
        --log-path)
            TEST_LOG_PATH="$2"
            shift
            ;;
        --component)
            add_component "$2"
            shift
            ;;
        --timeout)
            SUITE_TIMEOUT="$2"
            shift
            ;;
        --list-components)
            LIST_COMPONENTS=1
            ;;
        --help)
            usage
            exit
            ;;
        *)
            echo "Unknown option: $1"
            usage
            exit 1
            ;;
    esac
    shift   # Check next set of parameters.
done

if [ "$LIST_COMPONENTS" -eq 1 ]; then
    for comp in $COMPONENTS_ALL; do
        echo "$comp"
    done
    exit
fi

if [ -z "$COMPONENTS" ]; then
    COMPONENTS="$COMPONENTS_ALL"
fi

if [ -z "$MG_BUILD_DIR" ]; then
    echo "FATAL: --mapguide-build-dir is required"
    usage
    exit 1
fi
if [ ! -f "$MG_BUILD_DIR/CMakeCache.txt" ]; then
    echo "FATAL: $MG_BUILD_DIR is not a configured MapGuide build tree"
    exit 1
fi

# The suite loads libMgUnitTesting.so with dlopen() of a bare file name, and the FDO providers
# are recorded in providers.xml by bare file name too. mgserver's DT_RUNPATH is not used for
# either, so both directories have to be on LD_LIBRARY_PATH.
FDO_LIB_DIR=$(sed -n 's/^FDO_LIBRARY_DIR:PATH=//p' "$MG_BUILD_DIR/CMakeCache.txt")
if [ -z "$FDO_LIB_DIR" ]; then
    echo "FATAL: $MG_BUILD_DIR/CMakeCache.txt records no FDO_LIBRARY_DIR"
    exit 1
fi
FDO_ROOT=$(dirname "$FDO_LIB_DIR")

# The FDO install lives in the container, so a container that has not run a build yet does not
# have it. build_mapguide_incremental.sh --prepare installs it, stamped against the SDK tarball
# so a rebuilt SDK is picked up automatically.
if [ ! -f "$FDO_ROOT/lib64/libFDO.so" ]; then
    echo "FDO SDK is not installed in this container ($FDO_ROOT); preparing it"
    "$SCRIPT_DIR/build_mapguide_incremental.sh" --build-dir "$MG_BUILD_DIR" --prepare
    if [ "$?" -ne 0 ]; then
        echo "FATAL: could not install the FDO SDK"
        exit 1
    fi
fi

LD_LIBRARY_PATH="$MG_BUILD_DIR/Server/src/Core:$MG_BUILD_DIR/Server/src/UnitTesting:$FDO_ROOT/lib64${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}"
export LD_LIBRARY_PATH

echo "MapGuide build dir: $MG_BUILD_DIR"
echo "Log path is: $TEST_LOG_PATH"
echo "LD_LIBRARY_PATH: $LD_LIBRARY_PATH"
echo "Timeout per suite: $SUITE_TIMEOUT"
echo "Components: $COMPONENTS"
if [ ! -d "$TEST_LOG_PATH" ]; then
    mkdir -p "$TEST_LOG_PATH"
fi

cd "$MG_BUILD_DIR/Server/src/Core" || exit 1
if [ ! -x ./mgserver ]; then
    echo "FATAL: $MG_BUILD_DIR/Server/src/Core/mgserver is missing"
    echo "Build it with /tmp/work/scripts/build_mapguide_incremental.sh"
    exit 1
fi
if [ ! -f "$MG_BUILD_DIR/Server/src/UnitTesting/libMgUnitTesting.so" ]; then
    echo "FATAL: libMgUnitTesting.so is missing from the build tree"
    echo "Build it with /tmp/work/scripts/build_mapguide_incremental.sh --target MgUnitTesting"
    exit 1
fi

echo "Starting unit tests"

for comp in $COMPONENTS
do
    TEST_LOG="$TEST_LOG_PATH/mapguide_${comp}_unit_test.log"
    RESULT_XML="UnitTestResults_${comp}.xml"
    echo "Running suite: $comp"
    start=$SECONDS
    if [ "$SUITE_TIMEOUT" = "none" ]; then
        ./mgserver test "$comp" "$RESULT_XML" > "$TEST_LOG" 2>&1
        rc=$?
    else
        timeout "$SUITE_TIMEOUT" ./mgserver test "$comp" "$RESULT_XML" > "$TEST_LOG" 2>&1
        rc=$?
    fi
    elapsed=$((SECONDS - start))
    RUN_SUITES=$((RUN_SUITES + 1))

    leak_summary=$(grep -E '^SUMMARY: AddressSanitizer:' "$TEST_LOG" | tail -1)
    if suite_passed "$TEST_LOG"; then
        echo "  >> Test Suite ($comp) passed! (elapsed ${elapsed}s)"
        if [ -n "$leak_summary" ]; then
            echo "  >>   LeakSanitizer reported leaks: ${leak_summary#SUMMARY: AddressSanitizer: } - see $TEST_LOG"
        fi
        if [ "$rc" -eq 124 ]; then
            echo "  >>   (passed, then hung in exit-time teardown - see docs/fdo-exit-teardown.md)"
        elif [ "$rc" -ne 0 ] && [ -z "$leak_summary" ]; then
            echo "  >>   (passed, then exited $rc in exit-time teardown - see docs/fdo-exit-teardown.md)"
        fi
    else
        echo "  >> Test Suite ($comp) FAILED (exit $rc, elapsed ${elapsed}s)"
        if [ "$rc" -eq 124 ]; then
            echo "  >>   timed out after $SUITE_TIMEOUT without reaching an assertion summary"
        fi
        grep -E '^(test cases|assertions):' "$TEST_LOG" | tail -2 | while read -r line; do
            echo "  >>   $line"
        done
        echo "  >>   see $TEST_LOG"
        FAILED_SUITES=$((FAILED_SUITES + 1))
        FAILED_COMPONENTS="$FAILED_COMPONENTS $comp"
    fi

    if [ -f "$RESULT_XML" ]; then
        mv "$RESULT_XML" "$TEST_LOG_PATH/$RESULT_XML"
    fi
done

echo "Suites run: $RUN_SUITES, failed: $FAILED_SUITES (total $((SECONDS - TOTAL_START))s)"
if [ "$FAILED_SUITES" -ne 0 ]; then
    echo "Failed suites:$FAILED_COMPONENTS"
    exit 1
fi
