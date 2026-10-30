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
