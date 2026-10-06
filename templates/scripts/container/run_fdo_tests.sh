#!/bin/bash

TEST_FDOCORE=1
TEST_SDF=1
TEST_SQLITE=1
TEST_OGR=1
TEST_GDAL=1
TEST_SHP=1
TEST_WMS=0
TEST_WFS=0
TEST_ODBC=
TEST_MYSQL=
TEST_POSTGIS=
TEST_ORACLE=0
TEST_LOG_PATH=$(pwd)

TEST_SUITE_NAME=
TEST_SUITE_START=$SECONDS
TEST_FAILURE_COUNT=0
FDO_BUILD_DIR=
SCRIPT_START=$SECONDS

check_for_errors()
{
  # $ 1 is the return code
  # $ 2 is text to display on failure.
  # $ 3 is whether to count the failure towards the script's exit status.
  # $ 4 is the suite's log file (optional; it tells a LeakSanitizer report apart from a test failure).
  if [ "${1}" -ne "0" ] && [ -n "${4}" ] && log_is_successful "${4}" && log_has_leak_report "${4}"; then
    # Every test passed, so all LeakSanitizer did was make the binary exit non-zero to draw
    # attention to its report. Say so, but do not fail the suite: the report is the point of
    # these instrumented Debug builds, and a run that only reports leaks is still a passing run.
    echo "  >> Test Suite ($TEST_SUITE_NAME) passed! (elapsed $(format_elapsed $((SECONDS - TEST_SUITE_START))))"
    echo "  >>   LeakSanitizer reported leaks: $(log_leak_summary "${4}") - see ${4}"
    echo "  >>   (exit code ${1} is the leak report, not a test failure)"
    return
  fi
  if [ "${1}" -ne "0" ]; then
    echo "  >> ERROR # ${1} : ${2}"
    if [ "${3}" -ne "0" ]; then
      # make our script exit with the right error code.
      #exit ${1}
      FAIL_COUNT=${1}
      TEST_FAILURE_COUNT=$((TEST_FAILURE_COUNT + FAIL_COUNT))
      echo "  >> Test Suite ($TEST_SUITE_NAME) has $FAIL_COUNT test failures (elapsed $(format_elapsed $((SECONDS - TEST_SUITE_START))))"
    fi
  else
    echo "  >> Test Suite ($TEST_SUITE_NAME) passed! (elapsed $(format_elapsed $((SECONDS - TEST_SUITE_START))))"
    if [ -n "${4}" ] && log_has_leak_report "${4}"; then
      echo "  >>   LeakSanitizer reported leaks: $(log_leak_summary "${4}") - see ${4}"
    fi
  fi
}

# Does the suite's log show a passing run? CppUnit prints "OK (<n>)" (or "OK (<n> tests)") when
# every test passed, and a "Failures !!!" block instead when they did not.
log_is_successful()
{
  [ -f "${1}" ] && grep -qE '(^|[[:space:]])OK \(' "${1}"
}

# Did LeakSanitizer report leaks in the suite's log? Its report always ends with a SUMMARY line.
log_has_leak_report()
{
  [ -f "${1}" ] && grep -qE '^SUMMARY: [A-Za-z]+Sanitizer: .*leaked' "${1}"
}

# The leak totals from the suite's LeakSanitizer report, e.g. "220980 byte(s) leaked in 2418 allocation(s)."
log_leak_summary()
{
  sed -n 's/^SUMMARY: [A-Za-z]*Sanitizer: //p' "${1}" 2> /dev/null | head -1
}

format_elapsed()
{
  # Formats a number of seconds (parameter 1) as a human readable duration
  local secs="${1}"

  if [ "$secs" -ge 3600 ]; then
    echo "$((secs / 3600))h $(((secs % 3600) / 60))m $((secs % 60))s"
  elif [ "$secs" -ge 60 ]; then
    echo "$((secs / 60))m $((secs % 60))s"
  else
    echo "${secs}s"
  fi
}

start_suite()
{
  # $ 1 is the suite name to display and report against
  TEST_SUITE_NAME="${1}"
  TEST_SUITE_START=$SECONDS
  echo "Running suite: $TEST_SUITE_NAME"
}

