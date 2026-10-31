# Fix: Measure Distance on EPSG:3857 (ticket #2891)

**Status:** Implemented — the four viewer measure scripts now measure along the ellipsoid, with the
planar measurement kept as the fallback, and a regression test added. **Viewer-level end-to-end run
not done** (see [Not covered](#not-covered)).
**Date:** 2026-10-30
**Source tree:** `mapguide/MgDev` @ SVN `branches/4.0/MgDev`, revision 10235
**API/ABI mode:** `freeze`, scope `mapguide`. Nothing binding-visible moved: the changed viewer
scripts are not part of the SWIG surface, no C++ header changed, and `Bindings/src/ApiDump/api.*.txt`
is unaffected.
**Ticket:** [mapguide #2891](https://trac.osgeo.org/mapguide/ticket/2891) — *Measure Distance is
Incorrect When using PseudoMercator ESPG 3857*.

---

## The defect

The viewers do not measure client-side. `measureui.templ` posts each segment's map coordinates to a
server-side script, which computes that segment's length and accumulates the total. The script
picked its measurement method from the map coordinate system **type**:

```php
if($srsType == MgCoordinateSystemType::Geographic)
    $distance = $srsMap->MeasureGreatCircleDistance($x1, $y1, $x2, $y2);
else
    $distance = $srsMap->MeasureEuclideanDistance($x1, $y1, $x2, $y2);
```

So the geodesic was used for a *geographic* system only. Every **projected** system — EPSG:3857
included — was measured with `MeasureEuclideanDistance`, i.e. Pythagoras on the projected
coordinates ([`CoordSys.cpp`](../mapguide/MgDev/Common/CoordinateSystem/CoordSys.cpp)). 3857 is not
special-cased anywhere; it is simply the projection where the planar assumption breaks down badly
enough to be reported.

The same decision is copy-pasted into every viewer flavour:

| Viewer | File |
|---|---|
| AJAX (PHP) | [`Web/src/mapviewerphp/measure.php`](../mapguide/MgDev/Web/src/mapviewerphp/measure.php) |
| AJAX (ASP.NET) | [`Web/src/mapviewernet/measure.aspx`](../mapguide/MgDev/Web/src/mapviewernet/measure.aspx) |
| AJAX (Java) | [`Web/src/mapviewerjava/measure.jsp`](../mapguide/MgDev/Web/src/mapviewerjava/measure.jsp) |
| Fusion | [`Oem/fusion/layers/MapGuide/php/Measure.php`](../mapguide/MgDev/Oem/fusion/layers/MapGuide/php/Measure.php) |

`Oem/fusion` is an SVN external (`https://svn.osgeo.org/fusion/trunk`), so that last one is a change
to the **Fusion** repository, not to `MgDev`, and needs its own commit there. `Oem/fusion/build/` is
Fusion build output and is regenerated, so it is not edited by hand.

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

The ellipsoidal measurement becomes the default; only an **arbitrary** (non-earth) coordinate system
and a system whose geodesic computation fails keep Pythagoras:

```php
$srsType = $srsMap->GetType();
if($srsType == MgCoordinateSystemType::Arbitrary)
{
    $distance = $srsMap->MeasureEuclideanDistance($x1, $y1, $x2, $y2);
}
else
{
    try
    {
        $distance = $srsMap->MeasureGreatCircleDistance($x1, $y1, $x2, $y2);
    }
    catch(MgException $e)
    {
        $distance = $srsMap->MeasureEuclideanDistance($x1, $y1, $x2, $y2);
    }
}
```

The arbitrary-system rule is not new; it is the rule the library already uses in
[`CCoordinateSystemMeasure::GetDistance`](../mapguide/MgDev/Common/CoordinateSystem/CoordSysMeasure.cpp),
which is what `MgGeometry::Distance(geometry, measure)` and the MapAgent `geo.distance` operation
report with. Those were already correct for 3857 — measuring the same two points through
`geo.distance` and through the Measure panel was the quickest way to see the discrepancy.

It works because
[`MeasureGreatCircleDistance`](../mapguide/MgDev/Common/CoordinateSystem/CoordSys.cpp) **accepts
projected coordinates**: it calls `ConvertToLonLat` before `CS_llazdd`, and the
popularity-visualisation projection has a proper inverse (`csprm->cs2ll = CSmrcatI` in
`CS_mrcat.c`). It returns the distance in coordinate system units, so the existing
`ConvertCoordinateSystemUnitsToMeters` and the mi/km/ft conversions after it are unchanged.

### Why the try/catch is not optional

The geodesic is not available for every projected system. A sweep of the CS-MAP catalogue — 4 001
names read from `coordsys.asc`, 3 637 of them projected, each measured at a point inside its declared
useful range — found two real failures, `PNG-SG` and `MAUR-ZONE`, where `ConvertToLonLat` throws
*"outside of the mathematical domain of the coordinate system"*, plus `WORLD-MILLER` throwing at a
point its own declared bounds place inside the range (its `MIN_Y`/`MAX_Y` are unusable; `(0,0)`
converts fine). A further 72 entries could not be instantiated at all — the catalogue's `T-*` and
`TEST-*` test systems. No system returned a zero or negative distance.

Without the fallback those maps would start throwing "measure failed" in the panel, where today they
report an approximate distance. The fallback keeps the previous answer for exactly the systems that
cannot do better, so the change can only improve a measurement and never break one.

## What else changes

For every projected system the geodesic succeeds on, the reported distance changes. Local grid
projections lose their grid scale factor from the measurement — a UTM measurement is no longer
multiplied by 0.9996 — and equal-area projections lose theirs. That is more correct (the number now
means ground distance), but it is a visible behaviour change in all four viewers, so it belongs in
the ticket/release note.

The narrow alternative, special-casing the pseudo-Mercator (projection `MRCAT-PV` / CS code
`WGS84.PseudoMercator`), would have confined the change but leaves every other world projection with
the same sec(lat) error — `WORLD-MERCATOR` is the ellipsoidal Mercator and is just as wrong at high
latitude.

## Verification

The regression test is `PseudoMercator_Measure_GetDistance` in
[`TestCoordinateSystem.cpp`](../mapguide/MgDev/Server/src/UnitTesting/TestCoordinateSystem.cpp). It
builds EPSG:3857 from WKT, asserts the type is `Projected`, takes two points at 60°N one degree of
longitude apart, and pins three things:

- `MgCoordinateSystemMeasure::GetDistance` equals `MeasureGreatCircleDistance` — the measure the
  viewers report with must take the geodesic path for a projected system;
- `planar / geodesic` is 2.0 ± 0.01 (the secant relation; measured at 1.99499);
- the geodesic value converts to 55.7–55.9 km, the length of that parallel.

The existing `Projected_Measure_GetDistance` case could not catch this: its Transverse Mercator test
projection has a scale factor of 0.9999, so planar and geodesic there differ by 0.01% and the case
passes either way. 3857 is what makes the two answers distinguishable.

Result, Debug (`ubuntu22`), running the component out of the existing build tree:

```
build_mapguide_incremental.sh
run_mapguide_tests.sh --mapguide-build-dir /tmp/work/build_area/mapguide --component CoordinateSystem
```

```
All tests passed (46371 assertions in 190 test cases)
```

No LeakSanitizer direct or indirect records in the suite log. The two PHP scripts also pass `php -l`
(8.1); the `.aspx` and `.jsp` copies have no interpreter here.

## Not covered

- **The viewers were not run end to end.** That needs a web tier and a live server with a map in a
  3857 coordinate system; only the library contract the scripts now depend on is tested here, and
  the new `catch` around `MeasureGreatCircleDistance` is unexercised (the same `catch(MgException $e)`
  shape already guards the whole of `measure.php`, so the binding semantics are not in doubt).
- **Fusion** must be rebuilt for its copy of the fix to reach `Oem/fusion/build/`.
