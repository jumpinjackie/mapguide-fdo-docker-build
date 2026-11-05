# MapAgent OpenAPI — C# client & test harness

This directory proves the MapAgent OpenAPI spec
(`mapguide/MgDev/Web/src/openapi/openapi.yaml`) is usable end to end:

1. **Generate** a C# client from the spec with [Kiota](https://learn.microsoft.com/openapi/kiota/).
2. **Compile** the generated client.
3. **Run** an xUnit suite, built on the generated client, against a live MapGuide server —
   mirroring the request coverage of the `httpyac` suites in `../` (rendering, feature, resource,
   session/site, mapping/tile, coordinate-system and geo-processing).

The rendering tests are the focus: `GetMapImage` and `GetLegendImage` must return real image
streams (PNG/GIF/JPEG), which is what validates the spec's `image/*` binary response definitions.

The error contract is covered by `ErrorModelTests`, which provokes both shapes the mapagent emits
and checks them on the wire as well as through the generated client: `401` with a
`WWW-Authenticate: Basic` challenge for an anonymous call, and the non-standard `559`
(`HTTP_STATUS_MG_ERROR`) with a `text/html` body for a handler exception. The generated client
surfaces both as an `ApiException` carrying `ResponseStatusCode`, because the error bodies are
scalars Kiota cannot turn into a model.

## Requirements

- .NET SDK 10 (`dotnet`).
- The Kiota dotnet tool: `dotnet tool install --global Microsoft.OpenApi.Kiota`.
- A running MapGuide server exposing the mapagent (see below).

## Layout

```
openapi-csharp/
  generate.sh     # kiota generate -> ./Client and writes both project files (gitignored)
  run.sh          # generate + build + test (or --build-only)
  Client/         # generated C# client (not committed)
  Tests/          # xUnit source + generated test project file (csproj not committed)
```

Both `.csproj` files are emitted by `generate.sh` from templates it owns, so the projects are
reproducible and never drift from the spec. The hand-written sources are `Tests/*.cs`.

## Quick start

```bash
# 1. Point at a server
export MG_MAPAGENT_URL="http://localhost:8018/mapguide/mapagent/mapagent.fcgi"
export MG_USER="Administrator"
export MG_PASS="admin"

# 2. Generate + build + test
./run.sh

# Compile only (no server needed):
./run.sh --build-only
```

## Authentication

The harness authenticates with HTTP Basic (`MG_USER`/`MG_PASS`), which the MapAgent's CgiAgent
accepts directly. The `CreateSession` test additionally exercises the session flow.

## Standing up a server

The mapagent is served over HTTP by the MapGuide web tier (Apache + the CgiAgent FastCGI program)
on the client port (default 8018). Any of these produce a reachable endpoint:

- **Installed package** — `mapguide_image_install.sh` installs a `.run` build and starts the
  server; point `MG_MAPAGENT_URL` at `http://<host>:8018/mapguide/mapagent/mapagent.fcgi`.
- **Build container** — `templates/scripts/container/run_mapguide_tests.sh` runs the server for
  the web tier suites; the same endpoint is then reachable from inside the container.

The tests use the Sheboygan sample data (`Library://Samples/Sheboygan/...`). A server install does
**not** populate it — the library repository starts empty — so seed it first. The package is just a
zip of `Library/` plus `MgResourcePackageManifest.xml`, which the repository's test data already
contains; build it somewhere outside the working copy (the tree's own `build.sh` copies the `.sdf`
files into `Library/`, which dirties the SVN tree):

```bash
T="mapguide/MgDev/UnitTest/TestData"
rm -rf /tmp/sheb && mkdir -p /tmp/sheb && cp -R "$T/Samples/Sheboygan" /tmp/sheb/
cd /tmp/sheb/Sheboygan
D=Library/Samples/Sheboygan/Data
cp -f "$T/FeatureService/SDF/Sheboygan_BuildingOutlines.sdf" "$D/BuildingOutlines.FeatureSource_DATA_BuildingOutlines.sdf"
cp -f "$T/FeatureService/SDF/Sheboygan_CityLimits.sdf"       "$D/CityLimits.FeatureSource_DATA_CityLimits.sdf"
cp -f "$T/FeatureService/SDF/Sheboygan_Parcels.sdf"          "$D/Parcels.FeatureSource_DATA_Parcels.sdf"
cp -f "$T/FeatureService/SDF/Sheboygan_VotingDistricts.sdf"  "$D/VotingDistricts.FeatureSource_DATA_VotingDistricts.sdf"
cp -f "$T/MappingService/UT_HydrographicPolygons.sdf"        "$D/HydrographicPolygons.FeatureSource_DATA_HydrographicPolygons.sdf"
cp -f "$T/MappingService/UT_Rail.sdf"                        "$D/Rail.FeatureSource_DATA_Rail.sdf"
cp -f "$T/TileService/UT_RoadCenterLines.sdf"                "$D/RoadCenterLines.FeatureSource_DATA_RoadCenterLines.sdf"
zip -qr /tmp/Sheboygan.mgp Library MgResourcePackageManifest.xml
```

Then apply it. `OPERATION` has to be a **multipart form field**, not a query parameter: for a POST
the agent parses only the request body (`ApacheAgent.cpp`), so an `OPERATION` in the query string
is ignored and the call silently does nothing.

```bash
curl -u "$MG_USER:$MG_PASS" \
  -F "OPERATION=APPLYRESOURCEPACKAGE" -F "VERSION=1.0.0" \
  -F "PACKAGE=@/tmp/Sheboygan.mgp;type=application/octet-stream" \
  "$MG_MAPAGENT_URL"
```

Verify with `RESOURCEEXISTS` (`Library://Samples/Sheboygan/Maps/Sheboygan.MapDefinition` must
return `True`); `ApplyResourcePackage` answers `200` even when it did nothing, so a 200 alone
proves nothing.

## A note on addressing

Every MapAgent operation is a call to the single `mapagent.fcgi` endpoint dispatched by the
`OPERATION` query parameter. The spec gives each operation its own path (e.g. `/GetMapImage`) so
the generated client has a distinct method per operation; the segment after `mapagent.fcgi` is
request-routing decoration that the MapAgent ignores (CgiAgent reads only `QUERY_STRING`/POST
body), so real requests still hit the one endpoint with the right `OPERATION`. No product
configuration is needed for that: Apache's default `AcceptPathInfo` behaviour already serves the
path info to the `AddHandler mgmapagent_handler fcgi` mapping, verified against an installed server
(`/mapagent.fcgi/GetMapImage?OPERATION=GETSITESTATUS` returns `200` and the real payload), so
`mapguide/MgDev/cmake/configs/mapguide.conf.in` ships unchanged. On IIS the equivalent depends on
the ISAPI mapping's path-info setting.

## Known limitations

- `EnumerateRepositories` is deliberately absent from the spec and from these tests. The mapagent
  has no handler registered for `ENUMERATEREPOSITORIES` (see `test/API_BUGS.md`), so the operation
  can only ever return `559 MgInvalidOperationException` — a generated client method for it would be
  a method that cannot succeed.
- `GetLegendImage` renders nothing for some layers: `Layers/Parcels.LayerDefinition` returns
  `200` with a zero-length body, while `Layers/Soils.LayerDefinition` returns a real PNG. The test
  uses the latter.
