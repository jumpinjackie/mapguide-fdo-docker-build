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
| `/tmp/work/patches` | `patches/` | MapGuide patches (MapGuide container only) |
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

Because sources, build output and ccache are all on mounted volumes, editing a file under `fdo/` or `mapguide/MgDev` on the host and re-running the script rebuilds only what changed. For an even tighter loop you can drive the underlying build directly:

```
cd /tmp/work/build_area/fdo && cmake --build . --target install
cd /tmp/work/build_area/mapguide && cmake --build . --target install
```

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

`run_fdo_tests.sh` always runs the Core/SDF/SQLite/OGR/GDAL/SHP suites and installs FDO first (`cmake --build . --target install`). It reports the elapsed time of the install step and of each suite, plus the total at the end of the run. The MapGuide runner drives `mgserver test <component>` for each core component with a 5 minute timeout per suite.

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

To run *every* suite the runner supports in one go — the six defaults plus WMS, WFS and King Oracle, and the database suites through the shipped init files:

```
/tmp/work/scripts/run_fdo_tests.sh --log-path /tmp/work/artifacts/test-logs --fdo-build-dir /tmp/work/build_area/fdo \
    --with-wms --with-wfs --with-oracle \
    --with-mysql-init /tmp/work/scripts/test_init/MySqlInit.txt \
    --with-postgis-init /tmp/work/scripts/test_init/PostGisInit.txt
```

The PostGIS, MySQL and King Oracle suites need the `dbs` compose stack running first; ODBC has no shipped init file, so add `--with-odbc-init <file>` of your own to include it. WMS and WFS need outbound network access to the public OGC services they test against.

These are derived from the reference copies in the FDO source tree at `fdo/Providers/GenericRdbms/Src/UnitTest/`; only edit the SVN copies if you need a different configuration. The `service=` entry is the database host (`[dbname@]host:port`).

#### Running a single test binary

You can drive a unit test binary directly, which is the fastest way to iterate on one suite:

```
cd /tmp/work/build_area/fdo/Providers/GenericRdbms/Src/UnitTest
export NLSPATH=/tmp/work/build_area/fdo/nls/linux/en_US/%N
./UnitTestPostGis initfiletest=/tmp/work/scripts/test_init/PostGisInit.txt FdoConstraintsTest
```

- Run the binary from its own directory. Each unit test directory has a local `providers.xml`, except the GDAL and SHP suites, where that local copy does not work and has to be deleted (`rm providers.xml`); loading a provider from anywhere else fails with `CLNT_8_UNABLE_TO_LOAD_LIBRARY`.
- Export `NLSPATH` pointing at the generated message catalogues in the build tree, exactly as `run_fdo_tests.sh`, `env_test.sh` and `env_test_thin.sh` do. Without it, tests that assert on error message text see the raw message symbol (for example `FDOSM_220`) instead of the resolved English text, and will fail.
- The GDAL and SHP suites also need FDO installed at `/usr/local/fdo-4.2.0` (`cmake --build . --target install`).
- SHP needs two extra things the runner does for you. Its locale test only works if the locales it switches between exist (`locale-gen en_US en_US.UTF-8 fr_FR ja_JP.EUC-JP`), and its tests create filesets under `Providers/SHP/TestData` and open them with `IDF_CREATE_NEW`, so leftovers from an earlier run fail the next one — delete that whole `TestData` tree in the build area and copy it back from the sources (`cp -a <fdo sources>/Providers/SHP/TestData Providers/SHP/`) rather than relying on `sh ../../TestData/clean`, which is the shipped script but only removes some of what a run leaves behind.
- The optional positional argument is a CppUnit registry name (`FdoConstraintsTest`, `FdoApplySchemaTest`, `DescribeSchemaTest`, ...); omit it to run everything. Arguments of the form `key=value` are exported as environment variables for the run.

### 4.4 Database-backed tests

Some FDO suites (PostGIS, MySQL, ODBC, Oracle) need a live database. Start the required services from the `dbs` compose fixtures, for example:

```
docker compose -f dbs/docker-compose.yml up -d postgis_pg16 mariadb oracle_xe_11g mssql
```

> The whole stack cannot be started at once: several services publish the same host port (`5432` for the PostGIS variants, `3306` for the MariaDB/MySQL variants). Start one service per port.

> The `mysql_56` service pins a case-sensitive (`latin1_bin`) collation, because FDO class and schema names are case-sensitive while a datastore created without an explicit collation inherits the server's (case-insensitive) default. With a case-insensitive server, the unique index on `f_classdefinition(classname, schemaname)` rejects two classes whose names differ only in case, and `FdoApplySchemaTest::TestSchema` fails with `Duplicate entry 'aCxdATA-Acad' for key 'f_classdef_schnm_idx'`. A datastore created before this was pinned keeps its old collation until it is dropped and recreated (the FDO suites recreate their own datastores). MariaDB and MySQL 8.0 would need their own `--collation-server=*_bin` equivalent if they are ever held to the same standard.

The database containers run on their own compose network, separate from the build container, so reach them through their published ports via the host rather than by container name or `localhost`. The ready-made init files in `templates/scripts/container/test_init/` already point at the compose stack through `host.docker.internal:<port>`:

 * `PostGisInit.txt` → `service=host.docker.internal:5432`
 * `MySqlInit.txt` → `service=host.docker.internal:3306`

The King Oracle suite takes no init file. `run_fdo_tests.sh` points it at the compose stack instead, setting the `KG_ORA_SERVICE`, `KG_ORA_USERNAME`, `KG_ORA_PASSWORD` and `KG_DEFAULT_ORA_CONNECTION` environment variables that the FDO sources document (see `CMake__README.txt` under the King Oracle provider) to `//host.docker.internal:1521/xe` as `fdounittest`. Anything already exported in the environment wins, so another Oracle instance can still be targeted. `fdounittest` is created by the `oracle_xe_11g` service itself: it mounts the suite's `ora_init.sql` into the image's `/docker-entrypoint-initdb.d/`, which runs it as SYS on startup.

`host.docker.internal` works under Podman and Docker Desktop, and under Docker on Linux when the container is run with `--add-host=host.docker.internal:host-gateway`; Podman also provides the native alias `host.containers.internal`. To target a different host, edit the `service=` value in the file.

> The ODBC suite has no equivalent init file here: on Linux its DSNs must be configured separately, as the dynamic DSN setup in the FDO sources is Windows-only.

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

# Known issues

MapGuide has not been tested to build on Ubuntu versions older than 22.04

# WSL2 Notes

You must use Docker Desktop for Windows as the docker engine when going the WSL2 route. Alternatives like Rancher Desktop are not suitable yet due to various unresolved bugs around volume mounting that breaks building MapGuide/FDO code within dev containers.

# Credits

This docker-based build system was heavily inspired by: https://github.com/MatrixManAtYrService/lifecycle-snapshots
