# The FDO SQL Server Spatial provider on Linux

This note covers the port of `Providers/GenericRdbms/Src/SQLServerSpatial` to Linux: what now
builds, what it needs installed, which defects had to be fixed to make it work, and what is still
unverified. It is the SQL-Server-specific companion to
[`odbc-linux-support.md`](odbc-linux-support.md), which is about the *generic* ODBC provider.

Everything under `fdo/` here is a change set for the FDO Subversion working copy, not for this git
repository — see *Where the changes live* at the end.

## What was there before

The provider had **no CMake build at all**. `Providers/GenericRdbms/Src/CMakeLists.txt` recursed
into every other GenericRdbms provider (ODBC, MySQL, PostGIS, ...) but never into `SQLServerSpatial`,
so on Linux it did not compile, link or install — and `mapguide` could not consume it. Its sources
were Windows-only in a number of places.

## What now builds

Seven new `CMakeLists.txt`, modelled on the ODBC and PostGIS providers:

| Path | Target | What it is |
|------|--------|------------|
| `.../SQLServerSpatial/ODBCDriver/CMakeLists.txt` | `sqlserverspatialodbcdr` | The provider's own RDBI driver. Renamed from `FdoODBCDriver`, which collided with the *shared* `Src/ODBCDriver` target of the same name. Its sources are compiled as C++ (`set_source_files_properties(... LANGUAGE CXX)`) because they call `debug_trace`. |
| `.../SQLServerSpatial/Fdo/CMakeLists.txt` | `FdoRdbmsSQLServer_Fdo` | The `FdoRdbmsSqlServer*` connection/command layer. |
| `.../SQLServerSpatial/SchemaMgr/CMakeLists.txt` | `FdoRdbmsSQLServer_SchemaMgr` | Schema manager, recursing into `Lp` and `Ph`. |
| `.../SQLServerSpatial/SchemaMgr/Lp/CMakeLists.txt` | `FdoRdbmsSQLServer_SchemaMgr_Lp` | Logical/physical mapping, including the spatial-context classes. |
| `.../SQLServerSpatial/SchemaMgr/Ov/CMakeLists.txt` | `SQLServerOverrides-4.2.0` | The override shared library the core loads for SQL Server specifics. |
| `.../SQLServerSpatial/SchemaMgr/Ph/CMakeLists.txt` | `FdoRdbmsSQLServer_SchemaMgr_Ph` | Physical schema, recursing into `Rd`. |
| `.../SQLServerSpatial/SchemaMgr/Ph/Rd/CMakeLists.txt` | `FdoRdbmsSQLServer_SchemaMgr_Ph_Rd` | The readers. |
| `.../SQLServerSpatial/CMakeLists.txt` | `SQLServerSpatialProvider-4.2.0` | The provider itself, linked with `-Wl,-whole-archive` over the static libraries above and installed as `libSQLServerSpatialProvider.so` (+ versioned symlink). |

`Providers/GenericRdbms/Src/CMakeLists.txt` gained `add_subdirectory( SQLServerSpatial )`, and
`Providers/GenericRdbms/CMakeLists.txt`'s install rule now also picks up `ExtendedCoordSys.txt`,
which the provider reads next to its `com` directory.

The unit tests build as `UnitTestSQLServerSpatial`
(`Src/UnitTest/SQLServerSpatial/CMakeLists.txt` + the `SQLServerSpatialUnitTests` static library),
and `Common/ReaderTest.cpp` was added to `CommonUnitTests` — `SqlServerReaderTest` derives from it
and, without it, the link failed with missing base-class symbols.

## What it needs on Linux

The provider is an ODBC *client*: it brings no driver of its own, exactly like the generic ODBC
provider. The Microsoft driver is required — nothing else speaks TDS with the `geometry`/`geography`
UDTs it relies on.

```sh
wget -q https://packages.microsoft.com/keys/microsoft.asc -O- | gpg --dearmor > /etc/apt/trusted.gpg.d/microsoft.gpg
wget -q https://packages.microsoft.com/config/ubuntu/22.04/prod.list -O /etc/apt/sources.list.d/mssql-release.list
apt-get update
ACCEPT_EULA=Y apt-get install -y msodbcsql17
```

That registers `[ODBC Driver 17 for SQL Server]` in `/etc/odbcinst.ini`. The provider looks the
driver up **by name**, and the default is hard-coded to that string; override it with
`FDO_SQLSERVER_ODBC_DRIVER` (e.g. to use driver 18) — the name is the `[section]` in
`odbcinst.ini`, not a path:

```sh
FDO_SQLSERVER_ODBC_DRIVER="ODBC Driver 18 for SQL Server" ./UnitTestSQLServerSpatial ...
```

The same variable is honoured by the unit test's connection helper
(`Src/UnitTest/SQLServerSpatial/SqlServerConnectionUtil.cpp`), which on Windows probed `SQLNCLI`
instead.

### Connection string and init file

The provider adds its own `DRIVER={...};MARS_Connection=yes;SERVER=...` clauses to whatever
`Service=`, `Username=` and `Password=` describe, so a SQL Server init file uses a **comma** for
the port, not a colon:

`templates/scripts/container/test_init/SqlServerSpatialInit.txt`

```
provider=SQLServerSpatial;service=host.docker.internal,1434;username=sa;password=Sql2016!;clean=true;
```

