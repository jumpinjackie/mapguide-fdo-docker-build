#!/bin/bash
#
# Generate, compile and run the TypeScript verification against a live MapGuide MapAgent.
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

"$SCRIPT_DIR/generate.sh"

# generate.sh wipes Client/, so the verifier is copied in after generation rather than kept there.
cp "$SCRIPT_DIR/src/verify.ts" "$CLIENT/src/verify.ts"

cd "$CLIENT"
echo ">> Installing client dependencies and compiling"
npm install --no-audit --no-fund --silent
npx tsc

ENDPOINT="${MG_MAPAGENT_URL:-http://localhost:8018/mapguide/mapagent/mapagent.fcgi}"
echo ">> Verifying against $ENDPOINT"

MG_MAPAGENT_URL="$ENDPOINT" node dist/verify.js
