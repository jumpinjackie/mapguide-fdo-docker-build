# C++ Code Style Guidelines

Applies to edits under `mapguide/MgDev` and `fdo`.

## Language standard

Both source trees compile as **C++11**:

- `fdo/CMakeLists.txt` → `set (CMAKE_CXX_STANDARD 11)`
- `mapguide/MgDev/CMakeLists.txt` → `set (CMAKE_CXX_STANDARD 11)` + `set (CMAKE_CXX_STANDARD_REQUIRED ON)`

Keep any new code within C++11 and avoid newer language-standard features.

`wchar_t` is 16-bit on MSVC and 32-bit on GCC/Linux, and the same sources compile on both. Do not
assume a character width in size or copy arithmetic — use the existing conversion helpers
(`A2W_SLOW`/`W2A_SLOW`, and the fixed-buffer `A2W_FAST`/`W2A_FAST`) rather than `sizeof(wchar_t)` or a
hand-rolled copy.

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
  message buffer are leaked. Name the exception, assert on it, then release it. An exception nested
  as another exception's *cause* is AddRef'd by the new exception, so the caught reference still has
  to be released.
- `coll->Add(FdoX::Create(...))` — **wrong**: `Add()` AddRefs its argument, so it does not consume the
  reference `Create()` returned. Give every `Create()` a home:
  `FdoPtr<FdoX> x = FdoX::Create(...); coll->Add(x);`

### SmartCast and the vetted usages of FdoPtr

`SmartCast<T>()` (on `FdoSmDisposable` and friends) also **returns an AddRef'd pointer** — it exists
so the result can be handed straight to an `FdoPtr`:

- `FdoSmPhMySqlOwnerP owner = base->SmartCast<FdoSmPhMySqlOwner>();` — correct.
- `base->SmartCast<FdoSmPhMySqlOwner>()->GetName()` — **wrong**: the cast's reference is dropped and
  never released. Anything the object owns — potentially a whole schema graph — stays alive.

The same applies to dereferencing any AddRef'ing getter inline
(`expr.GetArguments()->GetCount()`, `->FindItem(x)->GetName()`): load it into an `FdoPtr` first, or
release it explicitly.

This includes the *internal* schema-manager collections — `FdoSmCollection::GetItem()`,
`FdoSmNamedCollection::GetItem()` and the `Sm/Ph` row/field collections all end in
`FDO_SAFE_ADDREF(m_list[index])` (via `FdoCollection::GetItem()`), so `rows->GetItem(0)`,
`ROW->GetFields()` and `fields->GetItem(L"name")` each hand back a reference the caller owns just like
the public FDO collections do. In a per-row or per-lookup path that is one leaked reference per row
per getter: ten `fields->GetItem(name)->SetFieldValue(...)` calls in a reader's `ReadNext()` leaked
48,844 blocks / 5.5 MB in one 24-test fixture (against 7 blocks / 8 KB with the cache disabled).
Prefer the owning class's own helper — `FdoSmPhReadWrite::SetString()` looks the field up, holds it in
an `FdoSmPhFieldP` and releases it — otherwise hold each result in a `Ptr` local.

`FdoPtr<>` is vetted **only** as a local variable or as a class member — never as an STL container
element or a function parameter, and do not introduce new code that returns one by value. Where
existing code already returns an `Fdo<X>P`, take the result into an `FdoPtr` local (or a member) and
let the local release it. For a raw-pointer boundary, use `FDO_SAFE_ADDREF`/`FDO_SAFE_RELEASE`.

Child-to-parent back-pointers must be **raw, non-owning** pointers. A counted reference in one
direction plus a raw (or non-releasing) member in the other is a reference cycle: the object can
never reach zero references, so a pass in the unit suite still reports a leak. The same rule applies
to a helper an object creates and stores in one of its own members (a capability, a processor, a
context): the helper may hold its creator only through a **raw** back-pointer, because the creator
already owns the helper. A cycle is not fixable by releasing "harder" — every participant has a
legitimate reference — which is why the catalogued cycle cases are recorded rather than patched.
Converting such a member is layout-neutral — `FdoPtr<T>` holds a single `T*`, so the member keeps
its size, alignment and place in the object, and there is no vtable change — which is why it is this
tree's standard cycle fix. It does change the member's *ownership semantics*, though, so any code
outside the class that treats it as an `FdoPtr` (a subclass in another header, for example) has to be
updated with it.

