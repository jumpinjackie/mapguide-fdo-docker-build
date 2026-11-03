# Handoff: SQL Server Spatial provider on Linux

State of play, and what to do next. Written at the point where the previous session's context was
exhausted rather than at a natural completion, so treat the "Open items" section as the work queue.

## Read first, don't re-derive

- [`docs/sqlserver-spatial-linux-support.md`](./sqlserver-spatial-linux-support.md) — the provider
  doc: build wiring, fixes 1–12 with their evidence, the measured `FDO_SQS_PERF` table, the
  **Remaining test failures** inventory, and Known issues. Anything about *what has been fixed and
  why* lives here; this file deliberately does not repeat it.
- `docs/fdo-provider-memory-leaks.md`, `docs/fdo-core-memory-leaks.md` — the leak catalogues whose
  status tables the repo's `AGENTS.md` expects to be kept current. This provider's fixes are **not**
  yet reflected in them (see Open items).
- `AGENTS.md`, `CPP_STYLE.md` — repo rules. `AGENTS.md`'s "Running commands inside build containers"
  and the memory-management rules apply throughout.

## Environment

- Build container: the interactive Debug thin container from an earlier session — find it rather
  than assuming: `. ./container_engine.sh && $DOCKER_CMD ps --format '{{.Names}} {{.Image}}'`. It was
  `dreamy_pike` / `dce248e95e63` (`localhost/fdo_ubuntu22_develop_thin_x64`). Source mounts at
  `/tmp/work/src`, build area at `/tmp/work/build_area/fdo`, init files at `/tmp/work/scripts/test_init`.
- Fixtures (both up as of this writing, and both must exist for the split to make sense):
  - `dbs_mssql` on **1433** — the Windows harness's instance, default collation, untouched.
  - `dbs_mssql_cs_1` on **1434** — this suite's, `Latin1_General_CS_AS`. Started with
    `podman-compose -f dbs/docker-compose.yml up -d mssql_cs`.
  - `dbs_mysql_56_1` (3306), `dbs_postgis_pg16_1` (5432) — the sibling providers' control suites.
- `templates/scripts/container/test_init/SqlServerSpatialInit.txt` points at **1434** (the Linux
  instance). Don't repoint it at 1433: the two suites must not share an instance, for the reasons in
  the provider doc's Known issues.
- Every suite run needs `NLSPATH=/tmp/work/build_area/fdo/nls/linux/en_US/%N`,
  `LC_CTYPE=C.UTF-8` (fix 8), `LD_LIBRARY_PATH=/usr/local/fdo-4.2.0/lib64`, and
  `ASAN_OPTIONS=detect_leaks=0` when you want to see anything that happens at process exit (LeakSanitizer
  `_exit`s before `_dl_fini` and hides finalizer double-frees).
- Run one fixture:
  `./UnitTestSQLServerSpatial initfiletest=<initfile> <RegistryName>`. **Registries are the
  `CPPUNIT_TEST_SUITE_NAMED_REGISTRATION` names, not class names** — `SqlServerFdoSqlCmdTest` is
  `FdoSqlCmdTest`, `SqlServerConnectTests` is `ConnectTests`. A name matching nothing prints
  `OK (0)`, which reads like a pass and isn't.

## Change set from the previous session (all Debug-validated)

| # | Change | Where | Evidence |
|---|---|---|---|
| 9 | Deleted a dead reserved-word map that was destroyed twice at exit | `SQLServerSpatial/SchemaMgr/Ph/Mgr.{h,cpp}` | 0 double-frees, 131 → 0 indirect LSan records |
| 10 | `BindBack`'s string case: added the missing `SupportsUnicode()` branch, and `EnsureSize` zero-fills | `Fdo/Pvc/FdoRdbmsPropBindHelper.cpp` (shared core) | whole suite now completes (`Run: 288`), 0 ASan errors; MySQL `OK (249)`, PostGIS `OK (140)` |
| 11 | Defined `SQL_SERVER_XPLAT` for the test static library | `UnitTest/SQLServerSpatial/CMakeLists.txt` | `ConnectTests` `Run: 4/2` → `OK (4)` |
| 12 | Repaired four U+FFFD-corrupted literals with `\uXXXX` escapes | `UnitTest/SQLServerSpatial/SqlServerFdoUpdateTest.cpp` | `testDefect810181` passes; `FdoUpdateTest` 2 failures → 1 |
| — | Split the SQL Server fixture per suite; init file → 1434; README + provider doc updated | `dbs/docker-compose.yml`, `templates/.../SqlServerSpatialInit.txt`, `README.md`, docs | `mssql_cs` up on 1434 with `Latin1_General_CS_AS`; `FdoDatastoreTest` `OK (7)`, 0 LSan records |

The whole-suite count went from *aborting mid-run with no summaries at all* to
`Run: 288   Failure total: 14`; three of those fourteen are fixed above. The remaining eleven are
tabled with an assessment in the provider doc — read it before re-triaging.

