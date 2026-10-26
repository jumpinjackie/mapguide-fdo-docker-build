# Troubleshooting `DB_LOG_BUFFER_FULL: In-memory log buffer is full`

A server-side resource write exceeded the Berkeley DB transaction log buffer that MapGuide gives the
**session** repository. It is not a database corruption, not a disk problem, and not usually a bug in the
provider you happen to be querying: it means **one transaction tried to write a blob bigger than the
buffer**, and the usual blob is a persisted selection or a large resource data upload.

## The message

```
An exception occurred in DB component. Db::put: DB_LOG_BUFFER_FULL: In-memory log buffer is full
An exception occurred in DB component. Db::put: DB_LOG_BUFFER_FULL: In-memory log buffer is full - MgResourceServiceHandler.ProcessOperation() line 80 file .../ResourceServiceHandler.cpp - MgOpSetResourceData.Execute() line 107 file .../OpSetResourceData.cpp - MgServerResourceService.SetResourceData() line 1783 file .../ServerResourceService.cpp - MgApplicationRepositoryManager.SetResourceData() line 974 file .../ApplicationRepositoryManager.cpp - MgResourceDataStreamManager.SetResourceData() line 101 file .../ResourceDataStreamManager.cpp
```

It is three separate pieces of text glued together:

| Part | Where it comes from |
| --- | --- |
| `An exception occurred in DB component.` | the generic text of `MgDbException` ([mapguide_en.res:38](../mapguide/MgDev/Common/MapGuideCommon/Resources/mapguide_en.res:38)) — carries no information |
| `Db::put: DB_LOG_BUFFER_FULL: In-memory log buffer is full` | Berkeley DB itself (`DB_LOG_BUFFER_FULL` is `-30992`, [db.h:1235](../mapguide/MgDev/Oem/dbxml/db-4.8.26/build_windows/db.h:1235); message text in [db_err.c:283](../mapguide/MgDev/Oem/dbxml/db-4.8.26/common/db_err.c:283)) |
| everything after the dash | the propagation stack, **outermost frame first** |

So the first thing to do is read the **last** frame in that stack: it names the write that failed.

## Why it happens

MapGuide's resource repository is Berkeley DB XML over Berkeley DB. The session repository is opened in a
mode the other repositories are not:

- `DB_PRIVATE` and `DB_LOG_IN_MEMORY` — the transaction log lives **only in RAM**, there is no on-disk
  log to spill to ([DbEnvironment.cpp:181](../mapguide/MgDev/Server/src/Services/Resource/DbEnvironment.cpp:181));
- `set_lg_bsize(SessionLogBufferSize * 1 MB)` — default **1 MB**
  ([DbEnvironment.cpp:144](../mapguide/MgDev/Server/src/Services/Resource/DbEnvironment.cpp:144),
  [`SessionLogBufferSize`](../mapguide/MgDev/Server/src/Core/serverconfig.ini:626)).

An in-memory log is a ring buffer that cannot be overwritten while a transaction is still using it, so
when the active transaction's records no longer fit, `__log_inmem_chkspace` gives up and returns
`DB_LOG_BUFFER_FULL` with the explanation *"In-memory log buffer is full (an active transaction spans the
buffer)"* ([log.c:1429](../mapguide/MgDev/Oem/dbxml/db-4.8.26/log/log.c:1429)).

The practical rule is therefore: **one transaction cannot write more than the log buffer size.** Since
`DB_LOG_IN_MEMORY` is only set for the session repository, this error is effectively session-only — if
your stack names a `Library:` or `Site:` resource, treat it as something else and report it.

The failure is raised as `DB_LOG_BUFFER_FULL` (`-30992`), which is *not* the deadlock the resource service
retries on, so there is no retry storm: the [retry loop](../mapguide/MgDev/Server/src/Services/Resource/ServerResourceService.cpp:77)
only loops on `DB_LOCK_DEADLOCK`, and this error propagates on the first attempt.

## What writes that much

