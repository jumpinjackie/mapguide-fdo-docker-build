#!/bin/bash

TEST_WMS=0
TEST_ODBC=
TEST_MYSQL=
TEST_POSTGIS=
TEST_ORACLE=0
TEST_LOG_PATH=$(pwd)

TEST_SUITE_NAME=
TEST_FAILURE_COUNT=0
FDO_BUILD_DIR=

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
      echo "  >> Test Suite ($TEST_SUITE_NAME) has $FAIL_COUNT test failures"
    fi
  else
    echo "  >> Test Suite ($TEST_SUITE_NAME) passed!"
  fi
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
            echo "  --help [Display usage]"
            exit
            ;;
    esac
    shift   # Check next set of parameters.
done

echo "FDO build dir: $FDO_BUILD_DIR"
echo "NLSPATH: $NLSPATH"
echo "Log path is: $TEST_LOG_PATH"
if [ ! -d "$TEST_LOG_PATH" ]; then
    mkdir -p $TEST_LOG_PATH
fi
cd $FDO_BUILD_DIR || exit

# Some suites (GDAL, SHP) just cannot be run from their built location, so they need FDO to be at its
# installed location
cmake --build . --target install

# Needed for some SHP test cases
locale-gen ja_JP.EUC-JP
update-locale

echo "Starting unit tests"

pushd Fdo/UnitTest >& /dev/null
TEST_SUITE_NAME="FDO Core"
echo "Running suite: $TEST_SUITE_NAME"
./UnitTest >& $TEST_LOG_PATH/Fdo_unit_test_log.txt
check_for_errors $? "Fdo unit test returned an error, please check Fdo_unit_test_log.txt for more information" "0"
popd >& /dev/null

pushd Providers/SDF/Src/UnitTest >& /dev/null
TEST_SUITE_NAME="SDF"
echo "Running suite: $TEST_SUITE_NAME"
./UnitTest >& $TEST_LOG_PATH/Sdf_unit_test_log.txt
check_for_errors $? "Sdf unit test returned an error, please check Sdf_unit_test_log.txt for more information" "0"
popd >& /dev/null

pushd Providers/SQLite/Src/UnitTest >& /dev/null
TEST_SUITE_NAME="SQLite"
echo "Running suite: $TEST_SUITE_NAME"
./UnitTest >& $TEST_LOG_PATH/SQLite_unit_test_log.txt
check_for_errors $? "SQLite unit test returned an error, please check SQLite_unit_test_log.txt for more information" "0"
popd >& /dev/null

pushd Providers/OGR/Src/UnitTest >& /dev/null
TEST_SUITE_NAME="OGR"
echo "Running suite: $TEST_SUITE_NAME"
./UnitTest >& $TEST_LOG_PATH/OGR_unit_test_log.txt
check_for_errors $? "OGR unit test returned an error, please check OGR_unit_test_log.txt for more information" "0"
popd >& /dev/null

if [ "$TEST_WMS" == "1" ];
then
    pushd Providers/WMS/Src/UnitTest >& /dev/null
    TEST_SUITE_NAME="WMS"
    echo "Running suite: $TEST_SUITE_NAME"
    ./UnitTest >& $TEST_LOG_PATH/Wms_unit_test_log.txt
    check_for_errors $? "Wms unit test returned an error, please check Wms_unit_test_log.txt for more information" "0"
    popd >& /dev/null
fi

if [ -f "$TEST_ODBC" ];
then
    pushd Providers/GenericRdbms/Src/UnitTest >& /dev/null
    TEST_SUITE_NAME="ODBC"
    echo "Running suite: $TEST_SUITE_NAME"
    ./UnitTestOdbc initfiletest=$TEST_ODBC >& $TEST_LOG_PATH/Odbc_unit_test_log.txt
    check_for_errors $? "Odbc unit test returned an error, please check Odbc_unit_test_log.txt for more information" "0"
    popd >& /dev/null
fi

if [ -f "$TEST_POSTGIS" ];
then
    pushd Providers/GenericRdbms/Src/UnitTest >& /dev/null
    TEST_SUITE_NAME="PostGIS"
    echo "Running suite: $TEST_SUITE_NAME"
    ./UnitTestPostGis initfiletest=$TEST_POSTGIS >& $TEST_LOG_PATH/PostGis_unit_test_log.txt
    check_for_errors $? "PostGis unit test returned an error, please check Odbc_unit_test_log.txt for more information" "0"
    popd >& /dev/null
fi

if [ -f "$TEST_MYSQL" ];
then
    pushd Providers/GenericRdbms/Src/UnitTest >& /dev/null
    TEST_SUITE_NAME="MySQL"
    echo "Running suite: $TEST_SUITE_NAME"
    ./UnitTestMySql initfiletest=$TEST_MYSQL >& $TEST_LOG_PATH/MySql_unit_test_log.txt
    check_for_errors $? "MySql unit test returned an error, please check MySql_unit_test_log.txt for more information" "0"
    popd >& /dev/null
fi

if [ "$TEST_ORACLE" == "1" ];
then
    pushd Providers/KingOracle/src/KgOraUnitTest >& /dev/null
    TEST_SUITE_NAME="King Oracle"
    echo "Running suite: $TEST_SUITE_NAME"
    ./UnitTest >& $TEST_LOG_PATH/Oracle_unit_test_log.txt
    check_for_errors $? "Oracle unit test returned an error, please check Oracle_unit_test_log.txt for more information" "0"
    popd >& /dev/null
fi

# These suites need FDO installed at the default location in order to run
export LD_LIBRARY_PATH=/usr/local/fdo-4.2.0/lib64

pushd Providers/GDAL/Src/UnitTest >& /dev/null
TEST_SUITE_NAME="GDAL"
rm providers.xml # Having this local copy sadly doesn't work, so remove it
echo "Running suite: $TEST_SUITE_NAME"
./UnitTest >& $TEST_LOG_PATH/GDAL_unit_test_log.txt
check_for_errors $? "GDAL unit test returned an error, please check GDAL_unit_test_log.txt for more information" "0"
popd >& /dev/null

pushd Providers/SHP/Src/UnitTest >& /dev/null
TEST_SUITE_NAME="SHP"
rm providers.xml # Having this local copy sadly doesn't work, so remove it
echo "Running suite: $TEST_SUITE_NAME"
./UnitTest >& $TEST_LOG_PATH/Shp_unit_test_log.txt
check_for_errors $? "Shp unit test returned an error, please check Shp_unit_test_log.txt for more information" "0"
popd >& /dev/null

echo "End unit tests..."

if [ "$TEST_FAILURE_COUNT" -ne "0" ];
then
    echo "$TEST_FAILURE_COUNT tests failed in total"
    exit $TEST_FAILURE_COUNT
fi