#!/bin/bash

# Run the MapGuide test suites out of a CMake build tree: the server unit suites
# (`mgserver test <component>`), the web tier suites (the C++ web tier runner and the
# language binding test runners), or both.
#
# A suite is judged by the assertion summary it prints, not by the process exit code: a Debug
# (ASan/LSan) build exits non-zero to report leaks after every test has passed, and a passing
# run can also die or wedge in exit-time teardown (see docs/fdo-exit-teardown.md).
#
# Ctrl-C, `docker stop` and a dropped tty stop the suite that is running rather than starting the
# next one, and the run then exits 130 (SIGINT), 143 (SIGTERM) or 129 (SIGHUP).
#
# The component names are the ones `mgserver test list` reports.
#
# --run-mode runs the real server instead (`mgserver run`): it waits for the client port, sends
# SIGTERM and requires a clean, prompt exit. `mgserver test` executes an MgTestCommand and never
# enters MgServer::svc()'s reactor branch (acceptors, the client/admin/site operation-thread pools,
# ACE_Reactor), so this is the only automated coverage that branch and its shutdown ordering get.
#
# The web tier suites (--tier web) are the ones that need a *running* server, so this script owns
# their whole lifecycle: it installs the build tree into its install prefix when the web tier is
# not there yet, stages the test pack (UnitTest/{TestData,Php,Java}) under the log path, starts
# the server, runs each suite against it, stops the server, and requires the clean shutdown that
# --run-mode requires. A web suite only passes if the server also shut down cleanly.
#
# The server and the C++ web tier runner come from the build tree. The language binding suites
# come from the *install* prefix: the PHP extension, the Java glue library and the API jar are
# only ever built as part of the web tier, and the installed webconfig.ini carries the paths
# those suites expect. `build_mapguide_incremental.sh` does not build the web tier, so the
# script builds the binding targets and installs the tree itself when they are missing.

COMPONENTS_ALL="CoordinateSystem DrawingService FeatureService Geometry GwsQueryEngine KmlService LogManager MappingService MdfModel Misc Performance RenderingService RasterStylization ResourceService ServerAdminService ServerManager ServiceManager SiteManager SiteService Selection Stylization TileService ProfilingService TransformMesh"

# The language binding suites run against a live server. The .NET one exists to check the
# arrangement that ships: the C# assemblies are compiled from SWIG-generated sources on Linux here,
# and P/Invoke the *UnmanagedApi glue libraries built by the same tree - the pairing the packages
# are assembled from on Windows.
WEB_SUITES_ALL="webtestrunner java php dotnet"
WEB_SUITES_WINDOWS_ONLY=""

SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd)
TEST_LOG_PATH=$(pwd)
MG_BUILD_DIR=
COMPONENTS=
SUITE_TIMEOUT=5m
WEB_SUITE_TIMEOUT=30m
TIMEOUT_SET=0
LIST_COMPONENTS=0
LIST_WEB_SUITES=0
RUN_MODE=0
COMPONENTS_SET=0
STARTUP_TIMEOUT=60
SHUTDOWN_TIMEOUT=30
FAILED_SUITES=0
FAILED_COMPONENTS=
RUN_SUITES=0
SKIPPED_SUITES=
SKIPPED_REASONS=
TOTAL_START=$SECONDS
SUITE_PID=
INTERRUPTED=0

TIER=server
WEB_SUITES=
WEB_SUITES_SET=0
WEB_SUITES_REQUIRED=
INSTALL_DIR=
DO_INSTALL=1
WEBCONFIG=
PHP_CMD=
DICT_PATH=
RESET_REPOSITORY=0
ARTIFACTS_DIR=
SWIG_BUILD_DIR=
DOTNET_GLUE_OK=0

WEB_LOG_PATH=
WEB_PACK=
SERVER_LOG=
SERVER_PID=
MG_SRC_DIR=

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

stop_process()
{
    if [ -z "$1" ]; then
        return
    fi
    pid="$1"
    kill -TERM -"$pid" 2>/dev/null
    kill -TERM "$pid" 2>/dev/null
    remaining=$((SUITE_STOP_GRACE * 4))
    while [ "$remaining" -gt 0 ] && kill -0 "$pid" 2>/dev/null; do
        sleep 0.25
        remaining=$((remaining - 1))
    done
    if [ "$remaining" -eq 0 ]; then
        echo "  >> Suite did not exit ${SUITE_STOP_GRACE}s after SIGTERM; sending SIGKILL"
    fi
    kill -KILL -"$pid" 2>/dev/null
    kill -KILL "$pid" 2>/dev/null
}

# An interrupt has to stop whatever is running: a suite, or - for the web tier - the server those
# suites run against.
stop_suite()
{
    stop_process "$SUITE_PID"
    stop_process "$SERVER_PID"
}

interrupt()
{
    INTERRUPTED=$1
    if [ -n "$SUITE_PID" ] || [ -n "$SERVER_PID" ]; then
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
    echo "  --log-path [Test log path]"
    echo "  --tier [server|web|all, which suites to run, default: server]"
    echo "  --component [Server component to run, repeatable, 'all' runs every suite in one process,"
    echo "               default: every component, one process each]"
    echo "  --web-suite [Web tier suite to run, repeatable: $WEB_SUITES_ALL,"
    echo "               'all' runs every suite that this install can run, default: all]"
    echo "  --install-dir [MapGuide install prefix used by the web tier suites,"
    echo "                 default: MG_INSTALL_PREFIX from the build tree]"
    echo "  --webconfig-path [webconfig.ini for the web tier, default: the installed one]"
    echo "  --php-path [PHP interpreter for the PHP binding suite, default: the installed one]"
    echo "  --dictionary-path [CS-Map dictionary directory, default: the installed one]"
    echo "  --no-install [Do not build/install the web tier when its artifacts are missing]"
    echo "  --artifacts-dir [Directory with mapguideopensource-<ver>-<distro>-<arch>.tar.gz, used to"
    echo "                   take the PHP interpreter from when the install has none,"
    echo "                   default: /tmp/work/artifacts when it exists]"
    echo "  --swig-build-dir [Where the pinned SWIG is downloaded and built when it is missing,"
    echo "                   default: /tmp/download, which is container-local; point it at a"
    echo "                   mounted path to keep the tarball across containers]"
    echo "  --reset-repository [Delete the server's repository before the web tier run]"
    echo "  --run-mode [Start the real server (mgserver run), wait for its client port, then stop it"
    echo "              with SIGTERM and require a clean exit; takes no --component]"
    echo "  --startup-timeout [Seconds to wait for the client port, default: $STARTUP_TIMEOUT]"
    echo "  --shutdown-timeout [Seconds to wait for exit after SIGTERM, default: $SHUTDOWN_TIMEOUT]"
    echo "  --timeout [Per-suite timeout, default: $SUITE_TIMEOUT for server suites and"
    echo "             $WEB_SUITE_TIMEOUT for web suites, or 'none' to disable]"
    echo "  --list-components [List the server component names and exit]"
    echo "  --list-web-suites [List the web tier suite names and exit]"
    echo "  --help [Display usage]"
}

is_known_component()
{
    case " $COMPONENTS_ALL " in
        *" $1 "*) return 0 ;;
    esac
    return 1
}

is_known_web_suite()
{
    case " $WEB_SUITES_ALL " in
        *" $1 "*) return 0 ;;
    esac
    return 1
}

is_required_web_suite()
{
    case " $WEB_SUITES_REQUIRED " in
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
    COMPONENTS_SET=1
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

# `all` expands to every suite the tier knows about; a suite named on the command line is
# required, so a missing prerequisite is a failure rather than a skip.
add_web_suite()
{
    WEB_SUITES_SET=1
    if [ "$1" = "all" ]; then
        for web_suite in $WEB_SUITES_ALL; do
            add_web_suite_one "$web_suite"
        done
        return
    fi
    if ! is_known_web_suite "$1"; then
        echo "FATAL: unknown web suite '$1'"
        echo "Valid web suites: all $WEB_SUITES_ALL"
        exit 1
    fi
    add_web_suite_one "$1"
    case " $WEB_SUITES_REQUIRED " in
        *" $1 "*) ;;
        *) WEB_SUITES_REQUIRED="${WEB_SUITES_REQUIRED:+$WEB_SUITES_REQUIRED }$1" ;;
    esac
}

