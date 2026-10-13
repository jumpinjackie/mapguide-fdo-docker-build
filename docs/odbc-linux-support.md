# The FDO ODBC provider on Linux — what it is, and what it can actually open

This note answers a question the build system raises and never answers: we build the ODBC FDO
provider for Linux, but **what is the user story for getting it to work?**

On Windows the story is a one-liner — install the Microsoft Access Database Engine (ACE/Jet) and
you get ready-made ODBC drivers for `.mdb`, `.xls`, `.dbf` and `.txt`. **No such story exists on
Linux.** The provider does not carry any drivers of its own; it is a client of the driver manager,
so its coverage on Linux is exactly the set of ODBC drivers you can install and register, and that
set does not include most of the file formats the Windows provider was written around.

## What the Linux build actually is

The FDO build installs only the **driver manager** (unixODBC), never a data-source driver:

- `ubuntu22` installs `unixodbc-dev` (driver-manager headers only) — see
  [`../templates/distros/ubuntu/cmd_prepare_fdo_develop.txt`](../templates/distros/ubuntu/cmd_prepare_fdo_develop.txt).
- `generic` compiles unixODBC from source — see
  [`../templates/scripts/container/build_fdo_generic.sh`](../templates/scripts/container/build_fdo_generic.sh).
- The provider links `libodbc` + `libodbcinst` through
  [`../fdo/cmake/modules/FindUnixODBC.cmake`](../fdo/cmake/modules/FindUnixODBC.cmake).
- The installer registers `OSGeo.ODBC.4.2` in `providers.xml` but ships **no driver at all** — see
  [`../templates/distros/ubuntu/install.sh`](../templates/distros/ubuntu/install.sh).

So the provider's Linux behaviour is bounded by two things: whether a unixODBC driver exists for
the data source, and whether that driver speaks enough SQL for the FDO schema manager. The
file-format half of the coverage was never validated on Linux.

## The file-format story is Windows-shaped

The provider was written against Microsoft's ODBC drivers, and that assumption is visible in the
sources (all paths relative to the FDO working copy):

- The connection helper hardcodes the Microsoft driver names — `Microsoft Access Driver (*.mdb)`,
  `Microsoft Excel Driver (*.xls)`, `Microsoft Text Driver (*.txt; *.csv)`, `Microsoft dBase Driver
  (*.dbf)` — in `Providers/GenericRdbms/Src/UnitTest/Odbc/OdbcConnectionUtil.cpp`.
- The shipped test init file is nothing but ACE/Jet driver versions (`AccessDriverVersion=12`,
  `DbaseDriverVersion=12`, `ExcelDriverVersion=12`, `TextDriverVersion=12`) —
  `Providers/GenericRdbms/Src/UnitTest/OdbcInit.txt`. Version `12` selects the Microsoft Access
  Database Engine (ACE 2007) driver names.
- All DSN **creation** is `#ifdef _WIN32` and goes through `SQLConfigDataSource` / `odbcinst.h`;
  on non-Windows `do_rdbi_init` is a no-op. That is why [the README says ODBC DSNs must be
  configured separately here](../README.md).
- The provider's own documentation describes the file-store use case as read-only over
  pre-existing tables, **point geometry only** (X/Y/Z columns), and — for Excel — tables that "must
  have at least one named range" —
  `Providers/GenericRdbms/Docs/doc_src/group_and_page_definitions/ODBC/define_pages.h`.

## Per-format reality on Linux

| Format | Linux ODBC driver? | Detail |
|--------|--------------------|--------|
| `.mdb` (MS Access) | **Yes** | `mdbtools` — packaged as `odbc-mdbtools` (Ubuntu 22.04 / Debian 12) or `mdbtools-odbc` (Fedora). Ships `libmdbodbc.so` + `libmdbodbcW.so`, registered as `[MDBTools]` / `[MDBToolsW]` with the `Database=<abs path>` keyword. **Read-only, forward-only cursor**; thin `SQLGetInfo`; write support is experimental; registration is manual (the package does not write `odbcinst.ini`). |
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
# /etc/odbcinst.ini  — register the driver
[MDBTools]
Description = MDB Tools ODBC driver
Driver      = /usr/lib/x86_64-linux-gnu/odbc/libmdbodbcW.so
FileUsage   = 1

# /etc/odbc.ini  — define the DSN
[MyAccessDb]
Driver = MDBTools
Database = /data/example.mdb
```

**`.mdb` — the one file format that can work.** Install `odbc-mdbtools` / `mdbtools-odbc`,
register the driver as above, then connect with `DataSourceName=MyAccessDb` (or
`ConnectionString=DRIVER={MDBTools};Database=/data/example.mdb`). Expect read-only, points-only
semantics; data-level writes are non-transactional and locking/timeouts are unsupported.

**`.xls` / `.xlsx` / `.dbf` / `.txt` / `.csv` — use the FDO GDAL/OGR provider instead.** These
formats are native OGR drivers (`CSV`, `ESRI Shapefile`/DBF, `XLS` via FreeXL, `XLSX`, and `MDB`
via mdbtools), and this build already enables both `OSGeo.Gdal.4.2` and `OSGeo.OGR.4.2`
(`--with-gdal --with-ogr`). That is the honest cross-format story on Linux, and the same
recommendation applies to MapGuide users.

## Bottom line

Present the ODBC provider on Linux as a **database connector** — and, narrowly, an `.mdb` reader.
Advertising a `.xls` / `.dbf` / `.txt` ODBC path there would promise something the platform cannot
deliver; point those users at GDAL/OGR.

> Package names, driver names and library paths above were as-observed against Ubuntu 22.04,
> Debian 12 and Fedora at the time of writing. Verify them against the target distro before relying
> on them.