Port 1434 is the `mssql_cs` fixture in `dbs/docker-compose.yml`: the Linux suite's own instance, with
the case-sensitive collation it needs, separate from the port 1433 fixture the Windows harness
points at. See [Known issues](#known-issues) for why the two must not share one instance.

Use it with the suite runner:

```sh
./env_test_thin.sh --target fdo --distro ubuntu22 --cpu x64 --with-sqlserver-init ./templates/scripts/container/test_init/SqlServerSpatialInit.txt
```

`run_fdo_tests.sh --with-sqlserver-init <file>` adds `UnitTestSQLServerSpatial` to the selected
suites and passes the file as `initfiletest=<file>`; `--with-sqlserver-perf` additionally runs it
with `FDO_SQS_PERF=1`.

## The portable-vs-Windows changes

Beyond the build wiring, the sources needed these changes. None of them changes behaviour on
Windows — where `sizeof(long) == sizeof(int)`, `%s` in a wide format string means a *wide* string,
and the driver runs in unicode mode, each change is a no-op.

### Platform assumptions

| File | Change |
|------|--------|
| `SQLServerSpatial.cpp` | The non-Windows branch now computes the provider's own library name (`libSQLServerSpatialProvider` under CMake, `libFdoSQLServerSpatial` otherwise) and the `com` directory with `dlopen`/`dlinfo` + a prefix match, instead of `LoadLibrary`/`GetModuleFileName`. |
| `Fdo/FdoRdbmsSqlServerConnection.cpp` | `GenConnectionStringParm` built the connection string around a `SQLNCLI` probe under `#ifdef _WIN32`; the Linux branch now takes the driver name from `FDO_SQLSERVER_ODBC_DRIVER` (default `ODBC Driver 17 for SQL Server`). |
| `SchemaMgr/Ph/Owner.cpp` | `_wfopen` → `fopen( (const char*)fileName, "rt")` off Windows. |
| `SchemaMgr/Ph/Rd/SpatialContextReader.cpp` | `_isnan` → `FdoCommonOSUtil::_isnan` (4 uses). |
| `ODBCDriver/savepoint.c` | `wsprintfW`/`wsprintfA` → `odbcdr_swprintf`/`snprintf` (4 sites). |
| `ODBCDriver/sql.c` | Hoisted declarations out of `local_odbcdr_sql`'s switch — GCC rejects a `goto` that jumps over an initialisation. |
| `ODBCDriver/constants.h`, `connect.c` | `get_drivertype()` now recognises the Linux driver names (`msodbcsql*`, `tdsodbc*`) as well as the Windows ones (`SQLNCLI`, `SQLSRV32`). |
| Several headers/sources | Include-path and symbol case fixes (`FdoRdbmsSQLBuilder.h`, `ColumnBLOB.h`, `constants.h`, ...) — the Windows filesystem is case-insensitive, so these only bite here. |
| `Fdo/FdoRdbmsSqlServerProcessors.*` | `_wcsicmp` → a `wcscasecmp` shim. |
| `Src/UnitTest/SQLServerSpatial/*` | Test-side Windows-isms: the driver name comes from the environment as above; `FdoDataValue::Create` calls that GCC found ambiguous are cast; an MSVC-style extra qualification in `SqlServerSchemaMgrTests.h` is gone; two test files that contain 8-bit characters in wide literals are compiled with `-finput-charset=ISO-8859-1`. |

### Correctness defects that only show up on LP64 or with glibc

These are the interesting ones: each was found by running the suite and each produces a symptom far
from its cause. They are listed with the message that led to them.

**1. `SQLINTEGER` result columns read back as 0 — `desc_slct.c`**

`SQLDescribeCol`'s `SQL_INTEGER` case reported `RDBI_INT` with `*binary_size = sizeof(long)`. The
RDBI/Gdbi layer sizes and strides a column's buffer from that number, but the value an `RDBI_INT`
column carries is 4 bytes (which is what the driver binds — `get_o_t_s.c` sets
`*odbcdr_size = sizeof(int)`), so on LP64 the framework allocated and stepped an 8-byte slot for a
4-byte value. Every `int`-typed result column then read as 0.

The visible symptom was a *schema* failure, not a query failure:

```
UTF8 representation of Schema Element Name exceeds 0 characters, value is 'unique2_1'
```

— the physical schema's column lengths are read through that path, so every metaschema column
(`f_schemainfo.schemaname` is `nvarchar(200)`) reported length 0, and every schema element failed
validation against a limit of 0. Trailing damage was worse than the message suggested: because the
described schema looked constraint-less, re-applying it dropped the real `CHECK` constraints from
the database. Fixed by reporting `sizeof(int)`.

**2. `nvarchar(max)` values truncated to one character — `desc_slct.c`**

A wide column with no declared length (`nvarchar(max)`, `ntext`) is reported as `RDBI_STRING_ULEN`
off Windows, and that type is read as a *chunked blob* — `SQLGetData(SQL_C_BINARY)` — which returns
the column's raw bytes. For a wide column those bytes are UTF-16, and the narrow reader treats them
as UTF-8, so the value ended at the first NUL: the SQL Server check-clause text
`([byterange]>=(11) AND [byterange]<(22))` arrived as `(`. The same applied to
`default_value`. With the clauses unreadable, the constraint reader found nothing to match, and the
next schema apply dropped the check constraints from the table.

Fixed by reporting a *bounded narrow string* for these columns off Windows
(`ODBCDR_WLONGVARCHAR_SIZE * 3 + 1` bytes, i.e. the 32,000 characters the framework already treats
as the limit for such values), which makes the driver convert the column to its narrow encoding
itself.

**3. Heap overflow in the geometry path — `ODBCDriver/geom.c`**

`boundParmID` was declared `SQLUINTEGER` (4 bytes) but passed as `(SQLPOINTER*)&boundParmID` to
`SQLParamData`, which writes a full **pointer**. On LP64 the upper 4 bytes went into the adjacent
local, `count` — the byte count handed to `SQLPutData`. The driver was therefore asked to read
~32,767 bytes from a 22-byte buffer:

```
==581==ERROR: AddressSanitizer: heap-buffer-overflow ... READ of size 32767
    #5 ... in SQLPutData
    #7 ... geom_convertToSqlServer_S .../ODBCDriver/geom.c:1315
```

It crashed `DataTypeTests::geometry` and, because ASan aborts the process, every fixture after it.
Fixed by declaring the token `SQLPOINTER` in both places it is used (`geom_convert_S` and
`geom_convertToSqlServer_S`).

**4. `USE "f"` instead of `USE "fdo_user"` — `SchemaMgr/Ph/Owner.cpp`**

`FdoSmPhSqsOwner::SetCurrent()` called `rdbi_set_schemaW` unconditionally. Off Windows the driver
runs in *narrow* mode (`odbcdr_UseUnicode == false`), so the wide entry point's string was read
through the narrow union member: the first UTF-16 byte (`f`) terminated the C string. Every
connection then tried to switch into database `f`, and the datastore tests failed with

```
Database 'f' does not exist. Make sure that the name is entered correctly.
```

Fixed by selecting the entry point from the driver's unicode capability, exactly as the generic
ODBC provider's `FdoSmPhOdbcOwner::SetCurrent()` does.

**5. `Invalid column name 'N'` — `SchemaMgr/Ph/Rd/FkeyReader.cpp`**

A wide format string used `%s` for a value that is a wide string. **MSVC's `wprintf` family treats
`%s` as a wide string; glibc follows C99 and treats it as a *narrow* one**, so the literal became
its first byte — the `N` of `N'fdo_user_constraints'` — and the foreign-key query failed to
compile on the server:

```
Invalid column name 'N'.
The batch could not be analyzed because of compile errors.
```

Fixed by using `%ls`, matching the other placeholders in the same statement. This is a general
hazard in this tree: any `L"..."` passed to `FdoStringP::Format` whose arguments are `FdoString*`
must use `%ls`.

**6. A failed test reported as a stack overflow — `Utilities/TestCommon/Src/TestCommonMiscUtil.cpp`**

Not provider code, but it hid the provider's failures: `TestCommonFail` concatenated the whole
exception chain — one `wcscat` per cause — into `wchar_t message[2000]` with no bound. A schema
error nests one cause per offending property, so the report ran off the end of the buffer and the
run died with `AddressSanitizer: stack-overflow ... nested bug in the same thread, aborting`
instead of naming the failure. The concatenation is now bounded and always terminated.

**7. Non-ASCII names failed with a 64 GiB allocation — the provider's unit tests**

The tests that exercise delimited/Unicode names built them with `%c`:

```c
return FdoStringP::Format( L"t%cble_id_geom", 0xe4 );   // "täble_id_geom"
```

In a *wide* `printf`, C99 says a bare `%c` converts its argument with `btowc` — as a *multibyte*
character — while MSVC treats it as a wide character. `btowc(0xe4)` fails outside a locale whose
encoding maps that single byte, so glibc's `vswprintf` returns -1, and `FdoStringP::Format`
doubles its buffer and retries **forever**:

```
==2558==ERROR: AddressSanitizer: allocator is out of memory trying to allocate 0x1000000000 bytes
    #1 ... FdoStringP::Format(wchar_t const*, ...) .../StringP.cpp:544
    #2 ... SqlServerFdoUpdateTest::TableIdGeomName() .../SqlServerFdoUpdateTest.cpp:158
```

which aborts the whole run. The suite's own NLS helpers already use the correct conversion
(`UnitTestUtil::GetNlsValue` builds `L"Val%lc%lc%lc"`), so the fix is to use `%lc` in the four
places that had `%c`. Note that `FdoStringP::Format`'s retry loop is itself fragile — it cannot tell
"buffer too small" from "format failed", so any bad conversion grows the buffer until the allocator
gives up.

**8. Every non-ASCII name in a statement literal silently matched nothing — the process locale**

This is the one that made the suite look like it had a schema-apply bug, and it is the largest of
the portability defects. `SqlServerFdoInsertTest::insert` failed with

```
(SchemaManager.cpp: 439) Cannot add schema Länd to database; it already exists
```

although the schema *was* stored correctly (`f_sad` holds `elementtype='schema'`,
`ownername`/`elementname` = UTF-16 `4C 00 E4 00 6E 00 64 00`, `name='version'`) — meaning the write
worked and the *read* did not. It is worth following the chain, because it is not obvious:

1. `FdoSmPhSADReader::MakeReader` reads a schema's attributes with a statement built by
   `FdoSmPhSqsMgr::FormatSQLVal`, which for a string emits `N'<value>'`;
2. the narrow ODBC API takes that text as `char*`, and FDO emits **UTF-8**, so the literal on the
   wire is `ownername = N'L<C3><A4>nd'`;
3. **unixODBC converts that narrow text to wide using `LC_CTYPE`**, and the process is in the `"C"`
   locale, where those bytes are read as Latin-1 — so the driver looks for `LÃ¤nd` and the statement
   returns no rows;
4. `ContainsAttribute(L"version")` is therefore false, `UnitTestUtil::CreateLandSchema` takes its
   "destroy and re-create" branch, and the re-create then fails because the schema really is still
   there.

Three things make this worth writing down. First, a C/C++ program **starts in the `"C"` locale
whatever `LC_ALL`/`LC_CTYPE` say** — the environment is only honoured once `setlocale()` is called,
which this suite never did, so exporting `LC_ALL=C.UTF-8` on the command line changes nothing.
Second, the wide ODBC path is not an escape: `rdbi_init.c` turns `odbcdr_UseUnicode` off on Linux
with the comment *"Linux defaults wchar_t to UTF32, but Easysoft driver expects UTF16 (like on
Windows)"*, so the narrow path is deliberate and the locale is part of its contract. Third, the
failure is **silent** — no ODBC error, just an empty result set — which is why it surfaced as an
unrelated-looking schema error.

