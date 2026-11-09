# A docker-driven build system for MapGuide and FDO

This is a docker-driven build system for MapGuide and FDO

# Requirements

 * A linux host OS that can run Docker
 * Git
 * Subversion

# Usage

## 1. Clone this repo and checkout MapGuide/FDO repositories

```
git clone https://github.com/jumpinjackie/mapguide-fdo-docker-build`
./svn_checkout.sh
```

## 2. Set up your desired target environment

Suppose you want to build MapGuide/FDO for Ubuntu 22.04 (64-bit)

```
./env_setup.sh --target fdo --distro ubuntu --tag 22.04 --cpu x64
./env_setup.sh --target mapguide --distro ubuntu --tag 22.04 --cpu x64
```

This will generate a series of `Dockerfile` and `snap.sh` build scripts in:

 * `docker/x64/fdo/ubuntu22/build`
 * `docker/x64/fdo/ubuntu22/develop_thin`
 * `docker/x64/fdo/ubuntu22/run`
 * `docker/x64/mapguide/ubuntu22/build`
 * `docker/x64/mapguide/ubuntu22/develop_thin`
 * `docker/x64/mapguide/ubuntu22/run`

The `--distro` and `--tag` parameters are composed into the base docker image from which our target environment is built on top of, so in the above example, our docker environment will ultimately be based from the `ubuntu:22.04` docker base image

A convenience `env_setup_all.sh` is provided that sets up the docker environments for all supported distros

The `--distro` and `--tag` combinations we currently recognise in this script are:

 * `ubuntu` and `22.04`
 * `generic` and no tag

The `generic` distro is a `rockylinux` container geared towards building MapGuide and FDO without any system-provided development libraries and allows for maximally portable linux binaries. This distro target also produces the "common libs subset" of MapGuide, whose `.so` binaries are bundled with a multi-platform .net API binding nuget package.

## 3. Run the build

Assuming you set up the target environment for Ubuntu 22.04 (64-bit), then to build FDO, run:

```
./build_thin.sh --target fdo --distro ubuntu --tag 22 --cpu x64
```

Once FDO is built, the tarballs will be copied to the top-level `artifacts` folder.

To build MapGuide, run:

```
./build_thin.sh --target mapguide --distro ubuntu --tag 22 --cpu x64
```

NOTE: You must build FDO first (and its SDK tarball present in `artifacts`) before you can build MapGuide.

A convenience `build_all_thin.sh` is provided that will build MapGuide/FDO for all supported distros

All MapGuide/FDO build containers are "thin" in the sense that source code and compiler output is not added to these docker images, only the development tools and libraries are added to the image. Source code and compiler output are read and written to directories referenced outside from the docker host via mounted volumes. Inside the container these are all mounted under `/tmp/work`:

 * `/tmp/work/src` is the source tree being built (the `fdo` checkout for FDO, `mapguide/MgDev` for MapGuide)
 * `/tmp/work/build_area` is the root of all intermediate compiler output
 * `/tmp/work/artifacts` holds the built SDK tarballs and packages
 * `/tmp/work/sdks` holds pre-downloaded SDKs such as the Oracle Instant Client

See [4. Inner-loop development and testing](#4-inner-loop-development-and-testing) for the complete list of mounted paths.

All MapGuide/FDO build containers also leverage the use of `ccache` to store their compilation output to a volume mounted ccache cache directory (the `/caches` sub-directory in this repo)

These 2 combined, result in a build pipeline that is very fast for builds after the first build, allowing for a rapid developer/iteration inner-loop.

## 4. Inner-loop development and testing

The build images are *thin*: they carry only toolchains and libraries, while source, compiler output and the `ccache` cache are read from and written to host-mounted volumes. This means you can keep a build container running, edit sources on the host, and rebuild incrementally instead of re-running a full non-interactive build for each change. This is the fastest way to iterate, and it lets you selectively run individual test suites after a build.

### 4.1 Drop into the build container

```
./build_thin.sh --target fdo --distro ubuntu --tag 22 --cpu x64 --interactive
./build_thin.sh --target mapguide --distro ubuntu --tag 22 --cpu x64 --interactive
```

Add `--debug` to work against a `Debug` (ASAN-instrumented) build. The interactive container mounts the same volumes as a non-interactive build and the version/build environment variables (`FDO_BUILD_CONFIG`, `FDO_DISTRO`, `FDO_VER*`, `MG_BUILD_CONFIG`, `MG_DISTRO`, `MG_VER*`) are already set.

Inside the container everything lives under `/tmp/work`:

| Path in container | Backing host directory | Purpose |
|---|---|---|
| `/tmp/work/src` | `fdo/` (FDO) or `mapguide/MgDev` (MapGuide) | source checkout |
| `/tmp/work/fdo_src` | `fdo/` | FDO source (MapGuide container only) |
| `/tmp/work/build_area` | `build_area/<cpu>/<config>/<distro_label>/<target>` | CMake/Ninja build output |
| `/tmp/work/artifacts` | `artifacts/<config>` | SDK tarballs and packages |
| `/tmp/work/sdks` | `sdks/` | Oracle Instant Client, etc. |
| `/tmp/work/patches` | `patches/` | scratch hand-over diffs (MapGuide container only, empty when the tree is settled) |
| `/tmp/work/scripts` | `templates/scripts/container` | build/test scripts |
| `/tmp/ccache` | `caches/<cpu>/<config>/<target>/<distro_label>/.ccache` | ccache cache |

The build directories created inside the container are:

 * FDO — `/tmp/work/build_area/fdo` (thirdparty dependencies under `/tmp/work/build_area/fdo_thirdparty`)
 * MapGuide — `/tmp/work/build_area/mapguide` (OEM dependencies under `/tmp/work/build_area/oem`)

### 4.2 Build by hand

Run the same scripts that a non-interactive build runs:

```
# FDO
/tmp/work/scripts/build_fdo.sh

# MapGuide (requires the FDO SDK tarball to already be present in /tmp/work/artifacts)
/tmp/work/scripts/build_mapguide.sh
```

> Distro-specific overrides (`build_fdo_<distro_label>.sh`, `build_mapguide_<distro_label>.sh`) take precedence over the generic scripts above.

Because sources, build output and ccache are all on mounted volumes, editing a file under `fdo/` or `mapguide/MgDev` on the host and re-running the script rebuilds only what changed. For an even tighter loop, drive the build directly. For FDO:

```
cd /tmp/work/build_area/fdo && cmake --build . --target install
```

MapGuide is not that simple: its build tree cannot build anything until the FDO SDK it was configured against is installed *in the container*, and the default `all` target drags in the web tier. Use [build_mapguide_incremental.sh](#44-the-mapguide-rapid-inner-loop) instead of a bare `cmake --build .`.

### 4.3 Run unit test suites

From the host, the wrapper scripts run the suites in a one-shot container and drop logs under `logs/test/`:

```
# Against the thin develop image (source and build tree are mounted from the host)
./env_test_thin.sh --target fdo --distro ubuntu22 --cpu x64
./env_test_thin.sh --target mapguide --distro ubuntu22 --cpu x64

# Against the non-thin build image (uses the build baked into the image)
./env_test.sh --target fdo --distro ubuntu22 --cpu x64
./env_test.sh --target mapguide --distro ubuntu22 --cpu x64
```

> `env_test_thin.sh` recreates an ad-hoc inner loop and can be flaky. When it misbehaves, run the same scripts inside an interactive container instead.

Or, inside the interactive build container:

```
# FDO
/tmp/work/scripts/run_fdo_tests.sh --log-path /tmp/work/artifacts/test-logs --fdo-build-dir /tmp/work/build_area/fdo