add_web_suite_one()
{
    case " $WEB_SUITES " in
        *" $1 "*) ;;
        *) WEB_SUITES="${WEB_SUITES:+$WEB_SUITES }$1" ;;
    esac
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
        --tier)
            TIER="$2"
            shift
            ;;
        --component)
            add_component "$2"
            shift
            ;;
        --web-suite)
            add_web_suite "$2"
            shift
            ;;
        --install-dir)
            INSTALL_DIR="$2"
            shift
            ;;
        --webconfig-path)
            WEBCONFIG="$2"
            shift
            ;;
        --php-path)
            PHP_CMD="$2"
            shift
            ;;
        --dictionary-path)
            DICT_PATH="$2"
            shift
            ;;
        --no-install)
            DO_INSTALL=0
            ;;
        --artifacts-dir)
            ARTIFACTS_DIR="$2"
            shift
            ;;
        --swig-build-dir)
            SWIG_BUILD_DIR="$2"
            shift
            ;;
        --reset-repository)
            RESET_REPOSITORY=1
            ;;
        --timeout)
            SUITE_TIMEOUT="$2"
            TIMEOUT_SET=1
            shift
            ;;
        --run-mode)
            RUN_MODE=1
            ;;
        --list-web-suites)
            LIST_WEB_SUITES=1
            ;;
        --startup-timeout)
            STARTUP_TIMEOUT="$2"
            shift
            ;;
        --shutdown-timeout)
            SHUTDOWN_TIMEOUT="$2"
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

if [ "$LIST_WEB_SUITES" -eq 1 ]; then
    for web_suite in $WEB_SUITES_ALL; do
        echo "$web_suite"
    done
    exit
fi

case "$TIER" in
    server|web|all) ;;
    *)
        echo "FATAL: unknown tier '$TIER' (expected server, web or all)"
        exit 1
        ;;
esac

# A selection that the tier cannot honour is a mistake rather than something to ignore: asking
# for --tier web --component X would otherwise run the web suites and silently drop X.
if [ "$COMPONENTS_SET" -eq 1 ] && [ "$TIER" = "web" ]; then
    echo "FATAL: --component selects server suites; use --tier server or --tier all"
    exit 1
fi
if [ "$WEB_SUITES_SET" -eq 1 ] && [ "$TIER" = "server" ]; then
    echo "FATAL: --web-suite selects web tier suites; use --tier web or --tier all"
    exit 1
fi

if [ -z "$COMPONENTS" ]; then
    COMPONENTS="$COMPONENTS_ALL"
fi

if [ "$WEB_SUITES_SET" -eq 0 ]; then
    for web_suite in $WEB_SUITES_ALL; do
        add_web_suite_one "$web_suite"
    done
fi

# `timeout` is what puts the suite in its own process group, and that group is what the interrupt
# handler signals; a duration of 0 is a documented "no timeout", so --timeout none keeps the
# grouping rather than dropping the wrapper. The duration is a per-suite budget, which is why
# `all` - every server suite in one process, and longer than any of them - is uncapped unless
# --timeout was given explicitly.
if [ "$SUITE_TIMEOUT" = "none" ]; then
    RUN_TIMEOUT=0
    WEB_RUN_TIMEOUT=0
else
    RUN_TIMEOUT="$SUITE_TIMEOUT"
    if [ "$TIMEOUT_SET" -eq 1 ]; then
        WEB_RUN_TIMEOUT="$SUITE_TIMEOUT"
    else
        WEB_RUN_TIMEOUT="$WEB_SUITE_TIMEOUT"
    fi
fi

# Reads a Port value out of serverconfig.ini for the given [section].
server_port()
{
    sed -n "/^\\[$1\\]/,/^\\[/p" "$CORE_DIR/serverconfig.ini" \
        | sed -n 's/^Port[[:space:]]*=[[:space:]]*\([0-9][0-9]*\).*/\1/p' \
        | head -1
}

# True when something already accepts connections on the port. The probe connects, so it is only
# used to fail fast with a clear message - a stray listener means this run would test the wrong
# process (or fail to bind) rather than the build we just made.
port_in_use()
{
    (exec 3<>"/dev/tcp/127.0.0.1/$1") 2>/dev/null
}

# Starts the real server and waits for its client port; $1 is the log file. Sets SERVER_PID,
# which is what the interrupt trap signals. The port checks fail fast so that a stray listener
# cannot make this run test the wrong process.
#
# This is the reactor path: MgServer::svc() with no command registers the accept handlers, starts the
# client/admin/site operation-thread pools and runs ACE_Reactor. None of the unit suites reach it, so
# this is where a shutdown ordering bug shows up - as a hang in the thread-manager wait, or as a
# LeakSanitizer report from the threads that outlived teardown.
start_server()
{
    run_log="$1"
    port=$(server_port "ClientConnectionProperties")
    if [ -z "$port" ]; then
        echo "FATAL: no Port in [ClientConnectionProperties] of $CORE_DIR/serverconfig.ini"
        return 1
    fi
    for p in "$(server_port AdministrationConnectionProperties)" \
             "$port" \
             "$(server_port SiteConnectionProperties)"; do
        if [ -n "$p" ] && port_in_use "$p"; then
            echo "FATAL: port $p is already in use; stop whatever is listening on 127.0.0.1:$p"
            return 1
        fi
    done

    echo "  >> Starting the server: ./mgserver run (client port $port, log $run_log)"
    mkdir -p /var/lock/mgserver 2>/dev/null
    start=$SECONDS
    # `timeout` puts the server in its own process group, so the interrupt handler and the SIGKILL
    # escalation cannot signal this script's own group. Its duration is only a backstop: the test is
    # the SIGTERM below.
    timeout "$((STARTUP_TIMEOUT + SHUTDOWN_TIMEOUT + 30))" ./mgserver run > "$run_log" 2>&1 &
    SERVER_PID=$!

    ready=0
    elapsed=0
    while [ "$elapsed" -lt "$STARTUP_TIMEOUT" ]; do
        if ! kill -0 "$SERVER_PID" 2>/dev/null; then
            break
        fi
        if port_in_use "$port"; then
            ready=1
            break
        fi
        sleep 1
        elapsed=$((elapsed + 1))
    done

    if [ "$ready" -ne 1 ]; then
        echo "  >> Server did not accept connections on port $port within ${STARTUP_TIMEOUT}s"
        tail -20 "$run_log" | sed 's/^/    /'
        kill -TERM "$SERVER_PID" 2>/dev/null
        sleep 1
        kill -KILL -"$SERVER_PID" 2>/dev/null
        kill -KILL "$SERVER_PID" 2>/dev/null
        wait "$SERVER_PID" 2>/dev/null
        SERVER_PID=
        return 1
    fi
    echo "  >> Server is accepting connections after $((SECONDS - start))s"
    return 0
}

# Stops the server start_server started, and requires the clean, prompt exit a real shutdown has
# to have: exit 0, a log that reached "Server stopped", and no LeakSanitizer summary. $1 is the
# log file start_server wrote.
stop_server()
{
    run_log="$1"
    if [ -z "$SERVER_PID" ]; then
        return 1
    fi
    kill -TERM "$SERVER_PID" 2>/dev/null
    stop=$SECONDS
    elapsed=0
    while [ "$elapsed" -lt "$SHUTDOWN_TIMEOUT" ] && kill -0 "$SERVER_PID" 2>/dev/null; do
        sleep 1
        elapsed=$((elapsed + 1))
    done
    if kill -0 "$SERVER_PID" 2>/dev/null; then
        echo "  >> Server did not exit within ${SHUTDOWN_TIMEOUT}s of SIGTERM - killing it"
        echo "  >>   (a thread is still running in the shutdown wait; see docs/mapguide-memory-leaks.md)"
        kill -KILL -"$SERVER_PID" 2>/dev/null
        kill -KILL "$SERVER_PID" 2>/dev/null
        wait "$SERVER_PID" 2>/dev/null
        SERVER_PID=
        return 1
    fi
    wait "$SERVER_PID"
    server_rc=$?
    SERVER_PID=
    echo "  >> Server exited $((SECONDS - stop))s after SIGTERM (exit $server_rc)"

    failed=0
    if [ "$server_rc" -ne 0 ]; then
        echo "  >> Expected a clean (exit 0) shutdown, got $server_rc"
        failed=1
    fi
    if ! grep -q "Server stopped" "$run_log"; then
        echo "  >> The log never reached \"Server stopped\"; shutdown did not complete"
        failed=1
    fi
    leak_summary=$(grep -E "^SUMMARY: AddressSanitizer:" "$run_log" | tail -1)
    if [ -n "$leak_summary" ]; then
        echo "  >> ${leak_summary#SUMMARY: AddressSanitizer: } - see $run_log"
        failed=1
    fi
    if [ "$failed" -ne 0 ]; then
        tail -30 "$run_log" | sed 's/^/    /'
        return 1
    fi
    return 0
}

