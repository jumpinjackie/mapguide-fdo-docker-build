#!/bin/bash
#
# Generate, compile and run the Java verification against a live MapGuide MapAgent.
#
#   ./run.sh
#
# Environment:
#   MG_MAPAGENT_URL   default http://localhost:8018/mapguide/mapagent/mapagent.fcgi
#   MG_USER           default Administrator
#   MG_PASS           default admin
#
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
CLIENT="$SCRIPT_DIR/Client"

# Maven needs a working JAVA_HOME. The environment's may point at a JVM that no longer exists, so
# derive it from the java actually on the PATH when it is missing or broken.
if [ -z "${JAVA_HOME:-}" ] || [ ! -x "$JAVA_HOME/bin/java" ]; then
    JAVA_HOME="$(dirname "$(dirname "$(readlink -f "$(command -v java)")")")"
fi
export JAVA_HOME

"$SCRIPT_DIR/generate.sh"

# generate.sh wipes Client/, so the verifier is copied in after generation rather than kept there.
cp "$SCRIPT_DIR/src/Verify.java" "$CLIENT/src/main/java/org/mapguide/mapagent/Verify.java"

cd "$CLIENT"
echo ">> Building the generated client and verifier ($("$JAVA_HOME/bin/java" -version 2>&1 | head -1))"
# The generated pom targets Java 1.8, which recent JDKs no longer accept.
mvn -q -DskipTests package -Dmaven.compiler.source=17 -Dmaven.compiler.target=17
mvn -q dependency:build-classpath -Dmdep.outputFile=cp.txt -DincludeScope=runtime

ENDPOINT="${MG_MAPAGENT_URL:-http://localhost:8018/mapguide/mapagent/mapagent.fcgi}"
echo ">> Verifying against $ENDPOINT"

MG_MAPAGENT_URL="$ENDPOINT" java -cp "target/classes:$(cat cp.txt)" org.mapguide.mapagent.Verify