Because `FdoPtr(T*)` *attaches*, **two `FdoPtr`s must never be built from the same raw pointer** —
each one will release on destruction, so the object is released twice for one `AddRef`:

```cpp
FdoPtr<FdoExpression> expr = filter.GetGeometry();           // owns the +1 the getter returned
FdoPtr<FdoGeometryValue> geom = dynamic_cast<FdoGeometryValue*>(expr.p);   // WRONG: attaches it again
```

The second pointer is a *borrow*; keep it raw (or copy the `FdoPtr`, which AddRefs). The symptom of
getting this wrong is not a leak but a crash — the object is destroyed early and something else is
still pointing at it.

### NULL `this` and Release builds

A member function must never be entered on a NULL object. That is undefined behaviour, and the
optimiser is entitled to assume `this` is never NULL, so it deletes any `if (this)`-style guard
(GCC warns about these with `-Wnonnull-compare`) and then dereferences the pointer anyway. Code that
survives a Debug build (`-O0`) can therefore fault in a Release build (`-O2`/`-O3`); do not write
code that depends on a NULL object being tolerated.

Two existing idioms do exactly that, and each has produced a Release-only crash:

- `FdoDataValue::Compare` cannot cope with a NULL operand — the `(!this)` test at its head is dead
  code. A NULL *value* has to go through `FdoInternalDataValue::Compare`, which is the gateway that
  tests for it.
- `SmartCast<T>(true)` is documented as usable on a NULL object, because `dynamic_cast(NULL)` is
  NULL and `FDO_SAFE_RELEASE(NULL)` is a no-op. Once `this` *is* the object pointer, though, the
  NULL guard inside `FDO_SAFE_RELEASE` is dead code, and the guard is removed. Anything that may be
  NULL — the result of a `FindItem()` that can fail, for example — must be cast through
  `FdoSmDisposable::SafeSmartCast<T>( pObject, true )` rather than `pObject->SmartCast<T>( true )`.

Since a Debug pass does not prove a Release build is safe here, run the affected suite in **both**
configurations (see [AGENTS.md](./AGENTS.md)).

### FDO

- Wrap FDO interface pointers in `FdoPtr<T>` (defined in `Fdo/Unmanaged/Inc/Common/Ptr.h`),
  or the `Fdo<T>P` convenience typedefs (for example `FdoClassP`).
- Use `FDO_SAFE_ADDREF` / `FDO_SAFE_RELEASE` for raw pointers (defined in
  `Fdo/Unmanaged/Inc/Common/IDisposable.h`).
- FDO interfaces derive from `FdoIDisposable`.
- `FdoCollection::Add()`, `Insert()` and `SetItem()` AddRef what they are given — the caller keeps its
  own reference and has to release it. The same is true of `GetItem()`/`FindItem()`, which return
  AddRef'd pointers.
- `FdoIDisposable::Release()` returns the new reference count ("value for debugging use only"), which
  makes it the cheapest leak probe there is: print it at teardown and an object that should be gone
  will show a count of 1.

### MapGuide

- Wrap `Mg*` objects in `Ptr<T>` (defined in `Common/Foundation/System/Ptr.h`).
- Use `SAFE_ADDREF` / `SAFE_RELEASE`.
- `Mg*` objects derive from `MgGuardDisposable` (or `MgDisposable`).
- When MapGuide code touches FDO objects, use `FdoPtr` / `FDO_SAFE_*` on them.

### Standard library smart pointers

- `std::shared_ptr` / `std::unique_ptr` are fine for anything that is **not** an `Fdo*` or
  `Mg*` class — use whichever construct is appropriate.
- Do **not** use `std::shared_ptr` on `Fdo*` / `Mg*` objects — it double-owns the refcount.
