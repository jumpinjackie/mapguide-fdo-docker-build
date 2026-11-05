# MapAgent OpenAPI — Java client verification

Proves the MapAgent OpenAPI spec drives a second, independent code generator: OpenAPI Generator's
Java (`okhttp-gson`) client (the C# harness uses Kiota). Two languages now agree on the same
document.

```
generate.sh    # openapi-generator -> ./Client (gitignored)
run.sh         # generate + mvn package + run org.mapguide.mapagent.Verify
src/Verify.java # the checks, copied into Client/src/main/java before compiling
```

## Requirements

- JDK 17+ and Maven. The generated `pom.xml` targets Java 1.8, which recent JDKs no longer accept,
  so `run.sh` passes `-Dmaven.compiler.source=17 -Dmaven.compiler.target=17`.
- `run.sh` derives `JAVA_HOME` from the `java` on the `PATH` when the inherited one is missing or
  points at a removed JVM (Maven refuses to start otherwise).
- Network access on first run: the generator and the client's Maven dependencies are downloaded.

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

`getMapImage` is generated as returning a `File` (the spec declares binary image responses), and the
check reads it back to assert the PNG magic bytes.

## Prerequisites

A running MapGuide server with the Sheboygan sample data applied — see
[`../openapi-csharp/README.md`](../openapi-csharp/README.md) for standing one up and seeding it.
