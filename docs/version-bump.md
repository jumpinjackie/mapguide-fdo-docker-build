# Bumping the MapGuide/FDO baseline version

A baseline version bump changes four things at once: the version a product stamps into its
binaries, the directory it installs into, the sonames its libraries get, and the names of the
artifacts this repository produces. This page is the checklist for doing one, and for deciding
which of the version strings found in this repository belong to a bump and which do not.

**The version is not read from the source trees.** Both trees carry version numbers of their own,
but this repository supplies the version from outside: `env_setup.sh` owns FDO's and MapGuide's and
passes them to each tree's `cmake_build.sh` as `--fdo-ver-*` / `--mg-ver-*`. The trees' own version
carriers (FDO's `.rc`/StampVer files, MapGuide's `Common/ProductVersion.h`) are stamped by the
*trees'* own scripts and do not reach CMake, so bumping them changes neither the Linux install
prefix, nor a soname, nor an artifact name. On Windows that job belongs to
[Bump-Version.ps1](https://github.com/jumpinjackie/mapguide-fdo-build-windows), which stamps the
trees *and* the wrappers' `MG_VER_*`/`FDOVER_*` constants; there is no equivalent script here.

## Where the version is supplied

### MapGuide

| Carrier | What it controls |
|---|---|
| `env_setup.sh` — `MG_VER_MAJOR`, `MG_VER_MINOR`, `MG_VER_REL` | **The root, and the only one that has to be right.** `MG_VER` is `<major>.<minor>.<rel>`; it is passed to `cmake_build.sh` as `--mg-ver-major/-minor/-rel`, becomes `-DMG_VERSION_{MAJOR,MINOR,RELEASE}` in `MgDev/CMakeLists.txt`, and CMake derives from it both `MG_INSTALL_PREFIX` (`/usr/local/mapguideopensource-<MG_VER>`) and `MG_VERSION_SUFFIX` (`-<MG_VER>`, appended to every `libMg*` library and every CMake target). It is also baked into the generated `docker/**` Dockerfiles and into `mapguide_version.sh`. |
| `env_setup.sh` — `MG_VER_REV` | The fourth component. It stays the **SVN last-changed revision** of `mapguide/MgDev`, so never hand-edit it. `mapguide_version.sh` therefore exports `MG_VER_TRIPLE=<major>.<minor>.<rel>` and `MG_VER=<major>.<minor>.<rel>.<svn rev>`. |
| `templates/distros/{ubuntu,generic}/install.sh` — `MGVER_MAJOR`, `MGVER_MINOR`, `MGVER_POINT` | `MG_INST`, the path every `post_install` step edits. These are **not templated**: `make_installer.sh` copies `install.sh` verbatim into the installer staging area. If they lag the build, the generic installer's `cp -R mapguideopensource-<ver> ${MG_INST}` fails outright, and so does the ubuntu installer, which runs under `set -euf` and `sed -i`s files under `${MG_INST}`. |
| `make_installer.sh` — `INSTALLER_LABEL` | The installer's display label only. It carries the version as literal text, so unlike everything else here it does not follow `mapguide_version.sh`. |

### FDO

| Carrier | What it controls |
|---|---|
| `env_setup.sh` — `FDO_VER_MAJOR`, `FDO_VER_MINOR`, `FDO_VER_REL` | The root. `FDO_VER` is `<major>.<minor>.<rel>` and becomes `-DFDO_VERSION_*` in the FDO tree, which derives the install prefix (`/usr/local/fdo-<FDO_VER>`) and the versioned sonames (`libFDO-<FDO_VER>.so`, `libMySQLProvider-<FDO_VER>.so`, ...). |
| `env_setup.sh` — `FDO_VER_REV` | The fourth component; the SVN revision of `fdo`. |
| `templates/distros/{ubuntu,generic}/install.sh` — `FDOVER_MAJOR`, `FDOVER_MINOR`, `FDOVER_POINT` | `FDO_INST`, plus the `<Version>`/`<FeatureDataObjectsVersion>` fields the ubuntu installer writes into `providers.xml`. Hand-edited, same as the MapGuide block above. |
| `templates/vscode/mapguide/launch.json` — `LD_LIBRARY_PATH` | A `cppdbg` launch configuration, so it cannot discover anything: the FDO path is literal. It is copied into `.vscode/` by hand rather than generated, so an FDO bump has to edit it. (The MapGuide half of the same list is a build-area path, which does not carry a version.) |

An FDO bump **renames the provider libraries**, so anything that names
`lib<X>Provider-<ver>.so` by hand has to follow. Nothing in this repository does: `providers.xml`
is written by the FDO build, and the MgPortable pack rewrites the `<LibraryPath>` entries with
`-${FDO_VER_TRIPLE}.so` when it stages the tarball.

### The source trees

The two trees own the version **files** but not the version **value**, so a bump of this repository
does not require an SVN change — with one historical exception, which is now gone. The MapGuide test
harness used to pin the install path in four places, each of which broke the moment the prefix moved
(`prepare_test_pack.sh` failed with `.../mapguideopensource-4.0.0/webserverextensions/www/WEB-INF/lib
does not exist`, which is the ant error an install of `-4.0.1` produced):

| File | Was | Now |
|---|---|---|
| `Bindings/src/Test/Java/build.xml` — `mapguide.ldpath` | `location="/usr/local/mapguideopensource-4.0.0/…"` | composed from `-Dinstall.dir`; `checkunix` fails with a message naming the flag when it is absent |
| `prepare_test_pack.sh` — the ant `-Djarsrc.web` | `-Djarsrc.web=/usr/local/mapguideopensource-4.0.0/…` | `--install-dir`, defaulting to discovery; also passes `-Dinstall.dir` |
| `UnitTest/run_web_tests.sh` — webconfig, CS-Map dictionaries, PHP dir, `LD_LIBRARY_PATH` | four literals | `--install-dir`, defaulting to discovery |
| `UnitTest/run_server_tests.sh` — `MG_INST_DIR` | `/usr/local/mapguideopensource-4.0.0` | discovery; `--install-dir` still overrides |

The two build scripts pass `--install-dir /usr/local/mapguideopensource-${MG_VER_TRIPLE}` so the
test pack is cut from the tree that build just installed, rather than from whichever tree happens to
sort highest under `/usr/local`. When adding anything to the test harness that needs the install
tree, take the same route: a flag with a discovery default, never a literal path.

The Windows repo's [Bump-Version.ps1](https://github.com/jumpinjackie/mapguide-fdo-build-windows)
knows these four files by name (`$MapGuideInstallPathPaths`) and checks them on every run: a working
copy that has not taken this change yet still holds the literal, so the script rewrites it to the
version being bumped to — and reports a literal it did not rewrite rather than letting the next
"Preparing test pack" fail with ant's `does not exist`. That is the safety net for the two working
copies drifting apart, not a substitute for the discovery above: the healthy report is that all four
derive the tree.

The `.bat` variants (`UnitTest/run_*_tests.bat`) take every path as a parameter and carry no
version, so they need nothing.

## Procedure

1. Bump the roots in `env_setup.sh`:

   - `MG_VER_MAJOR` / `MG_VER_MINOR` / `MG_VER_REL`
   - `FDO_VER_MAJOR` / `FDO_VER_MINOR` / `FDO_VER_REL` (only when FDO's baseline moves too)

2. Bump the hand-edited installer constants in **both** `templates/distros/ubuntu/install.sh` and
   `templates/distros/generic/install.sh`:

   - `MGVER_MAJOR` / `MGVER_MINOR` / `MGVER_POINT`
   - `FDOVER_MAJOR` / `FDOVER_MINOR` / `FDOVER_POINT`

3. Update `INSTALLER_LABEL` in `make_installer.sh`, and — on an FDO bump — the `LD_LIBRARY_PATH`
   in `templates/vscode/mapguide/launch.json`.

4. Regenerate the generated content for **every** target and distro. `docker/**` and
   `*_version.sh` are generated and gitignored, so editing them by hand is always wrong:

   ```sh
   ./env_setup.sh --target fdo      --distro ubuntu  --tag 22.04 --cpu x64
   ./env_setup.sh --target mapguide --distro ubuntu  --tag 22.04 --cpu x64
   ./env_setup.sh --target fdo      --distro generic --cpu x64
   ./env_setup.sh --target mapguide --distro generic --cpu x64
   ```

   (`env_setup_all.sh` runs the same four, and a bump is a good time to run it.)

5. **Rebuild from clean build trees and fresh containers.** A bump is not an incremental change: an
   existing `build_area/**/CMakeCache.txt` still records the old `MG_INSTALL_PREFIX` (which
   `build_mapguide_incremental.sh` and `run_mapguide_tests.sh` read the install path from), and an
   existing build container still has the old tree installed under `/usr/local`. Both have to go,
   or the new artifacts are cut from an install that only partly moved. `clean_artifacts.sh`,
   `clean_images.sh` and a fresh `build_thin.sh` cover it.

6. Build FDO, then MapGuide, then package the installers — see the main
   [README](../README.md#usage) workflow.

## What follows automatically

Nothing below needs editing; it all reads the version out of a generated file, the CMake cache or
the package name, and is listed here so a bump is not spent auditing it:

- `templates/scripts/container/build_mapguide.sh`, `build_mapguide_ubuntu22.sh` and
  `build_mapguide_generic.sh` — `MG_VER_TRIPLE` from the environment, the install prefix, the
  tarball names, and the MgPortable pack's `libMg<X>-<MG_VER_TRIPLE>.so` copies.
- `templates/scripts/container/build_mapguide_incremental.sh` and `run_mapguide_tests.sh` — read
  `MG_INSTALL_PREFIX` and `MG_VERSION_{MAJOR,MINOR,RELEASE}` out of `CMakeCache.txt`, which is also
  what every version-suffixed CMake target name is built from.
- `image_install.sh`, `mapguide_image_install.sh` — `MG_VER_TRIPLE` / `MG_VER`.
- Everything in `make_installer.sh` except `INSTALLER_LABEL` — `mapguide_version.sh`, plus the
  staging directory `mapguideopensource-${MG_VER_TRIPLE}`.
- `templates/scripts/container/dep_check.sh`, `mapguide_smoke_test.sh`,
  `run_fdo_tests.sh` — they **discover** the installed tree (`/usr/local/fdo-[0-9]*`,
  `/usr/local/mapguideopensource-[0-9]*`) instead of pinning a version, so they survive a bump
  unaided. `mapguide_smoke_test.sh --install-dir` overrides the discovery.
- The ubuntu `.deb` names (`mapguideopensource-server_<ver>-<rev>_amd64.deb`): the installer finds
  them by component with `grep "mapguideopensource-${file}"`, so their version is irrelevant to it.

## What must not be changed

- **`&VERSION=4.0.0`** in `test/*.http` and `test/openapi-{csharp,java}/` is the **MapAgent protocol
  version**, not a build version. It is `ApiVersion = L"4.0"` in
  `MgDev/Common/ProductVersion.h` and the mapagent accepts a fixed set of protocol versions; a
  baseline bump does not add one. See [openapi.yaml](./openapi.yaml).
- **`Version="4.0.0"` on the `OSGeo.MapGuide.*` `PackageReference`s** in the source tree's
  `Bindings/src/Test/DotNet/src/*/*.csproj` and `Portable/DotNetUnitTest/DotNetUnitTest.csproj` is
  the **NuGet package version** of the managed proxies, not this repository's build version. It is
  only ever used as a search string: `run_mapguide_tests.sh` replaces those references with
  `ProjectReference`s so the suites build the freshly generated C# instead of restoring from
  nuget.org. Those seds match the literal `4.0.0` coming from the tree, so they must keep matching
  what the tree says — if upstream ever bumps them, the sed stops matching silently and the .NET
  suites fall back to a package restore.
- **Recorded observations** in `docs/*.md` (the memory-leak records, `INNER_LOOP_PAIN_POINTS.md`,
  `mapguide-performance-log.md`, `mapguide-gws-query-engine-and-feature-joins.md`, ...) quote the
  version that was current when the run was captured, and usually only for the *shape* of a path or
  a soname. They are the record of a measurement, not a live instruction; leave them alone.

## Verification

After regenerating, before building:

```sh
cat mapguide_version.sh                                  # MG_VER_TRIPLE / MG_VER
grep -rn "mapguideopensource-" docker/x64/*/*/build/Dockerfile   # generated build steps
```

After building, from the artifacts of the new version:

```sh
grep -E '^MG_VERSION_(MAJOR|MINOR|RELEASE)|^MG_INSTALL_PREFIX' \
    build_area/x64/Release/ubuntu22/mapguide/mapguide/CMakeCache.txt
tar -tzf artifacts/Release/mapguideopensource-<ver>.<rev>-ubuntu22-amd64.tar.gz | grep 'libMg.*\.so$'
tar -tzf artifacts/Release/fdosdk-<ver>.<rev>-ubuntu22-amd64.tar.gz | grep 'libFDO.*\.so$'
ls artifacts/Release/ubuntu22/*.deb
```

The CMake cache must name the new prefix, the tarball's libraries must carry the new
`-<ver>.so` suffix, and the installer must still install and pass the smoke test
(`./mapguide_image_install.sh --target ubuntu22`, or `--target generic`) — that last one is what
actually exercises the hand-edited `install.sh` constants, since a mismatch there shows up as a
failing `cp` in the generic installer or a failing `post_install` `sed` in the ubuntu one.
