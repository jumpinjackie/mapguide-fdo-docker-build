# MgPortable memory leaks (LeakSanitizer findings)

This note records the leaks reported by the MgPortable C++ test runner (`Portable/UnitTest`) on
Linux x64, their root causes and fixes. Paths below are relative to the MapGuide source root
(`mapguide/MgDev` on the host, `/tmp/work/src` inside the build container).

MgPortable has no `mgserver test` equivalent: its runner is a Catch2 executable that drives the
portable API directly, so the leak report comes from that process alone.

## How the report is produced

```
# inside the interactive build container
/tmp/work/scripts/run_mapguide_tests.sh \
    --mapguide-build-dir /tmp/work/build_area/mapguide \
    --log-path /tmp/work/artifacts/test-logs --tier portable --portable-suite cpp
```

The runner builds `<build-dir>_commonlibs` with `WITH_PORTABLE` (and ASan in Debug), so the Debug
run is the leak-report carrier and `build_area/x64/Debug/.../Portable/UnitTest/UnitTest` is the
instrumented binary. Judge the run by its Catch2 summary as well as the leak records: the run exits
non-zero when it leaks even though every test passed.

A clean run is 215 test cases / 921 assertions in Debug (1920 in Release) with **no**
`Direct leak`/`Indirect leak`/`SUMMARY: AddressSanitizer` records at all.

The report is a single process, so it is dominated by whichever tests leave a reader, a connection
or a query graph alive. Two properties of this report are worth knowing before reading it:

- It is easy to produce a large report with **no direct records**. A reader that owns an object
  which points back at the reader (a counted child-to-parent link) is a rootless cycle, and every
  chunk in it is reported as indirect. The 16.6 MB first report was one such cycle and one leaked
  connection.
- `MgPortableFeatureConnection::OwnReader()` and the `MgPortableFeatureReader`/`GwsFeatureReader`
  destructors are the ownership seam. A connection whose reference was taken there and never
  returned drags in the whole FDO provider graph: the SDF connection, its schema cache, its
  property index and the SQLite page cache behind it (tens of KB per connection, and megabytes when
  a scrollable SDF reader is holding a cursor).

## Fixed

Totals are for the whole runner, before → after each row's fix (a row's "after" is the "before" of
the next row, so the rows are in the order they were worked).

| # | Leak | Root cause | Fix |
|---|------|------------|-----|
| 1 | 4 × `FdoExpressionCollection` (64 B, direct) plus their identifier strings, from `FdoExpression::Parse` under `MgPortableSelectFeatures::SupportsFdoJoin` | `MgPortableFeatureUtil::ExtractIdentifiers` read `FdoFunction::GetArguments()` (a counted reference) into a raw `FdoExpressionCollection*`, and `FdoUnaryExpression::GetExpression()` the same way | Hold both in `FdoPtr` |
| 2 | 5 × `FdoStringElement` (48 B, direct) from `MgToFdoStringCollection` | `MgPortableFdoForcedOneToOneFeatureReader::GetIdentityValue` kept `FdoStringCollection::GetItem(i)`'s counted element in a raw pointer | `FdoPtr<FdoStringElement>` |
| 3 | 3 × `SltTransaction` (40 B, direct) from `MgPortableUpdateFeaturesCommand::Execute` | The FDO transaction from `BeginTransaction()` was a raw `FdoITransaction*`; `Commit()`/`Rollback()` do not release it | `FdoPtr<FdoITransaction>` |
| 4 | 16.6 MB / 785 records, all indirect, from the `JoinFeatures` path | `MgPortableJoinFeatureReader` held its owner (`MgPortableGwsFeatureReader`) through a counted `Ptr`, and the reader holds the join reader (directly and via the expression engine): a rootless cycle that kept the GWS query, its iterators and the SDF cursor alive | The back-pointer is now a weak `MgPortableGwsFeatureReader*` (see `CPP_STYLE.md`: child-to-parent links are non-owning) |
| 5 | 1 SDF connection per scrollable select (~8.8 KB), plus 1 connection and its schema cache in the extended-class test (~97 KB) | `MgPortableScrollableFeatureReader`'s constructor called `m_connection->OwnReader()` a second time; the base `MgPortableFeatureReader` constructor had already done it. `OwnReader()` takes an extra FDO connection reference when it is not the first caller, and nothing released that second reference | Removed the duplicate call |
| 6 | The same connection graph where a GWS join reader is destroyed without `Close()` | The connections the reader handed to `MgPortableGwsConnectionPool` are marked `OwnReader()`, so their destructor does not return them and only the reader's `Close()` did. A reader that is only released (the `ExtendedFeatureClass` test) returned nothing | The pool's destructor calls `conn->Close()` before releasing each connection; it is a no-op for one an earlier `Close()` already returned |

## The idioms these were

- `FdoCollection::GetItem`, `FdoFunction::GetArguments`, `FdoUnaryExpression::GetExpression` and
  every other `Get*` that is documented as handing back a reference must be held in an `FdoPtr`.
  Portable code is dense with them, and the record's `#1` frame names the collection/element, not
  the call that dropped the reference.
- An object that owns a second object which points *back* at it must store that link weakly. The
  join reader is the portable instance of the same shape as `FdoSmPhDbObjectComponentLoader::mOwner`.
- `MgPortableFeatureConnection::OwnReader()` takes an extra FDO connection reference **only** when
  it is called on a connection another reader already owns, and there is exactly one `Close()` that
  gives it back. Calling it twice (base constructor plus derived constructor) creates a reference
  nothing owns, so a derived reader must not call it — and the owner that does hold the
  `MgPortableFeatureConnection`s (`MgPortableGwsConnectionPool`) must return them to the FDO
  connection pool when it releases them.
