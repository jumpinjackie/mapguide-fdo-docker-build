# MapGuide API memory guidance — agent instructions (.NET, Java, PHP)

Portable guidance for any repository that builds an application on top of the MapGuide Open Source
API. It is self-contained: every rule here is justified by a measurement made against the binding
itself, and nothing refers to a particular build system, test harness or source checkout.

## How to deploy this file

Copy it into the target repository and make an agent pick it up, using whichever of these the repo
already uses:

| Mechanism | What to do |
|-----------|------------|
| `AGENTS.md` (repo root) | If the repo has no `AGENTS.md`, rename this file to that. If it has one, add a line such as *"Code that calls the `Mg*` API must follow `docs/mapguide-bindings.md`."* and put this file at whatever path that line names. |
| `.github/copilot-instructions.md` | Paste this content into it (or `@`-include it if the tool supports includes). |
| VS Code *instructions* file | Save as `.github/instructions/mapguide-bindings.instructions.md` with this frontmatter: `---` / `applyTo: "**/*.{cs,java,php}"` / `---` |
| Anything else | Any file the agent already reads on every turn works; the content is what matters. |

## 1. Scope

This applies to application code that talks to a MapGuide server through the **.NET**, **Java** or
**PHP** bindings — usually `MgSiteConnection` + `CreateService(...)`, and also MgPortable. It does not
apply to code inside the MapGuide source tree itself (C++ ownership there is a different contract).

Every object these bindings hand you is a **counted native reference wrapped in a proxy object**. The
proxy owns exactly one reference. The whole of this document is about giving that reference back.

## 2. The one rule

**Release every proxy you obtain, on every path — including the exception path.**

| | Java | .NET | PHP |
|---|---|---|---|
| Release | `obj.delete()` | `obj.Dispose()`, ideally `using` | drop the last reference (`unset($obj)`, reassignment, or scope exit) |
| Backstop you must not rely on | `finalize()` → `delete()` (deprecated for removal in the JDK) | `~MgObject()` → `Dispose(false)` | Zend object free handler on refcount 0 |
| Zero-cost scoping construct | **none** — proxies do not implement `AutoCloseable` | `using` works (`MgObject : IDisposable`) | **none** — there is no `Dispose()` method at all |
| Idempotent | yes | yes | n/a |

Two consequences that catch people:

- **Java**: there is no try-with-resources. A `try { ... } finally { x.delete(); }` is the idiom.
- **PHP**: `$reader->Dispose()` **does not exist** — it is a fatal "call to undefined method". You
  release by letting the proxy go (`unset()`), which for a short-lived variable happens by itself,
  but not for a variable reused in a loop.

## 3. What a dropped reference costs (they are not equivalent)

Do not reason about this by analogy with C++. Measured behaviour, releasing the same native object
each iteration:

| Runtime | What a forgotten release costs |
|---------|--------------------------------|
| C++ (for contrast) | A true leak: the reference is lost with no owner. |
| **Java** | *Deferred*, not lost. The proxy's finalizer releases it eventually. But native memory gives the JVM **no pressure signal**, so nothing prompts a GC: 60 iterations held 4 MB each and grew RSS 68 → 328 MB while the Java heap stayed flat at 11 MB. One `System.gc(); System.runFinalization()` returned it to 77 MB. |
| **.NET** | *Deferred*, same reason: 40 iterations grew RSS 54 → 225 MB; one `GC.Collect(); GC.WaitForPendingFinalizers()` returned it to 66 MB. |
| **PHP** | *Deterministic*: released at the end of the statement. 40 iterations over 4 MB stayed flat. |

"Deferred until a collection the runtime has no reason to run" is unbounded in practice, so the rule
still stands everywhere. But the decisive reason for the rule is **resources that are not memory**:

A `MgByteReader` returned by a service through `MgSiteConnection` holds a **pooled server
connection** until its stream is drained or the reader is released:

| State of the reader | Connection | Reader + payload |
|---|---|---|
| neither drained nor disposed | **held** — one per reader | held |
| drained to the end (`Read` returns 0) | returned to the pool | held |
| drained and released | returned | released |