# MapGuide
/tmp/work/scripts/run_mapguide_tests.sh --log-path /tmp/work/artifacts/test-logs --mapguide-build-dir /tmp/work/build_area/mapguide
```

`run_fdo_tests.sh` always runs the Core/SDF/SQLite/OGR/GDAL/SHP suites and installs FDO first (`cmake --build . --target install`). It reports the elapsed time of the install step and of each suite, plus the total at the end of the run. The MapGuide runner drives `mgserver test <component>` for each component `mgserver test list` reports, with a 5 minute timeout per suite; [4.4](#44-the-mapguide-rapid-inner-loop) covers selecting individual suites and how the runner decides pass from fail.

`run_mapguide_tests.sh` runs the web tier suites too, which is the only way to run them: they need a running server, and the script owns that lifecycle. `--tier web` runs the C++ web tier runner and the PHP and Java binding suites, and `--tier all` runs those and the server suites in one go:

```
# Server suites (the default), web tier suites, or both
/tmp/work/scripts/run_mapguide_tests.sh --log-path /tmp/work/artifacts/test-logs --mapguide-build-dir /tmp/work/build_area/mapguide
/tmp/work/scripts/run_mapguide_tests.sh --log-path /tmp/work/artifacts/test-logs --mapguide-build-dir /tmp/work/build_area/mapguide --tier web
/tmp/work/scripts/run_mapguide_tests.sh --log-path /tmp/work/artifacts/test-logs --mapguide-build-dir /tmp/work/build_area/mapguide --tier all
```

Web tier output is namespaced under `<log-path>/webtier/`, so it sits beside the FDO and `mgserver` logs without colliding with them.

[4.6](#46-running-the-web-tier-test-suites) covers what each suite is and what the script does for it.

`run_fdo_tests.sh` points `NLSPATH` at the generated message catalogues in the build tree when the caller has not already set it, and echoes the value it ends up using. This matters because `env_test.sh`/`env_test_thin.sh` export `NLSPATH` themselves when they start the one-shot container, whereas a hand-run inside an interactive container has nobody to do it — and without it FDO falls back to raw message symbols (for example `FDOSM_220`) instead of resolved English text, which fails every test that asserts on message text (including `FdoApplySchemaTest::TestSchema`).

It also generates the system locales the SHP suite switches between (`en_US.iso88591`, `en_US.utf8`, `fr_FR.iso88591`, `ja_JP.eucjp`), and resets the generated SHP test data before that suite, because those tests create filesets with `IDF_CREATE_NEW` and a leftover from an earlier run fails a later one. The reset deletes `Providers/SHP/TestData` in the build area and copies the tree back from the FDO sources the build was configured against (the `CMAKE_HOME_DIRECTORY` entry in the build tree's `CMakeCache.txt`), so the suite always starts from the state a fresh build has. `TestData/clean`, the script the FDO sources ship, is only the fallback for when those sources cannot be located: it removes `*Generated.*`, `*.idx`, `schema.xml` and `Testing/`, but leaves `TestingSC/`, `InsertTest_default_values/` and the sidecars some tests create inside the shipped data directories behind. `InsertTests::insert_with_locale` calls `setlocale` without checking the result, so when a locale is missing the previous one stays in effect and the round-tripped value mismatches — the test then reports `incorrect street value` rather than naming the unavailable locale.

The FDO Core suite's log doubles as a LeakSanitizer report, because Debug builds are ASan/LSan-instrumented. A suite whose tests all pass but which does report leaks exits non-zero (LeakSanitizer's only way of drawing attention to the report), so `run_fdo_tests.sh` reports it as a pass with the leak totals printed underneath, for example:

```
Running suite: SDF
  >> Test Suite (SDF) passed! (elapsed 19s)
  >>   LeakSanitizer reported leaks: 55925 byte(s) leaked in 538 allocation(s). - see /logs/Sdf_unit_test_log.txt
  >>   (exit code 1 is the leak report, not a test failure)
```

A suite that has failures *and* leaks is still reported as an error: the runner reads the suite's log and only treats a non-zero exit as a leak report when the log shows a passing run. The leaks found in these suites, the ones deliberately left in place and the measurements behind them are tracked in [docs/fdo-core-memory-leaks.md](./docs/fdo-core-memory-leaks.md). The provider suites (`ODBC`, `PostGIS`, `MySQL`, `SQLite`, `GDAL`, `SHP`, `SDF`, `WMS`, `WFS`, `King Oracle`) report the same way; their fixes and remaining findings are tracked in [docs/fdo-provider-memory-leaks.md](./docs/fdo-provider-memory-leaks.md). How to read a report, the FDO ownership idioms behind most of these leaks and the instrumentation/verification loop are in [AGENTS.md](./AGENTS.md#debugging-memory-leaks-asanlsan).

#### Selecting FDO suites

Pass any of the following to `run_fdo_tests.sh` to enable the optional suites:

| Flag | Suite |
|---|---|
| `--with-postgis-init <file>` | PostGIS (`UnitTestPostGis initfiletest=<file>`) |
| `--with-mysql-init <file>` | MySQL (`UnitTestMySql initfiletest=<file>`) |
| `--with-odbc-init <file>` | ODBC (`UnitTestOdbc initfiletest=<file>`) |
| `--with-odbc-sqlserver [init file]` | ODBC SQL Server fixtures (`UnitTestOdbc initfiletest=<file> OdbcSqlServerTests`); the init file defaults to the shipped `OdbcSqlServerInit.txt` |
| `--with-odbc-access` | ODBC Access fixtures against mdbtools (`UnitTestOdbc OdbcAccessTests`, with the driver's own leaks suppressed by `templates/scripts/container/lsan/odbc-mdbtools.supp`) |
| `--with-oracle` | King Oracle (`UnitTest`) |
| `--with-wms` | WMS |
| `--with-wfs` | WFS |

The `*-init` suites only run when the supplied file exists, so simply omit the flag to skip them.

`--with-wms` and `--with-wfs` are off by default: they query live public OGC services over the network and assert against the shape of those services, so a service that has changed on the provider's side fails them.

The FDO Core, SDF, SQLite, OGR, GDAL and SHP suites always run by default. Skip any of them individually, or all of them at once, with:

| Flag | Effect |
|---|---|
| `--without-fdocore` | Skip the FDO Core suite |
| `--without-sdf` | Skip the SDF suite |
| `--without-sqlite` | Skip the SQLite suite |
| `--without-ogr` | Skip the OGR suite |
| `--without-gdal` | Skip the GDAL suite |
| `--without-shp` | Skip the SHP suite |
| `--no-default-suites` | Skip all of the above at once |

Each of those six also has a `--with-*` counterpart (`--with-fdocore`, `--with-sdf`, `--with-sqlite`, `--with-ogr`, `--with-gdal`, `--with-shp`) to turn it back on, so a single default suite can be run on its own.

If the resulting selection is empty (for example `--no-default-suites` with no `--with-*` opt-in), the script exits with an error rather than silently running nothing. A `--with-*-init` path that does not exist is reported as a warning and its suite is skipped.

Container-ready init files are kept in `templates/scripts/container/test_init/`, which is mounted into the build container at `/tmp/work/scripts/test_init/` (and at `/scripts/test_init/` in the `env_test*.sh` one-shot containers). For example, to run *only* the PostGIS suite against the `dbs` compose stack:

```
/tmp/work/scripts/run_fdo_tests.sh --log-path /tmp/work/artifacts/test-logs --fdo-build-dir /tmp/work/build_area/fdo \
    --no-default-suites --with-postgis-init /tmp/work/scripts/test_init/PostGisInit.txt
```

The same applies to the default suites; to run only the SHP suite (useful while iterating on it, since the runner still installs FDO and resets its test data first):

```
/tmp/work/scripts/run_fdo_tests.sh --log-path /tmp/work/artifacts/test-logs --fdo-build-dir /tmp/work/build_area/fdo \
    --no-default-suites --with-shp
```

To run *every* suite the runner supports in one go — the six defaults, WMS, WFS and King Oracle, the
three database suites through the shipped init files, and the ODBC provider's SQL Server and Access
fixtures:

```
/tmp/work/scripts/run_fdo_tests.sh --log-path /tmp/work/artifacts/test-logs --fdo-build-dir /tmp/work/build_area/fdo \
    --with-wms --with-wfs --with-oracle \
    --with-mysql-init /tmp/work/scripts/test_init/MySqlInit.txt \
    --with-postgis-init /tmp/work/scripts/test_init/PostGisInit.txt \
    --with-sqlserver-init /tmp/work/scripts/test_init/SqlServerSpatialInit.txt \
    --with-odbc-sqlserver /tmp/work/scripts/test_init/OdbcSqlServerInit.txt \
    --with-odbc-access
