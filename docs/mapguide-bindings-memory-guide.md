# Writing leak-free .NET, Java and PHP code against the MapGuide API

The C++ ownership contract lives in [CPP_STYLE.md § MapGuide](../CPP_STYLE.md#mapguide) and
[§ Ownership contract](../CPP_STYLE.md#ownership-contract). This page is the same contract seen from
the three managed bindings, plus the measurement recipes that tell you whether the code you wrote
obeys it; the measured record of the binding defects themselves is in the
[MapGuide leak record](./mapguide-memory-leaks.md#the-java-and-php-bindings-each-leaked-one-buffer-per-byte-out-parameter).

> This page is the repository's own record: it cites this tree's suites, containers and source paths.
> The same guidance as a **portable, repo-agnostic agent instructions file** — for dropping into an
> application repository that only consumes the MapGuide API — is
> [docs/mapguide-bindings-agent-guidance.md](./mapguide-bindings-agent-guidance.md). When the two
> disagree, this page is the evidence and that page is the summary.

## The one rule

**Every MapGuide object your code can see is a counted native reference, and your proxy owns one of
them.** When you are done with it, release it. Each language spells "release" differently:

| | Java | .NET | PHP |
|---|---|---|---|
| Release | `obj.delete()` | `obj.Dispose()` (`using`) | drop the last reference (`unset($obj)`) |
| Automatic backstop | `finalize()` → `delete()`, deprecated for removal in the JDK | `~MgObject()` → `Dispose(false)` | Zend object free handler, on refcount 0 |
| Idempotent | yes (`swigCPtr` zeroed) | yes (`Handle` zeroed) | n/a |
| `try`-with-resources / `using` | **no** — proxies do not implement `AutoCloseable` | yes — `MgObject : IDisposable` | **no** — there is no `Dispose()` at all |
| You forget → | released by a GC that has no reason to run (see below) | same | released at the end of the statement |

The last row is the one that matters and the one most easily mis-stated, so it has its own section:
[what a dropped reference actually costs, per binding](#1-dont-drop-an-intermediate-and-what-that-actually-costs).

```java
// Java
MgByteReader reader = resSvc.getResourceData(resId, "data.sdf");
try
{
    // ...
}
finally
{
    reader.delete();
}
```

```csharp
// .NET
using (var reader = resSvc.GetResourceData(resId, "data.sdf"))
{
    // ...
}
```

```php
// PHP
$reader = $resSvc->GetResourceData($resId, "data.sdf");
try
{
    // ...
}
finally
{
    unset($reader);
}
```

The finalizer/handler is a **backstop, not a plan**. In Java and .NET it runs when the GC feels like
it, which for a proxy holding an 18 MB native reader or a pooled server connection can be arbitrarily
late — and the GC is not even prompted, because native memory is invisible to it. In PHP the release
is deterministic (the object's refcount), but a leak inside one request looks identical to a correct
program until the request's `memory_limit` is reached.

## Where the references come from

Four shapes, all owning:

| Shape | Examples | What to do |
|-------|----------|------------|
| You construct it | `new MgResourceIdentifier(...)`, `new MgByteSource(...)`, a factory result such as `geomFactory.CreatePoint(coord)` | release it |
| A getter returns it | `con.GetSite()`, `coll.GetItem(0)`, `map.GetLayers()`, `layer.GetLayerDefinition()`, `resSvc.GetResourceContent(...)`, `resSvc.GetResourceData(...)`, `schema.GetClasses()` | release it — **including when you only need it for one expression** |
| A collection keeps it | `coll.Add(x)`, `coll.Insert(i, x)`, `coll.SetItem(i, x)` — the collection `SAFE_ADDREF`s what it is given (`MgDisposableCollection::Add`) | the collection's reference is its own: release yours |
| An exception carries it | `catch (MgException e)` in Java/.NET, `catch (MgException $e)` in PHP | don't hoard exceptions; release/dispose if you store one |

Arguments you *pass in* are never consumed — a callee that keeps one takes its own reference, so
releasing your copy after the call is always correct.

## The patterns

### 1. Don't drop an intermediate (and what that actually costs)

`con.getSite().createSession()` reads perfectly well, and in C++ it is an unambiguous leak: the
temporary `MgSite` loses its reference and nothing ever releases it. **The managed bindings are not
the same**, and the difference is worth stating precisely rather than by analogy.

Measured here (Debug tree, 4 MB native payload per iteration, in a 6 GB-capped container):

| Binding | `new MgByteSource(payload, len).GetReader()` in a loop — what the dropped temporary costs |
|---|---|
| Java | Nothing is *lost*: the proxy owns the reference and its `finalize()` releases it. But it holds the payload until a GC runs, and **native memory gives the JVM no pressure signal**, so none does: 60 iterations grew RSS 68 → 328 MB while the Java heap stayed flat at 11 MB. One `System.gc(); System.runFinalization()` took it back to 77 MB. |
| .NET | Same, via `~MgObject()` → `Dispose(false)`: 40 iterations grew RSS 54 → 225 MB; one `GC.Collect(); GC.WaitForPendingFinalizers()` took it back to 66 MB. |
| PHP | Nothing at all. The temporary's refcount reaches 0 at the end of the statement, so the object free handler releases it: 40 iterations over 4 MB stayed flat at 4,483 KB of `memory_get_usage()`. |

So it is a **deferred** release in Java and .NET, not a lost one — but "deferred until a collection
the runtime has no reason to run" is unbounded in practice, and Java's finalization is deprecated for
removal, so a future JDK can turn the deferral into a real leak. In PHP, chaining is genuinely fine
as far as memory goes.

The reason the rule still stands in all three languages is **resources that are not memory**. A
`MgByteReader` from a proxied service holds a pooled server connection until the stream is drained or
the reader is disposed (`ByteSourceSocketStreamImpl` keeps a `Ptr<MgServerConnectionBase> m_conn`),
and that is a hard, immediate failure rather than a slow one. Measured against a server whose
`[ClientConnectionProperties] MaxConnections` is 10:

- 12 readers fetched and neither read nor disposed → 12 established connections, and the **13th fetch
  fails outright** with "Cannot establish connection to the MapGuide Server". Disposing the held
  readers recovers it immediately; no GC is involved and memory pressure is irrelevant.
- 20 readers each **drained to the end** but not disposed → 1 connection established. Draining calls
  `Close()` and returns the connection to the pool, so draining fixes the connection — but only
  `delete()`/`Dispose()`/`unset()` gives back the reader proxy and its payload.

Hold each link in a named variable and release it:

```java
MgSite site = con.getSite();                             // owns one reference; you release it
try { session = site.createSession(); } finally { site.delete(); }
```

```csharp
using (var site = con.GetSite()) { session = site.CreateSession(); }
```

```php
$site = $con->GetSite();                                 // released when $site is reassigned/unset
$session = $site->CreateSession();
unset($site);
```

The same shape hides in `layer.getLayerDefinition().toString()` (the temporary `MgResourceIdentifier`),
`envelope.getLowerLeftCoordinate().getX()` (the temporary `MgCoordinate`),
`schema.getClasses().getItem(0)` (the temporary collection) and every other `Get*` in the chain.

### 2. Give an argument that you construct its own home

The same deferral as above, applied to an argument you create inline:

```java
resSvc.setResource(resId, src.getReader(), null);        // the reader returned by getReader() is dropped
```

```csharp
resSvc.SetResource(resId, src.GetReader(), null);
```

If you created it, the call does not take your reference away, so hold it and release it:

```java
MgByteReader def = src.getReader();
try { resSvc.setResource(resId, def, null); } finally { def.delete(); }
```

### 3. Collections: add, then release your own reference

```java
MgPropertyCollection props = new MgPropertyCollection();
MgProperty p = new MgStringProperty("Name", "Value");
try { props.addItem(p); } finally { p.delete(); }   // addItem() took its own reference
```

(`add` is renamed to `addItem` in Java so the collection proxies can implement `java.util.Collection`;
.NET and PHP keep `Add`.)

`GetItem()`/`GetItem(name)` hand back a **new** reference on top of the collection's. Iterating a
collection and disposing each result is correct; not disposing them leaks the whole element graph.

### 4. Readers are stream owners — dispose them, and prefer not to read what you don't need

A `MgByteReader` returned by a *proxied* service (i.e. anything reached through `MgSiteConnection`)
is backed by `ByteSourceSocketStreamImpl`, which holds a **pooled server connection** until the
stream is drained. Both draining and disposing run `Close()`, which drops the connection back into
the pool — but they are not equivalent:

| State of the reader | Connection | Reader + payload |
|---------------------|------------|------------------|
| neither drained nor disposed | held (measured: one per reader, and the 13th fetch fails outright) | held |
| drained to the end (`Read` returns 0) | returned | held until disposed |
| drained and disposed / `unset` | returned | released |

That is why "I read it all, so it must be fine" is only half true: the *connections* recover, the
native memory does not, and the finalizer is the only thing that will release it. Since a proxied
reader's error paths are exactly where a loop bails out early, the dispose belongs in a `finally`.

Consequences worth designing around:

- Always dispose the reader, even when you bail out early — and again, `unset()` in PHP.
- If you don't need the bytes in your process, don't read them: `reader.ToFile(path)` (all three
  bindings) or `new MgByteSink(reader).ToFile(path)` streams natively instead of copying the payload
  into the managed heap.
- Read in chunks of a sane size (8–64 KB is plenty). Chunk size does not change the amount of memory
  a *leak* costs you — it costs you the payload either way — but it does change the number of
  marshalling round-trips.

#### Pooling the read buffer (.NET): what it buys, and what it doesn't

`ArrayPool<byte>` is a **GC-pressure** tool, not a leak tool — the .NET binding never allocated
anything per call to begin with, so pooling changes nothing about leaks (the RSS deltas below are the
same either way). What it does buy depends entirely on the buffer size, because the read buffer is
allocated once per `Read` call and a 1 MB one lands on the Large Object Heap:

| Read buffer | 50–200 iterations | `new byte[n]` per read | `ArrayPool<byte>.Shared` |
|---|---|---|---|
| 1 MB | 50 fetches of a 16 MB stream (800 MB read) | 50 MB allocated, **13 gen2 collections** | 1 MB allocated, **1 collection** |
| 8 KB | 200 fetches (3.2 GB read) | 1.6 MB allocated, **0 collections** | ~0, 0 collections |

So: worth pooling at 1 MB, pointless at 8 KB. The break-even is simply whether the buffer is
LOH-sized (≥ 85 KB) — below that a gen0 allocation is cheaper than the `Rent`/`Return` bookkeeping.

**The binding plays along**, which was worth checking rather than assuming. A rented array is larger
than the count you asked for, so the question is whether `Read` respects the explicit length and
whether the P/Invoke copies. Measured with a rented 1 MB buffer and an 8 KB read: 8,192/8,192 bytes
of payload correct, **0 bytes written past the requested count**, and 0 MB of managed allocation
across 200 iterations — i.e. the array is pinned for the call and written in place, not marshalled
through a copy. Four things it does *not* give you:

- **No offset overloads.** `Read(byte[], int)` and both `MgByteSource`/`MgByteReader` constructors
  take `(array, length)` starting at index 0. A pooled buffer is usable only from 0; there is no
  `(array, offset, count)` and no `Span<byte>` overload, so slicing means copying.
- **Pass the count you want, not `buffer.Length`.** `Rent(n)` may return more than `n`; only
  `[0, returnValue)` holds this read's bytes.
- **`Return` in a `finally`.** An exception between `Rent` and `Return` loses the buffer; and never
  return one you did not rent.
- **Pooled buffers are not cleared.** Consume only what `Read` reported, and use
  `Return(buf, clearArray: true)` if the contents are sensitive.

And the thing to check first: **the read buffer is rarely where the pressure is.** In the leak-report
sample the 8 KB read buffer accounted for 0.001 MB per iteration while `mem.ToArray()` on the
accumulated stream accounted for **48 MB per iteration** (960 MB over 20 fetches of a 16 MB
resource, with 31 full gen2 collections and a 141 MB higher RSS watermark) — roughly 6,000× more.
Pooling the read buffer there optimises the wrong 8 KB. If the payload has to end up in a `byte[]`,
rent the *destination* and copy chunks into it, or write straight to the `Stream`/file
(`MgByteSink.ToFile`, `reader.ToFile`) and never materialise it.

### 5. Connection, service and session lifecycle

- `MgInitializeWebTier(...)` once per process: `MapGuideJavaApi.mgInitializeWebTier(path)` (Java),
  `OSGeo.MapGuide.MapGuideApi.MgInitializeWebTier(path)` (.NET), `MgInitializeWebTier($path)` (PHP).
  It is idempotent, and `MgUninitializeWebTier` is **not** part of the generated API in any of the
  three bindings — treat the API's process-global state as living for the process.
- One `MgSiteConnection` per user identity, created once. Server connections themselves are pooled
  and acquired per operation (`MgServerConnection::Acquire`, keyed on the connection properties), so
  a connection object per request is not a socket leak — but it is a new pool key, new session
  bookkeeping and a repeated handshake for no benefit. The thing that genuinely holds a connection
  for a long time is an unread proxied reader (pattern 4).
- `CreateService()` results are owned by you; create them once and release them at shutdown.
- A session is a heavy server object: `CreateSession()`/`DestroySession()` around the work, and let
  the session repository (`Session://...`) go away with it.

### 6. Threads

- MapGuide API objects are not thread-safe, and the connection pool is keyed per user/connection
  properties. Give each worker thread its own `MgSiteConnection` and its own services.
- `MgUserInformation.SetCurrentUserInfo()` stores into **thread-local** storage whose destructor is
  a NULL function pointer. Whichever value a thread last set stays with that thread until the thread
  clears it (`SetCurrentUserInfo(NULL)`) — a worker that returns to a pool without clearing it leaks
  the user information and everything hanging off it.

### 7. Don't hoard proxies

A static or long-lived cache of proxies pins the native objects and their whole object graphs (a
cached `MgMap` or `MgLayerDefinition` keeps every layer, resource content and style it references).
Cache identifiers or serialized documents instead, and re-fetch what you need.

## A correct program at a glance

The leak-test shape - connect, create a session, fetch resource data, read it, clean up - done in
each language. Every proxy created here is released, and every reader is drained or disposed on the
exception path too.

```java
MapGuideJavaApi.mgInitializeWebTier(webConfig);           // once per process

MgSiteConnection con = new MgSiteConnection();
MgUserInformation ui = new MgUserInformation(user, pass);
MgSite site = null;
MgResourceService resSvc = null;
String session = null;
try
{
    con.open(ui);
    site = con.getSite();
    session = site.createSession();
    resSvc = (MgResourceService)con.createService(MgServiceType.ResourceService);

    MgResourceIdentifier resId = new MgResourceIdentifier("Session:" + session + "//data.sdf");
    try
    {
        MgByteReader reader = resSvc.getResourceData(resId, "data.sdf");
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
    if (resSvc != null) resSvc.delete();
    if (site != null) site.delete();
    con.delete();
    ui.delete();
}
```

```csharp
MapGuideApi.MgInitializeWebTier(webConfig);               // once per process

using var ui = new MgUserInformation(user, pass);
using var con = new MgSiteConnection();
con.Open(ui);
using var site = con.GetSite();
string session = site.CreateSession();
try
{
    using var resSvc = (MgResourceService)con.CreateService(MgServiceType.ResourceService);
    using var resId = new MgResourceIdentifier("Session:" + session + "//data.sdf");
    using (var reader = resSvc.GetResourceData(resId, "data.sdf"))
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

```php
MgInitializeWebTier($webConfig);                          // once per process

$ui = new MgUserInformation($user, $pass);
$con = new MgSiteConnection();
$con->Open($ui);
$site = $con->GetSite();
$session = $site->CreateSession();
try
{
    $resSvc = $con->CreateService(MgServiceType::ResourceService);
    $resId = new MgResourceIdentifier("Session:" . $session . "//data.sdf");
    $reader = $resSvc->GetResourceData($resId, "data.sdf");
    try
    {
        $buf = null;
        while (($n = $reader->Read($buf, 65536)) > 0)
        {
            // consume $buf
        }
    }
    finally
    {
        unset($reader);
    }
}
finally
{
    $site->DestroySession($session);
}
```

In PHP the remaining locals are released when the script (or the function) ends; `unset()` matters
when the same variables are reused in a long-running loop, which is exactly the case the leak tests
above exercise.

## Binding defects you may inherit

Two of the three bindings leaked the caller's buffer on **every** bulk read; both are fixed in this
tree (details and measurements in
[docs/mapguide-memory-leaks.md](./mapguide-memory-leaks.md#the-java-and-php-bindings-each-leaked-one-buffer-per-byte-out-parameter)):

| Binding | Defect | Symptom on an older build |
|---------|--------|---------------------------|
| Java | `ReleaseByteArrayElements(..., JNI_COMMIT)` never freed the JNI buffer | RSS grows by the payload size per resource fetch while the Java heap stays flat |
| PHP | `ZVAL_STRINGL` overwrote the by-ref buffer without a `zval_ptr_dtor` | `memory_get_usage()` grows by ~1–1.5× the payload per fetch |
| .NET | none — `byte[]` is a pinned blittable array, nothing allocated per call | — |

The shape of both is "the leak is proportional to the payload, not to the number of calls", and both
look like "the reader is not being disposed" when it is nothing of the sort. If you are chasing that
symptom on an older build, upgrade before rewriting your loop.

### The complete byte-array surface (there are only three methods)

Audited rather than assumed: the whole wrapped API has exactly three methods whose signature involves
a byte array, and they are the same three in all three languages —

| Wrapped API | Direction | Java | .NET | PHP |
|-------------|-----------|------|------|-----|
| `MgByteReader(byte[], int, string)` | in | `GetByteArrayElements` / release mode 0 — correct | blittable `Byte[]` — correct | pointer into the `zend_string`, nothing allocated — correct |
| `MgByteSource(byte[], int)` | in | as above — correct | as above — correct | as above — correct |
| `MgByteReader.Read(byte[], int)` | out | **was `JNI_COMMIT` — leaked** | blittable `Byte[]` — correct | **was `ZVAL_STRINGL` without a dtor — leaked** |

Nothing in the wrapped API *returns* a byte array: the Java glue contains no `NewByteArray`/
`SetByteArrayRegion` call at all, and no generated .NET proxy declares a `byte[]` return. The
`BYTE_ARRAY_OUT`-returning methods that exist in C++ (`MgFeatureReader::GetGeometry(...)`, which hands
back an allocated buffer plus its length) are not in the wrapped `MgFeatureReader` — the generated
`MapGuideApi.i` carries `GetClassDefinition` and `GetFeatureObject` for that class but no
`GetGeometry`, and the client-side implementation (`MgProxyFeatureReader::GetGeometry`) throws
`NotImplemented` anyway. `MgByte`, the other class with a `BYTE_ARRAY_OUT Bytes()`, is not exposed.

The two `in` constructors were checked empirically, because "release mode 0 is correct" is a reading
of the JNI spec rather than an observation: 200 iterations of a 4 MB payload, explicitly deleting each
object, grew RSS by ~1 MB in total (~0.05 MB per iteration, allocator noise) for `MgByteSource` and
the same for `MgByteReader` — i.e. the per-call JNI buffer is freed. Deleting the native object cannot
mask a leaked JNI buffer (they are separate allocations), so that loop tests exactly the marshalling.
Both copy the input (`MgByte`'s constructor `memcpy`s into its own buffer), which is why mode 0 —
and, if anyone wants to shave a copy, `JNI_ABORT`, which skips the needless copy-back — is safe.

Re-run the audit against a build tree with:

```sh
# what the JNI glue actually does with byte arrays
grep -n "GetByteArrayElements\|ReleaseByteArrayElements\|NewByteArray" \
    Bindings/src/Bindings/Java/MgApi_wrap.cpp
# how many by-ref out-params the PHP glue writes back
grep -c Z_REFVAL Bindings/src/Bindings/Php/MgApi_wrap.cpp
# .NET proxies with a byte array in their surface
grep -rl "System.Byte\[\]" --include=*.cs .
# the C++ APIs that take or return one
grep -rn "BYTE_ARRAY_IN\|BYTE_ARRAY_OUT" --include=*.h Common PlatformBase
```

Anything that appears in the last command but not in the first three is an API that is not wrapped, and
therefore not reachable from an application.

## Proving that your code doesn't leak

The C++ instrumented build does not help here. The server suites run ASan/LSan on the **server**;
a binding leak happens in the **client** process's own runtime (JVM heap, Zend memory manager, .NET
managed heap). The suites can be perfectly green while the client OOMs, because their verdict is
assertions plus the server's log — neither of which knows how much memory the client used. That is
why neither of the two defects above was ever flagged by one.

### The plateau test (works for all three)

1. Warm up with 2–3 iterations and discard the numbers.
2. Run the suspect operation N times (20–50 is enough) with the same input.
3. Record, per iteration: process RSS (`VmRSS:` in `/proc/self/status`) **and** the runtime's own
   counter (Java heap MXBean, `GC.GetTotalMemory(false)`, `memory_get_usage(true/false)`).
4. Read the result:
   - **linear in N** → a leak; find what is allocated per iteration and not released;
   - **a step, then flat** → a pool, an arena or a GC heap sizing itself; not a leak;
   - **rounded growth with a matching runtime counter** → the runtime's own heap is the thing that
     grew; check whether it is your data (a cache) or garbage waiting for a collection.

Reference numbers from the investigation that produced this page, all fetching an 18 MB resource
data stream in a 6 GB-capped container:

| Client | Before the fix | After the fix |
|--------|----------------|---------------|
| Java, 12 fetches | 17,188 KB RSS per fetch, heap flat at 23 MB | 233 KB per fetch (JVM noise) |
| PHP, 12 fetches | 27,717 KB RSS per fetch | 2 KB per fetch |
| .NET, 12 fetches | 798 KB per fetch, plateau from the 7th — no defect to fix | — |

### Per runtime

**Java**

- `-Xmx` bounds the heap and nothing else: heap flat + RSS climbing is a native leak. Start there.
- `valgrind --tool=massif --detailed-freq=1 java -Xint ...` attributes the retained chunks with
  source lines (the tree is a Debug build), and works without instrumenting the JVM or MapGuide:
  read the last snapshot's allocation tree.
- `-Xcheck:jni` makes the JVM check every JNI call and report misuse (bad references, pending
  exceptions, mismatched release modes) — cheap to add to a CI run, and the kind of flag that would
  have flagged `JNI_COMMIT`-as-a-release the day it was written.

**\.NET**

- `GC.GetTotalMemory(false)` sees only the managed heap; native object growth (an undisposed proxy,
  a pooled stream) shows up in RSS only.
- Long-lived large arrays (`MemoryStream.ToArray()` over an 18 MB payload) put pressure on the LOH and
  make RSS look alarming while it is simply the heap's high-water mark. Check for a plateau before
  concluding anything.
- A proxy that is only released by its finalizer can survive several collections; if RSS grows
  steadily, look for a `Mg*` object that is never `Dispose()`d.

**PHP**

- `memory_get_usage(false)` is the number to watch: it counts the Zend heap, which is where a
  binding leak lands. `memory_get_usage(true)` (the arena) shows the same leak rounded to the
  allocator's size classes.
- Measure around **one** iteration, not the whole script: a leak of one buffer per call is obvious
  per iteration and diluted over a long run.
- In a web request the whole heap is reclaimed at request end, so leaks only surface in long-running
  CLI workers or as a `memory_limit` failure inside one large request.

### Where the automation stops

Nothing in this repository turns a *client-runtime* leak into a red build today: the instrumented
suites are native and single-pass, so they see neither the JVM, the Zend heap nor the .NET heap, and
a leak only shows over many iterations in one process. The other ABI-compatibility checks have the
same shape — they compare a surface, they do not run a program — so this is a gap rather than an
oversight. What is cheap to close, roughly in order of effort:

1. Script the plateau test for the one flow a binding application actually uses (connect, fetch,
   read, dispose) and assert that RSS and the runtime counter are within a band across N iterations.
   That is the only technique that catches the class of defect described above.
2. Java: add `-Xcheck:jni` to the suite's JVM flags. It costs nothing and reports the marshalling
   mistakes at the call that makes them.
3. PHP: run the suite with a `memory_limit` just above what a correct run needs. A per-call leak
   fails the run with a FATAL error instead of a silently larger process.
4. .NET: there is no built-in counter for live proxies. A ctor/`Dispose(bool)` pair in `MgObject`
   would give one, but it has to be generated (and is therefore a binding change, not a test).

### Use the repository's own suites as regression harnesses

`run_mapguide_tests.sh --tier web --web-suite java|php|dotnet` drives the real bindings against a
real server (they apply resource packages, read resource data, exercise the byte-reader paths) and
also fails the run if the server does not shut down cleanly. They cannot see a client-side runtime
leak, so pair them with the plateau test above when you have changed anything that marshals data.

## Checklist

- [ ] Every `new`/`Create*` result and every getter result has a `delete()` / `Dispose()` / `unset()`.
- [ ] No getter is dereferenced inline (`a.GetB().GetC()`) — in Java/.NET that defers the release to a
      GC that native memory never prompts; in PHP it is released at the end of the statement.
- [ ] Objects created to be passed as arguments are held and released after the call.
- [ ] Collections: added items are released by the caller after `Add`/`Insert`/`SetItem`.
- [ ] Readers are disposed on every path; large payloads go through `ToFile`/`MgByteSink`.
- [ ] One `MgSiteConnection` and one set of services per user/thread, released at shutdown.
- [ ] Sessions destroyed; thread-local user info cleared on worker exit.
- [ ] Nothing caches proxies in a static.
- [ ] A plateau test was run on the code path you changed, with the runtime's own counter *and* RSS.
