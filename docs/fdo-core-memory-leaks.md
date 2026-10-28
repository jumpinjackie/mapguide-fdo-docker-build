# FDO Core memory leaks (LeakSanitizer findings)

This note records the memory leaks reported by the FDO Core unit-test suite on Linux x64, what was
fixed, and the one leak that is deliberately left in place.

Paths below are relative to the FDO source root (`fdo/` on the host, `/tmp/work/src` inside the build
container).

## How the report is produced

Debug builds are ASan/LSan-instrumented: `templates/scripts/container/build_fdo.sh` passes
`--with-asan` when `FDO_BUILD_CONFIG` is `Debug`, and the FDO tree supplies the instrumentation through
`cmake/modules/FindASan.cmake`.

```
# inside the interactive build container
export NLSPATH=/tmp/work/build_area/fdo/nls/linux/en_US/%N
cd /tmp/work/build_area/fdo/Fdo/UnitTest && ./UnitTest
```

An instrumented run exits non-zero even when every test passes, so the `OK (n)` line and the
`SUMMARY: AddressSanitizer: ... leaked` block in the log are the authoritative result.

Two LSan behaviours matter when reading the report:

- Records are aggregated by allocation stack, so a record usually shows the *allocating* frames and
  not the ownership chain that failed to release the object.
- `Direct leak` means unreachable *and* not pointed to by any other leaked chunk; `Indirect leak`
  means unreachable but still pointed to by a leaked chunk. A report with **no** direct records and
  only indirect ones is the signature of a reference cycle, not of a missing `Release()`.

Per-suite attribution uses CppUnit named registries, which is much faster than running the whole
suite:

```
cd /tmp/work/build_area/fdo/Fdo/UnitTest
./UnitTest GmlTest        # also: SchemaTest, ExpressionTest, FilterParseTest, FilterTest, XmlTest ...
```

The registry name is the CppUnit class name; an unmatched name silently runs zero tests.

## Leaks that were fixed

| Defect | File(s) | Mechanism |
|---|---|---|
| `FdoDataValue::VldShift` dropped the source value when the conversion threw | `Fdo/Unmanaged/Inc/Fdo/Expression/DataValue.h`, `Fdo/Unmanaged/Src/Fdo/Expression/DecimalValue.cpp`, `DoubleValue.cpp`, `SingleValue.cpp`, `StringValue.cpp` | Added `VldShiftOrRelease()` and routed the 7 call sites through it so the value is released on the exception path too. |
| `FdoXmlElementMapping::mClassMapping` | `Fdo/Unmanaged/Inc/Fdo/Xml/ElementMapping.h`, `Fdo/Unmanaged/Src/Fdo/Xml/ElementMapping.cpp` | The member was assigned from a getter without taking a reference while its owning type mapping already owned the object; documented and made non-owning. |
| `FdoSchemaXmlError::Apply` | `Fdo/Unmanaged/Src/Fdo/Schema/XmlError.cpp` | `mParms->GetItem(i)` returns an AddRef'd pointer that the callee does not take ownership of; it is now held in an `FdoStringElementP` local. |
| `FdoXmlPolygon::GetFdoGeometry` | `Fdo/Unmanaged/Src/Fdo/Xml/Polygon.cpp` | The inner-ring reference came from a getter and was never released; it is now held in an `FdoPtr`. |
| `FdoXmlDeserializable::ReadXml` | `Fdo/Unmanaged/Src/Fdo/Xml/Deserializable.cpp` | The `mInternalReader` member kept the reader (and its SAX context) alive after the read, and leaked it outright when `Parse()` threw. The member is now copied to a local and cleared before `Parse()`. |
| `FdoFeatureSchemaCollection::XmlEndDocument` | `Fdo/Unmanaged/Src/Fdo/Schema/FeatureSchemaCollection.cpp` | `CommitSchemas()` throws for an error document, so the release of the XML context that followed it never ran, leaving the cycle `collection → XML context → merge context → collection` alive. The context is now detached into a local before the throwing call. |
| `FdoXmlLpCollection::Clear()` / `RemoveAt()` | `Fdo/Unmanaged/Src/Fdo/Xml/LpCollection.h` | The `GetItem()` result was held in a raw local and never released, so every removed item kept one stray strong reference — enough to retain whole schema graphs. Now held in an `FdoPtr`. |
| `FdoXmlGeometryHandler::EndHandleGML3MultiGeometry` | `Fdo/Unmanaged/Src/Fdo/Xml/GeometryHandler.cpp` | The geometry was popped off the raw `m_geometryStack` without releasing the reference taken by `Create()`; the destructor is the only other pop and does release. |
| `FdoSchemaXmlContext::RefClass2SchemaName` / `CheckWriteAssoc` | `Fdo/Unmanaged/Src/Fdo/Schema/XmlContext.cpp` | `AddError()` AddRefs its argument but does not take ownership. These were the only `AddError(FdoSchemaException::Create(...))` call sites missing the `FdoSchemaExceptionP(...)` wrapper (the 149 such sites in `Fdo/Unmanaged/Src` are now uniformly wrapped). |
| Chained getters on AddRef'ing collections in test code | `Providers/GenericRdbms/Src/UnitTest/Common/DescribeSchemaTest.cpp` (2), `.../Common/FdoApplySchemaTest.cpp` (8), `.../Odbc/OdbcDescribeSchemaTest.cpp` (14), `Providers/KingOracle/src/UnitTest/ut_UrbanizemTest.cpp` (1) | `coll->GetItem(i)->GetFoo()` leaks the reference `GetItem()` returns. Rewritten as `FdoStringElementP(coll->GetItem(i))->GetString()`. 25 of the 34 `GetItem(...)->` occurrences were real leaks; the remainder are `SmartCast<T>(true)` (which consumes the reference) or already wrapped. |
| `Create()` references never released in test code | `Fdo/UnitTest/FilterParseTest.cpp`, `Fdo/UnitTest/FilterTest.cpp`, `Fdo/UnitTest/SchemaTest.cpp` | Objects returned by `Create()` in tests were used and dropped without a matching release. |

