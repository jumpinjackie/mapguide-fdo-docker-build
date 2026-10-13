# The GenericRdbms framework — an onboarding guide

This document is for a developer who already knows the FDO provider model and the public FDO
API (`FdoIConnection`, `FdoISelect`, `FdoIFeatureReader`, `FdoFeatureSchema`, the physical
schema mapping, and so on) and now has to maintain or extend an FDO provider built on the
**GenericRdbms** framework. Those are the RDBMS-backed providers under
[`Providers/GenericRdbms`](Providers/GenericRdbms):

| Provider | Driver | Language of the driver | Vendor client library |
|----------|--------|------------------------|-----------------------|
| MySQL / MariaDB | `Src/MySQL/Driver` | C++ (`.cpp`) | `libmysqlclient` / MariaDB Connector/C |
| PostgreSQL + PostGIS | `Src/PostGis/Driver` | C (`.c`) | `libpq` |
| ODBC (generic) | `Src/ODBCDriver` | C (`.c`) | ODBC (`sql.h` / `sqlext.h`) |
| SQL Server Spatial | `Src/SQLServerSpatial/ODBCDriver` | C (`.c`) | ODBC |

> The generic ODBC provider is only as capable as the unixODBC drivers registered on the host; on
> Linux this makes it a database connector (plus a read-only `.mdb` reader), not a replacement for
> the Windows Access Database Engine. See [odbc-linux-support.md](./odbc-linux-support.md).

Everything a driver does *not* have to write lives in the same directory and is compiled into
every provider: the FDO command object model (`Src/Fdo`), the Schema Manager
(`Src/SchemaMgr`), the GDBI C++ layer (`Src/Gdbi`) and the RDBI C layer (`Src/Rdbi`).

> **Not part of the shipped FDO SDK surface.** GenericRdbms is a build-time framework, not a
> public interface. The FDO SDK installs `Fdo/`, `Common/`, `Geometry/`, `Spatial/`,
> `ExpressionEngine/` and the provider include trees (`SDF/`, `SHP/`, `WMS/`, `KingOracle/`,
> `GdalFile/`, `Rdbms/`); the GenericRdbms internals (`Providers/GenericRdbms/**`) and the
> provider-independent Schema Manager (`Utilities/SchemaMgr/**`) are **not** installed. Framework
> changes therefore do not move the provider-facing ABI — with one exception: the headers under
> `Providers/GenericRdbms/Inc/Rdbms/` *are* shipped, so treat those as public.

**Paths and conventions.** Every link in this document is relative to the root of the FDO working
copy (the directory containing `Fdo/`, `Providers/`, `Utilities/` and `providers.xml`). In the
prose, the shorthands `Src/…`, `Inc/…` and `com/…` mean `Providers/GenericRdbms/Src/…`,
`Providers/GenericRdbms/Inc/…` and `Providers/GenericRdbms/com/…` respectively; any other path is
written from the FDO root.

---

## 1. Why the framework exists

There are two ways to write an FDO provider.

1. **Direct implementation** — implement the public interfaces yourself against your own storage
   format. This is what SDF, SHP, WFS, WMS, GDAL and OGR do. You own command dispatch, filter
   handling, schema mapping and everything else.
2. **GenericRdbms** — your store is a relational database with SQL and a C client library, so you
   plug a *driver* into a framework that already implements the provider.

The framework gives you, out of the box:

- the full set of `FdoICommand` implementations (select, insert, update, delete, apply/describe/
  destroy schema, describe schema mapping, spatial contexts, long transactions, locks, …) in
  `Src/Fdo`;
- translation of the FDO **filter tree and expression tree into SQL** (`FdoRdbmsFilterProcessor`,
  `FdoRdbmsSQLBuilder`);
- `FdoIFeatureReader` and `FdoIDataReader` implementations over a fetched row buffer;
- the **Schema Manager**, which maps an FDO feature schema to and from RDBMS tables, columns,
  keys and indexes, and (when the datastore is FDO-enabled) stores the mapping in a set of
  metadata tables;
- capabilities objects, connection-info objects, transactions, and a spatial-context model.

What it costs you:

- you must implement the **RDBI driver** — the C function table that actually talks to the vendor
  client library (Section 8);
- you should adopt the framework's conventions: the optional `f_*` metadata tables that make a
  datastore *FDO-enabled*, a physical schema override vocabulary (`RdbmsOv*`), and the "Grd" base
  classes of the Schema Manager;
- your provider is a big shared library because every GenericRdbms component is a **static
  library** linked into it (`rdbi`, `Gdbi`, `FdoRdbms`, `SmGrd` are all `add_library(... STATIC)`),
  not a shared framework library loaded once.

If your backend is not SQL-shaped, GenericRdbms is the wrong tool and a direct provider (like SDF
or SHP) is the right one.

---

## 2. The layers

```
                    caller (MapGuide, FDO client application)
                                     |
                                     v
   +---------------------------------------------------------------+
   |  FDO public API + provider glue        Src/Fdo/**, Src/<Driver>/Fdo/**
   |  FdoRdbmsConnection, FdoRdbmsSelectCommand, FdoRdbmsFeatureReader,
   |  FdoRdbmsFilterProcessor, FdoRdbmsSqlBuilder, capabilities,
   |  FdoRdbmsDescribe/ApplySchemaCommand ...
   +---------------------------------------------------------------+
            |                                     ^
            | SQL text, bind values                | rows / column values
            v                                     |
   +---------------------------------------------------------------+
   |  Schema Manager      Src/SchemaMgr/**  +  Utilities/SchemaMgr/**
   |  Lp (logical-physical) | Ov (overrides) | Ph (physical)
   +---------------------------------------------------------------+
            |                                     ^
            v                                     |
   +---------------------------------------------------------------+
   |  GDBI  (C++ wrapper)                   Src/Gdbi/**
   |  GdbiConnection, GdbiCommands, GdbiStatement, GdbiQueryResult
   +---------------------------------------------------------------+
            |  context->dispatch.<fn>()            ^
            v                                     |
   +---------------------------------------------------------------+
   |  RDBI  (generic C layer)               Src/Rdbi/**  +  Inc/rdbi.h, Inc/Rdbi/**
   |  rdbi_connect, rdbi_sql, rdbi_define, rdbi_bind, rdbi_execute,
   |  rdbi_fetch, rdbi_desc_slct, ...
   +---------------------------------------------------------------+
            |  function-pointer table               ^
            v                                       |
   +---------------------------------------------------------------+
   |  Driver  (you write this)             Src/<Driver>/Driver/**
   |  mysql_connect, mysql_sql, mysql_define, mysql_bind, mysql_execute,
   |  mysql_fetch, mysql_desc_slct, mysql_term, ...
   +---------------------------------------------------------------+
            |  vendor client API
            v
   +---------------------------------------------------------------+
   |  Vendor client library   libmysqlclient / libpq / ODBC
   +---------------------------------------------------------------+
```

Two boundaries matter:

- **RDBI ↔ Driver** is a **C function-pointer table** (`rdbi_methods_def`). Everything below RDBI
  is a flat set of C-style free functions; everything above it is C++.