while [ $# -gt 0 ]; do    # Until you run out of parameters...
    case "$1" in
        --fdo-build-dir)
            FDO_BUILD_DIR="$2"
            shift
            ;;
        --log-path)
            TEST_LOG_PATH="$2"
            shift
            ;;
        --with-wms)
            TEST_WMS=1
            ;;
        --with-wfs)
            TEST_WFS=1
            ;;
        --with-odbc-init)
            TEST_ODBC="$2"
            shift
            ;;
        --with-mysql-init)
            TEST_MYSQL="$2"
            shift
            ;;
        --with-postgis-init)
            TEST_POSTGIS="$2"
            shift
            ;;
        --with-oracle)
            TEST_ORACLE=1
            ;;
        --with-fdocore)
            TEST_FDOCORE=1
            ;;
        --with-sdf)
            TEST_SDF=1
            ;;
        --with-sqlite)
            TEST_SQLITE=1
            ;;
        --with-ogr)
            TEST_OGR=1
            ;;
        --with-gdal)
            TEST_GDAL=1
            ;;
        --with-shp)
            TEST_SHP=1
            ;;
        --without-fdocore)
            TEST_FDOCORE=0
            ;;
        --without-sdf)
            TEST_SDF=0
            ;;
        --without-sqlite)
            TEST_SQLITE=0
            ;;
        --without-ogr)
            TEST_OGR=0
            ;;
        --without-gdal)
            TEST_GDAL=0
            ;;
        --without-shp)
            TEST_SHP=0
            ;;
        --no-default-suites)
            TEST_FDOCORE=0
            TEST_SDF=0
            TEST_SQLITE=0
            TEST_OGR=0
            TEST_GDAL=0
            TEST_SHP=0
            ;;
        --help)
            echo "Usage: $0 (options)"
            echo "Options:"
            echo "  --fdo-build-dir [FDO build dir]"
            echo "  --log-path [Unit Test log path]"
            echo "  --with-wms [Run WMS Tests]"
            echo "  --with-wfs [Run WFS Tests]"
            echo "  --with-oracle [Run Oracle Tests]"
            echo "  --with-odbc-init [Run ODBC Tests against provided init file]"
            echo "  --with-mysql-init [Run MySQL Tests against provided init file]"
            echo "  --with-postgis-init [Run PostGIS Tests against provided init file]"
            echo "  --with-fdocore [Run the FDO Core suite]"
            echo "  --with-sdf [Run the SDF suite]"
            echo "  --with-sqlite [Run the SQLite suite]"
            echo "  --with-ogr [Run the OGR suite]"
            echo "  --with-gdal [Run the GDAL suite]"
            echo "  --with-shp [Run the SHP suite]"
            echo "  --without-fdocore [Skip the FDO Core suite]"
            echo "  --without-sdf [Skip the SDF suite]"
            echo "  --without-sqlite [Skip the SQLite suite]"
            echo "  --without-ogr [Skip the OGR suite]"
            echo "  --without-gdal [Skip the GDAL suite]"
            echo "  --without-shp [Skip the SHP suite]"
            echo "  --no-default-suites [Skip the FDO Core, SDF, SQLite, OGR, GDAL and SHP suites]"
            echo "  --help [Display usage]"
            exit
            ;;
    esac
    shift   # Check next set of parameters.
done

# Warn about missing init files up front, so a mistyped path is not silently skipped
[ -n "$TEST_ODBC" ] && [ ! -f "$TEST_ODBC" ] && echo "WARNING: ODBC init file not found: $TEST_ODBC (suite will be skipped)"
[ -n "$TEST_POSTGIS" ] && [ ! -f "$TEST_POSTGIS" ] && echo "WARNING: PostGIS init file not found: $TEST_POSTGIS (suite will be skipped)"
[ -n "$TEST_MYSQL" ] && [ ! -f "$TEST_MYSQL" ] && echo "WARNING: MySQL init file not found: $TEST_MYSQL (suite will be skipped)"