## Leak deliberately left in place: strong reference cycles between class definitions

The remaining ~221 KB is a set of **strong reference cycles** between `FdoClassDefinition`s. A schema
removes the last *external* reference when it goes away, but the classes keep each other alive:

- `FdoClassCollection` (owned by `FdoFeatureSchema`) holds each `FdoClassDefinition` strongly.
- `FdoClassDefinition::m_baseClass` holds the base class strongly.
- `FdoObjectPropertyDefinition::m_class` (and `FdoAssociationPropertyDefinition::m_associatedClass`)
  holds the property's own class strongly.

Any mutually referencing pair, e.g. `TimeInstant` ↔ `TimeInstantProperty`, is therefore a cycle, and
the gml3 fixtures in `GmlTest` are full of them.

Evidence gathered:

- After the fixes above, the report contains **no `Direct leak` records at all** — every leaked chunk
  is reachable from another leaked chunk, which is the cycle signature described above.
- Temporary create/destruct and refcount instrumentation over the gml3 fixtures showed each leaked
  class's refcount is exactly `1 (owning class collection) + holders`, where `holders` is the number
  of other leaked classes whose `m_baseClass` or object-property `m_class` points at it — for example
  `Code` rc=34 holders=32, `Measure` rc=11 holders=9, `StringOrRef` rc=28 holders=26. Classes with no
  holders are destroyed normally.
- The leaked set is exactly the set of mutually referencing classes; nothing outside a cycle leaks,
  and per-registry runs localise it to `GmlTest` (181,620 B) and `SchemaTest` (39,360 B) with every
  other registry at 0 B.

Breaking this needs a semantic change to FDO rather than a reference count fix: either make the
class→class references weak (with on-demand resolution) or have schema/collection teardown walk its
classes and clear their internal class→class references. Both are out of scope for a leak-plugging
pass, so the finding is recorded here instead. Upstream candidates are `FdoClassDefinition`
(`m_baseClass`), `FdoObjectPropertyDefinition` (`m_class`) and `FdoAssociationPropertyDefinition`
(`m_associatedClass`).

