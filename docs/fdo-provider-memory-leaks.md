# FDO provider memory leaks (LeakSanitizer findings)

This note records the memory leaks that the GDAL, OGR, SHP, SDF, WMS, WFS and King Oracle provider suites reported on Linux
x64 under the ASan/LSan-instrumented Debug build, what was fixed, and what is deliberately left in
place. It is the provider-side companion to [docs/fdo-core-memory-leaks.md](./fdo-core-memory-leaks.md),
which covers the FDO Core suite.

Paths below are relative to the FDO source root (`fdo/` on the host, `/tmp/work/src` inside the build
container). The SQLite provider suite reported no leaks in this pass, and none of the leaks below are
in the SQLite provider; the suite's later leak (r8375, the "Default" spatial-context test) is recorded
at the end of [Leaks that were fixed](#leaks-that-were-fixed).

## How the report is produced

The provider suites run from their build directories the same way the FDO Core suite does, but GDAL
and SHP need FDO installed at its packaging location first:

```sh
# inside the interactive build container
export NLSPATH=/tmp/work/build_area/fdo/nls/linux/en_US/%N
cmake --build . --target install

cd Providers/SDF/Src/UnitTest  && ./UnitTest
cd Providers/GDAL/Src/UnitTest && LD_LIBRARY_PATH=/usr/local/fdo-4.2.0/lib64 ./UnitTest
cd Providers/WFS/Src/UnitTest  && ./UnitTest   # queries public WFS servers
cd Providers/WMS/Src/UnitTest  && ./UnitTest   # queries public WMS servers
```

The WMS suite is opt-in in `run_fdo_tests.sh` (`--with-wms`), like the public-server WFS suite, because
its results depend on hosts that come and go. Its registry name can also be passed to the unit test
binary to run a single suite, which is how the leaks below were attributed to individual tests:

```sh
cd Providers/WMS/Src/UnitTest
./UnitTest WmsTestCustomCommands
```

The SHP suite additionally needs the system locales (`en_US`, `en_US.UTF-8`, `fr_FR`, `ja_JP.EUC-JP`)
and a reset of `Providers/SHP/TestData` from the sources; `run_fdo_tests.sh` does both before it runs
the suite.

Records are aggregated by allocation stack, so a record shows the *allocating* frames, not the
ownership chain that failed to release an object. A record is *direct* when the chunk is not
reachable from any root at exit, and *indirect* when it is only reachable from another leaked chunk.
The recurring shapes in these suites are:

- **A caught exception chained as a cause but never released.** `FdoException::Create(message, cause)`
  and `FdoException::SetCause(cause)` both AddRef the cause (the outer exception owns it), but the
  code that created it still holds its own reference and must release it — `e->SetCause(Create(...))`
  leaks the cause.
- **A caught exception that is neither rethrown nor released** (in particular an empty
  `catch (...)`, which loses the reference to an `FdoException*` entirely).
- **A raw pointer that outlives an exception.** When the release of a resource is written on the
  normal path only (e.g. after the reader is built), an exception thrown between acquisition and
  release leaks it.
- **A reference returned by an AddRef'ing getter that is dropped.** FDO collections return AddRef'd
  items from `GetItem()`/`FindItem()`, and `FdoPtr(T*)` *attaches* without adding a reference, so
  wrapping the result of a `dynamic_cast` (which may be `NULL`) in an `FdoPtr` silently drops the
  reference whenever the cast fails.
- **A destructor that does not exist.** A constructor that throws runs no destructor, so anything
  acquired on the way in has to be released in a `catch (...)` block.
- **A value the parser discards on its error path.** A grammar whose actions hand a freshly
  created object to a *second* owner (here `AddNode()`/`AddNodeToDelete()` AddRef into the parse
  context) leaves the parser holding a reference it only releases when the symbol reaches a
  reduction. A syntax error discards symbols instead, so every node on the stack at the error
  leaks - and for a grammar that parses "is this a constraint I understand?" clauses, an error is
  the normal answer, not an exceptional one. Fix it with `%destructor` declarations (see
  **Generated parsers** below); releasing the values from the parse context's abort path instead
  would over-release the nodes whose stack reference an action already consumed.
- **A recursion that re-references its own result.** A function that hands back an owned reference and
  then returns `FDO_SAFE_ADDREF(Recurse(...))` drops the reference the recursive call returned — one
  leaked reference per level of depth, on whichever object the recursion ended up finding. Pass the
  result through instead.
- **An owned raw pointer with nobody to release it.** A member, or a container of raw pointers,
  populated with the result of a `Create()` or of an AddRef'ing call is freed only if something
  explicitly releases it: `std::map::clear()` and a defaulted destructor do not, so the objects stay
  alive for the life of the process. Release the elements as the container is emptied — `FdoPtr` is
  only ever used as a local or as a class member, never as a container element.
- **A second call that overwrites the handles the first one set up.** An `Open()` that re-creates the
  environment, schema and databases it owns leaks everything the previous call created. Releasing
  that state first is the fix; turning the second call into a no-op is not, because a caller is
  allowed to change connection properties on a live connection and then re-open it to have them
  applied.
- **A helper that holds a counted reference to the object that owns it.** A capability or processor
  created by a connection and stored in one of the connection's raw members, which then AddRefs the
  connection, forms a reference cycle: the connection can never reach zero references, so its whole
  graph — schema manager, cached schema elements, DB handles and capability caches (for an expression
  capability, the whole deep-copied standard-functions graph) — is leaked, and it leaks it *per
  connection*. The destructor cannot break the cycle because it never runs. Such helpers must keep a
  non-owning back-pointer; the connection already owns the helper.

## Leaks that were fixed

| Suite | Defect | File(s) | Mechanism |
|---|---|---|---|
| GDAL | `FdoRfpConnection::SetConfiguration` nested a parse failure as a cause without releasing the caught exception | `Providers/GDAL/Src/Provider/FdoRfpConnection.cpp` | The 3 `ReadXml` catch blocks now hold the caught exception in an `FdoPtr<FdoException>` before wrapping it, so the incoming reference is released even though the new exception owns the cause. This was the entire GDAL leak (4 exception objects plus their message buffers). |
| SHP | `ShpConnection::GetLpSchema` nested a schema-not-found failure without releasing the caught exception | `Providers/SHP/Src/Provider/ShpConnection.cpp` | Same cause-ownership fix. |
| SDF | `SdfConnection::Open` nested a "not an SDF file" failure without releasing the caught exception | `Providers/SDF/Src/Provider/SdfConnection.cpp` | Same cause-ownership fix. |
| SDF | `SdfConnection::Open` re-initialised `m_env` / `m_dbSchema` / `m_dbExtendedInfo` on every call | `Providers/SDF/Src/Provider/SdfConnection.cpp` | `Open()` overwrote the handles it owns, so `MasterTest::selectSpatialExtentsTest` — which opens the same connection twice — leaked the first open's SQLite database graphs (this was the single largest SDF leak). `Open()` still re-runs its initialisation, because a caller that changes connection properties on a live connection depends on that, but it releases the previous open's databases, schema and environment (`CloseDatabases()`) first. `CloseDatabases()` clears `m_bCreate`, so that caller-set flag is restored around it. |
| SDF | `SdfUpdate::Execute` only released the optimizer's filter on the success path | `Providers/SDF/Src/Provider/SdfUpdate.cpp` | The optimized filter is held in an `FdoPtr<FdoFilter>` and the reader in an `FdoPtr<SdfUpdatingFeatureReader>`, so a constraint violation raised while validating the update (which throws out of the reader constructor) still releases both. |
| SDF | `SdfSelect::Execute` same raw-filter-on-the-success-path issue | `Providers/SDF/Src/Provider/SdfSelect.cpp` | Same `FdoPtr` treatment for the optimized filter and for the computed-property definition collection returned by `ProcessComputedIdentifiers()`. |
| SDF | `FdoExpressionEngineUtilDataReader` constructor left raw members behind when it threw | `Utilities/ExpressionEngine/Src/Util/FdoExpressionEngineUtilDataReader.cpp` | A throwing constructor does not run the destructor, so the raw members (`m_resultsStack`, `m_binReader`, `m_propIndex`, the order-by readers) are now released in a `catch (...) { ...; throw; }`. |
| SHP | `ShpLpClassDefinition::ConvertLogicalToPhysical` overwrote `m_physicalColumns` | `Providers/SHP/Src/Provider/ShpLpClassDefinition.cpp` | A class definition that had already been populated by `ConvertPhysicalToLogical()` leaked its `ColumnInfo` (which owns a variable-length buffer allocated by a custom `operator new`); the old column info is now deleted first. |
| SHP | `ShpSelectAggregates::Execute` leaked `selAggrList` when no aggregate could be optimised | `Providers/SHP/Src/Provider/ShpSelectAggregates.cpp` | The empty list (and the list left behind by the non-optimizable path) is now deleted before falling back to the generic select-aggregates path. |
| SHP | Test code did not release AddRef'ing getters and `Create()` results | `Providers/SHP/Src/UnitTest/FdoExpressionFunctionTest.cpp` | `TestXYZMFunction` leaked the whole standard-functions graph returned by `GetExpressionCapabilities()` / `GetFunctions()`; those, and the reassigned locals in `AddXYZMFeature`, are now held in `FdoPtr`. This accounted for ~570 KB of the SHP report. |
| SDF | `SdfQueryOptimizer::recno_list_intersection` returned from inside the merge loop | `Providers/SDF/Src/Provider/SdfQueryOptimizer.cpp` | The two `return ret;` statements sat inside the loop, past the `delete left; delete right;` the caller is documented to rely on; reaching the end of either input skipped the disposal. They now `break` so the common disposal runs. |
| SDF | `SdfQueryOptimizer::recno_list_union` returned the non-`NULL` input when the other was `NULL` | `Providers/SDF/Src/Provider/SdfQueryOptimizer.cpp` | The union of "all features" (`NULL`) with a feature list is still "all features", so it now disposes of both inputs and returns `NULL` instead of leaking the list it did not return. |
| SDF | `SdfQueryOptimizer::ProcessSpatialCondition` shadowed `rl` in the non-axis-aligned branch | `Providers/SDF/Src/Provider/SdfQueryOptimizer.cpp` | The inner `recno_list* rl = new recno_list;` hid the outer variable, so the R-Tree result was leaked *and* `NULL` pushed as the condition's result. The branch now assigns to the outer variable. |
| SDF | `SdfQueryOptimizer::ProcessSpatialCondition` pushed no result for a geometry with unusable extents | `Providers/SDF/Src/Provider/SdfQueryOptimizer.cpp` | The Intersects/Contains/Within/Inside/Crosses branch only pushed a feature list inside its bounds check, leaving the filter stack and the result stack out of step; `GetResult()` then dropped the surplus entries. It now pushes `NULL` ("no features excluded") in that case. |
| SDF | `SdfDeletingFeatureReader` leaked the pending feature keys when it was not read to the end | `Providers/SDF/Src/Provider/SdfDeletingFeatureReader.cpp` | The `BinaryWriter`s accumulated in `m_keysToDelete` were only freed by the `ReadNext()` call that reports the end of the reader; the destructor now frees whatever is left, and `ReadNext()` clears the vector once it has disposed of them. |
| SDF | `SdfImpExtendedSelect::ExecuteScrollable` wrapped a `dynamic_cast` of an AddRef'd collection item in an `FdoPtr` | `Providers/SDF/Src/Provider/SdfImpExtendedSelect.cpp` | `FdoPtr<FdoComputedIdentifier> id = dynamic_cast<FdoComputedIdentifier*>(selectList->GetItem(i))` dropped the reference held by `GetItem()` whenever the item turned out not to be a computed identifier, leaking every select-list identifier (the last 960 B of the SDF report). The item is now held in an `FdoPtr<FdoIdentifier>` and the cast result is a raw pointer; the same treatment is applied to the `props->FindItem()` cast next to it. |
| SDF | `FdoExpressionEngineImp::PushIdentifierValue` copied a String property value onto the heap and handed it to an API that copies again | `Utilities/ExpressionEngine/Src/FdoExpressionEngineImp.cpp` | The `FdoDataType_String` case allocated `new wchar_t[...]` and passed it to `ObtainStringValue()`, which only copies the text into an `FdoStringValue`; the buffer leaked once per string property read (7 records). The copy is gone — the reader's string is passed directly. |
| SDF | DateTime range-constraint values were read into raw pointers | `Utilities/TestCommon/Src/TestCommonConstraints.cpp` | `FdoDataValue* valMin = pConstrR->GetMinValue();` (and `valMax`) dropped the reference returned by the AddRef'ing getters, leaking the four `FdoDateTimeValue` objects read by `SchemaDb::ReadDataPropertyDefinition`'s range-constraint path. Both are now `FdoPtr<FdoDataValue>`. |
| SDF+SHP | `TestSubstrFunction`'s "expected error" catch never released the exception it matched | `Utilities/TestCommon/Src/TestCommonExpressionFunctionW.cpp`, `Providers/SHP/Src/UnitTest/FdoExpressionFunctionTest.cpp` | The test asserts on the message of the exception the provider throws for `Substr(byte_val, 2)`; the matching branch fell through without releasing it (only the mismatch branch rethrew). The matched exception is now released. |
| SHP | `ShpLpClassDefinition` constructor leaked its `ColumnInfo` when construction failed | `Providers/SHP/Src/Provider/ShpLpClassDefinition.cpp` | The class registers itself with its parent schema at the end of the constructor, and that registration can throw (duplicate class name). A throwing constructor runs no destructor, so the column info allocated by the conversion is now freed in a `catch (...) { ...; throw; }`. `ConvertLogicalToPhysical`'s existing catch also nulls the member so the destructor cannot double free it. |
| SHP | `ShpConnection::CreateSpatialContext` and `GetPhysicalSchema` dropped the reference returned by `ShpSpatialContextCollection::FindItem()` | `Providers/SHP/Src/Provider/ShpConnection.cpp` | `while (mSpatialContextColl->FindItem(newName))` (two name-deduplication loops) discarded an AddRef'd spatial context per hit; each lookup is now held in an `FdoPtr` on the iteration. |
| SHP | `ShpLpClassDefinition::ConvertLogicalToPhysical` kept raw pointers around the spatial context lookups used to write the PRJ file | `Providers/SHP/Src/Provider/ShpLpClassDefinition.cpp` | `ShpSpatialContextCollection* scs = m_connection->GetSpatialContexts();` left the connection's collection AddRef'd forever (48 B) and `ShpSpatialContext* sc = scs->GetItem(scName);` did the same for the spatial context just created by `CreateSpatialContext` (160 B, plus its WKT/name buffers). Both are now `FdoPtr`s. |
| SHP | Test code swallowed the exception thrown by `FdoIConnection::Open()` | `Providers/SHP/Src/UnitTest/SelectTests.cpp` | `analyze_polygons()` and `select_large_geometries()` skipped unusable test files with an empty `catch (...)`, losing the `FdoException*` that `Open()` threw from `InitConnectionPaths()`. Both now catch `FdoException*`, release it, and continue. |
| WFS | `FdoWfsConnection::Close` cleared `mSchemaMap` without releasing the schema collections the map owned | `Providers/WFS/Src/Provider/FdoWfsConnection.h`, `Providers/WFS/Src/Provider/FdoWfsConnection.cpp` | The map held raw pointers whose reference was added on insert (`mSchemaMap.emplace(cName, FDO_SAFE_ADDREF(...))`), so `clear()` — and the defaulted destructor — dropped them instead of releasing them, leaking a whole schema collection per cached class name (128 B). It keeps its raw pointers and now empties itself through a `_disposeSchemaMap()` helper that releases every value and then clears, which both `Close()` and the destructor call, so neither path can drop an element. |
| WFS | `FdoWfsDescribeSchemaCommand` never released `mClassNames` | `Providers/WFS/Src/Provider/FdoWfsDescribeSchemaCommand.h` | The command created its string collection with `FdoStringCollection::Create()` into a raw member and had an empty destructor, so every DescribeSchema command leaked it (32 B); `SetClassNames` also leaked the collection it replaced. The member is a `FdoStringsP` now, which releases the old collection on reassignment and the current one on destruction. |
| WFS | The WFS test suite discarded the result of `FdoISpatialContextReader::GetExtent()` | `Providers/WFS/Src/UnitTest/WfsTestSpatialContexts.cpp` | The `_DEBUG` dump block called `reader->GetExtent()` twice and threw the first result away; `GetExtent()` returns a new `FdoByteArray` that the caller owns (184 B, plus the polygon buffer it wraps in the FGF geometry factory). The first call is held in an `FdoPtr` now, as the second one already was. |
| King Oracle | `FilterProcessorTests` started each test with a `DROP TABLE` cleanup whose failure it swallowed with a nameless catch | `Providers/KingOracle/src/KgOraUnitTest/FilterProcessorTests.cpp` | `catch (FdoException *) { }` (3 places) lost the exception `c_KgOraSQLCommand::ExecuteNonQuery` throws when the table does not exist yet, leaking the exception object (40 B) and its message buffer (164 B) per test. Each catch now names the exception and releases it. |
| WMS | `FdoOwsHttpHandler::_translateError` passed a freshly created exception straight to `FdoException::SetCause` | `Utilities/OWS/Src/FdoOwsHttpHandler.cpp` | `SetCause` takes a reference of its own (`FDO_SAFE_ADDREF(cause)`), so nesting `e->SetCause(FdoException::Create(...))` leaked the cause: the creating reference was never dropped. The 3 HTTP-returned-error/default branches now create the cause into a local, hand it to `SetCause`, and release it, the same treatment `FdoWmsServiceMetadata` already had. |
| WMS | The suite's "this server used to work" tests threw their exception away | `Providers/WMS/Src/UnitTest/*.cpp` | These tests assert that a *dead* server still fails, so they replaced `catch (FdoException* e) { fail(e); }` with a bare `catch (...) { failed = true; }`, and the handle of the exception `FdoOwsHttpHandler::Perform()` throws out of `FdoIConnection::Open()` was lost. 15 such catches (14 `catch (...)`, plus the nameless `catch (FdoException*)` in `WmsTestSelect::testServer1`) now name the exception, release it, and still record the failure. 6 of the suite's 7 direct leaks were this pattern — one 40 B exception per test that reached a throwing `Open()`; the 7th was the `SetCause` cause below, which these tests leaked indirectly as well. |
| WMS | `FdoWmsConnection::FindLayer` kept one reference per recursion level on the layer it found | `Providers/WMS/Src/Provider/FdoWmsConnection.cpp` | The recursive branch took the owned reference the recursive call returned and wrapped it in another `FDO_SAFE_ADDREF`, dropping the first, so a layer found at depth *d* came back carrying *d* references that nobody owned — the deeper the layer, the more it leaked. Once the capabilities tree was destroyed, a looked-up layer could no longer reach zero references and stayed alive with everything it owns (its child-layer, style, dimension and bounding-box collections, its styles, bounding boxes and string buffers) — the 141,904 B that remained in the WMS report after the direct leaks were plugged. The function returns exactly one owned reference on every path now: a direct hit takes its own reference while the loop-local `FdoPtr` is still alive, and a recursive hit is passed through instead of being re-AddRef'd. |
| MySQL | `FdoRdbmsPvcInsertHandler` never initialised, and its destructor never freed, the query cache slots | `Providers/GenericRdbms/Src/Fdo/Pvc/FdoRdbmsPvcInsertHandler.cpp` | The default constructor left all `QUERY_CACHE_SIZE` (10) slots with indeterminate `qid`/`bindHelper`/`bindProps`, and the destructor only cleaned up when `qid != -1` *and* the connection was open, so the bind helper and property bindings of every unused slot leaked — 2 sites × 75,088 objects, 4.2 MB, the largest single item in the report. The constructor now initialises every slot and the destructor walks all of them, keeping only the cursor release conditional on an open connection. |
| MySQL | `FdoRdbmsSelectCommand::GetOptimizedFeatureReader` leaked its aggregate-select list when it fell back to the generic reader | `Providers/GenericRdbms/Src/Fdo/FeatureCommands/FdoRdbmsSelectCommand.cpp` | `FdoRdbmsConnection::GetOptimizedAggregateReader()` returns `NULL` for the base class *without* taking ownership of `selAggrList` (only the SQLServer override may consume it), so the list and its elements were leaked on every non-optimizable aggregate select. Both are now disposed when the returned reader is `NULL`. |
| MySQL | `FdoRdbmsMySqlFilterCapabilities` held a counted reference back to its own connection | `Providers/GenericRdbms/Src/MySQL/Fdo/FdoRdbmsMySqlFilterCapabilities.h`, `.../FdoRdbmsMySqlFilterCapabilities.cpp` | The constructor did `m_parent = FDO_SAFE_ADDREF(parent)` for a `FdoPtr<FdoRdbmsMySqlConnection>` member. The connection stores this object in its raw `mFilterCapabilities` member, so the pair formed a cycle: the first `GetFilterCapabilities()` call (made by `FdoRdbmsSelectCommand::Execute`) made the connection un-freeable, which leaked the connection's whole graph — its schema manager and everything the schema cache had read, the MySQL client handles, the connection property dictionary, and the deep-copied standard-functions graph cached by its expression capabilities (5.4 MB alone). `m_parent` is a non-owning `FdoRdbmsMySqlConnection*` now, matching the raw back-pointer `FdoRdbmsSelectAggregates::mIConnection` already uses. |
| MySQL | Test code leaked connections, commands and readers by holding them in raw pointers | `Providers/GenericRdbms/Src/UnitTest/MySql/MySqlFdoForeignSchemaTest.cpp` | `create_foreign_datastore()` held the connection from `UnitTestUtil::GetProviderConnectionObject()` — an owned reference — in a raw pointer and never released it, and `insert()` did the same for the `FdoIInsert` and the `FdoIFeatureReader`. A leaked command keeps its AddRef'd connection alive (`FdoRdbmsFeatureCommand`'s constructor adds one), so the connection, its PVC processor and its entire schema/DB graph survived the test; 3 connections, 1.3 MB. All three are `FdoPtr`s now. |
| MySQL | Test code swallowed the exception the provider throws for an unsupported function argument | `Providers/GenericRdbms/Src/UnitTest/Common/FdoExpressionFunctionTest.cpp` | `TestExtractFunction` and `TestExtractToDoubleFunction` assert that `EXTRACT`/`EXTRACTTODOUBLE` reject a string argument, and both wrapped the call in `catch (...) { test_failed = true; }`, losing the `FdoCommandException*` that `FdoRdbmsSelectCommand::Execute` throws (it wraps the underlying `FdoException`). Each of the 4 call sites now catches `FdoException*` first, releases it and still records the failure, leaving the `catch (...)` for CppUnit's own exceptions. |
| MySQL | `SchemaMgrTests::testViews` released its static connection only when the test failed | `Providers/GenericRdbms/Src/UnitTest/Common/SchemaMgrTests.cpp` | The method re-creates its `StaticConnection` half-way through (after dropping the original) and the three `catch` blocks were the only places that deleted it, so a *passing* run leaked the second connection with its MySQL context (`StaticConnection::connect`), schema manager and cached physical schema objects (67 KB). It is now deleted after the catch chain, where the try block's schema-manager locals are already gone. |
| MySQL | `mysql_connect` never closed the client handle when `mysql_real_connect` failed | `Providers/GenericRdbms/Src/MySQL/Driver/connect.cpp` | The failure branch set the error message and returned `RDBI_GENERIC_ERROR` without storing the handle in the connection pool — and without `mysql_close()`-ing the handle `mysql_init()` had just allocated, so every failed connect (bad password, unknown host) leaked the whole client connection state. The sibling "unsupported client/server version" branch already closed it. |
| MySQL | Test helpers did not release AddRef'ing getters and `Create()` results | `Providers/GenericRdbms/Src/UnitTest/Common/SchemaMgrTests.cpp`, `.../Common/FdoConstraintsTest.cpp`, `.../Common/FdoExpressionFunctionTest.cpp`, `.../MySql/MySqlGeometryTests.cpp` | `testGenKeys` re-assigned its static connection without disposing the schema manager first; `TestParser(FdoString*)` dropped the constraint `ParseConstraint` returned; `ExecuteTestExtractToIntFunction`'s expected-error branch dropped the exception; `do_insert_geometry` dropped the `char*` returned by `get_geometry_text()`. Each is now an `FdoPtr` (or a `delete []`), and the static-connection re-creation disposes the manager before the connection. |
| MySQL | Test code dropped the counted references `SmartCast()` returns for the owner and its character set | `Providers/GenericRdbms/Src/UnitTest/MySql/MySqlFdoApplySchemaTest.cpp`, `.../MySql/MySqlSchemaMgrTests.cpp` | `TestCharSize` and `testWideConstraint` read the owner's character-set length as `owner->SmartCast<FdoSmPhMySqlOwner>()->GetCharacterSet()->SmartCast<FdoSmPhMySqlCharacterSet>()->GetCharLen()`. `SmartCast()` AddRefs the object it casts — it exists so the result can be handed straight to an `FdoPtr` — so the inline use left both the owner and the character set with an unowned reference. `FdoSmPhSchemaElement` keeps only a *raw* pointer to its physical schema manager, so the one lost owner reference kept the whole physical schema (databases, owners, tables, columns, cached meta-schema) unreachable-but-alive: LSan reported the owner as the root of its own leak group with ~331 KB hanging off it. Every `SmartCast()` result is held in an `FdoPtr` now. |
| MySQL | `FdoRdbmsMySqlFilterProcessor::HasNativeSupportedFunctionArguments` dropped the arguments collection of every `STDDEV` function it inspected | `Providers/GenericRdbms/Src/MySQL/Fdo/FdoRdbmsMySqlFilterProcessor.cpp` | `FdoFunction::GetArguments()` returns a counted reference, and `(expr.GetArguments()->GetCount() > 1) ? false : true` dereferenced it inline, dropping it — one leaked argument collection per aggregate-function test that reached this check. It is held in an `FdoPtr` now. |
| MySQL | `SmartCast()` results used inline leaked a reference to the physical schema manager | `Providers/GenericRdbms/Src/SchemaMgr/Ph/Cfg/ClassReader.cpp`, `.../SchemaMgr/Ph/Cfg/PropertyReader.cpp`, `Providers/GenericRdbms/Src/ODBC/SchemaMgr/Lp/Schema.cpp` | The same rule as above: `GetManager().p->SmartCast<FdoSmPhGrdMgr>()->ClassifyDbObject(...)` (the config class and property readers) and `GetPhysicalSchema()->SmartCast<FdoSmPhOdbcMgr>()->GetRdbiContext()` used the cast result inline, leaving an unowned reference on the physical schema manager per call and so keeping the whole physical schema graph alive. Each cast is loaded into an `FdoSmPhGrdMgrP`/`FdoSmPhOdbcMgrP` local first. |

