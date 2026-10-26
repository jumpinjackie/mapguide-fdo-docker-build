# The FDO ODBC provider on Linux — what it is, and what it can actually open

This note answers a question the build system raises and never answers: we build the ODBC FDO
provider for Linux, but **what is the user story for getting it to work?**

On Windows the story is a one-liner — install the Microsoft Access Database Engine (ACE/Jet) and
you get ready-made ODBC drivers for `.mdb`, `.xls`, `.dbf` and `.txt`. **No such story exists on
Linux.** The provider does not carry any drivers of its own; it is a client of the driver manager,
so its coverage on Linux is exactly the set of ODBC drivers you can install and register, and that
set does not include most of the file formats the Windows provider was written around.

## What the Linux build actually is

The FDO build installs the **driver manager** (unixODBC). The only data-source driver it brings in
is mdbtools', and only in the `ubuntu22` *test* image, where the Access suite needs it; the FDO
*installer* still ships no driver at all:

- `ubuntu22` installs `unixodbc-dev` (driver-manager headers) plus `odbc-mdbtools` (the `MDBTools`
  data-source driver the Access suite runs against) — see
  [`../templates/distros/ubuntu/cmd_prepare_fdo_develop.txt`](../templates/distros/ubuntu/cmd_prepare_fdo_develop.txt).
- `generic` compiles unixODBC from source — see
  [`../templates/scripts/container/build_fdo_generic.sh`](../templates/scripts/container/build_fdo_generic.sh).
  It installs no data-source driver (Rocky 8 has no mdbtools package), which is why the Access suite
  is an `ubuntu22` run.
- The provider links `libodbc` + `libodbcinst` through
  [`../fdo/cmake/modules/FindUnixODBC.cmake`](../fdo/cmake/modules/FindUnixODBC.cmake).
- The installer registers `OSGeo.ODBC.4.2` in `providers.xml` but ships **no driver at all** — see
  [`../templates/distros/ubuntu/install.sh`](../templates/distros/ubuntu/install.sh).

In the `generic` build the driver manager is linked **statically** (`libodbc.a`, plus
`libodbcinst.a`) so the SDK does not depend on a particular distro's unixODBC version. That works
because the driver manager `dlopen()`s whatever drivers are registered — but only if its compiled-in
config directory matches the distro's. `build_fdo_generic.sh` therefore configures unixODBC with
`--sysconfdir=/etc`; without that flag the static copy looks in `/usr/local/etc/odbcinst.ini` and
misses the drivers that distro packages register in `/etc`.

