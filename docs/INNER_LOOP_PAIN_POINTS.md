# Speeding up the MapGuide dev/debug inner loop

This note records the inner-loop problem as it was observed, what turned out to be missing in the
build system, and what was added. The resulting process is documented in
[README.md § 4.4](../README.md#44-the-mapguide-rapid-inner-loop).

## The loop this note was written against

```
# on the container host
./build_thin.sh  for FDO on $distro                 (one time)
./build_thin.sh  for MapGuide on $distro --interactive   (one time)

# inside the build container and then on the host, alternating
/tmp/work/scripts/build_mapguide_$distro.sh
[run test suite(s)]
[make MapGuide source code changes]
```

## Pain points

Running `make`/`ninja` in the CMake build area root should rebuild only what a source change
affects. That did not appear to work, so the full `build_mapguide_$distro.sh` had to be re-run as a
sledgehammer to make sure the change was picked up.

`build_mapguide_$distro.sh` is an end-to-end build, and none of its extra work helps while iterating
on server code: it rebuilds the OEM/web tier components (httpd, PHP, ...) and spends time producing
`.deb` packages and installer artefacts.

## What was actually missing

The incremental build does work; three things stopped the short commands from being usable.

1. **The FDO SDK install only happened inside the full build script.** The install goes into the
   *container* filesystem, so a freshly started interactive container has no
   `/usr/local/fdo-4.2.0` — and a MapGuide build tree cannot build a single target until it does.
   `ninja` stops before compiling anything:

   ```
   ninja: error: '/usr/local/fdo-4.2.0/lib64/libExpressionEngine.so', needed by
   'Common/Stylization/libMgStylization-4.0.0.so', missing and no known rule to make it
   ```

   That is why the sledgehammer "worked": it was not that incremental builds were broken, it was
   that it was the only thing that re-installed the SDK.
2. **Without a target, `cmake --build .` builds `all`**, which includes the web tier
   (`MgWebApp-4.0.0`, `MgHttpHandler-4.0.0`, `mod_mgmapagent-4.0.0`, the PHP/Java bindings,
   `mgdevhttpserver`) — exactly the work the inner loop wants to skip.
3. **The test runner could not run a suite on its own.** It always ran all 21 components (two fewer
   than `mgserver test list` reports), set no `LD_LIBRARY_PATH` — so `mgserver` could not `dlopen`
   `libMgUnitTesting.so` and every suite reported a failure — and judged each suite by its exit
   code, which a Debug (ASan/LSan) run makes non-zero even when every test passed.

## What was added

- `templates/scripts/container/build_mapguide_incremental.sh` — installs the FDO SDK the build tree
  was configured against (stamped against the tarball, so a rebuilt SDK is picked up), copies
  `atomic.h` only when it changed, and builds `mgserver` + `MgUnitTesting` by default.
  `--target` builds something else, `--install` installs the current output, `--prepare` does the
  SDK install only.
- `templates/scripts/container/run_mapguide_tests.sh` — `--component`/`--list-components` to select
  suites (`--component all` passes `all` through to `mgserver`, which runs every suite in one
  process, as upstream's `run_tests.sh` does), `--timeout` for the per-suite timeout, the
  `LD_LIBRARY_PATH` above, FDO-SDK install-on-first-use, and pass/fail decided from the Catch2
  assertion summary (leak-only and teardown-only non-zero exits are passes) with a non-zero overall
  exit when a suite really failed.
  Ctrl-C (and `docker stop`, and a dropped tty) stops the running suite rather than being swallowed
  and letting the loop start the next one: the suite is waited for as a background job, because a
  trap cannot interrupt a foreground wait, and the trap signals the process group `timeout` put the
  suite in, escalating to `SIGKILL` because `timeout` waits for a signal-ignoring child and
  `mgserver` can wedge in teardown.
- `env_test_thin.sh --target mapguide` — mounts the build area, sources, artifacts, patches and
  sdks into the thin container like the build does, instead of pointing the runner at
  `/usr/local/src/mapguide/build`, a path that only exists in the non-thin build image.

## Measured

Debug (`--debug`) build tree, 16-core host, warm ccache:

| Step | Time |
|---|---|
| `build_mapguide_incremental.sh` with no change | 0s (`ninja: no work to do`) |
| after `touch Common/Geometry/Geometry.cpp` | 5s (recompile + dependent relinks) |
| `build_mapguide_incremental.sh --prepare` in a fresh container | 2s (extract the FDO SDK) |
| `run_mapguide_tests.sh --component Geometry` | 2s |
| `run_mapguide_tests.sh` (all 22 suites) | 307s |

The slowest single suites are `TileService` (101s), `FeatureService` (66s) and `CoordinateSystem`
(37s), which is what `--component` exists for.
