# C++ Code Style Guidelines

Applies to edits under `mapguide/MgDev` and `fdo`.

## Language standard

Both source trees compile as **C++11**:

- `fdo/CMakeLists.txt` → `set (CMAKE_CXX_STANDARD 11)`
- `mapguide/MgDev/CMakeLists.txt` → `set (CMAKE_CXX_STANDARD 11)` + `set (CMAKE_CXX_STANDARD_REQUIRED ON)`

Keep any new code within C++11 and avoid newer language-standard features.

## Memory management

Both trees use intrusive reference counting with custom smart pointers. Never `delete` these
objects directly — their destructors are protected and lifetime is managed via
`AddRef` / `Release`.

`FdoPtr<>` and `Ptr<>` are reserved exclusively for reference-counted FDO (`Fdo*`) and
MapGuide (`Mg*`) classes. Do not use them for standard library types or for types from
third-party libraries — those have their own (or no) ownership model.

### Ownership contract

- `FdoPtr(T*)` and `FdoPtr::operator=(T*)` **attach without adding a reference** — they take
  ownership of the reference being handed over.
- `FdoPtr`'s copy constructor and copy-assignment **do** add a reference (shared ownership).
- FDO getters and collections (`GetX()`, `GetItem`, `FindItem`, `Add`) **return addref'd
  pointers** — the caller owns the returned reference.

Consequences:

- `FdoPtr<T> x = obj->GetX();` — correct: the getter's addref'd pointer is taken over by `x`.
- `m_X = value; FDO_SAFE_ADDREF(m_X.p);` — correct: the assignment attaches, so the explicit
  addref is what gives `m_X` its own owned reference.
- `return FDO_SAFE_ADDREF(m_X.p);` — correct: hands an owned reference to the caller.
- `FdoPtr<T> x = obj->GetX(); FDO_SAFE_ADDREF(x.p);` — **wrong**: over-retains (leaks), since
  `x` already owns the reference the getter returned.
- `catch (FdoException*) { }` (or a nameless `catch (...)`) — **wrong**: the caught exception and its
  message buffer are leaked. Name the exception, assert on it, then release it.

### SmartCast and the vetted usages of FdoPtr

`SmartCast<T>()` (on `FdoSmDisposable` and friends) also **returns an AddRef'd pointer** — it exists
so the result can be handed straight to an `FdoPtr`:

- `FdoSmPhMySqlOwnerP owner = base->SmartCast<FdoSmPhMySqlOwner>();` — correct.
- `base->SmartCast<FdoSmPhMySqlOwner>()->GetName()` — **wrong**: the cast's reference is dropped and
  never released. Anything the object owns — potentially a whole schema graph — stays alive.

The same applies to dereferencing any AddRef'ing getter inline
(`expr.GetArguments()->GetCount()`, `->FindItem(x)->GetName()`): load it into an `FdoPtr` first, or
release it explicitly.

`FdoPtr<>` is vetted **only** as a local variable or as a class member — never as an STL container
element or a function parameter, and do not introduce new code that returns one by value. Where
existing code already returns an `Fdo<X>P`, take the result into an `FdoPtr` local (or a member) and
let the local release it. For a raw-pointer boundary, use `FDO_SAFE_ADDREF`/`FDO_SAFE_RELEASE`.

Child-to-parent back-pointers must be **raw, non-owning** pointers. A counted reference in one
direction plus a raw (or non-releasing) member in the other is a reference cycle: the object can
never reach zero references, so a pass in the unit suite still reports a leak.

Because `FdoPtr(T*)` *attaches*, **two `FdoPtr`s must never be built from the same raw pointer** —
each one will release on destruction, so the object is released twice for one `AddRef`:

```cpp
FdoPtr<FdoExpression> expr = filter.GetGeometry();           // owns the +1 the getter returned
FdoPtr<FdoGeometryValue> geom = dynamic_cast<FdoGeometryValue*>(expr.p);   // WRONG: attaches it again
```

The second pointer is a *borrow*; keep it raw (or copy the `FdoPtr`, which AddRefs). The symptom of
getting this wrong is not a leak but a crash — the object is destroyed early and something else is
still pointing at it.

### FDO

- Wrap FDO interface pointers in `FdoPtr<T>` (defined in `Fdo/Unmanaged/Inc/Common/Ptr.h`),
  or the `Fdo<T>P` convenience typedefs (for example `FdoClassP`).
- Use `FDO_SAFE_ADDREF` / `FDO_SAFE_RELEASE` for raw pointers (defined in
  `Fdo/Unmanaged/Inc/Common/IDisposable.h`).
- FDO interfaces derive from `FdoIDisposable`.

### MapGuide

- Wrap `Mg*` objects in `Ptr<T>` (defined in `Common/Foundation/System/Ptr.h`).
- Use `SAFE_ADDREF` / `SAFE_RELEASE`.
- `Mg*` objects derive from `MgGuardDisposable` (or `MgDisposable`).
- When MapGuide code touches FDO objects, use `FdoPtr` / `FDO_SAFE_*` on them.

### Standard library smart pointers

- `std::shared_ptr` / `std::unique_ptr` are fine for anything that is **not** an `Fdo*` or
  `Mg*` class — use whichever construct is appropriate.
- Do **not** use `std::shared_ptr` on `Fdo*` / `Mg*` objects — it double-owns the refcount.