```

The one suite that command leaves out is `--with-odbc-init`, which needs an ODBC datastore's own init
file — none ships, so it only runs against a configuration you have prepared.

The PostGIS, MySQL, SQL Server and King Oracle suites need the `dbs` compose stack running first, as does the ODBC SQL Server suite (`--with-odbc-sqlserver`, whose init file defaults to the shipped `OdbcSqlServerInit.txt` pointing at `mssql_cs`; give it a path, as above, to run against a different server). The ODBC Access suite runs on Linux against the mdbtools driver (`--with-odbc-access`; the Ubuntu develop image installs `odbc-mdbtools`, and no DSN is needed). The Excel/dBase/Text ODBC fixtures still need drivers that only exist on Windows, so `--with-odbc-init <file>` is for a configuration you have prepared yourself. WMS and WFS need outbound network access to the public OGC services they test against. `--with-sqlserver-perf` runs the SQL Server suite with `FDO_SQS_PERF=1`, which opts into the provider's memoised `SQLDescribeParam()` and cached database-object catalog; over four SQL Server fixtures that cut `SQLDescribeParam` calls by ~73% and wall-clock time from 82 s to 34 s, with every fixture still `OK` and no change in the LSan record count. See [docs/sqlserver-spatial-linux-support.md](./docs/sqlserver-spatial-linux-support.md#the-fdo_sqs_perf1-opt-in-measured).

These are derived from the reference copies in the FDO source tree at `fdo/Providers/GenericRdbms/Src/UnitTest/`; only edit the SVN copies if you need a different configuration. The `service=` entry is the database host (`[dbname@]host:port`).

#### Running a single test binary

You can drive a unit test binary directly, which is the fastest way to iterate on one suite:

```
cd /tmp/work/build_area/fdo/Providers/GenericRdbms/Src/UnitTest
export NLSPATH=/tmp/work/build_area/fdo/nls/linux/en_US/%N
./UnitTestPostGis initfiletest=/tmp/work/scripts/test_init/PostGisInit.txt FdoConstraintsTest
```

- Run the binary from its own directory. Each unit test directory has a local `providers.xml`, which FDO reads from the **binary's** directory (`FdoRegistryUtility::GetFileName()` probes next to the executable, never the working directory), so a suite loads the provider it was built against. The GDAL and SHP suites are the exception: their local copy does not work and has to be deleted (`rm providers.xml`), which sends them to the installed registry; loading a provider from anywhere else fails with `CLNT_8_UNABLE_TO_LOAD_LIBRARY`.
- Export `NLSPATH` pointing at the generated message catalogues in the build tree, exactly as `run_fdo_tests.sh`, `env_test.sh` and `env_test_thin.sh` do. Without it, tests that assert on error message text see the raw message symbol (for example `FDOSM_220`) instead of the resolved English text and fail — which is easy to misread as a regression from the change under test (in the OGR suite it is `TestCase_EvalQuotedIdentifier`, `TestCase_SelectBadReaderProperties` and `TestCase_SelectAggregateBadReaderProperties`).
- The GDAL and SHP suites also need FDO installed at `/usr/local/fdo-4.2.0` (`cmake --build . --target install`).
- SHP needs two extra things the runner does for you. Its locale test only works if the locales it switches between exist (`locale-gen en_US en_US.UTF-8 fr_FR ja_JP.EUC-JP`), and its tests create filesets under `Providers/SHP/TestData` and open them with `IDF_CREATE_NEW`, so leftovers from an earlier run fail the next one — delete that whole `TestData` tree in the build area and copy it back from the sources (`cp -a <fdo sources>/Providers/SHP/TestData Providers/SHP/`) rather than relying on `sh ../../TestData/clean`, which is the shipped script but only removes some of what a run leaves behind.
- The optional positional argument is a CppUnit registry name (`FdoConstraintsTest`, `FdoApplySchemaTest`, `DescribeSchemaTest`, ...); omit it to run everything. Arguments of the form `key=value` are exported as environment variables for the run.

### 4.4 The MapGuide rapid inner loop

`build_mapguide.sh` (and its `build_mapguide_ubuntu22.sh` / `build_mapguide_generic.sh` overrides) is an end-to-end build: it re-installs the FDO SDK, re-runs `cmake_bootstrap.sh` and `cmake_linuxapt.sh`, builds the web tier (httpd/PHP/Tomcat) and packages a `.deb` plus the release tarball. None of that helps while iterating on server, common or geometry code, so MapGuide has a script for the inner loop:

```
/tmp/work/scripts/build_mapguide_incremental.sh
```

It does three things and nothing else:

1. **Installs the FDO SDK the build tree was configured against.** The install lives in the container, not on the host, so a fresh interactive container does not have it — and a MapGuide build tree cannot build a single target without it. `ninja` stops immediately with `'/usr/local/fdo-4.2.0/lib64/libExpressionEngine.so', needed by 'Common/Stylization/libMgStylization-4.0.0.so', missing and no known rule to make it`. The SDK tarball is stamped into the install directory, so a rebuilt tarball (a fresh FDO build) is re-installed and an unchanged one is skipped. `atomic.h` is copied to `/usr/include/asm` only when its contents changed, because re-stamping it would rebuild every translation unit that includes it.
2. **Builds `mgserver` and `MgUnitTesting` incrementally** — the server executable and the unit-test library. Everything under `Common/` and `Server/` is a dependency of one of them, and `ninja` re-runs CMake by itself when a `CMakeLists.txt` changes, so adding or removing a source file needs no extra step.
3. **Reports how long it took.** A no-op run builds nothing (`ninja: no work to do`) and takes a second; editing `Common/Geometry/Geometry.cpp` costs a recompile plus the dependent relinks (~5s).

| Flag | Effect |
|---|---|
| `--target <name>` | Build a different target (repeatable). `--list-targets` prints the valid names. |
| `--install` | Install the current build output afterwards (`cmake --install .`), which is what the installer/smoke-test path needs. |
| `--prepare` | Only install the FDO SDK and `atomic.h`, then stop. |
| `--skip-prepare` | Leave the FDO SDK alone and just build. |
| `--reinstall-fdo` | Re-extract the FDO SDK even if it is up to date. |
| `--fdo-sdk <tarball>` | Install a named SDK tarball instead of the one `build_thin.sh` picked. |
| `--jobs <n>` | Limit build parallelism. |

The script never configures from scratch: it needs the CMake build tree that a full build created, and reconfiguring is the full script's job because it owns `cmake_bootstrap.sh`/`cmake_linuxapt.sh` and the OEM tree (`oem/env_vars.sh`) the configuration depends on.

The default targets do not cover the web tier. An edit under `Web/` needs `--target mod_mgmapagent-4.0.0` (or `mgdevhttpserver`, `MgWebApp-4.0.0`, ...), and to exercise it through Apache/PHP, `--install`.

A session on a host that has already run a full build:

```
# once: build FDO, build MapGuide, then drop into the container
./build_thin.sh --target fdo --distro ubuntu --tag 22 --cpu x64
./build_thin.sh --target mapguide --distro ubuntu --tag 22 --cpu x64
./build_thin.sh --target mapguide --distro ubuntu --tag 22 --cpu x64 --interactive

# inside the container, after each edit
/tmp/work/scripts/build_mapguide_incremental.sh
/tmp/work/scripts/run_mapguide_tests.sh --log-path /tmp/work/artifacts/test-logs \
    --mapguide-build-dir /tmp/work/build_area/mapguide --component RenderingService
```

Add `--debug` to `build_thin.sh` to iterate on the ASan/LSan-instrumented tree instead. Debug and Release are separate containers and separate build trees — never install or copy a library between them.

#### Selecting MapGuide suites

`run_mapguide_tests.sh` runs every component suite by default, in the order `mgserver test list` reports them (23 of them, including `CoordinateSystem` and `DrawingService`). `--component <name>` narrows that to the suites you are iterating on, and `--list-components` prints the names:

```
/tmp/work/scripts/run_mapguide_tests.sh --mapguide-build-dir /tmp/work/build_area/mapguide \
    --component RenderingService --component Stylization
```

`--timeout` changes the per-suite timeout (default `5m`, `none` disables it), and the whole run exits non-zero if any suite failed, so it works as a gate.

`--component all` is the other way round: it hands `all` to `mgserver`, which runs every suite in **one** process — the run upstream's `run_tests.sh` performs, and the first entry `mgserver test list` prints. The trade is that the whole set shares one log, one exit status and one pass/fail line, so you learn *that* something failed but not which suite; the per-component loop above keeps a log and a `UnitTestResults_<component>.xml` per suite. Because `5m` is a per-suite budget and `all` is longer than any one suite, an `all` run has no timeout at all unless you pass `--timeout` (the runner says so when it starts). Note that `mgserver test list` describes `all` as "Excluding Performance", but the suite list in `Server/src/UnitTesting/UnitTesting.cpp` includes `[Performance]`, so it does run it.

Ctrl-C stops the suite that is running instead of the run carrying on to the next component. Each suite runs under `timeout` in its own process group, which a terminal Ctrl-C never reaches, so the runner signals that group itself and escalates to `SIGKILL` after 5s — `mgserver` can wedge in exit-time teardown. The interrupted suite is reported as `interrupted` rather than failed, the remaining components are skipped, and the run exits 130 (`docker stop` and a dropped tty behave the same way, exiting 143 and 129).

Two environment facts the runner handles for you, both of which look like something else when they are missing:

- It sets `LD_LIBRARY_PATH` to the build tree's `Server/src/Core` and `Server/src/UnitTesting` plus the FDO `lib64`. `mgserver` `dlopen()`s `libMgUnitTesting.so` by bare name, and the providers recorded in `providers.xml` are bare names too — and `dlopen()` searches `DT_RPATH` and `LD_LIBRARY_PATH`, never `DT_RUNPATH`, so `mgserver`'s own RUNPATH does not help. Without the FDO entry every suite that opens a feature source fails in `MgFdoConnectionManager.Open()` with `CLNT_8_UNABLE_TO_LOAD_LIBRARY`.
- If the container has no FDO SDK installed yet it installs it first (via the incremental build script's `--prepare`), so a one-shot `env_test_thin.sh` run works from a clean container.

A suite is judged by the Catch2 assertion summary it printed, not by the process exit code, because the exit code is misleading in two ways:

- Debug runs are ASan/LSan-instrumented. A suite whose tests all pass but which leaks exits 1 to report the leak — LeakSanitizer's only way of drawing attention to it — so the runner reports it as a pass and prints the totals underneath, exactly as `run_fdo_tests.sh` does for the FDO suites:

```
Running suite: Geometry
  >> Test Suite (Geometry) passed! (elapsed 2s)
  >>   LeakSanitizer reported leaks: 21632 byte(s) leaked in 263 allocation(s). - see /mapguide_Geometry_unit_test.log
```

- A passing run can also die or wedge in exit-time teardown after the summary has been printed. That is reported as a pass with a note pointing at [docs/fdo-exit-teardown.md](./docs/fdo-exit-teardown.md), not as a test failure.

One suite fails for a reason that is in the test code rather than the build: `LogManager`'s `EnumerateLogs` and `RenameLog` cases assert `logs->Contains(<property>)`, and `MgPropertyCollection::Contains(const MgProperty*)` ends in `MgDisposableCollection::Contains`, which compares pointers, so a freshly constructed property never matches. They fail in every build configuration; do not read them as a regression from a change in the tree.

#### Checking the reactor path (`--run-mode`)

Every `mgserver test <component>` run executes an `MgTestCommand`, so `MgServer::svc()` returns before it reaches its accept handlers, the client/admin/site operation-thread pools and `ACE_Reactor::run_reactor_event_loop()`. None of the server unit test cases therefore covers the path a *real* server takes, and the installer smoke test in `mapguide_smoke_test.sh` needs a packaged `.run` to get at it. The build tree can run the real thing directly, so the runner has a mode for it:

```
/tmp/work/scripts/run_mapguide_tests.sh --mapguide-build-dir /tmp/work/build_area/mapguide \
    --log-path /tmp/run-logs --run-mode