Measured against a server with the shipped client limit of 10 connections: 12 readers fetched and
neither read nor released held 12 connections, and the **13th fetch failed outright** with *"Cannot
establish connection to the MapGuide Server"*. Releasing the held readers recovered it immediately.
That is a hard, immediate failure — not a slow one — and no GC is involved.

## 4. Rules

### R1. Release everything you create or receive

- Anything you construct: `new MgResourceIdentifier(...)`, `new MgByteSource(...)`, factory results
  (`geometryFactory.CreatePoint(...)`), `MgX.Create(...)`.
- Anything a getter returns: `con.GetSite()`, `coll.GetItem(0)`, `map.GetLayers()`,
  `layer.GetLayerDefinition()`, `service.GetResourceContent(...)`, `service.GetResourceData(...)`,
  `schema.GetClasses()`.
- Arguments you *pass in* are never consumed. A callee that keeps one takes its own reference, so
  releasing your copy after the call is always correct.

### R2. Never chain a counted getter, and never pass a temporary

```java
con.getSite().createSession();            // the MgSite temporary is released only by a finalizer
service.setResource(resId, src.getReader(), null);   // same for the reader
```

Hold each link in a named variable and release it. This applies to
`layer.getLayerDefinition().toString()`, `envelope.getLowerLeftCoordinate().getX()`,
`schema.getClasses().getItem(0)` and every other `Get*` chain.

### R3. Collections: add, then release your own reference

`Add`/`Insert`/`SetItem` take their **own** reference (they `AddRef`; they do not consume yours), and
`GetItem`/`GetItem(name)` hand back a **new** reference on top of the collection's.

```java
MgPropertyCollection props = new MgPropertyCollection();
MgProperty p = new MgStringProperty("Name", "Value");
try { props.addItem(p); } finally { p.delete(); }
```

Note the Java rename: `Add` is `addItem` (so the collection proxies can implement
`java.util.Collection`). .NET and PHP keep `Add`.

### R4. Readers are stream owners

- Always release the reader, including when you bail out early — `finally` / `using`.
- If you do not need the bytes in-process, do not read them: `reader.ToFile(path)` or
  `new MgByteSink(reader).ToFile(path)` streams natively instead of copying the payload into your
  runtime.
- Read in chunks of 8–64 KB. Chunk size does not change what a *leak* costs (it costs the payload
  either way), only the number of marshalling round-trips.

### R5. Connection, service and session lifecycle

- `MgInitializeWebTier(configPath)` once per process (Java: `MapGuideJavaApi.mgInitializeWebTier`,
  .NET: `OSGeo.MapGuide.MapGuideApi.MgInitializeWebTier`,
  PHP: `MgInitializeWebTier`). It is idempotent. The bindings expose **no**
  `MgUninitializeWebTier`, so treat the API's process-global state as living for the process.
- One `MgSiteConnection` per user identity, created once. Server connections are pooled and acquired
  per operation, so a connection object per request is not a socket leak — it is wasted handshakes and
  pool keys. The thing that genuinely holds a connection is an unread proxied reader (R4).
- Create services once, and release them at shutdown.
- `CreateSession()` / `DestroySession()` around the work; the `Session://...` repository goes with it.

### R6. Threads

- API objects are not thread-safe, and connections are pooled per connection properties. Give each
  worker its own `MgSiteConnection` and its own services.
- `MgUserInformation.SetCurrentUserInfo(...)` writes **thread-local** state whose destructor is a
  NULL function pointer. Clear it (`SetCurrentUserInfo(null)`) before a pooled worker thread returns,
  or the user information (and everything attached) stays with that thread.

### R7. Do not cache proxies

A static or long-lived cache of proxies pins the native object and its whole graph — a cached `MgMap`
or `MgLayerDefinition` keeps every layer, resource content and style it references. Cache identifiers
or serialized documents and re-fetch.

## 5. Language cheat sheets

The same flow — connect, session, fetch, read, clean up — done correctly.

### Java