So the provider's Linux behaviour is bounded by two things: whether a unixODBC driver exists for
the data source, and whether that driver speaks enough SQL for the FDO schema manager. Of the file
formats the Windows provider was written around, only `.mdb` has a Linux driver, and that half now
has a suite of its own ([below](#activating-the-access-unit-test-suite-on-linux)); the
`.xls` / `.dbf` / `.txt` half has no Linux driver to validate against.

## The file-format story is Windows-shaped

The provider was written against Microsoft's ODBC drivers, and that assumption is visible in the
sources (all paths relative to the FDO working copy):

- The connection helper still names the Microsoft drivers — `Microsoft Excel Driver (*.xls)`,
  `Microsoft Text Driver (*.txt; *.csv)`, `Microsoft dBase Driver (*.dbf)`, and the Windows-only
  `Microsoft Access Driver (*.mdb)` and `SQL Server` — in
  `Providers/GenericRdbms/Src/UnitTest/Odbc/OdbcConnectionUtil.cpp`. Off Windows the Access and SQL
  Server names are replaced by `MDBTools` and `ODBC Driver 18 for SQL Server` (or whatever
  `FDO_ACCESS_ODBC_DRIVER` / `FDO_SQLSERVER_ODBC_DRIVER` names); the other three have no Linux
  driver to name.
- The shipped test init file is nothing but ACE/Jet driver versions (`AccessDriverVersion=12`,
  `DbaseDriverVersion=12`, `ExcelDriverVersion=12`, `TextDriverVersion=12`) —
  `Providers/GenericRdbms/Src/UnitTest/OdbcInit.txt`. Version `12` selects the Microsoft Access
  Database Engine (ACE 2007) driver names.
- All DSN **creation** is `#ifdef _WIN32` at its call sites and goes through `SQLConfigDataSource` /
  `odbcinst.h`, so no DSN is created here and the fixtures fall back to a `DRIVER=...` connection
  string. (`do_rdbi_init` itself is no longer a no-op off Windows — it initialises the context on
  every platform, see the table below.) That is why [the README says ODBC DSNs must be
  configured separately here](../README.md).
- The provider's own documentation describes the file-store use case as read-only over
  pre-existing tables, **point geometry only** (X/Y/Z columns), and — for Excel — tables that "must
  have at least one named range" —
  `Providers/GenericRdbms/Docs/doc_src/group_and_page_definitions/ODBC/define_pages.h`.

## Per-format reality on Linux

| Format | Linux ODBC driver? | Detail |
|--------|--------------------|--------|
| `.mdb` (MS Access) | **Yes** | `mdbtools` — packaged as `odbc-mdbtools` (Ubuntu 22.04 / Debian 12) and `mdbtools-odbc` (Fedora). Rocky 8/EPEL 8 have no mdbtools package, so the `generic` build image cannot install it. Ships `libmdbodbc.so` + `libmdbodbcW.so` and registers `[MDBTools]` in `odbcinst.ini` itself. **Read-only, forward-only cursor**; thin `SQLGetInfo`; no SQL parser support for views, aliases, table-qualified column names, arithmetic expressions or date literals. |
| `.accdb` | **Partial** | The same mdbtools driver detects and parses Jet-4-era `.accdb`; encrypted `.accdb` is not supported and fidelity is not guaranteed. |
| `.xls` / `.xlsx` | **No** | No open-source or packaged Linux ODBC driver; commercial drivers only (CData/Devart/Easysoft). |
| `.dbf` (dBase/xBase) | **No** | No open-source or packaged Linux ODBC driver; commercial xBase drivers only. |
| `.txt` / `.csv` | **No** | unixODBC's historical `txt` driver is an unshipped, unsupported example; Debian's `unixodbc` package contains no drivers at all. Commercial CSV drivers only. |

Distro driver inventories back this up: the *only* file-based ODBC driver packaged by Debian,
Ubuntu and Fedora is mdbtools' MDB driver. Everything else in those repos is a DBMS connector
(PostgreSQL, MySQL/MariaDB, FreeTDS/MSSQL, Oracle) or a language binding.

### There is no "install ACE" equivalent

Microsoft's ACE/Jet engine is Windows-only, its 2016 redistributable reached end of support on
2025-10-14, and the Wine route (`winetricks jet40` / `mdac28`) is **32-bit only**, so it cannot sit
under a 64-bit FDO/ODBC stack. It is not a supportable server story.

## So what *is* the Linux user story?

**Real databases — the provider's actual Linux purpose.** Point it at a registered unixODBC DSN
(PostgreSQL, MySQL/MariaDB, FreeTDS/MSSQL, Oracle, …). The provider accepts two connection modes
(`Providers/GenericRdbms/Src/ODBC/Fdo/FdoRdbmsOdbcConnectionInfo.cpp`):

- `DataSourceName=<dsn>` — a DSN defined in `odbcinst.ini` / `odbc.ini`; the DSN list is populated
  from `SQLDataSources` for the UI.
- `ConnectionString=DRIVER={...};...` — an inline ODBC connection string that bypasses DSN setup
  (the driver still has to be registered in `odbcinst.ini`).

Because DSN creation is Windows-only, configuring a DSN on Linux is a manual step:

```
# /etc/odbc.ini  — define the DSN
[MyPostgresDb]
Driver = PostgreSQL Unicode
Database = mydb
```

**`.mdb` — the one file format that can work.** Install `odbc-mdbtools` (which registers the
`MDBTools` driver itself) and connect with an inline driver string:

```
ConnectionString="DRIVER={MDBTools};DBQ=/data/example.mdb"
```

Use `DBQ=`, not `Database=`, in a driver connection string: mdbtools accepts `Database=` only in a
DSN entry. Use the inline form, not `DataSourceName=MyAccessDb`, for any query the provider has to
generate SQL for: the provider disables the table aliases mdbtools cannot parse by recognising the
`MDBTools` driver in the connection string, and a DSN name does not carry the driver name. Expect
read-only, points-only semantics; data-level writes are non-transactional and locking/timeouts are
unsupported.

**`.xls` / `.xlsx` / `.dbf` / `.txt` / `.csv` — use the FDO GDAL/OGR provider instead.** These
formats are native OGR drivers (`CSV`, `ESRI Shapefile`/DBF, `XLS` via FreeXL, `XLSX`, and `MDB`
via mdbtools), and this build already enables both `OSGeo.Gdal.4.2` and `OSGeo.OGR.4.2`
(`--with-gdal --with-ogr`). That is the honest cross-format story on Linux, and the same
recommendation applies to MapGuide users.

## Activating the SQL Server unit-test suite on Linux

The SQL Server half of the ODBC provider's own suite now runs on Linux. It is the fixture registry
`OdbcSqlServerTests` in `UnitTestOdbc`, and it uses the Microsoft ODBC Driver for SQL Server named
by `FDO_SQLSERVER_ODBC_DRIVER`, defaulting to `ODBC Driver 18 for SQL Server`. The SQL Server
Spatial provider and its suite select the newest registered driver themselves, so set the variable
to `ODBC Driver 17 for SQL Server` if that is the driver you have.

```sh
# mssql_cs from dbs/docker-compose.yml must be up (host port 1434)
run_fdo_tests.sh --fdo-build-dir /tmp/work/build_area/fdo \
    --no-default-suites --with-odbc-sqlserver /tmp/work/scripts/test_init/OdbcSqlServerInit.txt
```

`--with-odbc-sqlserver` takes an init file and defaults to the shipped
`test_init/OdbcSqlServerInit.txt`, which points at `host.docker.internal,1434` and logs in as `sa`;
pass your own path to run it against a different server. The fixtures ask for
`Encrypt=no;TrustServerCertificate=yes`, because ODBC Driver 18 encrypts by default and the fixture
server uses a self-signed certificate — without them every fixture fails with
`SSL Provider: ... certificate verify failed:self-signed certificate`. The registry name matters: without it the runner
would execute every `Odbc*` suite against that one init file, and the Excel/dBase/Text fixtures
need the Windows-only drivers described above (the Access fixtures have their own flag and
registry).

### What had to change

The fixtures were all behind `#ifdef _WIN32`, and the shared driver had several assumptions that
only held where `sizeof(long) == sizeof(int)`.

| Change | Why |
|--------|-----|
| SQL Server fixture classes, their registrations and their implementations moved out of `#ifdef _WIN32` (the Access write fixtures and the Excel/dBase/Text ones stay guarded) | They are ordinary C++ and the driver is available on Linux. |
| SQL Server fixture constructors made `public` | CppUnit's `CPPUNIT_TEST_SUITE_NAMED_REGISTRATION` instantiates the class; a private constructor fails to compile with GCC. |
| `OdbcConnectionUtil` selects the driver by name (`FDO_SQLSERVER_ODBC_DRIVER`) instead of hard-coding `{SQL Server}` | There is no `SQL Server` driver on Linux. |
| `Connection_WithDSN` falls back to the `DRIVER=...` string off Windows | `Setup*DSN()` is Windows-only, so no DSN exists to open. |
| `OdbcStaticConnection::do_rdbi_init` calls `rdbi_init()` under `RDBI_STATIC` on every platform | It returned success without initialising the context off Windows. |
| `OdbcDriver/connect.c` recognises `msodbcsql` / `tdsodbc` by substring (and `SQLNCLI`) | `SQL_DRIVER_NAME` is the driver library's file name on Linux; without this the driver was classified `Other`, losing the SQL Server cursor setup. |
| `Odbc.cpp`'s `getComDir()` guards a `strrchr` NULL and matches the versioned library name by prefix | The first link-map entry without a slash (`linux-vdso.so.1`) produced a NULL dereference, and `libODBCProvider-4.2.0.so` never equalled `libODBCProvider.so`. |
| Data-store DDL (`CREATE/DROP DATABASE`) runs with autocommit temporarily enabled | The connection runs with autocommit off, and SQL Server refuses `CREATE DATABASE` inside a transaction. |
| `ODBCDriver/desc_slct.c` sizes `RDBI_INT` by `sizeof(int)` | It used `sizeof(long)`. On LP64 the RDBI layer stepped 8 bytes through a densely packed 4-byte array, so every second row was skipped and the remaining rows carried their neighbour's column values. |
| `ODBCDriver/define.c` binds `RDBI_LONG` buffers wider than a `SQLINTEGER` as `SQL_C_SBIGINT` | Same class of bug for the 5–10-digit `numeric`/`decimal` band. |
| `ODBCDriver/fetch.c` stores `SQL_ATTR_ROWS_FETCHED_PTR` in a `SQLULEN` | It was an `int`, so the driver's 8-byte write overran the stack slot. |
| The ODBC reserved-word map became a function-local static | As a class-static it was defined in two images (provider DSO and unit-test executable) and its destructor ran twice at exit. |
| `SQLCMD_8BIT_TABLE_NAME` is written as `L"Fd\u00e9SqlTest"` | The source contained a UTF-8 replacement character instead of `é`, which SQL Server rejects. |

### Result

Both configurations are green (the Debug log carries 87 fixtures, the Release log 86 — it predates
`TestMaxBoolProperty`, which now runs as well):

| Build | Result | LeakSanitizer |
|-------|--------|---------------|
| Debug (ASan/LSan) | `OK (87)` | 0 direct records; 792 B in 9 indirect records, all hanging off the single 248-byte `FdoFeatureClass` that `FdoExpressionEngineUtilDataReader::GetAggregateClassDef` leaks (shared Expression Engine code, reached through `FdoAdvancedSelectTest::TestMaxBoolProperty`). The record count follows whatever that class definition happens to own, so read the family, not the count |
| Release | `OK (86)` | not instrumented |

## Activating the Access unit-test suite on Linux

The Access half of the ODBC provider's suite also runs on Linux, against the mdbtools driver. It is
the fixture registry `OdbcAccessTests` in `UnitTestOdbc`. Unlike the Windows run — which is split
into sub-suites because the Jet driver exhausts its connection limit — the mdbtools run is a single
process:

```sh
# odbc-mdbtools installed in the build container
run_fdo_tests.sh --fdo-build-dir /tmp/work/build_area/fdo \
    --no-default-suites --with-odbc-access
```

No init file or DSN is needed: the fixtures build `DRIVER={MDBTools};DBQ=<exe dir>/MSTest.mdb`
from the test executable's directory, where CMake stages `MSTest.mdb`.

### What had to change

| Change | Why |
|--------|-----|
| `OdbcConnectionUtil` uses `MDBTools` as the Access driver on Linux (`FDO_ACCESS_ODBC_DRIVER` overrides it) and builds a `DBQ=` connection string | The Windows fixtures name the Microsoft Access driver and a `MsTest` DSN; neither exists on Linux. |
| `OdbcConnectionUtil::GetTestDataPath()` resolves `/proc/self/exe` off Windows | The Windows implementation used `GetModuleFileName`; the staged test data sits beside the runner on both platforms. |
| `FdoRdbmsOdbcConnectionInfo` recognises `MDBTOOLS` as a file provider and accepts `DBQ=`/`DATABASE=` | The provider-info request otherwise reports an unknown datastore type. |
| `ODBCDriver/connect.c` falls back to `SQL_DBMS_NAME` when `SQLGetInfo(SQL_DRIVER_NAME)` fails, and classifies `MDBTOOLS` | mdbtools returns `SQL_ERROR` for `SQL_DRIVER_NAME`; failing the connection there is wrong for any driver with a thin `SQLGetInfo`. |
| `ODBCDriver/pkeys_.c` skips the `SQLSpecialColumns` approach for mdbtools | Its result set segfaults in `mdb_fetch_row`; the `SQLColumns` approach is used instead. |
| `ODBCDriver/objects_.c` drops `VIEW` rows for mdbtools | mdbtools lists Access saved queries as views but cannot execute them, and it ignores the `SQLTables` type/name filters. |
| `ODBCDriver/col_.c` describes columns with `SQLDescribeCol` for mdbtools | mdbtools implements only `SQL_DESC_NAME`, `SQL_DESC_TYPE`, `SQL_DESC_LENGTH`, `SQL_DESC_UNSIGNED` and `SQL_DESC_DISPLAY_SIZE`; every other `SQLColAttribute` is an error, and its `SQLColumns` reports `SQL_UNKNOWN_TYPE` for many columns. |
| `ODBCDriver/col_.c` drops the `where 1 = 2` predicate from the column probe for mdbtools | mdbtools leaks a glib object for every `WHERE` expression it evaluates (see [mdbtools leaks a chunk per filtered query](#mdbtools-leaks-a-chunk-per-filtered-query)). The probe only reads the result set's shape and never fetches a row, so the predicate bought nothing; removing it took the suite from 168 leaked allocations (40,810 B) to 92 (17,706 B). |
| `templates/scripts/container/lsan/odbc-mdbtools.supp`, applied by `run_fdo_tests.sh --with-odbc-access` | The residue is the driver's own leak, so it is suppressed (module-scoped) rather than reported as an FDO defect; the suite now runs clean. |
| `ODBCDriver/desc_slct.c` executes a prepared statement before describing it for mdbtools | mdbtools returns zero result columns until `SQLExecute`; FDO describes the select list before executing. |
| `FdoRdbmsFilterProcessor` has a `mUseTablePrefix` switch, and `FdoRdbmsOdbcConnection` clears aliases and prefixes for mdbtools | mdbtools' SQL parser rejects `FROM "T" D` and `"T"."COL"`; FDO otherwise generates both. |
| Access fixtures are registered on Linux; the write fixtures (`Delete`, `Insert`, `Update`, `SqlCmd`), the two view selects, the date-filter test and the computed-identifier arithmetic test stay Windows-only | mdbtools is read-only, cannot execute saved queries, has no date-literal support and cannot parse arithmetic expressions. |

### Result

Both configurations are green (`OK (35)`, 35 fixtures):

| Build | Result | LeakSanitizer |
|-------|--------|---------------|
| Debug (ASan/LSan) | `OK (35)` | clean: 0 records. mdbtools' own 17,706 B in 92 allocations are suppressed by `lsan/odbc-mdbtools.supp` (the runner reports "Suppressions used: 92 17706 libmdbsql.so") |
| Release | `OK (35)` | not instrumented |

### mdbtools leaks a chunk per filtered query

Not an FDO leak, and not something the provider can release: mdb-tools' SQL engine allocates one
304-byte glib object for every `WHERE` expression it evaluates and never frees it, so the cost is
proportional to the number of filtered queries a connection runs.

```
Direct leak of 304 byte(s) in 1 object(s) allocated from:
    #1 g_malloc0
    #2 mdb_sql_eval_expr | mdb_sql_add_and      (libmdbsql.so.3)
    #3 mdb_sql_run_query
    #4 SQLExecute                               (libmdbodbc.so)
```

A twenty-line C client that opens the same `.mdb` through the driver, frees every statement,
disconnects and frees every handle leaks identically, so it cannot be attributed to FDO ownership:

```
select * from "TABLE1"                  -> no leak
select * from "TABLE1" where 1 = 2      -> 304 B
select * from "TABLE1" where 1 = 2  (x5) -> 1,520 B
```

The suppressions file matches `libmdbsql.so`, the module the chunks are allocated under. Matching
by function name is not durable: the chunks come from glib, which ships no unwind tables, so how
much of the mdbtools stack LeakSanitizer can name depends on library load order. A leak in FDO
never carries a `libmdbsql` frame, so it is still reported; a hypothetical FDO bug that drops a
reference to an mdbtools allocation would be masked, which is the accepted cost of running the
suite clean. Enabling the suppression needs `ASAN_OPTIONS=fast_unwind_on_malloc=0`, which is
harmless here because the suite runs in about a second.

The provider's own share of the leak was real and **is** fixed: the column probe no longer sends a
constant predicate to mdbtools (168 leaked allocations -> 92, 40,810 B -> 17,706 B). The 92 that
remain are the driver's own — the suite's filtered queries and its other small internal allocations
— and are suppressed, not fixed.

## Bottom line

Present the ODBC provider on Linux as a **database connector** — and, narrowly, an `.mdb` reader.
Advertising a `.xls` / `.dbf` / `.txt` ODBC path there would promise something the platform cannot
deliver; point those users at GDAL/OGR.

> Package names, driver names and library paths above were as-observed against Ubuntu 22.04,
> Debian 12 and Fedora at the time of writing. Verify them against the target distro before relying
> on them.
