#!/bin/bash
#
# Generate a C# client from the MapAgent OpenAPI spec using Kiota.
#
# The spec is the single source of truth at
# mapguide/MgDev/Web/src/openapi/openapi.yaml. This script regenerates the C# client into
# ./Client (gitignored) and writes the project file Kiota itself does not emit, so the result
# can be compiled and referenced by the xUnit test project in ./Tests.
#
# Requirements: the Kiota dotnet tool (dotnet tool install --global Microsoft.OpenApi.Kiota).
#
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
SPEC="${MG_OPENAPI_SPEC:-$REPO_ROOT/mapguide/MgDev/Web/src/openapi/openapi.yaml}"
OUT="$SCRIPT_DIR/Client"
NAMESPACE="MapGuide.MapAgent.Client"
CLIENT_CLASS="MapAgentClient"

if ! command -v kiota >/dev/null 2>&1; then
    echo "ERROR: 'kiota' was not found on PATH." >&2
    echo "       Install it with: dotnet tool install --global Microsoft.OpenApi.Kiota" >&2
    exit 1
fi
if [ ! -f "$SPEC" ]; then
    echo "ERROR: OpenAPI spec not found at $SPEC" >&2
    exit 1
fi

echo ">> Generating C# client"
echo "   spec      : $SPEC"
echo "   output    : $OUT"
echo "   namespace : $NAMESPACE"
echo "   kiota     : $(kiota --version 2>/dev/null || echo unknown)"

rm -rf "$OUT"
kiota generate \
    --language CSharp \
    --openapi "$SPEC" \
    --output "$OUT" \
    --namespace-name "$NAMESPACE" \
    --class-name "$CLIENT_CLASS" \
    --clean-output

# Kiota emits source files but not a project file. Provide one so the generated code is a
# first-class project the test project can reference. Microsoft.Kiota.Bundle brings in the
# abstractions, serialization and HttpClient adapter packages the generated code needs.
cat > "$OUT/MapGuide.MapAgent.Client.csproj" <<'CSPROJ'
<Project Sdk="Microsoft.NET.Sdk">
  <PropertyGroup>
    <TargetFramework>net10.0</TargetFramework>
    <Nullable>enable</Nullable>
    <LangVersion>latest</LangVersion>
    <ImplicitUsings>enable</ImplicitUsings>
    <!-- CS1591: missing XML doc on generated members. CS0618: obsolete members in generated code. -->
    <NoWarn>$(NoWarn);CS1591;CS0618</NoWarn>
    <GenerateDocumentationFile>false</GenerateDocumentationFile>
  </PropertyGroup>
  <ItemGroup>
    <PackageReference Include="Microsoft.Kiota.Bundle" Version="2.0.0" />
  </ItemGroup>
</Project>
CSPROJ

echo ">> Done. Generated client project: $OUT/MapGuide.MapAgent.Client.csproj"

# The test project references the generated client. It is written here (rather than only kept by
# hand) so `./run.sh` is fully reproducible: regenerating the client can never leave the reference
# stale, and the test project always carries the ProjectReference to ./Client.
cat > "$SCRIPT_DIR/Tests/MapGuide.MapAgent.OpenApi.Tests.csproj" <<'CSPROJ'
<Project Sdk="Microsoft.NET.Sdk">
  <PropertyGroup>
    <TargetFramework>net10.0</TargetFramework>
    <Nullable>enable</Nullable>
    <LangVersion>latest</LangVersion>
    <ImplicitUsings>enable</ImplicitUsings>
    <IsPackable>false</IsPackable>
    <!-- CS0618: Kiota marks the raw OPERATION/VERSION/FORMAT string setters obsolete in favour of
         generated enum setters; the string forms still serialize correctly and keep the harness
         terse. CS1591: no XML docs on test helpers. -->
    <NoWarn>$(NoWarn);CS0618;CS1591</NoWarn>
  </PropertyGroup>
  <ItemGroup>
    <PackageReference Include="Microsoft.NET.Test.Sdk" Version="17.11.1" />
    <PackageReference Include="xunit" Version="2.9.2" />
    <PackageReference Include="xunit.runner.visualstudio" Version="2.8.2" />
  </ItemGroup>
  <ItemGroup>
    <ProjectReference Include="../Client/MapGuide.MapAgent.Client.csproj" />
  </ItemGroup>
</Project>
CSPROJ

echo ">> Done. Test project: $SCRIPT_DIR/Tests/MapGuide.MapAgent.OpenApi.Tests.csproj"
