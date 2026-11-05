# MapGuide server memory leaks (LeakSanitizer findings)

This note records the leaks reported by the `mgserver test all` suite on Linux x64, their root
causes and fixes. Paths below are relative to the MapGuide source root (`mapguide/MgDev` on the
host, `/tmp/work/src` inside the build container).

## How the report is produced

Debug builds are ASan/LSan-instrumented. The suite is run in one process so that exit-time teardown
runs once and every suite contributes to a single report:

```
# inside the interactive build container
mkdir -p /tmp/mglogs
/tmp/work/scripts/run_mapguide_tests.sh \
    --mapguide-build-dir /tmp/work/build_area/mapguide \
    --log-path /tmp/mglogs --component all
```

The run is judged by its Catch2 summary, never its exit code: an instrumented run exits non-zero
when it leaks, and a run that passed can still die in exit-time teardown (see
[fdo-exit-teardown.md](./fdo-exit-teardown.md)). `docs/INNER_LOOP_PAIN_POINTS.md` and
`README.md § 4.4` cover the incremental rebuild.

Two LSan behaviours matter when reading the report:

- `Direct leak` is a chunk nothing points to; `Indirect leak` is a chunk still pointed to by a leaked
  chunk. A report with no direct records at all is a reference cycle.
- Records are aggregated by allocation stack, so identical stacks collapse into one record ("N
  object(s)"), and a `#1` frame that is a *container* (`std::wstring::_M_assign`) names the string
  body but not the object that owned it.

Where the fast unwinder stops inside `libstdc++` or `libxerces`, re-run with the DWARF unwinder to
recover the owning frames - this is what attributed the 190-object Xerces record to
`MgXmlUtil::ToBytes()`:

```
ASAN_OPTIONS=fast_unwind_on_malloc=0 /tmp/work/scripts/run_mapguide_tests.sh ... --component all
```

CS-Map (`Oem/CsMap`) is compiled **without** `-fsanitize=address`, so its C globals are not LSan
roots: anything reachable only through `cs_CtDefHead`-style globals reads as leaked even though it is
still live.

## Baseline and result

| Run | Report |
|------|--------|
| `artifacts/Debug/test-logs/mapguide_all_unit_test.log` (before) | 647,644 bytes in 1,587 allocations; 27 direct + 216 indirect records |
| `all` suite (after) | no LeakSanitizer report at all |

610 test cases with 608 passing in both runs; the two failures are `TestLogManager.cpp:152` and
`:228` before and after, so they are not related to the leak work.

The **web tier** suites (`run_mapguide_tests.sh --tier web`) are instrumented the same way, and they
reported three more families, all now closed:

| Suite | Before | After |
|-------|--------|-------|
| `webtestrunner` (server) | 17,168 B in 12 allocations (1 direct + 5 indirect) | no report |
| `webtestrunner` (the runner process itself) | 2,560 B in 20 allocations (20 direct) | no report |
| `java` / `php` / `dotnet` (server) | 3,156 B in 38 allocations (30 records, all indirect) | no report |

## The fixes

| Record (before) | Root cause | Fix |
|-----------------|------------|-----|
| 265,536 B / 245 direct - `CSrdCategoryEx` ← `CS_ctdef` | `EnumerateCoordinateSystems` makes CS-Map read the whole `Category.CSD` into its process globals; nothing releases the cache, because the catalog is not destroyed at shutdown (it still has 22 references at teardown) and CS-Map's globals are invisible to LSan | `MgCoordinateSystemFactory::DeleteCatalog()` calls `CSrlsCategories()`, and `MgServer::fini()` calls `DeleteCatalog()` |
| 9,120 B / 190 direct - `XMemory::operator new` (no frames) | `MgXmlUtil::ToBytes()` freed the serializer and the format target but not the `DOMLSOutput` returned by `createLSOutput()` | release the output descriptor in `ToBytes()` |
| 4,800 B direct + ~15 KB indirect - `PolygonBuilder::buildMaximalEdgeRings` | a `TopologyException` escaping `PolygonBuilder::add()` left `maxEdgeRings`/`edgeRings`/`freeHoleList` behind; `SnapIfNeededOverlayOp` then retries, so the tests still pass. Ring constructors that throw also lost their point sequence | exception-safe cleanup in `PolygonBuilder::add`/`buildMaximalEdgeRings`/`buildMinimalEdgeRings`, and `EdgeRing::cleanupAfterFailedConstruction()` in the `MaximalEdgeRing`/`MinimalEdgeRing` constructors |
| 2,592 B / 27 direct - `IOGridColorBands::StartElement` | one `ChannelBand` per `<RedBand>`/`<GreenBand>`/`<BlueBand>`, copied by value in `EndElement` and never released | delete them in `~IOGridColorBands` |
| 1,800 B / 15 direct + 285 KB indirect (class definitions, properties, strings) | the test dropped the counted reference `MgFeatureSchema::GetClasses()` returns: `schema->GetClasses()->GetItem(0)` | hold the collection in a `Ptr` (`TestRasterStylization.cpp` `PublishFeatureSource`) |
| 1,280 B / 10 direct - `MgCoordinateXY` in `ComputeLineStringEnvelope` | same pattern with `MgEnvelope::GetLowerLeftCoordinate()`/`GetUpperRightCoordinate()` | hold both in `Ptr<MgCoordinate>` (`TestRasterStylization.cpp`) |
| 172 KB, indirect only - `MgLayerBase::SetLayerResourceContent` ← `MgMap::CreateFromTileSet` | two tests allocated a runtime map with a raw `MgMap*` and never released it, leaving a rootless map/layer cycle | `Ptr<MgMap>` in `TestTileService.cpp` |
| 4 x 320 B direct - `MgUserInformation` from the tile workers and session creation | `MgTileCacheDefault::GetMapFromDefinition` passed `GetCurrentUserInfo()` inline to `MgSiteConnection::Open()`, dropping the counted reference the thread-local user info owns | hold it in a `Ptr<MgUserInformation>` |
| 272 B direct - `MgResourceIdentifier` at `TestKmlService.cpp:298` | `MgServerKmlService::GetPointStyleImageUrl` used `layer->GetLayerDefinition()->ToString()` inline | hold the definition id in a `Ptr<MgResourceIdentifier>` and reuse it for the later lookup |
| 3 x 48 B direct - `FdoStringElement` in `MgToFdoStringCollection` | `MgFdoForcedOneToOneFeatureReader::GetIdentityHash` used a raw `FdoStringElement*` for `FdoStringCollection::GetItem()` | `FdoPtr<FdoStringElement>` |
| 4,216 B + 4,097 B + 16 B direct (`ACE_Log_Msg`, its buffer, `ACE_Thread_Exit`) - a thread spawned by `ACE_Thread_Adapter::invoke` | MapGuide spawned its log/worker/operation threads with `THR_DETACHED`, so the `ACE_Task::wait()` in `MgLogManager::StopLogThread`/`MgServerManager::StopWorkerThreads`/`MgServer::svc` returned in 0 us without waiting. `main()` then called `ACE::fini()` with the log thread still running, so ACE's TSS machinery was finalised before that thread exited and its per-thread ACE state was never released | spawn joinable threads in `MgThreadBase::Activate()` (`THR_NEW_LWP` without `THR_DETACHED`), which makes the existing waits actually wait |
| 17,168 B / 12 records (1 direct) - `TransformCache` + its `MgCSTrans`/CS-Map transform, from `MgOpGetWfsReader` | `TransformCache::GetLayerToMapTransform` deliberately does not cache the `reverse == false` (feature-to-map) direction, because a map-to-feature entry with the same WKT key would answer the wrong way round, so it returns a fresh entry the caller owns - and `MgWfsQueryAdapter::SetOptions` kept only `item->GetMgTransform()` and dropped the entry | hold the entry in a `unique_ptr` in `SetOptions` (the transform it carries is reference counted, so `m_xform` is unaffected), and document the ownership contract on `GetLayerToMapTransform` |
| 2,560 B / 20 direct - `MgCoordinateXY` from `MgHttpWmsGetFeatureInfo::GetSelectionGeometry` | `linearRingCoords->Add(new MgCoordinateXY(...))` - `MgCoordinateCollection::Add()` takes its own reference, so the one `new` returned was dropped, once per corner per GetFeatureInfo request | give each of the four corners a `Ptr<MgCoordinateXY>` and add the first one twice to close the ring |
| 3,156 B / 30 indirect records - the SDF schema graph behind `MgServerDescribeSchema::DescribeSchemaAsXml` | `SdfConnection::GetSchema(..., bNewCopyFromFile = true)` reads a whole schema from the file and then validates the requested schema name; on a mismatch it threw `SDFPROVIDER_58_INVALID_SCHEMANAME` and abandoned the copy, which still referenced its class collection, classes, properties and strings. An all-indirect report is the signature here: every chunk is reachable from another leaked chunk (the schema's raw parent links), not from a live one | hold the fresh copy in an `FdoPtr` while the name is validated and `Detach()` it on the way out, so the throwing path releases it; the borrowed `m_dbSchema->GetSchema()` result is still returned untouched. Covered by the SDF provider suite's `SchemaTest::TestDescribeSchemaInvalidName`, which drives the same invalid-name describe and checks the connection survives it - see [docs/fdo-provider-memory-leaks.md](./fdo-provider-memory-leaks.md) |

## The Java and PHP bindings each leaked one buffer per `byte[]` out-parameter

Not in this file's LSan reports, because neither is a MapGuide allocation: the chunk lives in the
client process's own runtime (the JVM heap for Java, the Zend memory manager for PHP), so the server
suites never see either. They are recorded here because they are the one leak an application hits by
doing nothing wrong, and they are big enough to OOM a real client. What an application should
otherwise do (and how to measure its own memory) is in
[docs/mapguide-bindings-memory-guide.md](./mapguide-bindings-memory-guide.md).

Both bindings marshall the same single API - `MgByteReader::Read(byte[]/&$buffer, length)`, the only
`BYTE_ARRAY_OUT` parameter in the API - and each leaked the caller's buffer once per call, so a
client that drained a resource in chunks leaked the whole payload per fetch: ~18 MB for an 18 MB
resource, however the reads were chunked.

### Java: `ReleaseByteArrayElements(..., JNI_COMMIT)`

The Java `byte[]` was marshalled like this:

```
%typemap(freearg) BYTE_ARRAY_OUT
{
    jenv->ReleaseByteArrayElements($input, bytes$argnum, JNI_COMMIT);
}
```

`JNI_COMMIT` copies the buffer back but deliberately does **not** free it (the JNI spec's mode 0 is
"copy back and free", `JNI_COMMIT` is "copy back", `JNI_ABORT` is "free without copying"). So every
`read(byte[], len)` leaked one buffer of `len` bytes.

Measured with the Debug tree (ubuntu22 x64): a `MgSiteConnection` client fetching an 18 MB resource
data stream 12 times grew its RSS by 206,260 KB (17,188 KB per iteration) while the Java heap stayed
at 23 MB. Massif attributed the whole of it in two iterations (37,756,928 B = 2 x 18,874,368 B plus
JVM overhead) to:

```
jni_GetByteArrayElements
  JNIEnv_::GetByteArrayElements (jni.h)
    Java_..._MgByteReader_1read (MgApi_wrap.cpp:1627)
```

which is the typemap's `in` half. After changing `JNI_COMMIT` to `0` in
`Bindings/src/Bindings/Java/java.i` (and the same typemap in
`Portable/PortableUnmanagedApi/JavaApiEx/java.i`, where the "MapGuideApiEx" Java binding that the
leak report came from is generated) the same 12-iteration run grows 2,804 KB, and 40 iterations with
1 MB reads grow 32 MB total with the heap oscillating between 17 and 44 MB - i.e. noise, not a leak.
The `java` web suite still reports `Tests failed/run: 0/618`.

### PHP: `ZVAL_STRINGL` over the previous by-ref value

A different mechanism, same symptom. The `argout` typemap copied the filled buffer into the caller's
by-reference variable and freed the temporary, but it never released the value that variable already
held:

```
%typemap(argout) BYTE_ARRAY_OUT buffer
{
    if (Z_ISREF($input))
    {
        ZVAL_STRINGL(Z_REFVAL($input), (char*)$1, result);
        efree($1);
    }
}
```

`ZVAL_STRINGL` only stores the new string into the zval; it does not dtor what was there. So each
`Read` leaked the *previous* chunk's string. Measured on the same Debug tree, on a reader over the same
18 MB resource: `memory_get_usage(false)` grew 27,649 KB per drained resource with 8 KB reads and
18.5 MB per drained resource with 1 MB reads - i.e. one buffer per call, rounded up to a Zend MM size
class (an 8,193-byte allocation lands in the 12,288 class, which is why the total is ~1.5 x the
payload). `memory_get_usage(true)` (the arena) tracked it exactly.

Isolating it is what makes the diagnosis, because the resource-service half is clean:

| Loop | Before the fix |
|------|----------------|
| `GetResourceData` + `unset($reader)` only | flat at 2,048 KB of arena, 393 KB used, four rounds |
| `new MgByteReader(file)` + `Read` in 8 KB chunks, four rounds | +27,649 KB of used memory per round |

The fix is a `zval_ptr_dtor(Z_REFVAL($input));` before the assignment in
`Bindings/src/Bindings/Php/php.i`. After it, both loops above are flat (arena stays at 2,048 KB over
four drained resources, and the proxied 12-iteration run grows 28 KB in total), and the `php` web
suite - which reads through `MgByteReader::Read` in `Validate.php` - still reports
`Tests failed/run: 0/593` with a clean server shutdown.

Note that PHP has no `Dispose()`: the only way to release a proxy is to let it be destroyed
(`unset()`, or reassigning the variable), which is what a `while ($reader->Read(...))` loop's owner
has to do. `MgByteReader::Dispose()` does not exist in this binding, so a port of the Java/.NET test
case fails with "Call to undefined method".

Recipes worth keeping:

- **The leak is proportional to the payload, not to the call count**, so it looks like "the reader is
  not being disposed" when it is nothing of the sort. A control Java run that never disposes the
  reader grows 865 KB per iteration; the typemap bug grew 17,188 KB for the same resource. Disposing
  the reader correctly is not enough to avoid either leak, and neither is reading in bigger chunks -
  the total leaked is the payload either way.
- **Measure it in a memory-limited container.** The repro is a Web Tier client that opens an
  `MgSiteConnection`, creates a session, `SetResourceData`s a large file and then loops
  `GetResourceData` → `Read` → dispose; a 6 GB `--memory` cap is enough to see linear growth without
  taking the host down.
- **Use `valgrind --tool=massif` on the client when LSan cannot help.** It needs no instrumentation of
  the JVM or of the MapGuide libraries, and the allocation stack comes out with source lines because
  the tree is a Debug build: `valgrind --tool=massif --detailed-freq=1 java -Xint ...`, then read the
  last snapshot's allocation tree. For PHP a plain `memory_get_usage(false)` before and after one
  drained resource is enough, and it is what separates "the client's runtime is leaking" (this) from
  "the fetch is leaking" (`GetResourceData` alone: flat).
- **The .NET binding does not have this defect and needs no fix.** Its `byte[]` parameter is
  marshalled by the P/Invoke runtime (a blittable array, pinned for the call), which allocates
  nothing per call. The same proxied flow over the same 18 MB resource grows 9.6 MB over 12
  iterations with 1 MB reads and is flat from the seventh iteration on, and a client that also
  reproduces the leak report's `RecyclableMemoryStream` + `ArrayPool<byte>` shape rises to ~202 MB by
  its tenth fetch of the resource and then moves 656 KB over the next fifty - that plateau is the
  pooled 18 MB stream plus a managed heap that the GC lets grow, not a leak.

## The ACE allocations that only appear in a single-suite run

`run_mapguide_tests.sh --component <one suite>` used to report a fixed trio in most suites while
`--component all` reported nothing:

```
Direct leak of 4216 byte(s) in 1 object(s) ... ACE_Log_Msg::instance()
Direct leak of   16 byte(s) in 1 object(s) ... ACE_Thread_Exit::instance()
Indirect leak of 4097 byte(s) in 1 object(s) ... ACE_Log_Msg::~ACE_Log_Msg()
```

They are one thread's `ACE_Log_Msg` (4,216 B plus its 4,097 B output buffer) and
`ACE_Thread_Exit` (16 B), allocated by `ACE_Thread_Adapter::invoke()` ->
`inherit_log_msg()`. Whether they show up or not was a shutdown race, not a property of the suite:
whichever ACE thread was still running when `main()` reached `ACE::fini()` lost its per-thread ACE
state. `ASAN_OPTIONS=fast_unwind_on_malloc=0` names the thread (for example `MgLogThread`), and
`/proc/self/task` confirms it is still alive at that point:

```
(x) MgServer::fini()
(x) MgLogThread - Exiting thread      <- logged after ACE::fini() has already run
```

Commenting out `ACE::fini()` made them disappear, which is what identified it: with the fix in
place the threads exit before it runs and there is nothing left to strand. A one-line check that
`ACE_Task::wait()` really blocks is worth remembering - for a `THR_DETACHED` thread it returns
immediately (measured: 0 us, vs 500 us for a joinable thread doing the same half-second of work).

### Recorded residue: 8 bytes from ACE's syslog backend (intermittent, not fixed)

A system log message (`MG_LOG_SYSTEM_ENTRY` -> `mltSystem`) makes `MgLogManager::LogToSysLog()` call
`ACE_Log_Msg::open(..., SYSLOG, ...)`, which allocates a small (8 byte) ACE syslog backend inside
`ACE_Log_Msg::open()`. ACE 7.0.6 frees that backend only from its private
`ACE_Log_Msg::close()`, so when the log thread exits the backend is left behind:

```
Direct leak of 8 byte(s) in 1 object(s) ... libACE-7.0.6.so+0xc6f89
    ACE_Log_Msg::open(char const*, unsigned long, char const*)
    MgLogManager::LogToSysLog(ACE_Log_Msg*, char*)
    MgLogThread::svc()
```

It is recorded rather than fixed because the release path is not reachable from MapGuide: `close()`
is private, `clr_flags(SYSLOG)` keeps the backend, and the allocation is 8 bytes once per thread that
logs a system message. It appeared in roughly one Geometry-suite run in three under the slow
unwinder and not at all in the six runs measured after the thread fix, so do not mistake a lone
8-byte record for a regression.

## The reactor path is not in the unit suite

`mgserver test <component>` runs an `MgTestCommand`, so `MgServer::svc()` returns at its
`if (m_command.get())` branch and never reaches the accept handlers, the client/admin/site operation
thread pools or `ACE_Reactor::run_reactor_event_loop()`. The thread-teardown fix above touches that
branch too (`MgOperationThread` is only started from it), and the waits in `MgServer::svc()` became
effective with it, so the reactor path needs its own check:

```
/tmp/work/scripts/run_mapguide_tests.sh --mapguide-build-dir /tmp/work/build_area/mapguide \
    --log-path /tmp/run-logs --run-mode
```

It starts the real server from the build tree, waits for the client port, sends `SIGTERM`, and fails
on a hang in the shutdown wait, a non-zero exit, a log that never reaches `Server stopped`, or a
LeakSanitizer summary. A clean run of the measured build looks like this:

```
  >> Server is accepting connections after 1s
  >> Server exited 1s after SIGTERM (exit 0)
Run-mode check passed
```

Every pool prints `MgOperationThread - Exiting thread` (and the worker and log threads theirs)
*before* `MgServer::~MgServer()`, which is the observable form of "the waits returned because the
threads exited", and the run reports no leaks. Two failure modes were injected to prove the check
works: a server that ignores `SIGTERM` is killed after `--shutdown-timeout` and reported as
`Server did not exit within Ns of SIGTERM`, and a server that exits non-zero is reported against both
the exit code and the missing `Server stopped` marker.

## Technique notes

- **`Ptr<T>` attaches.** `Ptr(T*)` and `Ptr::operator=(T*)` take ownership of an *existing*
  reference (they do not AddRef), so a counted getter's result is correctly held by
  `Ptr<T> p = getter();`. The leak appears when the same result is dereferenced inline
  (`getter()->Foo()`): the reference is never released. The same holds for `FdoPtr<T>` and for
  `FdoCollection::GetItem`/`FindItem`.
- **`GetCurrentUserInfo()`, `GetLayerDefinition()`, `GetClasses()` and
  `MgEnvelope::Get*Coordinate()` all return counted references**, and so does any `Get*`/`Find*`
  that returns a `MgDisposable`-derived pointer from a collection or a cache.
- **A test that allocates with `new` and stores into a raw pointer always leaks.** Test helpers that
  return `MgMap*`/`MgReader*` are fine only where every caller wraps the result in a `Ptr`, which is
  worth re-checking whenever a suite gains a case.
- **Count constructions against disposals before guessing at ownership.** A `fprintf` in the
  constructor and in `Dispose()` answers two questions at once: how many objects are still alive
  (`ctor` count minus `Dispose` count), and — printed from `Dispose()` — whether the member you
  suspect is over-retained (`m_collection->GetRefCount()` of 2 there is a lost release somewhere
  else). The MgFeatureSchema family was found this way: 17 of 80 disposals saw a class collection at
  refcount 2, and the extra reference was the test's inline `GetClasses()`.