```

It starts `./mgserver run` from the build tree (the tree's own `serverconfig.ini`, so the client port is 2811 unless you changed it), waits for that port to accept, sends `SIGTERM`, and requires that the process

- exits 0 within `--shutdown-timeout` (default 30s) — a thread that never leaves its `getq()` loop shows up here as `Server did not exit within Ns of SIGTERM`, not as a hang;
- reaches `Server stopped` in its log, and
- prints no LeakSanitizer summary.

`--startup-timeout` (default 60s) covers the wait for the port. The run takes about as long as the two waits, because the server starts in a second or two and stops in about the same. It fails fast if any of the three ports is already listening, so a stray `mgserver` is reported rather than silently tested instead of the build. It is not a substitute for the installer smoke test — it does not exercise the packaged layout, the web tier or the PHP binding — but it is the only check that covers the reactor path without packaging anything, and it is where a shutdown-ordering regression (or a leak in the threads teardown leaves behind) shows up.

#### Running one MapGuide suite by hand

Same thing, without the wrapper:

```
cd /tmp/work/build_area/mapguide/Server/src/Core
LD_LIBRARY_PATH=$PWD:$PWD/../UnitTesting:/usr/local/fdo-4.2.0/lib64 \
    ./mgserver test RenderingService /tmp/UnitTestResults_RenderingService.xml
```

The second argument is where the JUnit XML result goes; omit it and nothing is written. The build tree's `serverconfig.ini`, `Resources/`, `Schema/`, `UnitTestFiles/` and the `libMgUnitTesting.so` symlink are all generated by CMake configure, which is why a suite runs from the build tree without installing MapGuide first.

### 4.5 Database-backed tests

Some FDO suites (PostGIS, MySQL, ODBC, Oracle) need a live database. Start the required services from the `dbs` compose fixtures, for example:

```
docker compose -f dbs/docker-compose.yml up -d postgis_pg16 mariadb oracle_xe_11g mssql_cs
```

> The whole stack cannot be started at once: several services publish the same host port (`5432` for the PostGIS variants, `3306` for the MariaDB/MySQL variants). Start one service per port. The two SQL Server fixtures are the exception — `mssql` (1433) and `mssql_cs` (1434) sit on different ports on purpose, so the Windows and Linux SQL Server Spatial suites can each have their own instance at the same time; see the collation note below for why that matters.

> Each fixture keeps its database files in its own directory under [dbs/data](./dbs/data/README.md), so they outlive the container: `mariadb` → `dbs/data/mariadb`, `mysql_80` → `dbs/data/mysql_80`, `postgis_pg16` → `dbs/data/postgis_pg16`, and so on. That means recreating a container no longer gives you an empty database — delete the service's directory for that. Under rootless podman the directory is owned by the container's database user, so the delete has to go through the user namespace: `podman unshare rm -rf dbs/data/mysql_80`. `oracle_xe_11g` has no directory because its image ships a pre-built database that a bind mount would hide.

> The `mysql_56` service pins a case-sensitive (`latin1_bin`) collation, because FDO class and schema names are case-sensitive while a datastore created without an explicit collation inherits the server's (case-insensitive) default. With a case-insensitive server, the unique index on `f_classdefinition(classname, schemaname)` rejects two classes whose names differ only in case, and `FdoApplySchemaTest::TestSchema` fails with `Duplicate entry 'aCxdATA-Acad' for key 'f_classdef_schnm_idx'`. A datastore created before this was pinned keeps its old collation until it is dropped and recreated (the FDO suites recreate their own datastores). MariaDB and MySQL 8.0 would need their own `--collation-server=*_bin` equivalent if they are ever held to the same standard.

The database containers run on their own compose network, separate from the build container, so reach them through their published ports via the host rather than by container name or `localhost`. The ready-made init files in `templates/scripts/container/test_init/` already point at the compose stack through `host.docker.internal:<port>`:

 * `PostGisInit.txt` → `service=host.docker.internal:5432`
 * `MySqlInit.txt` → `service=host.docker.internal:3306`
 * `SqlServerSpatialInit.txt` → `service=host.docker.internal,1434`, the `mssql_cs` fixture (a comma before the port, as SQL Server's `SERVER=` keyword expects)

The SQL Server suite also needs the *Microsoft ODBC Driver for SQL Server* — the FDO build only ever installs the unixODBC **driver manager**. The `develop_thin` images install driver 18 (`msodbcsql18`), so a container made by `build_thin.sh` needs nothing else; install it yourself in a container that predates that:

```
wget -q https://packages.microsoft.com/keys/microsoft.asc -O- | gpg --dearmor > /etc/apt/trusted.gpg.d/microsoft.gpg && \
wget -q https://packages.microsoft.com/config/ubuntu/22.04/prod.list -O /etc/apt/sources.list.d/mssql-release.list && \
apt-get update && ACCEPT_EULA=Y apt-get install -y msodbcsql18
```

`FDO_SQLSERVER_ODBC_DRIVER` overrides the driver name the provider looks up; without it the provider uses the newest Microsoft ODBC Driver for SQL Server that is registered, so driver 18 when it is installed and driver 17 otherwise. What the provider needed to become portable, and the defects that had to be fixed for it — an `RDBI_INT` column sized as `sizeof(long)`, `nvarchar(max)` values read as raw UTF-16, an `SQLParamData` token that clobbered the adjacent byte count, and a wide-format `%s` — are in [docs/sqlserver-spatial-linux-support.md](./docs/sqlserver-spatial-linux-support.md). The complete inventory of environment variables FDO and its providers read — `FDO_TRACE_FILE`, `FDO_SQS_PERF`, `FDO_SQLSERVER_ODBC_DRIVER`, `SDF_MAXCACHESIZE`, `FDOHOME`, and the variables inherited from GDAL/OGR, libcurl, libpq, libmysqlclient and unixODBC — is in [docs/fdo-environment-variables.md](./docs/fdo-environment-variables.md).

> The SQL Server instance needs a **case-sensitive** collation, for the reason described for `mysql_56` above: FDO class and schema names are case-sensitive, and a datastore created without an explicit collation inherits the server's. With the image's default (`SQL_Latin1_General_CP1_CI_AS`) the unique index on `f_classdefinition(classname, schemaname)` rejects two classes whose names differ only in case, and `FdoApplySchemaTest` fails with `Cannot insert duplicate key row in object 'dbo.f_classdefinition' with unique index 'f_classdef_schnm_idx'. The duplicate key value is (aCxdATA, Acad)`. Changing the *model* database's collation makes every datastore the suites create inherit it. The `mssql_cs` fixture pins it when the server is **created** (`MSSQL_COLLATION=Latin1_General_CS_AS`), which is the only point at which SQL Server honours it, and the shipped init file already points at that fixture; on an existing instance:

```
docker exec dbs_mssql_1 /opt/mssql-tools/bin/sqlcmd -S localhost -U sa -P 'Sql2016!' \
    -Q "ALTER DATABASE model COLLATE Latin1_General_CS_AS"
```

Datastores created before the change keep their old collation, so drop them (the suites recreate their own datastores) — and note that a failed apply leaves an open transaction behind, which makes later fixtures slow or stuck until the connection is closed.

If the `ALTER DATABASE model` route is refused while the database is in use, the reliable way with the fixture's own image is to create a *fresh* server with the collation already set, which SQL Server 2017 does honour (`Attempting to change default collation to Latin1_General_CS_AS` appears in its startup log):

```
podman run -d --name sqs_cs -e ACCEPT_EULA=Y -e SA_PASSWORD='Sql2016!' \
    -e MSSQL_COLLATION=Latin1_General_CS_AS -p 1434:1433 \
    mcr.microsoft.com/mssql/server:2017-latest
```

Then point an init file at `service=host.docker.internal,1434`, which is what the shipped `SqlServerSpatialInit.txt` already does. Two further things are worth knowing before you read a failure as a regression. A datastore written by a build older than the locale fix holds mangled non-ASCII identifiers (a column stored as `prÃ¶vince` instead of `prövince`), so drop it — `ALTER DATABASE fdo_root SET SINGLE_USER WITH ROLLBACK IMMEDIATE; DROP DATABASE fdo_root;` — and re-run; `datastore=<name>` on the command line does not move the suite to a fresh datastore. And a case-sensitive collation is **necessary but not sufficient**: with it, `FdoApplySchemaTest` reports `Run: 5   Failure total: 1` — the duplicate-key failure is environmental and goes away, and what remains is a master-file comparison of the generated schema, which is a provider-versus-test-data question rather than an environment one. Both are written up in [docs/sqlserver-spatial-linux-support.md](./docs/sqlserver-spatial-linux-support.md#known-issues).

The King Oracle suite takes no init file. `run_fdo_tests.sh` points it at the compose stack instead, setting the `KG_ORA_SERVICE`, `KG_ORA_USERNAME`, `KG_ORA_PASSWORD` and `KG_DEFAULT_ORA_CONNECTION` environment variables that the FDO sources document (see `CMake__README.txt` under the King Oracle provider) to `//host.docker.internal:1521/xe` as `fdounittest`. Anything already exported in the environment wins, so another Oracle instance can still be targeted. `fdounittest` is created by the `oracle_xe_11g` service itself: it mounts the suite's `ora_init.sql` into the image's `/docker-entrypoint-initdb.d/`, which runs it as SYS on startup.

