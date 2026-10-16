# Handoff: MapGuide Web tier — four exception guards that construct instead of throw

**Status:** Investigation complete; root cause and blast radius confirmed. **Fix deliberately not
implemented** — deferred at the user's request so it can be actioned separately from the document
that found it.
**Date:** 2026-10-16
**Source tree:** `mapguide/MgDev` @ SVN `branches/4.0/MgDev`, revision 10218 (clean working copy)
**API/ABI mode:** `freeze` — not engaged. Every file below is under `Web/src/**`, none of which is a
shipped SDK header, so there is no provider-facing surface to check.

---

## Why this document exists

Found while writing [mapguide-load-balancing-assessment.md](./mapguide-load-balancing-assessment.md).
That document needed to answer "does MapGuide have a way to make a repository read-only?" — it does
not, and the switch that looks like it does, `[AgentProperties] DisableAuthoring`, is inert for the
reason described in defect A below. Chasing that one case turned up three more of the same shape.

The findings are recorded in the load-balancing document as behaviour
([§6.6](./mapguide-load-balancing-assessment.md) and drift 4 in §7), because they are *observed
capabilities* and belong there. The **clear-up work** is here, because it is a source change rather
than an assessment.

---

## TL;DR

Four places in the Web tier test a condition and then construct an `MgException` **without throwing
it**, which is equivalent to deleting the check. Two of them fall through to a null dereference, so
the failure mode is a crash rather than a diagnostic.