- **FDO ↔ Schema Manager** is the other interesting one: commands ask the Schema Manager for the
  logical-physical class definition of a name, and use it to map between FDO properties and
  physical columns.

---

## 3. What is RDBI?

**RDBI** ("relational database interface") is the framework's lowest, *vendor-neutral* C API. It
is the abstraction that lets the same FDO code drive MySQL, PostgreSQL and ODBC: RDBI defines a
neutral SQL statement lifecycle and a neutral type vocabulary, and each vendor's driver
implements that vocabulary in terms of its own client library.

Key files:

| File | What it holds |
|------|---------------|
| [`Inc/rdbi.h`](Providers/GenericRdbms/Inc/rdbi.h) | Constants: max connections/cursors, neutral data types (`RDBI_STRING`, `RDBI_INT`, `RDBI_DOUBLE`, `RDBI_GEOMETRY`, `RDBI_BLOB`, `RDBI_LONGLONG`, …), and the `RDBI_*` status codes (`RDBI_SUCCESS`, `RDBI_END_OF_FETCH`, `RDBI_NO_SUCH_TABLE`, …). |
| `Inc/Rdbi/methods.h` | **`rdbi_methods_def` — the driver dispatch table.** Every function a driver can implement, plus a `capabilities` sub-struct. |
| `Inc/Rdbi/proto.h` | The `rdbi_*` prototypes, and `typedef int initializer(void **contextp, rdbi_methods methods)` — the driver's entry point. |
| `Inc/Rdbi/context.h` | **`rdbi_context_def`** — one per connection. Holds the vendor context pointer (`drvr`), the dispatch table (`dispatch`), the connection array and the cursor array, and `last_error_msg`. |
| `Inc/Rdbi/connect.h` | `rdbi_connect_def` — per-connection bookkeeping: vendor handle, in-use flag, transaction stack, autorecommit state. |
| `Inc/Rdbi/cursor.h` | `rdbi_cursor_def` — the neutral *cursor*, i.e. a prepared statement: the SQL verb, parsed flags, bound/defined flags, rows processed, transaction state. |
| `Inc/Rdbi/vndr_info.h` | `rdbi_vndr_info_def` — vendor name, DB version, min/max precision, scale and string length, max fetch size. |

The generic layer itself is `Src/Rdbi/*.c` — one `.c` file per operation. Each is a thin, uniform
shape: do the cross-vendor bookkeeping, then dispatch to the driver and normalise the result.
For example, [`rdbi_execute`](Providers/GenericRdbms/Src/Rdbi/execute.c) manages the
autocommit transaction wrapper, normalises the `select` vs DML meaning of `count`, and then calls

```c
cursor->status = (*(context->dispatch.execute))(
        context->drvr, cursor->vendor_data, count, offset, &cursor->rows_processed);
```

The neutral **statement lifecycle** is:

1. `rdbi_est_cursor` — allocate a cursor (a vendor statement handle).
2. `rdbi_sql` / `rdbi_sqlW` — give it SQL text; RDBI records the first word as the `verb`
   (`select`, `insert`, …) and derives the statement type.
3. `rdbi_desc_slct` — ask the driver to describe the select list: for each column, name, RDBI
   type, binary size and nullability.
4. `rdbi_define` — bind an **output** buffer to a column.
5. `rdbi_bind` — bind an **input** buffer to a parameter placeholder.
6. `rdbi_execute` — execute/prepare.
7. `rdbi_fetch` — fetch one or more rows into the defined buffers.
8. `rdbi_fre_cursor` — release it.

`RDBI_GEOMETRY`, `RDBI_BLOB` and friends travel as opaque buffers carrying an FGF geometry or a
LOB locator; the conversion to and from the vendor's native geometry type happens inside the
driver.

---

## 4. What is GDBI?

**GDBI** is the C++ wrapper that sits directly on top of RDBI and is what the FDO command classes
actually call. It exists to turn RDBI's C conventions into the C++/FDO conventions the rest of the
framework wants:

| Responsibility | Where |
|----------------|-------|
| RAII object model for connection, statement and result set | `GdbiConnection`, `GdbiStatement`, `GdbiQueryResult`, `GdbiQueryIdentifier` |
| Thin, exception-throwing wrappers for every RDBI call | [`GdbiCommands`](Providers/GenericRdbms/Src/Gdbi/GdbiCommands.h) |
| Unicode ↔ UTF-8 conversion (`FdoStringP`), picking `rdbi_*W` vs `rdbi_*` by driver capability | `GdbiCommands::sql`, `run_sql`, … |
| Column description caching and typed accessors (`GetInt32`, `GetString`, `GetDouble`, …) | `GdbiQueryResult` |
| Geometry: FGF byte array ↔ vendor geometry buffer | `GdbiQueryResult::geom_to_fgf`, `GdbiStatement::GetGeomInfoFromFgf` |
| Sequence/generator allocation, with three fallbacks | `GdbiCommands::NextSequenceNumber` → `NextRDBMSSequenceNumber` (Oracle-style sequence) / `NextRDBMSAutoincrementNumber` / `NextGDBISequenceNumber` (simulated) |
| Exception translation | `GdbiException` |

`GdbiCommands` has **no virtual functions**. In this branch drivers do **not** subclass it; the
driver is injected one level down, at RDBI. (`Src/Gdbi/Gdbi_Oracle.vcproj` is a legacy artifact
from when Oracle had its own GDBI variant.) The capability flags the FDO layer needs
(`SupportsUnicode()`, `SupportsInt64Binding()`) are read from the driver's `capabilities` struct
through the RDBI context.

`GdbiQueryResult::define_exec()` is the heart of the up-path and worth reading early:

1. loop `desc_slct(...)` to build a `GdbiColumnInfoType` per select-list column;
2. `alcnullind(...)` to allocate the null-indicator array;
3. `define(...)` per column to bind its output buffer;
4. `execute(qid, 0, 0)`.

`ReadNext()` then calls `fetch(qid, array_size, &rows)`, and the accessors read the buffers,
consulting `is_null(...)`.

---

## 5. Why the drivers are written in C

Your speculation is right, and it is worth stating the full reason because it explains the shape
of the driver code you are about to write:

- **The vendor client APIs are C.** `mysql.h`/`mysql_stmt_*`, `libpq-fe.h`/`PQexec`, and ODBC's
  `SQLPrepare`/`SQLFetch` are all C APIs with C-shaped callbacks and handles. A driver is mostly
  glue around them, so C is the natural fit and avoids an impedance mismatch at the hot path.
- **RDBI was designed as a C interface from the start.** The extension point is a plain
  `rdbi_methods_def` struct of C function pointers (`Inc/Rdbi/methods.h`), dispatched as
  `context->dispatch.<fn>(context->drvr, ...)`. There is no vtable, no base class, and no
  `this`. Any driver implementation that matches those signatures plugs in — linkage is not the
  point, the *shape* is.
- **The PostGIS and ODBC drivers are literally C** (`.c` files: `connect.c`, `execute.c`,
  `fetch.c`, …). The **MySQL driver was later ported to C++** (`.cpp` files) but still presents
  the same flat free functions with the same C-style signatures — a deliberate example that the
  boundary is a *signature contract*, not a language requirement.

