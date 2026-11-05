#!/bin/bash
#
# Regenerate the C# client from the OpenAPI spec, build it, and run the xUnit suite against a
# running MapGuide MapAgent.
#
#   ./run.sh               generate + build + test
#   ./run.sh --build-only  generate + build (no server required)
#
# The server endpoint and credentials are read from the environment:
#   MG_MAPAGENT_URL   default http://localhost:8018/mapguide/mapagent/mapagent.fcgi
#   MG_USER           default Administrator
#   MG_PASS           default admin
#
# To stand up a server, install a MapGuide build (see the repository's mapguide_image_install.sh
# or run the web tier inside a build container with
# templates/scripts/container/run_mapguide_tests.sh) and point MG_MAPAGENT_URL at its mapagent.
#
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT="$SCRIPT_DIR/Tests/MapGuide.MapAgent.OpenApi.Tests.csproj"
BUILD_ONLY=0
[ "${1:-}" = "--build-only" ] && BUILD_ONLY=1

"$SCRIPT_DIR/generate.sh"

# generate.sh recreates ./Client, which invalidates the previous restore graph. Clearing the
# intermediate/output folders forces a clean restore so the Tests -> Client ProjectReference is
# re-resolved (otherwise NuGet can report "up-to-date" and drop the reference).
rm -rf "$SCRIPT_DIR/Client/obj" "$SCRIPT_DIR/Client/bin" \
       "$SCRIPT_DIR/Tests/obj" "$SCRIPT_DIR/Tests/bin"

echo ">> Building the generated client and tests"
dotnet build "$PROJECT" -c Debug

if [ "$BUILD_ONLY" -eq 1 ]; then
    echo ">> Build-only requested; skipping test run."
    exit 0
fi

ENDPOINT="${MG_MAPAGENT_URL:-http://localhost:8018/mapguide/mapagent/mapagent.fcgi}"
echo ">> Running the suite against $ENDPOINT"
echo "   (set MG_MAPAGENT_URL / MG_USER / MG_PASS to target another server)"

MG_MAPAGENT_URL="$ENDPOINT" \
    dotnet test "$PROJECT" -c Debug --no-build --logger "console;verbosity=normal"