# Bail out early if nothing is selected, otherwise the run would silently do nothing
SELECTED_SUITES=0
[ "$TEST_FDOCORE" == "1" ] && SELECTED_SUITES=$((SELECTED_SUITES + 1))
[ "$TEST_SDF" == "1" ] && SELECTED_SUITES=$((SELECTED_SUITES + 1))
[ "$TEST_SQLITE" == "1" ] && SELECTED_SUITES=$((SELECTED_SUITES + 1))
[ "$TEST_OGR" == "1" ] && SELECTED_SUITES=$((SELECTED_SUITES + 1))
[ "$TEST_WMS" == "1" ] && SELECTED_SUITES=$((SELECTED_SUITES + 1))
[ "$TEST_WFS" == "1" ] && SELECTED_SUITES=$((SELECTED_SUITES + 1))
[ "$TEST_GDAL" == "1" ] && SELECTED_SUITES=$((SELECTED_SUITES + 1))
[ "$TEST_SHP" == "1" ] && SELECTED_SUITES=$((SELECTED_SUITES + 1))
[ "$TEST_ORACLE" == "1" ] && SELECTED_SUITES=$((SELECTED_SUITES + 1))
[ -f "$TEST_ODBC" ] && SELECTED_SUITES=$((SELECTED_SUITES + 1))
[ -f "$TEST_POSTGIS" ] && SELECTED_SUITES=$((SELECTED_SUITES + 1))
[ -f "$TEST_MYSQL" ] && SELECTED_SUITES=$((SELECTED_SUITES + 1))

if [ "$SELECTED_SUITES" -eq 0 ]; then
    echo "ERROR: No test suites selected, nothing to run."
    echo "The FDO Core, SDF, SQLite, OGR, GDAL and SHP suites run by default; add a --with-* flag for an optional suite, or drop the --without-*/--no-default-suites flags."
    exit 1
fi

echo "FDO build dir: $FDO_BUILD_DIR"
echo "Log path is: $TEST_LOG_PATH"
if [ ! -d "$TEST_LOG_PATH" ]; then
    mkdir -p $TEST_LOG_PATH
fi
cd $FDO_BUILD_DIR || exit

# Without this the NLS message catalogues are not found and every localized message falls back to
# its raw symbol name (e.g. FDOSM_220) instead of its English text, which breaks the message
# assertions in the provider suites. The host wrappers (env_test.sh/env_test_thin.sh) pass this in
# when they run us, but a hand-run inside an interactive container has nobody to do it, so default
# it to the catalogues in the build tree.
if [ -z "$NLSPATH" ]; then
    NLSPATH="$(pwd)/nls/linux/en_US/%N"
    export NLSPATH
    NLSPATH_DEFAULTED=1
    if [ ! -d "$(pwd)/nls/linux/en_US" ]; then
        echo "WARNING: $(pwd)/nls/linux/en_US does not exist, localized messages will not resolve"
    fi
fi

echo "NLSPATH: $NLSPATH${NLSPATH_DEFAULTED:+ (defaulted by this script)}"

# Some suites (GDAL, SHP) just cannot be run from their built location, so they need FDO to be at its
# installed location
INSTALL_START=$SECONDS
cmake --build . --target install
echo "FDO install completed in $(format_elapsed $((SECONDS - INSTALL_START)))"

# The SHP suite's locale test round-trips values through locale-specific encodings, so every locale
# it switches to with setlocale() has to exist: en_US.iso88591, en_US.utf8, fr_FR.iso88591 and
# ja_JP.eucjp. Debian's locale-gen spells the ISO-8859-1 variants without a codeset suffix (en_US,
# fr_FR), and only ja_JP.EUC-JP used to be generated, which left the fr_FR.iso88591 case -- the only
# one using a non-ASCII value -- failing.
locale-gen en_US en_US.UTF-8 fr_FR ja_JP.EUC-JP
update-locale

echo "Starting unit tests"