| PostGIS | A cursor's previous result was overwritten instead of cleared on re-execution | `Providers/GenericRdbms/Src/PostGis/Driver/execute.c` | `postgis_execute()` assigned `curs->stmt_result = PQexecPrepared(...)` without clearing what was already there. The PVC insert/update handlers keep their cursors cached and run the same prepared statement once per row, so every row but the last leaked a libpq `PGresult` (and everything it holds) — 486/405/180-object records, the largest item in the PostGIS report. `fetch.c` already cleared before re-assigning; `execute.c` now does the same. |
| PostGIS | Two `PQexec` results in `postgis_run_sql` were discarded | `Providers/GenericRdbms/Src/PostGis/Driver/run_sql.c` | The two `(void)PQexec(conn, "COMMIT")` calls that close an open transaction before a DDL statement threw their `PGresult` away, leaking it (plus the `PQgetResult` machinery behind it) once per DDL statement — 58 records, mostly from the schema-manager delete/apply paths. Both results are captured and passed to `postgis_pgresult_clear` now, as every other `PQexec` in the driver already was. |
| PostGIS | The filter processor kept the counted reference `GetGeometry()` returns in a raw pointer | `Providers/GenericRdbms/Src/PostGis/Fdo/FdoRdbmsPostGisFilterProcessor.cpp` | `FdoSpatialCondition::GetGeometry()`/`FdoDistanceCondition::GetGeometry()` return `FDO_SAFE_ADDREF(m_geometry)`, and `ProcessSpatialDistanceCondition` stored that in a raw `FdoGeometryValue*` (`geom = dynamic_cast<...>(spatialFilter->GetGeometry())`), so the test geometry of *every* spatial and distance condition leaked (13 records). Every other provider already holds it in an `FdoPtr`, as does this one now. `geomFgf`, the byte array `FdoGeometryValue::GetGeometry()` AddRefs, was raw too and leaked with it. |
| PostGIS | The constraint grammar stranded the semantic values of every symbol the parser discards on a syntax error | `Utilities/Common/Src/Parse/yyConstraint.y`, `yyConstraint.cpp`, `yyConstraintWin.cpp` | Each node-producing nonterminal's value is an owned reference (created with `Create()`, then AddRef'd into the parse context by `AddNode()`/`AddNodeToDelete()`), and the parser never released its own copy when a syntax error discarded a partially built constraint — which is the *normal* path for the check clauses this provider skips. `%destructor` declarations for the 18 node-producing nonterminals, plus the equivalent destructor in both generated parsers, release it: 6 direct records and the 12 objects below them (888 B in 18 allocations) go, with no new record family. See **Generated parsers** below — the generated files could not be reproduced by today's generators and are therefore hand-patched in step with the `.y`. |
| SQLite | The r8375 spatial-context test dropped the counted references of every `Create()` result and AddRef'ing getter in its insert and describe-schema steps | `Providers/SQLite/Src/UnitTest/SpatialContextTest.cpp` | `TestDefaultSpatialContext` added its two property values as `vals->Add(FdoPropertyValue::Create(...))`, and `Add()` takes its own reference, so the reference `Create()` returned was lost — 40 B each, the report's only 2 **direct** records. The describe-schema step then wrote `schemas->GetItem(0)->GetClasses()->GetItem(L"FeatClass1")`, which drops the counted references of the schema and of its class collection, and parked `((FdoFeatureClass*)cls.p)->GetGeometryProperty()` — which returns `FDO_SAFE_ADDREF(m_geometry)` — in a raw pointer. That last reference is what keeps the leak large rather than small: it points *into* the deep-copied schema graph, so the whole graph goes unreachable-but-alive when the test returns, and every one of its chunks is then reported as an indirect record reachable from another. Together they were the entire report: 5,712 B in 75 allocations (2 direct, 72 indirect), all in this one test. Restoring the two `Add()` calls alone, leaving the describe-schema references dropped, leaves **0 direct records and 62 indirect records (5,184 B)**: the 80 B of property values and the 448 B of geometry-value and string-value records they anchored are gone, while the schema graph, still held by the un-released `GetGeometryProperty()` reference, is not. That is what attributes the 5,184 B residue to the describe-schema references rather than to a reference cycle inside the copied schema. Each result is held in an `FdoPtr` now and the suite reports **0 B**. |
| OGR | `OgrFeatureReader`'s spatial-filter geometry passed the counted reference returned by `FdoGeometryValue::GetGeometry()` inline into `CreateGeometryFromFgf()`, dropping it | `Providers/OGR/Src/Provider/OgrProvider.cpp` | `FdoGeometryValue::GetGeometry()` returns `FDO_SAFE_ADDREF(m_geometry)`. For every spatial condition whose operation is not `EnvelopeIntersects`, the reader built its filter geometry as `m_geomFilter = gf->CreateGeometryFromFgf(((FdoGeometryValue*)(geomExpr.p))->GetGeometry())`, so the reference the getter returned was never released; the byte array behind it — a pooled `FdoByteArray` that `FdoFgfGeometryFactory::GetFgf()` had shared out — stayed alive but unreachable, the suite's only record (184 B, direct). Holding the getter's result in an `FdoPtr<FdoByteArray>` local releases it. |

