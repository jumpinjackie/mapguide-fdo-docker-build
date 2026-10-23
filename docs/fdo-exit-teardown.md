# FDO exit-time teardown: the provider module map must never be destroyed

This note records an intermittent hang/segfault at process exit in `mgserver`, the
static-destruction-order bug in `libFDO` behind it, the fix, and the measurements that
proved the cause. It also explains why this is **not** the same thing as ticket #965,
which is the other exit-teardown note in this repository.

Paths below are relative to the source roots (`fdo/` and `mapguide/MgDev` on the host,
`/tmp/work/src` inside the build container).

## Symptom

A unit-test run **passes**, prints the shutdown banner, and only then dies or wedges:

```
===============================================================================
All tests passed (150 assertions in 2 test cases)

Finished running the unit tests.

(18) Server stopped.
<process then hangs, or dies with SIGSEGV>
```

Measured on the `[RasterStylization]` suite in Release builds: **14 failures in 100 runs
(14%)**, split between hangs (`timeout` hitting) and `SIGSEGV` — 80 runs on an unmodified
r10225 working copy and 20 with the band-IO hardening patch applied, i.e. the defect is in
neither of those change sets. It is not specific to that suite either: `[FeatureService]`
was seen doing the same after passing 316 assertions.

Two properties make it easy to misdiagnose:

- It is **not** a `futex` wait. The stuck process is single-threaded and spinning in
  `std::_Rb_tree_increment`, so the "hung suite" recipe in the repo guidance (look for
  `futex_do_wait`) will not find it. Sample it with `gdb -p <pid>` instead.
- The pass/fail line is already printed, so any harness that keys off the process exit
  code reports a test failure that did not happen.

## Root cause

`gdb -p` on a wedged run gave a single thread with this stack:

```
#0  std::_Rb_tree_increment(std::_Rb_tree_node_base*)
#1  FdoConnectionManager::~FdoConnectionManager()
#2  FdoConnectionManager::Dispose()
#3  FdoIDisposable::Release()
#4  FdoFeatureAccessManager::Reset()
#5  InitClass::~InitClass()
#6  __cxa_finalize
#7  _dl_fini
```

`libFDO` registers a static `InitClass` instance in `Fdo/Unmanaged/Src/Fdo/Fdo.cpp` whose
destructor calls `FdoFeatureAccessManager::Reset()`. That releases the connection
manager, which runs `~FdoConnectionManager`, which walks and `dlclose`s the providers in

```c++
// Fdo/Unmanaged/Src/Fdo/ClientServices/ConnectionManager.cpp
static FdoModuleMap m_moduleMap;     // namespace-scope static, separate TU
```

`m_moduleMap`'s own destructor can therefore already have run by the time
`~FdoConnectionManager` iterates it. Walking a destroyed red-black tree is undefined
behaviour: heap reuse decides whether it spins forever (hang) or faults (segfault), which
is exactly the observed intermittency. As corroboration, running the suite under an
`LD_PRELOAD` backtrace shim changed the *mix* of hangs and crashes without removing either
— the signature of reading reused memory, not of a deterministic bug.

MapGuide cannot work around this. `MgFdoConnectionManager::Terminate()` only clears
MapGuide's own `sm_fdoConnectionManager` pointer; it never touches FDO's registry, so the
bad teardown still happens inside `libFDO` regardless of what the server does.

Releasing pooled connections earlier does not help much, and the measurements above were
taken *with* that mitigation already in place: the `[RasterStylization]` fixtures call
`MgFdoConnectionManager::ClearCache()` after every one, and the failure rate is still 14%.
It changes how many connections are open at teardown, not whether a destroyed container
gets walked, so do not read "the suite is green now" as evidence that this is resolved.

## Fix

Make the module map immortal, so destruction order cannot matter:

```c++
// The provider module map is deliberately never destroyed. ... iterating a freed
// red-black tree is what makes the process hang or crash intermittently at exit.
static FdoModuleMap& GetModuleMap()
{
    static FdoModuleMap* s_moduleMap = new FdoModuleMap();
    return *s_moduleMap;
}
```

Every `m_moduleMap` use goes through `GetModuleMap()`. The `dlclose`/`FreeLibrary` loop in
`~FdoConnectionManager` is unchanged — only the container's lifetime is. Leaking it is
harmless: the process is exiting, and the values are DSO handles the loader tears down
itself.

This is in the **FDO working copy**, not MapGuide, so it is a pending change there to be
committed with `svn commit` (one file) — never committed by an agent — and kept as
`patches/fdo_connection_manager_static_teardown.patch` for the sibling
`mapguide-fdo-build-windows` repo. It is platform-neutral: the same
ordering hazard exists on Windows, where `InitClass` is compiled out but `DllMain`'s
process-detach path runs the same `~FdoConnectionManager`.