| Data name | Written by | Grows with |
| --- | --- | --- |
| `RuntimeData` | [`MgResource::SerializeToRepository`](../mapguide/MgDev/Common/PlatformBase/Services/Resource.cpp:105) — used by [`MgSelection::Save`](../mapguide/MgDev/Common/MapGuideCommon/MapLayer/Selection.cpp:139) | the number of selected features |
| `LayerGroupData` | [`MgMap::Save`](../mapguide/MgDev/Common/MapGuideCommon/MapLayer/Map.cpp:974) | the number of layers and groups in the map |
| any name you choose | `SETRESOURCEDATA` / `MgResourceService::SetResourceData` | the size of the uploaded file (`.sdf`, `.shp`, `.dwf`, …) |

The stream writer stores the **whole blob as one record in one transaction**:
[`ResourceDataStreamManager.cpp:99`](../mapguide/MgDev/Server/src/Services/Resource/ResourceDataStreamManager.cpp:99).
A huge resource *content* (XML) write fails the same way but through DB XML's
[`MgResourceDefinitionManager::PutDocument`](../mapguide/MgDev/Server/src/Services/Resource/ResourceDefinitionManager.cpp:512),
which is worth distinguishing in the stack.

A selection blob is one string per feature, so its size is linear in the selection:

```
bytes per feature = 1 + 4 + sizeof(wchar_t) * (len(base64 identity) + 1)
```

`sizeof(wchar_t)` is **4 on Linux and 2 on Windows**, so the same selection is twice the size here — a
selection that fits in the 1 MB default on Windows can fail on Linux. A 4-byte integer identity encodes
to 8 base64 characters, giving 41 bytes per feature and roughly 24 000 features per MB.

## Measured thresholds

Reproduced against the vendored Berkeley DB 4.8.26 with exactly the session repository's settings
(`DB_PRIVATE`, `DB_LOG_IN_MEMORY`, 2 MB cache, 2 KB pages):

| `SessionLogBufferSize` | largest single record written successfully | first size that fails |
| --- | --- | --- |
| 1 (default) | 972 800 B | 993 280 B |
| 16 | 15 360 000 B | 16 384 000 B |

So you get roughly 95 % of the configured value, and the value is in **MB** (allowed range 1–1024,
[validation table](../mapguide/MgDev/Common/MapGuideCommon/System/ConfigProperties.cpp:820)).

## Diagnose

**1. Read the last frame.** `MgResourceDataStreamManager.SetResourceData` is a blob write;
`MgResourceDefinitionManager::PutDocument` is an XML content write.

**2. Get the size and the target resource from the trace log.** In `serverconfig.ini`, enable the trace
log and ask the Resource Service for trace detail, then restart the server:

```ini
[TraceLogProperties]
Enabled                            = 1
Filename                           = "Trace.log"
Parameters                         = ResourceService:2
```

`MgServerResourceService.SetResourceData` logs `Id=`, `DataName=`, `DataType=` and `Size=`
([ServerResourceService.cpp:1753](../mapguide/MgDev/Server/src/Services/Resource/ServerResourceService.cpp:1753)),
so the entry names the exact resource, which data stream, and the byte count. That single line is usually
the whole diagnosis. (`2` is `MgLogDetail::Trace`, the level that makes `Size` get filled in.)

**3. Confirm the size from the client, without persisting anything.** Re-send the same
`QUERYMAPFEATURES` with `PERSIST=0`: the selection is still returned inline in `<FeatureSet>`, but nothing
is written to the repository. Then count it:

```bash
grep -o '<ID>' selection.xml | wc -l
```