run_server_mode()
{
    run_log="$TEST_LOG_PATH/mapguide_run_mode.log"
    if start_server "$run_log"; then
        if stop_server "$run_log"; then
            return 0
        fi
        return 1
    fi
    # start_server already reported the failure and the log tail
    return 1
}

# --- web tier ------------------------------------------------------------------------------
#
# The web tier suites all need a running server, and two of the three need an installed tree,
# so the functions below own both: they install the build tree when the web tier artifacts are
# missing, stage a test pack that the suites can write to, and bracket every suite with the
# server lifecycle and shutdown check --run-mode uses.

cache_value()
{
    sed -n "s/^$1:[A-Z]*=//p" "$MG_BUILD_DIR/CMakeCache.txt" | head -1
}

# SWIG is pinned to the version the MapGuide bootstrap builds from source, and a distro package is
# never used: one SWIG version generates the Java and PHP glue while another generates the .NET
# glue, so a replacement SWIG silently makes the bindings disagree. cmake_bootstrap.sh is the single
# place that decides the version, so it is read from there rather than repeated here.
SWIG_PREFIX=/usr/local
SWIG_TOOL_PATH="$SWIG_PREFIX/bin/swig"

swig_required_version()
{
    sed -n 's|.*refs/tags/v\([0-9][0-9.]*\).zip.*|\1|p' \
        "${MG_SRC_DIR:-/tmp/work/src}/cmake_bootstrap.sh" 2>/dev/null | head -1
}

# cmake_bootstrap.sh acquires SWIG itself when `swig` is not on PATH, but "is swig on PATH" is not
# the question - a distro package satisfies that with a version nothing here pinned - so this asks
# the installed tool what it is.
swig_available()
{
    want=$(swig_required_version)
    [ -x "$SWIG_TOOL_PATH" ] || return 1
    if [ -n "$want" ]; then
        "$SWIG_TOOL_PATH" -version 2>/dev/null | grep -q "SWIG Version $want"
        return $?
    fi
    return 0
}

# Builds the pinned SWIG from source when the container does not already have it, reusing a tarball
# that is already in $SWIG_BUILD_DIR. Must run before anything is configured: `find_package(SWIG 4.1)`
# only requires a *new enough* SWIG, so a configure that ran earlier would have baked whatever swig
# was on PATH into the build tree's CMakeCache.
build_swig()
{
    if swig_available; then
        return 0
    fi
    want=$(swig_required_version)
    if [ -z "$want" ]; then
        echo "FATAL: could not read the pinned SWIG version from cmake_bootstrap.sh"
        return 1
    fi
    if [ -x "$SWIG_TOOL_PATH" ]; then
        echo "  >> $SWIG_TOOL_PATH is not SWIG $want; replacing it with the pinned source build"
    fi
    echo "  >> Building SWIG $want from source (not using any distro package)"
    mkdir -p "$SWIG_BUILD_DIR" || return 1
    if [ ! -f "$SWIG_BUILD_DIR/swig.zip" ]; then
        curl -fsSL -o "$SWIG_BUILD_DIR/swig.zip" \
            "https://github.com/swig/swig/archive/refs/tags/v$want.zip" || return 1
    fi
    ( cd "$SWIG_BUILD_DIR" && unzip -oq swig.zip ) || return 1
    (
        cd "$SWIG_BUILD_DIR/swig-$want" || exit 1
        ./autogen.sh > /dev/null \
            && ./configure --enable-silent-rules > /dev/null \
            && make -j"$(nproc)" > /dev/null \
            && make install > /dev/null
    ) || return 1
    hash -r
    swig_available || {
        echo "FATAL: the SWIG build installed $SWIG_TOOL_PATH, but it does not report $want"
        return 1
    }
    echo "  >> $("$SWIG_TOOL_PATH" -version 2>/dev/null | head -1)"
    return 0
}

# The suffix CMake appends to the library and target names, e.g. "-4.0.0".
mg_version_suffix()
{
    echo "-$(cache_value MG_VERSION_MAJOR).$(cache_value MG_VERSION_MINOR).$(cache_value MG_VERSION_RELEASE)"
}

# The .NET glue is generated by SWIG, and so is the Java/PHP glue; webtestrunner is not.
web_suites_need_swig()
{
    case " $WEB_SUITES " in
        *" java "*|*" php "*|*" dotnet "*) return 0 ;;
    esac
    return 1
}

# The CMake targets the web tier suites are built from. build_mapguide_incremental.sh builds
# only mgserver and MgUnitTesting, so a container whose build tree was never fully built needs
# these before `cmake --install` can install them.
web_suite_targets()
{
    targets=
    suffix=$(mg_version_suffix)
    case " $WEB_SUITES " in
        *" webtestrunner "*) targets="$targets MgWebTestRunner" ;;
    esac
    case " $WEB_SUITES " in
        *" php "*) targets="$targets php_MapGuideApi$suffix" ;;
    esac
    case " $WEB_SUITES " in
        *" java "*) targets="$targets MapGuideJavaApi$suffix" ;;
    esac
    # The .NET glue is not part of this tree's targets - it comes from the common-libs subset,
    # which prepare_dotnet_glue builds.
    echo "$targets"
}

# Prints what the requested suites need and do not have yet: the runner comes from the build
# tree, the binding artifacts from the install prefix.
missing_web_artifacts()
{
    missing=
    if [ -z "$WEBCONFIG" ] && [ ! -f "$INSTALL_DIR/webserverextensions/www/webconfig.ini" ]; then
        missing="$missing webconfig.ini"
    fi
    case " $WEB_SUITES " in
        *" webtestrunner "*)
            if [ ! -x "$MG_BUILD_DIR/Web/src/WebTestRunner/MgWebTestRunner" ]; then
                missing="$missing MgWebTestRunner"
            fi
            ;;
    esac
    case " $WEB_SUITES " in
        *" php "*)
            if [ ! -f "$INSTALL_DIR/webserverextensions/lib64/libphp_MapGuideApi.so" ]; then
                missing="$missing libphp_MapGuideApi.so"
            fi
            ;;
    esac
    case " $WEB_SUITES " in
        *" java "*)
            if [ ! -f "$INSTALL_DIR/webserverextensions/lib64/libMapGuideJavaApi.so" ]; then
                missing="$missing libMapGuideJavaApi.so"
            fi
            if [ ! -f "$INSTALL_DIR/webserverextensions/www/WEB-INF/lib/MapGuideApi.jar" ]; then
                missing="$missing MapGuideApi.jar"
            fi
            ;;
    esac
    echo "$missing"
}

# Builds the web tier targets the requested suites need, and installs them when the install
# prefix does not have them. Ninja makes the build a no-op when nothing changed, so it is worth
# doing unconditionally: a build tree that predates this script has no MgWebTestRunner target
# until CMake is re-run, which `cmake --build` does for us.
prepare_web_tier()
{
    if [ -z "$INSTALL_DIR" ]; then
        echo "FATAL: could not work out the MapGuide install prefix"
        echo "Pass it with --install-dir, or use a build tree configured with MG_INSTALL_PREFIX"
        return 1
    fi

    targets=$(web_suite_targets)
    if [ "$DO_INSTALL" -eq 1 ] && [ -n "$targets" ]; then
        # The glue in these targets is generated by whatever SWIG the tree was configured with, so a
        # tree configured against another version would be built - and then tested - with the wrong
        # one. Say so rather than silently producing glue the pinned SWIG did not generate.
        configured_swig=$(cache_value SWIG_VERSION)
        pinned_swig=$(swig_required_version)
        if [ -n "$configured_swig" ] && [ -n "$pinned_swig" ] && [ "$configured_swig" != "$pinned_swig" ]; then
            echo "FATAL: this build tree was configured with SWIG $configured_swig, but the pinned version is $pinned_swig"
            echo "  The glue has to be generated by $pinned_swig. Remove $MG_BUILD_DIR and run again."
            return 1
        fi
        echo "Building the web tier targets:$targets"
        ( cd "$MG_BUILD_DIR" && cmake --build . --target $targets ) || return 1
    fi

    missing=$(missing_web_artifacts)
    if [ -z "$missing" ]; then
        return 0
    fi

    if [ "$DO_INSTALL" -eq 0 ]; then
        echo "FATAL: the web tier is not installed under $INSTALL_DIR (missing:$missing)"
        echo "  Run again without --no-install to build and install it from the build tree."
        return 1
    fi

    echo "Installing the web tier from $MG_BUILD_DIR into $INSTALL_DIR"
    echo "  >> missing:$missing"
    # Installs whatever is already built, without pulling the web tier back in the way the
    # install target's dependency on "all" would.
    ( cd "$MG_BUILD_DIR" && cmake --install . )
}

