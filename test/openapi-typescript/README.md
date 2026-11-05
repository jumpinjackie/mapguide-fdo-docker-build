# MapAgent OpenAPI — TypeScript client verification

Proves the MapAgent OpenAPI spec drives a second, independent code generator: OpenAPI Generator's
`typescript-fetch` client (the C# harness uses Kiota). If a spec change breaks a toolchain, it shows
up here.

```
generate.sh   # openapi-generator -> ./Client (gitignored)
run.sh        # generate + npm install + tsc + run dist/verify.js
src/verify.ts # the checks, copied into Client/src before compiling
```

## Requirements

- Node.js 18+ (the generated client uses the global `fetch`).
- Network access on first run: `npx @openapitools/openapi-generator-cli` downloads the generator.

## Usage

```bash
export MG_MAPAGENT_URL="http://localhost:8018/mapguide/mapagent/mapagent.fcgi"
export MG_USER="Administrator"
export MG_PASS="admin"
./run.sh
```

Expected output:

```
PASS  GetSiteStatus returns a SiteStatus document
PASS  GetMapImage streams PNG bytes
PASS  anonymous GetSiteInfo is rejected with 401
PASS  handler exception surfaces as 559

4/4 checks passed
```

The rendering check asserts the response `Content-Type` is `image/png` and that the body starts with
the PNG magic bytes, so it fails if the spec's `image/*` binary responses stop matching reality.

## Prerequisites

A running MapGuide server with the Sheboygan sample data applied — see
[`../openapi-csharp/README.md`](../openapi-csharp/README.md) for standing one up and seeding it.