`host.docker.internal` works under Podman and Docker Desktop, and under Docker on Linux when the container is run with `--add-host=host.docker.internal:host-gateway`; Podman also provides the native alias `host.containers.internal`. To target a different host, edit the `service=` value in the file.

> ODBC DSNs must be configured separately on Linux, as the dynamic DSN setup in the FDO sources is Windows-only. The SQL Server fixtures do not need a DSN (they use the `DRIVER=...` connection string) and run with `--with-odbc-sqlserver`; the Access fixtures build a `DRIVER={MDBTools};DBQ=...` string and run with `--with-odbc-access`. The remaining file-based fixtures (Excel/dBase/Text) still need drivers that only exist on Windows. What the provider can and cannot open on Linux — the mdbtools read-only and SQL-parser limits, and why the `.xls`/`.dbf`/`.txt` story has no Linux equivalent of the Windows Access Database Engine — is in [docs/odbc-linux-support.md](./docs/odbc-linux-support.md).

### 4.6 Running the web tier test suites

The web tier is the part of MapGuide that a client talks to: the mapagent HTTP handlers and the
language bindings that sit on top of them. Its suites live in the source tree as
`Web/src/WebTestRunner` (a Catch2 binary) and `Bindings/src/Test/{Java,Php}` (the binding test
runners), and they all have the same problem: each one drives a *running* MapGuide Server, so
"run the tests" means start a server, set half a dozen environment variables, run the suite and
shut the server down again — per suite, because the binding suites leave resources behind.

`run_mapguide_tests.sh --tier web` does all of that, for every suite:

```
/tmp/work/scripts/run_mapguide_tests.sh --mapguide-build-dir /tmp/work/build_area/mapguide \
    --log-path /tmp/work/artifacts/test-logs --tier web
```