# The suites open the sqlite fixtures they generate next to the .dump files and write their logs
# beside themselves, so they get a copy of the pack: the SVN working copy stays clean.
prepare_web_pack()
{
    if [ -z "$MG_SRC_DIR" ]; then
        echo "FATAL: could not work out the MapGuide source directory from $MG_BUILD_DIR/CMakeCache.txt"
        return 1
    fi
    WEB_PACK="$WEB_LOG_PATH/testpack"
    echo "Staging the test pack in $WEB_PACK"
    rm -rf "$WEB_PACK"
    mkdir -p "$WEB_PACK/UnitTest" || return 1
    cp -R "$MG_SRC_DIR/UnitTest/TestData" "$WEB_PACK/UnitTest/TestData" || return 1
    cp -R "$MG_SRC_DIR/Bindings/src/Test/Php" "$WEB_PACK/UnitTest/Php" || return 1
    build_sample_package "$WEB_PACK/UnitTest/TestData/Samples/Sheboygan"
}

# UnitTest/TestData ships the Sheboygan sources but not the package built from them, and the
# suites expect the package. build.sh is the source of truth for the file list; it ends in `zip`,
# which not every image has, so the same copies are made here and archived with `zip` or `jar`
# (both write an archive the resource service accepts).
build_sample_package()
{
    dir="$1"
    if [ ! -d "$dir" ] || [ -f "$dir/Sheboygan.mgp" ]; then
        return 0
    fi
    for data_file in \
        "FeatureService/SDF/Sheboygan_BuildingOutlines.sdf:BuildingOutlines" \
        "FeatureService/SDF/Sheboygan_CityLimits.sdf:CityLimits" \
        "FeatureService/SDF/Sheboygan_Parcels.sdf:Parcels" \
        "FeatureService/SDF/Sheboygan_VotingDistricts.sdf:VotingDistricts" \
        "MappingService/UT_HydrographicPolygons.sdf:HydrographicPolygons" \
        "MappingService/UT_Rail.sdf:Rail" \
        "TileService/UT_RoadCenterLines.sdf:RoadCenterLines"; do
        src_file="${data_file%%:*}"
        name="${data_file##*:}"
        if [ -f "$dir/../../$src_file" ]; then
            cp -f "$dir/../../$src_file" \
                "$dir/Library/Samples/Sheboygan/Data/${name}.FeatureSource_DATA_${name}.sdf" || return 1
        fi
    done
    if command -v zip >/dev/null 2>&1; then
        ( cd "$dir" && zip -qr Sheboygan.mgp Library MgResourcePackageManifest.xml )
    elif command -v jar >/dev/null 2>&1; then
        ( cd "$dir" && jar cfM Sheboygan.mgp Library MgResourcePackageManifest.xml )
    else
        echo "  >> WARNING: neither zip nor jar is available; the sample data package was not built"
        return 0
    fi
    if [ -f "$dir/Sheboygan.mgp" ]; then
        echo "  >> Built the Sheboygan sample data package"
    else
        echo "  >> WARNING: could not build the Sheboygan sample data package"
    fi
}

# The interpreter cmake_linuxapt.sh built, wherever that working dir is: its CLI binary is usable
# straight from the build tree, which saves an install (and, before the incremental build learned to
# run cmake_linuxapt.sh, saved a full build).
linuxapt_php_cli()
{
    linuxapt_dir=$(cache_value MG_LINUXAPT_WORK_DIR)
    if [ -n "$linuxapt_dir" ]; then
        ls "$linuxapt_dir"/LinuxApt/php-*/sapi/cli/php 2>/dev/null | head -1
    fi
}

php_loads_mapguide()
{
    "$1" -d "extension_dir=$INSTALL_DIR/webserverextensions/lib64" \
        -d "extension=libphp_MapGuideApi.so" -m 2>/dev/null | grep -qx 'MapGuideApi'
}

php_cmd()
{
    if [ -n "$PHP_CMD" ]; then
        if [ -x "$PHP_CMD" ]; then
            echo "$PHP_CMD"
        fi
        return
    fi
    if [ -x "$INSTALL_DIR/webserverextensions/php/bin/php" ]; then
        echo "$INSTALL_DIR/webserverextensions/php/bin/php"
        return
    fi
    candidate=$(linuxapt_php_cli)
    if [ -n "$candidate" ] && php_loads_mapguide "$candidate"; then
        echo "$candidate"
        return
    fi
    candidate=$(command -v php 2>/dev/null)
    if [ -n "$candidate" ] && php_loads_mapguide "$candidate"; then
        echo "$candidate"
    fi
}

# The PHP interpreter is built by cmake_linuxapt.sh, which is part of a full build, so
# `cmake --install` never puts one in the install prefix: a develop_thin container has the
# extension (webserverextensions/lib64/libphp_MapGuideApi.so) but no interpreter to load it with,
# and the PHP suite is skipped. The release tarball in artifacts/ does contain one, so take the
# interpreter from there rather than requiring a full rebuild. Only webserverextensions/php is
# extracted: the rest of that tarball is the packaged build, and extracting it over the install
# would replace the libraries this run just built with the packaged ones.
provision_php_interpreter()
{
    if [ -n "$(php_cmd)" ]; then
        return 0
    fi
    if [ "$DO_INSTALL" -eq 0 ]; then
        return 0
    fi
    if [ -z "$ARTIFACTS_DIR" ] || [ ! -d "$ARTIFACTS_DIR" ]; then
        return 0
    fi

    # Never take "any tarball": the one built for another distro links a different set of
    # thirdparty libraries, exactly as with the FDO SDK.
    tarball=
    if [ -n "$MG_DISTRO" ]; then
        tarball=$(ls -t "$ARTIFACTS_DIR"/mapguideopensource-*.*.*.*-"$MG_DISTRO"-*.tar.gz 2>/dev/null | head -1)
    fi
    if [ -z "$tarball" ]; then
        # webserverextensions/php/lib/php.ini is a CMake install artefact, so the directory exists and
        # looks populated; only the interpreter is absent, because only the full build makes one.
        if [ -d "$INSTALL_DIR/webserverextensions/php" ] && [ ! -x "$INSTALL_DIR/webserverextensions/php/bin/php" ]; then
            echo "  >> $INSTALL_DIR/webserverextensions/php has php.ini but no bin/php:"
            echo "  >>   cmake --install installs the configuration, the interpreter comes from a full build"
        fi
        echo "  >> No PHP interpreter and no MapGuide release tarball for ${MG_DISTRO:-this distro} in $ARTIFACTS_DIR"
        echo "  >>   (build one with ./build_mapguide_incremental.sh, or point --artifacts-dir at a"
        echo "  >>    directory with the distro tarball, or pass --php-path)"
        return 0
    fi
    if ! tar -tzf "$tarball" 2>/dev/null | grep -qx 'webserverextensions/php/bin/php'; then
        echo "  >> $(basename "$tarball") carries no webserverextensions/php/bin/php"
        return 0
    fi

    echo "Installing the PHP interpreter from $(basename "$tarball")"
    mkdir -p "$INSTALL_DIR" || return 1
    tar -xzf "$tarball" -C "$INSTALL_DIR" webserverextensions/php || return 1
    if [ -x "$INSTALL_DIR/webserverextensions/php/bin/php" ]; then
        echo "  >> $INSTALL_DIR/webserverextensions/php/bin/php"
    else
        echo "  >> WARNING: the extraction produced no interpreter"
    fi
    return 0
}

