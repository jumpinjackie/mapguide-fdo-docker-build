#!/bin/bash
#
# Generate a Java client from the MapAgent OpenAPI spec (OpenAPI Generator, okhttp-gson).
#
# Deliberately not Kiota: this directory exists to show the same spec drives a second,
# independent generator in a second ecosystem.
#
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
SPEC="$REPO_ROOT/mapguide/MgDev/Web/src/openapi/openapi.yaml"

echo ">> Generating Java client from $SPEC"

npx --yes @openapitools/openapi-generator-cli generate \
    -i "$SPEC" \
    -g java \
    -o "$SCRIPT_DIR/Client" \
    --library okhttp-gson \
    --additional-properties=groupId=org.mapguide,artifactId=mapagent-client,artifactVersion=0.0.1,invokerPackage=org.mapguide.mapagent,apiPackage=org.mapguide.mapagent.api,modelPackage=org.mapguide.mapagent.model \
    --global-property=apiTests=false,modelTests=false,apiDocs=false,modelDocs=false

echo ">> Generated Java client: $SCRIPT_DIR/Client"