```java
MapGuideJavaApi.mgInitializeWebTier(webConfig);          // once per process

MgSiteConnection con = new MgSiteConnection();
MgUserInformation ui = new MgUserInformation(user, pass);
MgSite site = null;
MgResourceService svc = null;
String session = null;
try
{
    con.open(ui);
    site = con.getSite();
    session = site.createSession();
    svc = (MgResourceService)con.createService(MgServiceType.ResourceService);

    MgResourceIdentifier resId = new MgResourceIdentifier("Session:" + session + "//data.sdf");
    try
    {
        MgByteReader reader = svc.getResourceData(resId, "data.sdf");
        try
        {
            byte[] buf = new byte[64 * 1024];
            int n;
            while ((n = reader.read(buf, buf.length)) > 0)
            {
                // consume buf[0..n)
            }
        }
        finally { reader.delete(); }
    }
    finally { resId.delete(); }
}
finally
{
    if (session != null) site.destroySession(session);
    if (svc != null) svc.delete();
    if (site != null) site.delete();
    con.delete();
    ui.delete();
}
```

### .NET

```csharp
MapGuideApi.MgInitializeWebTier(webConfig);              // once per process

using var ui = new MgUserInformation(user, pass);
using var con = new MgSiteConnection();
con.Open(ui);
using var site = con.GetSite();
string session = site.CreateSession();
try
{
    using var svc = (MgResourceService)con.CreateService(MgServiceType.ResourceService);
    using var resId = new MgResourceIdentifier("Session:" + session + "//data.sdf");
    using (var reader = svc.GetResourceData(resId, "data.sdf"))
    {
        byte[] buf = new byte[64 * 1024];
        int n;
        while ((n = reader.Read(buf, buf.Length)) > 0)
        {
            // consume buf[0..n)
        }
    }
}
finally
{
    site.DestroySession(session);
}
```

### PHP

```php
MgInitializeWebTier($webConfig);                         // once per process

$ui = new MgUserInformation($user, $pass);
$con = new MgSiteConnection();
$con->Open($ui);
$site = $con->GetSite();
$session = $site->CreateSession();
try
{
    $svc = $con->CreateService(MgServiceType::ResourceService);
    $resId = new MgResourceIdentifier("Session:" . $session . "//data.sdf");
    $reader = $svc->GetResourceData($resId, "data.sdf");
    try
    {
        $buf = null;
        while (($n = $reader->Read($buf, 65536)) > 0)
        {
            // consume $buf
        }
    }
    finally { unset($reader); }
}
finally
{
    $site->DestroySession($session);
}
```

## 6. Review checklist

When authoring or reviewing a diff that touches `Mg*` code, flag any occurrence of:

- [ ] A getter result that is not assigned to a variable and later released — especially two getters
      on one line (`a.GetB().GetC()`).
- [ ] A temporary created inside an argument list (`service.X(resId, src.GetReader(), ...)`).
- [ ] A `new Mg*` whose result is never released, including in a `catch`/early `return`.
- [ ] A reader that is read but not released, or released only on the happy path.
- [ ] A collection `Add`/`Insert`/`SetItem` argument that is not released by the caller.
- [ ] A `static`/singleton holding a proxy.
- [ ] Java: reliance on `finalize()`, or `delete()` only in the success path.
- [ ] PHP: `->Dispose()` (does not exist), or a loop that reuses a proxy variable without `unset`.
- [ ] .NET: a proxy created in a method that is not `using`/`Dispose`d.
- [ ] Worker threads that do not clear `MgUserInformation.SetCurrentUserInfo`.
- [ ] A `catch` block that swallows the exception and leaks a resource acquired before the throw.

## 7. Known binding defects, and how to tell whether your build has them

Two real defects existed in the bindings and are fixed in current MapGuide source. Both affect the
**single** method with a byte-array out-parameter, `MgByteReader.Read`, and **both are invisible to
the server's ASan/LSan instrumentation**, because the leaking allocation lives in the client process
(the JVM heap, or the Zend memory manager).

| Binding | Defect | Symptom |
|---|---|---|
| Java | `ReleaseByteArrayElements(..., JNI_COMMIT)` never frees the buffer `GetByteArrayElements` allocated | process RSS grows by roughly the payload size **per fetch** while the Java heap stays flat |
| PHP | `ZVAL_STRINGL` overwrites the caller's by-reference buffer without a `zval_ptr_dtor` | `memory_get_usage()` grows by ~1–1.5× the payload per fetch |
| .NET | none — `byte[]` is a blittable, pinned array; nothing is allocated per call | — |

Tell which build you have by measurement rather than by version arithmetic: fetch one large resource
in a loop and watch the plateau (section 8). A binding with either defect grows linearly with the
number of fetches regardless of chunk size; a fixed one plateaus immediately.