The practical consequence for you: **driver code has no exceptions and no RAII.** Functions return
`RDBI_*` status codes; buffers are `malloc`/`free`d; every failure path must unwind what it
allocated. The C++/exception translation happens one layer up, in GDBI. (For how this bites and
how to keep it leak-free, see [Section 11](#11-gotchas-and-working-notes).)

---

## 6. The Schema Manager

The Schema Manager is the half of GenericRdbms that is not about running queries: it is about
mapping FDO's schema model onto real tables. Its own header documents three jobs
(`Utilities/SchemaMgr/Inc/Sm/SchemaManager.h`):

1. **Update the physical schema** of the current datastore from an FDO feature schema
   (`ApplySchema` → DDL).
2. **Translate the physical schema back into an FDO feature schema** (`GetFdoSchemas`, used by
   `DescribeSchema`).
3. **Describe the mappings** between the feature and physical schemas
   (`DescribeSchemaMapping`).

### The layers

There are three layer families, named by two-letter prefixes, and they live in two places (the
generic engine in `Utilities/SchemaMgr`, and the RDBMS specialisation in the provider):

| Layer | Meaning | Generic engine | GenericRdbms specialisation ("Grd" = *Generic RDBMS*) | Provider specialisation (MySQL example) |
|-------|---------|----------------|--------------------------------------------------------|-----------------------------------------|
| **Lp** | *Logical-Physical*: the merged view of an FDO logical class plus its physical mapping. This is what the FDO commands actually consult. | `FdoSmLpSchema`, `FdoSmLpClassDefinition`, … in `Utilities/SchemaMgr/Inc/Sm/Lp` | `FdoSmLpGrdSchema`, `FdoSmLpGrdClassDefinition`, … in `Src/SchemaMgr/Lp` | `FdoSmLpMySql*` in `Src/MySQL/SchemaMgr/Lp` |
| **Ov** | *Overrides*: the FDO **physical schema mapping** document (the XML `<RdbmsSchemaMapping>`), i.e. the user-specified table/column names, types, storage options. | — (FDO-side base types in `Fdo/…/SchemaMapping`) | `RdbmsOvTable`, `RdbmsOvColumn`, `RdbmsOvClassDefinition`, `RdbmsOvPhysicalSchemaMapping`, … in `Inc/Rdbms/Override` + `Src/SchemaMgr/Ov` | `MySqlOv*` in `Inc/Rdbms/Override/MySQL` + `Src/MySQL/SchemaMgr/Ov` |
| **Ph** | *Physical*: the real database objects — owner/database, table, column, index, foreign key, view, synonym, spatial context — plus their readers and writers. | `FdoSmPhMgr`, `FdoSmPhTable`, `FdoSmPhColumn`, … in `Utilities/SchemaMgr/Inc/Sm/Ph` | `FdoSmPhGrdMgr`, `FdoSmPhGrdTable`, `FdoSmPhGrdOwner`, `FdoSmPhGrdIndex`, `FdoSmPhGrdFkey`, `FdoSmPhGrdView`, `FdoSmPhGrdSynonym`, `FdoSmPhGrdClassWriter`, … in `Src/SchemaMgr/Ph` | `FdoSmPhMySqlColumn`, `FdoSmPhMySqlDatabase`, `FdoSmPhMySqlColTypeMapper`, … in `Src/MySQL/SchemaMgr/Ph` |

The "Grd" classes are the framework's *generic RDBMS* implementations — the ones that already
know how to drive an SQL database. A provider subclasses them (for example
`FdoPostGisSchemaManager : public FdoGrdSchemaManager`,
`FdoSmPhMySqlColumn : virtual public FdoSmPhColumn`) and overrides the vendor-specific parts,
above all the **column type mapper** and the concrete column/owner classes.

**Specialisation is by inheritance and by a naming convention.** The pattern is: generic base
class → `FdoSmPhGrd…` generic-RDBMS class → `FdoSmPhMySql…` / `FdoSmPhPostGis…` provider class.
The provider entry point wires the top of it — `FdoPostGisSchemaManager` overrides
`FdoRdbmsConnection::NewSchemaManager`.

### The metadata tables (optional)

The `f_*` tables are **optional**. When a datastore has them it is described as **FDO-enabled**
(or as "having a MetaSchema"), and that is what turns on the schema-management capabilities that
need somewhere to record FDO-level information. When a datastore does not have them, the
framework still reads it — it reverse-engineers the schema from the physical tables and columns —
but it cannot record FDO-level information in metadata. Whether it can still *apply* a feature
schema (writing only the physical DDL) is a provider policy, not a framework rule — see
[FDO-enabled datastores](#fdo-enabled-datastores-the-metaschema-is-optional) below.

The tables are created from the SQL scripts in
[`com`](Providers/GenericRdbms/com) (`fdo_sys.sql`, `fdo_sys_idx.sql`, plus the PostGIS and
`fdosys_sys.sql` variants). They are the physical side of the mapping, and the `Ph/Cfg`
readers/writers (and the `Ph/Rd` query readers) are the code that reads and writes them:

| Table | Holds |
|-------|-------|
| `f_schemainfo` | One row per feature schema: name, description, owner, creation date, schema version, table mapping type. |
| `f_classdefinition` | The class ↔ physical table mapping. |
| `f_attributedefinition` | The property ↔ physical column mapping. |
| `f_associationdefinition` | Association and object-property relationships. |
| `f_classtype` | Class type metadata. |
| `f_spatialcontext`, `f_spatialcontextgeom`, `f_spatialcontextgroup` | The spatial context model. |
| `f_sequence` | The simulated sequence allocator (used when the RDBMS has neither sequences nor a usable autoincrement). |
| `f_lt`, `f_lock`, `f_lockname`, `f_ltid_in_table`, `f_lockid_in_table`, `f_activelt`, … | Long-transaction and locking metadata. |
| `f_sad` | The Schema Attribute Dictionary — FDO's per-schema/per-class/per-property attribute store. |
| `f_options`, `f_schemaoptions`, `f_dbopen`, `f_feature`, `f_attributedependencies` | Supporting metadata. |

The scripts are templated with `#ifdef Oracle` / `#ifdef MySQL` / `#ifdef SQLServer` (and the
`VISION_noschema` guard) so one file covers every provider; the keywords are passed to the SQL
preprocessor by `FdoSmPhGrdMgr::ExecSchemaFile`.

### FDO-enabled datastores (the metaschema is optional)

Whether a datastore has the `f_*` tables is a per-datastore flag, `hasMetaSchema`, held on the
physical owner (`FdoSmPhOwner::GetHasMetaSchema`,
[`Utilities/SchemaMgr/Inc/Sm/Ph/Owner.h`](Utilities/SchemaMgr/Inc/Sm/Ph/Owner.h)). It can
only be set while the owner is being created (`SetHasMetaSchema` requires
`FdoSchemaElementState_Added`). The flag is also fine-grained after the fact: the owner exposes a
presence accessor per table (`GetHasClassMetaSchema`, `GetHasAttrMetaSchema`, `GetHasSADMetaSchema`,
`GetHasSCMetaSchema`, …), because a datastore may have some of the tables and not others.

- **The create-datastore flag.** `FdoICreateDataStore` itself carries no flag — it is a *datastore
  property*, `IsFdoEnabled` (`FDO_RDBMS_DATASTORE_FDO_ENABLED` in
  [`Src/Fdo/Connection/FdoRdbmsConnectionPropertyDictionary.h`](Providers/GenericRdbms/Src/Fdo/Connection/FdoRdbmsConnectionPropertyDictionary.h)),
  set through `GetDataStoreProperties()->SetProperty(...)`. The provider's create-datastore
  command reads it and passes it to
  `FdoRdbmsConnection::CreateDb(..., bool isFdoEnabled, ...)`
  ([`Src/Fdo/Connection/FdoRdbmsConnection.cpp`](Providers/GenericRdbms/Src/Fdo/Connection/FdoRdbmsConnection.cpp)),
  which calls `FdoSmPhDatabase::CreateOwner(dbName, isFdoEnabled)` (declared as
  `CreateOwner(owner, bool hasMetaSchema = true)`), which calls `FdoSmPhOwner::SetHasMetaSchema`.
  When set, the owner's `Commit` runs `FdoSmPhGrdOwner::AddMetaSchema`, which executes
  `fdo_sys.sql` + `fdo_sys_idx.sql` (or `fdosys_sys.sql` for the system owner), creates the
  MetaClass schema, and stamps `f_schemainfo`. The real suppression mechanism is simply that
  `AddMetaSchema` is only reached when `GetHasMetaSchema()` is true (the scripts also carry a
  legacy `VISION_noschema` guard, but nothing passes it).
- **It is discoverable.** `FdoIDataStoreReader::GetIsFdoEnabled()` returns the owner's
  `GetHasMetaSchema()`, and `FdoIListDataStores::SetIncludeNonFdoEnabledDatastores(bool)`
  (`Src/Fdo/DataStore/FdoRdbmsGetDataStores.*`) filters the list. A provider may bulk-read the
  FDO-enabled datastores, or fall back to per-datastore catalog queries.
- **What lights up.**
  - **Feature-schema apply — provider policy, not a framework rule.** Applying a schema to a
    datastore with no metadata is an explicitly modelled mode, not an oversight. Each logical
    element's `Commit()` writes metadata only `if (owner->GetHas…MetaSchema())`; otherwise it asks
    the provider whether a metadata-free apply is acceptable. The provider opts in by overriding
    `CanApplySchemaWithoutMetaSchema()` — the base returns `false`, but **PostGIS and SQL Server
    Spatial return `true`**, so they *can* apply a full feature schema to a non-FDO-enabled
    datastore (physical DDL only, no metadata). The gate is consulted both at the `ApplySchema`
    entry point and per element, in
    `Utilities/SchemaMgr/Src/Sm/Lp/{ClassDefinition,PropertyDefinition,AssociationPropertyDefinition,ObjectPropertyDefinition}.cpp`.
    The providers that do not opt in throw, naming the missing table(s): `FDOSM_31` (schema),
    `FDOSM_32` (spatial context), `FDOSM_429` (`f_classdefinition`, `f_classtype`), `FDOSM_430`
    (`f_attributedefinition`), `FDOSM_431` (`f_associationdefinition`), `FDOSM_432` (object
    properties — its message text is a copy of `FDOSM_431`'s). So "no metaschema" never *forces* a
    failure — it is a capability a provider either supports or declines.
  - **Physical-object creation.** `CanCreatePhysicalObjects()` is
    `GetCreatePhysicalObjects() && (hasMetaSchema || CanApplySchemaWithoutMetaSchema())`. When
    that expression is false, columns are treated as "fixed" and are only matched against columns
    that already exist — no new tables or columns are emitted.
  - **FDO-specific metadata.** The Schema Attribute Dictionary (`f_sad`), spatial-context metadata
    (`f_spatialcontext*`) and schema options are each consulted only when the corresponding
    presence flag is set.

`DescribeSchema` works either way: with the tables it reads the FDO metadata; without them it
reverse-engineers the schema from the physical tables and columns. The `f_*` tables are therefore
the difference between a datastore that FDO *manages* and one that FDO merely *reads*.

### Where DDL is generated

Physical schema change is executed by the **Ph writers** (`ClassWriter`, `CommandWriter`,
`SpatialContextWriter`, …) driving `Ph/Table`, `Ph/Column`, `Ph/Index`, `Ph/Fkey`, `Ph/View`,
`Ph/Synonym`. A table's `AddColumn` produces the column's SQL type by asking the provider's
column-type mapper. `FdoGrdSchemaManager::ApplySchema`
([`Src/SchemaMgr/SchemaManager.cpp`](Providers/GenericRdbms/Src/SchemaMgr/SchemaManager.cpp))
is the orchestrator: it opens a transaction, takes a lock on a metadata table so two concurrent
`ApplySchema` calls cannot corrupt each other, talks to the physical schema, updates the metadata
tables, and commits. The lock and the metadata updates are both conditional on the owner being
FDO-enabled (`GetHasMetaSchema()`); a provider that can apply a schema without a metaschema does
so without them.

---

## 7. A SELECT, end to end

This section traces one `FdoISelect::Execute()` through every layer and back. The two entry
points to know are:

- the **simple** select command, `FdoRdbmsSimpleSelectCommand`, which uses the SQL builder; and
- the **full** select command, `FdoRdbmsSelectCommand`, which handles the general case (object
  properties, joins, aggregates, expression-engine fallbacks).

`FdoRdbmsConnection::CreateCommand(FdoCommandType_Select)` decides between them; the simple one
falls back to the full one when the class has object properties or no property list was given.

### Down: command → SQL → vendor client

1. **Command creation.** `FdoRdbmsMySqlConnection::CreateCommand` (the provider's subclass of
   `FdoRdbmsConnection`) returns the provider's select command.
2. **SQL text.** `FdoRdbmsSimpleSelectCommand::Execute()`
   ([`Src/Fdo/FeatureCommands/FdoRdbmsSimpleSelectCommand.cpp`](Providers/GenericRdbms/Src/Fdo/FeatureCommands/FdoRdbmsSimpleSelectCommand.cpp))
   calls `PrepareSelect()`, which calls
   `mFdoConnection->GetSqlBuilder()->ToSelectSqlString(className, alias, filter, properties,
   ordering, joinCriteria)`. The SQL builder
   ([`Src/Fdo/Other/FdoRdbmsSQLBuilder.h`](Providers/GenericRdbms/Src/Fdo/Other/FdoRdbmsSQLBuilder.h))
   turns the FDO class, the selected identifiers, the ordering and the filter into a `SELECT`.
   `GetSqlBuilder()` is virtual, so a provider can supply its own dialect.
   In the **full** path (`FdoRdbmsSelectCommand::Execute()`) the SQL is instead produced by
   `FdoRdbmsFilterProcessor`, whose `FilterToSql(...)` walks the `FdoFilter` tree and emits a
   `WHERE` clause (and, for unsupported expressions, the framework falls back to fetching all
   rows and applying the FDO expression engine in-process).
3. **Cursor + parse.** The SQL string reaches GDBI:
   `mConnection->GetGdbiCommands()->sql(sql, &qid)`. `GdbiCommands::sql` calls
   `rdbi_est_cursor` (allocate a neutral cursor) then `rdbi_sql` (record the verb).
   `rdbi_sql` dispatches to the driver's `sql` method.
4. **Describe + define + execute.** A `GdbiQueryIdentifier` wraps the cursor, and
   `GdbiQueryResult::Create` runs `define_exec()`: `desc_slct` per column to learn name/type/size,
   `alcnullind`, then `define` per column, then `execute(qid, 0, 0)`.
   Each of those calls is a GDBI wrapper over the matching `rdbi_*` function, which dispatches
   through `context->dispatch` to the driver — for MySQL, `mysql_desc_slct`, `mysql_define`,
   `mysql_execute` — which in turn calls `mysql_stmt_prepare` / `mysql_stmt_bind_result` /
   `mysql_stmt_execute`.
5. **Bind values.** Parameter values (`:par1` placeholders) are bound before execution by
   `FdoRdbmsPropBindHelper::BindParameters` — either against a `GdbiStatement`, or against a
   `GdbiCommands` plus a cursor id, as the simple path does — which calls `GdbiCommands::bind`
   (`GdbiStatement::Bind`) → `rdbi_bind` → `mysql_bind` → `mysql_stmt_bind_param`.

So the SQL text is built by the FDO/GenericRdbms layer, and the driver never sees FDO types — it
sees RDBI types (`RDBI_STRING`, `RDBI_GEOMETRY`, …) and a vendor statement handle.

### Up: result set → feature reader

6. **Reader construction.** The command returns
   `FdoRdbmsSimpleFeatureReader::Create(connection, queryResult, isFeatureQuery, classDefinition,
   schemaCollection, properties)` (or `FdoRdbmsFeatureReader` for the full path). The reader owns
   the `GdbiQueryResult`.
7. **Column→property mapping.** `GenerateInternalMapping()` asks the result set for its column
   descriptors (`GdbiQueryResult::GetColumnDesc(i+1, …)`) and builds a column list. When a
   property is requested, the reader maps the FDO property name to a physical column name using
   the class's logical-physical definition and
   `FdoRdbmsSchemaUtil::ColName2Property`, then resolves the column in the list.
8. **Fetching.** `FdoIFeatureReader::ReadNext()` → `GdbiQueryResult::ReadNext()` →
   `GdbiCommands::fetch(qid, array_size, &rows)` → `rdbi_fetch` → the driver's `fetch`
   (MySQL: `mysql_fetch` → `mysql_stmt_fetch`) fills the defined output buffers and the null
   indicators. The framework fetches in **arrays** (`get_array_size`) unless the row has a LOB.
9. **Value access.** `GetString`, `GetInt32`, `GetDouble`, `GetDateTime`, `GetGeometry`, etc.
   read the buffer for the mapped column, after checking `is_null`. Type translation from the
   neutral RDBI type to `FdoDataType` is done by `FdoRdbmsUtil::DbiToFdoType`. A geometry column
   is special: the driver exposes the vendor geometry, and
   `GdbiQueryResult::geom_to_fgf` calls the driver's geometry conversion to produce **FGF**, which
   the FDO geometry factory turns into an `FdoIGeometry`.
10. **Teardown.** When the reader is released, the `GdbiQueryResult` destructor frees the cursor
    (`rdbi_fre_cursor` → driver `fre_cursor`), destroying the vendor statement.

The same down/up shape applies to insert, update and delete; only the command classes and the
`Src/Fdo/Pvc` handlers (insert/update with automatically-generated values, geometry formatting,
etc.) differ.

---

## 8. Driver surface reference

This is the contract you implement. The table is `rdbi_methods_def` in
[`Inc/Rdbi/methods.h`](Providers/GenericRdbms/Inc/Rdbi/methods.h); the generic side calls
each entry as `context->dispatch.<name>(context->drvr, ...)`. Every entry may be **NULL** to mean
"not supported", and the framework degrades gracefully where it can — the MySQL driver leaves a
large fraction NULL.

Grouped by role, with the MySQL implementation as the worked example:

| Role | Methods | MySQL | Notes |
|------|---------|-------|-------|
| Driver entry | `initializer` (`<x>_rdbi_init`) | `mysql_rdbi_init` | Allocates the vendor context and fills the table; passed to `rdbi_init`. |
| Connect | `connect`, `connectW`, `disconnect` | `mysql_connect`, `mysql_disconnect` | `connect` receives datasource/user/password and an opaque connection string; returns a vendor handle. |
| Connection info | `vndr_name`, `vndr_nameW`, `vndr_info`, `get_con_var`, `get_server_rc` | `mysql_vndr_name`, `mysql_vndr_info` | `vndr_info` fills precision/scale/string-length limits. |
| Schema/search helpers | `set_schema`, `set_schemaW`, `col_act/get/deac`, `objects_act/get/deac`, `pkeys_act/get/deac`, `users_act/get/deac`, `usr_exists`, `stores_act/get/deac` | `mysql_set_schema` (rest NULL) | Used by the Schema Manager to enumerate metadata. |
| Cursor lifecycle | `est_cursor`, `est_cursor_obj`, `fre_cursor`, `close_cursor` | `mysql_est_cursor`, `mysql_est_cursor_obj`, `mysql_fre_cursor` | A cursor is a prepared statement. |
| Statement | `sql`, `sqlW`, `execute`, `exec_coc`, `run_sql`, `run_sqlW`, `desc_bind`, `desc_slct`, `desc_slctW` | `mysql_sql`, `mysql_execute`, `mysql_run_sql`, `mysql_desc_slct`, `mysql_desc_bind` | `run_sql` is the direct-execute path (DDL, utility SQL). |
| Output binding | `define`, `null` helpers (`alcnullind`, `set_null`, `set_nnull`, `is_null`) | `mysql_define`, `mysql_alcnullind`, `mysql_set_null`, `mysql_set_nnull`, `mysql_is_null` | `define` binds a column's output buffer; null indicators are separate. |
| Input binding | `bind` | `mysql_bind` | Binds a parameter placeholder. |
| Rows | `fetch` | `mysql_fetch` | Fills defined buffers, one or many rows. |
| Errors | `get_msg`, `get_msgW` | `mysql_get_msgW` | Last error into the context's `last_error_msg`. |
| Transactions | `commit`, `tran_begin`, `tran_sp`, `tran_spW`, `autocommit_on/off/mode`, `do_break` | `mysql_commitx` | Save-points and autocommit are optional. |
| Sequences / identity | `get_gen_id`, `get_gen_idW`, `get_next_seq`, `get_next_seqW` | `mysql_get_gen_id` | Only one of the two families is normally implemented. |
| Geometry | `geom_srid_set`, `geom_type_set`, `geom_version_set`, `geom_dimens_set`, `get_geoms_ext` | `mysql_geom_srid_set` | `get_geoms_ext` converts vendor geometry ↔ FGF. |
| LOBs | `lob_create_ref`, `lob_destroy_ref`, `lob_get_size`, `lob_write_next`, `lob_read_next`, `lob_open`, `lob_close` | (all NULL) | Needed for streaming BLOB/CLOB. |
| Lifecycle | `term` | `mysql_term` | Release vendor state. |

Plus the **capabilities** struct, which the FDO layer reads:

```c
typedef struct _driver_capability_ {
    int supports_sequence;
    int supports_autoincrement;
    int supports_unicode;
    int supports_int64_binding;
} rdbi_driver_capabilities_def;
```

Read them in the generic layer:
`context->dispatch.capabilities.supports_unicode` is what makes `GdbiCommands::SupportsUnicode()`
choose `rdbi_sqlW`/`rdbi_desc_slctW` over the narrow functions.

### Driver file map (MySQL example)

The MySQL driver under [`Src/MySQL/Driver`](Providers/GenericRdbms/Src/MySQL/Driver) is the
most complete reference. PostGIS and ODBC have the same filenames (with `.c`). A driver is a set
of files each mapping to one or a few methods:

| File(s) | Role |
|---------|------|
| `local.h` (or `context.h`/`structs.h`) | The vendor context struct (handles + per-connection state) and per-cursor struct. |
| `rdbi_init.cpp` / `init.c` | `<x>_rdbi_init`: allocate the context and fill the methods table. |
| `connect.*`, `disconnect.*`, `commit.*`, `term.*`, `set_schema.*` | Connection and transaction lifecycle. |
| `est_cursor.*`, `fre_cursor.*`, `sql.*`, `execute.*`, `run_sql.*`, `desc_slct.*`, `desc_bind.*` | Statement lifecycle. |
| `define.*`, `bind.*`, `fetch.*`, `null.*` | Row I/O. |
| `type.*`, `xlt_status.*`, `drv_errno.h` | RDBI type ↔ vendor type mapping and status/error translation. |
| `Geometry.*`, `geom_srid.*` | Native geometry ↔ FGF and SRID handling. |
| `get_gen_id.*` / `get_next_seq.*` | Identity/sequence support. |
| `vndr_name.*`, `vndr_info.*`, `get_msg.*`, `nls.*` | Metadata and messages. |

---

## 9. Provider glue above the driver

A driver alone is not a provider. Each provider also supplies a small set of C++ classes that
specialise the framework and the single exported entry point.

**Provider entry point.** The provider shared library exports exactly one symbol the core
resolves:

```cpp
extern "C" FDORDBMS_API FdoIConnection* CreateConnection()
{
    return FdoRdbmsMySqlConnection::Create();
}
```

(`Src/MySQL/MySql.cpp`.) The provider's `FdoRdbms*Connection::Create()` is also where the RDBI
driver is injected:

```cpp
FdoRdbmsMySqlConnection* FdoRdbmsMySqlConnection::Create()
{
    FdoRdbmsMySqlConnection *conn = new FdoRdbmsMySqlConnection();
    conn->GetDbiConnection()->InitRdbi( mysql_rdbi_init );   // -> rdbi_init(&ctx, driver)
    return conn;
}
```

`DbiConnection::InitRdbi` calls the generic
[`rdbi_init`](Providers/GenericRdbms/Src/Rdbi/init.c), which allocates the
`rdbi_context_def`, then calls your `initializer` with `(&context->drvr, &context->dispatch)`.
That single call is where your driver is bound into the framework.

**Classes a provider subclasses, by directory** (`Src/<Driver>/…`):

| Directory | What lives there | Base to subclass |
|-----------|------------------|------------------|
| `Fdo/` | The connection and its capability objects: `FdoRdbms<X>Connection`, `…CommandCapabilities`, `…ConnectionCapabilities`, `…FilterCapabilities`, `…SchemaCapabilities`, `…GeometryCapabilities`, `…ExpressionCapabilities`, `…ConnectionInfo`, and `FdoRdbms<X>FilterProcessor`, `FdoRdbms<X>CreateDataStore`/`DeleteDataStore`, `…GetDataStores`. | `FdoRdbmsConnection`, `FdoRdbmsFilterProcessor`, the `FdoI*Capabilities` interfaces. |
| `SchemaMgr/` | `Lp/`, `Ov/`, `Ph/` subclassing the Grd classes, plus `SchemaManager.{h,cpp}`. | `FdoGrdSchemaManager`, `FdoSmLpGrd*`, `RdbmsOv*`, `FdoSmPhGrd*`. |
| `Custom/` | Provider-specific command objects, if the provider needs any. The shared spatial-index commands (`FdoRdbmsCreateSpatialIndex`, …) already live in `Src/Fdo/Custom`; `Src/PostGis/Custom` is currently empty. | — |
| provider root | `<X>.cpp` (`CreateConnection`, Windows `DllRegisterServer`, Linux `__attribute__((constructor))` hooks), `<X>.rc` (resource + NLS message catalogue id), `CMakeLists.txt`. | — |
| SQL | `<X>/sql/*.sql` or shared `com/*.sql`. | — |

Registration is in [`providers.xml`](providers.xml): a `<FeatureProvider>` with a
`<Name>` (for example `OSGeo.MySQL.4.2`), display name, description, version, and the shared
library path. The message catalogue is built from the provider's `.rc`/NLS sources and resolved
via `NLSPATH` at run time (missing catalogues make tests assert on raw symbols like `FDOSM_220`
instead of English text).

---

## 10. Supporting a new RDBMS: an implementation guide

This is the checklist for a hypothetical `FooDB` provider. It is deliberately ordered so you can
get a connection and a `SELECT` working before you tackle schema mutation.

### Step 0 — decide and record

- Confirm the backend really is SQL + a C client library. If not, GenericRdbms is the wrong
  framework.
- Note the shipped-surface rule above: adding a provider and its driver is additive; changing a
  shipped header under `Providers/GenericRdbms/Inc/Rdbms/` is not.

### Step 1 — skeleton

Create `Providers/GenericRdbms/Src/Foo/` with `Driver/`, `Fdo/`, `SchemaMgr/{Lp,Ov,Ph}/`,
optionally `Custom/`, a root `Foo.cpp` + `Foo.rc` + `CMakeLists.txt`, and an entry in
`providers.xml`. Copy the PostGIS provider as a template — it is smaller than MySQL and its
driver is C, matching the "new vendor client library is C" case. Wire `add_subdirectory( Foo )`
into `Src/CMakeLists.txt` and mirror the `target_link_libraries` pattern (the vendor client
library, plus the framework static libs `rdbi`, `Gdbi`, `FdoRdbms`, `SmGrd`).

### Step 2 — the driver context and init

In `Driver/local.h`, define your context struct — vendor connection handles plus whatever
per-connection state you need — modelled on
[`Src/MySQL/Driver/local.h`](Providers/GenericRdbms/Src/MySQL/Driver/local.h). In
`Driver/rdbi_init.cpp`, write `<foo>_rdbi_init(void **contextp, rdbi_methods methods)`:
allocate the context, then assign the methods table. You can (and should) leave unsupported
entries NULL.

### Step 3 — connection

`connect.cpp` / `disconnect.cpp`: open the vendor connection from the datasource/user/password
strings and return an opaque handle; implement `set_schema` if the vendor has a schema/namespace
concept. Implement `vndr_name`, `vndr_info` and `term`.

### Step 4 — statement lifecycle

`est_cursor` (allocate a statement), `sql`, `execute`, `run_sql` (direct execution for DDL),
`fre_cursor`. Have `sql` just store the text; parse nothing yourself.

### Step 5 — describe, define, bind, fetch

This is the core. `desc_slct` must report, for each select-list column, the **RDBI type** that
best represents it, its binary size and nullability. `define` must arrange for `fetch` to fill
the caller's buffer. `bind` maps an RDBI-typed input to the vendor's parameter mechanism. `fetch`
fills all defined buffers and sets the null indicators (`null.cpp` helpers).

Implement `type.cpp` with a mapping in both directions between vendor column/parameter types and
the `RDBI_*` constants.

Set the `capabilities` flags honestly — `supports_sequence`, `supports_autoincrement`,
`supports_unicode`, `supports_int64_binding`. They change which generic code paths run (for
example, `supports_unicode` selects the `rdbi_*W` entry points).

### Step 6 — FDO glue

Subclass `FdoRdbmsConnection` (`FdoRdbmsFooConnection`) with `Create`, `Open`/`DbiOpen`,
`CreateCommand`, `CreateSchemaMapping`, `GetFilterProcessor`, `NewSchemaManager`, the capability
getters, and the time conversions `DbiToFdoTime` / `FdoToDbiTime`. If your dialect differs from
the default SQL, override `GetSqlBuilder` or subclass `FdoRdbmsFilterProcessor`.
Export `CreateConnection`.

At this point a `SELECT` should work: create a connection with a hand-written overridden schema,
call `FdoISelect`, and read rows.

### Step 7 — Schema Manager

Subclass `FdoGrdSchemaManager` and the `FdoSmLpGrd*` / `FdoSmPhGrd*` classes you need. The
minimum is:

- a **column-type mapper** (`ColTypeMapper`) translating FDO data types to your DDL types and back;
- concrete `Column` (and one class per FDO data type, if you need per-type precision rules),
  `Database`/`Owner`, and `Table` classes;
- the `Ov` override classes (`FooOv*`) if your provider exposes vendor-specific storage options;
- `SchemaManager.cpp` returning your manager from `NewSchemaManager`;
- a decision on `CanApplySchemaWithoutMetaSchema()`: return `true` only if your backend's own
  catalog has enough information to describe a feature schema without the `f_*` tables (PostGIS
  and SQL Server Spatial do; the rest of the providers do not).

### Step 8 — metadata

Provide a `Foo`-flavoured `fdo_sys.sql` (start from `com/fdo_sys.sql`, add your
`#ifdef Foo` branches) and make datastore creation run it **only when the datastore is created
FDO-enabled** — that is, when the `IsFdoEnabled` datastore property is set. A datastore created
without it is still readable (the schema is derived from the physical tables), but it is not
FDO-managed: no SAD, no spatial-context metadata, and no feature-schema apply *unless you choose
to allow it* by overriding `CanApplySchemaWithoutMetaSchema()` (see
[FDO-enabled datastores](#fdo-enabled-datastores-the-metaschema-is-optional)). Teach the `Ph/Cfg`
readers your catalogue queries if they differ from the generic ones.

### Step 9 — geometry

Implement `geom_srid_set`, the SRID/dimension plumbing, and `get_geoms_ext` (native geometry ↔
FGF) if the vendor has a spatial type. If it does not, expose geometry as WKB in a BLOB and
convert in the driver.

### Step 10 — test

Reuse the framework's test harness under
[`Src/UnitTest`](Providers/GenericRdbms/Src/UnitTest): the runners take an init file via
`initfiletest=<file>` and register suites by name, so `./UnitTestFoo initfiletest=FooInit.txt
<SuiteName>` runs one suite. Run in **Debug (ASan)** and **Release** — they are different runtimes
and a Release-only `this == NULL` problem can pass in Debug.

### The "generic vs you" split, in one table

| Concern | Provided by framework | You implement |
|---------|-----------------------|---------------|
| Command objects | yes (`Src/Fdo`) | — |
| Filter/expression → SQL | yes (generic `FdoRdbmsFilterProcessor`) | dialect tweaks (subclass) |
| SQL text generation | yes (`FdoRdbmsSqlBuilder`) | dialect override (optional) |
| Feature/data readers | yes | — |
| Schema mapping model | yes (`Sm`, `RdbmsOv*`, `SmGrd`) | `Lp/Ov/Ph` subclasses |
| DDL emission | yes (`Ph` writers) | column type mapper + column/owner classes |
| Metadata tables | yes — optional, created only when the datastore is FDO-enabled (`com`) | vendor-specific SQL branches |
| Capabilities objects | base implementations | subclass + declare what you support |
| SQL execution & typing | neutral API (RDBI/GDBI) | **the driver** |
| Vendor client calls | — | **the driver** |
| Provider entry point | pattern | `CreateConnection` + `Foo.cpp` |

---

## 11. Gotchas and working notes

The framework is old, large and full of conventions that are not obvious from a cold read. The
following are the traps most likely to cost you a day.

- **Reference counting.** GenericRdbms is full of counted references. The same idioms that cause
  leaks in the rest of FDO apply here: `SmartCast<T>()` returns a counted reference that must go
  into an `FdoPtr`; any `Get*`/`Find*`/`Create*` that returns an `FdoXxx*` may be counted;
  `FdoCollection::Add()` AddRefs. The framework itself has been a source of exactly these leaks,
  including a `FdoRdbmsPvcInsertHandler` constructor/destructor bug where uninitialised member
  slots leaked.
- **Driver failure paths leak.** Because the driver has no RAII or exceptions, an early `return`
  on an error must free what it allocated (`mysql_real_connect` failing without `mysql_close`, a
  dropped `new[]`). This is a recurring defect class in the RDBI drivers.
- **Two lock semantics, one shim.** The SQLite provider (not GenericRdbms, but the same era) shims
  `CRITICAL_SECTION`, which is recursive, onto a POSIX mutex, which is not. If you introduce a
  lock in GenericRdbms code that was written against Windows behaviour, check whether a
  same-thread re-entry is possible before choosing a plain mutex (a `PTHREAD_MUTEX_RECURSIVE`
  mutex is usually the faithful port).
- **Unique, hidden init hooks.** Never add a function-scope `extern` with a generic name such as
  `_load`/`_unload`/`init`; ELF symbol interposition across the FDO shared libraries has bitten
  this codebase before. The MySQL provider's constructor is named `FdoMySqlProviderLoad`,
  `static`, and hidden — follow that pattern.
- **Debug and Release are different runtimes.** Debug is ASan/LSan-instrumented. Never copy a
  provider library or installed FDO between the two build trees; reinstall FDO in the tree you
  are testing.
- **The statement-reuse path in the simple select command is disabled.** `Src/Fdo/FeatureCommands/
  FdoRdbmsSimpleSelectCommand.cpp` contains several `#if 0` blocks around a statement pool; the
  command allocates a fresh cursor per `Execute()`. Do not assume the pool works.
- **`DbiConnection::dbi_*` are legacy wrappers.** The 600-line
  [`DbiConnection.h`](Providers/GenericRdbms/Src/Fdo/Connection/DbiConnection.h) exposes a
  large set of `dbi_*` methods (versioning, locking, `dbi_gql`, `dbi_bind`, …) that date from the
  original Oracle-oriented DBI and are mostly unused by the newer command classes. The live path
  is the GDBI one (`GetGdbiCommands()`, `GetGdbiConnection()`); read the `dbi_*` layer only if you
  are chasing long-transaction or lock code.
- **`Grd` means "Generic RDBMS".** Class-name prefixes you will meet: `Sm` = schema manager, `Lp`
  = logical-physical, `Ov` = overrides, `Ph` = physical, `Grd` = generic RDBMS, `Gdbi` = the C++
  wrapper, `Rdbi` = the C layer, `Pvc` = property-value handlers for insert/update.

### Raster data is not supported

GenericRdbms does not merely omit raster support — it deliberately denies it, and the denial is
above the driver, so a new driver cannot switch it on.

- **Capabilities.** `FdoRdbmsConnection::GetRasterCapabilities()`
  ([`Src/Fdo/Connection/FdoRdbmsConnection.cpp`](Providers/GenericRdbms/Src/Fdo/Connection/FdoRdbmsConnection.cpp))
  returns an anonymous `Nothing : FdoIRasterCapabilities` whose `SupportsRaster()`,
  `SupportsStitching()`, `SupportsSubsampling()` and `SupportsDataModel()` all return false. No
  GenericRdbms provider overrides it.
- **Schema.** The *generic* Schema Manager rejects raster properties: the
  `FdoPropertyType_RasterProperty` case in `FdoSmLpClassDefinition::CreateProperty`
  (`Utilities/SchemaMgr/Src/Sm/Lp/ClassDefinition.cpp`) throws `FDOSM_421` — *"Raster properties
  are not supported for the current Provider."* There is no `FdoSmLpRasterPropertyDefinition`, no
  `RasterOv*` override class and no raster `Ph` column, so a raster property cannot even be
  defined through `ApplySchema`.
- **Readers.** `FdoRdbmsFeatureReader::GetRaster` returns `NULL`;
  `FdoRdbmsSimpleFeatureReader::GetRaster` throws *"GetRaster() is not implemented by this
  provider."*
- **RDBI.** The neutral type vocabulary in `Inc/rdbi.h` has no raster type, and
  `rdbi_methods_def` has no raster method group — only geometry and LOB.

For contrast, **GDAL** and **WMS** are real raster providers in the FDO tree
(`FdoRfpRasterCapabilities::SupportsRaster()` and `FdoWmsRasterCapabilities::SupportsRaster()`
both return true); every relational provider returns false.

Raster *could* be added, but as a framework extension rather than a driver: override
`GetRasterCapabilities()` (it is `virtual` and `FDORDBMS_API`-exported), add a raster property
type across the `Lp`/`Ov`/`Ph` layers and the `f_attributedefinition` metadata, and implement
`GetRaster` on the readers, carrying the image bytes in the existing `RDBI_BLOB`/LOB plumbing and
wrapping them as an `FdoIRaster`. The FDO-side types (`FdoIRaster`,
`FdoIRasterPropertyDictionary`, `FdoRasterDataModel`) already exist.

---

## 12. Source map

All paths are relative to the root of the FDO working copy (the directory containing `Fdo/`,
`Providers/`, `Utilities/` and `providers.xml`).

| Path | Contents |
|------|----------|
| [`Providers/GenericRdbms/Src/Fdo`](Providers/GenericRdbms/Src/Fdo) | The FDO command object model: `Connection/`, `FeatureCommands/`, `Filter/`, `Schema/`, `Capability/`, `SpatialContext/`, `Lt/` (long transaction), `Lock/`, `Pvc/`, `Custom/`, `Other/` (SQL builder, util, BLOB stream, SQL command). |
| [`Providers/GenericRdbms/Src/Gdbi`](Providers/GenericRdbms/Src/Gdbi) | GDBI C++ wrapper (`GdbiCommands`, `GdbiConnection`, `GdbiStatement`, `GdbiQueryResult`, `GdbiException`). |
| [`Providers/GenericRdbms/Src/Rdbi`](Providers/GenericRdbms/Src/Rdbi) | Generic RDBI C layer, one `.c` per operation. |
| [`Providers/GenericRdbms/Inc`](Providers/GenericRdbms/Inc) | Public framework headers: `rdbi.h`, `Rdbi/*` (the API and the driver table), `Rdbms/Override/*` (the `RdbmsOv*` and provider `*Ov*` classes), `Util/*`, `Geometry/*`, `Nls/*`. |
| [`Providers/GenericRdbms/Src/SchemaMgr`](Providers/GenericRdbms/Src/SchemaMgr) | `FdoGrdSchemaManager` plus the `Grd` Lp / Ov / Ph classes. |
| [`Utilities/SchemaMgr`](Utilities/SchemaMgr) | The provider-independent Schema Manager engine (`Sm/Lp`, `Sm/Ph`, `SchemaManager`). |
| [`Providers/GenericRdbms/com`](Providers/GenericRdbms/com) | The `fdo_sys*.sql` metadata-table scripts (installed to `lib64/com`). |
| [`Providers/GenericRdbms/Src/MySQL`](Providers/GenericRdbms/Src/MySQL), [`.../PostGis`](Providers/GenericRdbms/Src/PostGis), [`.../ODBC`](Providers/GenericRdbms/Src/ODBC), [`.../ODBCDriver`](Providers/GenericRdbms/Src/ODBCDriver), [`.../SQLServerSpatial`](Providers/GenericRdbms/Src/SQLServerSpatial) | The four reference providers: driver, FDO glue and Schema Manager subclasses. |
| [`Providers/GenericRdbms/Src/UnitTest`](Providers/GenericRdbms/Src/UnitTest) | The driver test harness (`initfiletest=…`, named suites). |
| [`providers.xml`](providers.xml) | Provider registry entries. |

### Suggested reading order

1. `Inc/Rdbi/methods.h` — the contract (Section 8).
2. `Src/MySQL/Driver/rdbi_init.cpp` + `Src/MySQL/Driver/local.h` — how a driver binds in.
3. `Src/Gdbi/GdbiCommands.cpp` (`sql`, `execute`, `bind`, `define`, `fetch`) — the C++ wrapper.
4. `Src/Fdo/FeatureCommands/FdoRdbmsSimpleSelectCommand.cpp` — the command that carries SQL down.
5. `Src/Gdbi/GdbiQueryResult.cpp` (`define_exec`, `ReadNext`) — the result coming back up.
6. `Src/Fdo/FeatureCommands/FdoRdbmsSimpleFeatureReader.cpp` — column→property mapping.
7. `Src/SchemaMgr/SchemaManager.cpp` + `Src/SchemaMgr/Ph/Table.h` — the schema side.
8. `com/fdo_sys.sql` — the optional metadata tables that make a datastore FDO-enabled.