ant_cmd()
{
    if command -v ant >/dev/null 2>&1; then
        echo "ant"
    elif [ -n "$ANT_HOME" ] && [ -x "$ANT_HOME/bin/ant" ]; then
        echo "$ANT_HOME/bin/ant"
    fi
}

java_cmd()
{
    if [ -n "$JAVA_HOME" ] && [ -x "$JAVA_HOME/bin/java" ]; then
        echo "$JAVA_HOME/bin/java"
    elif command -v java >/dev/null 2>&1; then
        echo "java"
    fi
}

# The image installs the SDK with dotnet-install.sh, which puts it in ~/.dotnet and only adds that
# to PATH from the build scripts, so look there before trusting PATH.
dotnet_cmd()
{
    if [ -n "$DOTNET_ROOT" ] && [ -x "$DOTNET_ROOT/dotnet" ]; then
        echo "$DOTNET_ROOT/dotnet"
    elif [ -x "$HOME/.dotnet/dotnet" ]; then
        echo "$HOME/.dotnet/dotnet"
    elif command -v dotnet >/dev/null 2>&1; then
        echo "dotnet"
    fi
}

# The .NET glue is built from the common-libs subset, which a full build does not produce: its
# CMakeLists only adds Bindings/DotNet when COMMON_SUBSET_ONLY is set, because on Windows the C#
# sources are compiled separately and the Linux glue is overlaid on them. Keep that build beside
# the main one, under its own install prefix, so neither disturbs the other.
dotnet_common_build_dir()
{
    echo "${MG_BUILD_DIR}_commonlibs"
}

dotnet_glue_install_dir()
{
    echo "$(dotnet_common_build_dir)/install"
}

# True when the five glue libraries are installed. They are what the generated C# P/Invokes.
dotnet_glue_ready()
{
    glue_dir="$(dotnet_glue_install_dir)/lib64"
    for api in Foundation Geometry PlatformBase MapGuideCommon Web; do
        if [ ! -f "$glue_dir/lib${api}UnmanagedApi.so" ]; then
            return 1
        fi
    done
    return 0
}

# Builds the common-libs subset with the .NET glue, the way build_mapguide_generic.sh does for a
# generic build: a common-subset OEM tree of its own, then cmake_build.sh --common-subset-only.
prepare_dotnet_glue()
{
    # The generated C# lives in the build tree, not in the install, so being "installed" is not a
    # freshness signal for it: the build runs even then, which ninja makes a no-op unless a
    # CMakeLists.txt (or an .i) changed. That is what regenerates the sources after a change to
    # the SWIG command line.
    if dotnet_glue_ready && [ ! -f "$(dotnet_common_build_dir)/build.ninja" ]; then
        return 0
    fi
    if [ "$DO_INSTALL" -eq 0 ]; then
        if dotnet_glue_ready; then
            return 0
        fi
        echo "  >> No .NET glue in $(dotnet_glue_install_dir) and --no-install was given"
        return 1
    fi
    # SWIG generates the C# sources here and the Java/PHP glue in the other build tree, and both have
    # to come from the same pinned build - so this refuses to configure against anything else rather
    # than letting cmake_bootstrap.sh fall back to whatever `swig` happens to be on PATH.
    if [ "$DO_INSTALL" -eq 1 ] && ! swig_available; then
        echo "  >> the pinned SWIG $(swig_required_version) is not installed; building it"
        build_swig || return 1
    fi
    build_dir=$(dotnet_common_build_dir)
    oem_dir="$(dirname "$MG_BUILD_DIR")/oem_commonlibs"
    log="$WEB_LOG_PATH/dotnet_glue_build.log"

    if [ ! -f "$build_dir/CMakeCache.txt" ]; then
        echo "Building the .NET glue libraries (common-libs subset) - first run only"
        echo "  >> log: $log"
        : > "$log"
        if [ ! -f "$oem_dir/env_vars.sh" ]; then
            ( cd "$MG_SRC_DIR" && ./cmake_bootstrap.sh --config "$(cache_value CMAKE_BUILD_TYPE)" \
                --oem-working-dir "$oem_dir" --build 64 --with-ccache --have-system-xerces \
                --with-internal-geos --common-subset-only ) >> "$log" 2>&1 || return 1
        fi
        # MG_INST_PREFIX, BUILD_CPU and BUILD_CONFIG are read from the environment by cmake_build.sh.
        if ! ( cd "$MG_SRC_DIR" && MG_INST_PREFIX="$(dotnet_glue_install_dir)" BUILD_CPU=64 \
            BUILD_CONFIG="$(cache_value CMAKE_BUILD_TYPE)" \
            LINUXAPT_WORK_DIR="$(cache_value MG_LINUXAPT_WORK_DIR)" \
            ./cmake_build.sh --oem-working-dir "$oem_dir" --cmake-build-dir "$build_dir" \
                --mg-ver-major "$(cache_value MG_VERSION_MAJOR)" \
                --mg-ver-minor "$(cache_value MG_VERSION_MINOR)" \
                --mg-ver-rel "$(cache_value MG_VERSION_RELEASE)" \
                --mg-ver-rev "$(cache_value MG_VERSION_REV)" \
                --ninja --common-subset-only ) >> "$log" 2>&1; then
            # cmake_build.sh configures and builds in one call, so a failure here has usually left a
            # complete configure behind; one more pass finishes it (and fails again if it was the
            # configure that broke).
            echo "  >> the glue build failed; retrying once (see $log)" >&2
            ( cd "$build_dir" && cmake --build . ) >> "$log" 2>&1 || return 1
        fi
    else
        configured_swig=$(sed -n "s/^SWIG_VERSION:[A-Z]*=//p" "$build_dir/CMakeCache.txt" | head -1)
        pinned_swig=$(swig_required_version)
        if [ -n "$configured_swig" ] && [ -n "$pinned_swig" ] && [ "$configured_swig" != "$pinned_swig" ]; then
            echo "  >> this tree was configured with SWIG $configured_swig, not the pinned $pinned_swig"
            echo "  >> removing $build_dir so the glue is regenerated with the pinned SWIG"
            rm -rf "$build_dir" || return 1
            return prepare_dotnet_glue
        fi
        # The DotNet CMakeLists order the modules by their %include graph because generation writes
        # into the source tree, but a second pass is still cheap insurance against a collision.
        if ! ( cd "$build_dir" && cmake --build . ) >> "$log" 2>&1; then
            echo "  >> the incremental glue build failed; retrying once (see $log)" >&2
            ( cd "$build_dir" && cmake --build . ) >> "$log" 2>&1 || return 1
        fi
    fi
    # Always refresh the install: the glue links the core libraries, so a rebuilt libMgFoundation
    # has to reach the glue directory or the suite would run the old one against the new server.
    ( cd "$build_dir" && cmake --install . ) >> "$log" 2>&1 || return 1

    if ! dotnet_glue_ready; then
        echo "  >> the build produced no glue libraries; see $log"
        return 1
    fi
    echo "  >> $(dotnet_glue_install_dir)/lib64"
    return 0
}

# Prints why a suite cannot run here, and nothing when it can.
web_suite_unavailable_reason()
{
    case "$1" in
        webtestrunner)
            if [ ! -x "$MG_BUILD_DIR/Web/src/WebTestRunner/MgWebTestRunner" ]; then
                echo "the web tier runner was not built (target MgWebTestRunner)"
            fi
            ;;
        php)
            cmd=$(php_cmd)
            if [ -z "$cmd" ]; then
                echo "no PHP interpreter with the MapGuide extension (cmake --install only installs its configuration; run ./build_mapguide_incremental.sh to build one, or supply --php-path / --artifacts-dir with a distro tarball)"
            elif ! "$cmd" -m 2>/dev/null | grep -qx 'MapGuideApi'; then
                echo "$cmd does not load the MapGuide extension"
            fi
            ;;
        java)
            if [ -z "$(ant_cmd)" ]; then
                echo "ant is not installed (it builds the Java test runner)"
            elif [ -z "$(java_cmd)" ]; then
                echo "java is not installed"
            elif [ ! -f "$INSTALL_DIR/webserverextensions/www/WEB-INF/lib/MapGuideApi.jar" ]; then
                echo "MapGuideApi.jar is not installed under $INSTALL_DIR"
            fi
            ;;
        dotnet)
            if [ -z "$(dotnet_cmd)" ]; then
                echo "no .NET SDK (the image installs one with dotnet-install.sh; look for ~/.dotnet)"
            elif [ "$DOTNET_GLUE_OK" -eq 0 ] && ! dotnet_glue_ready; then
                echo "the .NET glue libraries could not be built (see $WEB_LOG_PATH/dotnet_glue_build.log)"
            fi
            ;;
        *)
            echo "unknown suite"
            ;;
    esac
}