| # | Location | Guard that does nothing | Consequence |
|---|----------|------------------------|-------------|
| A | [`HttpRequestResponseHandler.cpp:72`](../mapguide/MgDev/Web/src/HttpHandler/HttpRequestResponseHandler.cpp#L72) | `[AgentProperties] DisableAuthoring` / `DisableWms` / `DisableWfs` | Three documented config switches have no effect, and setting one leaks an `MgException` per classified request |
| B | [`HttpRequest.cpp:328`](../mapguide/MgDev/Web/src/HttpHandler/HttpRequest.cpp#L328) | unknown MapAgent operation name | Falls through to a **call through a NULL function pointer** on line 331 instead of `MgInvalidOperationException` |
| C | [`InitializeWebTier.cpp:90`](../mapguide/MgDev/Web/src/WebSupport/InitializeWebTier.cpp#L90) | CS-Map coordinate system catalog missing | The check is discarded, then line 97 dereferences the NULL catalog |
| D | [`InitializeWebTier.cpp:110`](../mapguide/MgDev/Web/src/WebSupport/InitializeWebTier.cpp#L110) | CS-Map library status not initialised | Broken CS-Map dictionaries are silently ignored through web tier startup |

---

## The pattern

Each site is inside a `MG_TRY()` / `MG_CATCH…THROW` block, in a file where every neighbouring guard
throws correctly. The exception object is allocated and immediately unreachable: no `throw`, no
`Ptr<>`, no assignment. In a `_DEBUG` build this is also a plain memory leak, and each one is on a
path that already has a correct `throw new MgException(…)` a few lines away to copy from.

---

## Defect A — the read-only switches are inert

[`Web/src/HttpHandler/HttpRequestResponseHandler.cpp:65-74`](../mapguide/MgDev/Web/src/HttpHandler/HttpRequestResponseHandler.cpp#L65)

```c++
    if (disableProperty.length() > 0)
    {
        bool bDisable = false;
        MgConfiguration* config = MgConfiguration::GetInstance();
        config->GetBoolValue(MgConfigProperties::AgentPropertiesSection, disableProperty, bDisable, false);
        if (bDisable)
        {
            new MgException(MgExceptionCodes::MgInvalidOperationException, L"HttpRequestResponseHandler.InitializeCommonParamters", __LINE__, __WFILE__, NULL, L"", NULL);
        }
    }
```

`disableProperty` is selected by request classification at lines 42-63 — `mrcAuthor` →
`AgentDisableAuthoring`, `mrcWms` → `AgentDisableWms`, `mrcWfs` → `AgentDisableWfs`. `bDisable` is
never read again after line 70, and `AgentDisableAuthoring` has this one reader in the whole tree.

The three keys are documented as working, in the shipped `webconfig.ini`
([`Web/src/webconfig.ini:145-149`](../mapguide/MgDev/Web/src/webconfig.ini#L145), values at
[:175-177](../mapguide/MgDev/Web/src/webconfig.ini#L175)):

```
# DisableAuthoring                 Disables Authoring HTTP requests
#                                       0 = false and 1 = true
# DisableWfs                       Disables OGC Wfs HTTP requests
# DisableWms                       Disables OGC Wms HTTP requests
```

**Impact.** An operator who sets `DisableAuthoring = 1`, believing they have made the Web Tier
read-only for served content, has not. They also get a leaked `MgException` per classified request,
because the allocation happens on every request while the flag is set — so the leak is a fingerprint
that the feature was attempted.

**Fix.** `throw new MgException(…)`, matching line 201 of the same function. The enclosing
`MG_HTTP_HANDLER_TRY()` / `…CATCH_AND_THROW` already handles it.

**Note.** Fixing this changes behaviour for anyone who has `DisableAuthoring`/`DisableWms`/`DisableWfs`
set today and has been silently not-disabled: after the fix those operations start returning
`MgInvalidOperationException`. That is the documented contract, but it is a visible behaviour change
and belongs in the commit message and the release notes.

---

## Defect B — unknown operation name crashes instead of throwing

[`Web/src/HttpHandler/HttpRequest.cpp:325-331`](../mapguide/MgDev/Web/src/HttpHandler/HttpRequest.cpp#L325)

```c++
    //find in the map the creator for the http mapping class
    MgHttpRequestResponseHandler* (*createFunc)(MgHttpRequest*) = httpClassCreators[OperationName];
    if(createFunc == NULL)
        new MgException(MgExceptionCodes::MgInvalidOperationException, L"MgHttpRequest::CreateRequestResponseHandler", __LINE__, __WFILE__, NULL, L"", NULL);

    //instantiate the http class
    returnHandler = (*createFunc)(this);
```

**Impact.** Two things, the first worse than the second:

1. **Null call.** `createFunc` is still `NULL` at line 331, so an unrecognised `OPERATION` is a call
   through a null function pointer — a `SEGV` in the Web tier rather than a clean
   `MgInvalidOperationException`. This is reachable by any client that guesses or fuzzes an operation
   name.
2. **Unbounded map growth.** `httpClassCreators` is a `std::map` ([`HttpRequest.cpp:143`](../mapguide/MgDev/Web/src/HttpHandler/HttpRequest.cpp#L143)),
   and line 326 looks up with `operator[]`, which **inserts** a null entry for a missing key. Every
   distinct unknown operation name therefore permanently grows the map — a slow memory-growth vector
   that a hostile client controls.

**Fix.** `throw new MgException(…)` on line 328. That also removes the growth vector, because the
throw happens before any code could rely on the inserted entry — but the `operator[]` is still worth
swapping for `find`/`at` so the lookup cannot mutate the map at all. Either is a one-line change;
doing both is the clean version.

---

## Defects C and D — web tier initialisation

[`Web/src/WebSupport/InitializeWebTier.cpp:87-112`](../mapguide/MgDev/Web/src/WebSupport/InitializeWebTier.cpp#L87)

```c++
    //Check catalog
    if (NULL == csCatalog.p)
    {
        new MgException(MgExceptionCodes::MgCoordinateSystemInitializationFailedException,
            L"MgInitializeWebTierInternal", __LINE__, __WFILE__, NULL, L"", NULL);
    }
    ...
        csCatalog->SetDictionaryDir(mentorDictPath);       // line 97
    ...
    //Check lib status
    LibraryStatus status = csCatalog->GetLibraryStatus();  // line 107
    if(lsInitialized != status)
    {
        new MgException(MgExceptionCodes::MgCoordinateSystemInitializationFailedException,
            L"MgInitializeWebTierInternal", __LINE__, __WFILE__, NULL, L"", NULL);
    }
```

**Impact.**

- **C** guards `csCatalog.p == NULL`, discards it, and then dereferences `csCatalog` at line 97 (when
  a dictionary path is configured) and at line 107 (always). A CS-Map catalog that failed to load
  therefore produces a null dereference in `MgInitializeWebTier`, not the
  `MgCoordinateSystemInitializationFailedException` the code names.
- **D** guards a `LibraryStatus` that is not `lsInitialized` — i.e. missing or unusable CS-Map
  coordinate system dictionaries — and discards it, so the Web tier reports itself initialised and
  goes on to fail later, further from the cause. `MgCoordinateSystemCatalog::GetLibraryStatus` is
  exactly the fail-fast signal the callers of `MgInitializeWebTier` need.

**Fix.** `throw new MgException(…)` in both places; the function is wrapped by
`MG_CATCH_AND_THROW(L"MgInitializeWebTierInternal")`, so nothing else is needed.

**Note.** C and D are the most valuable of the four to fix despite being the least reachable: the
whole point of `MgInitializeWebTier` is to tell an integrator their dictionaries are not where the
config says they are, and today it either crashes or lies.

---

## Suggested fix outline (when resumed)

1. Four one-line changes — give each `new MgException(…)` its missing `throw`. Copy the shape from
   [`HttpRequestResponseHandler.cpp:201`](../mapguide/MgDev/Web/src/HttpHandler/HttpRequestResponseHandler.cpp#L201),
   which is correct in the same function.
2. In defect B, additionally replace the `httpClassCreators[OperationName]` lookup with a
   non-mutating lookup.
3. Do **not** widen scope: the same sweep over `Server/`, `Common/` and the rest of `Web/` found only
   legitimate matches — assignments to a local `mgException`/`exception` used by the `MG_CATCH`
   convention ([LogThread.cpp](../mapguide/MgDev/Server/src/Common/Manager/LogThread.cpp),
   [WorkerThread.cpp](../mapguide/MgDev/Server/src/Common/Manager/WorkerThread.cpp),
   [FdoConnectionManager.cpp](../mapguide/MgDev/Server/src/Common/Manager/FdoConnectionManager.cpp),
   [MappingUtil.cpp](../mapguide/MgDev/Server/src/Services/Mapping/MappingUtil.cpp) and others) and
   genuine `Ptr<MgException>` locals
   ([HttpWmsGetMap.cpp](../mapguide/MgDev/Web/src/HttpHandler/HttpWmsGetMap.cpp),
   [TestMisc.cpp](../mapguide/MgDev/Server/src/UnitTesting/TestMisc.cpp)). Those are not defects.
4. The command that found them, for re-running after a tree update. It looks for a `new MgException(…)`
   in statement position, which is the signature of every one of these:

   ```console
   $ grep -rnE --include=*.cpp "^[[:space:]]*new MgException\(" Server/ Web/ Common/
   Web/src/HttpHandler/HttpRequestResponseHandler.cpp:72:            new MgException(...);
   Web/src/HttpHandler/HttpRequest.cpp:328:        new MgException(...);
   Web/src/WebSupport/InitializeWebTier.cpp:90:        new MgException(...
   Web/src/WebSupport/InitializeWebTier.cpp:110:        new MgException(...
   ```

   Exactly four, all of them listed above (arguments elided). Adding `--include=*.h` keeps the count
   at four.

   Statement position is not assumed to be the only shape a broken guard could take — a guard written
   as `if (x) new MgException(...)` on one line would be missed by it. So the claim was closed the
   other way round as well, by subtracting every known-good shape and requiring nothing to be left:

   ```console
   $ grep -rnE --include=*.cpp --include=*.h "new MgException\(" Server/ Web/ Common/ \
       | grep -vE "throw new MgException\(" \
       | grep -vE "= new MgException\(" \
       | grep -vE "return new MgException\(" \
       | grep -vE "^[^:]+:[0-9]+:[[:space:]]*new MgException\("
   (no output)
   ```

   No output means every `new MgException(` in those three trees is one of: a `throw`, an assignment
   to a `mgException`/`exception` local used by the `MG_CATCH` convention, a `Ptr<MgException>` local,
   a `return new MgException(…)` factory
   ([Exception.cpp:697+](../mapguide/MgDev/Common/Foundation/Exception/Exception.cpp#L697)), or one of
   the four defects above. There are no others. Note that a hand-rolled `grep -v` filter over the
   `MgException*` type name is not a substitute for the shapes above: these lines carry a
   `file:line:` prefix, so an anchored `:\s*MgException` pattern never matches them and filters
   nothing.

---

## Verification plan

Defect A is the only one with a clean end-to-end test that needs no special environment, and it is
also the one the load-balancing document relies on:

1. **A — the switch stays inert until fixed.** Install the built package
   (`./mapguide_image_install.sh --target ubuntu22 --target-distro ubuntu22 --tag 22`), set
   `[AgentProperties] DisableAuthoring = 1` in `webconfig.ini`, restart the Web Tier, and POST an
   authoring operation (e.g. `SETRESOURCECONTENT` from
   [`test/resource_service_api.http`](../test/resource_service_api.http)). Today it **succeeds**.
   After the fix it must return `MgInvalidOperationException`. Leaving the flag at its default `0`
   must be unaffected either way.
2. **A — the leak, before and after.** With the flag set, the per-request `MgException` shows up as an
   `MgException`-sized leak in a Debug (ASan/LSan) build. That is the cheapest confirmation that the
   code path really is reached; see
   [AGENTS.md § Debugging memory leaks](../AGENTS.md#debugging-memory-leaks-asanlsan).
   The Web tier is not one of the suites `run_mapguide_tests.sh` covers, so this needs an ad-hoc
   `LSAN_OPTIONS` run rather than a suite.
3. **B.** Request an `OPERATION` that does not exist (`npx httpyac` with a hand-written request, or
   `curl` against `/mapagent/mapagent.fcgi?OPERATION=NOTANOPERATION`) and confirm the process does
   not die; expect `MgInvalidOperationException`. Repeating it many times with distinct names should
   not grow memory.
4. **C and D.** Point `MentorDictionaryPath` at an empty directory (or rename it) and call
   `MgInitializeWebTier` from a small C++ or PHP harness; expect
   `MgCoordinateSystemInitializationFailedException` rather than a crash. The existing web tier
   samples under `Web/src/WebApp` and the `MgTestAdmin`-style tools are the natural harnesses.

---

## Validation required before committing a fix (repo definition of done)

These are Web-tier source changes in the `MgDev` tree, so the repo's source-tree rule applies:

- `./build_thin.sh --target mapguide --distro ubuntu --tag 22 --cpu x64` against the baseline distro
  (Ubuntu 22.04) — MapGuide's own build; `mapguide_image_install.sh` for the install/smoke path.
- The MapGuide unit suites via [templates/scripts/container/run_mapguide_tests.sh](../templates/scripts/container/run_mapguide_tests.sh)
  in the running baseline container (`$DOCKER_CMD exec`, per
  [AGENTS.md § Running commands inside build containers](../AGENTS.md#running-commands-inside-build-containers)),
  or `./env_test_thin.sh --target mapguide --distro ubuntu22 --cpu x64`.
- The `test/` `httpyac` suites, which is where defect A's behaviour is observable:
  `cd test && npx httpyac *_api.http --all --bail --output headers`.
- Debug **and** Release: the changed code is plain control flow, but this file is compiled into the
  Web tier library that the Debug (ASan) and Release builds use differently, and the `throw`-vs-`new`
  difference is exactly the kind of thing a `_DEBUG`-only leak report would otherwise hide.
- **Never `svn commit`.** The edit stays in the working copy; the user commits, and the commit
  message covers only `mapguide/MgDev/**` paths (see
  [AGENTS.md § Commit messages](../AGENTS.md#commit-messages-one-scope-per-repository)).

---

## Key references

| Item | Location |
|------|----------|
| A — `DisableAuthoring`/`Wms`/`Wfs` guard | `mapguide/MgDev/Web/src/HttpHandler/HttpRequestResponseHandler.cpp:65-74` (the discarded allocation is line 72) |
| A — correct sibling `throw` to copy | same file, line 201 |
| A — classification → property mapping | same file, lines 42-63 |
| A — documented-but-untrue keys | `mapguide/MgDev/Web/src/webconfig.ini:145-149` (documentation), `:175-177` (values) |
| B — unknown-operation guard | `mapguide/MgDev/Web/src/HttpHandler/HttpRequest.cpp:327-328` (null call at 331) |
| B — the map and its mutating lookup | same file, lines 143 (`static map<STRING, …>`) and 326 (`operator[]`) |
| C, D — web tier init guards | `mapguide/MgDev/Web/src/WebSupport/InitializeWebTier.cpp:88-92`, `:107-112` |
| C — the dereference the guard should have prevented | same file, line 97 and line 107 |
| Not defects (same grep, legitimate uses) | `Server/src/Common/Manager/{LogThread,WorkerThread,FdoConnectionManager}.cpp`, `Server/src/Services/Mapping/MappingUtil.cpp`, `Web/src/HttpHandler/HttpWmsGetMap.cpp`, `Server/src/UnitTesting/TestMisc.cpp` |
| Where the behaviour is documented | `docs/mapguide-load-balancing-assessment.md` §6.6, §7 drift 4, §9.2 |
| Read-only enforcement question that started this | `docs/mapguide-load-balancing-assessment.md` §6.6 |

---

## Notes / clean-up

- **No source files were modified.** No commit was made, in either the git repository or the SVN
  working copy; `svn status` on `mapguide/MgDev` is clean.
- No temporary files were left behind.
- The `DisableAuthoring` finding is the reason the load-balancing document, which sets out to answer
  "can MapGuide be horizontally scaled", ends up concluding that repository immutability in a
  multi-site deployment is a **deployment discipline** rather than something the software can
  enforce. Until this handoff is actioned, that conclusion stands: plan on denying write roles
  rather than on `DisableAuthoring`.
