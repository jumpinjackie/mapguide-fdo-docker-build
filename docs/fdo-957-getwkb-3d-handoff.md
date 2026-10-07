# Handoff: FDO ticket #957 — `GetWkb` fails for 3D (Z) geometries

**Status:** Investigation complete, root cause confirmed. **Fix intentionally not implemented** — paused at a representation design decision (see [Open decision](#open-decision)).
**Date:** 2026-10-08
**Source tree:** `fdo` @ SVN `branches/4.2`, revision 8375 (working copy `/home/user/projects/mapguide-fdo-docker-build/fdo`)

---

## Ticket

- Upstream: https://trac.osgeo.org/fdo/ticket/957 — *"SHP-files with 3D throw error"*
- Symptom: reading a 3D shapefile, then calling `GetWkb` throws
  `OSGeo.FDO.Common.Exception: Unsupported geometry type.` at
  `OSGeo.FDO.Geometry.FgfGeometryFactory.GetWkb(IGeometry geometry)`.
- Reporter's question: *"Shouldn't this method have the possibility to return the read geometry in 2d if 3d is not supported?"*

## Confirmation (TL;DR)

**The hypothesis is correct.** The FGF → WKB conversion is incomplete for 3D: `FdoFgfGeometryFactory::GetWkb` has an explicit hard gate that rejects *any* geometry whose dimensionality is not exactly `FdoDimensionality_XY`. There is no Z/M branch, no ISO WKB Z type codes (1001+), and no EWKB high-bit handling in the generic factory. This is deliberate, documented current behaviour — the 3D case is simply unimplemented.

## Root cause

[`fdo/Fdo/Unmanaged/Src/Geometry/Fgf/GeometryFactory.cpp`](/home/user/projects/mapguide-fdo-docker-build/fdo/Fdo/Unmanaged/Src/Geometry/Fgf/GeometryFactory.cpp)

`FdoFgfGeometryFactory::GetWkb` (starts line 604):

```cpp
// GeometryFactory.cpp:618
// WKB only supports XY, no Z or M ordinates.
FdoInt32 dimensionality = geometry->GetDimensionality();
if (dimensionality != FdoDimensionality_XY)                         // line 620
    throw FdoException::Create(FdoException::NLSGetMessage(          // line 621
        FDO_NLSID(FDO_10_UNSUPPORTEDGEOMETRYTYPE)));
```

The XY branch that follows only prepends the endian byte, copies the geometry type, and memmoves the 2-ordinate payload — so even the "supported" path assumes exactly two ordinates per position.

Supporting evidence that this is by design, not a regression:

- Public header documents it — [`fdo/Fdo/Unmanaged/Inc/Geometry/Fgf/Factory.h:147`](/home/user/projects/mapguide-fdo-docker-build/fdo/Fdo/Unmanaged/Inc/Geometry/Fgf/Factory.h):
  > *"This method does not support geometry collections, curved geometries or geometries with Z or M ordinates and will throw if given such geometries"*
- The managed binding in the ticket's stack trace is a thin passthrough, so the `.NET` exception is this core throw:
  [`mgFgfGeometryFactory.cpp:149`](/home/user/projects/mapguide-fdo-docker-build/fdo/Fdo/Managed/Src/OSGeo/Geometry/mgFgfGeometryFactory.cpp)
  `arr = GetImpObj()->GetWkb(...)`.

### Why ticket #957 hits it (the SHP path)

The SHP provider correctly reads a 3D shape and deliberately builds an **XYZ** FDO geometry:

- [`fdo/Providers/SHP/Src/ShpRead/PolylineZShape.cpp:91`](/home/user/projects/mapguide-fdo-docker-build/fdo/Providers/SHP/Src/ShpRead/PolylineZShape.cpp)
  ```cpp
  dimensionality = FdoDimensionality_XY | FdoDimensionality_Z;   // line 91
  ...
  line = factory->CreateLineString(dimensionality, doubles, points);  // line 127
  ```
- Same pattern in the sibling Z shapes: `PointZShape.cpp`, `PolygonZShape.cpp`, `MultiPointZShape.cpp`.
- Capability advertisement already includes Z/M:
  [`ShpGeometryCapabilities.cpp:75`](/home/user/projects/mapguide-fdo-docker-build/fdo/Providers/SHP/Src/ShpGeometryCapabilities.cpp)
  `return (FdoDimensionality_XY | FdoDimensionality_Z | FdoDimensionality_M);`

So the provider hands `GetWkb` a `dimensionality == 1` (`XY|Z`) geometry → the line-620 gate throws `FDO_10_UNSUPPORTEDGEOMETRYTYPE` → exactly the reported exception.

## Reproduction (already done)

A minimal harness linked against the pre-built Debug library reproduced it without any external data.

Harness source (`repro.cpp`):

```cpp
#include <Geometry/Fgf/Factory.h>
#include <Geometry/IPoint.h>
#include <Geometry/ILineString.h>
#include <Common/Exception.h>
#include <Common/Ptr.h>
#include <cstdio>

static void tryGetWkb(FdoFgfGeometryFactory* gf, FdoIGeometry* g, const char* label)
{
    std::printf("[%s] dimensionality = %d\n", label, g->GetDimensionality());
    try
    {
        FdoPtr<FdoByteArray> wkb = gf->GetWkb(g);
        std::printf("[%s] GetWkb OK, %d bytes\n", label, wkb->GetCount());
    }
    catch (FdoException* e)
    {
        std::printf("[%s] GetWkb THREW: %ls\n", label, e->GetExceptionMessage());
        FDO_SAFE_RELEASE(e);
    }
}

int main()
{
    FdoFgfGeometryFactory* gf = FdoFgfGeometryFactory::GetInstance();

    double xy[] = { 1.0, 2.0 };
    FdoPtr<FdoIPoint> pt2d = gf->CreatePoint(FdoDimensionality_XY, xy);
    tryGetWkb(gf, pt2d, "2D point");

    double xyz[] = { 1.0, 2.0, 3.0 };
    FdoPtr<FdoIPoint> pt3d = gf->CreatePoint(FdoDimensionality_XY | FdoDimensionality_Z, xyz);
    tryGetWkb(gf, pt3d, "3D point");

    double xyzline[] = { 1.0,2.0,3.0, 4.0,5.0,6.0 };
    FdoPtr<FdoILineString> ls3d = gf->CreateLineString(FdoDimensionality_XY | FdoDimensionality_Z, 6, xyzline);
    tryGetWkb(gf, ls3d, "3D linestring");

    return 0;
}
```

Build (from repo root; paths valid for the existing `generic` Debug build area):

```bash
g++ -std=c++11 \
  -I fdo/Fdo/Unmanaged/Inc \
  -I build_area/x64/Debug/generic/fdo/fdo/Fdo/Unmanaged/Inc \
  repro.cpp \
  -L build_area/x64/Debug/generic/fdo/fdo/Fdo/Unmanaged/Src -lFDO-4.2.0 \
  -L build_area/x64/Debug/generic/fdo/fdo/_CPack_Packages/generic-amd64/TGZ/fdosdk-4.2.0.8326-generic-amd64/lib64 \
  -lxalan-c -lxerces-c-3.1 \
  -Wl,-rpath,$PWD/build_area/x64/Debug/generic/fdo/fdo/_CPack_Packages/generic-amd64/TGZ/fdosdk-4.2.0.8326-generic-amd64/lib64 \
  -o repro

LD_LIBRARY_PATH=$PWD/build_area/x64/Debug/generic/fdo/fdo/Fdo/Unmanaged/Src:$PWD/build_area/x64/Debug/generic/fdo/fdo/_CPack_Packages/generic-amd64/TGZ/fdosdk-4.2.0.8326-generic-amd64/lib64 ./repro
```

Observed output:

```
[2D point]      dimensionality = 0  -> GetWkb OK, 21 bytes
[3D point]      dimensionality = 1  -> GetWkb THREW: FDO_10_UNSUPPORTEDGEOMETRYTYPE
[3D linestring] dimensionality = 1  -> GetWkb THREW: FDO_10_UNSUPPORTEDGEOMETRYTYPE
```

(Temp harness/tooling under `/tmp/wkbrepro` was deleted after the investigation.)

## Test data (NOT committable)

Local-only 3D shapefile supplied for reproduction:

```
/home/user/libvirt-share/3d_shp/Bohrung Bestand.shp   (shape type 13 = PolyLineZ)
/home/user/libvirt-share/3d_shp/Bohrung Bestand.{dbf,idx,prj,shx}
```

- Header shape type verified via the `.shp` header (bytes 32–35): `13 (PolyLineZ)` → the 3D reader path `PolylineZShape::GetGeometry()` is what runs.
- **Licensing:** this data is **not open data**. It must **not** be committed to the FDO SVN repo and must **not** be added to any test suite. Any regression test must be built from synthetic ordinates (see below).

## Related finding: the reverse direction is also XY-only

While confirming, the WKB → FGF path was found to be equally Z-blind:

[`GeometryFactory.cpp:467`](/home/user/projects/mapguide-fdo-docker-build/fdo/Fdo/Unmanaged/Src/Geometry/Fgf/GeometryFactory.cpp) — `CreateFgfFromWkb`:

```cpp
FdoInt32 dimensionality = FdoDimensionality_XY; // XY is the only one supported by WKB.
```

It reads exactly 2 ordinates per position for Point / LineString / Polygon / Multi* (and throws `FDO_10_UNSUPPORTEDGEOMETRYTYPE` at lines 533, 548, 583 for unhandled cases). Consequently `CreateGeometryFromWkb` cannot round-trip Z either. A complete fix for "FGF ↔ WKB is 3D-incomplete" would touch both directions; ticket #957 only concerns `GetWkb`.

Also still unsupported by the generic factory (out of scope for #957, but same "incomplete" family):
- Curved geometries (`CurveString`, `CurvePolygon`, `MultiCurveString`, `MultiCurvePolygon`) — no case in either switch; `GetWkb` falls through to the default throw at [`GeometryFactory.cpp:682`](/home/user/projects/mapguide-fdo-docker-build/fdo/Fdo/Unmanaged/Src/Geometry/Fgf/GeometryFactory.cpp).
- Multi-collection sub-geometry endianness is checked to be little-endian only.

## In-tree precedent for a Z representation

The codebase already serialises 3D at the **FGF level inside the PostGIS provider**, using **PostGIS Extended WKB (EWKB)** high-bit flags — it bypasses the generic factory:

[`fdo/Providers/GenericRdbms/Src/PostGis/Driver/Geometry.c`](/home/user/projects/mapguide-fdo-docker-build/fdo/Providers/GenericRdbms/Src/PostGis/Driver/Geometry.c)

```c
eWkbFlagZ    = 0x80000000,   // line 33
eWkbFlagM    = 0x40000000,
eWkbFlagSrid = 0x20000000,
```

Entry points: `GeometryFromExtendedWkb` (152), `FgfFromExtendedWkb` (174), `ExtendedWkbFromGeometry` (277), `ExtendedWkbFromFgf` (301).

This is the only Z-aware WKB machinery in the tree, so EWKB high-bit is the natural convention if the generic factory is to gain Z support.

## Open decision

Which representation should the generic `FdoFgfGeometryFactory::GetWkb` emit for Z/M? Options presented to the user (fix paused here):

1. **EWKB high-bit flags** (`0x80000000` for Z, `0x40000000` for M) — matches the existing in-tree PostGIS EWKB code. *Recommended.*
2. **ISO/OGC WKB Z type codes** (`PointZ=1001`, `LineStringZ=1002`, `PolygonZ=1003`, `MultiPointZ=1004`, `MultiLineStringZ=1005`, `MultiPolygonZ=1006`).
3. **Drop Z/M, return 2D XY WKB** — the ticket reporter's suggestion; lossy (silently discards elevation).

Note a compatibility angle for option 3 vs 1/2: the other callers of `GetWkb` (MySQL driver `Geometry.cpp:66`, KingOracle `c_KgOtl.cpp`, KingInformix, KingMsSqlSpatial `c_KgOtl.cpp:452`, PostGIS `WkbFromGeometry`) today only ever pass XY because Z throws, so none of them regress if Z is added — but if Z is *emitted*, each consumer's expectations for a Z payload would need checking.

## Suggested fix outline (when resumed)

1. Decide representation (above). If EWKB: reuse/port the flag logic already proven in `Geometry.c`.
2. In `GetWkb`: replace the XY-only gate (lines 618–621) with dimensionality handling that:
   - keeps byte-for-byte output identical for `FdoDimensionality_XY` (no behaviour change / no regression), and
   - emits Z/M ordinates for `XY|Z`, `XY|M`, `XY|Z|M` for Point / LineString / Polygon and the Multi* aggregates (recursing as the existing code already does).
3. If symmetric round-trip is wanted, apply the mirror change in `CreateFgfFromWkb` (remove the XY hardcode at line 467, read 3 or 4 ordinates per position based on the representation).
4. Update the `GetWkb` doc comment at `Factory.h:147` to reflect the new capability.
5. Keep curved geometries and the SRID flag question out of scope unless explicitly requested.

## Test strategy (must avoid the non-open SHP)

The existing FDO core test already exercises the WKB round-trip with synthetic ordinates — extend it; do **not** introduce the supplied shapefile.

- [`fdo/Fdo/UnitTest/GeometryTest.cpp`](/home/user/projects/mapguide-fdo-docker-build/fdo/Fdo/UnitTest/GeometryTest.cpp)
  - WKB round-trip patterns: `testLineString` (~line 884), polygon (~927), multi-polygon (~1069) — each calls `GetWkb` then `CreateGeometryFromWkb` and re-checks.
  - `CheckWkb(FdoByte*)` (~line 2034) decodes WKB back to WKT for assertions.
  - `CheckFGFT(...)` compares FGF-derived WKT.
- Suggested new cases: build a `Point`/`LineString`/`Polygon` with `FdoDimensionality_XY | FdoDimensionality_Z` via `CreatePoint`/`CreateLineString`/`CreateLinearRing`, call `GetWkb`, and assert the exact expected bytes/type flag; and (if symmetric) round-trip back and compare WKT.
- The 3D SHP file cannot back a test; if provider-level coverage is ever wanted, it would have to use synthetic/generated 3D shapefiles committed under `Providers/SHP/TestData`, which needs its own licensing review.

## Validation required before committing a fix (repo definition of done)

- Source-tree change → a run of `./build_thin.sh` for **FDO** against the baseline distro (**ubuntu 22.04**):
  `./build_thin.sh --target fdo --distro ubuntu --tag 22 --cpu x64`
- Then run the FDO core unit tests (prefer an interactive build container because `env_test_thin.sh` is known-flaky): `./build_thin.sh --target fdo --distro ubuntu --tag 22 --cpu x64 --interactive`, and run the core `UnitTest` / `GeometryTest` suite.
- Debug builds are ASan/LSan-instrumented — a green run that leaks still exits non-zero; read `OK (<n>)` in the log rather than the exit code (relevant only if the fix allocates anywhere that could leak).
- Never `svn commit`; edits to the `fdo` tree stay local.

## Key references

| Item | Location |
|------|----------|
| `GetWkb` XY-only gate | `fdo/Fdo/Unmanaged/Src/Geometry/Fgf/GeometryFactory.cpp:618-621` |
| `GetWkb` default throw | `fdo/Fdo/Unmanaged/Src/Geometry/Fgf/GeometryFactory.cpp:682` |
| `CreateFgfFromWkb` XY hardcode | `fdo/Fdo/Unmanaged/Src/Geometry/Fgf/GeometryFactory.cpp:467` |
| `GetWkb` documented limitation | `fdo/Fdo/Unmanaged/Inc/Geometry/Fgf/Factory.h:147` |
| Managed wrapper | `fdo/Fdo/Managed/Src/OSGeo/Geometry/mgFgfGeometryFactory.cpp:149` |
| SHP 3D reader sets Z | `fdo/Providers/SHP/Src/ShpRead/PolylineZShape.cpp:91,127` |
| SHP Z/M capability | `fdo/Providers/SHP/Src/Provider/ShpGeometryCapabilities.cpp:75` |
| PostGIS EWKB flags + impl | `fdo/Providers/GenericRdbms/Src/PostGis/Driver/Geometry.c:33-35,152,174,277,301` |
| Core WKB round-trip tests | `fdo/Fdo/UnitTest/GeometryTest.cpp` (`testLineString` ~884, `CheckWkb` ~2034) |
| Upstream mirror (same unpatched code) | `jumpinjackie/fdo` `Fdo/Unmanaged/Src/Geometry/Fgf/GeometryFactory.cpp` @ 57d3349 |

## Notes / clean-up

- No source files were modified. No commit was made.
- Temporary reproduction files under `/tmp/wkbrepro` were removed.
- Upstream FDO (incl. the `jumpinjackie/fdo` mirror) still carries the unpatched XY-only code as of this investigation, so there is no upstream fix to align with.