## Status

| Suite | Log | Before | After |
|---|---|---|---|
| GDAL | `artifacts/Debug/test-logs/GDAL_unit_test_log.txt` | 28,380 B in 68 allocations | 0 B |
| SHP | `artifacts/Debug/test-logs/Shp_unit_test_log.txt` | 617,880 B in 9,783 allocations | 0 B |
| SDF | `artifacts/Debug/test-logs/Sdf_unit_test_log.txt` | 170,243 B in 2,760 allocations | 0 B direct; 55,925 B in 538 allocations (348 indirect records) |
| SQLite | `artifacts/Debug/test-logs/SQLite_unit_test_log.txt` | 0 B in this pass; 5,712 B in 75 allocations (2 direct records) after r8375 added the "Default" spatial-context test | 0 B |
| WFS | `artifacts/Debug/test-logs/Wfs_unit_test_log.txt` | 82,112 B in 938 allocations (3 direct) | 0 B direct; 64,564 B in 758 indirect |
| WMS | `artifacts/Debug/test-logs/Wms_unit_test_log.txt` | 145,128 B in 1,426 allocations (7 direct) | 0 B |
| OGR | `artifacts/Debug/test-logs/OGR_unit_test_log.txt` | 184 B in 1 allocation (1 direct record) | 0 B |
| King Oracle | (opt-in suite, run against the `dbs` compose Oracle) | 408 B in 4 allocations (2 direct) | 0 B |
| PostGIS | `artifacts/Debug/test-logs/PostGis_unit_test_log.txt` | 1,930,054 B in 15,841 allocations (730 direct records) | 0 B direct; 105,212 B in 942 allocations (388 indirect records) |
| MySQL | `artifacts/Debug/test-logs/MySql_unit_test_log.txt` | 10,068,363 B in 261,631 allocations (356 direct records) | 0 B direct; 46,236 B in 491 allocations (318 indirect records) |

