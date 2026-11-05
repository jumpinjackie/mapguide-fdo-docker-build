# Fix: Measure Distance on EPSG:3857 (ticket #2891)

**Status:** Implemented — the measurement rule now lives in `MgCoordinateSystemMeasure::GetDistance`,
so the viewer measure command, the MapAgent `geo.distance` operation and `MgGeometry::Distance` all
report the same number. **Viewer-level end-to-end run not done** (see [Not covered](#not-covered)).
**Date:** 2026-10-30, reworked 2026-11-06 after review feedback and to unify the two APIs
**Source tree:** `mapguide/MgDev` @ SVN `branches/4.0/MgDev`, revision 10261
**API/ABI mode:** `freeze`, scope `mapguide`. No symbol, signature or class layout moved: the only
shipped-header edit is a comment in
[`CoordinateSystemMeasure.h`](../mapguide/MgDev/Common/Geometry/CoordinateSystem/CoordinateSystemMeasure.h).
What changes is *behaviour*, deliberately — see [What changes for a user](#what-changes-for-a-user).
**Ticket:** [mapguide #2891](https://trac.osgeo.org/mapguide/ticket/2891) — *Measure Distance is
Incorrect When using PseudoMercator ESPG 3857*.

---

## What was wrong

Two pieces of code answered "how far apart are these two points?" and **they did not agree**:

- The **viewer measure command** (AJAX PHP/ASP.NET/Java and Fusion) chose by type in each script:
  `Geographic → geodesic, else planar`.
- The **library**, [`CCoordinateSystemMeasure::GetDistance`](../mapguide/MgDev/Common/CoordinateSystem/CoordSysMeasure.cpp),
  chose `Arbitrary → planar, else geodesic`. It is what the MapAgent `geo.distance` operation and
  `MgGeometry::Distance` report through.

So on an EPSG:3857 map the Measure panel reported a **planar** distance while `geo.distance` reported
the **geodesic** one — the same two clicked points, two different answers. And on a local grid such
as VICGRID94 the split ran the other way: the panel was planar, `geo.distance` geodesic.

Both were also wrong in their own way. The panel's planar measurement is not a ground distance on a
world projection; the library's geodesic measurement is not the grid distance a local grid's users
compute from the projected coordinates themselves.

The affected code, before the change:

| Viewer | File |
|---|---|
| AJAX (PHP) | [`Web/src/mapviewerphp/measure.php`](../mapguide/MgDev/Web/src/mapviewerphp/measure.php) |
| AJAX (ASP.NET) | [`Web/src/mapviewernet/measure.aspx`](../mapguide/MgDev/Web/src/mapviewernet/measure.aspx) |
| AJAX (Java) | [`Web/src/mapviewerjava/measure.jsp`](../mapguide/MgDev/Web/src/mapviewerjava/measure.jsp) |
| Fusion | [`Oem/fusion/layers/MapGuide/php/Measure.php`](../mapguide/MgDev/Oem/fusion/layers/MapGuide/php/Measure.php) |

`Oem/fusion` is an SVN external (`https://svn.osgeo.org/fusion/trunk`), so that copy is a change to the
**Fusion** repository, not to `MgDev`, and needs its own commit there. `Oem/fusion/build/` is Fusion
build output and is regenerated, so it is not edited by hand.

## Why 3857 is the worst case

Web Mercator is conformal with a local scale factor of 1/cos(latitude): its eastings are metres of a
sphere of radius 6378137, whatever the latitude. A planar measurement therefore overstates ground
distance by sec(lat):

| Latitude | Planar / geodesic |
|---|---|
| 0° | 1.000 |
| 30°N | 1.155 |
| 45°N | 1.414 |
| 51.5°N (London) | 1.606 |
| 60°N | 1.995 |
| 70°N | 2.918 |

Measured with the library itself: a 1° east-west segment at 60°N is 111 319.49 m in EPSG:3857
coordinates and 55 799.47 m on the WGS84 ellipsoid. A 10 km line drawn at 60°N reported 20 km.

## The fix

One rule, in the library, where every consumer already goes:

```cpp
INT32 type = m_pCoordSys->GetType();
distance = m_pCoordSys->MeasureEuclideanDistance(x1, y1, x2, y2);   // never fails; the fallback

if(MgCoordinateSystemType::Arbitrary != type)
{
    try
    {
        double geodesic = m_pCoordSys->MeasureGreatCircleDistance(x1, y1, x2, y2);
        if(MgCoordinateSystemType::Geographic == type ||
           ::fabs(geodesic - distance) > kdPlanarMeasurementTolerance * geodesic)
        {
            distance = geodesic;
        }
    }
    catch(MgException* e) { SAFE_RELEASE(e); }   // keep the planar value
}
```

- **Geographic** — always the geodesic. Its coordinates are angles, so the planar value is not a
  length at all. *Unchanged* from the library's previous behaviour.
- **Arbitrary (non earth)** — always planar. There is no ellipsoid. *Unchanged.*
- **Projected** — the geodesic takes over only when the two measurements disagree by more than 1%.

The four viewer scripts then become a single call, so there is no second copy of the rule to drift:

```php
$distance = $srsMap->GetMeasure()->GetDistanceSimple($x1, $y1, $x2, $y2);
```

(`GetDistanceSimple` is the PHP name of the four-double overload —
[`monkey_patch.i`](../mapguide/MgDev/Bindings/src/SwigCommon/Php/monkey_patch.i); C# and Java call
`GetDistance(x1, y1, x2, y2)`.)

It works because
[`MeasureGreatCircleDistance`](../mapguide/MgDev/Common/CoordinateSystem/CoordSys.cpp) **accepts
projected coordinates**: it calls `ConvertToLonLat` before `CS_llazdd`, and the
popularity-visualisation projection has a proper inverse (`csprm->cs2ll = CSmrcatI` in
`CS_mrcat.c`). It returns the distance in coordinate system units, so the existing
`ConvertCoordinateSystemUnitsToMeters` and the mi/km/ft conversions after it are unchanged.

### Why the 1% threshold, and not "always geodesic"

Review feedback on the first cut: preferring the geodesic for *every* projected system changes the
number for grids users have always measured on — "anyone used to their local projection, e.g Vic
State, and taking 2 points from that projected coord system to get an off-system calculated distance
will get a slightly different value". That is correct in principle, and the first cut was wrong to
trade a local grid's established answer for no benefit.

The gap between the two families is wide enough to drive a policy off it. Measuring a 5 km east-west
segment at a point inside each system's useful range, with the library:

| System | planar (m) | geodesic (m) | disagreement |
|---|---|---|---|
| **EPSG:3110 VICT** (Victorian grid, LCC) | 5 005.286 | 5 006.000 | **0.014%** |
| GA-W (Transverse Mercator, SF 0.9999) | 5 004.507 | 5 005.007 | 0.010% |
| UTM83-18 | 5 009.576 | 5 011.580 | 0.040% |
| EPSG:3857 at the equator | 4 999.977 | 4 999.977 | 0.000% |
| WORLD-MERCATOR at 16°N | 5 205.529 | 5 001.273 | **4.08%** |
| EPSG:3857 at 60°N (1° segment) | 111 319.49 | 55 799.47 | **99.5%** |

A grid chosen for its area is *locally representative* — that is what it is for — so its scale
factor is within a fraction of a percent of 1 and the two measurements agree. A world projection is
not, and they diverge by whole percent. 1% sits 25× above the widest local-grid margin measured
(UTM's 0.04%) and 4× below the smallest world-projection margin (WORLD-MERCATOR's 4.08% at 16°N),
so it separates the families with room on both sides.

The threshold is also self-limiting in the direction that matters: a number is only ever replaced by
one that differs from it by more than 1%, so no user sees a revised measurement smaller than the
error the revision removes. Below ~8° latitude EPSG:3857 stays on the planar path, where the two
agree to better than 1% anyway.

### Why the comparison, and not `MgCoordinateSystem::GetScale`

The coordinate system exposes the grid scale factor directly, and it is the quantity this threshold
is a proxy for. `GetScale` / `GetScaleH` / `GetScaleK`
([`CoordinateSystem.h`](../mapguide/MgDev/Common/Geometry/CoordinateSystem/CoordinateSystem.h)) sit
in the `PUBLISHED_API:` block, so all three bindings have them (the .NET surface dump lists
`[Method] Double GetScale(Double, Double)`), and they call CS-MAP's `CS_csscl` / `CS_cssch` /
`CS_cssck`, which document the intended use: *"Comparing this value to 1.0 will provide a reasonable
means of determining one aspect of projection distortion at any given point on the map."* Measured
against the ratios above, it reproduces them exactly:

| System | `GetScale` | measured planar/geodesic |
|---|---|---|
| VICT (−36.76°) | 0.999857 | 0.999857 |
| GA-W | 0.999900 | 0.999900 |
| UTM83-18 | 0.999600 | 0.999600 |
| WORLD-MERCATOR (16.15°N) | 1.040841 | 1.040841 |
| EPSG:3857 (equator) | 1.000000 | 1.000000 |

Coverage is good — over the 3 637 projected systems in the catalogue, 3 631 return a positive scale
at their range centre, none non-positive, and 36 distort by more than 1% — so it was a real
candidate. It was rejected for two measured reasons:

- **It reports one direction only.** `CS_csscl` returns "the most meaningful of the two values
  depending upon the projection", so on an anisotropic projection the distortion in the other
  direction is invisible. Measured at 45°N:

  | System | `GetScale` | `GetScaleH` | `GetScaleK` | E-W ratio | N-S ratio |
  |---|---|---|---|---|---|
  | WORLD-ROBINSON | 1.0757 | 0.9460 | 1.0757 | 1.0739 | **0.9464** |
  | CANADA-ALBERS | 1.0093 | **0.9908** | 1.0093 | 1.0093 | 0.9908 |
  | WORLD-SINUSOIDAL | 1.0076 | 1.0076 | 1.0000 | **1.0000** | 1.0076 |

  A sound rule would need `max(|H−1|, |K−1|)`, i.e. two more calls and a policy of its own.
  Measuring the segment is direction-agnostic for free.
- **The H/K labels disagree with the behaviour.** The header documents `GetScaleK` as "along
  parallels", yet on WORLD-SINUSOIDAL the east-west (parallel) ratio is 1.0000 while `GetScaleK` is
  1.0076 — it tracks the meridian. Building the rule on a label that contradicts the measurement is
  a maintenance trap.

The comparison also states the guarantee that matters: a distance changes only when it was wrong by
more than the tolerance *for that measurement*, rather than a claim about the map. The cost is one
geodesic computation that is sometimes discarded, which is a handful of CS-MAP conversions.

The property `GetScale` does offer is stability — it is a property of the map position, not the
segment, so it cannot flip between segments of a polyline near the threshold. That is theoretical
here: the ratio barely varies with length for realistic measurements (VICT measures 0.014% at 5 km
and 0.497% even for a 1 500 km line drawn far outside Victoria).

The other properties on the interface do not discriminate. `GetLonMin/Max` and `GetLatMin/Max` (the
declared useful range) separate VICT's 11.3° from Mercator's 361°, but conflate world with
continental and are absent entirely for some systems (`EURO-LM-CONIC` declares none). `GetGroup()` is
dictionary metadata: `EURO-LM-CONIC` is `GROUP: WORLD`, so a European projection would be treated as
a world one. `GetUnitScale()`, `GetMapScale()` and `GetScaleReduction()` are definition parameters,
not distortion — EPSG:3857 and VICT both report unit scale 1.0 and map scale 1.0.

### Why the try/catch is not optional

The geodesic is not available for every projected system. A sweep of the CS-MAP catalogue — 4 001
names read from `coordsys.asc`, 3 637 of them projected, each measured at a point inside its declared
useful range — found two real failures, `PNG-SG` and `MAUR-ZONE`, where `ConvertToLonLat` throws
*"outside of the mathematical domain of the coordinate system"*, plus `WORLD-MILLER` throwing at a
point its own declared bounds place inside the range (its `MIN_Y`/`MAX_Y` are unusable; `(0,0)`
converts fine). A further 72 entries could not be instantiated at all — the catalogue's `T-*` and
`TEST-*` test systems. No system returned a zero or negative distance.

For the viewers this changes nothing: they report a number for those maps, as before. For the
**library** it is a semantic change worth naming — `GetDistance` previously propagated that exception
to `geo.distance` callers, and now returns the planar measurement instead. It is the same choice the
viewers already made, and it is what makes the two agree.

## What changes for a user

| Map coordinate system | Measure panel, before | `geo.distance` / `MgGeometry::Distance`, before | Both, after |
|---|---|---|---|
| Geographic (LL84, …) | geodesic | geodesic | geodesic — unchanged |
| Arbitrary (non earth) | planar | planar | planar — unchanged |
| Local grid: State Plane, UTM, VICGRID94, … | planar | **geodesic** | **planar** (≤0.04% from the old panel value) |
| World projection: EPSG:3857, WORLD-MERCATOR, … | **planar** (wrong by sec(lat)) | geodesic | **geodesic** |
| Projected, no usable inverse projection | planar | **threw** | planar |

The two APIs now cannot disagree, because there is one implementation. `geo.distance` on a VICGRID94
map moves to the grid distance (a 0.014% change — 0.7 m in 5 km), and on an EPSG:3857 map it keeps
the ground distance it already reported while the panel starts reporting that same number.

## Verification

```
ninja mgserver MgUnitTesting
run_mapguide_tests.sh --mapguide-build-dir /tmp/work/build_area/mapguide --component CoordinateSystem --component Geometry
```

```
CoordinateSystem: All tests passed (46377 assertions in 191 test cases)
Geometry:         All tests passed (303 assertions in 40 test cases)
```

Neither suite recorded a LeakSanitizer direct or indirect record in that run; a repeated run of the
CoordinateSystem suite also returns the single 8-byte `ACE_Log_Msg` syslog-backend record already
recorded in
[mapguide-memory-leaks.md](./mapguide-memory-leaks.md#recorded-residue-8-bytes-from-aces-syslog-backend-intermittent-not-fixed),
which that record says not to read as a regression. Both PHP scripts pass `php -l` (8.1); the
`.aspx` and `.jsp` copies have no interpreter here.

`Geometry` is in the run because `MgGeometry::Distance` goes through the changed code. Its
`Distance` test uses an arbitrary measure and is unaffected; a new
`Distance (follows the measure's policy)` case pins that the geometry API returns exactly what the
measure returns, for arbitrary, geographic and projected measures — the property that keeps
`geo.distance` and the panel in step.

In the `CoordinateSystem` suite:

- `PseudoMercator_Measure_GetDistance` — EPSG:3857 built from WKT, two points at 60°N one degree of
  longitude apart: `GetDistance` equals `MeasureGreatCircleDistance`, `planar / geodesic` is
  2.0 ± 0.01 (measured 1.99499), and the geodesic converts to 55.7–55.9 km.
- `Projected_Measure_GetDistance` — the Transverse Mercator grid now expects the **planar** value
  (56970.20205 ft, 17364.55231 m) and asserts it equals `MeasureEuclideanDistance`; previously it
  expected the geodesic 56975.49704. This is the contract change, stated as a fixture.
- `Projected_Measure_PlanarIsLocallyRepresentative` — pins the small-end margin: the two
  measurements differ by 0.01% for this grid, two orders of magnitude below the 1% trigger.

## Not covered

- **The viewers were not run end to end.** That needs a web tier and a live server with a map in a
  3857 coordinate system. What is tested is the library rule they now call, and the geometry API's
  use of it; the script diff is one call per viewer (plus its comment).
- **Fusion** must be rebuilt for its copy of the fix to reach `Oem/fusion/build/`.