`count * 41` bytes (integer identity) is roughly the blob you were trying to store. If the count is absurd for
the gesture — the whole table rather than the few features inside the box — stop here: the size limit is
only the messenger, and the filter is the bug (see [When the cause is upstream](#when-the-cause-is-upstream)).

**4. Check what is actually configured**, remembering that the value is read when the DB environment is
created, so a restart is required:

```bash
sed -n '/^\[DBEnvironmentProperties\]/,/^\[/p' /path/to/serverconfig.ini | grep LogBufferSize
grep '^SessionRepositoriesConfig' /path/to/serverconfig.ini
```

`SessionRepositoriesConfig = FilePerSession` (the default) means **one DB environment per session**, so
the buffer is allocated per live session — see the memory arithmetic below.

**5. Rule out the other repositories.** If `Id=` starts with `Library:` or `Site:`, those are opened with
an on-disk log and do not use this code path; that is a different defect.

## Fix

| Fix | Where | Notes |
| --- | --- | --- |
| Raise `SessionLogBufferSize` | `serverconfig.ini`, `[DBEnvironmentProperties]` (default 1, MB) | costs that much RAM **per session repository**; with `FilePerSession` and `SessionRepositoriesLimit = 200` a value of 16 is a worst case of ~3.2 GB of log buffers |
| Cap what is selected | mapagent `webconfig.ini`, `[AgentProperties]`, `GlobalMaxMapFeatureQueryLimit` (0 = off) | bounds the response, the persisted selection and the render cost together — the right fix for a viewer over a big table |
| Cap it per request | `MAXFEATURES` on `QUERYMAPFEATURES` | `-1` means `INT_MAX`; there is no other default cap |
| Stop persisting selections | `PERSIST=0`, or the stateless design in [mapguide-stateless-selection-handoff.md](./mapguide-stateless-selection-handoff.md) | removes the write entirely |
| One environment for all sessions | `SessionRepositoriesConfig = SingleFile` | one buffer for the whole server instead of one per session; changes how session state is stored, so test it |

Raising `LibraryLogBufferSize` (default 12) does **not** help this error, because the library repository
does not use the in-memory log. It only matters for large library writes, which fail differently.

Memory arithmetic for `FilePerSession`, where `N` is the number of live sessions and `S` the setting:

```
log buffers = N x S MB        (1 MB each today, so 200 sessions already reserve 200 MB)
```

If you need large single writes and cannot cap the query, prefer `SingleFile` plus a larger
`SessionLogBufferSize` over raising the per-session value blindly.

## When the cause is upstream

A buffer that fills is a *consequence* of a write that is too big, and the two most common upstream causes
are ones this repository has already hit:

- **A spatial filter that matches everything.** A clockwise ring in a SQL Server `geography` column means
  "the whole planet except this box", so a small drag can select the entire table — see fix 23 in
  [sqlserver-spatial-linux-support.md](./sqlserver-spatial-linux-support.md). The give-away is that
  reversing the drag direction changes the result, and that the feature count from step 3 is the row
  count of the layer.
- **A browser/unit mismatch.** Sending degrees to a map whose `CoordinateSystem` is
  `WGS84.PseudoMercator` (or the reverse) puts the filter somewhere unrelated to the data; combined with
  an unconstrained `MAXFEATURES` the result is either nothing or everything.

## Side effects worth knowing

- **A failed selection save leaves a placeholder behind.** `MgSelection::Save` first creates the resource
  with filler content (`SetResource`, its own transaction) and only then writes `RuntimeData`
  ([Resource.cpp:94](../mapguide/MgDev/Common/PlatformBase/Services/Resource.cpp:94)). When the second
  write fails, `Session:<sid>//<map>.Selection` exists with no data stream, so a later
  `GETDYNAMICMAPOVERLAYIMAGE` in that session looks like the selection silently vanished. The next
  successful save overwrites it.
- **Nothing is half-written.** The failed operation never reaches `Terminate()` (which *commits*); the
  repository manager's destructor aborts the uncommitted transaction instead
  ([RepositoryManager.cpp:62](../mapguide/MgDev/Server/src/Services/Resource/RepositoryManager.cpp:62)).
- **The client sees a 500 with the text above.** It is a server-side resource-service error, so it
  appears in the mapagent response and in `Error.log`, not in the map image or the feature reader.

## Related messages

| Message | Meaning |
| --- | --- |
| `DB_LOCK_DEADLOCK` (`-30994`) | a real deadlock; the resource service retries up to `sm_retryAttempts` (50) with a jittered sleep, then throws |
| `DB_LOG_BUFFER_FULL` (`-30992`, this page) | one transaction is larger than the in-memory log buffer; never retried |
| `ENOSPC` / failed log-directory write | the **on-disk** log of the library or site repository cannot grow; it is a disk-space problem, not this one |
| `DB_RUNRECOVERY` (`-30974`) | the environment needs recovery; restore the repository from backup and run the recovery script |
