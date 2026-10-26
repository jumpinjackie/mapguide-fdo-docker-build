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

Eight new `CMakeLists.txt`, modelled on the ODBC and PostGIS providers:

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

The `develop_thin` images install it, so a build container made by `build_thin.sh` needs nothing else:
`templates/distros/ubuntu/cmd_prepare_fdo_develop_ubuntu22.txt` and
`templates/distros/generic/cmd_prepare_fdo_develop.txt` add the Microsoft package repository and
`msodbcsql18`. **A container started before that change, or from an older image, does not have it** —
and the failure is not self-evident: the whole suite fails from its first fixture with
`RDBMS: No current open database.` (see [fix 19](#19-a-failed-connect-lost-the-driver-managers-diagnostic--connectc)).
Check with `ls /opt/microsoft/msodbcsql18/lib64/` and install it there, or rebuild the image:

```sh
# Ubuntu 22.04
wget -q https://packages.microsoft.com/keys/microsoft.asc -O- | gpg --dearmor > /etc/apt/trusted.gpg.d/microsoft.gpg
wget -q https://packages.microsoft.com/config/ubuntu/22.04/prod.list -O /etc/apt/sources.list.d/mssql-release.list
apt-get update
ACCEPT_EULA=Y apt-get install -y msodbcsql18

# Rocky Linux 8 (the `generic` image's base): the RHEL 8 packages are compatible
wget -q https://packages.microsoft.com/config/rhel/8/prod.repo -O /etc/yum.repos.d/mssql-release.repo
rpm --import https://packages.microsoft.com/keys/microsoft.asc
ACCEPT_EULA=Y yum install -y msodbcsql18
```

The installer acquires it too, so an installed deployment does not need the manual steps shown above. The
Ubuntu installer adds Microsoft's package repository and installs `msodbcsql18` (falling back to
`msodbcsql17`) when `--with-sqlserverspatial` or `--with-rdbms` selects the provider, and skips the
acquisition entirely if either driver is already installed; the `generic` installer only prints the
[download link](https://learn.microsoft.com/sql/connect/odbc/download-odbc-driver-for-sql-server),
because it bundles its FDO tree rather than installing packages.

That registers `[ODBC Driver 18 for SQL Server]` in `/etc/odbcinst.ini`. The provider looks the
driver up **by name** and asks the driver manager which Microsoft drivers are registered, preferring
the **newest** one, so with both installed it uses driver 18 and only falls back to 17 when 18 is not
there. `FDO_SQLSERVER_ODBC_DRIVER` overrides that choice — the name is the `[section]` in
`odbcinst.ini`, not a path:

```sh
FDO_SQLSERVER_ODBC_DRIVER="ODBC Driver 18 for SQL Server" ./UnitTestSQLServerSpatial ...
```

The same variable is honoured by the unit test's connection helper
(`Src/UnitTest/SQLServerSpatial/SqlServerConnectionUtil.cpp`), which makes the same choice, and on
Windows probed `SQLNCLI` instead.

### unixODBC: shared on ubuntu, static in `generic`

On ubuntu the provider links the distribution's `libodbc.so.2`. The `generic` image has no unixODBC
package, so `build_fdo_generic.sh` compiles unixODBC with `--disable-shared --enable-static
--sysconfdir=/etc` into `/usr/local`, and the provider links `libodbc.a` (and `libodbcinst.a`).

That still works with a driver installed: the driver manager is what `dlopen()`s the driver's shared
library, and a static driver manager can do that as well as a shared one. What a static-only unixODBC
does *not* provide is `libodbcinst.so.2`, and **the Microsoft driver links that one dynamically**
(`ldd libmsodbcsql-17.11.so.1.1` shows `libodbcinst.so.2 => /lib/x86_64-linux-gnu/libodbcinst.so.2` and
nothing else from unixODBC). The `msodbcsql18` (and `msodbcsql17`) package depends on the
distribution's `unixODBC` package, which supplies it, so installing the driver satisfies the requirement — the process then has
two copies of the odbcinst code, one linked into the provider and one loaded by the driver, and both
read `/etc/odbcinst.ini`. That is harmless, but it is worth knowing when a lookup behaves unexpectedly:
`ODBCSYSINI` moves the file for both.

`--sysconfdir=/etc` is what makes the static copy read `/etc` as well: without it, autoconf's default
(`<prefix>/etc`, i.e. `/usr/local/etc`) is compiled in as `SYSTEM_FILE_PATH`, and the provider silently
looks for `/usr/local/etc/odbcinst.ini` while the driver packages write `/etc/odbcinst.ini`. The
install hook only `touch`es the ini files, so pointing at `/etc` does not overwrite registrations that
are already there.

Because installing `unixODBC` also puts a `libodbc.so.2` on the system, `FindUnixODBC.cmake` would have
started preferring the shared driver manager for `generic` and silently dropped the static link. The
`generic` build therefore passes `--with-odbc-static`, which makes the module look for `libodbc.a`
explicitly; it is the same mechanism as the existing `--with-mysql-static` / `--with-libpq-static`.

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
| `Fdo/FdoRdbmsSqlServerConnection.cpp` | `GenConnectionStringParm` built the connection string around a `SQLNCLI` probe under `#ifdef _WIN32`; the Linux branch now takes the driver name from `FDO_SQLSERVER_ODBC_DRIVER`, or else the newest Microsoft ODBC Driver for SQL Server registered with the driver manager (18 over 17). |
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

One consequence worth knowing, because it is not a provider problem: a `LC_CTYPE` that differs from
the other categories makes `setlocale(LC_ALL, "")` return the **composite** name
(`LC_CTYPE=C.UTF-8;LC_NUMERIC=C;LC_TIME=C;…`, 166 characters in this image) rather than a single
locale name, so any code that copies that string into a fixed buffer has to size the buffer for it.
The SHP suite's `InsertTests::insert_with_locale` copied it into a 50-byte stack buffer and ASan
aborted the whole run with a `stack-buffer-overflow`; it now allocates the buffer from the string's
own length. Nothing else in the tree reads that return value.

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
their maps are load-bearing, so they cannot be deleted either. The ODBC comparison was never completed
— that was written before the ODBC provider had a Linux suite, and it has two now
(`OdbcSqlServerTests` `OK (87)` and `OdbcAccessTests` `OK (35)`, see
[odbc-linux-support.md](odbc-linux-support.md)), so `OdbcStringMap` can be checked the same way. That
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

**11. The unit tests were built without `SQL_SERVER_XPLAT`**

`SqlServerConnectTests::do_rdbi_connect` selects SQL Server authentication (`Uid`/`Pwd`) over
`Trusted_Connection=yes` under `SQL_SERVER_XPLAT`, and the Windows project defines that macro for every
configuration — `UnitTestSQLServerSpatial.vcxproj` carries `WIN32;SQL_SERVER_XPLAT;...` in all four. No
CMake file defined it, so this build compiled the `#else` branch and asked SQL Server for integrated
Windows authentication, which it cannot do:

```
ConnectTests.cpp:125:Assertion
Test name: SqlServerConnectTests::connect
assertion failed
- Expression: RDBI_SUCCESS == do_rdbi_connect (rdbi_context, id)
```

`ConnectTests::connect` and `::info` failed on every run (`Run: 4   Failure total: 2`). The rest of the
suite was unaffected because `SqlServerConnectionUtil` — the helper the other tests connect through —
branches on whether the init file supplied a username instead of on this macro, which is why the
failure looked like a provider defect when it was a build omission.

The definition belongs on **`SQLServerSpatialUnitTests`** (`UnitTest/SQLServerSpatial/CMakeLists.txt`),
not on `UnitTestSQLServerSpatial`: those sources are compiled into that static library and the
executable only links it, so a definition on the executable never reaches them — the first attempt here
did exactly that and changed nothing. `ConnectTests` is `OK (4)` now, and `::info` prints the server's
real vendor information (`ODBC version 4, precision(0,38), scale(-84,127), string(1,8000)`).

**12. A test file's non-ASCII literals were destroyed by an editing tool**

`SqlServerFdoUpdateTest.cpp` is Windows-1252 upstream. An editing pass during this port read it as
UTF-8, replaced the undecodable `ä` and `ö` bytes with U+FFFD (EF BF BD), and wrote it back — invisible
to anything that renders text, and unflagged by `file`, because the result is valid UTF-8. The test
then asked for a class named `L<U+FFFD>nd:Parcel` while the datastore held `Länd`, so
`testDefect810181` failed with

```
Class 'Lï¿½nd:Parcel' not found
```

The catalog was right and the test was wrong: `f_classdefinition.schemaname` really did hold
`L`+`C3 A4`+`nd`. The four literals now use `\u00E4`/`\u00F6` escapes, so the source is pure ASCII and
cannot be damaged again. A byte-level scan found no other occurrence — 0 in the change set's 42 files,
and the only four non-ASCII data files are intact masters whose tests pass.

Two traps this cost a cycle each: in a UTF-8 locale `grep -P '\xef\xbf\xbd'` reports **0** because it
matches the *characters* `ï¿½` rather than the U+FFFD bytes, so only a byte-level check settles it; and
`file` reporting "UTF-8 text" says nothing about whether the text is *right*. `FdoUpdateTest` went
from 2 failures to 1.

The same trap caught a later edit of `SqlServerFdoSqlCmdTest.cpp`, which had one non-ASCII byte — the
`ö` of `SQLCMD_8BIT_TABLE_NAME` (`L"Fd"`+`ö`+`L"SqlTest"`) — and a tool that rewrites the whole file
turns that byte into U+FFFD, because the file is Windows-1252 while the tool reads UTF-8 and nothing
warns. It left the name self-consistent (the same macro builds both the `create` and the `drop`) and
still broke the table's DDL, so the literal now uses a `\u00F6` escape like the four above and the file
is pure ASCII. A byte-level scan of the whole change set afterwards found that one occurrence and no
other, which is the check to re-run after any bulk edit of these test files.

**13. `decimal(p,0)` columns in the RDBI's 5–10 digit band read back one row out of step — `define.c`**

`desc_slct.c` maps `SQL_DECIMAL`/`SQL_NUMERIC` with `scale == 0` to `RDBI_SHORT` below five digits,
`RDBI_LONG` from five to ten, and `RDBI_DOUBLE` above ten, and it sizes the middle band's result buffer
with `sizeof(long)` — **8 bytes on LP64**. `get_o_t_s.c` binds `SQL_C_LONG` for `RDBI_LONG`, which is a
4-byte C type on every platform. unixODBC takes a column-wise array's element stride from the C type
rather than from the `BufferLength` it is handed (that number is the RDBI layer's `binary_size`), so the
driver wrote 4-byte elements at a 4-byte stride into a buffer the RDBI layer allocated and read at an
8-byte stride. Every row from the second on read half of its own value and half of its neighbour's.

Being a *read* defect is what made it look like something else. `FdoUpdateTest`'s
`UpdateMultiIdFeatureClass` asserts `Value == 5000000` on a `value decimal(8,0)` column and failed for
PIN 4 alone, but the physical row was correct the whole time —

```
pin |value  |revisionnumber|# employees
1   |5000000|0.0           |200
4   |5000000|1.0           |250
```

— because the parcel `UPDATE` this test issues for PIN 4 is byte-for-byte the one it issues for PIN 2
(`set revisionnumber = revisionnumber+1, "# employees"=? where "prövince" =? and "pin" =?`).
Instrumenting the read-back loop showed what the five-row result actually delivered:

```
pin=[1] val_i=5000000 val_d=21474836485000000 val_s=[5000000]   # own low word + PIN 2's
pin=[2] val_i=5000000 val_d=21474836485000000 val_s=[5000000]   # own low word + PIN 3's
pin=[3] val_i=5000000 val_d=5000000            val_s=[5000000]   # PIN 5's low word + unwritten tail
pin=[4] val_i=0       val_d=0                  val_s=[0]         # unwritten tail
```

`5000000 + (5000000 << 32)` is exactly two adjacent 4-byte values read as one 8-byte one, and the last
two rows read past the 20 bytes the driver had written. The `Value = 0` the earlier session recorded
belonged to the fourth *row*, not to a fourth-PIN update — which is also why removing PIN 4's owned-object
update, or reordering the inserts, changed nothing.

The fix is in `define.c` — the result-column path, where the RDBI layer's buffer width is known:

```c
	odbcdr_get_o_t_s( context, datatype, size, &odbcdr_datatype, &odbcdr_size );

	if ( datatype == RDBI_LONG && size > (int) sizeof(SQLINTEGER) )
		odbcdr_datatype = SQL_C_SBIGINT;
```

It deliberately does **not** go in `get_o_t_s.c`, which `define.c` and `bind.c` share. A bind's C type
has to match the *caller's* buffer, and one caller disagrees with the RDBI layer about how wide
`RDBI_LONG` is: `SqlServerGeometryTests::do_insert_geometry` binds `RDBI_LONG, sizeof(long)` against an
`FdoInt32 *featId`, so widening the bind read 4 bytes of adjacent stack and the insert failed with
`Numeric value out of range`. Result columns have no such caller — the RDBI layer supplies the address
*and* the stride — so only they need the wider C type. A define that really does pass 4 bytes still gets
`SQL_C_LONG`, which covers the `DataTypeTests` `NUMERIC`/`DECIMAL`/`DEC` (6,0) round trips; the
`SelectTests` `phone` and `odbcdr_get_gen_id` defines pass an `int64_t`/`sizeof(long)` and are repaired
by the wider type rather than broken by it (`get_gen_id` had only 4 of its 8 bytes written before). On
Windows `sizeof(long) == 4`, so the condition is false and this compiles to the same `SQL_C_LONG`.

`FdoUpdateTest` is `OK (12)` now, where it was `Run: 12   Failure total: 1`; `SqlServerGeometryTests`
stays `OK (4)`, `DataTypeTests` `OK (30)` and `SelectTests` `OK (5)`. The same `RDBI_LONG` band was
wrong in the shared driver the **ODBC** provider compiles and is fixed there too — see
[Relationship to the sibling ODBC driver](#relationship-to-the-sibling-odbc-driver).

**14. The SQL Server profile's expected schema still encoded a case-insensitive instance — `LogicalPhysicalBender.xslt`**

`FdoApplySchemaTest::TestSchema` compares the generated logical/physical schema against the shared
`apply_schema_test*_master.txt` after both sides have been through a stylesheet:
`LogicalPhysicalBender.xslt` bends the master into the profile's *expected* output, and
`LogicalPhysicalFormatter.xslt` formats the generated schema into the thing it is compared with. Four
rules in the bender encode the fixture this suite used to run against — a SQL Server with no explicit
collation, and therefore the image's case-*in*sensitive default — and each removes from the expected
output something a case-sensitive instance legitimately creates. Both sides then disagree by
construction:

| Bender rule | What it removes | Change |
| --- | --- | --- |
| `lp:class[@name='aCxdATA' and (SqlServer or SQLServerSpatial)]`, a deletion | the `aCxdATA` class, which cannot be created on a case-insensitive server because `AcXData` is already there | narrowed to `SqlServer` |
| `lp:property[@name='GEOMETRY' and hybrid 0 and (SqlServer or SQLServerSpatial)]`, a deletion | the case-variant `GEOMETRY` property of `Transformer` | narrowed to `SqlServer` |
| `lp:column[(SqlServer or SQLServerSpatial) and @name='GEOMETRY1' and local-name(..)='table']`, plus the matching exclusion in the `lp:column[@dataType]` rule below it | the disambiguated `GEOMETRY1` column | narrowed to `SqlServer` |
| the `ancestor::lp:class` fallbacks in `bendTableName` and `bendColumnName` (a name with no explicit rule is taken from its class or property) | maps the case-variant's disambiguated names back onto names that cannot both exist: `ACXDATA1` → `acxdata`, `GEOMETRY1` → `geometry` | `ACXDATA1` → `acxdata1` and `GEOMETRY1` → `geometry1` added ahead of them |

The first failure was the one hunk the class deletion predicts — 16 lines added to the `Acad` schema,
nothing removed:

```
+<class xsi:type="Class" name="aCxdATA" description="Xdata" baseClass="" abstract="False" tableName="dbo.acxdata1" tblCreator="False" fixedTbl="False">
+<property xsi:type="Data" name="ClassName" .../>
+<property xsi:type="Data" name="SchemaName" .../>
+<property xsi:type="Data" name="Seq" description="seq" dataType="int32" .../>
+</class>
```

That one hunk is not the whole story, though: `CheckOutput` asserts per file, so only the *first*
mismatching master is reported and clearing test2 simply exposed a second, previously masked one in
test3 — `Transformer`'s two geometry properties, where the expected output had a single `Geometry`
property with `columnName="geometry"` and the generated one has `GEOMETRY`/`geometry` *and*
`Geometry`/`geometry1`. Same cause, one level down. MySQL's and PostGIS's profiles never had any of the
four rules and pass against the same masters, which is the shape the SQL Server profile now produces:
`FdoApplySchemaTest` is `OK (5)` where it was `Run: 5   Failure total: 1`, with MySQL `OK (6)` and
PostGIS `OK (5)` unchanged.

The Windows harness reaches the same rules through the same `SQLServerSpatial` provider name, so its SQL
Server fixture needs the case-sensitive collation too — which [Known issues](#known-issues) already
requires of any instance this suite runs against (a case-insensitive one cannot hold two class names
that differ only in case).

**15. The extended coordinate system file is looked up under a name that does not exist — `Mgr.cpp`**

`FdoSmPhSqsMgr::GetExtendedCsysFilename()` asked for `GetHomeDir() + "extendedCoordSys.txt"`, while the
file ships and installs as **`ExtendedCoordSys.txt`**. The two names differ only in the case of the
first letter, which is why this survived: Windows finds the file either way. On Linux the `fopen` fails,
and the loader is written to treat a missing file as ordinary —
`// Not an error if file not found. No extended coordinate systems in this case.` — so **nothing is
reported** and the list is simply empty.

That silence is what made this look like an unimplemented feature. SQL Server's own catalogue
(`sys.spatial_reference_systems`) carries only geodetic systems; everything else is expected to come
from this file, so with the list empty every spatial context that names one of those coordinate systems
fails the provider's strict match:

```
(SpatialContext.cpp: 644) Error creating spatial context California, coordinate system CA-I is not in current datastore.
```

Six of the eight failures still open at the time were this one defect: `FdoSelectTest` (24 tests),
`FdoSpatialContextTest::testAdjustExtents` and `::testDottedSpatialContext`, and
`SqlServerSchemaMgrTests::testGenGeom` and `::testSpatialContextsGeog` all passed once the file was
found. The name is now spelled as it is installed, and the comment in `Owner.h` that documented the old
spelling is corrected with it.

The file the tests must read is **not** the one the provider ships: `Src/UnitTest/ExtendedCoordSys.txt`
(337 lines) defines the fixture's own systems — `CA-I` with `PROJCS["California test",...]`, which is
what the expected-output files contain — while the shipped `com/ExtendedCoordSys.txt` (2 784 lines) is
the real-world catalogue, which lists `26741 CA-I` with no WKT because that SRID is not in SQL Server's
own geodetic catalogue. Without the fixture the suite reports five failures, the decisive one being

```
(SchemaMgr/Sm/Lp/SpatialContext.cpp: 657) Error creating spatial context Mentor by WKT,
coordinate system catalog does not contain entry for WKT 'PROJCS["Quebec test",...]'
```

with `testMeta`, `testNoMeta`, `testGenGeom`, `testSpatialContextsGeog` and `testSynonyms` following
from it.

Only SQL Server has this requirement; the MySQL and PostGIS providers also read `com`, but everything
they read there (the MetaSchema `.sql` scripts) is identical in the source tree, the build tree and the
install, so whichever copy of the provider the loader picks, the content is the same. The catalogue is
the one file whose content is *test-specific*, and the fix is to put it where the convention already
looks rather than to give the provider a way to be pointed elsewhere:

- `getComDir()` resolves `com` from the directory of the provider library that is executing — the
  `GetModuleFileNameW(hModule)` arrangement the Windows `DllMain` uses, expressed on Linux by scanning
  the link map for the provider's own name. It reads no environment variable, exactly like the MySQL,
  PostGIS and ODBC providers.
- The SQL Server unit-test `CMakeLists.txt` stages the test's `ExtendedCoordSys.txt` into the `com`
  directory **beside the provider in the build tree**, over the copy of the shipped catalogue the
  provider's own `CMakeLists.txt` puts there. This is the Linux counterpart of the Windows post-build
  step, which copies the test's catalogue into `$(OutDir)\com` next to the copy of the provider DLL the
  suite loads. The installed catalogue is never touched: `install` takes it from the source tree.
- Because the suite must therefore run against the **build-tree** provider, `run_fdo_tests.sh` clears
  `LD_LIBRARY_PATH` for that one run. An inherited `LD_LIBRARY_PATH` pointing at `/usr/local/fdo-4.2.0`
  would load the installed provider instead (its `DT_NEEDED` copy is mapped first, and the link-map scan
  takes the first match), which finds the real catalogue and brings the five failures back. The binary's
  `RUNPATH` already resolves every dependency, so nothing else needs the variable; see
  [Validation](#validation).

**16. Expected-output files with Windows line endings compared unequal on Linux — `UnitTestUtil.cpp`**

Several masters are checked into SVN with **CRLF** and only some of them carry the `svn:eol-style`
property (`apply_schema_test2_master.txt` has `native`; `synonyms1_SQLServerSpatial_master.xml` has
none), so which ending a file has depends on its history rather than on its content. `CompareFiles`
opened both files with `fopen(..., "r")` and compared them line by line with `strcmp` — and reading a
file in text mode strips the CR **on Windows but not on Linux**. On Windows the two files compared
equal; on Linux every line differed:

```
synonyms1_SQLServerSpatial_master.xml SQLServerSpatial_2050750910_synonyms1.xml differ: char 40, line 1
```

with the two files byte-identical apart from 1 030 CRs (34 181 vs 33 151 bytes, and exactly 1 030 of
them). `SqlServerSchemaMgrTests::testSynonyms` was the only failure this produced — the other CRLF
masters are either unused on Linux or have the property. `CompareFiles` now normalises the terminator
each line arrives with, so a file compares equal whether it has CRLF or LF. (The first attempt at this
looked at the last character of the line, which `fgets` has already set to `\n` — the CR is the
*second-to-last* character of a Windows line.)

**17. The comparison sort order depended on the XSLT engine — `UnitTestUtil.cpp`**

`Config2SortedFile` sorts an exported document before it is compared with its master, "so that the
Spatial Contexts, Schemas and Schema Mappings are always in the same order". The sort key for spatial
contexts was a bare `<xsl:sort select="@gml:id" />`, with no `lang` or `case-order`, so the order came
from **the XSLT processor's default collation** — and that differs by implementation. libxslt compares
code points, where `'S'` (0x53) sorts before `'c'` (0x63), so `South` precedes `sc_1`; MSXML's is
case-insensitive, so `sc_1` precedes `South`. The masters were cut on Windows, so `testMeta` and
`testNoMeta` failed on Linux with a diff that moved `sc_1`/`sc_2` after `South`/`South Duplicate` and
changed nothing else — 20 lines moved, none added or removed.

The key is now spelled out as `translate(@gml:id, 'A…Z', 'a…z')`, which both engines evaluate
identically. Case-folding reproduces the order in the existing masters (checked entry by entry), so the
masters do not change and the Windows suite keeps producing the same order.

Only that one key is folded. Folding the `@name` keys as well looked like the same fix, but it
**reordered** `TIME_COLUMN` against `TIMESTAMP_COLUMN` (`'_'` sorts before `'s'` only after folding)
and broke `MySqlSchemaMgrTests::testGenDefault` and `PostGisSchemaMgrTests::testGenDefault`, whose
masters already agree with the code-point order. Those sorts are therefore left alone, and the reason is
recorded beside them.

**18. `SQLFetch` wrote a row count over the provider's own stack — `fetch.c` (the Release-only crash)**

A Release (`-O3 -DNDEBUG`) build of the suite died in `odbcdr_fetch2` before the second fixture could
run, and the Debug build of the same source was fine. The backtrace is in
[Known issues](#known-issues); the cause is a single local's type:

```c
int rows_in_last_fetch;
...
SQLSetStmtAttr( c->hStmt, SQL_ATTR_ROWS_FETCHED_PTR, &rows_in_last_fetch, SQL_IS_POINTER);
```

`SQL_ATTR_ROWS_FETCHED_PTR` takes a **`SQLULEN`**, and the driver writes that much — 8 bytes on LP64 —
through the pointer it was given. Declaring the target as a 4-byte `int` means `SQLFetch` writes 8 bytes
into a 4-byte local and overwrites the 4 bytes that follow it. Which local follows is the compiler's
choice, and in the Release frame it is `c`, the cursor pointer: `0x5603f88f1d00` becomes
`0x560300000000`, the low half replaced by the upper half of the row count, and the next dereference
(`c->hStmt`, at `fetch.c:207`) faults. Debug builds the frame differently and survives, which is why
this only ever appeared in Release — and why running the suite in both configurations is worth doing.

A hardware watchpoint on `&c` confirmed it: the write came from inside `SQLFetch`, through
libmsodbcsql, with no provider frame in between. `rows_in_last_fetch` is now a `SQLULEN`, and the
handful of places that pass it to an `int` parameter or print it are cast, so the narrowing is explicit.

The same declaration is in the **shared** `Src/ODBCDriver/fetch.c` the ODBC provider compiles, so that
provider has the defect too — see
[Relationship to the sibling ODBC driver](#relationship-to-the-sibling-odbc-driver).

**19. A failed connect lost the driver manager's diagnostic — `connect.c`**

Without the ODBC driver installed, every fixture in the suite failed from its first test, and the only
thing any of them reported was

```
RDBMS: No current open database.
```

which says nothing about a driver. The cause is in the provider's connect path: when
`SQLDriverConnect` returns `SQL_ERROR`, `odbcdr_connect` calls `DumpError2(context, SQL_HANDLE_DBC,
hDbc)` to capture `SQLGetDiagRec`'s message, and on Linux that function was an **empty stub**:

```c
#ifndef _WIN32
static void DumpError2 (...)  { }
static void DumpError2W(...)  { }
#else
    ...the real implementations, using SQLGetDiagRec/SQLGetDiagRecW...
#endif
```

So nothing was recorded, and `odbcdr_get_msg` fell through to its "no message" case
(`FDORDBMS_506`). The sibling driver the ODBC provider compiles (`Src/ODBCDriver/connect.c`) has no
such guard — its implementations run on Linux — so this was a regression introduced by the copy this
port started from, not a platform limitation.

The narrow implementation now mirrors the Windows one, storing the driver manager's text in
`odbcdr_last_err_msg`. The same two cases now read:

| Situation | Message |
| --- | --- |
| no driver registered at all | `RDBMS: [unixODBC][Driver Manager]Can't open lib 'ODBC Driver 18 for SQL Server' : file not found` |
| a name that has no entry in `odbcinst.ini` | `RDBMS: [unixODBC][Driver Manager]Can't open lib 'ODBC Driver 99 for SQL Server' : file not found` |

Both name the driver the provider looked for, which is what a user needs to know. `DumpError2W` stays a
stub on Linux, with a comment: the Linux driver runs in *narrow* mode (`rdbi_init.c` turns
`odbcdr_UseUnicode` off because the driver speaks UTF-16 while `wchar_t` is UTF-32), so it is
unreachable, and the Windows body cannot be reused verbatim because `SQLWCHAR` is a 16-bit code unit
there but `unsigned short` here — a real implementation would have to convert to `wchar_t`.

**20. Every range check constraint leaked a reference to its min and max value — `SchemaMgr/Ph/Table.cpp`**

`FdoSmPhSqsTable::GetCkeyClause` builds the `CHECK` clause that `CreateCkeysFromFdo` sends back to the
server, and it tested the constraint's two values with the counted getters themselves:

```cpp
if ( c->GetMinValue() )
{
    ...
    FdoPtr<FdoDataValue>  val = c->GetMinValue();
```

`FdoPropertyValueConstraintRange::GetMinValue()` returns `FDO_SAFE_ADDREF(m_minValue)`, so the guard's
reference is lost the moment the condition is evaluated; the value is then fetched a second time into an
`FdoPtr`. Each range constraint therefore retired one reference short, and the leftover reference kept
the value alive forever — a *direct* record, because the constraint that owned the other reference was
freed normally. `GetMaxValue()` had the same defect, and the same two lines also leaked the values the
*test* supplied (`AddRangeProperty`'s `FdoDataValue::Create`) and the ones the constraint parser built
(`ParseConstraint`), since those become the constraint's min/max whenever no type conversion is needed.

This is the SQL-Server-only physical layer, which is why the sibling providers never showed it: the
PostGIS equivalent (`Providers/GenericRdbms/Src/PostGis/SchemaMgr/Ph/Table.cpp`) already wraps the
getter in an `FdoPtr`. Both values are now fetched once, into an `FdoPtr`, and tested through it.

Measured on `FdoConstraintsTest` alone — the suite that exercises every constraint type: **62 direct
records before, 0 after**, and no new records of either kind.

**21. The last fetch of a query stranded the geometries of the previous, larger batch — `ODBCDriver/geom.c`**

The geometry arrays are presized to the fetch's row count and then shrunk to the rows a batch actually
returned (`odbcdr_fetch2` calls `odbcdr_geom_setNumRows(context, c, (int)rows_in_last_fetch)`), and two
separate loops are written against that shrunk count: the conversion loop (`j < numRows_I`) and the
release loop in `col_list_free_S` (`j < column->geom_list.size`). Both are correct only while the last
batch is at least as large as the one before it. `FdoConnectTest::query` reads a 192-row table in
100-row batches, so the final batch is 92 rows: slots 92..99 kept the `FdoGeometry` objects the first
batch had put there, nothing released them, and the free loop never looked at them — 8 leaked
`FdoFgfLineString` objects (640 B) per query.

`col_list_setNumRows_S` now takes a `release_geoms` flag (TRUE for `defined_geometries`, FALSE for
`bound_geometries`, which never hold FDO geometries) and, when it is about to drop slots, releases each
`l_address[j]` above the new size and NULLs it. `l_address` is sized for the largest fetch and is never
reallocated, so those slots are always in bounds. `FdoConnectTest` went from **1 direct record (640 B in
8 objects) to 0**.

**22. Three teardown leaks in the shared and test code**

None of these are in the SQL Server provider's own logic; two are in code every GenericRdbms provider
compiles, so they were found here and fixed for all of them:

- `Rdbi/tran_sp.c` allocated a copy of the save-point name on entry and freed it only when
  `status != RDBI_SUCCESS` at `the_exit`, so *every successful* `SAVEPOINT`/`ROLLBACK TO`/`RELEASE`
  leaked it (4 records, 21 B, from `FdoTransactionTest`'s save-point tests). It is now freed
  unconditionally; the two `rdbi_msg_set_S` calls that use it copy the text.
- `UnitTest/Common/ReaderTest.cpp` — `TestExceptionalCase` asserts on the message of the
  `FdoCommandException` that each failing `Get*()` throws and never releases the exception itself (5
  records, 200 B). Each of the eleven catch blocks now holds the caught exception in an `FdoPtr`
  (`expHolder`), which also releases it when a `CPPUNIT_ASSERT` in the block throws.
- `UnitTest/SQLServerSpatial/SqlServerFdoSelectTest.cpp` — `TestSpatialGeogValidSpatialOperators`
  opened a `StaticConnection` and neither closed the `FdoIConnection` nor `delete`d it, unlike its
  sibling `TestSpatialGeog` immediately above it (1 record, 48 B). It now does both on the normal path
  and in the `catch (...)` that already swallowed its failures.

**23. A clockwise geography filter selected the complement of its area — the filter and bind paths**

SQL Server's `geography` type does not treat a polygon's rings as a container with an inside: it reads
the ring **direction** as which side of the ring is the interior, so a loop wound the other way round
describes everything *except* the area it encloses. The provider passed the caller's literal through
unchanged, so a box selection against a geographic feature class selected the whole table:

```
POLYGON((-87.71986 43.75843, -87.71978 43.75843, -87.71978 43.75839, -87.71986 43.75839, ...))
                                               ^ clockwise: 510 065 621 710 968 m², EnvelopeAngle 180°
```

Every stage below the caller was already correct — `BuildPolygon` writes rings in arrival order with
ring 0 as the exterior ring — so the winding the client sent is the winding SQL Server saw. What was
missing is the consumer for a capability the provider already advertises: `FdoSmPhSqsDbObject::
GetPolygonVertexOrderStrictness` returns true for a `geography` column, and `FdoSpatialUtility::
FixPolygonVertexOrder` exists to apply a rule, but there was no product call site for either (only the
unit tests called it), while the renderer's own reorientation in `RSMgFeatureReader` is driven by the
stylizer, not by FDO.

`FdoRdbmsSchemaUtil::FixGeometryVertexOrder` now reads the class's advertised rule and strictness for
the property and reorients a literal through `FdoSpatialUtility::FixPolygonVertexOrder` when — and
only when — the rule is declared strict, so planar `geometry` columns, SHP (which advertises `CW`) and
SDF/ODBC (which advertise `None`) are untouched, and a deliberately large geography polygon is still
expressible through a provider that does not declare strictness. It is applied on both sides:
`FdoRdbmsSqlServerFilterProcessor` and `FdoRdbmsSqlServerSqlBuilder` reorient the filter literal, and
the four bind sites that write geometry (`FdoRdbmsSimpleInsertCommand`, `FdoRdbmsSimpleUpdateCommand`,
and the insert/update PVC handlers) reorient stored values, where a clockwise ring was otherwise
accepted and silently stored as the complement. The reoriented values are owned by
`FdoRdbmsGeometryValueOwner` for as long as the parameters that point at them are bound.

`TestSpatialGeogWinding` is the fixture for it: the same box wound both ways against a `geography`
column, which must select the same two features. It fails without the change
(`cwNames->GetCount() == ccwNames->GetCount()`) and passes with it. The suite had no coverage for this
because `TestSpatialGeog` associates its geometry property named `Geog` with the **projected** spatial
context `projSC`, so that fixture never created a geography column at all.

In MapGuide this surfaces as `DB_LOG_BUFFER_FULL` on the persisted selection, because selecting the whole
table makes the selection blob larger than the session repository's log buffer — the error and its
troubleshooting are covered in [mapguide-db-log-buffer-full.md](./mapguide-db-log-buffer-full.md).

Validated in both configurations against the baseline distro, full suite, `initfiletest` against the
`mssql_cs` fixture:

| Run | Assertions | LeakSanitizer |
| --- | --- | --- |
| Release, before | `Run: 289  Failure total: 38` | — |
| Release, after | `Run: 290  Failure total: 38` | — |
| Debug, before | `Run: 289  Failure total: 38` | 10 direct / 1 459 indirect, 1 772 808 B |
| Debug, after | `Run: 290  Failure total: 38` | 11 direct / 1 096 indirect, 1 431 200 B |

The 38 names are identical in every run (`SqlServerFdoAdvancedSelectTest`'s `setUp` failing on a missing
`dbo.ind…` object is the first of them), so they are unrelated to this change: they are the stale
datastore this fixture had accumulated, and dropping the `fdo_*` databases turns the same tree green
(`OK (290)`, see [Test results](#test-results)). The direct-record count moves 10 → 11 purely as
run-to-run drift among the same record
families — `FdoCapabilityTest::Datastore` and `SqlServerFdoUpdateTest::testDefect810181` each swap one
record for the other between runs — and no record in either run has a frame in `FixGeometryVertexOrder`,
`FdoRdbmsGeometryValueOwner` or a geometry bind site. The reoriented literals are owned, so the indirect
graph shrinks by 341 KB rather than growing.

## Test results

**The port finished with the whole suite passing**: `Run: 288   Failure total: 0`, reported as
`OK (288)`. It got there in stages — `Failure total: 14` when the case-insensitive-instance and
out-parameter defects were still in, `8` after the first round of fixes, and `0` then:

| Fixed by | Tests it cleared |
| --- | --- |
| fix 11 `SQL_SERVER_XPLAT` | `SqlServerConnectTests::connect`, `::info` |
| fix 12 U+FFFD literals | `SqlServerFdoUpdateTest::testDefect810181` |
| fix 13 `RDBI_LONG` stride | `SqlServerFdoUpdateTest::UpdateMultiIdFeatureClass` |
| fix 14 bender expectations | `SqlServerFdoApplySchemaTest::TestSchema` |
| fix 15 extended csys file | `FdoSelectTest` (all 24, its count at the time — r8415 added a 25th), `testAdjustExtents`, `testDottedSpatialContext`; and with the fixture actually staged beside the provider, `testMeta`, `testNoMeta`, `testGenGeom`, `testSpatialContextsGeog` |
| fix 16 CRLF comparison | `testSynonyms` |
| fix 17 sort collation | `testMeta`, `testNoMeta` |
| the `sql_variant` test decoding its own payload | `TestInParamsStoreProcVariant` |

The eight failures that were open before this round were **not** one missing feature, which is what
they looked like: six were fix 15 (the provider silently loading an empty coordinate system catalogue),
one was fix 16 and one was fix 17. Nothing in the suite needed geography-typed support added — the
`testSpatialGeog` in that list is `FdoSelectTest`'s spatial-context helper, not a geography round trip.
The provider still has no general geography support (see [Known issues](#known-issues)), and nothing
exercised one at that point; fix 23's `TestSpatialGeogWinding` is the first test that does.

Two hypotheses are ruled out rather than fixed. The expected-output and NLS data files under
`UnitTest/` are **not** corrupted — a byte-level scan of all 444 files found no U+FFFD, so the
master-file failures were content and ordering differences rather than encoding damage. And the
remaining failures were not caused by any of this port's earlier changes: fixes 13 and 18 were both
A/B tested by reverting them.

The suite was `OK (288)` in **both** configurations at that point, run through `run_fdo_tests.sh`
with an inherited `LD_LIBRARY_PATH` pointing at the install (which the runner clears for this suite,
see fix 15): the Debug run then reported 0 direct leak records (that log,
`artifacts/Debug/test-logs/SqlServerSpatial_unit_test_log.txt`, has since been overwritten by the
290-fixture run below), and Release (`artifacts/Release/rel_sqs_final.log`) is green with no change in
behaviour. The provider has no environment input for the catalogue — it read the one next to itself
before and does so now — and the suite only needed the staging step, not a variable.

**The suite is green at 290.** Re-run on 2026-10-26 against a recreated `mssql_cs` after dropping the
`fdo_*` datastores: `OK (290)`, `Failure total: 0`, 22m 39s
(`artifacts/Debug/test-logs/SqlServerSpatial_unit_test_log.txt`). That also settles what the 38
failures in the fix-23 runs were: `setUp` failures against the datastore, identical either side of
fix 23, and gone once the datastores are — including `spatial_or_attribute_query`, the one failure the
fixture kept when the winding test was run alone. The two additions since the 288-fixture run are
`SqlServerFdoSelectTest::TestExplicitPropertyListGeometryTypes` (r8415, 288 -> 289) and
`TestSpatialGeogWinding` (fix 23, 289 -> 290); the latter's own before/after is
`Run: 26   Failure total: 2` -> `Failure total: 1` in
`artifacts/Release/rel_sqs_winding_selectsuite_*.log`. The Release configuration has not been re-run
at 290 — its last green run is the 288 one above, and the 289/290 Release runs were taken on the stale
datastore — so `OK (290)` is recorded for Debug only.

The suites that compile the same RDBI and unit-test-harness code were re-run in both configurations and
are unchanged at their baseline figures: `UnitTestMySql` `OK (249)` and `UnitTestPostGis` `OK (140)`,
as is `UnitTest` (SHP) `OK (138)`.

Fixtures measured individually, Debug and Release unless noted: `FdoApplySchemaTest` OK (5),
`FdoUpdateTest` OK (12), `DataTypeTests` OK (30), `SelectTests` OK (5), `FdoSpatialContextTest` OK (6),
`SchemaMgrTests` OK (10), `FdoSelectTest` OK (26) and `GeometryTests` OK (4); `FdoSelectTest` grew from
24 to 26 with `TestExplicitPropertyListGeometryTypes` (r8415) and `TestSpatialGeogWinding` (fix 23).
The sibling suites that share
the unit-test harness are unchanged: `UnitTestMySql` `OK (249)` and `UnitTestPostGis` `OK (140)`, in
both configurations.

## Relationship to the sibling ODBC driver

`Providers/GenericRdbms/Src/SQLServerSpatial` is largely a copy of `Providers/GenericRdbms/Src/ODBC`,
so the same defects existed in both. The ODBC port (r8417) then fixed the shared driver the same way,
so only the `%s` hazard is still outstanding:

- `ODBCDriver/geom.c` declared `boundParmID` as `SQLSMALLINT` (2 bytes!) in `geom_convert_S` and
  `geom_convertToSqlServer_S` while passing `(SQLPOINTER*)&boundParmID` to `SQLParamData`, so on
  LP64 an 8-byte pointer was written into a 2-byte local — a stack smash with the same signature as
  fix 3 above. **Fixed** in the shared `Src/ODBCDriver` copy, exactly as in this provider: both
  declarations are `SQLPOINTER`.
- The `%s`-in-a-wide-format hazard (fix 5) is a trap for any file in either provider, and is the one
  item on this list that is still live in both copies.
- The `RDBI_LONG` stride mismatch (fix 13) was present verbatim in the *shared* `Src/ODBCDriver` (the
  ODBC provider compiles that directory, not a private copy): its `desc_slct.c` sizes the 5–10 digit
  `decimal`/`numeric` band `RDBI_LONG` by `sizeof(long)` while its `get_o_t_s.c` binds `SQL_C_LONG`,
  so its `define.c` needed the same promotion to `SQL_C_SBIGINT`. **Fixed** in r8417, together with
  its `desc_slct.c` sizing `RDBI_INT` by `sizeof(int)`. Unlike this provider's copy it is exercised:
  `OdbcSqlServerTests` is green in both configurations ([odbc-linux-support.md](odbc-linux-support.md)).
- `ODBCDriver/fetch.c` declared `rows_in_last_fetch` as an `int` and registered it with
  `SQL_ATTR_ROWS_FETCHED_PTR` (fix 18), so that provider had the Release-only stack overwrite too.
  **Fixed** in r8417 — it is a `SQLULEN` there now, and the ODBC suite runs in Release.

Two of the fixes are *not* provider-specific even though only this suite noticed them: `CompareFiles`
(fix 16) and the comparison sort key (fix 17) live in the GenericRdbms unit-test harness that MySQL and
PostGIS share, so they apply to those suites as well. Both were validated by re-running those suites —
green before and after — because the sort-key change in particular reorders output and could have
disturbed their masters.

## Validation

Run from the build area with the message catalogue in place. **Do not** set `LD_LIBRARY_PATH` to the
install for this suite:

```sh
cd /tmp/work/build_area/fdo/Providers/GenericRdbms/Src/UnitTest
export NLSPATH=/tmp/work/build_area/fdo/nls/linux/en_US/%N
export LC_CTYPE=C.UTF-8    # required; see fix 8. run_fdo_tests.sh defaults it
unset LD_LIBRARY_PATH      # required; see fix 15. The RUNPATH resolves every dependency
./UnitTestSQLServerSpatial initfiletest=<init file>                 # whole suite
./UnitTestSQLServerSpatial initfiletest=<init file> FdoSelectTest   # one fixture
```

The provider finds its own `com` directory with no environment input (fix 15), and the build stages the
test's catalogue beside the build-tree provider that `providers.xml` names. `LD_LIBRARY_PATH` is the one
thing that can break that: pointing it at `/usr/local/fdo-4.2.0/lib64` loads the *installed* provider,
whose `com` holds the real catalogue, and the five spatial-context fixtures then fail with *coordinate
system … is not in current datastore*. `run_fdo_tests.sh --with-sqlserver-init` clears it for you.

That clearing is specific to this suite, and it has to be: the ODBC, PostGIS and MySQL suites need the
opposite, because they load their provider **by name** through the FDO registry. On Linux the registry
is `providers.xml` beside `libFDO`, which a build tree does not have, so FDO falls back to the
installed `/usr/local/fdo-4.2.0/lib64/providers.xml`, whose entries are bare names
(`libMySQLProvider.so`) that `dlopen()` resolves through `LD_LIBRARY_PATH`. The runner therefore
exports that path before the first RDBMS suite and overrides it to empty for this one; when running by
hand, set it for those suites and unset it for this one.

The staged catalogue is written by CMake when the build is **configured**, not when it is compiled, so a
build tree that predates that rule, or that has only been built, will not have it — re-run `cmake .` (or
any build step, which reconfigures when the CMake files changed) before running the suite. Check that
`Providers/GenericRdbms/Src/SQLServerSpatial/com/ExtendedCoordSys.txt` is the **337-line** fixture and not
the 2 784-line shipped catalogue: `cmake --build . --target install` does not disturb it, but a
reconfigure that ran before the staging rule did would leave the shipped one there.
`testSynonyms` depends on the same data, which is not obvious from its name: the export it compares
contains the datastore's spatial contexts, so a missing catalogue shows up there too.

The other thing the suite needs to be current is the **built** provider. The suite resolves it through
`providers.xml`, which names the library in the build tree, so a provider edit takes effect after
`cmake --build . --target UnitTestSQLServerSpatial` (or `install`, which builds it too); running the old
binary reproduces the old behaviour rather than erroring.

A Debug build is ASan/LSan-instrumented, so a green run still exits non-zero — judge it by
`OK (<n>)` in the output, not by the exit code. The current run (`OK (290)`, 2026-10-26) reports
**3 direct leak records**, 292 B in total, all of them allocating in test code rather than in the
provider:

| Record | Site | Bytes |
| --- | --- | --- |
| `FdoArrayHelper::AllocMore` | `FdoFgfGeometryFactory::CreateLinearRing` in `SqlServerFdoSelectTest::TestSpatialGeog` (`SqlServerFdoSelectTest.cpp:284`) | 188 |
| `FdoIdentifier::Create` | `SqlServerFdoSelectTest::TestExplicitPropertyListGeometryTypes` (`:995`) | 64 |
| `FdoSchemaException::Create` | the negative `DropDatastore` path in `FdoSchemaTest::OverrideTablesWithOddAsciiChars` | 40 |

The 288-fixture run this section used to quote reported none, so treat the direct count as moved
rather than as a provider defect: no record has a provider frame, and each is a counted reference a
test drops.

Beyond those, the run leaves 1,543 indirect records (1,889,844 B in 21,259 allocations). The largest
family is now the extended coordinate system catalogue — `FdoSmPhSqsOwner::LoadExtendedCoordinateSystems()`
alone accounts for 618 KB in 14 records, and it is new only because fix 15 makes the file load at all
(when the name did not resolve, nothing was read and nothing could leak). After it come the
schema-document graphs every RDBMS suite carries: `FdoStringP::AllocateBuffer` (538 KB in 475
records), `FdoDictionaryElement::Create` (168 KB in 102) and the coordinate-system map nodes (141 KB
in 10). The 288-fixture run reported 1,889,108 B in 1,539 indirect records; it predates the Microsoft
ODBC Driver move (r8420/r8423), so read the families, not the totals. Compare record *signatures* as
well as totals when you touch this area — the before/after comparison for fixes 20–22 removed 68
signatures and added none, and a fix that replaces one record with another of the same size has not
fixed anything.

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

The suite was green at that point. Earlier in the port it was not, and the split below is what the
measurements looked like while `FdoApplySchemaTest` was still failing — it is kept because it records
why the case-sensitive fixture is required. Every fixture listed passes on **both** instances in those
runs; the collation's remaining effect is on `FdoApplySchemaTest`'s *failure mode*, which no longer
arises:

| Fixture | case-insensitive fixture | case-sensitive instance |
|---|---|---|
| `FdoDatastoreTest` | OK (7) | OK (7) |
| `FdoConstraintsTest` | OK (16) | OK (16) |
| `DataTypeTests` | OK (30) | OK (30) |
| `SelectTests` | OK (5) | OK (5) |
| `FdoInsertTest` | OK (14) \* | OK (14) |
| `FdoApplySchemaTest` | fails on the collation (below) | OK (5) |

\* after dropping the datastore an earlier build wrote; before that it failed with
`Property 'Prövince' not found`.

`FdoApplySchemaTest`'s failure on a case-insensitive instance is `TestSchema`'s duplicate-key error,
which is why the suite is pinned to `mssql_cs`. One of its other failures was a different thing
altogether and is fixed: `TestNoMeta` is a negative test that applies a schema which already exists and
asserts the exception text, and it expected that text to end in a trailing space. The catalogue text in
`Utilities/SchemaMgr/Nls/SmMessage.mc` has never had one, so the test compared
`Cannot add schema X to database; it already exists` against `Cannot add schema X to database; it
already exists ` — a one-character mismatch that fails on any platform, while the schema operation
under test had in fact behaved correctly. Deleting the stray space removed that failure.

The same fixtures were then run against a **Release** tree, because fix 10 changed shared bind code and
a Debug pass does not validate Release. `UnitTestMySql` is `OK (249)` there, matching Debug, and the
whole SQL Server suite ran to completion and passed at that point — it did not before fix 18, which is
the Release-only stack overwrite the compiler's optimiser exposed. See
[Test results](#test-results) for what the later, larger suite records.

The changes are part of the official build, not just a hand-built tree: a full Debug `build_thin.sh`
pass on ubuntu22 (`./build_thin.sh --target fdo --distro ubuntu --tag 22 --cpu x64 --debug`)
configures, builds, installs and packages with the provider included, and the resulting
`artifacts/Debug/fdosdk-4.2.0.<rev>-ubuntu22-amd64.tar.gz` contains

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

  `TestInParamsStoreProcVariant` was a **separate** failure, and it was not the overflow: it binds a
  `sql_variant` OUT as an `FdoBLOBValue` and then reinterpreted the payload as a `wchar_t[]` with
  `sizeof(wchar_t)` strides (`SqlServerFdoSqlCmdTest.cpp:842`) — a Windows-shaped expectation of
  2-byte `wchar_t` over a UTF-16 payload, which is what produced the `Value = <replacement
  characters>` in the log on Linux. A BLOB is bytes by definition and the test chose that parameter
  type, so the test now decodes its own payload as UTF-16 (one `bytes[i] | bytes[i+1] << 8` per code
  unit) and asserts on the decoded text; the provider's contract is unchanged.

  A case-sensitive instance is what `SqlServerFdoApplySchemaTest::TestSchema` needs. With it, and with
  the datastore recreated as described below, the whole suite passes — that fixture included, once
  fix 14 corrected the expected output it was comparing against.

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

  The same remedy is what clears a whole run: a stale datastore also fails every fixture that
  connects, each reported as a `setUp()` failure rather than as a test result — typically beginning
  with `SqlServerFdoAdvancedSelectTest` and `Invalid object name 'dbo.…'` — which is what the 38
  failures in the fix-23 A/B runs were. Drop every `fdo_*` database (and the
  `fdolimitedprivilegeuser` login) and re-run; `OK (290)` is what that gives on the current tree.

- **`SqlServerFdoApplySchemaTest::TestSchema` failed a master-file comparison on a case-sensitive
  instance — fixed by [fix 14](#14-the-sql-server-profiles-expected-schema-still-encoded-a-case-insensitive-instance--logicalphysicalbenderxslt).** Once the
  collation was corrected the schema operations under test succeeded and what was left was the
  serialized schema differing from its master:

  ```
  Output file ..._apply_schema_test2_LPhF.xml differs from expected output file
  ..._apply_schema_test2_master.txt
  ```

  The difference was small and precise — one hunk, 16 lines **added** and none removed: the generated
  schema carried a class the expected output did not, `aCxdATA`, with properties `Seq`, `ClassName`
  and `SchemaName`. The reading offered here at the time — that the master was cut against a
  case-insensitive instance where the class could not be created, so the *expected* side was stale —
  turned out to be right, but the stale side was not the shared master: it was `LogicalPhysicalBender.xslt`,
  which carried a SQL-Server-only rule deleting that class from the expected output. See fix 14 for the
  four rules that had to change (and the second, previously masked mismatch behind them). `TestSchema`
  passes now, and the masters are unmodified.

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
- **`DataTypeTests`' geometry roundtrip** passes now (fix 3), but geography is only lightly covered:
  `TestSpatialGeogWinding` (fix 23) creates a `geography` column, inserts points into it and selects
  through it with a polygon filter in both windings, and that is the whole of the geography coverage —
  no `geography` roundtrip of the other geometry types has been exercised.
- **The Release build of the suite segfaulted in `DataTypeTests`' first test — fixed by
  [fix 18](#18-sqlfetch-wrote-a-row-count-over-the-providers-own-stack--fetchc-the-release-only-crash).**
  A Debug pass does not validate Release, so a Release tree was built and the affected suites run
  against it (fix 10 touched shared bind code). This entry is kept for the diagnosis. The SQL Server
  suite could not get past its second fixture:

  ```
  Program received signal SIGSEGV, Segmentation fault.
  #0  odbcdr_fetch2(_odbcdr_context_def*, char*, int, int, int, int*)+464
  #1  rdbi_fetch
  #2  GdbiCommands::fetch
  #3  GdbiQueryResult::ReadNext
  #4  FdoSmPhRdGrdQueryReader::ReadNext
  #5  FdoSmPhSqsMgr::GetDbVersion
  #6  FdoRdbmsSqlServerConnection::CheckForUnsupportedVersion
  #7  FdoRdbmsSqlServerConnection::Open
  #8  DataTypeTests::setUp
  ```

  `#0+464` is a load through a garbage pointer: the local cursor pointer read `0x5603_0000_0000` where
  the live heap address was `0x5603_f88f_1d00`, i.e. its low 32 bits had been replaced. A hardware
  watchpoint on that local showed the writer to be `SQLFetch` itself — `SQL_ATTR_ROWS_FETCHED_PTR` was
  registered against a 4-byte `int` while the driver writes a 8-byte `SQLULEN` through it, so the row
  count landed on the neighbouring local. Debug's frame layout put something else there and survived,
  which is why it only ever showed in Release; it is unrelated to fix 13, which was ruled out by
  reverting it and reproducing the same crash. `DataTypeTests` is `OK (30)` in Release now, and the
  whole suite runs there.

  The same defect was present in the **shared** `Src/ODBCDriver/fetch.c`, which the ODBC provider
  compiles; it was fixed there in r8417 as part of the ODBC port, which runs that suite in Release.