Suite results are unchanged and green: GDAL `OK (65 tests)`, OGR `OK (57)`, SHP `OK (138)`, SDF `OK (118)`,
SQLite `OK (90)`, King Oracle `OK (33)` (opt-in, needs the `dbs` compose Oracle), MySQL `OK (246)`
(needs the `dbs` compose MySQL 5.6), PostGIS `OK (137)` (needs the `dbs` compose PostGIS), and
FDO Core
`OK (123)` still reports the 220,980 B of documented
`FdoClassDefinition` reference cycles described in the FDO Core note. The WFS suite is opt-in
(`run_fdo_tests.sh --with-wfs`) because it queries live public WFS servers, and it is *not* green:
`Run: 6   Failure total: 4`, with the failures being assertions on server-supplied capabilities and
schema counts (and unreachable hosts) rather than on the provider's own behaviour. Because of that its
figures are a lower bound — the paths that ran are the ones the reachable servers exercise.

SDF, SHP, WMS, WFS, MySQL and SQLite (with the r8375 test fixed) now report no direct leaks at all, and
WMS and SQLite report none of either kind.
SDF, WFS, MySQL and FDO Core still report indirect leaks, and so does PostGIS (only the schema-error cycle
now that the parser's direct records are gone); the SDF indirect total is what remains of the two
`SdfConnection` graphs the suite leaves
behind; its largest contributors are the connection's SQLite database
(`SdfConnection::InitDatabases`, `sqlite3GenericMalloc`, the property-index hashtable nodes), the
`FdoClassDefinition` graphs reachable from it (`FdoDataPropertyDefinition`, `FdoFeatureClass`, the
schema-element attributes) and their string buffers. The WFS indirect leaks are the same
`FdoClassDefinition` graphs — every remaining record allocates beneath
`FdoXmlReaderXrcs::startElement` → `FdoClassDefinition::XmlStartElement` → `Fdo...::Create()` while
the DescribeFeatureType/DescribeSchema tests read a schema, with no WFS frame in the chain at all, so
they are the FDO XML/schema layer's cycles rather than a WFS ownership bug. As with FDO Core,
breaking that needs a semantic change (weakening the connection-to-reader strong references) rather
than a reference-count fix, so it is recorded here rather than fixed in this pass.

The WMS leftovers turned out to be a WMS ownership bug one level up rather than a cycle in the FDO XML
layer: `FdoWmsConnection::FindLayer` (the lookup that the style/CRS-name/select/spatial-extents
commands all go through) leaked one reference per recursion level on the layer it found, so a layer
that had been looked up could no longer be freed once the capabilities tree was released, and it kept
its whole subtree alive. Finding it needed temporary instrumentation — reference tracing on
`FdoWmsLayer::AddRef`/`Release`, a registry of live layers dumped at every lifecycle point
(connection, metadata, capabilities destructors and `atexit`), and destructor tracing — because the
leak report alone says only that the surviving chunks point at each other. The measurements showed the
parse-time tree healthy (all 16 layers at refcount 1, freed by the capabilities destructor) and the
same layers at refcount 3 after the commands had run: one reference for the collection that owns them
and one per level of the `FindLayer` recursion that had found them.

The MySQL suite was the largest single report (10,068,363 B in 261,631 allocations) and, unlike the
others, no single fix carried it: the 4.2 MB `FdoRdbmsPvcInsertHandler` slot leak, the aggregate-select
list and the test-code ownership fixes took it to 5,966,935 B, and what was left was a *per-connection*
graph repeated ten times over — ten copies of the whole deep-copied standard-functions graph
(15,620 `FdoArgumentDefinition` objects), ten schema managers and ten sets of MySQL client handles,
with no connection record anywhere in the report because the leaked chunk was reachable from another
leaked chunk. The suite's multi-thread test was the way in: it prints the result of its final
`Release()` (the FDO `Release()` returns the new reference count), all ten connections came back as
`1` instead of `0`, and a temporary `AddRef`/`Release` override on `FdoRdbmsConnection` that printed a
backtrace per call showed the unmatched reference coming from
`FdoRdbmsMysqlFilterCapabilities::FdoRdbmsMysqlFilterCapabilities(FdoRdbmsMySqlConnection*)` — the
filter capabilities' constructor AddRef'ing the connection that owns it, i.e. a cycle. Making that
back-pointer non-owning emptied that graph out.

What was then left (332,594 B in 3,405 allocations) still named a *root* the report could not explain:
17 records of which only 9 were direct — one `FdoSmPhMySqlOwner`, two `FdoSmPhCharacterSet`s and six
`FdoExpressionCollection`s — with the other ~331 KB hanging off them. The giveaway was that a
`FdoSmPhOwner` can never own its physical schema manager, yet the physical schema manager's own
members (the 262 reserved-word `std::map` nodes of two `FdoSmPhGrdMgr` instances, the databases, the
tables and 59 columns) were all *below* that owner in the leak graph. It could only be there through
`FdoSmPhSchemaElement`'s **raw** `mpManager` back-pointer, which LeakSanitizer follows like any other
pointer: the owner was genuinely unreachable (a lost reference) while everything it *pointed at* was
still alive. The lost reference was one call in each of two tests —
`owner->SmartCast<FdoSmPhMySqlOwner>()->GetCharacterSet()->SmartCast<FdoSmPhMySqlCharacterSet>()->GetCharLen()`
— because `SmartCast()` returns a counted reference that the caller must hand to an `FdoPtr`, and
using it inline drops it. Holding each result in an `FdoPtr`, plus the same fix for
`FdoFunction::GetArguments()` in `FdoRdbmsMySqlFilterProcessor` and the inline `SmartCast()` casts in
the config readers, took the report to **0 direct leaks**: 46,236 B in 491 allocations.

That remainder is a rootless reference cycle rather than a lost reference — with no *direct* record
left, every surviving chunk is pointed at by another surviving chunk and LeakSanitizer can only
attribute them to each other (the same shape as the SDF and WFS residues). Its records are all
allocated in the suite's deliberate-error paths: the circular base-class/association tests
(`FdoAssociationSchemaTest::TestCreate`, reached through the association insert and select tests) and
`FdoApplySchemaTest::CreateErrorSchema`. They are the logical class and property definitions, their
FDO-level counterparts and the errors collected against them
(`FdoSmLpObjectPropertyDefinition::AddReferenceLoopError` → `FdoSmError` → `FdoSchemaException`).
Breaking that needs the error/association ownership in the schema manager to change — the same kind of
semantic change the FDO Core, SDF and WFS cycles need — so it is recorded here rather than fixed in
this pass. No connection, MySQL client handle or PVC processor is in the report, and the suite that
used to leave every one of its connections behind in the multi-thread test now releases all 30 of them
to zero references.

The PostGIS report was the second largest (1,930,054 B in 15,841 allocations, 730 direct records) and
it had the same character as the MySQL one: a handful of ownership bugs repeated across many cursors
and commands. Literally reusing the MySQL fixes helped — and one of them had already been applied to
the shared GenericRdbms PVC handler, which removed 284 of the 730 direct records (184 KB) before any
PostGIS-specific work started. The rest was three leaks in the provider and its driver:

  * the driver's `postgis_execute()` overwrote `curs->stmt_result` on re-execution without clearing
    the previous result, which the cached PVC insert/update cursors do once per row (the 778 KB
    `PQmakeEmptyPGresult` family);
  * `postgis_run_sql()` threw away the two `PQexec(conn, "COMMIT")` results that close a transaction
    before DDL (58 records);
  * `FdoRdbmsPostGisFilterProcessor::ProcessSpatialDistanceCondition` kept the counted reference
    `GetGeometry()` returns in a raw pointer, leaking the test geometry of every spatial and distance
    condition (13 records).

That took the report to 106,100 B in 960 allocations with **6 direct records (288 B)**. Those 6 are now
fixed as well, which leaves one family:

  * The 6 direct records were 3 `FdoIdentifier`s and 3 `FdoDataValueCollection`s allocated by
    `yyConstraint.y` while parsing a check clause that turns out **not** to be a constraint the parser
    understands — which the PostGIS constraint reader treats as normal (`// Silently skip the
    unsupported constraints`). Tracing `FdoIdentifier::AddRef`/`Release` showed each leaked object
    with exactly two events: the collection's `AddRef` from `FdoCommonParse::AddNode`, and one
    `Release` from `FdoCommonParse::Abort()` → `m_nodes->Clear()`. The grammar's *own* reference (the
    `$$` of the reduction that created it) was never released, because on a syntax error the
    reductions of the enclosing rules never run, so their `FDO_SAFE_RELEASE($1)` cleanup never
    happens. That is the leak `Abort()`'s commented-out release loop was trying to fix; releasing
    twice there over-releases nodes whose grammar reference *was* consumed before the error, and
    releasing "down to one reference" corrupts nodes that are also reachable from another discarded
    node, so neither can be done safely from `Abort()`. The fix is the one the generator has for
    exactly this: `%destructor` declarations in `yyConstraint.y` for the 18 node-producing
    nonterminals, with the equivalent destructor code added to both generated parsers
    (`yyConstraint.cpp` for byacc, `yyConstraintWin.cpp` for bison). It removes the 6 direct records
    and the 12 objects below them (the collections' own `FdoDataValue`s and the identifiers' name
    buffers): 888 B in 18 allocations. See **Generated parsers** below for why the generated files
    had to be touched by hand rather than regenerated.
  * The 105,212 B (388 records) of indirect records are the schema-error cycle the MySQL note
    describes (`FdoSmLpClassBase::Errors2Exception` → `FdoSmError` → `FdoSchemaException` →
    `FdoSmErrorCollection`, reachable from the shared `FdoApplySchemaTest` delete/error tests), which
    needs the same ownership change in the schema manager. Every one of those records is byte-for-byte
    what it was before the parser fix — the fix added no new record family.