### Correction: they are collectable, and the measurement says so

The conclusion above was drawn from the naive teardown break, and the naive break is what changes the
contract — not the cycle itself. Two experiments settle it (both on a Debug tree, FDO Core suite):

| Experiment | Suite | Direct | Indirect | Bytes |
|---|---|---|---|---|
| Baseline (no change) | `OK (130)` | 0 | 50 | 220,980 in 2,418 allocations |
| Detach every class→class link in `~FdoClassCollection` | `Run: 130 Failure total: 1` | 1 | 24 | 1,844 in 25 allocations |
| Mark externally-reachable classes, detach only the rest | `OK (130)` | 0 | 0 | **0** |

- The naive detach fails exactly one fixture, `SchemaTest::testFeatureSchema`, on
  `FDO_CPPUNIT_ASSERT(pclass->GetRefCount() == 3);  // once for self, twice for pobjprop (m_class and
  m_classCHANGED)`. That assertion *is* the contract the naive break violates: the test holds a class
  and an object property outside the schema and expects the property's links to survive. The 1,844 B
  it leaves is not a separate leak — the assert aborts the test before its own cleanup runs.
- The collector that satisfies both marks as *roots* the classes whose refcount is not explained by
  the collection's own reference plus the links from inside the collection, follows their links, and
  detaches only the unmarked (garbage) ones. ~100 lines, and it takes the suite to 0 B with the
  original `OK (130)`. The landing form adds a non-virtual member and `friend` declarations rather
  than the prototype's temporary public hooks — no virtual and no data member, so it is ABI-neutral.
- **Change tracking doubles every link, which the record above missed.** `_StartChanges()` snapshots
  the current link into a *counted* `*CHANGED` member (`m_baseClassCHANGED`, `m_classCHANGED`,
  `m_associatedClassCHANGED`), so a modified element holds two references to the class it points at.
  Any fix has to detach both, and any refcount expectation written against a modified element counts
  both.

A working prototype is kept as [patches/fdo_leak_fixes.patch](../patches/fdo_leak_fixes.patch)
(paths relative to the FDO source root, so `cd fdo && svn patch ../patches/fdo_leak_fixes.patch`; it also
carries the aggregate-class factory fix described in the provider record, and does not include the
unrelated fixes above) rather than landed: it is
a behaviour change that lands in shipped headers
(`Inc/Fdo/Schema/ClassCollection.h` plus accessor additions on `ClassDefinition.h`,
`ObjectPropertyDefinition.h` and `AssociationPropertyDefinition.h`), it runs on every schema
teardown in every provider suite, and the current cycle is `freeze` — the policy gate in
[AGENTS.md](../AGENTS.md) makes that an escalation, and `FdoFeatureSchema` teardown
is exercised by MapGuide's schema cache as well as by every FDO consumer, so it wants a deliberate
change with a release note rather than a leak-plug.

## Status

| Measurement | Direct | Indirect | LSan summary |
|---|---|---|---|
| `artifacts/Debug/test-logs/Fdo_unit_test_log.txt` (before this pass) | 784 B (4 records) | 8,449,838 B (896 records) | 8,450,622 B in 80,343 allocations |
| After the fixes (re-measured with the fixes in the tree) | 0 B (0 records) | 220,980 B (50 records) | 220,980 B in 2,418 allocations |
| With the unlanded cycle collector (see the correction below) | 0 B (0 records) | 0 B (0 records) | 0 B |

(An earlier run of the same suite, before the first batch of fixes, reported 33,392 B direct; the log
in `artifacts/` was re-taken part-way through the effort and shows the 784 B figure above.)

Suite results are unchanged by the fixes and remain green: FDO Core `OK (130)`, PostGIS `OK (137)`
against PostgreSQL 16, MySQL `OK (246)` against MySQL 5.6. Leak totals reported by the provider suites
(`UnitTestPostGis`, `UnitTestMySql`) are pre-existing and were not part of this pass.