if [ "$TEST_FDOCORE" == "1" ];
then
    pushd Fdo/UnitTest >& /dev/null
    start_suite "FDO Core"
    ./UnitTest >& $TEST_LOG_PATH/Fdo_unit_test_log.txt
    check_for_errors $? "Fdo unit test returned an error, please check $TEST_LOG_PATH/Fdo_unit_test_log.txt for more information" "0" "$TEST_LOG_PATH/Fdo_unit_test_log.txt"
    popd >& /dev/null
fi

if [ "$TEST_SDF" == "1" ];
then
    pushd Providers/SDF/Src/UnitTest >& /dev/null
    start_suite "SDF"
    ./UnitTest >& $TEST_LOG_PATH/Sdf_unit_test_log.txt
    check_for_errors $? "Sdf unit test returned an error, please check $TEST_LOG_PATH/Sdf_unit_test_log.txt for more information" "0" "$TEST_LOG_PATH/Sdf_unit_test_log.txt"
    popd >& /dev/null
fi

if [ "$TEST_SQLITE" == "1" ];
then
    pushd Providers/SQLite/Src/UnitTest >& /dev/null
    start_suite "SQLite"
    ./UnitTest >& $TEST_LOG_PATH/SQLite_unit_test_log.txt
    check_for_errors $? "SQLite unit test returned an error, please check $TEST_LOG_PATH/SQLite_unit_test_log.txt for more information" "0" "$TEST_LOG_PATH/SQLite_unit_test_log.txt"
    popd >& /dev/null
fi

if [ "$TEST_OGR" == "1" ];
then
    pushd Providers/OGR/Src/UnitTest >& /dev/null
    start_suite "OGR"
    ./UnitTest >& $TEST_LOG_PATH/OGR_unit_test_log.txt
    check_for_errors $? "OGR unit test returned an error, please check $TEST_LOG_PATH/OGR_unit_test_log.txt for more information" "0" "$TEST_LOG_PATH/OGR_unit_test_log.txt"
    popd >& /dev/null
fi

if [ "$TEST_WMS" == "1" ];
then
    pushd Providers/WMS/Src/UnitTest >& /dev/null
    start_suite "WMS"
    ./UnitTest >& $TEST_LOG_PATH/Wms_unit_test_log.txt
    check_for_errors $? "Wms unit test returned an error, please check $TEST_LOG_PATH/Wms_unit_test_log.txt for more information" "0" "$TEST_LOG_PATH/Wms_unit_test_log.txt"
    popd >& /dev/null
fi

if [ "$TEST_WFS" == "1" ];
then
    pushd Providers/WFS/Src/UnitTest >& /dev/null
    start_suite "WFS"
    ./UnitTest >& $TEST_LOG_PATH/Wfs_unit_test_log.txt
    check_for_errors $? "Wfs unit test returned an error, please check $TEST_LOG_PATH/Wfs_unit_test_log.txt for more information" "0" "$TEST_LOG_PATH/Wfs_unit_test_log.txt"
    popd >& /dev/null
fi

if [ -f "$TEST_ODBC" ];
then
    pushd Providers/GenericRdbms/Src/UnitTest >& /dev/null
    start_suite "ODBC"
    ./UnitTestOdbc initfiletest=$TEST_ODBC >& $TEST_LOG_PATH/Odbc_unit_test_log.txt
    check_for_errors $? "Odbc unit test returned an error, please check $TEST_LOG_PATH/Odbc_unit_test_log.txt for more information" "0" "$TEST_LOG_PATH/Odbc_unit_test_log.txt"
    popd >& /dev/null
fi

if [ -f "$TEST_POSTGIS" ];
then
    pushd Providers/GenericRdbms/Src/UnitTest >& /dev/null
    start_suite "PostGIS"
    ./UnitTestPostGis initfiletest=$TEST_POSTGIS >& $TEST_LOG_PATH/PostGis_unit_test_log.txt
    check_for_errors $? "PostGis unit test returned an error, please check $TEST_LOG_PATH/PostGis_unit_test_log.txt for more information" "0" "$TEST_LOG_PATH/PostGis_unit_test_log.txt"
    popd >& /dev/null
fi