## Open items, in the order I would take them

1. **`SqlServerFdoUpdateTest::UpdateMultiIdFeatureClass`** — the only remaining failure that is a
   real SQL Server defect rather than a documented gap. Measured, not guessed:
   - fails identically with fix 10 reverted, so it is **pre-existing**;
   - `SqlServerFdoUpdateTest` does **not** override it (only `OdbcFdoUpdateTest` stubs the whole
     update family), so the Windows build of this suite runs it — **it must pass here, do not stub it**;
   - instrumenting the read-back loop (`UnitTest/Common/FdoUpdateTest.cpp`, right after `pPin` is
     assigned) gave: PIN 1/2/3 `Value = 5000000`, **PIN 4 `Value = 0`, non-null**, with
     `# employees = 250` correct. A data-only update (PIN 2) and an object-only update (PIN 3) leave
     `Value` alone; the PIN 4 update touches **data *and* object** properties and zeroes it.
   - **Next datum to collect:** `RevisionNumber` for that row plus the row count per PIN — one
     `printf` in the same loop, or query the physical table behind `Länd:<NLS Industrial Parcel>` in
     `fdo_root` on 1434. It distinguishes in-place zeroing from a revision-copied row written with 0.
   - Candidate sites: the revision/property-copy path in
     `Fdo/Pvc/FdoRdbmsPvcUpdateHandler.cpp::Execute` (`:60`), or decimal bind/read conversion.
     MySQL/PostGIS pass the same shared test, which is the control saying the shared handler is fine.
2. **Release configuration** — nothing in the previous session was built or run in Release, and fix
   10 changed shared bind code. This is mechanical and closes a real validation gap: build a Release
   tree and run the affected suites, per the repo's "Release vs Debug" rule in `AGENTS.md`.
3. **The two decisions**, both needing the user rather than more analysis:
   - `FdoApplySchemaTest::TestSchema` — the generated schema differs from the master by one class
     (`aCxdATA`): re-cut the master, or change the provider.
   - `SqlServerFdoSqlCmdTest::TestInParamsStoreProcVariant` — reinterprets a BLOB payload with
     `sizeof(wchar_t)` strides, a Windows-shaped expectation.
4. **Leak catalogues** — add rows for fixes 9/10 to `docs/fdo-provider-memory-leaks.md`, per the
   rule in `AGENTS.md`. Their status tables also have no SQL Server Spatial row.
5. Geography/spatial-context cluster (8 failures) — the documented unimplemented-geography gap. One
   hypothesis is already ruled out: the expected-output and NLS data files are **not** encoding
   damaged (444 files scanned, zero U+FFFD).

## Gotchas that each cost a cycle

- **ble.sh and multi-line commands.** A multi-line command pasted into the workspace shell sits in the
  buffer awaiting Ctrl-J and looks like a hang. Keep every command on one line; if you trip it,
  `kill_terminal` and re-issue. `AGENTS.md` warns about this and it is easy to forget.
- **`svn patch`**: the git repo root is *not* an SVN working copy (`fdo/` is). A diff generated from
  the repo root has root-relative paths, so re-apply with `cd fdo && svn patch --strip 1 <patch>`;
  this SVN rejects `-p1`. See `/memories/repo/svn-working-copy.md`.
- **Attributing a failure to your own change**: `svn diff <file> > /tmp/x.diff`, `svn revert <file>`,
  rebuild, run the one fixture, then re-apply — do it all in one command so the tree is never left
  without the change. A whole-suite run that aborted leaves no failure list, so "did I break it?" often
  needs this A/B.
- **CMake target vs static library**: test sources are often compiled into `<Provider>UnitTests`, and
  the executable only links it — so `target_compile_definitions` on the executable silently does
  nothing. Check where the `.o` lives (`CMakeFiles/<Target>.dir/...`) before adding a flag. See
  `/memories/repo/fdo-cmake-targets.md`.
- **Encoding**: several upstream files are Windows-1252. Editing one with a UTF-8-assuming tool
  rewrites its non-ASCII bytes as U+FFFD and no tool warns you — `file` still says "UTF-8 text", and
  `grep -P '\xef\xbf\xbd'` reports 0 in a UTF-8 locale because it matches the *characters* `ï¿½`.
  Use `\uXXXX` escapes in wide literals. See `/memories/repo/fdo-source-encoding.md`.
- **Logs inside the build container are ephemeral** — `/tmp/*.log` disappeared when a terminal was
  cleaned up, losing two failure lists. Copy anything you need into the workspace as you go.

## Suggested skills for the next session

- `diagnose` — for item 1: reproduce, minimise, hypothesise, instrument, fix, regression-test. The
  remaining defect has a fast loop (one fixture, ~1 minute) and a known-good control (MySQL/PostGIS).
- `handoff` again — if the next session also ends mid-investigation.
