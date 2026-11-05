# FDO environment variables

This is an inventory of the environment variables that can configure or influence the runtime
behaviour of FDO and its providers. It was produced from the FDO Subversion working copy at
`fdo/` (branch `branches/4.2`, revision r8418), by searching every `getenv` /
`GetEnvironmentVariable` / `getenv`-equivalent call under `Fdo/`, `Providers/` and `Utilities/`,
then separating the variables FDO reads **directly** from those it inherits from the libraries it
links.

It covers:

- variables read by FDO code — the authoritative list, with source references;
- variables honoured by third-party libraries the providers link (GDAL/OGR, libcurl, libpq,
  libmysqlclient, unixODBC, OCI, Xerces, embedded SQLite);
- compile-time switches and connection properties that are often mistaken for environment
  variables;
- the environment variables the unit-test harness uses (they are not production runtime knobs).

Anything not listed here is either not read at runtime or belongs to MapGuide rather than FDO.
See [Scope and method](#scope-and-method) for how to reproduce and extend the list.

---

## 1. Variables read directly by FDO code

### 1.1 Quick reference

| Variable | Read by | Accepted values | Default | What it does |
|---|---|---|---|---|
| `FDO_TRACE_FILE` | Generic RDBMS RDBI (`Providers/GenericRdbms/Src/Util/trace.cpp`) | file path; leading `+` = append; `%p` = provider module base name (Linux) | unset (tracing off) | Writes the RDBI SQL statements, row counts and timing to a log file (some driver error paths pass their message through the same hook) |
| `FDO_SQS_PERF` | SQL Server Spatial provider (schema manager and ODBC driver) | exactly `1` | unset / any other value | Opt-in to the experimental round-trip reductions (memoised `SQLDescribeParam`, cached database-object catalog) |
| `FDO_SQLSERVER_ODBC_DRIVER` | SQL Server Spatial provider, Linux only; also its unit-test helper and the ODBC test helper | ODBC driver name (the `[section]` in `odbcinst.ini`) | newest registered Microsoft driver (18 over 17) | Selects the ODBC driver used to build the SQL Server connection string |
| `FDOHOME` | `FdoRegistryUtility` (provider registry lookup) and the NLS catalog loader, Linux only | path | `/usr/local/fdo-4.2.0` (registry), `/usr/local/fdo-3.6.0/nls/` (NLS) | Relocates `providers.xml` and message catalogs — see the caveat below |
| `SDF_MAXCACHESIZE` | SDF provider, through `Utilities/SQLiteInterface` | positive integer (feature count) | `10000` | Size of the SDF write cache |
| `TMPDIR` | `FdoCommonFile::GetTempFile` (used by SHP), and the SQLite provider's embedded SQLite (3.7.0.1) | directory | `P_tmpdir` (`/tmp`) | Location of temporary files |
| `PATH` | `FdoConnectionManager` — **Windows only** | — | — | Read and **modified**: the provider and module directories are prepended so dependent DLLs resolve |
| `VISION_OWNER` | `rdbi_vis_owner()` in the RDBI layer | owner name | `vision` (`ops$vision` on Oracle) | Legacy schema-owner override; no caller exists in this tree |
| `VISION_ODBCDR_DDLEXEC` | The ODBC and SQL Server Spatial RDBI drivers | `yes` / `y` (case-insensitive) | off | Legacy DDL-execution switch; the value is stored but never consulted |
| `VISION_ODBCDR_CCACHE_SIZE` | The ODBC and SQL Server Spatial RDBI drivers | integer | `10` | Legacy cursor-cache size; the value is stored but never consulted |
| `FDO_FILTER_YYDEBUG` | Filter parser (generated `yyFilter.cpp` / `yyFilterWin.cpp`) | first character `0`–`9` | off | Parser trace level, printed to **stdout** — only if the parser was compiled with `FDO_FILTER_YYDEBUG=1` |
| `FDO_EXPRESSION_YYDEBUG` | Expression parser (`yyExpression.cpp` / `yyExpressionWin.cpp`) | first character `0`–`9` | off | Parser trace level — only if compiled with `FDO_EXPRESSION_YYDEBUG=1` |
| `FDO_CONSTRAINT_YYDEBUG` | Constraint parser (`Utilities/Common/Src/Parse/yyConstraint.cpp`) | first character `0`–`9` | off | Parser trace level — only if compiled with `FDO_CONSTRAINT_YYDEBUG=1` |
| `FDO_FGFT_YYDEBUG` | Geometry parser (`Fdo/Unmanaged/Src/Geometry/Parse/yyFgft.cpp`) | first character `0`–`9` | off | Parser trace level — only if compiled with `FDO_FGFT_YYDEBUG=1` |
| `FDO_ACCESS_ODBC_DRIVER` | ODBC unit-test connection helper only | ODBC driver name | `MDBTools` on Linux, `Microsoft Access Driver (*.mdb)` on Windows | Selects the Access driver used by the ODBC test fixtures (test-only) |

### 1.2 `FDO_TRACE_FILE` — RDBI SQL trace

**Read at:** `Providers/GenericRdbms/Src/Util/trace.cpp:79` (Windows) and
`Providers/GenericRdbms/Src/Util/trace.cpp:412` (non-Windows).

Tracing is enabled by setting `FDO_TRACE_FILE` **before the first `debug_trace()` call**. Each
Generic RDBMS provider (ODBC, MySQL, PostGIS, SQL Server Spatial) statically links its own copy of
`trace.cpp`, so each provider independently looks the variable up once and caches the result in a
function-local static.

Value semantics:

- Unset (or an empty string on Linux) disables tracing with no overhead beyond one atomic
  increment per call.
- A leading `+` opens the file in append mode; any other value truncates/creates it.
- On Linux, every `%p` in the path is replaced by the base name of the shared object the code was
  linked into, e.g. `libODBCProvider.so`. This is the recommended form when several providers
  trace at once:

  ```sh
  export FDO_TRACE_FILE=/tmp/fdo-%p.log
  # -> /tmp/fdo-libODBCProvider.so.log, /tmp/fdo-libMySQLProvider.so.log, ...
  ```

  Without `%p`, every provider writes to the same path and the last one to open it truncates the
  others (unless `+` is used to append).
- The `%p` expansion exists only in the non-Windows implementation. On Windows the value is used
  verbatim.

What is written: the RDBI-level SQL text (wide or narrow, depending on the driver), the number of
rows processed, the cumulative wall-clock time and user/system CPU time, and a monotonically
increasing sequence number. Example header and shape:

```text
Cum. E: 1.23, CPU: U 0.01, S 0.00

!!42: FDO
select ... from ...
Rows processed: 7
```

The trace records the statements FDO generates, so it is the cheapest way to see the SQL a provider
actually sends; it is implemented at the RDBI layer, not inside the ODBC driver manager, so it does
not require unixODBC's `Trace = Yes`. Because the code lives in the provider shared libraries, the
same variable traces queries issued through MapGuide as well as through a standalone FDO client.

### 1.3 `FDO_SQS_PERF` — SQL Server Spatial opt-in fast path

**Read at:** `Providers/GenericRdbms/Src/SQLServerSpatial/SchemaMgr/Ph/Mgr.cpp:35` and
`Providers/GenericRdbms/Src/SQLServerSpatial/ODBCDriver/rdbi_init.c:214`.

The variable is experimental and strictly opt-in: only the exact value `1` enables it; unset,
empty, `true`, `0` and every other value keep the original behaviour.

It switches on two independent optimisations:

1. **Schema manager** (`FdoSmPhSqsMgr::mPerfEnabled`, exposed as `IsPerfEnabled()`): the physical
   schema catalog reads are de-duplicated for the lifetime of the per-connection schema manager,
   and the cached database-object catalog is dropped again when schema changes are committed.
2. **ODBC driver** (`odbcdr_FastCursors`): each parameter's type is fetched from the server once
   per statement text instead of once per bind, and `SQLDescribeParam()` results are memoised per
   connection/statement.

The measured effect (documented in
[`sqlserver-spatial-linux-support.md`](sqlserver-spatial-linux-support.md#the-fdo_sqs_perf1-opt-in-measured))
over four fixtures was 82 s → 34 s wall clock and 16,222 → 5,116 `SQLDescribeParam()` calls, with
every fixture remaining green and leak-neutral.

Set it before the connection is opened:

```sh
FDO_SQS_PERF=1 ./UnitTestSQLServerSpatial initfiletest=...
```

`run_fdo_tests.sh --with-sqlserver-perf` does exactly that for the suite. As with `FDO_TRACE_FILE`,
the flag lives in the provider, so it also applies when MapGuide uses the SQL Server Spatial
provider.

### 1.4 `FDO_SQLSERVER_ODBC_DRIVER` — SQL Server ODBC driver name

**Read at:** `Providers/GenericRdbms/Src/SQLServerSpatial/Fdo/FdoRdbmsSqlServerConnection.cpp:809`
(Linux branch), and by the test helpers in
`Providers/GenericRdbms/Src/UnitTest/SQLServerSpatial/SqlServerConnectionUtil.cpp:526` and
`Providers/GenericRdbms/Src/UnitTest/Odbc/OdbcConnectionUtil.cpp:143`.

The SQL Server Spatial provider builds its own
`DRIVER={...};MARS_Connection=yes;SERVER=...` connection string. On Windows it enumerates the
registered drivers with the ODBC driver manager and uses the newest Microsoft SQL Server driver,
falling back to `SQL Server Native Client` and then the legacy `SQL Server` driver. On non-Windows
it enumerates the same way, and because only the Microsoft driver exists there, this variable and
that enumeration are all there is: unset, the provider uses the newest Microsoft ODBC Driver for
SQL Server registered with the driver manager, so

```text
ODBC Driver 18 for SQL Server
```

when driver 18 is installed, and `ODBC Driver 17 for SQL Server` only when it is not.

The value is the `[section]` name in `odbcinst.ini`, **not** a path:

```sh
FDO_SQLSERVER_ODBC_DRIVER="ODBC Driver 18 for SQL Server" ./UnitTestSQLServerSpatial ...
```

An empty value falls back to the enumeration. The enumeration is resolved once per process, so a
driver installed after the first connection is picked up after a restart. This variable is read
when the connection string is generated (connection open), so set it before opening the connection.
On Windows the provider does not read it; the test helper does, on both platforms.

The ODBC provider's own test helper (`OdbcConnectionUtil.cpp`) does not enumerate: unset, it asks
for `ODBC Driver 18 for SQL Server` on Linux (and `SQL Server` on Windows).

See [`sqlserver-spatial-linux-support.md`](sqlserver-spatial-linux-support.md) for the full Linux
setup.

### 1.5 `FDOHOME` — relocated FDO installation

**Read at:** `Fdo/Unmanaged/Src/Fdo/ClientServices/RegistryUtility.cpp:803` and
`Fdo/Unmanaged/Src/Nls/cat_open.c:147` (both in non-Windows-only branches).

`FDOHOME` is meant to point at an FDO installation that is not in the compiled-in default location.
The two consumers interpret it slightly differently:

- `FdoRegistryUtility::GetFileName()` uses it as the install prefix, and only after two nearer
  probes: `providers.xml` next to `libFDO`, then next to the running executable. Failing both it
  tries `<FDOHOME>/lib64/providers.xml` and then `<FDOHOME>/lib/providers.xml` (default prefix
  `/usr/local/fdo-4.2.0`). The executable's directory is the probe a build tree relies on, because
  its single `libFDO` has no registry beside it while every provider suite has one next to its
  test binary.
- `nls_cat_open()` uses it as the *catalog directory*: it concatenates `FDOHOME` with the catalog
  name directly (`sprintf(fullfilename, "%s%s", install, cat_name)`). The default is the legacy
  string `/usr/local/fdo-3.6.0/nls/`, so a value should end with a slash for this path to work.

The practical guidance is: set `FDOHOME` to the install prefix if you need to relocate
`providers.xml`, and set `NLSPATH` (see [§2.1](#21-locale-and-message-catalogues)) for message
catalogs, rather than relying on the NLS interpretation of `FDOHOME`.

Both consumers cache their result (the registry path is resolved once per process, and catalogs are
cached), so set `FDOHOME` before the first FDO call.

### 1.6 `SDF_MAXCACHESIZE` — SDF write cache size

**Read at:** `Utilities/SQLiteInterface/SQLiteDataBase.cpp:200`, when
`SQLiteDataBase::SetMaxCacheSize()` is asked to reset the cache (the `SQLiteDataBase` constructor
does this).

The value is parsed with `atol`; only a value greater than zero is accepted. The precedence is:

1. the SDF connection property `MaxCacheSize` (if greater than zero) —
   `Providers/SDF/Src/Provider/SdfConnection.cpp:557`;
2. the `SDF_MAXCACHESIZE` environment variable (if greater than zero);
3. the compiled-in default `SQLiteDB_MAXCACHESIZE`, which is `10000` features
   (`Utilities/SQLiteInterface/SQLiteDataBase.h:37`).

The cache is the write cache used when inserting features; larger values can speed up bulk inserts,
at the cost of memory. Despite the `SDF_` prefix, the code lives in the shared `SQLiteInterface`
library; it is only wired into the SDF provider in this tree.

### 1.7 `TMPDIR` — temporary file location

**Read at:** `Utilities/Common/Src/FdoCommonFile.cpp:859` (non-Windows), and inside the SQLite
provider's embedded SQLite 3.7.0.1 (`Providers/SQLite/Src/sqlite/os_unix.c:4215`).

`FdoCommonFile::GetTempFile(name, path)` honours its `path` argument first. If that is NULL or
empty, it uses `TMPDIR`, then `P_tmpdir` (`/tmp`). The only FDO caller in this tree is the SHP
provider's spatial-index defragmentation
(`Providers/SHP/Src/ShpSpatialIndex/ShpSpatialIndex.cpp:2375`), which passes its
`TemporaryFileLocation` connection property (empty unless set). So:

- SHP with `TemporaryFileLocation=...` in the connection string uses that directory;
- SHP without it uses `TMPDIR` or `/tmp`;
- the SQLite provider's temp files (sorts, temporary tables) use `TMPDIR`, then `/var/tmp`,
  `/usr/tmp`, `/tmp`;
- the SDF provider does **not** honour `TMPDIR` for its embedded SQLite 3.3.13 temporary files —
  that version has a fixed search list (`/var/tmp`, `/usr/tmp`, `/tmp`, `.`) and can only be
  redirected with `PRAGMA temp_store_directory`.

On Windows, `FdoCommonFile::GetTempFile` calls `GetTempPath()`, which in turn follows
`TMP`, `TEMP`, `USERPROFILE`, then the Windows directory — so those variables affect FDO on
Windows indirectly.

### 1.8 `PATH` — Windows provider dependency search path

**Read and written at:** `Fdo/Unmanaged/Src/Fdo/ClientServices/ConnectionManager.cpp:49,176,189`.

This is Windows-only (`addPath()` is a no-op off Windows). When FDO loads a provider for the first
time, it prepends the FDO module's directory and the provider library's directory to the process
`PATH` if they are not already there, so that dependent DLLs (for example `FDOSpatial.dll`) resolve.
Because FDO **modifies** `PATH`, code that later inspects the process environment sees the added
entries. On Linux the equivalent search is governed by the dynamic loader
(`LD_LIBRARY_PATH`, see [§2.2](#22-dynamic-loader)).

### 1.9 Legacy RDBI variables

These are read by the generic RDBI/ODBC layer. All three are legacy and none of them currently
changes behaviour:

| Variable | Read at | Current status |
|---|---|---|
| `VISION_OWNER` | `Providers/GenericRdbms/Src/Rdbi/vis_owner.c:58` | `rdbi_vis_owner()` has no caller in the FDO tree; the value would be used as the schema owner, prefixed with `ops$` on Oracle |
| `VISION_ODBCDR_DDLEXEC` | `Providers/GenericRdbms/Src/ODBCDriver/rdbi_init.c:207` and `Providers/GenericRdbms/Src/SQLServerSpatial/ODBCDriver/rdbi_init.c:220` | Stored in `odbcdr_ddlexec`, which is never consulted |
| `VISION_ODBCDR_CCACHE_SIZE` | `Providers/GenericRdbms/Src/ODBCDriver/rdbi_init.c:220` and `Providers/GenericRdbms/Src/SQLServerSpatial/ODBCDriver/rdbi_init.c:233` | Stored in `odbcdr_ccache_size`, which is never consulted |

The names are constructed at runtime (`"VISION" + "_" + "ODBCDR" + "_" + suffix`) so they do not
appear as contiguous strings in the binaries. Both the shared ODBC driver and the SQL Server
Spatial driver's own copy of the driver read the same names.

If a future change starts using those fields, `DDLEXEC` accepts `yes`/`y` (case-insensitive) and
defaults to off; `CCACHE_SIZE` is parsed with `atoi`, negative values are clamped to zero, and the
default is 10.

### 1.10 Parser debug variables (compile-time gated)

**Read at:**

- `Fdo/Unmanaged/Src/Fdo/Parse/yyFilter.cpp:661` (`FDO_FILTER_YYDEBUG`)
- `Fdo/Unmanaged/Src/Fdo/Parse/yyExpression.cpp:513` (`FDO_EXPRESSION_YYDEBUG`)
- `Fdo/Unmanaged/Src/Geometry/Parse/yyFgft.cpp:388` (`FDO_FGFT_YYDEBUG`)
- `Utilities/Common/Src/Parse/yyConstraint.cpp:540` (`FDO_CONSTRAINT_YYDEBUG`)

These follow the traditional yacc convention: the first character of the value, if it is a digit
`0`–`9`, sets the parser's trace level; at level 0 tracing is off. The trace is printed to
**stdout** (`printf("%sdebug: state %d, ...")`), not stderr.

**They do nothing unless the parser is compiled with the matching macro enabled.** All four
generated parsers default the macro to `0`:

```c
#ifndef FDO_FILTER_YYDEBUG
#define FDO_FILTER_YYDEBUG 0
#endif
```

The intended way to enable them was to uncomment the switches in
`Fdo/Unmanaged/Src/Fdo/Parse/Lex.h` (`FDO_FILTER_YYDEBUG`, `FDO_EXPRESSION_YYDEBUG`) or
`Fdo/Unmanaged/Src/Geometry/Parse/LexFgft.h` (`fdo_fgft_YYDEBUG`, note the lowercase prefix),
which requires a rebuild. No CMake or build-script definition enables them today, so in a normal
build these environment variables are inert.

Because the parsers are checked-in generated files, remember the rule in
[`../AGENTS.md`](../AGENTS.md): a grammar change has to be applied to both the `.y` input and
the generated parser; the same applies to enabling debug output.

---

## 2. Variables inherited from third-party libraries

The variables below are not read by FDO code. They reach FDO because a provider links a library
that reads them, so they can still change provider behaviour. Treat this as a set of categories
rather than an exhaustive list — the libraries' own documentation is authoritative for each one,
and the exact set grows with each library upgrade.

### 2.1 Locale and message catalogues

FDO's messages are looked up through `catopen()`/`catgets()`
(`Fdo/Unmanaged/Src/Nls/cat_open.c` → `Fdo/Unmanaged/Src/Nls/msg_get.c`), and numeric formatting
consults the process locale through `localeconv()`.

| Variable | Who reads it | Effect |
|---|---|---|
| `NLSPATH` | glibc `catopen()` | Search path for message catalogues. The FDO test scripts point it at `<build>/nls/linux/en_US/%N`; without it, error messages fall back to raw symbols such as `FDOSM_220`. Set **and modified** by `MgPortablePlatform::Initialize()` in MapGuide, which prepends the catalogues derived from its `Platform.ini` `FdoPath` — see [§2.1](#21-locale-and-message-catalogues) |
| `LANG`, `LC_ALL`, `LC_MESSAGES` | libc / `catopen()` | Select the message language and the catalogue subdirectory |
| `LC_NUMERIC`, `LC_ALL`, `LANG` | libc `localeconv()` | Determine the decimal separator used by `FdoStringP`, `FdoStringUtility::FormatNumber`, `GeometryUtility::FormatNumber` and the lexer's number parsing |
| `LC_CTYPE`, `LC_ALL` | libc, and unixODBC's narrow→wide conversion | On Linux the FDO ODBC path emits UTF-8; unixODBC converts it to wide characters using `LC_CTYPE`. In the `C` locale non-ASCII identifiers can silently fail to match. The test scripts default `LC_CTYPE=C.UTF-8` for this reason |
| `LC_ALL`, `LANG`, `LC_CTYPE` | SHP provider (`ShapeCPG`, `ShapeDBF`) | When a `.dbf` file has neither a `.cpg` sidecar nor an LDID code page, SHP derives the DBF code page from the process locale (`setlocale(LC_ALL, NULL)`), including the `.iso`/`.cp`/`.utf8`/`.euc`/`.big5`/`.ujis` suffix mappings |
| `XERCESC_NLS_HOME` | bundled Xerces message loaders | Location of Xerces message catalogues |
| `XERCESCROOT` | bundled Xerces message loaders | Fallback for `<XERCESCROOT>/msg` when `XERCESC_NLS_HOME` is unset |

MapGuide's portable API sets `NLSPATH` itself, so a consumer of `libMgPortable`/the
`OSGeo.MapGuide.Portable` package never has to: `MgPortablePlatform::Initialize()`
(`Portable/MgPortable/System/PlatformInit.cpp`) derives the catalogue directory from the `FdoPath`
in `Platform.ini` — `<fdo root>/nls`, `<fdo root>/nls/linux/en_US` (build trees) and `<FdoPath>/nls`
(a flattened tree), taking whichever exist — and prepends them as `<dir>/%N` patterns to any
`NLSPATH` already in the environment. That is what makes a relocated FDO tree resolve its messages,
since the catalogues live beside the `lib64` the SDK installs rather than on any default path.

A C/C++ process starts in the `"C"` locale regardless of these variables. FDO does not call
`setlocale(LC_ALL, "")` on library initialisation — its `nls_locale_set()` helper is only invoked by
the standalone NLS test program. The **host application** decides whether the environment's locale
is applied. The FDO unit-test host does call `setlocale(LC_ALL, "")`
(`Providers/GenericRdbms/Src/UnitTest/Common/UnitTest.cpp`), which is why `LC_CTYPE` matters in the
suites.

The SHP provider is the one place FDO itself consults the process locale explicitly: `ShapeCPG` and
`ShapeDBF` call `setlocale(LC_ALL, NULL)` (they read it, they do not change it) to turn a locale
such as `en_US.UTF-8` into an ESRI code page when a shapefile's `.dbf` has no `.cpg` and no LDID.
That is why the test image has to generate several locales, and why the SHP suite's
locale round-trip test is sensitive to the host's locale settings.

### 2.2 Dynamic loader

| Variable | Platform | Effect |
|---|---|---|
| `LD_LIBRARY_PATH` | Linux | Where `dlopen()` (FDO's provider loading) and the loader resolve `libFdo*.so` and provider dependencies |
| `LD_PRELOAD` | Linux | Injects libraries ahead of the ASan runtime; for instrumented builds this must be used together with `ASAN_OPTIONS=verify_asan_link_order=0` |
| `PATH` | Windows | See [§1.8](#18-path--windows-provider-dependency-search-path); also the loader's search path for dependent DLLs |

### 2.3 libcurl — WMS and WFS providers

The WMS and WFS providers perform their HTTP through `Utilities/OWS/Src/FdoOwsHttpHandler.cpp`,
which uses libcurl (bundled 8.4.0 in `generic` builds, the system libcurl on Ubuntu).

| Variable | Effect |
|---|---|
| `http_proxy` (lowercase only), `HTTPS_PROXY`, `https_proxy`, `all_proxy`, `ALL_PROXY` | Proxy URL used when the connection string's `ProxyServerName` is empty |
| `no_proxy`, `NO_PROXY` | Hosts that bypass the proxy |
| `CURL_SSL_BACKEND` | Selects the TLS backend when libcurl has more than one |
| `SSLKEYLOGFILE` | Writes TLS secrets for packet capture (curl 8.x) |
| `CURL_TRACE`, `CURL_DEBUG`, `CURL_DEBUG_SIZE` | libcurl internal diagnostics |

The provider's own `ProxyServerName`, `ProxyServerPort`, `ProxyServerUsername` and
`ProxyServerPassword` connection properties take precedence: if `ProxyServerName` is set, FDO passes
`CURLOPT_PROXY` explicitly and libcurl's proxy environment variables are ignored. The handler also
sets `CURLOPT_SSL_VERIFYPEER` to false, so CA-path variables rarely change its behaviour.

### 2.4 GDAL and OGR providers

The GDAL and OGR providers link GDAL (bundled 2.4.4 in the `generic` build, the system GDAL on
Ubuntu). Every GDAL **configuration option** can be supplied as an environment variable of the same
name, and is read by `CPLGetConfigOption`/`CPLTestBool` throughout GDAL/OGR. Commonly relevant ones:

| Variable | Effect |
|---|---|
| `GDAL_DATA` | Directory holding `gdal/*.csv`, `pcs.csv`, `coordinate_axis.csv`, etc. Wrong or missing values break coordinate-system and axis lookups |
| `GDAL_DRIVER_PATH` | Extra directory searched for GDAL/OGR driver plugins |
| `GDAL_CACHEMAX` | Raster block cache size |
| `GDAL_DISABLE_READDIR_ON_OPEN` | Stops GDAL listing a directory to find sidecar files; often a large speed-up on network filesystems |
| `CPL_DEBUG` | GDAL debug output (e.g. `CPL_DEBUG=ON`) |
| `CPL_TMPDIR`, `TMPDIR` | Directory used by `CPLGenerateTempFilename()` (`CPL_TMPDIR` wins) |
| `OGR_SKIP` | Comma-separated list of OGR drivers to skip |
| `OGR_*` format options | Per-format behaviour, e.g. `OGR_S57_OPTIONS`, `OGR_VRT_*` |

Cloud and database drivers add their own credentials/endpoint variables (`AWS_*`, `AZURE_*`,
`PG*`, `MYSQL_*`, ...); those only matter if the relevant OGR driver is used.

### 2.5 libpq — PostGIS provider

The PostGIS provider uses libpq directly (`Providers/GenericRdbms/Src/PostGis/Driver/connect.c`)
and builds the connection with `PQsetdbLogin(pghost, pgport, NULL, NULL, dbname, user, password)`.
Because the provider always supplies a host (`localhost` by default) and a port (`5432` by
default), libpq's `PGHOST`/`PGPORT` fallbacks do **not** apply. The remaining libpq defaults do,
whenever the corresponding value is not supplied:

| Variable | Applies when |
|---|---|
| `PGDATABASE` | no database is given in the connection string (the provider passes NULL) |
| `PGUSER`, `PGPASSWORD` | the connection's username/password are empty |
| `PGPASSFILE`, `PGSERVICE`, `PGSERVICEFILE` | libpq's normal service/password-file lookup |
| `PGOPTIONS` | always passed through to the server |
| `PGCONNECT_TIMEOUT` | libpq connection timeout |
| `PGCLIENTENCODING` | client encoding — the provider later forces UTF-8 with `PQsetClientEncoding` |
| `PGSSLMODE`, `PGSSLCERT`, `PGSSLKEY`, `PGSSLROOTCERT`, `PGSSLCRL`, `PGSSLCRLDIR` | TLS behaviour |
| `PGKRBSRVNAME`, `PGGSSENCMODE`, `PGGSSLIB` | Kerberos/GSS behaviour |
| `PGTZ`, `PGDATESTYLE`, `PGAPPNAME`, `PGTARGETSESSIONATTRS` | session defaults |
| `PGSYSCONFDIR`, `PGLOCALEDIR` | libpq configuration and message locations |

### 2.6 libmysqlclient — MySQL provider

`Providers/GenericRdbms/Src/MySQL/Driver/connect.cpp` passes an explicit host (`localhost` by
default), port (`MYSQL_PORT` by default), user and password to `mysql_real_connect()`, so
`MYSQL_HOST` and `MYSQL_TCP_PORT` do not apply. What remains:

| Variable | Applies when |
|---|---|
| `MYSQL_PWD` | the password argument is NULL/empty |
| `MYSQL_UNIX_PORT` | connecting to `localhost` over a Unix socket |
| `MYSQL_TEST_LOGIN_FILE` | only if the client library performs a login-path lookup; FDO does not request one explicitly |

### 2.7 unixODBC / iODBC — ODBC and SQL Server Spatial providers

FDO passes a `DRIVER={...}` connection string to the driver manager, which then `dlopen()`s the
driver. The driver manager and the driver read their own configuration from files, located with:

| Variable | Effect |
|---|---|
| `ODBCINI` | Path to the user's `.odbc.ini` |
| `ODBCSYSINI` | Directory holding the system `odbcinst.ini` (default `/etc` or the build's `--sysconfdir`) |
| `ODBCINSTINI` | Name of the system driver-registration file (default `odbcinst.ini`) |

For the SQL Server providers this is why installing the Microsoft driver registers a section such as
`[ODBC Driver 18 for SQL Server]` in `/etc/odbcinst.ini`, why the provider enumerates those sections
to pick a driver, and why `FDO_SQLSERVER_ODBC_DRIVER` is a *name*, not a path. In `generic` builds the provider links a static unixODBC compiled with
`--sysconfdir=/etc`, so `ODBCSYSINI` moves the file for both that copy and the dynamically loaded
driver.

Driver-specific variables also apply. For example, if the SQL Server connection is routed through
FreeTDS's `tdsodbc` driver (which the provider recognises), FreeTDS reads `FREETDS`, `TDSVER`,
`TDSDUMP`, `TDSDUMPCONFIG`, `TDSHOST`, `TDSPORT`, `TDSDATABASE`, `TDSUSERNAME`, `TDSPASSWORD`,
`TDSQUERY`, `TDSCHARSET`, and others. Those are properties of the installed driver, not of FDO.

### 2.8 Oracle OCI — KingOracle provider

The KingOracle provider calls OCI directly (`#include <oci.h>`). OCI reads its own environment:

| Variable | Effect |
|---|---|
| `ORACLE_HOME` | Oracle client installation (legacy; not needed by Instant Client) |
| `TNS_ADMIN` | Directory containing `tnsnames.ora`, `sqlnet.ora`, `ldap.ora` |
| `TWO_TASK` / `LOCAL` | Default connect identifier |
| `ORACLE_SID` | Default local instance |
| `NLS_LANG` | Client language/territory/charset, affecting OCI messages and conversions |
| `ORA_NLS10` / `ORA_NLS33` | Legacy NLS data directory |
| `LD_LIBRARY_PATH` | Where the OCI libraries are found |

The provider itself reads no environment variables; the KingOracle **unit test** reads
`KG_DEFAULT_ORA_CONNECTION`, `KG_ORA_USERNAME`, `KG_ORA_PASSWORD` and `KG_ORA_SERVICE`
(see [§3](#3-unit-test-harness-variables)).

### 2.9 Informix and ArcSDE (not built by default)

`Providers/CMakeLists.txt` does not build `KingInformix`, `KingMsSqlSpatial`, `ArcSDE` or
`KingKML`. If they are enabled, their client libraries' environments apply:

- **Informix:** `INFORMIXDIR`, `INFORMIXSERVER`, `INFORMIXSQLHOSTS`, `ONCONFIG`, `DB_LOCALE`,
  `CLIENT_LOCALE`, `DBDATE`, `DBTIME`, `IFX_LONGID`, `LD_LIBRARY_PATH`.
- **ArcSDE:** `SDEHOME` is the build/developer-SDK location (set by `setenvironment.sh` and checked
  by the Windows build scripts); at runtime the ArcSDE client libraries come from the loader path.

### 2.10 Embedded SQLite

| Variable | Where | Effect |
|---|---|---|
| `TMPDIR` | SQLite provider's embedded 3.7.0.1 (`Providers/SQLite/Src/sqlite/os_unix.c:4215`) | Temporary files (sorts, temp tables) |
| `SQLITE_FORCE_PROXY_LOCKING` | Same file, line 4585 | Forces SQLite's proxy locking on/off. Only compiled in when `SQLITE_ENABLE_LOCKING_STYLE` is 1 (macOS); on Linux and Windows it is inert |
| `TMP`, `TEMP`, `USERPROFILE` | Embedded SQLite's Windows VFS | Windows temporary directory |

The SDF provider's embedded SQLite (3.3.13) does not read `TMPDIR`; see
[§1.7](#17-tmpdir--temporary-file-location).

### 2.11 OpenSSL

WMS/WFS HTTPS (through libcurl) and any provider using OpenSSL-linked client libraries inherit
OpenSSL's environment: `OPENSSL_CONF`, `OPENSSL_CONF_INCLUDE`, `OPENSSL_MODULES`, `OPENSSL_ENGINES`,
`SSL_CERT_FILE`, `SSL_CERT_DIR`, `RANDFILE`, and the `OPENSSL_*cap` CPU overrides. These are rarely
useful in normal operation but are the first thing to check when TLS behaves differently in a
container from the host. `SSLKEYLOGFILE` is read by libcurl, not by OpenSSL itself; it is listed in
[§2.3](#23-libcurl--wms-and-wfs-providers).

---

## 3. Unit-test harness variables

These are not production runtime settings. They are included because a sweep of the tree finds
them next to the real knobs, and because some of them (`initfiletest`, `USE_ENV`) look like they
should influence the provider when they only configure the tests.

The Generic RDBMS test runners convert each `name=value` command-line argument into an environment
variable (`Providers/GenericRdbms/Src/UnitTest/Common/UnitTest.cpp`), which is why these are read
with `getenv`.

| Variable | Where | Effect |
|---|---|---|
| `initfiletest` | `MySql`, `Odbc`, `PostGis`, `SQLServerSpatial` connection helpers | Path to the init file supplying `provider`, `service`, `username`, `password`, `datastore`, `clean` |
| `USE_ENV` | Same helpers | If set, the init file does not clear `service`/`username`/`password`, so values already in the environment are used |
| `service`, `username`, `password`, `datastore`, `provider`, `dsnname` | `ConnectionUtil::GetEnviron` / `GetEnv` | Connection values; set from the init file unless `USE_ENV` is set |
| `ROOT` | `FdoInsertTest`, `FdoUpdateTest`, `GeometryMemPerfTest` | Test data root |
| `ltmethod`, `lt_mode` | `UnitTestUtil::CreateDB`, `SchemaMgrTests` | Long-transaction method/mode used when the fixture does not fix it |
| `testgroups` | `UnitTestUtil::DoThisTest` | Comma-separated group names; tests in other groups are skipped (`all` runs everything) |
| `description` | `UnitTestUtil::CreateDB` | Datastore description used when the fixture creates its datastore |
| `sqlserver_data_root` | `SqlServerFdoApplySchemaTest` (Windows) | SQL Server data directory used by the file-placement fixtures |
| `USER` | SDF/SQLite `tester-linux.h` `GETUSER` | Default datastore name component |
| `FDO_ACCESS_ODBC_DRIVER` | `OdbcConnectionUtil` | Access driver name for the ODBC fixtures (default `MDBTools`) |
| `FDO_SQLSERVER_ODBC_DRIVER` | `OdbcConnectionUtil`, `SqlServerConnectionUtil` | As [§1.4](#14-fdo_sqlserver_odbc_driver--sql-server-odbc-driver-name) |
| `FDO_CRT_LEAK_CHECK` | Bundled CppUnit host (Windows) | Send the MSVC CRT leak report to stderr |
| `rdbms`, `server`, `port_multi`, `port_single`, `sdepwd`, `dataset`, `initschema`, `supportsusermanagedstringids` | ArcSDE tests | ArcSDE fixture configuration; despite the "command-line argument" wording in the messages, they are read from the environment |
| `KG_DEFAULT_ORA_CONNECTION`, `KG_ORA_USERNAME`, `KG_ORA_PASSWORD`, `KG_ORA_SERVICE` | KingOracle tests | Oracle fixture configuration |

`run_fdo_tests.sh` also sets `NLSPATH` and `LC_CTYPE` for the suites; see
[§2.1](#21-locale-and-message-catalogues).

`GVC_TRACE_FILE` is set by `FdoSqlCmdTest`/`FdoUpdateTest` but nothing in this tree reads it; it is
a vestige of a geometry test harness.

---

## 4. Things that are not environment variables

These are frequently mistaken for environment variables because they are named like them, or
because the code around them uses `getenv` for the neighbouring setting:

| Name | What it really is |
|---|---|
| `FDO_FILTER_YYDEBUG`, `FDO_EXPRESSION_YYDEBUG`, `FDO_CONSTRAINT_YYDEBUG`, `FDO_FGFT_YYDEBUG` | Compile-time macros first, environment variables only if the macro is enabled at build time (see [§1.10](#110-parser-debug-variables-compile-time-gated)) |
| `DEBUG_TRACELEX`, `DEBUG_TRACETREE`, `DEBUG_TRACETOKEN`, `DEBUG_TRACEACTIONS` | Compile-time `#define`s in the `Lex*.h` headers; no environment lookup |
| `XML_DEBUG` | Compile-time switch that makes `FdoXml::Deserializable` write `temp_in.xml`; it does not read an environment variable |
| `VERBOSE` | Compile-time switch in `Utilities/OWS/Src/FdoOwsHttpHandler.cpp` that turns on `CURLOPT_VERBOSE`; not settable at runtime |
| `_KGORA_EXTENDED_LOG` | Compile-time switch for KingOracle logging. When enabled, logs to the fixed path `/tmp/kingora.log` on Linux (`Providers/KingOracle/src/Provider/c_KgOraConnection.cpp:91`), regardless of environment |
| `MaxCacheSize` | SDF **connection property**, not an environment variable; it overrides `SDF_MAXCACHESIZE` |
| `TemporaryFileLocation` | SHP **connection property**; overrides `TMPDIR` for spatial-index defragmentation |
| `ProxyServerName` etc. | WMS/WFS **connection properties**; override libcurl's proxy environment |
| `FDO_TRACE_FILE` on Windows with `%p` | Windows does not expand `%p`; it is a literal path |
| `SDEHOME`, `FDOTHIRDPARTY`, `FDO` | Build-time variables in `setenvironment.sh` / `cmake_bootstrap.sh`, not FDO runtime settings |

---

## 5. Scope and method

This inventory was produced with:

```sh
cd fdo

# Direct reads by FDO code (Thirdparty and .svn excluded)
grep -rn --include='*.cpp' --include='*.h' --include='*.c' \
     -E 'getenv|GetEnvironmentVariable|_wgetenv|getenv_s' \
     Fdo Providers Utilities Samples Tools \
  | grep -v '/Thirdparty/' | grep -v '/\.svn/' | grep -v '/sqlite/'

# FDO-prefixed names anywhere in the tree
grep -rhoE 'FDO_[A-Z][A-Z0-9_]+' --include='*.cpp' --include='*.h' --include='*.c' \
     Fdo Providers Utilities | sort -u
```

Two caveats for anyone repeating this:

1. `grep` also matches the SVN pristine copies under `fdo/.svn/pristine/` and the bundled
   third-party trees; both have to be excluded to get usable results. The embedded SQLite files
   under `Providers/SQLite/Src/sqlite/` are third-party code but are listed here because they are
   compiled into a provider.
2. Several legacy names are constructed at runtime (`VISION_ODBCDR_*`) and will not appear as
   string literals; search for `getparm` and for `getenv` with a variable argument.

The authoritative list is always the source: if a variable is added to FDO, add a row here and to
the quick-reference table. Keep the "current status" column honest — several entries above are
read but no longer consumed, and that is useful information rather than something to tidy away.