# Runs a suite in the background under `timeout` - which is what puts it in its own process
# group, so the interrupt handler can signal it - and waits for it. $1 is the working directory.
run_guarded()
{
    run_dir="$1"
    shift
    # `exec` makes the subshell *become* `timeout`, which then leads its own process group -
    # that group is what the interrupt handler signals, and without it the suite would be
    # orphaned by a signal that only reached the subshell.
    ( cd "$run_dir" && exec timeout "$WEB_RUN_TIMEOUT" "$@" ) &
    SUITE_PID=$!
    wait "$SUITE_PID"
    rc=$?
    if [ "$INTERRUPTED" -ne 0 ]; then
        # `wait` returns as soon as the trap has run, so reap the suite the trap just killed.
        wait "$SUITE_PID" 2>/dev/null
    fi
    SUITE_PID=
    return $rc
}

# The binding runners print "Tests failed/run: <failed>/<run>" as their last line, so a run that
# died before printing it (a fatal error, an abort) is a failure rather than a pass.
binding_suite_passed()
{
    summary=$(grep -E '^Tests failed/run:' "$1" | tail -1)
    case "$summary" in
        "Tests failed/run: 0/"*) return 0 ;;
    esac
    return 1
}

run_web_webtestrunner()
{
    run_log="$1"
    run_dir="$WEB_LOG_PATH/webtestrunner"
    rm -rf "$run_dir"
    mkdir -p "$run_dir" || return 1
    # The runner initializes the web tier from ./webconfig.ini and reads its fixtures from
    # ./TestData, both relative to the working directory.
    cp "$WEBCONFIG" "$run_dir/webconfig.ini" || return 1
    cp -R "$MG_SRC_DIR/Web/src/WebTestRunner/TestData" "$run_dir/TestData" || return 1
    run_guarded "$run_dir" "$MG_BUILD_DIR/Web/src/WebTestRunner/MgWebTestRunner" > "$run_log" 2>&1
}

run_web_php()
{
    run_log="$1"
    run_dir="$WEB_PACK/UnitTest/Php"
    php=$(php_cmd)
    php_args=
    # The installed php.ini already points extension_dir at the install; a php from the
    # environment does not, so tell it where the extension is.
    if ! "$php" -m 2>/dev/null | grep -qx 'MapGuideApi'; then
        php_args="-d extension_dir=$INSTALL_DIR/webserverextensions/lib64 -d extension=libphp_MapGuideApi.so"
    fi
    run_guarded "$run_dir" "$php" $php_args RunTests.php > "$run_log" 2>&1
}

run_web_java()
{
    run_log="$1"
    run_dir="$WEB_PACK/UnitTest/Java"
    proj_dir="$WEB_PACK/UnitTest/JavaProject"
    build_log="$WEB_LOG_PATH/java_build.log"
    src_dir="$MG_SRC_DIR/Bindings/src/Test/Java"

    # ant writes into its own project tree (it copies MapGuideApi.jar into lib/), so it runs
    # against a copy rather than against the SVN working copy.
    rm -rf "$run_dir" "$proj_dir"
    cp -R "$src_dir" "$proj_dir" || return 1
    # `build/` is svn-ignored output from an earlier local ant run. Copying it would give ant a
    # set of .class files as new as the .java files it just copied, so javac would skip the
    # recompile and the suite would silently run stale code.
    rm -rf "$proj_dir/build"
    ( cd "$proj_dir" && "$(ant_cmd)" -Ddist="$run_dir" \
        -Djarsrc.web="$INSTALL_DIR/webserverextensions/www/WEB-INF/lib" \
        -Dmapguide.res.src="$MG_SRC_DIR/Common/MapGuideCommon/Resources/mapguide_en.res" \
        -Dmapguide.config.src="$MG_SRC_DIR/Web/src/webconfig.ini" \
        -f build.xml ) > "$build_log" 2>&1
    if [ "$?" -ne 0 ] || [ ! -f "$run_dir/MgUnitTest.jar" ]; then
        echo "Could not build the Java test runner; see $build_log" >> "$run_log"
        return 1
    fi
    # The sqlite4java native library ships in the runner's own directory; the Java glue library
    # is in the install.
    run_guarded "$run_dir" "$(java_cmd)" \
        -Djava.library.path="$run_dir:$INSTALL_DIR/webserverextensions/lib64" \
        -jar "$run_dir/MgUnitTest.jar" "$WEBCONFIG" "$run_dir/UnitTests.log" > "$run_log" 2>&1
}

# The server reads its WFS and WMS configuration documents from the directories that
# serverconfig.ini names in WfsDocumentPath/WmsDocumentPath. For a build tree those resolve to
# <build>/Server/src/Core/{Wfs,Wms}, but nothing in the build puts them there: Core/CMakeLists.txt
# copies Resources and Schema into the build tree, and Server/src/CMakeLists.txt only *installs*
# the two document directories, into <prefix>/server/{Wfs,Wms} for an installed server. A server
# run out of the build tree therefore answers every WFS and WMS request with
#   GetDocument.1.0.0:1(Wfs:OgcWfsService.config) Failure
#   The specified file was not found: <build>/Server/src/Core/Wfs/OgcWfsService.config.awd
# which is what every Wfs_*/Wms_* case in the web tier runner asserts on. Copy them in before any
# server starts; it is the same content the install target ships, taken from the sources the tree
# was configured against.
prepare_server_documents()
{
    copied=0
    for doc_dir in Wfs Wms; do
        src="$MG_SRC_DIR/Server/src/$doc_dir"
        dst="$CORE_DIR/$doc_dir"
        if [ ! -d "$src" ]; then
            if [ ! -d "$dst" ]; then
                echo "  >> WARNING: $src is missing, so $dst will be too; WFS/WMS requests will fail"
            fi
            continue
        fi
        mkdir -p "$dst" || return 1
        for doc in "$src"/*.awd; do
            if [ ! -f "$doc" ]; then
                continue
            fi
            doc_name=$(basename "$doc")
            # Only touch the build tree when the content actually differs, so a repeat run is
            # silent and does not re-stamp files the server has already read.
            if [ ! -f "$dst/$doc_name" ] || ! cmp -s "$doc" "$dst/$doc_name"; then
                cp -f "$doc" "$dst/$doc_name" || return 1
                copied=$((copied + 1))
            fi
        done
    done
    if [ "$copied" -ne 0 ]; then
        echo "  >> Copied $copied WFS/WMS service document(s) into $CORE_DIR"
    fi
    return 0
}

# Builds the C# side: the SWIG-generated sources from the glue build plus the checked-in managed
# sources, into a staged copy of the tree so neither the SVN working copy nor the source project
# directories are touched. The test projects reference the OSGeo.MapGuide packages by version, so
# they are pointed at the locally built projects instead - the point of the exercise is to run
# *these* assemblies against *these* glue libraries, not the published package.
prepare_dotnet_pack()
{
    glue_build="$(dotnet_common_build_dir)/Bindings/src/Bindings/DotNet"
    stage="$WEB_PACK/UnitTest/DotNet"
    managed="$stage/Bindings/src/Managed/DotNet"
    build_log="$WEB_LOG_PATH/dotnet_build.log"

    rm -rf "$stage"
    # The managed and test projects reach outside their own directories for License.txt,
    # mapguide_en.res and MgClassMap.cs, so the stage keeps the paths they use.
    mkdir -p "$stage/Bindings/src/Test" "$stage/Common/MapGuideCommon/Resources" || return 1
    cp -R "$MG_SRC_DIR/Bindings/src/Managed" "$stage/Bindings/src/Managed" || return 1
    cp -R "$MG_SRC_DIR/Bindings/src/Test/DotNet" "$stage/Bindings/src/Test/DotNet" || return 1
    cp "$MG_SRC_DIR/Common/MapGuideCommon/Resources/mapguide_en.res" \
        "$stage/Common/MapGuideCommon/Resources/" || return 1
    cp "$MG_SRC_DIR/License.txt" "$stage/" || return 1
    # Stale build output from a checkout made on Windows/another machine would shadow the new
    # sources.
    find "$stage" -type d \( -name obj -o -name bin \) -prune -exec rm -rf {} + 2>/dev/null

    for api in Foundation Geometry PlatformBase MapGuideCommon Web; do
        if [ ! -d "$glue_build/$api" ]; then
            echo "no generated C# for $api in $glue_build" >> "$build_log"
            return 1
        fi
        cp "$glue_build/$api"/*.cs "$managed/OSGeo.MapGuide.$api/" || return 1
    done

    for proj in "$stage/Bindings/src/Test/DotNet/src"/*/*.csproj; do
        for api in Foundation Geometry PlatformBase MapGuideCommon Web; do
            sed -i "s|<PackageReference Include=\"OSGeo.MapGuide.$api\" Version=\"4.0.0\" />|<ProjectReference Include=\"$managed/OSGeo.MapGuide.$api/OSGeo.MapGuide.$api.csproj\" />|" "$proj"
        done
    done

    echo "Building the .NET test runner" >> "$build_log"
    ( cd "$stage/Bindings/src/Test/DotNet" && \
        "$(dotnet_cmd)" build src/TestRunner/TestRunner.csproj -c Release ) >> "$build_log" 2>&1
    runner="$stage/Bindings/src/Test/DotNet/src/TestRunner/bin/Release/net6.0/TestRunner.dll"
    if [ ! -f "$runner" ]; then
        echo "  >> Could not build the .NET test runner; see $build_log" >&2
        return 1
    fi
    echo "$runner"
}

