#!/bin/bash

TEST_LOG_PATH=$(pwd)

TEST_SUITE_NAME=
TEST_FAILURE_COUNT=0
MG_BUILD_DIR=

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
        --mapguide-build-dir)
            MG_BUILD_DIR="$2"
            shift
            ;;
        --log-path)
            TEST_LOG_PATH="$2"
            shift
            ;;
        --help)
            echo "Usage: $0 (options)"
            echo "Options:"
            echo "  --mapguide-build-dir [MapGuide build dir]"
            echo "  --log-path [Unit Test log path]"
            echo "  --help [Display usage]"
            exit
            ;;
    esac
    shift   # Check next set of parameters.
done

echo "MapGuide build dir: $MG_BUILD_DIR"
echo "Log path is: $TEST_LOG_PATH"
if [ ! -d "$TEST_LOG_PATH" ]; then
    mkdir -p $TEST_LOG_PATH
fi
cd $MG_BUILD_DIR || exit
echo "Starting unit tests"

cd Server/src/Core || exit

for comp in FeatureService Geometry KmlService LogManager MappingService TileService ResourceService MdfModel Misc Performance RenderingService ServerAdminService ServerManager ServiceManager SiteManager SiteService ProfilingService TransformMesh
do
    TEST_SUITE_NAME="MapGuide Test: $comp"
    echo "Running suite: $TEST_SUITE_NAME"
    timeout 5m ./mgserver test $comp UnitTestResults_${comp}.xml >& $TEST_LOG_PATH/mapguide_${comp}_unit_test.log
    check_for_errors $? "Fdo unit test returned an error, please check FeatureService_test_log.txt for more information" "0"
    if [ -f UnitTestResults_${comp}.xml ]; then
        mv UnitTestResults_${comp}.xml $TEST_LOG_PATH/UnitTestResults_${comp}.xml
    fi
done