if [ -f "$TEST_MYSQL" ];
then
    pushd Providers/GenericRdbms/Src/UnitTest >& /dev/null
    start_suite "MySQL"
    ./UnitTestMySql initfiletest=$TEST_MYSQL >& $TEST_LOG_PATH/MySql_unit_test_log.txt
    check_for_errors $? "MySql unit test returned an error, please check $TEST_LOG_PATH/MySql_unit_test_log.txt for more information" "0" "$TEST_LOG_PATH/MySql_unit_test_log.txt"
    popd >& /dev/null
fi

if [ "$TEST_ORACLE" == "1" ];
then
    # The King Oracle provider is linked against the Oracle Instant Client under sdks/, and the
    # build baked that absolute container path into the provider's RUNPATH (ORACLE_LIBRARY_CLNTSH
    # in the CMake cache is what it was configured with). A RUNPATH only resolves an object's own
    # dependencies, so libclntsh.so.12.1's dependencies (libmql1, libipc1, libnnz12, libons -- all
    # sitting next to it in the same directory) still have to be found on LD_LIBRARY_PATH.
    # Without it the suite does not even start: "libmql1.so: cannot open shared object file".
    oracle_lib_dir=$(sed -n 's/^ORACLE_LIBRARY_CLNTSH:FILEPATH=//p' CMakeCache.txt 2> /dev/null)
    oracle_lib_dir=${oracle_lib_dir%/*}
    if [ -z "$oracle_lib_dir" ] || [ ! -d "$oracle_lib_dir" ]; then
        echo "  >> WARNING: Oracle Instant Client not found (ORACLE_LIBRARY_CLNTSH in CMakeCache.txt points at '$oracle_lib_dir'), the suite will fail to load libclntsh"
    fi
    # OCI needs libaio, which the develop images install; check anyway, as the suite may be running
    # in a different image (a _build_ image built before that dependency was added, for instance)
    if ! ldconfig -p 2> /dev/null | grep -q 'libaio\.so\.1'; then
        echo "  >> WARNING: libaio.so.1 is not installed in this image, the Oracle client cannot load without it (apt-get install -y libaio1)"
    fi
    # The suite opens connections both from a full connection string (KG_DEFAULT_ORA_CONNECTION) and
    # from a username/password/service triplet (KG_ORA_*), and the King Oracle README in the FDO
    # sources documents that all of them have to be set together. Point them at the Oracle XE the
    # dbs compose stack publishes on the host, the same way the PostGIS and MySQL init files reach
    # theirs, and leave anything already exported alone so another instance can still be targeted.
    fdo_src_dir=$(sed -n 's/^CMAKE_HOME_DIRECTORY:INTERNAL=//p' CMakeCache.txt 2> /dev/null)
    KG_ORA_SERVICE=${KG_ORA_SERVICE:-"//host.docker.internal:1521/xe"}
    KG_ORA_USERNAME=${KG_ORA_USERNAME:-"fdounittest"}
    if [ -z "$KG_ORA_PASSWORD" ]; then
        # The credentials the suite expects are the ones its own fixture creates, so read the password
        # out of ora_init.sql rather than keeping a copy of it here.
        ora_init_sql="$fdo_src_dir/Providers/KingOracle/src/KgOraUnitTest/ora_init.sql"
        KG_ORA_PASSWORD=$(grep -oE 'IDENTIFIED BY[[:space:]]+[^;"[:space:]]+' "$ora_init_sql" 2> /dev/null | head -1 | awk '{print $NF}')
    fi
    export KG_ORA_SERVICE
    export KG_ORA_USERNAME
    if [ -n "$KG_ORA_PASSWORD" ]; then
        export KG_ORA_PASSWORD
        KG_DEFAULT_ORA_CONNECTION="Username=$KG_ORA_USERNAME;Password=$KG_ORA_PASSWORD;Service=$KG_ORA_SERVICE;OracleSchema=$KG_ORA_USERNAME"
        export KG_DEFAULT_ORA_CONNECTION
    else
        echo "  >> WARNING: no Oracle password found in $ora_init_sql, the suite will fall back to its built-in defaults (which point at localhost)"
    fi
    echo "  >> Oracle instance: $KG_ORA_SERVICE as $KG_ORA_USERNAME"
    ora_hostport=${KG_ORA_SERVICE#//}
    ora_hostport=${ora_hostport%%/*}
    ora_host=${ora_hostport%%:*}
    ora_port=${ora_hostport##*:}
    case "$ora_port" in
        ''|*[!0-9]*)
            ;;
        *)
            if command -v timeout > /dev/null 2>&1 && ! timeout 2 bash -c "exec 3<>/dev/tcp/$ora_host/$ora_port" 2> /dev/null; then
                echo "  >> WARNING: nothing is listening on $ora_hostport (is the dbs compose stack up?)"
            fi
            ;;
    esac
    pushd Providers/KingOracle/src/KgOraUnitTest >& /dev/null
    start_suite "King Oracle"
    LD_LIBRARY_PATH="$oracle_lib_dir${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}" ./KgOraUnitTest >& $TEST_LOG_PATH/Oracle_unit_test_log.txt
    check_for_errors $? "Oracle unit test returned an error, please check $TEST_LOG_PATH/Oracle_unit_test_log.txt for more information" "0" "$TEST_LOG_PATH/Oracle_unit_test_log.txt"
    popd >& /dev/null
fi

# These suites need FDO installed at the default location in order to run
export LD_LIBRARY_PATH=/usr/local/fdo-4.2.0/lib64

if [ "$TEST_GDAL" == "1" ];
then
    pushd Providers/GDAL/Src/UnitTest >& /dev/null
    [ -f providers.xml ] && rm providers.xml # Having this local copy sadly doesn't work, so remove it
    start_suite "GDAL"
    ./UnitTest >& $TEST_LOG_PATH/GDAL_unit_test_log.txt
    check_for_errors $? "GDAL unit test returned an error, please check $TEST_LOG_PATH/GDAL_unit_test_log.txt for more information" "0" "$TEST_LOG_PATH/GDAL_unit_test_log.txt"
    popd >& /dev/null
fi

if [ "$TEST_SHP" == "1" ];
then
    # This suite creates filesets under TestData and opens them with IDF_CREATE_NEW (which fails if
    # the file is already there), so it is sensitive to whatever an earlier run left behind.
    # TestData/clean (shipped with the FDO sources) only removes *Generated.*, *.idx, schema.xml and
    # Testing/, leaving e.g. TestingSC/, InsertTest_default_values/ and the sidecars some tests create
    # inside the shipped data directories. Restoring the whole tree from the sources this build was
    # configured against instead always starts the suite in the state a fresh build has.
    fdo_src_dir=$(sed -n 's/^CMAKE_HOME_DIRECTORY:INTERNAL=//p' CMakeCache.txt 2> /dev/null)
    pushd Providers/SHP/Src/UnitTest >& /dev/null
    [ -f providers.xml ] && rm providers.xml # Having this local copy sadly doesn't work, so remove it
    if [ -n "$fdo_src_dir" ] && [ -d "$fdo_src_dir/Providers/SHP/TestData" ]; then
        rm -rf ../../TestData
        cp -a "$fdo_src_dir/Providers/SHP/TestData" ../../
    else
        echo "WARNING: unable to locate the SHP TestData sources (see $fdo_src_dir), falling back to TestData/clean"
        [ -f ../../TestData/clean ] && sh ../../TestData/clean
    fi
    start_suite "SHP"
    ./UnitTest >& $TEST_LOG_PATH/Shp_unit_test_log.txt
    check_for_errors $? "Shp unit test returned an error, please check $TEST_LOG_PATH/Shp_unit_test_log.txt for more information" "0" "$TEST_LOG_PATH/Shp_unit_test_log.txt"
    popd >& /dev/null
fi

echo "End unit tests..."
echo "Total elapsed time: $(format_elapsed $((SECONDS - SCRIPT_START)))"

if [ "$TEST_FAILURE_COUNT" -ne "0" ];
then
    echo "$TEST_FAILURE_COUNT tests failed in total"
    exit $TEST_FAILURE_COUNT
fi