The complete byte-array surface of all three bindings is only three methods — `new
MgByteReader(byte[], int, string)`, `new MgByteSource(byte[], int)` and `MgByteReader.Read(byte[],
int)`. No wrapped API *returns* a byte array, so there is no equivalent hazard on the return side.

## 8. Measuring: the plateau test

The server's instrumented build proves nothing about your client. Use this instead; it works in all
three languages and needs no special tooling.

1. Warm up with 2–3 iterations, then discard the numbers.
2. Run the suspect operation 20–50 times on the same input.
3. Record per iteration: process RSS (`VmRSS:` in `/proc/self/status`) **and** your runtime's own
   counter — Java heap MXBean, `GC.GetTotalMemory(false)`, `memory_get_usage(false)`.
4. Read the result:
   - **linear in N** → a leak: something is acquired per iteration and not released.
   - **a step, then flat** → a pool, an arena or a GC sizing itself. Not a leak.
   - **growth only in RSS, counter flat** → native memory; suspect an unreleased proxy.
   - **growth only in the runtime counter** → your own data (a cache), or garbage awaiting a
     collection.

Per runtime:

- **Java**: `-Xmx` bounds the heap and nothing else, so heap-flat + RSS-climbing is native. Add
  `-Xcheck:jni` in CI to catch marshalling mistakes at the call that makes them. For a stack,
  `valgrind --tool=massif --detailed-freq=1 java ...` works without instrumenting anything.
- **.NET**: `GC.GetTotalMemory` sees only the managed heap; undisposed proxies show up in RSS only.
  A proxy released only by its finalizer can survive several collections.
- **PHP**: `memory_get_usage(false)` is the number to watch. Measure around **one** iteration — a
  per-call leak is obvious there and diluted over a long script. In a web request the heap is
  reclaimed at request end, so leaks surface in long-running CLI workers or as a `memory_limit`
  failure inside one large request.

## 9. Buffer pooling (.NET): only for LOH-sized buffers

`ArrayPool<byte>` reduces GC pressure; it does not affect leaks, because the .NET binding allocates
nothing per call. Whether it helps depends on the buffer size, since a read buffer is allocated once
per `Read`:

| Read buffer | Work | `new byte[n]` per read | `ArrayPool<byte>.Shared` |
|---|---|---|---|
| 1 MB | 50 fetches of a 16 MB stream | 50 MB allocated, 13 **gen2** collections | 1 MB allocated, 1 collection |
| 8 KB | 200 fetches | 1.6 MB allocated, 0 collections | ~0, 0 collections |

Pool at 85 KB and above; below that a gen0 allocation is cheaper than `Rent`/`Return`.

The binding accepts a pooled array correctly: it honours the explicit `length` (8,192/8,192 bytes
correct, zero written past the requested count with a rented 1 MB buffer), and pins rather than copies
(0 managed allocation per call). Four things it does not give you:

- **No offset or `Span<byte>` overloads.** `Read(byte[], int)` and both constructors are
  `(array, length)` from index 0; slicing a pooled buffer means copying.
- **Pass the count, not `buffer.Length`** — `Rent(n)` may return more, and only `[0, returnValue)`
  holds this read's bytes.
- **`Return` in a `finally`**, and never return a buffer you did not rent.
- **Pooled buffers are not cleared** — consume only what `Read` reported; use
  `Return(buf, clearArray: true)` for sensitive content.

Check where the pressure actually is before pooling. In one measured sample the 8 KB read buffer cost
0.001 MB per iteration while `MemoryStream.ToArray()` on the accumulated payload cost **48 MB per
iteration** — ~6,000× more. If the payload must end up in a `byte[]`, rent the *destination* and copy
chunks into it, or write straight to the `Stream`/file and never materialise it.

## 10. What this does not cover

- **Server-side leaks.** The MapGuide server's own memory behaviour is a different problem, and its
  instrumented (ASan/LSan) test builds only ever report on the server and the test runner.
- **Thread-safety beyond the rules above.** Object-level races are a correctness matter, not a
  lifetime one; R6 covers only the ownership-relevant part.
- **Windows-specific packaging.** The rules are identical; only the shipped binaries differ.
