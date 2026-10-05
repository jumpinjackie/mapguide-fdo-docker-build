#!/bin/bash

TEST_FDOCORE=1
TEST_SDF=1
TEST_SQLITE=1
TEST_OGR=1
TEST_GDAL=1
TEST_SHP=1
TEST_WMS=0
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
  fi
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
            echo "  --with-oracle [Run Oracle Tests]"
            echo "  --with-odbc-init [Run ODBC Tests against provided init file]"
            echo "  --with-mysql-init [Run MySQL Tests against provided init file]"
            echo "  --with-postgis-init [Run PostGIS Tests against provided init file]"
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

# Needed for some SHP test cases
locale-gen ja_JP.EUC-JP
update-locale

echo "Starting unit tests"

if [ "$TEST_FDOCORE" == "1" ];
then
    pushd Fdo/UnitTest >& /dev/null
    start_suite "FDO Core"
    ./UnitTest >& $TEST_LOG_PATH/Fdo_unit_test_log.txt
    check_for_errors $? "Fdo unit test returned an error, please check $TEST_LOG_PATH/Fdo_unit_test_log.txt for more information" "0"
    popd >& /dev/null
fi

if [ "$TEST_SDF" == "1" ];
then
    pushd Providers/SDF/Src/UnitTest >& /dev/null
    start_suite "SDF"
    ./UnitTest >& $TEST_LOG_PATH/Sdf_unit_test_log.txt
    check_for_errors $? "Sdf unit test returned an error, please check $TEST_LOG_PATH/Sdf_unit_test_log.txt for more information" "0"
    popd >& /dev/null
fi

if [ "$TEST_SQLITE" == "1" ];
then
    pushd Providers/SQLite/Src/UnitTest >& /dev/null
    start_suite "SQLite"
    ./UnitTest >& $TEST_LOG_PATH/SQLite_unit_test_log.txt
    check_for_errors $? "SQLite unit test returned an error, please check $TEST_LOG_PATH/SQLite_unit_test_log.txt for more information" "0"
    popd >& /dev/null
fi

if [ "$TEST_OGR" == "1" ];
then
    pushd Providers/OGR/Src/UnitTest >& /dev/null
    start_suite "OGR"
    ./UnitTest >& $TEST_LOG_PATH/OGR_unit_test_log.txt
    check_for_errors $? "OGR unit test returned an error, please check $TEST_LOG_PATH/OGR_unit_test_log.txt for more information" "0"
    popd >& /dev/null
fi

if [ "$TEST_WMS" == "1" ];
then
    pushd Providers/WMS/Src/UnitTest >& /dev/null
    start_suite "WMS"
    ./UnitTest >& $TEST_LOG_PATH/Wms_unit_test_log.txt
    check_for_errors $? "Wms unit test returned an error, please check $TEST_LOG_PATH/Wms_unit_test_log.txt for more information" "0"
    popd >& /dev/null
fi

if [ -f "$TEST_ODBC" ];
then
    pushd Providers/GenericRdbms/Src/UnitTest >& /dev/null
    start_suite "ODBC"
    ./UnitTestOdbc initfiletest=$TEST_ODBC >& $TEST_LOG_PATH/Odbc_unit_test_log.txt
    check_for_errors $? "Odbc unit test returned an error, please check $TEST_LOG_PATH/Odbc_unit_test_log.txt for more information" "0"
    popd >& /dev/null
fi

if [ -f "$TEST_POSTGIS" ];
then
    pushd Providers/GenericRdbms/Src/UnitTest >& /dev/null
    start_suite "PostGIS"
    ./UnitTestPostGis initfiletest=$TEST_POSTGIS >& $TEST_LOG_PATH/PostGis_unit_test_log.txt
    check_for_errors $? "PostGis unit test returned an error, please check $TEST_LOG_PATH/PostGis_unit_test_log.txt for more information" "0"
    popd >& /dev/null
fi

if [ -f "$TEST_MYSQL" ];
then
    pushd Providers/GenericRdbms/Src/UnitTest >& /dev/null
    start_suite "MySQL"
    ./UnitTestMySql initfiletest=$TEST_MYSQL >& $TEST_LOG_PATH/MySql_unit_test_log.txt
    check_for_errors $? "MySql unit test returned an error, please check $TEST_LOG_PATH/MySql_unit_test_log.txt for more information" "0"
    popd >& /dev/null
fi

if [ "$TEST_ORACLE" == "1" ];
then
    pushd Providers/KingOracle/src/KgOraUnitTest >& /dev/null
    start_suite "King Oracle"
    ./UnitTest >& $TEST_LOG_PATH/Oracle_unit_test_log.txt
    check_for_errors $? "Oracle unit test returned an error, please check $TEST_LOG_PATH/Oracle_unit_test_log.txt for more information" "0"
    popd >& /dev/null
fi

# These suites need FDO installed at the default location in order to run
export LD_LIBRARY_PATH=/usr/local/fdo-4.2.0/lib64

if [ "$TEST_GDAL" == "1" ];
then
    pushd Providers/GDAL/Src/UnitTest >& /dev/null
    rm providers.xml # Having this local copy sadly doesn't work, so remove it
    start_suite "GDAL"
    ./UnitTest >& $TEST_LOG_PATH/GDAL_unit_test_log.txt
    check_for_errors $? "GDAL unit test returned an error, please check $TEST_LOG_PATH/GDAL_unit_test_log.txt for more information" "0"
    popd >& /dev/null
fi

if [ "$TEST_SHP" == "1" ];
then
    pushd Providers/SHP/Src/UnitTest >& /dev/null
    rm providers.xml # Having this local copy sadly doesn't work, so remove it
    start_suite "SHP"
    ./UnitTest >& $TEST_LOG_PATH/Shp_unit_test_log.txt
    check_for_errors $? "Shp unit test returned an error, please check $TEST_LOG_PATH/Shp_unit_test_log.txt for more information" "0"
    popd >& /dev/null
fi

echo "End unit tests..."
echo "Total elapsed time: $(format_elapsed $((SECONDS - SCRIPT_START)))"

if [ "$TEST_FAILURE_COUNT" -ne "0" ];
then
    echo "$TEST_FAILURE_COUNT tests failed in total"
    exit $TEST_FAILURE_COUNT
fi