# Runs the .NET runner against the live server. Its options mirror the other binding runners:
# webconfig.ini, the CS-Map dictionary directory and the root of the test data.
run_web_dotnet()
{
    run_log="$1"
    runner=$(prepare_dotnet_pack) || return 1
    run_dir=$(dirname "$runner")
    # The C# P/Invokes lib<Api>UnmanagedApi.so by bare name, so the glue directory has to be
    # findable at load time; the runner writes its log relative to the working directory.
    run_guarded "$run_dir" env \
        LD_LIBRARY_PATH="$(dotnet_glue_install_dir)/lib64${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}" \
        MENTOR_DICTIONARY_PATH="$DICT_PATH" \
        DOTNET_ROLL_FORWARD=Major \
        "$(dotnet_cmd)" TestRunner.dll \
            --web-config-path "$WEBCONFIG" \
            --dictionary-path "$DICT_PATH" \
            --test-data-root "$WEB_PACK/UnitTest/TestData" \
            --log-path "$WEB_LOG_PATH/dotnet.log" > "$run_log" 2>&1
}

run_web_tier()
{
    WEB_LOG_PATH="$TEST_LOG_PATH/webtier"
    mkdir -p "$WEB_LOG_PATH" || return 1

    if [ -z "$INSTALL_DIR" ]; then
        INSTALL_DIR=$(cache_value MG_INSTALL_PREFIX)
    fi
    if [ -z "$MG_SRC_DIR" ]; then
        MG_SRC_DIR=$(cache_value CMAKE_HOME_DIRECTORY)
    fi
    # SWIG has to be the pinned build before anything is generated with it. `webtestrunner` is pure
    # C++ and needs none, so only the binding suites pay for the acquisition.
    if [ "$DO_INSTALL" -eq 1 ] && web_suites_need_swig; then
        if [ -z "$SWIG_BUILD_DIR" ]; then
            # The tarball is cached in the same place cmake_bootstrap.sh uses, so a container that
            # paid for the download once reuses it. It is container-local (only ccache is mounted
            # from the host), so point --swig-build-dir at a mounted path to keep it across
            # containers.
            SWIG_BUILD_DIR=/tmp/download
        fi
        build_swig || return 1
    fi
    # The install has to exist before the default webconfig.ini and the installed dictionaries
    # can be looked for.
    prepare_web_tier || return 1

    # build_thin.sh mounts artifacts/<conf> at /tmp/work/artifacts; that is where the release
    # tarball with the PHP interpreter is when the container is the interactive build one.
    if [ -z "$ARTIFACTS_DIR" ] && [ -d /tmp/work/artifacts ]; then
        ARTIFACTS_DIR=/tmp/work/artifacts
    fi
    case " $WEB_SUITES " in
        *" php "*) provision_php_interpreter || return 1 ;;
    esac
    case " $WEB_SUITES " in
        *" dotnet "*)
            if prepare_dotnet_glue; then
                DOTNET_GLUE_OK=1
            else
                echo "  >> the .NET suite cannot run in this container"
            fi
            ;;
    esac

    if [ -z "$WEBCONFIG" ]; then
        WEBCONFIG="$INSTALL_DIR/webserverextensions/www/webconfig.ini"
    fi
    if [ -z "$DICT_PATH" ] && [ -n "$MENTOR_DICTIONARY_PATH" ]; then
        DICT_PATH="$MENTOR_DICTIONARY_PATH"
    fi
    if [ -z "$DICT_PATH" ] && [ ! -f "$INSTALL_DIR/share/gis/coordsys/Coordsys.CSD" ]; then
        # Fall back to the dictionaries the server was configured with, which is what a build
        # tree has before it is installed.
        DICT_PATH=$(sed -n '/^\[GeneralProperties\]/,/^\[/p' "$CORE_DIR/serverconfig.ini" \
            | sed -n 's/^MentorDictionaryPath[[:space:]]*=[[:space:]]*//p' | head -1)
    fi
    if [ -z "$DICT_PATH" ]; then
        DICT_PATH="$INSTALL_DIR/share/gis/coordsys"
    fi
    if [ ! -f "$WEBCONFIG" ]; then
        echo "FATAL: web tier webconfig.ini not found: $WEBCONFIG"
        echo "It comes from the install; pass it with --webconfig-path or drop --no-install."
        return 1
    fi
    if [ ! -f "$DICT_PATH/Coordsys.CSD" ]; then
        echo "FATAL: CS-Map dictionaries not found in $DICT_PATH"
        echo "Pass the dictionary directory with --dictionary-path."
        return 1
    fi

    echo "Install prefix: $INSTALL_DIR"
    echo "Web config: $WEBCONFIG"
    echo "CS-Map dictionaries: $DICT_PATH"

    prepare_web_pack || return 1

    if [ "$RESET_REPOSITORY" -eq 1 ]; then
        echo "Resetting the server repository"
        rm -rf "$CORE_DIR/Repositories"
    fi

    # The suites and the server they talk to share one environment: the dictionaries, the test
    # data and the localization files are all resolved through it.
    export MENTOR_DICTIONARY_PATH="$DICT_PATH"
    export MG_TEST_WEBCONFIG_PATH="$WEBCONFIG"
    export MG_TEST_DATA_PATH="$WEB_PACK/UnitTest/TestData"
    export LC_CTYPE=C.UTF-8

    web_run=0
    for suite in $WEB_SUITES; do
        if [ "$INTERRUPTED" -ne 0 ]; then
            break
        fi

        reason=$(web_suite_unavailable_reason "$suite")
        if [ -n "$reason" ]; then
            if is_required_web_suite "$suite"; then
                echo "Web Suite ($suite) FAILED: $reason"
                FAILED_SUITES=$((FAILED_SUITES + 1))
                FAILED_COMPONENTS="$FAILED_COMPONENTS $suite"
            else
                echo "Web Suite ($suite) skipped: $reason"
                SKIPPED_SUITES="$SKIPPED_SUITES $suite"
                # Repeated in the summary: the reason scrolls away between the other suites' output,
                # and "Skipped suites: php" on its own is the question this line answers.
                SKIPPED_REASONS="$SKIPPED_REASONS\n  $suite: $reason"
            fi
            continue
        fi

        SERVER_LOG="$WEB_LOG_PATH/mapguide_server_$suite.log"
        suite_log="$WEB_LOG_PATH/$suite.log"
        echo "Running web suite: $suite"
        web_run=$((web_run + 1))

        if ! start_server "$SERVER_LOG"; then
            echo "  >> Web Suite ($suite) FAILED: the server did not start"
            FAILED_SUITES=$((FAILED_SUITES + 1))
            FAILED_COMPONENTS="$FAILED_COMPONENTS $suite"
            continue
        fi
        if [ "$INTERRUPTED" -ne 0 ]; then
            stop_suite
            break
        fi

        # Named distinctly from start_server's/stop_server's own counters: those are globals in this
        # script, so a shared name would be overwritten by the shutdown wait below.
        suite_start=$SECONDS
        # Truncate first: if the suite's preparation fails before it writes anything, the verdict
        # below must not read a previous run's summary out of this file.
        : > "$suite_log"
        case "$suite" in
            webtestrunner) run_web_webtestrunner "$suite_log" ;;
            php) run_web_php "$suite_log" ;;
            java) run_web_java "$suite_log" ;;
            dotnet) run_web_dotnet "$suite_log" ;;
        esac
        suite_rc=$?
        suite_elapsed=$((SECONDS - suite_start))

        # The server is stopped even when the suite failed, and its shutdown is part of the
        # verdict: a suite can pass and still leave a thread the shutdown wait hangs on.
        if stop_server "$SERVER_LOG"; then
            server_ok=1
        else
            server_ok=0
        fi

        if [ "$INTERRUPTED" -ne 0 ]; then
            echo "  >> Web Suite ($suite) interrupted after ${suite_elapsed}s - see $suite_log"
            break
        fi

        if [ "$suite" = "webtestrunner" ]; then
            if suite_passed "$suite_log"; then
                suite_ok=1
            else
                suite_ok=0
            fi
        else
            if binding_suite_passed "$suite_log"; then
                suite_ok=1
            else
                suite_ok=0
            fi
        fi

        if [ "$suite_ok" -eq 1 ] && [ "$server_ok" -eq 1 ]; then
            echo "  >> Web Suite ($suite) passed! (elapsed ${suite_elapsed}s)"
            suite_leaks=$(grep -E '^SUMMARY: AddressSanitizer:' "$suite_log" | tail -1)
            if [ -n "$suite_leaks" ]; then
                echo "  >>   LeakSanitizer reported leaks in the suite: ${suite_leaks#SUMMARY: AddressSanitizer: } - see $suite_log"
            fi
        else
            echo "  >> Web Suite ($suite) FAILED (exit $suite_rc, elapsed ${suite_elapsed}s)"
            if [ "$suite_ok" -eq 0 ]; then
                # A runner that echoes its summary to both the console and its own log writes it
                # twice into the same file; report each distinct line once.
                grep -E '^(Tests failed/run|test cases|assertions):' "$suite_log" | awk '!seen[$0]++' \
                    | tail -3 | while read -r line; do
                        echo "  >>   $line"
                    done
                if [ "$suite_rc" -eq 124 ]; then
                    echo "  >>   timed out after $WEB_RUN_TIMEOUT without reaching a summary"
                fi
            else
                # The suite's own assertions passed; what failed is the server it ran against,
                # which stop_server already reported against SERVER_LOG.
                echo "  >>   the suite's tests passed, but the server did not shut down cleanly - see $SERVER_LOG"
            fi
            echo "  >>   see $suite_log"
            FAILED_SUITES=$((FAILED_SUITES + 1))
            FAILED_COMPONENTS="$FAILED_COMPONENTS $suite"
        fi
    done

    RUN_SUITES=$((RUN_SUITES + web_run))
    return 0
}