`--log-path` is the same mounted log root [4.3](#43-run-unit-test-suites) points the FDO and
`mgserver` suites at, so a web tier run writes *beside* their logs rather than into the container's
throw-away current directory (which is what the option defaults to). Everything it produces — the
per-suite logs, each suite's server log, the ant build log and the staged test pack — goes under
`/tmp/work/artifacts/test-logs/webtier/`, which is `artifacts/<Release|Debug>/test-logs/webtier/` on
the host (`artifacts/**` is gitignored), so the logs outlive the container.

| Suite | What it runs | Needs |
|-------|--------------|-------|
| `webtestrunner` | `Web/src/WebTestRunner`, the in-process Catch2 tests over the mapagent HTTP handlers | the build tree (target `MgWebTestRunner`) |
| `java` | `Bindings/src/Test/Java`, built with ant into `MgUnitTest.jar` | ant, java, `MapGuideApi.jar` and `libMapGuideJavaApi.so` from the install |
| `php` | `Bindings/src/Test/Php`, `RunTests.php` | the PHP 8.3 interpreter *and* the MapGuide extension from the install |
| `dotnet` | `Bindings/src/Test/DotNet` (the `net6.0` runner), built with `dotnet build` | the .NET SDK and the pinned SWIG; the `lib*UnmanagedApi.so` glue, which the script builds |

`webtestrunner` also carries the OGC template engine's own self-test: in a Debug build,
`Wms_GetCapabilities_OgcServerSelfTest` asks the WMS service for `VERSION=REGRESS`, which selects
`server/Wms/REGRESS.xml.awd`, and fails unless the template reports every one of its checks as
`<Success/>`. The case is compiled out of Release, where the `REGRESS` version hook does not exist
(see [docs/mapguide-ogc-pipeline-and-template-engine.md](./docs/mapguide-ogc-pipeline-and-template-engine.md#33-version-negotiation)).

What it does before each suite runs, which is what used to be manual:

1. **Installs the build tree into its install prefix when the web tier artifacts are missing**
   (`MG_INSTALL_PREFIX` from the build tree's `CMakeCache.txt`, normally
   `/usr/local/mapguideopensource-4.0.0`). The PHP extension, the Java glue library and the API jar
   are only ever built as part of the web tier, and `build_mapguide_incremental.sh` builds neither,
   so the script builds those targets and runs `cmake --install .` itself. `--no-install` turns
   that off and reports what is missing instead.
2. **Stages a test pack** under `<log-path>/webtier/testpack` — a copy of `UnitTest/TestData`, of
   `Bindings/src/Test/Php`, and the `Sheboygan.mgp` package, which `UnitTest/TestData` ships the
   sources for but not the archive. The suites write the sqlite fixtures they generate next to the
   `.dump` files, so they get a copy: the SVN working copy stays clean.
3. **Copies the WFS/WMS service documents into the build tree.** `serverconfig.ini` points
   `WfsDocumentPath`/`WmsDocumentPath` at `<build>/Server/src/Core/{Wfs,Wms}`, but nothing in the
   build populates them: `Server/src/Core/CMakeLists.txt` copies `Resources` and `Schema` into the
   build tree, while `Server/src/CMakeLists.txt` only *installs* the two document directories, to
   `<prefix>/server/{Wfs,Wms}` for an installed server. A server run out of the build tree without
   them answers every WFS and WMS request with
   `The specified file was not found: <build>/Server/src/Core/Wfs/OgcWfsService.config.awd`, which
   is exactly what the `Wfs_*` and `Wms_*` cases assert on. The script copies
   `Server/src/{Wfs,Wms}/*.awd` there before any server starts (and before `--run-mode`), touching
   only files whose content differs, so a repeat run is silent.
4. **Starts the server, runs the suite, stops the server**, and judges the shutdown the way
   `--run-mode` does — exit 0, `Server stopped` in the log, no LeakSanitizer summary. A suite only
   passes if the server also shut down cleanly. Each suite gets its own server log
   (`<log-path>/webtier/mapguide_server_<suite>.log`).
5. **Exports what the suites expect**: `MENTOR_DICTIONARY_PATH`, `MG_TEST_DATA_PATH`,
   `MG_TEST_WEBCONFIG_PATH` and `LC_CTYPE=C.UTF-8`, from the install and the staged pack.

A suite is judged by the summary it prints, not by its exit code: the binding runners print
`Tests failed/run: <failed>/<run>` as their last line and exit with the failure count, and a run
that aborts before printing it (a PHP fatal error, for instance) is a failure. `--web-suite` picks
individual suites; naming one makes its prerequisites required, while `--web-suite all` (the
default) skips what this install cannot run and lists it under `Skipped suites`.
`--reset-repository` deletes the server's `Repositories` directory before the run, which is the only
way to get a pristine server without recreating the container; the suites are otherwise designed to
clean up after themselves.

### 4.7 Building and testing MgPortable

MgPortable is the portable (console/desktop) MapGuide API. It is off by default and is enabled with
`-DWITH_PORTABLE=TRUE` (or `cmake_build.sh --with-portable`). It is built by the **common-libs
subset** tree, not the full build, because that is where the portable NuGet package's native libs
are collected: MgPortable links `MgGwsCommon`/`MgGwsQueryEngine` and the DWF Toolkit, so a
portable-enabled common-subset tree also builds `Server/src/Gws` and `Oem/DWFTK`.

`build_mapguide_generic.sh` enables it for the common-subset pass and emits two tarballs into
`artifacts/<conf>/`:

| Tarball | Contents |
|---------|----------|
| `mapguideopensource-common-<ver>-generic-linux-amd64.tar.gz` | unchanged; `portable/` is excluded |
| `mapguideopensource-portable-<ver>-generic-linux-amd64.tar.gz` | `Platform.ini` prepared for the tarball layout, `lib64/` with `libMgPortable*`, `libPortableUnmanagedApi.so`, the GWS libs and the Mg libraries MgPortable links, plus a top-level `fdo/` with the whole FDO install (`fdo/lib64` = `libFDO`, `libExpressionEngine`, every provider, `providers.xml`, `com/`, and for `generic` the gdal/xerces/xalan the FDO SDK bundles; `fdo/nls` = the message catalogues) |

In Release every library in both tarballs is stripped. Nothing in the thin path runs
`strip_mapguide_binaries.sh` (only the build image does), so the common-subset install is stripped
in `build_mapguide_generic.sh` before either tarball is cut from it — the common tarball goes from
~83 MB to ~12 MB, and the portable one from ~125 MB to ~39 MB. A Debug tarball keeps its symbols.
`cmake --install --strip` is not enough on its own: it only sees `install(TARGETS)`, so the OEM
copies that arrive through `install(FILES)` (`libACE`, `libxerces-c`, `liblib_json`) keep their
symbol tables.

Everything MgPortable owns installs under `<prefix>/portable/lib64`, which is what lets the common
tarball exclude it as a single subtree. The DWF Toolkit is static and ends up inside
`libMgRenderers`/`libMgPortable`, so it has no files of its own in the tarball.

The portable tarball contains no symbolic links. It is overlaid into the NuGet package on Windows,
and NuGet copies a link as a full duplicate of the file it points at, so
`build_mapguide_generic.sh` stages one real file per library: it drops the unversioned developer
names from `lib64/` (the only P/Invoked library, `libPortableUnmanagedApi.so`, is itself a real
unversioned file, and every `DT_NEEDED` in the tree names a versioned soname), rewrites
`providers.xml` to name each provider by its versioned soname, and renames the bundled gdal/xalan
libraries to the sonames the loader asks for (`libgdal.so.20`, `libxalan-c.so.111`,
`libxalanMsg.so.111`). It also leaves out `libFDO.so`, which
`MgPortablePlatform::Initialize()` dlopens by name: the package's `build/OSGeo.MapGuide.Portable.targets`
recreates it on Linux as `FDO/lib64/libFDO.so` linked to the flat `libFDO-<ver>.so` it stages beside
the application. A copy there would be a second FDO instance — the glue has already loaded the flat
one through its `$ORIGIN` RUNPATH — and two instances crash when their static destructors run.

The portable tarball carries FDO rather than depending on `/usr/local/fdo-4.2.0` on the machine that
consumes it, so it is self-contained once unpacked, and keeps it in one `fdo/` subtree so a consumer
can lift FDO out as a unit. That works because the FDO install is relocatable: every FDO library (and
the gdal/xerces/xalan copies the `generic` SDK bundles) is linked with `$ORIGIN` as its runtime path,
`providers.xml` sits beside `libFDO`, and a provider registered there is loaded from that same
directory — nothing has to be on `LD_LIBRARY_PATH`, and `FDOHOME` is not needed. The MapGuide
libraries that use FDO (`libMgPortable`, `libPortableUnmanagedApi`, `libMgGwsCommon`,
`libMgGwsQueryEngine` and `libMgStylization`) carry `$ORIGIN:$ORIGIN/../../lib64:$ORIGIN/../fdo/lib64`
as their runtime search path (`MG_PORTABLE_INSTALL_RPATH`), so they find FDO in `fdo/lib64` in the
tarball and in `<prefix>/lib64` in an install tree. `libMgRenderers` is not in that set: it only
renders and uses no FDO symbol, matching its Windows project, which imports none — and since
`MgStylization` declares FDO as a `PRIVATE` dependency, nothing is inherited, so the Linux library
carries no `DT_NEEDED` entry for FDO either. Keep the `lib64` directory name inside `fdo/`: FDO's fallback
for `providers.xml` is `$FDOHOME/lib64/providers.xml`, then `$FDOHOME/lib/providers.xml`, and only
then the compiled-in prefix (a stray `/usr/local/fdo-4.2.0` on the target would win over a bundled
tree that cannot be found one of those ways). `fdo/nls` carries the message catalogues, and
`MgPortablePlatform::Initialize()` locates them itself: it derives `<fdo root>/nls` from `FdoPath`
(and, for a build tree, `<fdo root>/nls/linux/en_US`; and `<FdoPath>/nls` for a flattened tree) and
prepends whichever exist as `<dir>/%N` patterns to any `NLSPATH` already in the environment. A
consumer therefore does not have to set `NLSPATH`; without this every message would fall back to its
raw symbol (`FDOSM_220` rather than English text).

The tarball ships the `Platform.ini` `MgPortablePlatform::Initialize()` needs, as a top-level file
beside `lib64/` and `fdo/`. It is the file the common-subset build prepared (`configure_file` of
`cmake/configs/Platform.ini.in`) with the two paths the build fills in adjusted for the tarball:
`FdoPath` becomes `fdo/lib64/`, and `MentorDictionaryPath` is left empty because the tarball carries
no CS-Map dictionaries (the platform then leaves `MENTOR_DICTIONARY_PATH` alone, and a consumer that
has dictionaries points it at them). Every configured path is resolved against the **working
directory**, not against the ini's own directory, so unpacking the tarball and running from its root
is what makes `fdo/lib64/` resolve; an application that lays the native libraries out differently
(namespace them under `runtimes/linux-x64/native` for the NuGet package, say) copies the file next to
its own executable and edits `FdoPath`. Checked in the generic thin container: with no
`/usr/local/fdo-*` and only ACE on `LD_LIBRARY_PATH`, `libPortableUnmanagedApi.so` and
`libMgPortable` load under `RTLD_NOW`, resolving `libFDO`, `libExpressionEngine`, gdal, xerces and
xalan from `lib64/../fdo/lib64`; pointing the shipped `FdoPath` at a directory that does not exist
makes `MgPortablePlatform::Initialize()` fail with `Failed to load FDO library`, so that is the value
it reads; and, after linking `fdo/lib64/libFDO.so` to `libFDO-4.2.0.so` (which the NuGet targets do
for the packaged layout), the `Portable/UnitTest` runner passes all 215 test cases out of the
unpacked layout (with `MENTOR_DICTIONARY_PATH` set to a dictionary set, since the tarball carries
none, and `NLSPATH` unset).

To build and run the portable suites from an existing build tree (the runner creates the
`<build-dir>_commonlibs` tree and configures it with `--with-portable`, plus `--with-asan` when the
main tree is Debug):

```
/tmp/work/scripts/run_mapguide_tests.sh --mapguide-build-dir /tmp/work/build_area/mapguide \
    --log-path /tmp/work/artifacts/test-logs --tier portable
```

| Suite | What it runs |
|-------|--------------|
| `cpp` | `Portable/UnitTest`, the Catch2 runner. In a Debug tree it is ASan/LSan-instrumented, so its log carries the leak report; the server-tier rules apply (`All tests passed`, then a `SUMMARY: AddressSanitizer:` line, and a non-zero exit is not a test failure). A clean Debug run reports no leak records at all — the fixed families are recorded in [docs/portable-memory-leaks.md](./docs/portable-memory-leaks.md). On Windows the same runner honours `MG_CRT_LEAK_CHECK=1`, which redirects the CRT leak report to stderr. |
| `dotnet` | `Portable/DotNetUnitTest`. The SWIG-generated C# and the managed sources are staged and built for `net6.0` on Linux **for testing only**; the packaged assemblies still come from the Windows build. It runs against the same generated `Platform.ini` and `UnitTestFiles` as the C++ runner. |

`--tier all` also runs the portable suites. They are skipped (and listed under `Skipped suites`)
when the container has no .NET SDK or the portable tree could not be built; naming one with
`--portable-suite` makes its prerequisites required. The C# sources are only built on Linux by this
test path — a normal `build_thin.sh` build produces the native libs and the SWIG glue only.

For the Windows overlay, `Bindings/setup_linux_native_libs.cmd` takes the common tarball as its
first argument and the portable tarball as an optional second one; the second copies the portable
native libs into `src/Managed/DotNet/OSGeo.MapGuide.Portable/runtimes/linux-x64/native`.

### SWIG is pinned, and never taken from the distro

The bindings are generated by SWIG proper, and one version has to generate all of them: a distro
package satisfying `find_package(SWIG 4.1)` with, say, 4.1.0 would produce Java and PHP glue that
disagrees with the .NET glue the same tree generated before. So the version is pinned to the one
`MgDev/cmake_bootstrap.sh` builds (currently **4.3.1**, read from that script rather than repeated
here), and the images deliberately ship **no** SWIG package for the harness to fall back to.

`run_mapguide_tests.sh` therefore owns the acquisition for a web tier run:

- it asks `/usr/local/bin/swig` what it is, and if that is not the pinned version it builds the
  pinned release from source over it (the tarball and built tree live in `/tmp/download`, where
  `cmake_bootstrap.sh` already puts `swig.zip`; `--swig-build-dir` points that somewhere persistent);
- a run with the right SWIG installed does no work, so the second and later runs skip it entirely;
- it refuses to build a tree that was *configured* against another SWIG, and regenerates the
  common-libs subset from scratch if that one was, because the glue is baked at configure time —
  `find_package(SWIG 4.1)` only requires "new enough", so nothing else would notice.

`build_thin.sh` is unaffected: a full build gets its SWIG from `cmake_bootstrap.sh`, which builds the
same pinned release when `swig` is absent. The two mechanisms agree on the version because both take
it from the bootstrap.

Windows pins the same 4.3.1 by convention rather than by a check — `$(SWIG_DIR)` is expected to point
at a 4.3.1 binary install, and the `*.vcxproj` generate the C# with it. Since both platforms run one
SWIG, the **flags** passed to `swig -csharp` decide whether they produce the same C#, so
`Bindings/src/Bindings/DotNet/*/CMakeLists.txt` passes the same four suppressions the `*.vcxproj` do,
and `-DSWIG_CSHARP_NO_WSTRING_EXCEPTION_HELPER` must stay: 4.3 no longer emits the
`SWIGWStringHelper` class, and without that flag the exception helper still references it
(`CS0103`). Suppressing the class is the trap — that combination emits references with no definition.

The `dotnet` suite is what checks the .NET arrangement the packages are assembled from. The C#
assemblies are only ever compiled on Windows, and the Linux `lib*UnmanagedApi.so` glue libraries are
overlaid on those binaries and bundled into the NuGet packages, so what ships is Windows-compiled C#
P/Invoking Linux glue — a pairing nothing used to exercise. There is no `MgWebTestRunner`-style
target for it: the glue comes from a **common-libs subset build** (the CMake option that adds
`Bindings/DotNet`, which a full build does not), and the C# comes from the SWIG-generated sources
that build writes next to the glue. On the first run the script:

1. builds that subset beside the main build tree (`<build-area>/mapguide_commonlibs`, installing to
   `mapguide_commonlibs/install` so nothing is mixed into the web tier install). The five
   modules generate one after another rather than all at once, because `IMake` writes
   `<Api>Api_Properties.i` into the source tree while each module `%include`s the `.i` files the
   earlier ones generate: run concurrently, one module reads another's fragments mid-write and SWIG
   fails with `Unterminated %{ ... %}` in `<Api>Api_Doc.i` or `Unable to find
   '<Api>Api_Properties.i'`. That ordering is the `add_dependencies` line each
   `Bindings/src/Bindings/DotNet/*/CMakeLists.txt` carries;
2. stages `Bindings/src/Managed` and `Bindings/src/Test/DotNet`, drops the generated `.cs` into the
   managed projects, and rewrites the test projects' `OSGeo.MapGuide.*` package references to those
   local projects, so the run tests *this* tree's assemblies against *this* tree's glue rather than
   whatever version is on nuget.org;
3. runs `TestRunner` against the live server, with `LD_LIBRARY_PATH` pointing at the glue directory
   and `DOTNET_ROLL_FORWARD=Major` (the projects target `net6.0`; the image's SDK is newer).

The staging copy is why the SVN working copy stays clean: the Windows build writes its generated C#
into the managed project directories, and nothing here does.

The PHP interpreter is the one artefact no CMake target produces. `cmake --install` puts the
extension in PHP's extension directory (`webserverextensions/php/lib/php/extensions/<api>/`,
which is the `extension_dir` in `webserverextensions/php/lib/php.ini`) and the interpreter's
configuration in place, but never an interpreter to load it with: the
interpreter is built by `cmake_linuxapt.sh`, which a full build runs. An installed `.run` package
and the `build` image have one out of the box; a `develop_thin` container does not.

`build_mapguide_incremental.sh` therefore builds one, because the alternative was a full MapGuide
build just to run one suite:

```
$ /tmp/work/scripts/build_mapguide_incremental.sh
Building the PHP interpreter into /usr/local/mapguideopensource-4.0.0/webserverextensions/php
  (the PHP binding suite needs it; cmake --install only installs its configuration)
...
PHP interpreter installed: /usr/local/mapguideopensource-4.0.0/webserverextensions/php/bin/php
```

That is `cmake_linuxapt.sh --php-only`: the same recipe a full build uses, minus httpd, the tomcat
connector and fusion. Two details follow from not building httpd. It configures PHP **without
`--with-apxs2`**, because there is no `apxs` yet, so the interpreter has no Apache module — fine for
the CLI the test suite runs, and a later full build reconfigures the tree with the module. And it
adds **`--enable-zts`**, because `--with-apxs2` would have implied thread safety and the extension
is a `TS` module: an `NTS` interpreter refuses to load it (`Module compiled with build ID=API…,TS /
PHP compiled with build ID=API…,NTS`). The step is idempotent — it is skipped when the installed
interpreter already reports `Thread Safety => enabled` — and `--no-php` skips it. It costs about
eight minutes the first time in a container and nothing after that.

With no interpreter and no build step having run, the script falls back to the release tarball that
`build_thin.sh` already mounts at `/tmp/work/artifacts`, and will also use the CLI straight out of
the `cmake_linuxapt.sh` build tree if one is there (`<linuxapt>/LinuxApt/php-*/sapi/cli/php`, which
needs no install at all). The tarball path looks like this:

```
Installing the PHP interpreter from mapguideopensource-4.0.0.10232-ubuntu22-amd64.tar.gz
  >> /usr/local/mapguideopensource-4.0.0/webserverextensions/php/bin/php
```

Only `webserverextensions/php` is extracted — the rest of that tarball is the packaged build, and
unpacking it over the install would replace the libraries this run just built with the packaged
ones. The tarball is chosen for `MG_DISTRO` and never "any tarball", for the same reason the FDO
SDK is: one built for another distro links a different set of thirdparty libraries. If neither an
interpreter nor a matching tarball can be found the suite is skipped with that reason and the other
suites still run; `--artifacts-dir` points at a different directory, `--php-path` at a specific
interpreter (and a `--php-path` that does not exist is a hard error rather than a silent skip).

The Java suite reads its `.dump` fixtures through `sqlite4java`, which loads a native library
per platform. The Windows ones have always been checked in under `Bindings/src/Test/Java/extlib`;
`libsqlite4java-linux-amd64.so` now sits beside them, and `Bindings/src/Test/Java/README.txt`
records where it came from and how it is verified. Without it every dump-driven Java test fails
with `no sqlite4java-linux-amd64 in java.library.path`.

A Debug web tier run is also a LeakSanitizer run of the server, exactly like `--run-mode`, so it
fails on a leak summary even when every suite passed. Both the server and the C++ runner process
report one, and the records are in
[docs/mapguide-memory-leaks.md](./docs/mapguide-memory-leaks.md); a Debug run of the four suites now
comes back with no report from either:

- 17,168 B in 12 allocations (server, `Wfs_*` cases) from `TransformCache::GetLayerToMapTransform`:
  the `reverse == false` direction is deliberately not cached, so the entry it returns belongs to the
  caller, and `MgWfsQueryAdapter::SetOptions` used to keep only its transform and drop the entry.
- 2,560 B in 20 allocations (the runner process, `Wms_*` cases) from
  `MgHttpWmsGetFeatureInfo::GetSelectionGeometry`, whose `linearRingCoords->Add(new MgCoordinateXY(...))`
  dropped the reference `Add()` does not consume, once per corner per request.
- 3,156 B in 30 allocations (server, every binding suite) from the SDF schema graph: a describe with
  a schema name that does not match the file's read a whole schema copy and then threw
  `SDFPROVIDER_58_INVALID_SCHEMANAME`, abandoning it. It is the one report that is all-indirect —
  every chunk is reachable from another leaked chunk, never from a live one — so it reads as a cycle
  when it is a lost reference on an exception path.

`mgserver`'s records are what used to make the *suite* verdict fail even though its tests passed; the
runner's are printed underneath the passing summary. Both are now silent, so a Debug web tier run
green on assertions is also a green verdict.

All of those records are native, on the server and runner side. A leak inside a binding *client* —
the JVM heap, the Zend memory manager or the .NET managed heap — is invisible to LSan, and the two
such defects that have been found (Java and PHP both leaked one buffer per `MgByteReader::Read`)
could not have failed any of these suites: the verdict is assertions plus the server's own log, and
neither depends on the client's memory. The ownership rules for .NET, Java and PHP application code,
and the plateau/`massif`/`memory_get_usage` recipes that catch that class of leak, are in
[docs/mapguide-bindings-memory-guide.md](./docs/mapguide-bindings-memory-guide.md).

> The corrupt-DWF fixture (`DrawingService_MasterApiTest` feeding a truncated package through
> `MgServerDrawingServiceUtil::OpenDrawingResource`) used to kill the server in a Debug container:
> DWFTK's `DWFException` copy constructor over-read the message buffer
> (`AddressSanitizer: heap-buffer-overflow` in `__interceptor_wcslen`, from `throw e;` on the
> caught `DWFInvalidTypeException`), after which every later call failed with "Cannot establish
> connection to the MapGuide Server". `DWFCore::DWFException` never terminated its 512-character
> message buffer — it zeroed `nBytes + 2` bytes, so the two zeroed bytes landed in the low half of
> the first `wchar_t` past the copy and the uninitialised high half made it non-zero — and the
> constructor, copy constructor and assignment operator all did it. They now share one bounded
> copy that always terminates; see `Oem/DWFTK/develop/global/src/dwfcore/Exception.cpp`. The same
> over-read was happening silently in Release, where there is no ASan to catch it.
>
> The defect is Linux-only in effect, which is why it went unnoticed: `2` in `nBytes + 2` is two
> *bytes*, and on Windows `sizeof(wchar_t)` is 2, so the old code did zero a whole terminator there
> — the buffers the fix produces are byte-for-byte identical to what Windows already had (verified
> by modelling both implementations with a 2-byte and a 4-byte character type, and at the 511/512
> truncation boundary). It only ran off the end where `wchar_t` is 4 bytes. The change is
> behaviour-neutral on Windows, uses no new language features (it still compiles as C++98, which
> the VC 8.0 project's `/W4 /WX` build needs), and needs no project-file change: the Windows build
> compiles the same `Exception.cpp` through `Oem/DWFTK/develop/global/build/VC 14.0/DWFCore/DWFCore.vcxproj`
> into the `dwfcore_wt.1.7.0.lib` that `ServerDrawingService.vcxproj` links.

> `ResourceService_ApplyResourcePackageApiBranchTest` carried a second, unrelated "will kill the
> mgserver" record — the `FIXME` all three binding runners threw off Windows — and it was not a
> DWFTK problem. Param set 18002's `PACKAGE` is empty, which the runners resolve to the working
> directory, and on POSIX `open()` succeeds on a directory while `lseek(SEEK_END)` reports
> `LLONG_MAX` for it. `MgByteSource` therefore produced a reader that serialized a stream header
> declaring 2^63-1 bytes, the first `read()` then failed with `EISDIR` *after* that header had gone
> out, and the server's `MgStreamReader::GetStream` was left waiting for data that never arrived:
> the operation thread never returned and the connection stayed desynchronised, so the suite hung
> rather than failed. Windows fails the directory open outright, which is why it only ever bit on
> Linux. `ByteSourceFileImpl::LoadFile` now rejects a directory with `MgFileIoException`, so the
> reader throws before it is serialized, and the three runners run the operation everywhere: the
> four param sets give `mgfileioexception`, `mginvaliddwfpackageexception` (not a zip),
> `mginvaliddwfpackageexception` (corrupt zip) and success. That took the binding suites from
> 1/614 (Java), 4/700 (.NET) and 5/593 (PHP) to 0/618, 0/700 and 1/593 — the one PHP failure left
> is the unrelated `GETDRAWINGLAYER` binary comparison.

## 5. Running integration test suites

Open 2 separate terminal sessions

In terminal 1 (to install the MapGuide installer package into the target distro docker container and start the MapGuide Server in interactive mode):

```
./mapguide_image_install.sh --target [generic|ubuntu] --target-distro [distro] --tag [latest|version]
```

In terminal 2 (to run the integration test suite):

> NOTE: You must have node.js installed

> `--output headers` option is specified as some test cases output binary response content which certain shells/terminals may try to interpet the content as extra commands/control sequences/audio cues. This option was the best one that provides some level of chatter without being too quiet or too verbose.

```
cd test
# Run all mapagent test suites
npx httpyac *_api.http --all --bail --output headers
# Run post install sanity check
npx httpyac post_install_checks.http --all --bail --output headers
# Run teardown
npx httpyac _teardown.http --all --bail --output headers
```

# A special note for Ubuntu 22.04 docker hosts

ASAN in llvm 14 provided in ubuntu 22.04 is incompatible with high-entropy ASLR in much newer
kernels to random crashes: https://reviews.llvm.org/D148280

This issue is most prevalent in debug builds as the build process has a random, but high chance
of crashing and infinitely looping with `AddressSanitizer:DEADLYSIGNAL`

To workaround this, restore the older entropy setting like so

> sudo sysctl vm.mmap_rnd_bits=28

To check if your entroy is at the right level, run the following command:

> sudo sysctl -a | grep vm.mmap.rnd

It should report something like this

```
vm.mmap_rnd_bits = 28
vm.mmap_rnd_compat_bits = 8
```

This setting does not persist, so it must be done and checked before starting a build

More information on this issue can be found here: https://llbit.github.io/programming/2024/03/19/aslr-asan-problem.html

# Supported build environments

|target  |distro|tag  |
|--------|------|-----|
|mapguide|generic|    |
|mapguide|ubuntu|22.04|
|fdo     |ubuntu|22.04|
|fdo     |ubuntu|16.04|
|fdo     |ubuntu|18.04|
|fdo     |generic|    |

Building for 32-bit Linux distros is not supported.

Our canonical distros for building MapGuide releases for Linux are:

 * Rocky Linux 8 (for `generic`)
 * Ubuntu 22.04

# FDO Thirdparty matrix

> On Windows, all internal thirdparty libraries are used

| Distro   | GDAL             | OpenSSL         | libcurl         | mysqlclient | mariadbclient   | libpq           | xalan-c          | xerces-c          |
|----------|------------------|-----------------|-----------------|-------------|-----------------|-----------------|------------------|-------------------|
| generic  | Internal/dynamic | Internal/static | Internal/static | N/A         | Internal/static | Internal/static | Internal/dynamic | Internal/dynamic  |
| ubuntu22 | System           | System          | System          | System      | N/A             | System          | System           | System            |

# MapGuide Thirdparty matrix

> On Windows, all internal thirdparty libraries are used

| Distro   | ACE              | dbxml            | berkely db       | xqilla           | geos            | gd              | libpng          | freetype        | libjpeg         | zlib            | xerces-c         |
|----------|------------------|------------------|------------------|------------------|-----------------|-----------------|-----------------|-----------------|-----------------|-----------------|------------------|
| generic  | Internal/dynamic | Internal/dynamic | Internal/dynamic | Internal/dynamic | Internal/static | Internal/static | Internal/static | Internal/static | Internal/static | Internal/static | Internal/dynamic |
| ubuntu22 | System           | Internal/dynamic | Internal/dynamic | Internal/dynamic | Internal/static^| System          | System          | System          | System          | System          | System           |

^ The version of GEOS library shipped with Ubuntu 22.04 has an incompatible C++ API that is too difficult to #ifdef around. Until MapGuide switches to using GEOS's C API we will have to build MapGuide against our internal copy for the foreseeable future

# Generic build runtime requirements

The `generic` artifacts are built on Rocky Linux 8 and bundle every library they need except the
system C/C++ runtime. They do not need any of the build-time thirdparty packages listed above on the
machine that runs them, but they are not dependency-free: the table lists everything that is still
external.

| Requirement | Needed by | Notes |
|-------------|-----------|-------|
| glibc 2.28 or newer | everything | The highest symbol version required is `GLIBC_2.28`. A distro at that floor (Debian 10) runs the server; Ubuntu 18.04 (2.27) fails with `version 'GLIBC_2.28' not found`. |
| `libstdc++` with `GLIBCXX_3.4.22`/`CXXABI_1.3.9`, and `libgcc_s` | everything | The C++ runtime of GCC 6 or newer. |
| `libcrypt.so.1` (libxcrypt, `XCRYPT_2.0` symbols) | Apache httpd/APR (web tier) | Present by default on Debian/Ubuntu. On Fedora, RHEL 9 and Arch install `libxcrypt-compat` (`libxcrypt` itself now provides `libcrypt.so.2`); on openSUSE install `libcrypt1`. Without it the web tier does not start. |
| Oracle Instant Client (`libclntsh.so.12.1`) | KingOracle provider | Bring your own OCI, as on every platform. |
| `liblttng-ust.so.0` (optional) | `MapGuide.RepositoryAdmin` | The self-contained .NET runtime ships `libcoreclrtraceptprovider.so`, which the CLR opens only when LTTng tracing is enabled. The runtime and the admin app start and run without it (measured on Debian 12, which has no LTTng installed), and `dep_check.sh` skips it for that reason. |
| a JVM | Tomcat (optional) | |
| a `daemon` user/group, or another existing pair | httpd | `httpd.conf` runs as `daemon:daemon`. The installer does not create accounts: an interactive install asks for an existing user and group when `daemon` is missing, and a headless install fails unless `--httpd-user`/`--httpd-group` name an existing pair (on openSUSE the usual pair is `wwwrun:www`). |
| a UTF-8 locale | Xerces-C (`mgserver`) and Apache | Both fail with `Could not load a transcoding service` when the locale has no UTF-8 charset. The installed launchers (`mgserver.sh`, `mgserverd.sh`, apache `envvars`) select one if the environment has none. |
| `tar` and `gzip` | the `.run` installer | A makeself archive; every normal distribution has both. |

Everything else in the matrices above is bundled, including ACE, Xerces-C, Xalan-C, GDAL, OpenSSL,
libcurl, SQLite, MariaDB Connector/C, libpq, unixODBC, PCRE2, libxml2, expat, oniguruma, CS-Map,
GEOS, Berkeley DB/DbXML/XQilla, gd, libpng, libjpeg, libtiff and freetype. On Linux,
`MapGuide.RepositoryAdmin` is published self-contained, with invariant globalization and without
the .NET single-file host, so it needs neither ICU nor zlib (the Windows publish is unchanged).
Fonts are *not* bundled: text rendering uses the system font directories configured by
`LinuxFontDirectories` in `serverconfig.ini`.

These requirements were measured on the Release artifacts. A full end-to-end run — install,
`mgserver`, the PHP binding under httpd and a `GETSITEVERSION` MapAgent request — works on Debian
12, Fedora 43, AlmaLinux 9, Arch Linux and openSUSE Leap 15.6 once the per-distro packages above are
present. Ubuntu 22.04 installs and runs the server and the PHP extension without any of them.
Debian 10 (glibc 2.28, the floor) runs the server and PHP; its web tier additionally needs
`libcrypt1`, because its default `libcrypt.so.1` is glibc's and lacks `XCRYPT_2.0`. Ubuntu 18.04
(glibc 2.27) fails as expected. Every FDO provider except KingOracle also loads under `RTLD_NOW` on
Debian 12, Fedora 43 and AlmaLinux 9; the FDO SDK is relocatable because `libFDO` and the providers
carry `$ORIGIN` in their runtime path.

# Known issues

MapGuide has not been tested to build on Ubuntu versions older than 22.04

# WSL2 Notes

You must use Docker Desktop for Windows as the docker engine when going the WSL2 route. Alternatives like Rancher Desktop are not suitable yet due to various unresolved bugs around volume mounting that breaks building MapGuide/FDO code within dev containers.

# Credits

This docker-based build system was heavily inspired by: https://github.com/MatrixManAtYrService/lifecycle-snapshots
