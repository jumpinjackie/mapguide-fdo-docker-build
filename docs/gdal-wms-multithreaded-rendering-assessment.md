# GDAL and WMS FDO providers: suitability for multi-threaded raster stylization

**Question asked:** can the GDAL (and, by extension, the WMS) FDO provider now be used safely from
multiple threads during MapGuide rendering/stylization, so that the process-wide *global raster
stylization lock* in `MgMappingUtil::StylizeLayers()` can be removed?

**Answer:** **No — not yet.** Two of the three "layers" of the problem have been resolved or are
tractable, but there are concrete, reachable defects that the global lock is currently *masking*, and
one of the two providers still declares itself single-threaded in a way that makes MapGuide serialise
it anyway. Removing the lock today would trade a performance bottleneck for a class of intermittent,
load-dependent crashes and stale-image bugs.

This document records the evidence, the remaining road blocks, and a suggested way forward. It is a
static analysis of the trees at the revisions below plus the packaged GDAL; no new concurrency tests
were written for it (see [Verification plan](#verification-plan)).

| Item | Revision / version |
|------|--------------------|
| `fdo` working copy | `branches/4.2` r8410 |
| `mapguide/MgDev` working copy | `branches/4.0/MgDev` r10218 (clean, no local mods) |
| GDAL used by `ubuntu22` builds | **system GDAL 3.4.1** (`/usr/lib/libgdal.so`, from `libgdal-dev`); confirmed in `build_area/x64/Release/ubuntu22/fdo/fdo/CMakeCache.txt` |
| GDAL used by `generic` builds | **internal GDAL 2.4.4** (`fdo/Thirdparty/gdal`, `VERSION` = 2.4.4) |
| API/ABI mode at time of writing | `freeze` (see [AGENTS.md](../AGENTS.md#current-cycle)) — nothing here requires a shipped-surface change |

> Note the GDAL split: `ubuntu22` links the distro GDAL, `generic` builds the vendored 2.4.4
> ([README.md](../README.md), FDO thirdparty matrix). Any conclusion about GDAL's own thread-safety
> has to be validated on both, and the two are two minor versions apart.

---

## 1. What the lock actually is, and what it covers

The lock lives in `MgMappingUtil::StylizeLayers()`
([MappingUtil.cpp](../mapguide/MgDev/Server/src/Services/Mapping/MappingUtil.cpp)) and has existed
since r3218 (2008, *"#610: Raster performance and stability"*), where it was introduced with the
comment:

```c++
// TODO: FDO RFP - Make FdoPtr's reference counter thread-safe.
static ACE_Recursive_Thread_Mutex sg_fdoRfpMutex;
```

It was made toggleable in r9836 (2021, *Fixes #2830*):

```c++
MgConfiguration* pConf = MgConfiguration::GetInstance();
bool bUseGlobalLock = true;
pConf->GetBoolValue(MgConfigProperties::RenderingServicePropertiesSection,
    MgConfigProperties::RenderingServicePropertiesGlobalRasterStylizationLockEnabled,
    bUseGlobalLock,
    MgConfigProperties::DefaultRenderingServicePropertiesGlobalRasterStylizationLockEnabled);
```

- `[RenderingServiceProperties] GlobalRasterStylizationLockEnabled` — default `1`
  ([serverconfig.ini](../mapguide/MgDev/Server/src/Core/serverconfig.ini#L381),
  [ConfigProperties.cpp](../mapguide/MgDev/Common/MapGuideCommon/System/ConfigProperties.cpp#L326)).
- Key detail: the mutex is a **function-local `static`**, i.e. one instance for the whole process, and
  it guards **grid layers only** — `else if (gl)` in `StylizeLayers()`
  ([MappingUtil.cpp:622](../mapguide/MgDev/Server/src/Services/Mapping/MappingUtil.cpp#L622)).
  Vector and drawing layers take no such lock and are already stylized concurrently today.

It is held around exactly two things:

| # | Guarded region | Line |
|---|----------------|------|
| 1 | `TransformCache::GetLayerToMapTransform(...)` — builds the layer→map coordinate-system transform | [652-660](../mapguide/MgDev/Server/src/Services/Mapping/MappingUtil.cpp#L652) |
| 2 | `ExecuteRasterQuery(...)` — builds the `RESAMPLE(...)` computed property and calls `svcFeature->SelectFeatures(...)` | [755-765](../mapguide/MgDev/Server/src/Services/Mapping/MappingUtil.cpp#L755) |

**The lock does *not* cover the raster read.** After the guard is released, the same block runs:

```c++
ds->StylizeGridLayer(gl, dr, rsReader, xformer, scale, NULL, NULL);   // line 771
```

and `DefaultStylizer::StylizeGridLayer()` is what drives the actual pixel traffic —
`features->ReadNext()` then `features->GetRaster(rpName)`
([DefaultStylizer.cpp:474-484](../mapguide/MgDev/Common/Stylization/DefaultStylizer.cpp#L474)).
So the lock's critical section is *query setup + query execution*, not the raster transfer. That is
worth keeping in mind: whatever currently protects the transfer is something else (see
[§3](#3-mapguide-side-the-connection-pool-is-already-a-global-raster-lock) and
[§4.3](#43-what-is-and-is-not-covered-by-ggdalmutex)).

The `MgPortable` twin of this code
([Portable/…/MappingUtil.cpp:612](../mapguide/MgDev/Portable/MgPortable/Services/Rendering/MappingUtil.cpp#L612))
has the same static mutex but **no config toggle** — it is unconditionally on. Any decision to make
the lock opt-in must be mirrored there (or the two will disagree in hosted deployments).

## 2. What "multi-threaded rendering" means here

The concurrency comes from the server's ACE client-connection thread pool, not from threads spawned
inside a single map render:

- `[ClientConnectionProperties]` sets `MaxConnections = 100` (line 162) and `ThreadPoolSize = 20`
  (line 165) ([serverconfig.ini:141-165](../mapguide/MgDev/Server/src/Core/serverconfig.ini#L141)) — up
  to 20 client operations execute concurrently, each on its own thread.
- `MgServerRenderingService::RenderMapInternal()` itself is single-threaded and creates its
  `DefaultStylizer` / `AGGRenderer` locally
  ([ServerRenderingService.cpp:1219](../mapguide/MgDev/Server/src/Services/Rendering/ServerRenderingService.cpp#L1219)),
  so per-request renderer/stylizer/`LineBufferPool`/`RasterAdapter` state is thread-confined.
- Concurrency therefore arises from *many simultaneous requests* — map images, `RenderTile` /
  `RenderTileXYZ` / dynamic overlays, metatiles, KML, etc. The tile service only serialises per
  metatile path (`MgMetatileLockUtil`), so different tiles really do render in parallel threads.
- Both the map path ([ServerRenderingService.cpp:1864](../mapguide/MgDev/Server/src/Services/Rendering/ServerRenderingService.cpp#L1864))
  and the tile path ([:1949](../mapguide/MgDev/Server/src/Services/Rendering/ServerRenderingService.cpp#L1949))
  funnel into `MgMappingUtil::StylizeLayers()`, so the single static mutex is shared by *all* raster
  rendering in the process.

## 3. MapGuide side: the connection pool is already a global raster lock

This is the most important structural finding, and it is independent of the config setting.

Each provider declares a thread capability; MapGuide's `FdoConnectionManager` uses it to size the
connection pool and to decide whether a connection that is `bInUse` may be shared:

- GDAL: `FdoThreadCapability_SingleThreaded`
  ([FdoRfpConnectionCapabilities.cpp:29](../fdo/Providers/GDAL/Src/Provider/FdoRfpConnectionCapabilities.cpp#L29))
- WMS: `FdoThreadCapability_PerConnectionThreaded`
  ([FdoWmsConnectionCapabilities.cpp:37](../fdo/Providers/WMS/Src/Provider/FdoWmsConnectionCapabilities.cpp#L37))
- OGR (for reference): see `fdo/Providers/OGR`.

`ProviderInfo::SetThreadModel()` clamps the pool to **1 connection** for a single-threaded provider
([FdoConnectionManager.h:135-146](../mapguide/MgDev/Server/src/Common/Manager/FdoConnectionManager.h#L135)),
and `AcquireFdoConnection()` reports "no connection available" while that one connection is checked out
unless the provider is `PerCommandThreaded`/`MultiThreaded`
([FdoConnectionManager.cpp:1461-1470](../mapguide/MgDev/Server/src/Common/Manager/FdoConnectionManager.cpp#L1461)).
`TryAcquireFdoConnection()` then **polls every 100 ms for up to 600 retries (1 minute)** before throwing
`MgAllProviderConnectionsUsedException`
([FdoConnectionManager.cpp:1930-1965](../mapguide/MgDev/Server/src/Common/Manager/FdoConnectionManager.cpp#L1930)).

The FDO connection is not released when the query returns — it is held by the reader for its whole
life: `MgServerFeatureReader` stores `Ptr<MgServerFeatureConnection> m_connection` and takes ownership
of it ([ServerFeatureReader.cpp:37-43](../mapguide/MgDev/Server/src/Services/Feature/ServerFeatureReader.cpp#L37),
[ServerFeatureReader.h:574](../mapguide/MgDev/Server/src/Services/Feature/ServerFeatureReader.h#L574),
constructed in [SelectCommand.cpp:227](../mapguide/MgDev/Server/src/Services/Feature/SelectCommand.cpp#L227)),
and `RSMgFeatureReader` keeps that reader alive across the whole `StylizeGridLayer()` loop.

**Consequence:** with GDAL declared `SingleThreaded`, a GDAL grid layer *already* serialises against
every other concurrent request in the process — for the whole duration of query **and** raster read,
including the part outside `sg_fdoRfpMutex`. Two threads that both want a GDAL raster cannot proceed in
parallel; the second waits on a 10 Hz poll loop and, under sustained load, can time out with
`MgAllProviderConnectionsUsedException` after a minute.

So today there are effectively **two** global raster locks: the explicit one in `MappingUtil`, and the
implicit one imposed by the GDAL provider's capability declaration. **Disabling
`GlobalRasterStylizationLockEnabled` does not give parallel GDAL raster stylization** — it only removes
one of the two, and the weaker one at that (the pool mutex actually spans more work). Anything that
drives the raster concurrently through a different route — e.g. an FDO connection obtained outside the
pool, another service, a second server process sharing a tile cache — is *not* covered by the implicit
lock.

That is the first road block:

> **RB-1.** With GDAL declaring `FdoThreadCapability_SingleThreaded`, the intended benefit
> (parallel raster stylization) is not achievable by turning off the lock. The capability declaration
> is the thing that has to change, and it can only change once the provider is genuinely safe for
> concurrent use.

## 4. GDAL provider audit

### 4.1 The provider declares itself single-threaded, on purpose

```c++
FdoThreadCapability FdoRfpConnectionCapabilities::GetThreadCapability()
{
    return FdoThreadCapability_SingleThreaded;
}
```

and the unit suite asserts it: `FDO_CPPUNIT_ASSERT (capabilities->GetThreadCapability() ==
FdoThreadCapability_SingleThreaded);`
([RfpTestThorough.cpp:372](../fdo/Providers/GDAL/Src/UnitTest/RfpTestThorough.cpp#L372)). Any change
here is a deliberate contract change that the test must be updated with.

### 4.2 There is already a process-wide GDAL lock inside the provider

`fdo/Providers/GDAL/Src/Provider/FdoRfpDatasetCache.cpp` defines a **file-scope** mutex and a scoped
holder:

```c++
static FdoCommonThreadMutex g_GdalMutex;          // line 194

FdoGdalMutexHolder::FdoGdalMutexHolder() { g_GdalMutex.Enter(); }   // line 196
FdoGdalMutexHolder::~FdoGdalMutexHolder() { g_GdalMutex.Leave(); }  // line 201
```

`FdoCommonThreadMutex` is recursive on Linux (`PTHREAD_RECURSIVE_MUTEX_INITIALIZER_NP`, copied per
instance) ([FdoCommonThreadMutex.cpp:24](../fdo/Utilities/Common/Src/FdoCommonThreadMutex.cpp#L24)),
which is required because the holder is taken re-entrantly (`GetDataModel()` → `GetImage()` →
`GetDS()` → `LockDataset()`).

So the provider is, by construction, a **globally serialised GDAL client**: every `GDALDatasetH` in
the process is opened, read and closed under one lock. It is thread-*safe* in the narrow sense, and
thread-*incapable* in the useful sense.

### 4.3 What is and is not covered by `g_GdalMutex`

Call-site inventory (verified by walking every `GDAL*`/`CPL*` call and its enclosing function):

| File / function | GDAL calls | Under `g_GdalMutex`? |
|---|---|---|
| `FdoRfpDatasetCache::LockDataset` | `GDALOpen`, `GDALGetDescription`, `GDALReferenceDataset`, `GDALDereferenceDataset`, `CPLPush/PopErrorHandler`, `CPLRealloc` | yes (whole body) |
| `FdoRfpDatasetCache::UnlockDataset` / `CloseDataset` / `CloseUnlocked` / `CloseAll` | `GDALDereference/ReferenceDataset`, `GDALClose` | yes |
| `FdoRfpImage::Initialize` | `GDALGetRasterBand/Count/DataType`, `GDALGetBlockSize`, … | yes |
| `FdoRfpBandRaster::GetDataModel` / `GetNullPixelValue` | `GDALGetRasterBand`, `GDALGetRasterColorInterpretation`, `GDALGetRasterNoDataValue` | yes |
| `FdoRfpRasterPropertyDictionary::GetProperty` | `GDALGetRasterColorTable`, `GDALGetColorEntry*` | yes |
| `FdoRfpGeoBandRasterImp::loadImageInfo` | `GDALGetRasterXSize/YSize` | yes |
| `FdoRfpGeoRasterExtractor::ExtractRasters` | `GDALGetRasterXSize/YSize` (+ `GetGeoReferenceInfo`) | yes (per file, in the loop) |
| **`FdoRfpStreamReaderGdalByTile::_getTile`** (default read path) | **`GDALDatasetRasterIO`** + colour-table lookups | **yes** ([FdoRfpStreamReaderByTile.cpp:423-426](../fdo/Providers/GDAL/Src/Provider/FdoRfpStreamReaderByTile.cpp#L423)) |
| **`FdoRfpStreamReaderGdalByTileResample::_getTile`** (the `ResamplingMethod` read path) | `GDALGetDriverByName`, `GDALOpen` ×2, `GDALCreateWarpOptions`, `GDALCreateWarpOperation`, `GDALWarpRegion`, `GDALClose` ×2, `GDALDestroyWarp*`, `CPLPrintPointer` | **NO — no holder anywhere in the function** ([FdoRfpStreamReaderByTileResample.cpp:105-218](../fdo/Providers/GDAL/Src/Provider/FdoRfpStreamReaderByTileResample.cpp#L105)) |
| `FdoRfpRasterUtil::GetGeoReferenceInfo` / `GetLastGdalErrorMessage` | `GDALGetGeoTransform`, `GDALGetProjectionRef`, `CPLErrorReset`, `CPLGetLastErrorMsg` | helpers take no lock; today every caller holds it |
| `FdoRfpStreamReaderGdalByTile` ctor/dtor, `FdoRfpDatasetCache` dtor | `CPLMalloc`/`CPLFree` | n/a (thread-safe heap ops) |

Two observations:

1. The `ResamplingMethod` path is a **genuine hole**. `ResamplingMethod` is a first-class connection
   property ([FdoRfpConnectionInfo.cpp:112-117](../fdo/Providers/GDAL/Src/Provider/FdoRfpConnectionInfo.cpp#L112),
   read in [FdoRfpConnection.cpp:371](../fdo/Providers/GDAL/Src/Provider/FdoRfpConnection.cpp#L371)),
   and when it is non-empty `FdoRfpBandRaster::GetStreamReader()` selects the warp-based reader
   ([FdoRfpBandRaster.cpp:626-641](../fdo/Providers/GDAL/Src/Provider/FdoRfpBandRaster.cpp#L626)).
   Those reads happen lazily in `_moveTo()`/`_getTile()` — which `MgMappingUtil` calls **outside**
   `sg_fdoRfpMutex`. Under this configuration MapGuide has *no* lock protecting the GDAL warp calls at
   all. (MapGuide's own feature-source editor does not write `ResamplingMethod`, but it is settable and
   is exercised by the provider's own `RfpTestResample` suite, which opens with
   `...;ResamplingMethod=BILINEAR`.)
2. `GetGeoReferenceInfo()`/`GetLastGdalErrorMessage()` are unguarded `static` helpers that are only
   safe because every current caller happens to hold the lock. That is fragile and easy to break.

> **RB-2.** The `ResamplingMethod` (= warp) raster path bypasses `g_GdalMutex` entirely. Any plan to
> rely on the provider's internal lock instead of MapGuide's must first close this hole.

### 4.4 The "multi-threaded" build switch is dead code

`GRFP_EXPERIMENTAL_MULTI_THREADED_SUPPORT` is referenced in 13 places across the provider — 12
`#ifndef … #endif` blocks around an `FdoGdalMutexHolder`, plus one `#ifdef` branch in
`FdoRfpConnection::_buildUpDefaultFeatureSchema()`
([FdoRfpConnection.cpp:256-277](../fdo/Providers/GDAL/Src/Provider/FdoRfpConnection.cpp#L256)).
It is **defined nowhere**: not in the provider/tree `CMakeLists.txt`, not in the `.vcxproj`/`.vcproj`,
not in any build script. So:

- The safe (locked) branch is what everyone builds, and the switch has evidently never been compiled.
- Flipping it removes *all* the locking at once, including around
  `GDALReferenceDataset`/`GDALDereferenceDataset` (plain `++`/`--` on `GDALDataset::nRefCount`) and the
  dataset-cache LRU list (`pahDatasetList`/`nDatasetCount`). That is not a safe change on its own — the
  cache's own bookkeeping would need its own synchronisation, independently of GDAL.
- When enabled it also turns on a process-wide cached default schema
  (`static FdoFeatureSchemaCollection* s_cachedDefaultSchema`, line 260) that is then deep-copied per
  connection. That path is worth reviewing before it is ever enabled.

> **RB-3.** The only multi-threading mechanism the provider has is an all-or-nothing compile switch
> that has never been built or tested, and that as written would also remove the locking the provider's
> own data structures need.

### 4.5 Per-connection state (safe *because* MapGuide uses one connection at a time)

- `FdoRfpDatasetCache` is **per connection** (`FdoPtr<FdoRfpDatasetCache> m_datasetCache`,
  [FdoRfpConnection.h:61](../fdo/Providers/GDAL/Src/Provider/FdoRfpConnection.h#L61)), not a process
  singleton. Two connections would have two caches and could hold two `GDALDatasetH` for the same file;
  that is legal for GDAL, but it means the LRU cap (`nOpenDatasetMaximum = 3`) is *per connection*, so
  raising concurrency raises open file descriptors by 3×N.
- Schema/spatial-context/class data are per connection and mutated only during `Open()`
  ([FdoRfpConnection.cpp:359-405](../fdo/Providers/GDAL/Src/Provider/FdoRfpConnection.cpp#L359)).
- `FdoRfpConnection::CreateConnection()` guards its `static int bInitialized` with the mutex before
  calling `GDALAllRegister()` ([FdoRfpConnection.cpp:56-63](../fdo/Providers/GDAL/Src/Provider/FdoRfpConnection.cpp#L56)) — correct.
- The provider never calls `FdoIDisposable::EnableGlobalThreadLocking()`; it relies on the host
  application for thread-safe refcounting.

## 5. WMS provider audit

WMS is the more interesting case because it *claims* to be concurrency-capable and MapGuide therefore
does allocate one connection per thread and lets threads run concurrently.

### 5.1 What is per-connection and fine

- `mWmsServiceMetadata` (capabilities document) is per connection, fetched in `Open()`
  ([FdoWmsConnection.cpp:433](../fdo/Providers/WMS/Src/Provider/FdoWmsConnection.cpp#L433)).
- The HTTP client is created per request: `FdoOwsHttpHandler::Create(...)` in
  `FdoOwsDelegate::Invoke()`, with a fresh `CURL*` from `curl_easy_init()` per handler
  ([FdoOwsHttpHandler.cpp:396](../fdo/Utilities/OWS/Src/FdoOwsHttpHandler.cpp#L396)) and
  `curl_easy_cleanup` at the end (line 579). No handles or `CURLSH` are shared between threads.
  The handler copies the response into its own buffer; its own mutex/condition-variable pair only
  guards the handler's private state.
- GDAL datasets used to decode the returned image bytes are per-`FdoWmsRasterGdal` instance.
- There is **no lock anywhere in the provider** (`grep -rn "Mutex|mutex|CriticalSection"` over
  `Providers/WMS/Src/Provider` returns nothing). Everything rests on "one thread per connection" and on
  GDAL/libcurl's own behaviour.

### 5.2 Global mutable state found in WMS (and reachable from a raster)

**(a) `_reverseCheck()`'s lazily-populated static — a real data race.**

```c++
FdoBoolean _reverseCheck(FdoStringP epsgName)          // FdoWmsUtils.cpp:113
{
    static vector<wstring> epsgList;                    // line 119
    if (epsgList.empty())                               // line 121
    {
        for (...) epsgList.push_back(...);              // lines 125-126
        ... read ExtendedReverseEPSGs file, push_back ...
    }
    vector<wstring>::iterator it = find(epsgList.begin(), epsgList.end(), s);   // line 146
```

`_reverseCheck` is called for every EPSG-coded `GetMap` at WMS 1.3.0+ from `_encodeGetMapURL()`
([FdoWmsUtils.cpp:251](../fdo/Providers/WMS/Src/Provider/FdoWmsUtils.cpp#L251)), which is on the
path taken by `FdoWmsGetMap` — i.e. **every WMS raster request**. The initialisation is neither
atomic nor guarded: two threads that both observe `empty()` concurrently will both `push_back` into the
same `std::vector` (heap corruption / lost writes), and a third thread calling `find()` while a
`push_back` reallocates is a use-after-free. There is no `std::once`/mutex anywhere in the file.

Today this is masked twice over: MapGuide's `sg_fdoRfpMutex` serialises the `SelectFeatures()` call that
issues the GetMap, and in any case the first request(s) normally populate the list before load builds
up. **Remove the lock and the first concurrent WMS raster burst becomes the trigger.**

> **RB-4.** `FdoWmsUtils.cpp::_reverseCheck` has an unsynchronised lazy static that every WMS raster
> request touches.

**(b) `/vsimem` registration that is never released.**

`FdoWmsRasterGdal::_getDataset()` dumps the downloaded image into a heap buffer and hands it to GDAL's
**process-global** `/vsimem` filesystem
([FdoWmsRasterGdal.cpp:66-77](../fdo/Providers/WMS/Src/Provider/FdoWmsRasterGdal.cpp#L66)):

```c++
char vfileName[64];
sprintf(vfileName, "/vsimem/%d", (FdoSize)this);                       // line 69
VSILFILE *fp = VSIFileFromMemBuffer(vfileName, m_rasterBuffer, m_rasterBufferSize, FALSE);
VSIFCloseL( fp );
m_gdalDataSet = GDALOpen(vfileName, GA_ReadOnly);
```

Three problems:

1. The name is derived from `this`, which is fine for uniqueness *while the object lives*, but there is
   **no `VSIUnlink()` anywhere in the provider** — the `/vsimem` entry outlives the object and keeps
   pointing at a buffer the destructor `delete[]`s. The global `/vsimem` table therefore grows by one
   entry per WMS raster request and accumulates dangling pointers. (GDAL's own `VSIMemFilesystemHandler`
   does guard the table with a global mutex, so the table itself is not corrupted — but nothing is ever
   removed.)
2. The format string is `%d` against a pointer-width `FdoSize`. On x64 this truncates the address to
   its low 32 bits. That is both undefined behaviour in a varargs call *and* a much weaker uniqueness
   key: two live `FdoWmsRasterGdal` objects whose addresses differ only in the upper 32 bits would
   produce the same `/vsimem/…` name, and the second `VSIFileFromMemBuffer` **replaces** the first
   (`Unlink_unlocked` then insert), so one thread would silently decode the other's buffer.
3. Because the entry is a global resource keyed on an address, address reuse across threads is exactly
   the scenario where "harmless in a serialised server" stops being harmless.

**(c) `GDALAllRegister()` / `GDALDestroyDriverManager()` from a static object.**

```c++
class GDALRegister { GDALRegister(){ GDALAllRegister(); } ~GDALRegister(){ GDALDestroyDriverManager(); } };
GDALRegister g_GDALRegister;      // FdoWmsConnection.cpp:79 — runs at DSO load
```

The WMS provider asserts ownership of *shared* GDAL lifecycle state that the GDAL provider, the OGR
provider and `libOWS`-based providers also depend on. `GDALAllRegister()` at load time is benign
(idempotent, and it happens before any thread), but `GDALDestroyDriverManager()` in a static destructor
tears down the shared driver manager while other providers may still hold cached datasets — a
shutdown-time (or, if FDO ever calls `FdoConnectionManager::FreeLibrary()`, mid-run) use-after-free.
This is not a new consequence of the lock setting, but it is a reason to be careful about claiming WMS
"just works" concurrently.

**(d) `curl_global_init()` is never called.**

Neither the WMS provider nor `libOWS` nor any other FDO component calls `curl_global_init()`. The
handler relies on `curl_easy_init()`'s implicit global initialisation
([FdoOwsHttpHandler.cpp:396](../fdo/Utilities/OWS/Src/FdoOwsHttpHandler.cpp#L396)), which libcurl
documents as not thread-safe; libcurl expects `curl_global_init()` to be called once, single-threaded,
before any other call. With a serialised GetMap the implicit init happens inside one thread; with
concurrent GetMaps the first burst can call it from several threads at once. (Note the MapGuide tree
does contain a curl net-accessor at `mapguide/MgDev/Oem/dbxml/xerces-c-src/.../NetAccessors/Curl/CurlNetAccessor.cpp:66`
that calls `curl_global_init`, but that copy of xerces is not used on `ubuntu22`, which links the
system xerces-c — so it cannot be relied on.)

> **RB-5.** FDO's HTTP stack never calls `curl_global_init()`; concurrent first use is a libcurl-documented
> thread-safety violation.

**(e) Connection-level mutable cache written by a select command.**

`FdoWmsSelectCommand::Execute()` caches the GetMap parameters on the connection for a later
`GetFeatureInfo` ([FdoWmsSelectCommand.cpp:390](../fdo/Providers/WMS/Src/Provider/FdoWmsSelectCommand.cpp#L390) →
[FdoWmsConnection.cpp:886](../fdo/Providers/WMS/Src/Provider/FdoWmsConnection.cpp#L886)). This is
consistent with `PerConnectionThreaded` (one thread per connection at a time) and MapGuide's pool
respects that, but it means a WMS *connection* is not re-entrant: anything that ever hands the same
connection to two threads, or removes the `bInUse` check, corrupts the raster/feature-info pairing.

## 6. FDO Core findings

### 6.1 Reference counting: fixed, and already enabled by MapGuide

`FdoIDisposable::AddRef`/`Release` are non-atomic by default and switch to `__sync_add_and_fetch` /
`InterlockedIncrement` when either the global or the per-object locking flag is set
([IDisposable.cpp:34-90](../fdo/Fdo/Unmanaged/Src/Common/IDisposable.cpp#L34),
[IDisposable.h:66](../fdo/Fdo/Unmanaged/Inc/Common/IDisposable.h#L66)). MapGuide turns the global flag
on at server start:

- [Server.cpp:930](../mapguide/MgDev/Server/src/Core/Server.cpp#L930) — `FdoIDisposable::EnableGlobalThreadLocking(true);` immediately after `libFDO` is loaded.
- [PlatformInit.cpp:172](../mapguide/MgDev/Portable/MgPortable/System/PlatformInit.cpp#L172) — same for `MgPortable`.
- WMS also does it from its provider entry point ([FdoWmsConnection.cpp:85](../fdo/Providers/WMS/Src/Provider/FdoWmsConnection.cpp#L85), added in r8272), which is a process-wide side effect triggered by any host that loads the WMS provider.

The flag lives in one exported BSS symbol in `libFDO.so`
(`_ZN14FdoIDisposable28m_globalThreadLockingEnabledE`, verified with `nm -D` on
`build_area/x64/Release/ubuntu22/fdo/fdo/Fdo/Unmanaged/Src/libFDO-4.2.0.so`), and the inline
`EnableGlobalThreadLocking()` setter writes that same symbol from whichever DSO calls it. So the setting
does what it says.

**This means the original TODO on the lock ("Make FdoPtr's reference counter thread-safe") is obsolete
for the MapGuide server process.** That alone is not sufficient evidence to remove the lock — see the
other road blocks — but it does remove the historical justification.

Caveat worth stating: `FdoPtr` itself takes no lock; it calls through to the object's `AddRef`/`Release`.
Objects created by a host that has *not* called `EnableGlobalThreadLocking()` still refcount
non-atomically, and the provider-level `EnableGlobalThreadLocking(true)` in WMS means that simply
loading the WMS provider changes refcount behaviour for the whole process.

### 6.2 Expression engine: a process-wide lock (by design)

`fdo/Utilities/ExpressionEngine/Src/FdoExpressionEngineImp.cpp` has a **file-scope**
`FdoCommonThreadMutex mutex;` (line 94) and a file-scope **global function registry**
`ExpressionEngineInitializeClass initFunction;` (line 96), with ~10 guarded regions (lines 1482, 4112,
4168, 4515, 4602, …). `RegisterFunctions()` mutates the process-global user-defined function table
(only via the static `FdoExpressionEngine::RegisterFunctions`, which MapGuide does **not** use — MapGuide
passes its stylization functions per engine instance through
[ExpressionHelper.cpp:124](../mapguide/MgDev/Common/Stylization/ExpressionHelper.cpp#L124)).

Impact: expression-engine *population* and expression *type resolution* are serialised process-wide,
for every layer type (vector included). `PopulateFunctions()` runs once per engine instance
(`m_FunctionsPopulated`), so this is a per-stylize-call contended region rather than a per-feature one.
It is a **scalability limiter, not a correctness bug** — but it is worth knowing that "remove the raster
lock" will not produce linear scaling, because every stylized layer already queues here.

### 6.3 Parsing and geometry are already reentrant

- Every parse allocates its own parser object — `FdoFilter::Parse`/`FdoExpression::Parse` do
  `new FdoParse()`, parse, `delete`
  ([Parse.cpp:392-430](../fdo/Fdo/Unmanaged/Src/Fdo/Parse/Parse.cpp#L392)) — and the generated
  parsers take `FdoCommonParse*` / `FdoParse*` as a parameter rather than using globals
  (`fdo_filter_yyparse(FdoParse*)`, `pParse->fdo_filter_yyvsp[…]`).
- The FGF geometry factory singleton is **thread-local**
  ([GeometryFactory.cpp:35-58](../fdo/Fdo/Unmanaged/Src/Geometry/Fgf/GeometryFactory.cpp#L35) —
  `FdoGeometryThreadData::GetValue()`, created per thread).

Both are already exercised concurrently by vector stylization, which has never had a global lock. That
is the strongest available evidence that FDO Core itself is not the reason the raster lock exists.

## 7. Summary of road blocks

Ordered by how directly they block removing the lock.

| Ref | Where | Nature | Why it blocks |
|-----|-------|--------|---------------|
| **RB-1** | `FdoRfpConnectionCapabilities::GetThreadCapability` (GDAL) | Declares `SingleThreaded` | MapGuide clamps the GDAL pool to 1 connection and busy-waits, so disabling the `MappingUtil` lock yields no parallelism, and the provider contract still says "not thread safe" |
| **RB-2** | `FdoRfpStreamReaderGdalByTileResample::_getTile` | GDAL open/warp/close with no lock | The `ResamplingMethod` raster path is unprotected today; concurrent use corrupts GDAL state |
| **RB-4** | `FdoWmsUtils.cpp::_reverseCheck` | Unsynchronised lazy `static vector` | Reachable from every WMS 1.3.0 EPSG GetMap; concurrent first use corrupts the heap |
| **RB-5** | `FdoOwsHttpHandler` / `libOWS` | No `curl_global_init()` | libcurl requires a single-threaded global init before any other call |
| **RB-3** | `GRFP_EXPERIMENTAL_MULTI_THREADED_SUPPORT` | Never compiled; removes all locking at once | The provider has no incremental, tested path to concurrency |
| **RB-6** | `FdoWmsRasterGdal::_getDataset` | Global `/vsimem` entry never unlinked; `%d` on a pointer | Global mutable state that outlives the object, with a truncated, weak uniqueness key |
| **RB-7** | WMS `GDALRegister g_GDALRegister` | `GDALDestroyDriverManager()` in a static destructor | Shared-GDAL teardown owned by one provider |
| **RB-8** | `MgPortable` `MappingUtil` | Same lock, no config toggle | The toggle only exists in the server build |
| **RB-9** | `FdoExpressionEngineImp` global mutex | Process-wide serialisation of expression-engine population | Not a blocker for correctness; caps any scaling win |

## 8. Verdict

- **GDAL: not suitable for concurrent stylization today.** It is safe only because it is serialised —
  both by its own process-wide `g_GdalMutex` and, at the MapGuide layer, by a one-connection pool. It
  is not *multi-threaded capable*; it is *mutually exclusive*. There is one reachable unguarded path
  (RB-2) and no tested route to relaxing the serialisation (RB-3). Its `SingleThreaded` declaration is
  also what makes the MapGuide-side lock change pointless (RB-1).
- **WMS: deliberately concurrent, and therefore closer — but it has at least one real data race on the
  raster path (RB-4) plus two global-state hazards (RB-5, RB-6).** It has already opted into FDO's
  global thread-safe refcounting, and its per-request HTTP handling is sound. It looks like the
  provider the "global lock was collateral damage for" complaint is really about: the lock is
  penalising WMS for GDAL's deficiency.
- **FDO Core: not the blocker.** Thread-safe refcounting is implemented and enabled by MapGuide; the
  parsers are reentrant; geometry is TLS. The expression engine's global mutex is a scaling ceiling,
  not a correctness problem.

### The pragmatic conclusion

The most valuable next step is **not** "turn the lock off for everything". It is to make the lock
*per-provider* (or at least to narrow it), because:

1. WMS declares `PerConnectionThreaded` and already runs one connection per thread, so it does not need
   the process-wide lock — once RB-4/RB-5/RB-6 are fixed.
2. GDAL is serialised by its own declaration regardless of the lock, so removing the lock gains nothing
   for it until RB-1/RB-2/RB-3 are addressed.
3. Vector rendering — which uses the same FDO Core machinery — has been lock-free for years.

## 9. Suggested work, smallest-first

Ordered so that each step is independently verifiable and reversible.

1. **`docs`-only / no code:** decide whether "the raster lock" should become per-provider rather than
   per-grid-layer. That is a MapGuide-side design question with no provider dependency.
2. **Fix the WMS lazy static (RB-4).** Replace the `if (epsgList.empty())` population with a
   `std::once_flag` (or populate it from a file-scope initialiser with `std::call_once`). Small,
   self-contained, and independently testable — and it is a bug even for single-threaded use under
   unlucky timing.
3. **Fix `/vsimem` handling (RB-6).** Unlink in the destructor (`VSIUnlink(vfileName)`), keep the name
   in a member, and use a pointer-correct format (`%p`/`%llx`). Removes a growing global table and a
   stale-pointer hazard.
4. **Add `curl_global_init()` (RB-5)** in the provider/`libOWS` entry point, guarded by a
   `std::once_flag`, before any handler can be created.
5. **Fix the GDAL resample hole (RB-2).** Take `FdoGdalMutexHolder` in
   `FdoRfpStreamReaderGdalByTileResample::_getTile()` (and consider giving the unguarded
   `FdoRfpRasterUtil` helpers their own guard so callers cannot get it wrong).
6. **Only then** revisit `GetThreadCapability` (RB-1). This is a provider-contract change: the GDAL
   suite asserts `SingleThreaded` and would have to be updated, and the natural target is
   `PerConnectionThreaded` (each thread its own connection) rather than `MultiThreaded`, which would
   additionally require the per-connection dataset cache and the shared-schema path to be safe for
   concurrent intra-connection use.
7. **Retire or rewrite the `GRFP_EXPERIMENTAL_MULTI_THREADED_SUPPORT` switch (RB-3)** — either delete
   the dead branch, or replace it with a per-call-site decision backed by tests, so it stops looking
   like a supported option.
8. **Mirror the toggle in `MgPortable` (RB-8)**, or remove it from the server side too, so the two
   builds cannot diverge.

### Verification plan

No concurrency testing was performed for this assessment; the findings are static. Before any of the
above is called done, the following would give real evidence — all of it cheap relative to a full
build:

1. **Threaded provider harness.** Write a small CppUnit-free driver that opens N connections (or shares
   one, deliberately) and runs the same raster `RESAMPLE` select concurrently against
   `Providers/GDAL/Src/UnitTest` test data (`TestData/pci_eg/acea.tif` is already used by
   `RfpTestResample`), once with `ResamplingMethod` unset and once set. Run it against the Debug build,
   which is ASan/LSan-instrumented.
2. **ThreadSanitizer.** Build the provider and a driver with `-fsanitize=thread` in the `ubuntu22`
   Debug container. TSan is the tool that will name RB-4 and RB-6 directly. Note that TSan and ASan
   cannot be combined, so this is a second build tree, and that FDO's global refcount locking must
   still be enabled (or TSan will also flag every `FdoPtr` copy, which would be a distraction).
3. **Valgrind/Helgrind or DRD** as a fallback if a TSan build of the whole tree proves impractical —
   slower, but it needs no rebuild of dependencies.
4. **End-to-end.** With `GlobalRasterStylizationLockEnabled = 0`, drive the `test/*.http` suites plus a
   concurrent tile-cache-priming run (`RenderTileXYZ` from several clients) against a GDAL-backed grid
   layer *and* a WMS-backed grid layer, and watch for `MgAllProviderConnectionsUsedException`
   (the pool timeout in [§3](#3-mapguide-side-the-connection-pool-is-already-a-global-raster-lock))
   and for stale/mismatched tiles.
5. **Both GDALs.** Any GDAL-side conclusion must be checked twice: `ubuntu22` (system GDAL 3.4.1) and
   `generic` (vendored 2.4.4).

## Appendix: evidence index

MapGuide

- `mapguide/MgDev/Server/src/Services/Mapping/MappingUtil.cpp` — 244 (`ExecuteRasterQuery`), 358
  (`StylizeLayers`), 381-386 (config read), 619-622 (lock + comment), 652-660, 755-765, 771 (stylize
  call outside the lock)
- `mapguide/MgDev/Common/MapGuideCommon/System/ConfigProperties.cpp:325-326`
- `mapguide/MgDev/Server/src/Core/serverconfig.ini:364,381`; `mapguide/MgDev/cmake/configs/serverconfig.ini.in:366,383`
- `mapguide/MgDev/Server/src/Core/Server.cpp:930`; `mapguide/MgDev/Portable/MgPortable/System/PlatformInit.cpp:172`
- `mapguide/MgDev/Portable/MgPortable/Services/Rendering/MappingUtil.cpp:612,643,737`
- `mapguide/MgDev/Server/src/Common/Manager/FdoConnectionManager.h:87-93,135-146`; `FdoConnectionManager.cpp:241,1461-1470,1893-1979`
- `mapguide/MgDev/Server/src/Services/Feature/SelectCommand.cpp:227`; `ServerFeatureReader.h:574`; `ServerFeatureConnection.cpp:56-86`
- `mapguide/MgDev/Common/Stylization/DefaultStylizer.cpp:432-489`
- `mapguide/MgDev/Common/Stylization/ExpressionHelper.cpp:114-140`
- `mapguide/MgDev/Common/CoordinateSystem/CriticalSection.cpp:36-37,86-114` (CS-Map global lock)
- `mapguide/MgDev/Server/src/Services/Rendering/ServerRenderingService.cpp:1219,1822-1837,1864,1949`
- `mapguide/MgDev/Server/src/Services/Tile/MetatileLockUtil.cpp:21-44`

FDO — GDAL provider

- `fdo/Providers/GDAL/Src/Provider/FdoRfpConnectionCapabilities.cpp:29-32`
- `fdo/Providers/GDAL/Src/Provider/FdoRfpConnection.cpp:54-63` (`CreateConnection`), `256-277`
  (`_buildUpDefaultFeatureSchema`), `359-405` (`Open`), `371` (`ResamplingMethod`)
- `fdo/Providers/GDAL/Src/Provider/FdoRfpDatasetCache.h:62-68`; `FdoRfpDatasetCache.cpp:53-204`
- `fdo/Providers/GDAL/Src/Provider/FdoRfpStreamReaderByTile.cpp:330-497` (guarded read),
  `FdoRfpStreamReaderByTileResample.cpp:105-218` (**unguarded warp read**)
- `fdo/Providers/GDAL/Src/Provider/FdoRfpBandRaster.cpp:190-230,420-460,620-645`
- `fdo/Providers/GDAL/Src/Provider/FdoRfpImage.cpp:35-90`; `FdoRfpRasterPropertyDictionary.cpp:94-150`
- `fdo/Providers/GDAL/Src/Provider/FdoRfpGeoRasterExtractor.cpp:90-200`; `FdoRfpGeoBandRasterImp.cpp:172-200`
- `fdo/Providers/GDAL/Src/Provider/FdoRfpRasterUtil.cpp:167-235`
- `fdo/Providers/GDAL/Src/UnitTest/RfpTestThorough.cpp:372`; `RfpTestResample.cpp:31-35`

FDO — WMS provider and OWS

- `fdo/Providers/WMS/Src/Provider/FdoWmsConnectionCapabilities.cpp:37-40`
- `fdo/Providers/WMS/Src/Provider/FdoWmsConnection.cpp:56-87` (GDALRegister, `EnableGlobalThreadLocking`),
  `433`, `886-912` (GetMap parameter cache)
- `fdo/Providers/WMS/Src/Provider/FdoWmsUtils.cpp:113-152,239-256`
- `fdo/Providers/WMS/Src/Provider/FdoWmsSelectCommand.cpp:386-390`
- `fdo/Providers/WMS/Src/Provider/FdoWmsRasterGdal.cpp:26-96`
- `fdo/Providers/WMS/Src/Provider/FdoWmsBandRasterGdal.cpp:137-151`; `FdoWmsImage.cpp`/`.h`
- `fdo/Utilities/OWS/Src/FdoOwsDelegate.cpp:145-195`; `FdoOwsHttpHandler.cpp:89-99,181-183,374-400,579`
- `fdo/Utilities/OWS/CMakeLists.txt:44-52` (links `CURL_LIBRARIES`)

FDO Core / utilities

- `fdo/Fdo/Unmanaged/Inc/Common/IDisposable.h:66-113`; `fdo/Fdo/Unmanaged/Src/Common/IDisposable.cpp:34-90`
- `fdo/Fdo/Unmanaged/Inc/Common/Ptr.h`
- `fdo/Utilities/Common/Src/FdoCommonThreadMutex.cpp:24-58`; `Inc/FdoCommonThreadMutex.h`
- `fdo/Utilities/ExpressionEngine/Src/FdoExpressionEngineImp.cpp:94-96,1482-1510,4112,4168,4515,4602`
- `fdo/Utilities/ExpressionEngine/Src/ExpressionEngineInitializeClass.h:150-215`
- `fdo/Fdo/Unmanaged/Src/Fdo/Parse/Parse.cpp:388-430`; `Utilities/Common/Inc/Parse/Parse.h:64-118`
- `fdo/Fdo/Unmanaged/Src/Geometry/Fgf/GeometryFactory.cpp:35-58`
- `fdo/Utilities/OWS/Src/FdoOwsHttpHandler.cpp`

GDAL (vendored, for reference)

- `fdo/Thirdparty/gdal/VERSION` (`2.4.4`), `gcore/gdal_version.h.in`
- `gcore/gdaldataset.cpp:1085-1150` (`GDALReferenceDataset`/`GDALDereferenceDataset` are a plain
  non-atomic `++`/`--` on `GDALDataset::nRefCount`)
- `port/cpl_error.cpp:57,148-270` (error-handler stack: global mutex + TLS)
- `port/cpl_vsi_mem.cpp:160-165,485-500,874-930` (`/vsimem` table is globally mutex-guarded, and
  `VSIFileFromMemBuffer` *replaces* an existing entry)