## Verification

Same binaries throughout; only `libFDO-4.2.0.so` was swapped in `/usr/local/fdo-4.2.0/lib64`.
Each run is one `mgserver test RasterStylization`, classified by exit code
(`timeout` → hang, 139 → crash), and the assertion line was checked on every run.

| Tree | libFDO | Runs | Failures |
|------|--------|------|----------|
| pristine r10225 | original | 80 | 11 (13.8%) |
| pristine r10225 | fixed | 80 | **0** |
| hardening patch applied | original | 20 | 3 (15%) |
| hardening patch applied | fixed | 20 | **0** |

At the measured 14% rate, 80 consecutive clean runs have probability below 10⁻⁵, so the
causality is established rather than inferred from a lucky sample. An earlier 20-run
sample of the fixed library came back clean and was **not** treated as evidence for this
reason; the sample sizes above are what the conclusion rests on.

### Debug does not reproduce it

Debug was measured separately, with a Debug-built `libFDO` — a Debug library and its
hosting executable have to be the same runtime, per the repo guidance:

| Tree | libFDO | Options | Runs | Failures |
|------|--------|---------|------|----------|
| hardening patch applied | original (Debug) | `detect_leaks=0` | 100 | 0 |
| hardening patch applied | original (Debug) | `+quarantine_size_mb=0` | 40 | 0 |
| hardening patch applied | fixed (Debug) | `detect_leaks=0` | 100 | 0 |

So the Debug pair demonstrates **no regression**, not an improvement: at 100 clean baseline
runs the Debug failure rate is bounded at roughly 3% (95% confidence), and is most likely
zero. The reason is not established, but the plausible one is allocation: the Debug host
links the ASan runtime (`mgserver` carries 32 `__asan_*` imports) and therefore allocates
and frees through ASan's allocator, which poisons freed memory without overwriting its user
bytes, whereas Release's glibc `free()` writes free-list pointers into the chunk it is
releasing. The tree therefore stays readable in Debug, and since the Debug `libFDO` is not
itself ASan-instrumented (`nm -D | grep asan` finds nothing), ASan cannot report the read
either. Disabling the quarantine did not change the outcome, which is consistent with that
explanation but does not prove it.

One check that *is* meaningful in Debug: LeakSanitizer's report is byte-identical with
either library — 11,945 bytes in 38 allocations, 7 direct and 1 indirect record. That is
expected, because LSan runs before `_dl_fini`, so the map's lifetime never reaches it, and
it confirms the deliberate leak is invisible to the leak gate.

## Do not read this as "exit-time destructor bugs are harmless"

The `#965` note in `AGENTS.md` says the deferred static destructors are harmless and should
not be "fixed". That conclusion is correct **for the vague-linkage data it is about**
(`STB_GNU_UNIQUE` symbols pinning DSOs so `dlclose` unloads nothing), and the reasoning
there — bounded process-lifetime state, never reloaded, LSan unaffected — does not
generalise.

The bug above is the counter-example: an exit-time destructor walking a sibling static
that is already destroyed. It is real, it is worth fixing, and it was cheap to fix. The
test is whether the teardown **reads or writes state owned by another static**, not
whether it runs at exit.

## Operational consequence: rebuild the FDO SDK

The fix lives in `libFDO`, which ships inside the FDO SDK tarball that MapGuide consumes
(`artifacts/<conf>/fdosdk-<ver>.<rev>-<distro>-<arch>.tar.gz`). Swapping the `.so` by hand
is enough to validate the fix, but **the tarball still contains the old library** until
FDO is rebuilt:

```
./build_thin.sh --target fdo --distro ubuntu --tag 22 --cpu x64
```

Until that is done, test runs against the packaged SDK will keep showing the flake.

## Diagnosing the next one

1. Reproduce with a bounded loop and a timeout, and classify by exit code rather than
   reading a single run: `timeout 45 ./mgserver test <Suite>`, `124` is a hang, `139`/`134`
   a crash. Print the assertion summary for every run so a passing-but-dying run stands out.
2. On a hang, `gdb -p <pid> -batch -ex "thread apply all bt"` — do not assume `futex`.
   A single thread inside `libstdc++` tree/list routines is a use-after-free or a corrupt
   container, not lock contention.
3. If the stack is in `_dl_fini`/`__cxa_finalize`/`~InitClass`, it is static-destruction
   order between translation units inside one library. The fix belongs in that library.
