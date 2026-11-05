#!/bin/bash
#
# Generate a TypeScript client from the MapAgent OpenAPI spec.
#
# This deliberately uses OpenAPI Generator (typescript-fetch) rather than Kiota: the point of this
# directory is to prove the same spec drives a second, independent code generator.
#
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
SPEC="$REPO_ROOT/mapguide/MgDev/Web/src/openapi/openapi.yaml"

echo ">> Generating TypeScript client from $SPEC"

npx --yes @openapitools/openapi-generator-cli generate \
    -i "$SPEC" \
    -g typescript-fetch \
    -o "$SCRIPT_DIR/Client" \
    --additional-properties=supportsES6=true,npmName=mapagent-client,npmVersion=0.0.1 \
    --global-property=apiTests=false,modelTests=false,apiDocs=false,modelDocs=false

echo ">> Generated TypeScript client: $SCRIPT_DIR/Client"
