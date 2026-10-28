#!/bin/bash

# Run the MapGuide server unit suites (mgserver test <component>) out of a CMake build tree.
#
# A suite is judged by the assertion summary it prints, not by the process exit code: a Debug
# (ASan/LSan) build exits non-zero to report leaks after every test has passed, and a passing
# run can also die or wedge in exit-time teardown (see docs/fdo-exit-teardown.md).
#
# Ctrl-C, `docker stop` and a dropped tty stop the suite that is running rather than starting the
# next one, and the run then exits 130 (SIGINT), 143 (SIGTERM) or 129 (SIGHUP).
#
# The component names are the ones `mgserver test list` reports.

COMPONENTS_ALL="CoordinateSystem DrawingService FeatureService Geometry KmlService LogManager MappingService MdfModel Misc Performance RenderingService RasterStylization ResourceService ServerAdminService ServerManager ServiceManager SiteManager SiteService Stylization TileService ProfilingService TransformMesh"

SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd)
TEST_LOG_PATH=$(pwd)
MG_BUILD_DIR=
COMPONENTS=
SUITE_TIMEOUT=5m
TIMEOUT_SET=0
LIST_COMPONENTS=0
FAILED_SUITES=0
FAILED_COMPONENTS=
RUN_SUITES=0
TOTAL_START=$SECONDS
SUITE_PID=
INTERRUPTED=0

# Ctrl-C (SIGINT), `docker stop` (SIGTERM) and a dropped tty (SIGHUP) have to reach the suite, and
# by default none does. `timeout` runs the suite in its own process group, so a SIGINT from the
# terminal never reaches mgserver, and bash defers a trap until the foreground command it is waiting
# for exits - so a trap on its own would let the loop carry on to the next component. The suite is
# therefore started as a background job and waited for, because `wait` is interruptible, and the trap
# signals the suite's whole process group. The SIGKILL escalation is not optional: `timeout` waits
# for a child it signalled, and mgserver can wedge in exit-time teardown (see
# docs/fdo-exit-teardown.md), so a SIGTERM-ignoring suite would otherwise pin both `timeout` and this
# script.
SUITE_STOP_GRACE=5

stop_suite()
{
    if [ -z "$SUITE_PID" ]; then
        return
    fi
    kill -TERM -"$SUITE_PID" 2>/dev/null
    kill -TERM "$SUITE_PID" 2>/dev/null
    remaining=$((SUITE_STOP_GRACE * 4))
    while [ "$remaining" -gt 0 ] && kill -0 "$SUITE_PID" 2>/dev/null; do
        sleep 0.25
        remaining=$((remaining - 1))
    done
    if [ "$remaining" -eq 0 ]; then
        echo "  >> Suite did not exit ${SUITE_STOP_GRACE}s after SIGTERM; sending SIGKILL"
    fi
    kill -KILL -"$SUITE_PID" 2>/dev/null
    kill -KILL "$SUITE_PID" 2>/dev/null
}

interrupt()
{
    INTERRUPTED=$1
    if [ -n "$SUITE_PID" ]; then
        echo "  >> Interrupt received; stopping the suite"
    fi
    stop_suite
}

trap 'interrupt 130' INT
trap 'interrupt 143' TERM
trap 'interrupt 129' HUP

usage()
{
    echo "Usage: $0 (options)"
    echo "Options:"
    echo "  --mapguide-build-dir [MapGuide CMake build dir]"
    echo "  --log-path [Unit test log path]"
    echo "  --component [Component to run, repeatable, 'all' runs every suite in one process,"
    echo "               default: every component, one process each]"
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
    if [ "$1" != "all" ] && ! is_known_component "$1"; then
        echo "FATAL: unknown component '$1'"
        echo "Valid components: all $COMPONENTS_ALL"
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
            TIMEOUT_SET=1
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

# `timeout` is what puts the suite in its own process group, and that group is what the interrupt
# handler signals; a duration of 0 is a documented "no timeout", so --timeout none keeps the
# grouping rather than dropping the wrapper. The duration is a per-suite budget, which is why
# `all` - every suite in one process, and longer than any of them - is uncapped unless --timeout
# was given explicitly.
if [ "$SUITE_TIMEOUT" = "none" ]; then
    RUN_TIMEOUT=0
else
    RUN_TIMEOUT="$SUITE_TIMEOUT"
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
    prepare_rc=$?
    if [ "$INTERRUPTED" -ne 0 ]; then
        echo "Interrupted while installing the FDO SDK"
        exit "$INTERRUPTED"
    fi
    if [ "$prepare_rc" -ne 0 ]; then
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
    if [ "$INTERRUPTED" -ne 0 ]; then
        break
    fi
    TEST_LOG="$TEST_LOG_PATH/mapguide_${comp}_unit_test.log"
    RESULT_XML="UnitTestResults_${comp}.xml"
    echo "Running suite: $comp"
    suite_timeout="$RUN_TIMEOUT"
    if [ "$comp" = "all" ] && [ "$TIMEOUT_SET" -eq 0 ]; then
        suite_timeout=0
        echo "  >> 'all' runs every suite in one process; no per-suite timeout applies (--timeout caps it)"
    fi
    start=$SECONDS
    timeout "$suite_timeout" ./mgserver test "$comp" "$RESULT_XML" > "$TEST_LOG" 2>&1 &
    SUITE_PID=$!
    wait "$SUITE_PID"
    rc=$?
    if [ "$INTERRUPTED" -ne 0 ]; then
        # `wait` returns as soon as the trap has run, so reap the suite the trap just killed before
        # its log and results are read.
        wait "$SUITE_PID" 2>/dev/null
    fi
    SUITE_PID=
    elapsed=$((SECONDS - start))
    RUN_SUITES=$((RUN_SUITES + 1))

    if [ "$INTERRUPTED" -ne 0 ]; then
        echo "  >> Test Suite ($comp) interrupted after ${elapsed}s - see $TEST_LOG"
        if [ -f "$RESULT_XML" ]; then
            mv "$RESULT_XML" "$TEST_LOG_PATH/$RESULT_XML"
        fi
        break
    fi

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
if [ "$INTERRUPTED" -ne 0 ]; then
    echo "Interrupted - remaining components were not run"
    exit "$INTERRUPTED"
fi
if [ "$FAILED_SUITES" -ne 0 ]; then
    echo "Failed suites:$FAILED_COMPONENTS"
    exit 1
fi