The encoding could be pinned down from outside the provider. Running `isql` with the *same* literal
encoded both ways, in both locales, gives a 2×2 that names the contract exactly:

| locale | literal bytes | row found |
| --- | --- | --- |
| `POSIX` | Latin-1 `E4` | yes |
| `POSIX` | UTF-8 `C3 A4` | no |
| `C.UTF-8` | Latin-1 `E4` | no |
| `C.UTF-8` | UTF-8 `C3 A4` | yes |

So FDO's UTF-8 output is right; the process just has to *ask* for a UTF-8 `LC_CTYPE`. The fix is two
lines in `Providers/GenericRdbms/Src/UnitTest/Common/UnitTest.cpp`'s `main` — `setlocale(LC_ALL, "")`
— plus the `LC_CTYPE=C.UTF-8` default in `run_fdo_tests.sh` that gives that call something UTF-8 to
pick up. Only `LC_CTYPE` is defaulted, so `LC_NUMERIC`/`LC_COLLATE` stay in the `"C"` locale the
suites expect. An application embedding this provider on Linux needs the same `LC_CTYPE`; setting
`LC_ALL` in the environment is not enough on its own, because the library or application must call
`setlocale()`.

It is not only literals. A quoted identifier goes to the server as a bare (non-`N'`) string too, so
`CREATE TABLE` was affected in the same way and wrote `prÃ¶vince` where the property is `Prövince` —
one column that can never be found again, and a `Property 'Prövince' not found` error from an insert
that is looking at a table whose column is really there. That is also why a datastore created before
this fix has to be dropped rather than reused; see [Known issues](#known-issues).

**9. A dead static map was destroyed twice at exit**

AddressSanitizer reported a double free at exit, and the two stacks are identical except for their
outermost frame — which is what names the cause:

```
#19 FdoSmPhGrdMgr::StringMap::~StringMap()
#20 FdoSmPhSqsMgr::SqsStringMap::~SqsStringMap()
#21 __cxa_finalize          <- the first free, reached from the provider DSO itself
...
#21 __run_exit_handlers     <- the second free, on the ordinary exit path
```

An ordinary run hides this, because LeakSanitizer exits the process before the static destructors
run; it takes `ASAN_OPTIONS=detect_leaks=0` to see it at all. The object destroyed twice is
`FdoSmPhSqsMgr::mSqsReservedDbObjectNames`, a static `SqsStringMap` (a `std::map` subclass). Two
things about it matter, and together they make the fix a deletion:

- **It is dead code.** Its accessor is an empty constructor — `SqsStringMap()`'s entire body is
  `// No reserved words for SqlServer` — and nothing ever calls `IsReserved()` on it. The words it
  holds come from the base `FdoSmPhGrdMgr::StringMap` constructor, and nothing reads them back.
- **A static data member is a global symbol with external linkage, and this one is defined in two
  images at once**: the provider DSO and the unit-test executable, because that test compiles the
  provider's `SchemaMgr/Ph/Mgr.cpp` as well as linking the provider. File-scope `static` objects do
  not have this problem — they have internal linkage, so each image keeps a private copy with its own
  constructor and destructor.

The fix is to delete the map, its nested class, its definition and its constructor
(`SQLServerSpatial/SchemaMgr/Ph/Mgr.h`, `.../Mgr.cpp`). It has no callers, so this cannot change
behaviour, and it clears the double free and every leak record that came with it:

| `FdoDatastoreTest`, Debug (ASan) | before | after |
| --- | --- | --- |
| result | OK (7) | OK (7) |
| direct LSan records | 0 | 0 |
| indirect LSan records | 131 (8 384 bytes) | **0** |
| `attempting double-free` (`detect_leaks=0`) | 1 | **0** |

An earlier revision of this document kept the map and held it by pointer, never destroying it, on the
theory that any static teardown in a `dlclose()`d provider runs twice under the pinning FDO ticket
#965 describes. That did remove the double free but left 132 LSan records — the leaked map plus its
nodes — where deleting the dead object leaves none. The general theory is wrong anyway:
`ColTypeMapper.cpp`'s file-scope statics have destructors and are finalised exactly once, and the
sibling providers' maps are clean (below). Two things set this object apart — it is *dead*, so
nothing keeps it reachable, and it is a global symbol that two images define — but why that
combination destroys it twice while the live ones are fine was not established.

The same pattern in the other providers was measured before deciding to leave it alone. Each was run
on the `FdoDatastoreTest` fixture with leak detection left in its default state, and again with
`ASAN_OPTIONS=detect_leaks=0`:

| Provider | map | consulted? | double free? | direct records | indirect records |
| --- | --- | --- | --- | --- | --- |
| SQL Server Spatial | `mSqsReservedDbObjectNames` | no — dead code | 1 → **0** | 0 | 131 → **0** |
| ODBC | `mOdbcReservedDbObjectNames` | yes, `Mgr.cpp:185` | not run — see below | — | — |
| MySQL | `mMySqlReservedDbObjectNames` | yes, `Mgr.cpp:273` | 0 | 0 | 0 |
| PostGIS | `mReservedWords` | yes, `Mgr.cpp:357` | 0 | 0 | 0 |

MySQL and PostGIS each have their own instance here (`UnitTestMySql`, `UnitTestPostGis`) and are green
in both configurations with nothing reported, so there is nothing to fix in them; and unlike this one
their maps are load-bearing, so they cannot be deleted either. ODBC is listed as unverified rather
than clean: its suites need Access, Excel and dBASE drivers that this container does not have. That
three live maps are unaffected is the strongest argument for not editing them — the change here is
justified by removing dead code from one provider, not by a defect the others are believed to share.

**10. A string output parameter was read as `wchar_t` on the narrow path**

`FdoRdbmsPropBindHelper::BindBack()` is what copies an output parameter back into its FDO value.
Every text-valued case resolves the buffer's width — `FdoDataType_DateTime` branches on
`cmds->SupportsUnicode()` and passes `(char*)` or `(wchar_t*)` accordingly, and the bind struct is
documented as `void *strvalue; // can be char* or wchar_t*` — except `FdoDataType_String`, which
always cast to `wchar_t*`. A provider that declares no unicode support binds the parameter **narrow**,
and the bind cases write UTF-8 into that buffer with `_ut_utf8_from_unicode`, so
`FdoStringValue::SetString()` was handed UTF-8 and ran `wcslen` over it as 4-byte units:

```
READ of size 16004
  #1 FdoStringValue::SetString(wchar_t const*)                    Fdo/Unmanaged/Src/Fdo/Expression/StringValue.cpp:94
  #2 FdoRdbmsPropBindHelper::BindBack(...)                        Providers/GenericRdbms/Src/Fdo/Pvc/FdoRdbmsPropBindHelper.cpp:1245
  #3 FdoRdbmsSQLCommand::ExecuteReader()                          Providers/GenericRdbms/Src/Fdo/Other/FdoRdbmsSQLCommand.cpp:697
  #4 SqlServerFdoSqlCmdTest::TestOutParamsStoreProcRetAndInOut()  Providers/GenericRdbms/Src/UnitTest/SQLServerSpatial/SqlServerFdoSqlCmdTest.cpp:321
```

`EnsureSize()` compounded it: the buffer is `new char[2*sz]` with no zero-fill, so nothing guaranteed
a terminator and the scan covered the whole buffer (`_SQL_MAX_VAR_LEN_BIND` is 8000, giving 16 000
bytes — the 16 004 ASan reported). `GdbiQueryResult` zero-fills the equivalent buffers on the reader
path, so the fix does the same. Both changes sit in `Fdo/Pvc/FdoRdbmsPropBindHelper.cpp` and follow the
file's own idioms:

- `BindBack`'s `String` case branches exactly as `DateTime` does, converting the narrow form with
  `_ut_utf8_to_unicode` — the inverse of the `_ut_utf8_from_unicode` the bind cases already use — sized
  as `strlen + 1` elements, the `A2W_SLOW` idiom in `Providers/SQLite/Src/Provider/SltConversionUtils.cpp`.
- `EnsureSize` zero-fills the buffer it allocates, so termination no longer depends on the driver.

This is **shared core**, so it applies to every GenericRdbms provider, and the blast radius was
measured rather than assumed. The parameter-binding path is exercised by the SQL Server suite alone:
`MySqlFdoSqlCmdTest` never binds a parameter, no MySQL or PostGIS test uses
`ParameterDirection_Output`, and no provider subclasses `FdoRdbmsSQLCommand`. All three providers
declare the narrow path (`supports_unicode = 0` in `MySQL/Driver/rdbi_init.cpp:130` and
`PostGis/Driver/rdbi_init.c:132`; the ODBC driver's `odbcdr_UseUnicode`, which this port turns off on
Linux, for SQL Server).

| Suite, Debug/ASan | before | after |
| --- | --- | --- |
| `UnitTestSQLServerSpatial`, whole suite | aborted mid-run, **no fixture summary printed** | `Run: 288   Failure total: 14`, 0 ASan errors |
| the out-param test itself | aborted the process | passes |
| `UnitTestMySql`, whole suite | — | `OK (249)`, 0 ASan errors |
| `UnitTestPostGis`, whole suite | — | `OK (140)`, 0 ASan errors |

It is **order-dependent**, which is why one symptom alone misleads: run on its own, `FdoSqlCmdTest`
completed all 27 tests with no ASan error even before the fix, because the same code path takes a
different branch depending on what ran earlier in the process. The suite's 14 remaining failures are
outside this path — geography and spatial-context mapping (`Sm/Lp/SpatialContext.cpp:644`),
master-file comparisons, an rdbi-level connect, a mangled `Länd` class name, and
`TestInParamsStoreProcVariant`'s BLOB payload — and the unfixed tree died before printing any of them,
so they are attributed by path rather than by a before/after run.

## Relationship to the sibling ODBC driver

`Providers/GenericRdbms/Src/SQLServerSpatial` is largely a copy of `Providers/GenericRdbms/Src/ODBC`,
so the same defects exist there and were **not** fixed by this work:

- `ODBCDriver/geom.c` declares `boundParmID` as `SQLSMALLINT` (2 bytes!) at lines 547 and 1120 and
  passes it to `SQLParamData` as a `SQLPOINTER*`. On Linux that writes an 8-byte pointer into a
  2-byte local — a stack smash with the same signature as fix 3 above. It is exercised only by the
  `Odbc*` suites, which are not run here.
- The `%s`-in-a-wide-format hazard (fix 5) is a trap for any file in either provider.

## Validation

Run from the build area with the message catalogue in place:

```sh
cd /tmp/work/build_area/fdo/Providers/GenericRdbms/Src/UnitTest
export NLSPATH=/tmp/work/build_area/fdo/nls/linux/en_US/%N
export LC_CTYPE=C.UTF-8    # required; see fix 8. run_fdo_tests.sh defaults it
./UnitTestSQLServerSpatial initfiletest=<init file>            # whole suite
./UnitTestSQLServerSpatial initfiletest=<init file> FdoSelectTest   # one fixture
```

A Debug build is ASan/LSan-instrumented, so a green run still exits non-zero — judge it by
`OK (<n>)` in the output, not by the exit code. Read the report with care in both directions: the
leak report is empty for the fixtures measured (fix 9 removed the 131 records `FdoDatastoreTest` used
to carry), but AddressSanitizer still finds a genuine defect on the stored-procedure path, which
aborts the process — so a whole-suite run stops there and prints no fixture summary at all. See
[Known issues](#known-issues).

Fixtures measured green in Debug (ASan) against SQL Server 2017 through msodbcsql17, all of which
failed before the fixes above: `FdoDatastoreTest` OK (7), `FdoConstraintsTest` OK (16),
`DataTypeTests` OK (30), `SelectTests` OK (5), and — once the pre-fix datastore is dropped, see
[Known issues](#known-issues) — `FdoInsertTest` OK (14). Those figures were taken on the port 1433
instance with the image's default case-*in*sensitive collation, because that is what the init file
pointed at when they were measured; the fixture split now sends the suite to `mssql_cs` instead, and the only result that collation
changes is `FdoApplySchemaTest`'s failure mode. Measured on `mssql_cs`: `FdoDatastoreTest` OK (7) with
no LSan records at all, and `FdoApplySchemaTest` `Run: 5   Failure total: 1` — the duplicate-key error
is gone and the remaining failure is the master-file comparison described under
[Known issues](#known-issues).

The suite as a whole is **not** green yet. Everything except `FdoApplySchemaTest` passes on both
instances; that fixture reports `Run: 5   Failure total: 1` on each, but for *different* reasons, so
both are worth running. The split was found by re-running the same fixtures against a throwaway
case-sensitive instance (`MSSQL_COLLATION=Latin1_General_CS_AS`):

| Fixture | case-insensitive fixture | case-sensitive instance |
|---|---|---|
| `FdoDatastoreTest` | OK (7) | OK (7) |
| `FdoConstraintsTest` | OK (16) | OK (16) |
| `DataTypeTests` | OK (30) | OK (30) |
| `SelectTests` | OK (5) | OK (5) |
| `FdoInsertTest` | OK (14) \* | OK (14) |
| `FdoApplySchemaTest` | `Run: 5   Failure total: 1` | `Run: 5   Failure total: 1` |

\* after dropping the datastore an earlier build wrote; before that it failed with
`Property 'Prövince' not found`.

`FdoApplySchemaTest`'s one remaining failure is `TestSchema`'s duplicate-key error, so it wants the
collation change above. Its other failure was a different thing altogether and is fixed: `TestNoMeta`
is a negative test that applies a schema which already exists and asserts the exception text, and it
expected that text to end in a trailing space. The catalogue text in
`Utilities/SchemaMgr/Nls/SmMessage.mc` has never had one, so the test compared
`Cannot add schema X to database; it already exists` against `Cannot add schema X to database; it
already exists ` — a one-character mismatch that fails on any platform, while the schema operation
under test had in fact behaved correctly. Deleting the stray space removed that failure.

What `FdoApplySchemaTest::TestSchema` complains about depends on the instance, which is itself the
point. On the fixture it is the duplicate-key error from the collation problem above. On a
case-sensitive instance the schema operations finally succeed and it is a **master-file comparison**
instead — the two are described under [Known issues](#known-issues).

The changes are part of the official build, not just a hand-built tree: a full Debug `build_thin.sh`
pass on ubuntu22 (`./build_thin.sh --target fdo --distro ubuntu --tag 22 --cpu x64 --debug`)
configures, builds, installs and packages with the provider included, and the resulting
`artifacts/Debug/fdosdk-4.2.0.8364-ubuntu22-amd64.tar.gz` contains

```
lib64/libSQLServerSpatialProvider-4.2.0.so
lib64/libSQLServerSpatialProvider.so
lib64/libSQLServerOverrides-4.2.0.so
lib64/libSQLServerOverrides.so
include/Rdbms/Override/SQLServerSpatial/*.h
```

### The `FDO_SQS_PERF=1` opt-in, measured

The fast path is portable — it is read with a plain `getenv` and no `_WIN32` guard, in
`ODBCDriver/rdbi_init.c` (`odbcdr_FastCursors`, the memoised `SQLDescribeParam()`) and
`SchemaMgr/Ph/Mgr.cpp` (`mPerfEnabled`, the cached database-object catalog) — and it repays opting in.
Measured by counting the ODBC calls the provider makes, through unixODBC's own driver-manager trace
(`Trace = Yes` in the `[ODBC]` section of `/etc/odbcinst.ini`, which logs every `SQLDescribeParam`,
`SQLPrepare` and `SQLExecDirect`), over four fixtures:

| Fixtures | `FDO_SQS_PERF` | Wall clock | `SQLDescribeParam` | `SQLPrepare` |
|---|---|---|---|---|
| `DataTypeTests`, `FdoConstraintsTest`, `SelectTests`, `FdoInsertTest` | unset | 82 s | 16 222 | 11 674 |
| the same four | `1` | 34 s | 5 116 | 10 692 |

Run in both orders to rule out warm-up (the reverse ordering gave 102 s unset against 33 s set), so the
speed-up is the option's rather than the caches'. Every fixture stayed `OK` in both modes, and the
runs are leak-neutral (zero direct LSan records either way). The driver's `TraceFile` is the cheapest
way to confirm the memoisation is actually engaging, because it is invisible from outside the provider.

## Known issues

- **The instance must use a case-sensitive collation.** FDO class and schema names are
  case-sensitive; a datastore created without an explicit collation inherits the server's, and the
  image's default (`SQL_Latin1_General_CP1_CI_AS`) is case-*in*sensitive. The unique index on
  `f_classdefinition(classname, schemaname)` then rejects two classes whose names differ only in
  case and `FdoApplySchemaTest` fails with

  ```
  Cannot insert duplicate key row in object 'dbo.f_classdefinition' with unique index 'f_classdef_schnm_idx'.
  The duplicate key value is (aCxdATA, Acad).
  ```

  This is the SQL Server form of the case-sensitivity problem the README already documents for
  `mysql_56`. Fix the instance rather than the provider, and note that it has to be done when the
  server is **created** — `ALTER DATABASE model COLLATE` is refused while the database is in use,
  and `mssql-conf set-collation` needs a restart. `dbs/docker-compose.yml` therefore ships the
  collation-pinned instance as `mssql_cs` (`MSSQL_COLLATION=Latin1_General_CS_AS`, which the 2017
  image honours — `Attempting to change default collation to Latin1_General_CS_AS` appears in its
  startup log — on port 1434), and the suite's init file points at it. A hand-built instance needs
  the same:

  ```
  podman run -d --name sqs_cs -e ACCEPT_EULA=Y -e SA_PASSWORD='Sql2016!' \
      -e MSSQL_COLLATION=Latin1_General_CS_AS -p 1434:1433 \
      mcr.microsoft.com/mssql/server:2017-latest
  ```

  A failure like this also leaves the connection's transaction open, which makes the fixtures after it
  crawl or appear to hang.

- **The Windows and Linux suites must not share one SQL Server instance.** Both derive their datastore
  name from the OS account (`fdo_<account>` — `fdo_user` for the Windows harness, `fdo_root` inside the
  build container), so they do not normally collide, but `FdoDatastoreTest` enumerates, creates and
  destroys datastores server-wide and its own tests assume a private server, so on a shared instance
  that fixture's result depends on whatever the other run left behind. `dbs/docker-compose.yml`
  therefore provides two fixtures on different ports, so both can be up at once: `mssql` (1433, the
  image's default collation) for the Windows suite, and `mssql_cs` (1434, case-sensitive) for this one.
  Two further hazards when sharing: a restart or recreate mid-run shows up as `RDBMS: No current open
  database` failures that look like a code regression, and changing the collation changes which of
  `FdoApplySchemaTest`'s two failures appears.

- **`SqlServerFdoSqlCmdTest` aborted the whole suite under AddressSanitizer — fixed by [fix 10](#10-a-string-output-parameter-was-read-as-wchar_t-on-the-narrow-path).** This entry is kept for the diagnosis, and for one failure it left behind. A Debug run of the full
  suite stops in `TestOutParamsStoreProcRetAndInAndOut` with a heap-buffer-overflow, so **no fixture
  summary is printed at all** and the exit code says only that ASan found something:

  ```
  READ of size 16004
    #0 __interceptor_wcslen
    #1 FdoStringValue::SetString(wchar_t const*)                        Fdo/Unmanaged/Src/Fdo/Expression/StringValue.cpp:94
    #2 FdoRdbmsPropBindHelper::BindBack(unsigned long, FdoLiteralValue*) Providers/GenericRdbms/Src/Fdo/Pvc/FdoRdbmsPropBindHelper.cpp:1245
    #3 FdoRdbmsSQLCommand::ExecuteReader()                              Providers/GenericRdbms/Src/Fdo/Other/FdoRdbmsSQLCommand.cpp:697
    #4 SqlServerFdoSqlCmdTest::TestOutParamsStoreProcRetAndInOut()      Providers/GenericRdbms/Src/UnitTest/SQLServerSpatial/SqlServerFdoSqlCmdTest.cpp:321
  ```

  The `String` case is the one text-valued case in `BindBack` that does **not** branch on
  `cmds->SupportsUnicode()` — the `DateTime` case 87 lines above it does exactly that (`(char*)`
  when unicode is off, `(wchar_t*)` when it is on), and the bind struct is itself documented as
  `void *strvalue; // can be char* or wchar_t*`. On this platform the parameter is bound **narrow**:
  `GdbiCommands::bind` throws "Cannot bind widechar strings; target RDBMS does not support widechar
  strings" for `RDBI_WSTRING` when unicode support is off, and no exception was taken — so the buffer
  holds UTF-8 that `wcslen` walks as 4-byte units. The buffer size corroborates it: `EnsureSize`
  allocates `new char[2*sz]`, and with `_SQL_MAX_VAR_LEN_BIND` at 8000 that is 16 000 bytes, matching
  the 16 004 ASan reported. On Windows the wide branch is what already runs, so adding the missing
  branch is a no-op there.

  It is **order-dependent**, which is why one symptom on its own misleads. Run on its own,
  `FdoSqlCmdTest` completes **all 27 tests with no ASan error** and
  `TestOutParamsStoreProcRetAndInAndOut` prints its values — the same code path takes a different
  branch depending on what ran earlier in the process. A second symptom of the same family appears in
  that solo run: `TestInParamsStoreProcVariant` fails a `ret == L"20000000280"` assertion with a
  garbled value printed (`Value = <replacement characters>`). Both point at string parameter
  marshalling disagreeing about width in the SQL-command path, not at the test.

  `TestInParamsStoreProcVariant` is a **separate, still-open** failure, and it is not the overflow: it
  binds a `sql_variant` OUT as an `FdoBLOBValue` and then reinterprets the payload as a `wchar_t[]`
  with `sizeof(wchar_t)` strides (`SqlServerFdoSqlCmdTest.cpp:842`) — a Windows-shaped expectation of
  2-byte `wchar_t` over a UTF-16 payload, which is what produces the `Value = <replacement
  characters>` in the log on Linux. Whether the provider should hand back platform-wide text for a
  BLOB-bound `sql_variant`, or the test should decode its own payload, is still undecided.

  A case-sensitive instance is what `SqlServerFdoApplySchemaTest::TestSchema` needs; with it, and with
  the datastore recreated as described below, everything measured here passes except that fixture's
  master-file comparison, which is the next bullet.

- **A datastore written before fix 8 must be recreated — the identifiers in it are mangled.** Fix 8
  turned out to cover the last failure as well, but only for a datastore created *after* it, and the
  mechanism is worth knowing. With the failure in place, `Property 'Prövince' not found` comes from
  `FdoRdbmsSimpleInsertCommand`'s look-up of a property that *is* present in the class definition:
  `RefColumn()` returns NULL, because the property has no column attached. The physical table says
  why — `sys.columns` for the Land schema's `parcel` table holds `prÃ¶vince`, the UTF-8 bytes
  `C3 B6` for `ö` stored as two Latin-1 characters. `CREATE TABLE` sends a bare (non-`N'`) quoted
  identifier, so the creating run's statement went through the same locale conversion as fix 8's
  literals, and the property name no longer matches the column. Dropping the datastore and re-running
  gives `FdoInsertTest` **OK (14)**.

  Two traps when reproducing this. `datastore=<name>` on the command line does **not** move the suite
  to a fresh datastore — an earlier round of these measurements was misled by exactly that, and
  reported the failure as "reproducible on a fresh datastore" when it was not. Drop it instead
  (`ALTER DATABASE fdo_root SET SINGLE_USER WITH ROLLBACK IMMEDIATE; DROP DATABASE fdo_root;`), or
  recreate the fixture. This is the same operational note as the collation change above: state
  written by an older build has to go.

- **`SqlServerFdoApplySchemaTest::TestSchema` fails a master-file comparison on a case-sensitive
  instance — open.** Once the collation is corrected the schema operations under test succeed and what
  is left is the serialized schema differing from its master:

  ```
  Output file ..._apply_schema_test2_LPhF.xml differs from expected output file
  ..._apply_schema_test2_master.txt
  ```

  The difference is small and precise — one hunk, 16 lines **added** and none removed. The generated
  schema carries a class the master does not: `aCxdATA`, with properties `Seq`, `ClassName` and
  `SchemaName`. `aCxdATA` is one of the case-mixed names the case-sensitivity test introduces, which
  suggests the master was cut against an instance where that class could not be created at all — a
  case-insensitive one, where the apply fails as described above — rather than against a correctly
  configured server. Whether the answer is to re-cut the master or to change the provider is not yet
  decided. This only became visible once the collation was corrected, because before that the apply
  failed earlier and the comparison was never reached.

- **The datastore-enumerating tests assume a private server.** The suite names its datastores
  `fdo_<account>` (`fdo_root` in these containers, `fdo_user` on the Windows build machine) and a
  few fixtures assert on *exactly* the set of databases they created:
  `SqlServerFdoDatastoreTest::Cmd_ListDatastores` and `::ListDataStores_LimitedPrivilegeUser`
  (`4 == count`) both fail if the instance also holds another account's `fdo_*` datastores, and
  `::Cmd_CreateNoMeta` fails if an earlier run left a half-created table behind. The limited-user
  test also leaves a `fdolimitedprivilegeuser` login with a user mapping in its own
  `fdo_<account>_limiteduser` database, which makes the *other* account's run fail the same
  assertion. Point the suite at a dedicated instance, or clean up before a run — drop the `fdo_*`
  datastores and `DROP USER fdolimitedprivilegeuser` inside each `*_limiteduser` database.
- **`DataTypeTests`' geometry roundtrip** passes now (fix 3), but no geography/`geography`-typed
  roundtrip has been exercised.