## Generated parsers: the `.y` is the input, but the generated file is what compiles

`Utilities/Common/Src/Parse/yyConstraint.y`, `Fdo/Unmanaged/Src/Fdo/Parse/yy{Filter,Expression}.y` and
`Fdo/Unmanaged/Src/Geometry/Parse/yyFgft.y` are the grammar inputs. `build_parse.sh` (Linux) and
`build_parse.bat` (Windows) run the generator and the `script*` sed pipelines that rename the symbols
into the `fdo_constraint_yy*` namespace and move the parser's globals into the shared `FdoCommonParse`
context — but the **generated `yy*.cpp` is what is checked into SVN and compiled**, and the checked-in
copies are old enough that today's generators no longer reproduce them:

- The Linux copies (`yyConstraint.cpp`, `yyFilter.cpp`, `yyExpression.cpp`) are **byacc 1.9**
  (FreeBSD yacc) output — `YYBYACC 1`, `yyrcsid[] = "$FreeBSD: ... skeleton.c,v 1.28 ..."`.
  `byacc 2.0` (Ubuntu 22.04's `byacc`) emits a different 1,9xx-line skeleton with `YYBTYACC`,
  different stack handling and new globals that the sed pipeline does not rewrite; GNU bison (the
  container's `/usr/bin/yacc` is bison 3.8 in yacc mode) differs far more. Regenerating with either
  would replace ~1,000 lines of a parser compiled into every provider.
- The Windows copies (`yy*Win.cpp`) are **GNU Bison 1.875** output, and `FdoCommon.vcproj` carries a
  custom build step that regenerates `yyConstraintWin.cpp` with whatever `bison` is on the local
  `PATH`, so on that side the `.y` is authoritative for a regenerating build.
- `build_parse.sh` also writes the generated header to `Src/Parse/`, while the checked-in header lives
  in `Inc/Parse/yyConstraint.h` (where `Parse.h` includes it from), so even its output paths no longer
  match the tree.

The practical rule: **change the `.y` (it records the intent, and it is what a Windows regeneration
consumes) and then make the equivalent change in both generated parsers by hand**, exactly as was done
for the `%destructor` work above. Table numbering is the thing to be careful with — the destructor
cases are keyed by the generator's symbol numbers, which differ between the two variants (`314`-`331`
for the byacc file, `65`-`82` for the bison file, where the bison numbering comes from its `yytname`
and the byacc one from a `yystos[state]` table that had to be added because byacc 1.9 does not emit
one). Both sets of numbers are only valid while the grammar's symbol set and order are unchanged, so
they carry the symbol names as comments.