if [ -z "$MG_BUILD_DIR" ]; then
    echo "FATAL: --mapguide-build-dir is required"
    usage
    exit 1
fi
# An explicit --php-path is an instruction, not a hint: silently falling back to discovery (and
# then to "skipped") would hide the typo.
if [ -n "$PHP_CMD" ] && [ ! -x "$PHP_CMD" ]; then
    echo "FATAL: --php-path $PHP_CMD is not an executable"
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
echo "Timeout per suite: $SUITE_TIMEOUT (server), $WEB_SUITE_TIMEOUT (web)"
echo "Tier: $TIER"
if [ "$RUN_MODE" -eq 1 ]; then
    echo "Components: (none - --run-mode runs the server itself)"
elif [ "$TIER" != "web" ]; then
    echo "Components: $COMPONENTS"
fi
if [ "$TIER" != "server" ]; then
    echo "Web suites: $WEB_SUITES"
fi
if [ ! -d "$TEST_LOG_PATH" ]; then
    mkdir -p "$TEST_LOG_PATH"
fi

cd "$MG_BUILD_DIR/Server/src/Core" || exit 1
CORE_DIR=$(pwd)
if [ ! -x ./mgserver ]; then
    echo "FATAL: $MG_BUILD_DIR/Server/src/Core/mgserver is missing"
    echo "Build it with /tmp/work/scripts/build_mapguide_incremental.sh"
    exit 1
fi
if [ "$TIER" != "web" ] && [ ! -f "$MG_BUILD_DIR/Server/src/UnitTesting/libMgUnitTesting.so" ]; then
    echo "FATAL: libMgUnitTesting.so is missing from the build tree"
    echo "Build it with /tmp/work/scripts/build_mapguide_incremental.sh --target MgUnitTesting"
    exit 1
fi

if [ -z "$MG_SRC_DIR" ]; then
    MG_SRC_DIR=$(cache_value CMAKE_HOME_DIRECTORY)
fi
if [ -n "$MG_SRC_DIR" ]; then
    prepare_server_documents || exit 1
fi

if [ "$RUN_MODE" -eq 1 ]; then
    if [ "$COMPONENTS_SET" -ne 0 ]; then
        echo "FATAL: --run-mode runs the server, not a suite; do not combine it with --component"
        exit 1
    fi
    if [ "$TIER" != "server" ]; then
        echo "FATAL: --run-mode runs the server, not a test suite; do not combine it with --tier"
        exit 1
    fi
    if run_server_mode; then
        echo "Run-mode check passed"
        exit 0
    fi
    echo "Run-mode check FAILED"
    exit 1
fi

if [ "$TIER" = "server" ] || [ "$TIER" = "all" ]; then
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
        comp_start=$SECONDS
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
        comp_elapsed=$((SECONDS - comp_start))
        RUN_SUITES=$((RUN_SUITES + 1))

        if [ "$INTERRUPTED" -ne 0 ]; then
            echo "  >> Test Suite ($comp) interrupted after ${comp_elapsed}s - see $TEST_LOG"
            if [ -f "$RESULT_XML" ]; then
                mv "$RESULT_XML" "$TEST_LOG_PATH/$RESULT_XML"
            fi
            break
        fi

        leak_summary=$(grep -E '^SUMMARY: AddressSanitizer:' "$TEST_LOG" | tail -1)
        if suite_passed "$TEST_LOG"; then
            echo "  >> Test Suite ($comp) passed! (elapsed ${comp_elapsed}s)"
            if [ -n "$leak_summary" ]; then
                echo "  >>   LeakSanitizer reported leaks: ${leak_summary#SUMMARY: AddressSanitizer: } - see $TEST_LOG"
            fi
            if [ "$rc" -eq 124 ]; then
                echo "  >>   (passed, then hung in exit-time teardown - see docs/fdo-exit-teardown.md)"
            elif [ "$rc" -ne 0 ] && [ -z "$leak_summary" ]; then
                echo "  >>   (passed, then exited $rc in exit-time teardown - see docs/fdo-exit-teardown.md)"
            fi
        else
            echo "  >> Test Suite ($comp) FAILED (exit $rc, elapsed ${comp_elapsed}s)"
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
fi

if [ "$TIER" = "web" ] || [ "$TIER" = "all" ]; then
    echo
    run_web_tier || exit 1
fi

echo "Suites run: $RUN_SUITES, failed: $FAILED_SUITES (total $((SECONDS - TOTAL_START))s)"
if [ -n "$SKIPPED_SUITES" ]; then
    echo "Skipped suites:$SKIPPED_SUITES"
    printf "%b\n" "$SKIPPED_REASONS"
fi
if [ "$INTERRUPTED" -ne 0 ]; then
    echo "Interrupted - remaining suites were not run"
    exit "$INTERRUPTED"
fi
if [ "$FAILED_SUITES" -ne 0 ]; then
    echo "Failed suites:$FAILED_COMPONENTS"
    exit 1
fi
