# Handoff: stateless selection set management

**Status:** Design exploration. **No source change made.** The recommendation is a wire-compatible
extension of the existing selection document plus one request parameter (`SELECTION`) on four
existing MapAgent operations — not a new selection service.
**Date:** 2026-10-22
**Source tree:** `mapguide/MgDev` @ SVN `branches/4.0/MgDev`, revision 10223 (clean apart from the
unrelated Band/Stylization work already in the working copy)
**API/ABI mode:** `freeze`, scope `mapguide`. Nothing binding-visible has to move: the C++ classes
are not the public surface, and the proposal only adds an **optional** HTTP parameter and an
**optional** XML attribute. The check is nevertheless mandatory and cheap — `Bindings/src/ApiDump/api.*.txt`
must come out identical (see [Verification](#8-verification-plan)).
**Predecessor:** [mapguide-load-balancing-assessment.md](./mapguide-load-balancing-assessment.md) —
this document assumes its §4.3 (session affinity), §6.2 (sessions are pinned) and §8 (verdict).

---

## Why this document exists

[RFC 157](https://trac.osgeo.org/mapguide/wiki/MapGuideRfc157) removed the first half of the
stateful-map problem: `MgMap::Create()` can now be given the display parameters
(`displayWidth`, `displayHeight`, `x`, `y`, `scale`, `dpi`) at creation time, so a map can be built
from a MapDefinition and rendered without ever being written to a session repository —
[`Map.h:407`](../mapguide/MgDev/Common/MapGuideCommon/MapLayer/Map.h#L407),
implemented at [`Map.cpp:135`](../mapguide/MgDev/Common/MapGuideCommon/MapLayer/Map.cpp#L135), exposed
to PHP as `CreateStateless` ([`monkey_patch.i:32`](../mapguide/MgDev/Bindings/src/SwigCommon/Php/monkey_patch.i#L32)).

The second half was left open in RFC 157's own addendum: a selection produced by an operation that
took a stateless map could not be interrogated later, because it had no map. `SetMap` was promoted
to `EXTERNAL_API` as the workaround
([`SelectionBase.h:543-547`](../mapguide/MgDev/Common/PlatformBase/MapLayer/SelectionBase.h#L543)).
That is a repair, not a model.

So the question this document answers is: **what does a selection set look like when no server-side
resource remembers it, and which operations produce and consume it?**

The short answer, argued below: *the selection set is already a document* — the `FeatureSet` XML that
`QUERYMAPFEATURES` returns and that `GETFEATURESETENVELOPE` and `FEATUREFILTER` already accept. The
server already reattaches it to a map on every rendering call
([`OpRenderMap.cpp:65-71`](../mapguide/MgDev/Server/src/Services/Rendering/OpRenderMap.cpp#L65)). The
only thing that is *not* portable about the document is the layer key it carries: a per-creation
UUID. Fix that and the rest is plumbing.

---

## TL;DR

| # | Finding | Consequence |
|---|---------|-------------|
| 1 | A selection is serialized as `FeatureSet` XML: layer key → class name → base64 identity blobs ([`SelectionBase.cpp:196`](../mapguide/MgDev/Common/PlatformBase/MapLayer/SelectionBase.cpp#L196)) | It is already a transferable document; no new format is needed |
| 2 | Rendering already takes an explicit `MgSelection*`, and the map+selection travel together over the wire on every call ([`RenderingService.h:433`](../mapguide/MgDev/Common/MapGuideCommon/Services/RenderingService.h#L433), [`OpRenderMap.cpp:65-71`](../mapguide/MgDev/Server/src/Services/Rendering/OpRenderMap.cpp#L65)) | The rendering service layer is stateless today; the state lives in the session repository, written by the web tier (and by `CREATERUNTIMEMAP` on the server) |
| 3 | The layer key is `MgLayerBase::GetObjectId()` — a UUID generated in the layer constructor ([`LayerBase.cpp:76`](../mapguide/MgDev/Common/PlatformBase/MapLayer/LayerBase.cpp#L76)) | A document from one map instance does not resolve against a map created fresh for the next request |
| 4 | Layer **names** are unique within any successfully created map (`MgNamedCollection` throws on duplicates, [`NamedCollection.cpp:487`](../mapguide/MgDev/Common/Foundation/Data/NamedCollection.cpp#L487)) and are already the stateless currency (`SHOWLAYERS`, `LAYERNAMES`, the `FEATUREFILTER` correlation) | Add an optional `name` attribute to `<Layer>`; resolve `id` first, `name` second |
| 5 | `SELECTION` is already a defined-but-unused MapAgent parameter name ([`HttpResourceStrings.cpp:238`](../mapguide/MgDev/Web/src/HttpHandler/HttpResourceStrings.cpp#L238)) | No new vocabulary; four existing operations gain one optional parameter |
| 6 | `FEATUREFILTER` on `QUERYMAPFEATURES` is **already** parsed as selection XML, not as an attribute filter ([`ServerRenderingService.cpp:1489-1492`](../mapguide/MgDev/Server/src/Services/Rendering/ServerRenderingService.cpp#L1489)) | The capability exists today under a misleading name; formalising it is a rename, not a new mechanism |
| 7 | Accepting client-supplied blobs exposes several weaknesses: FDO string literals are not escaped ([`SelectionBase.cpp:630-637`](../mapguide/MgDev/Common/PlatformBase/MapLayer/SelectionBase.cpp#L630)) and the id blobs are decoded without bounds checks ([`MemoryStreamHelper.cpp:192`](../mapguide/MgDev/Common/Foundation/System/MemoryStreamHelper.cpp#L192)) | **Hardening is a precondition, not a follow-up** (see [§4.6](#46-security-requirements-p0)) |

Recommended shape, in one paragraph: a selection is a **value the client holds**, not a resource the
server owns. Operations are pure functions over `(map definition, view state, selection document)`
and return one of `selection document | image | attributes | envelope`. `SELECTION` supplies the input
document; omitting it preserves today's session-backed behaviour exactly.

---

## 1. What already exists (the primitives)

Every row below is shipped code. The column on the right is the assumption that stops it being used
statelessly today.

| Primitive | Where | What it gives us | What it still assumes |
|---|---|---|---|
| `MgMap::Create` with display parameters | [`Map.h:407`](../mapguide/MgDev/Common/MapGuideCommon/MapLayer/Map.h#L407), [`Map.cpp:135`](../mapguide/MgDev/Common/MapGuideCommon/MapLayer/Map.cpp#L135) | A complete map (layers, groups, extent, scale, size) with no repository write | an `MgResourceService` (the web tier has one via the site connection) |
| `MgSelection(map, xml)` / `ToXml` / `FromXml` | [`Selection.h:67`](../mapguide/MgDev/Common/MapGuideCommon/MapLayer/Selection.h#L67), [`SelectionBase.h:68`](../mapguide/MgDev/Common/PlatformBase/MapLayer/SelectionBase.h#L68), [`SelectionBase.h:169`](../mapguide/MgDev/Common/PlatformBase/MapLayer/SelectionBase.h#L169), [`SelectionBase.h:187`](../mapguide/MgDev/Common/PlatformBase/MapLayer/SelectionBase.h#L187), [`SelectionBase.cpp:104`](../mapguide/MgDev/Common/PlatformBase/MapLayer/SelectionBase.cpp#L104), [`SelectionBase.cpp:196`](../mapguide/MgDev/Common/PlatformBase/MapLayer/SelectionBase.cpp#L196) | A selection can be built from, and emitted as, a document | the layer keys in the document must match the map passed in |
| `MgSelection::SetMap` (`EXTERNAL_API`, in the bindings) | [`SelectionBase.h:547`](../mapguide/MgDev/Common/PlatformBase/MapLayer/SelectionBase.h#L547), [`SelectionBase.cpp:955`](../mapguide/MgDev/Common/PlatformBase/MapLayer/SelectionBase.cpp#L955) | Reattach a detached selection (the RFC 157 addendum's fix) | nothing — it resolves nothing today, it only stores the pointer |
| `RenderMap(map, selection, …)` / `RenderDynamicOverlay(map, selection, …)` | [`RenderingService.h:433`](../mapguide/MgDev/Common/MapGuideCommon/Services/RenderingService.h#L433), [`RenderingService.h:356`](../mapguide/MgDev/Common/MapGuideCommon/Services/RenderingService.h#L356) | Rendering with an explicit selection, no session lookup | the selection must already be keyed to *that* map instance |
| map + selection over the wire | [`OpRenderMap.cpp:65-71`](../mapguide/MgDev/Server/src/Services/Rendering/OpRenderMap.cpp#L65) | The server receives both and calls `selection->SetMap(map)` itself | nothing |
| `QueryFeatures(…, featureFilter, …)` | [`ServerRenderingService.cpp:1489-1492`](../mapguide/MgDev/Server/src/Services/Rendering/ServerRenderingService.cpp#L1489) | A query can be **restricted by an existing selection document** | the `FEATUREFILTER` name says the opposite (see §4.3) |
| `SelectionKey` = the `<ID>` encoding | [`HtmlController.cpp:760`](../mapguide/MgDev/Common/MapGuideCommon/Controller/HtmlController.cpp#L760) (`EncodeKey`, a "carbon-copy impl of `MgSelectionBase::AddFeatureIds()`"), emitted at [`HtmlController.cpp:543`](../mapguide/MgDev/Common/MapGuideCommon/Controller/HtmlController.cpp#L543) | The v4 API already hands the client a per-feature token in the same encoding the document uses | nothing |
| `GETFEATURESETENVELOPE` (`FEATURESET`) | [`HttpGetFeatureSetEnvelope.cpp:38`](../mapguide/MgDev/Web/src/HttpHandler/HttpGetFeatureSetEnvelope.cpp#L38), [`HttpGetFeatureSetEnvelope.cpp:65`](../mapguide/MgDev/Web/src/HttpHandler/HttpGetFeatureSetEnvelope.cpp#L65) | An HTTP operation that accepts a selection document and computes its envelope | it opens the map by `MAPNAME` from the session |
| `GETMAPIMAGE` with `MAPDEFINITION` | [`HttpGetMapImage.cpp:43`](../mapguide/MgDev/Web/src/HttpHandler/HttpGetMapImage.cpp#L43), [`HttpGetMapImage.cpp:101`](../mapguide/MgDev/Web/src/HttpHandler/HttpGetMapImage.cpp#L101) | An HTTP render path that already creates the map statelessly when no map name/session is given | no selection parameter; it renders "no selection" today |
| WMS `GetMap` | [`HttpWmsGetMap.cpp:212`](../mapguide/MgDev/Web/src/HttpHandler/HttpWmsGetMap.cpp#L212), session destroyed at [`HttpWmsGetMap.cpp:257`](../mapguide/MgDev/Web/src/HttpHandler/HttpWmsGetMap.cpp#L257) | The shipped template for "create a throwaway session, build the map from request parameters, render, destroy the session" | WMS has no selection |
| `SELECTION` parameter name | [`HttpResourceStrings.cpp:238`](../mapguide/MgDev/Web/src/HttpHandler/HttpResourceStrings.cpp#L238) | The name is reserved — and read by no handler | — |

Two facts from this table matter more than the rest:

- **The service layer is already stateless with respect to selection.** `MgOpRenderMap` receives the
  map object and the selection object in the same packet and reattaches them. Whatever is stateful
  lives in the web tier's decision to *read* the selection from `Session:<sid>//<map>.Selection`
  before calling the service.
- **`FEATUREFILTER` is a misnomer, not a feature gap.** It is parsed with
  `new MgSelection(map, featureFilter)`
  ([`ServerRenderingService.cpp:1491`](../mapguide/MgDev/Server/src/Services/Rendering/ServerRenderingService.cpp#L1491)),
  so `QUERYMAPFEATURES&FEATUREFILTER=<FeatureSet>` is already "query with a base selection". The
  OpenAPI file documents it as *"Attribute filter expression"*
  ([`openapi.yaml:3600`](./openapi.yaml)) — a documented-vs-code drift worth fixing in the same change.

---

## 2. Where the state actually is, and what it costs

### 2.1 The two resources

| Resource | Identifier | Written by |
|---|---|---|
| Map state | `Session:<sid>//<map>.Map` ([`Map.cpp:930`](../mapguide/MgDev/Common/MapGuideCommon/MapLayer/Map.cpp#L930)) | `MgMap::Save()` ([`Map.cpp:1028`](../mapguide/MgDev/Common/MapGuideCommon/MapLayer/Map.cpp#L1028)) |
| Selection | `Session:<sid>//<map>.Selection` ([`Selection.cpp:168`](../mapguide/MgDev/Common/MapGuideCommon/MapLayer/Selection.cpp#L168)) | `MgSelection::Save()` ([`Selection.cpp:139`](../mapguide/MgDev/Common/MapGuideCommon/MapLayer/Selection.cpp#L139)) |

`MgSelectionBase` derives from `MgResource` ([`SelectionBase.h:30`](../mapguide/MgDev/Common/PlatformBase/MapLayer/SelectionBase.h#L30)),
so "open" and "save" below are repository resource operations, not in-memory serialization.

Reading either requires a session id — `MgSelection::Open` throws `MgSessionExpiredException` when
the user information has none ([`Selection.cpp:121-137`](../mapguide/MgDev/Common/MapGuideCommon/MapLayer/Selection.cpp#L121)).

### 2.2 What one overlay request does today

`GETDYNAMICMAPOVERLAYIMAGE` goes through `MgHtmlController::GetDynamicMapOverlayImage`
([`HtmlController.cpp:41`](../mapguide/MgDev/Common/MapGuideCommon/Controller/HtmlController.cpp#L41)):

1. open the map from `Session:<sid>//<map>.Map` (`:48`),
2. open the selection from `Session:<sid>//<map>.Selection` (`:59-60`),
3. apply the `SETVIEW*`/`SETDISPLAY*`/`SHOW*` commands,
4. **save the map back** (`:69`), unconditionally,
5. render (`:75`).

So a render that changes nothing still costs a repository read of two resources and a **write** of
one, and the result is pinned to the server that owns the session ([assessment §4.3](./mapguide-load-balancing-assessment.md)).

The view itself is already per-request data — `SETVIEW*`/`SETDISPLAY*` are numbers carried on the
request and applied before rendering. That is why RFC 157 could turn them into creation-time
arguments. The selection is the one operand that is a *document* rather than a handful of numbers,
and it is the only reason the map resource has to be read at all.

### 2.3 Where the selection gets written

| Path | Write | Code |
|---|---|---|
| `QUERYMAPFEATURES&PERSIST=1` | selection | [`HtmlController.cpp:224-232`](../mapguide/MgDev/Common/MapGuideCommon/Controller/HtmlController.cpp#L224) (v1), `:293-297` (v2.6+) |
| `CREATERUNTIMEMAP` | selection **and** map | [`ServerMappingService.cpp:1535-1550`](../mapguide/MgDev/Server/src/Services/Mapping/ServerMappingService.cpp#L1535); the handler creates the session if the request has none ([`HttpCreateRuntimeMap.cpp:111-116`](../mapguide/MgDev/Web/src/HttpHandler/HttpCreateRuntimeMap.cpp#L111)) |
| `GETDYNAMICMAPOVERLAYIMAGE` | map only | `HtmlController.cpp:69` |

### 2.4 The client is already the authority

The 4.0 viewer (maplite, a separate repository from this one) keeps the selection in its own state
and re-sends it to the server to keep the session copy in step. An *append* is two
`QUERYMAPFEATURES` calls: a spatial pick, then a second call whose only purpose is to push the
client-merged document back via `FEATUREFILTER` with `PERSIST=1`. Against older servers it also has
to split the append into a first call that suppresses the attributes bit and a second call that adds
it back, because the server's attribute set would otherwise describe only the newly picked features.

That is the clearest evidence for the design direction: **the client already owns the selection; the
server copy is a mirror that has to be maintained with extra round-trips.** Removing the mirror
removes the round-trips, the `MgSessionExpiredException` on failover, and the per-session growth.

---

## 3. The one hard problem: what identifies a layer

### 3.1 Today's key

`MgSelectionBase::Add` keys the selection by `layer->GetObjectId()`
([`SelectionBase.cpp:743-764`](../mapguide/MgDev/Common/PlatformBase/MapLayer/SelectionBase.cpp#L743)),
and `GetLayers()` resolves by scanning the map's layers for a matching object id
([`SelectionBase.cpp:437-460`](../mapguide/MgDev/Common/PlatformBase/MapLayer/SelectionBase.cpp#L437)).

`GetObjectId()` returns `m_objectId` ([`LayerBase.cpp:121`](../mapguide/MgDev/Common/PlatformBase/MapLayer/LayerBase.cpp#L121)),
which is generated by `MgUtil::GenerateUuid` in the layer constructor
([`LayerBase.cpp:76`](../mapguide/MgDev/Common/PlatformBase/MapLayer/LayerBase.cpp#L76) and `:105`).
The map itself gets one too ([`Map.cpp:163`](../mapguide/MgDev/Common/MapGuideCommon/MapLayer/Map.cpp#L163)).

The id **is** serialized with the map (`Layer.cpp:160`, `:206`), so:

| The map comes from | Layer ids | Selection document stays valid? |
|---|---|---|
| `Session:<sid>//<map>.Map` (opened again) | the ids saved with the map | **Yes** — for as long as the session lives |
| `MgMap::Create()` from a MapDefinition | fresh UUIDs on every call | **No** |

### 3.2 The failure mode is silent

When no key matches, `GetLayers()` returns `NULL`, and `RenderSelection` guards with
`if (selLayers.p && selLayers->GetCount() > 0)`
([`ServerRenderingService.cpp:1903`](../mapguide/MgDev/Server/src/Services/Rendering/ServerRenderingService.cpp#L1903)).
The render succeeds and simply has no highlight. That is exactly the kind of failure that costs an
afternoon: a stateless client that posts a perfectly well-formed selection gets a correct-looking
image with the selection missing.

### 3.3 Why layer names work

- The runtime layer name comes from the **map definition**, not from the layer definition:
  `rtLayer->SetName(layer->GetName())`
  ([`Map.cpp:431`](../mapguide/MgDev/Common/MapGuideCommon/MapLayer/Map.cpp#L431), same for base
  layers at `:502`, `:754`).
- Duplicates are rejected at map creation. `m_layers->Add(rtLayer)`
  ([`Map.cpp:440`](../mapguide/MgDev/Common/MapGuideCommon/MapLayer/Map.cpp#L440)) goes through
  `MgNamedCollection::Add` → `CheckDuplicate`, which throws `MgDuplicateObjectException`
  ([`NamedCollection.cpp:487-503`](../mapguide/MgDev/Common/Foundation/Data/NamedCollection.cpp#L487) —
  `m_bCheckDuplicate` is `true` and `m_bAllowDuplicate` is `false` by default). A map definition with
  two identically-named layers cannot be turned into an `MgMap` at all, so **any map a client can
  render has unique layer names**. (`UnpackLayersAndGroups` turns the check off while *reading* a
  persisted map — [`Map.cpp:1158`](../mapguide/MgDev/Common/MapGuideCommon/MapLayer/Map.cpp#L1158) —
  which is safe because creation already validated them.)
- Names are already the stateless currency everywhere else:
  - `SHOWLAYERS`/`HIDELAYERS` accept names *or* ids, and the `MAPDEFINITION` path deliberately
    switches to names ([`Controller.cpp:337`](../mapguide/MgDev/Common/MapGuideCommon/Controller/Controller.cpp#L337),
    [`HttpGetMapImage.cpp:108`](../mapguide/MgDev/Web/src/HttpHandler/HttpGetMapImage.cpp#L108));
  - `LAYERNAMES` on `QUERYMAPFEATURES` is matched with `layerNames->IndexOf(layer->GetName())`
    ([`ServerRenderingService.cpp:1511`](../mapguide/MgDev/Server/src/Services/Rendering/ServerRenderingService.cpp#L1511));
  - the existing selection-as-filter path already correlates selection layers to map layers **by
    name** ([`ServerRenderingService.cpp:1540`](../mapguide/MgDev/Server/src/Services/Rendering/ServerRenderingService.cpp#L1540)),
    with a TODO admitting the linear search is a stopgap (`:1532-1534`).
- `MgLayerCollection::IndexOf(name)` already exists and is what `SHOWLAYERS` uses
  ([`LayerCollection.cpp:195`](../mapguide/MgDev/Common/PlatformBase/MapLayer/LayerCollection.cpp#L195)).

### 3.4 The options

| # | Key in the document | Cost | Verdict |
|---|---|---|---|
| **A** | `<Layer id="…" name="…">`, resolve **id first, name second** | ~40 lines in `SelectionBase.cpp` + the XSD doc | **Recommended.** Wire-compatible, no id semantics change, fixes the silent-null case |
| B | Make layer/group/map object ids deterministic (hash of map definition + layer name) | changes id generation for every map; needs a sweep of every `GetObjectId()` consumer | **Defer.** Worth doing later because it also makes `CREATERUNTIMEMAP`'s `<ObjectId>` values portable across servers and restarts, which names alone do not |
| C | Key on the layer definition resource id | two map layers may reference the same layer definition | Reject |
| D | Server-issued selection token (opaque id + server-side store) | reintroduces exactly the shared state we are removing; needs a store, eviction and affinity | Reject |

A note on B, because it looks tempting: object ids are also used by `SHOWLAYERS` by-id mode, the
runtime map description (`<ObjectId>` in [`ServerMappingService.cpp:1619`](../mapguide/MgDev/Server/src/Services/Mapping/ServerMappingService.cpp#L1619)),
KML/DWF layer ids and `RS_MapUIInfo`. Deterministic ids would make all of those portable, but they
would also make two *different* runtime maps of the same definition share ids inside one process —
which is fine for per-map lookups but needs an audit before it is claimed safe. Option A gets the
selection benefit without touching that surface.

---

## 4. The proposed API

Read this as a **set algebra with no mutable server-side operand**. The document is the operand and
the result; the server contributes only the operations it alone can perform (evaluate a spatial
query against FDO, render a highlighted image, read attributes, compute an envelope). Union,
difference and "is this feature in the set" are client-side string operations over `<ID>` values,
which is what the viewer already does.

### 4.1 The document

Keep the existing `FeatureSet` document and add one optional attribute:

```xml
<?xml version="1.0" encoding="UTF-8"?>
<FeatureSet xmlns:xsi="http://www.w3.org/2001/XMLSchema-instance"
            xsi:noNamespaceSchemaLocation="FeatureSet-1.0.0.xsd">
  <Layer id="0d0f0b3a-…-7f3c" name="Parcels">
    <Class id="Default:Parcels">
      <ID>AAECAwQ=</ID>
      <ID>AAECAwU=</ID>
    </Class>
  </Layer>
</FeatureSet>
```

Rules:

1. `<ID>` is unchanged: base64 of the packed identity-property values for the layer's class
   ([`AddFeatureIds`](../mapguide/MgDev/Common/PlatformBase/MapLayer/SelectionBase.cpp#L315),
   decoded in `GenerateFilters` at `:547`). The same string is what `QUERYMAPFEATURES` v4 returns as
   `<SelectionKey>` ([`HtmlController.cpp:760`](../mapguide/MgDev/Common/MapGuideCommon/Controller/HtmlController.cpp#L760)).
2. On **output**, `ToXml` writes `id` and `name`
   ([`SelectionBase.cpp:196`](../mapguide/MgDev/Common/PlatformBase/MapLayer/SelectionBase.cpp#L196)).
   The name is the one parsed from the document, or, when the selection was built in memory, looked
   up from the attached map. A selection with neither emits `id` only, which is today's behaviour.
3. On **input**, a `<Layer>` may carry `id`, `name`, or both. Resolution is: exact object id match
   → use it; otherwise unique name match → rewrite the key to that layer's object id; otherwise the
   layer is unresolved (see §4.5).
4. `Class@id` is the feature class name and is unchanged. The schema calls it *"a string identifying
   the feature class"*
   ([`FeatureSet-1.0.0.xsd`](../mapguide/MgDev/Common/Schema/FeatureSet-1.0.0.xsd)), so no schema
   break; only the `name` attribute needs adding (as `use="optional"`).
5. An empty `<FeatureSet/>` means *nothing selected* — not *use the session's selection*. That
   distinction is the whole point.

Resolution belongs where the map is known. `MgSelectionBase` already holds `m_map`
([`SelectionBase.h:641`](../mapguide/MgDev/Common/PlatformBase/MapLayer/SelectionBase.h#L641));
`SetMap` and the `(map, xml)` constructor are the two places it is set, and `FromXml` runs *after*
`m_map` is assigned in that constructor ([`SelectionBase.cpp:43-49`](../mapguide/MgDev/Common/PlatformBase/MapLayer/SelectionBase.cpp#L43)).
A private, non-virtual `ResolveLayers()` called from `FromXml` (when a map is present) and from
`SetMap` covers both. Keep a private `std::map<STRING, STRING> m_layerNames` (key → parsed name) so
an unresolved layer survives a round-trip and `ToXml` does not need a map to emit its name.

This is the one place the design adds a data member to a wide class. That is allowed here and only
here: MapGuide ships no C++ headers (the installer's `install_manifest.txt` contains no `.h` at all),
nothing links these classes, and the bindings are rebuilt from source, so the FDO-style ABI gate
does not apply — see [AGENTS.md § MapGuide API/ABI compatibility](../AGENTS.md#mapguide-apiabi-compatibility).
If the reviewer prefers no member at all, the alternative is to resolve names through `m_map` only:
correct for rendering, but it loses the name on any unresolved layer the client round-trips.

### 4.2 Operations

No new operations. Four existing ones gain parameters:

| Operation | New input | Behaviour when supplied | Session repository touched? |
|---|---|---|---|
| `QUERYMAPFEATURES` | `SELECTION` (and `MAPDEFINITION`) | The document is the **base** set; the query restricts it. The resulting document is returned in `<FeatureSet>`, as today | No (unless `PERSIST=1` **and** `MAPNAME` is given) |
| `GETMAPIMAGE` | `SELECTION` | Render with the supplied selection; requires `MAPDEFINITION` or `MAPNAME` | No in the `MAPDEFINITION` path |
| `GETDYNAMICMAPOVERLAYIMAGE` | `SELECTION`, `MAPDEFINITION` | Create the map from the definition, apply `SETVIEW*`/`SHOW*` **by name**, render the overlay | No |
| `GETFEATURESETENVELOPE` | `SELECTION` (alias of `FEATURESET`), `MAPDEFINITION` | Envelope of the supplied document | No |

`SELECTION` is the name already reserved in
[`HttpResourceStrings.cpp:238`](../mapguide/MgDev/Web/src/HttpHandler/HttpResourceStrings.cpp#L238) —
and read by no handler today, so there is no collision.

The obvious objection is *why not just tell clients to use `FEATUREFILTER`?* Three reasons:

1. It is documented as an attribute filter, so no client author will find the capability;
2. it exists on `QUERYMAPFEATURES` only — the two render operations have no equivalent at all;
3. the name has to stay free for Phase 4's real attribute-filter selection, so the two concepts need
   distinct names now rather than a rename later.

Implementation sketch for the overlay (the only one that needs a new map-creation branch), mirroring
the `GETMAPIMAGE` branch that already exists:

```c++
// session mode: unchanged
if (!m_mapName.empty() && !sessionId.empty())
{
    map->Open(resourceService, m_mapName);
    if (!m_selectionXml.empty())
        selection = new MgSelection(map, m_selectionXml);   // explicit wins
    else { selection = new MgSelection(map); selection->Open(resourceService, m_mapName); }
}
// stateless mode
else if (!m_mapDefinition.empty())
{
    Ptr<MgResourceIdentifier> resId = new MgResourceIdentifier(m_mapDefinition);
    map->Create(resourceService, resId, resId->GetName());
    ApplyMapViewCommands(map, commands, false);              // false = names, not ids
    if (!m_selectionXml.empty())
        selection = new MgSelection(map, m_selectionXml);
}
```

`ApplyMapViewCommands(..., false)` is the same flag `GETMAPIMAGE` already passes for its
`MAPDEFINITION` branch, and `MgMap::Create(MgResourceService*, …)` is `INTERNAL_API`
([`Map.h:651`](../mapguide/MgDev/Common/MapGuideCommon/MapLayer/Map.h#L651)) — fine for the web tier,
which is the handler's own build.

### 4.3 Semantics: restriction, not union

This is the part most likely to be got wrong, because the code already does something slightly
different from what the name suggests.

`RenderForSelection` treats the base document as a **pre-filter**
([`ServerRenderingService.cpp:1489-1492`](../mapguide/MgDev/Server/src/Services/Rendering/ServerRenderingService.cpp#L1489)).
For a layer named in the document it builds an FDO filter from the selected ids and uses it **in
place of** the layer definition's filter
([`ServerRenderingService.cpp:1628-1639`](../mapguide/MgDev/Server/src/Services/Rendering/ServerRenderingService.cpp#L1628)),
combined with the spatial filter when a geometry was supplied. The layer's own filter is therefore a
trust assumption: the base selection is expected to be a subset of it. So:

| Client intent | Request | Result |
|---|---|---|
| Pick features under a click/polygon, *replacing* the selection | `QUERYMAPFEATURES&GEOMETRY=…` (no `SELECTION`) | New set |
| Add to the current selection | The same, then merge the returned `<FeatureSet>` into the local one (client-side union) | Union |
| Remove from the selection | Client-side difference over `<ID>` values (`SelectionKey`s are comparable strings) | Difference |
| "Select all where …" | Not expressible at all — the document names features, not predicates. An attribute-driven selection needs a filter-based document (Phase 4) | — |
| Attributes / tooltips of the current selection | `QUERYMAPFEATURES&SELECTION=…&REQUESTDATA=1` (attributes bit) **with no `GEOMETRY`** | The reader walks every selected layer and returns all matching features (this path already works via `FEATUREFILTER`) |
| Highlight the current selection | `GETDYNAMICMAPOVERLAYIMAGE&SELECTION=…&BEHAVIOR=1` (selection only) | Image |

Server-side union (`SELECTIONMODE=ADD`) is deliberately **not** proposed for v1: the client already
merges documents and has to do so anyway for features picked offline. Adding it later is
backwards-compatible.

### 4.4 Precedence and compatibility

| Situation | Behaviour |
|---|---|
| `SELECTION` omitted | Today's behaviour, byte for byte — session selection for `MAPNAME`, none for `MAPDEFINITION` |
| `SELECTION` + `MAPNAME` | The document wins over the session selection; nothing is read from the repository |
| `SELECTION` + `PERSIST=1` + `MAPNAME` | Allowed: the resulting document is saved to the session (migration path for existing viewers) |
| `SELECTION` + `PERSIST=1` + no `MAPNAME` | Rejected with `MgInvalidArgumentException` — there is no map name to key the resource by |
| Document with `id` only (old client) | Works unchanged against the map it came from; unresolved against a fresh map (documented limitation) |
| Document with both, from another map instance | Resolved by name |
| Old *server* receiving a document with `name` | Ignores the attribute (it reads `id`), so it behaves exactly as today — no worse |
| Client validates documents against its own copy of `FeatureSet-1.0.0.xsd` | Needs the updated (optional-attribute) schema; parsers that do not validate are unaffected. The schema is installed at `server/Schema/FeatureSet-1.0.0.xsd`, so keep the 1.0.0 name rather than inventing 1.1.0 — the change is additive and a renamed schema would break the `xsi:noNamespaceSchemaLocation` every existing response already carries |

### 4.5 Errors and limits

Silent dropping is the current behaviour and the reason the problem is hard to diagnose. Proposed:

| Condition | Default | Strict mode (`SELECTIONSTRICT=1`) |
|---|---|---|
| Layer id/name not in the map | Keep the entry (so a client round-trip does not truncate the user's selection), skip it when resolving for render/query, log a warning naming the layer | `MgInvalidArgumentException` (`MgInvalidSelectionLayer`, new message key) |
| Class name not in the layer's class definition | Log; skip | throw |
| Document exceeds `[AgentProperties] MaxSelectionDocumentSize` (new setting, suggested default 4 MB) | reject | reject |
| More than `[AgentProperties] MaxSelectionIdsPerLayer` (new, suggested default 10,000) | reject | reject |
| Truncated/invalid base64 blob | reject | reject |

The default must stay lenient: a client-held selection outliving a map-definition edit should still
render the rest of the map, and the response must not quietly delete the layers it could not resolve
— the client is the owner of that state, so a round-trip has to be lossless for unresolved layers.
Strict mode exists for tests and for clients that would rather fail than show an incomplete
selection.

### 4.6 Security requirements (P0)

The current code assumes selection documents come from the server. Once they come from the caller,
four things become attack surface: two in the parser, one in the query it feeds, and one in the
request size. None of them is hypothetical for this design.

1. **FDO string literals are not escaped.**
   [`SelectionBase.cpp:630-637`](../mapguide/MgDev/Common/PlatformBase/MapLayer/SelectionBase.cpp#L630)
   builds `prop='<value>'` by concatenating the decoded string. A layer whose identity property is a
   `String` lets a crafted `<ID>` inject filter syntax (for example a value containing `' OR …`).
   Fix: apply the FDO filter grammar's own escaping (double the quote) when emitting the literal, and
   add a round-trip test with a quote in the identity value. This is a latent correctness bug too —
   an identity value containing `'` is unselectable today.
2. **Blobs are decoded without bounds checks.**
   `MgMemoryStreamHelper::FromBase64` decodes whatever it is given
   ([`MemoryStreamHelper.cpp:386-407`](../mapguide/MgDev/Common/Foundation/System/MemoryStreamHelper.cpp#L386)),
   then `GenerateFilters` reads typed values with the status of each read ignored. A short blob makes
   the string reader scan for a NUL past what was written
   (`GetNullTermString` at [`MemoryStreamHelper.cpp:192-211`](../mapguide/MgDev/Common/Foundation/System/MemoryStreamHelper.cpp#L192)
   uses `strchr` over a fixed 1024-byte stack buffer). Fix: a bounds-checked reader that walks the
   blob per the layer's `IdPropertyList`
   ([`Layer.cpp:438`](../mapguide/MgDev/Common/MapGuideCommon/MapLayer/Layer.cpp#L438)) and rejects
   anything with trailing or missing bytes.
3. **The base selection replaces the layer's own filter.** §4.3's `SetFilter` call discards
   `LayerDefinition/Filter` for any layer the document names, so an id that exists in the feature
   source but is excluded by the layer definition would be selected and highlighted. Combine the two
   filters (`(layer) AND (selection)`) instead of replacing one with the other. This changes
   existing behaviour only for clients that relied on the replacement, which is the current
   `FEATUREFILTER` path — check the viewer flows before changing it.
4. **Size and count are unbounded.** `MAXPOSTSIZE` is 1 GB
   ([`CgiPostParser.cpp:29`](../mapguide/MgDev/Web/src/CgiAgent/CgiPostParser.cpp#L29)), `<ID>` elements are
   unlimited, and each one becomes a serialized query. Cap the document size and the per-layer count.

Also required by this change, and small:

- **`FromXml` leaks on three paths.** An empty `<Class>` leaks its `SelectionList`
  ([`SelectionBase.cpp:104-183`](../mapguide/MgDev/Common/PlatformBase/MapLayer/SelectionBase.cpp#L104) —
  `new SelectionList()` is only handed over when non-empty); a duplicated `<Class>` inside one
  `<Layer>` leaks the earlier list because `Add(layerId, className, idList)` overwrites
  ([`SelectionBase.cpp:766`](../mapguide/MgDev/Common/PlatformBase/MapLayer/SelectionBase.cpp#L766));
  and an exception mid-parse leaks the list in flight. Use a `std::unique_ptr` and release it into
  the map only on hand-over. These are pre-existing, but accepting client input makes them reachable
  at will.
- **The TODO in `FromXml` is this feature.** *"Validate that data is legal by parsing each selection
  string. MgMap will be required to do this."*
  ([`SelectionBase.cpp:108-110`](../mapguide/MgDev/Common/PlatformBase/MapLayer/SelectionBase.cpp#L108))
  Names in the document are only safe because they are resolved against the map, never trusted.

---

## 5. Worked flows

### 5.1 Create once, render anywhere

```
CREATERUNTIMEMAP&MAPDEFINITION=Library://…/Sheboygan.MapDefinition&TARGETMAPNAME=Sheboygan
    → runtime map description; keep each <Layer><Name> (and <ObjectId>)
```

The description is the client's map state. Rendering it needs no session map:

```
GETMAPIMAGE&VERSION=3.0.0&MAPDEFINITION=Library://…/Sheboygan.MapDefinition&FORMAT=PNG
    &SETVIEWCENTERX=-87.723&SETVIEWCENTERY=43.753&SETVIEWSCALE=5581
    &SETDISPLAYWIDTH=750&SETDISPLAYHEIGHT=975&SETDISPLAYDPI=96
    &SHOWLAYERS=Parcels,Roads
    &SELECTION=<FeatureSet with name="Parcels">…
```

Every parameter here is already accepted except `SELECTION`. The map is created, the view commands
are applied by name, and the selection resolves by name.

The cost is a per-request `MgMap` creation: a map-definition parse plus layer-definition lookups,
served from the per-process resource cache rather than from a session resource. That is the trade
this design makes — CPU and XML parsing on every call, in exchange for no repository read or
write and no session affinity. Measure it on the Sheboygan sample before making the stateless path
the viewer's default; the stateful path is not free either (it writes the map on every overlay).

### 5.2 Pick, append, remove

```
QUERYMAPFEATURES&MAPDEFINITION=…&GEOMETRY=POLYGON((…))&SELECTIONVARIANT=INTERSECTS
    &REQUESTDATA=1&FORMAT=application/json
    &SELECTION=<current FeatureSet>              # omitted for a replacing pick
```

→ response contains the new `<FeatureSet>`. Append = union the ids client-side and keep the result;
remove = difference. No `PERSIST`, no second call, no session state.

A pick on a dense layer can produce a document well past a URL's length limit, which is why the
parameter has to be usable from a body: an `application/x-www-form-urlencoded` POST is parsed into
the same parameter set as the query string by the CGI, ISAPI and Apache agents, so the same request
works either way.

### 5.3 Attributes for the current selection

```
QUERYMAPFEATURES&MAPDEFINITION=…&SELECTIONVARIANT=INTERSECTS&REQUESTDATA=1
    &SELECTION=<current FeatureSet>              # no GEOMETRY
```

The server returns the property values and the v4 `<SelectionKey>` for each feature — this is the
existing `FEATUREFILTER` path with an honest name, and it is what makes the viewer's
"append with attributes" workaround unnecessary.

### 5.4 Failover and several servers

Because no repository resource is involved, a request may land on any server that can read the map
definition and the feature source:

- no session id → the web tier's round-robin picks any server ([assessment §1.3](./mapguide-load-balancing-assessment.md));
- a session id, if used for authentication only, still pins the request ([§4.3](./mapguide-load-balancing-assessment.md)) — so the stateless endpoints are better used with Basic auth or an anonymous session;
- losing a server no longer loses the selection.

The data side is the remaining requirement, and it is exactly what
[assessment §9.5](./mapguide-load-balancing-assessment.md) sets up: the same physical feature data
behind every instance. Identity blobs are provider-generated; two instances reading different copies
of an SDF file have different implicit ids, so a selection is only as portable as the data is shared.

---

## 6. Implementation map

### Phase 0 — decisions (this document)

Pick option A. Confirm the `SELECTION` name and the strict/lenient policy. Nothing to build.

### Phase 1 — make the document portable (C++, no wire change)

| File | Change |
|---|---|
| [`SelectionBase.cpp`](../mapguide/MgDev/Common/PlatformBase/MapLayer/SelectionBase.cpp) | `ToXml`: emit `name`. `FromXml`: read and retain `name`. New private `ResolveLayers()`, called from `FromXml` (when `m_map` is set) and `SetMap`. Merge duplicate keys instead of overwriting. Clear `m_layerNames` in `ClearSelections` and `Deserialize`. `unique_ptr` ownership for `SelectionList` |
| [`SelectionBase.h`](../mapguide/MgDev/Common/PlatformBase/MapLayer/SelectionBase.h) | one private non-virtual declaration and the private `m_layerNames` member |
| [`FeatureSet-1.0.0.xsd`](../mapguide/MgDev/Common/Schema/FeatureSet-1.0.0.xsd) | optional `name` attribute on `Layer` |
| [`TestRenderingService.cpp`](../mapguide/MgDev/Server/src/UnitTesting/TestRenderingService.cpp) | new `TEST_CASE("StatelessSelectionRoundTrip", "[RenderingService]")`: build a map from a MapDefinition, make a selection, `ToXml`, create a **second** map from the same definition, `MgSelection(map2, xml)`, assert `GetLayers()` is non-null and `GetSelectedFeaturesCount()` matches |

Acceptance: the existing `RenderMapWithSelectionPNG`/`PNG8` cases
([`TestRenderingService.cpp:1550`](../mapguide/MgDev/Server/src/UnitTesting/TestRenderingService.cpp#L1550))
still pass, and the new case proves the document survives a map re-creation.

### Phase 2 — the HTTP surface

| File | Change |
|---|---|
| [`HttpQueryMapFeatures.cpp`](../mapguide/MgDev/Web/src/HttpHandler/HttpQueryMapFeatures.cpp) | read `SELECTION`; pass it as the base selection; `MAPDEFINITION` alternative |
| [`HtmlController.cpp`](../mapguide/MgDev/Common/MapGuideCommon/Controller/HtmlController.cpp) | overloads that take `(map, inputSelectionXml, commands)`; skip `persist` in stateless mode; stop calling `selection->Open` when a document was supplied |
| [`HttpGetMapImage.cpp`](../mapguide/MgDev/Web/src/HttpHandler/HttpGetMapImage.cpp) | `SELECTION` on both branches |
| [`HttpGetDynamicMapOverlayImage.cpp`](../mapguide/MgDev/Web/src/HttpHandler/HttpGetDynamicMapOverlayImage.cpp) | `SELECTION`, `MAPDEFINITION`, name-mode commands, no `map->Save` in stateless mode |
| [`HttpGetFeatureSetEnvelope.cpp`](../mapguide/MgDev/Web/src/HttpHandler/HttpGetFeatureSetEnvelope.cpp) | `SELECTION` alias, `MAPDEFINITION` alternative |
| [`openapi.yaml`](./openapi.yaml) | document `SELECTION` on all four; fix `FEATUREFILTER`'s description (it is selection XML); add the missing `MAPNAME` to `GETFEATURESETENVELOPE`; note POST for large documents |
| [`map_interaction_api.http`](../test/map_interaction_api.http#L96) | stateless variants of the pick/overlay/attributes flows, and one request with a document produced by a *previous* response |

Acceptance: a client can run §5.1–§5.3 with no `SESSION` parameter and no repository write
(verify by checking the session repository directory before/after).

### Phase 3 — hardening (precondition for exposing Phase 2 publicly)

The four items in [§4.6](#46-security-requirements-p0), each with a unit test: quote-in-identity
round trip, truncated-blob rejection, layer-filter intersection, size/count caps. Reuse `MgInvalidArgumentException` with new
message keys in [`mapguide_en.res`](../mapguide/MgDev/Common/MapGuideCommon/Resources/mapguide_en.res)
rather than adding exception codes.

### Phase 4 — optional, only if a client needs it

- Deterministic object ids (option B) — unlocks portable runtime map descriptions.
- Filter-based selection documents (`<Filter>` per layer/class) — "select by attribute expression"
  without a geometry, compact for large sets, and re-evaluated server-side. It reuses the same
  rendering path, which only ever needs a filter (`GenerateFilters`,
  [`SelectionBase.cpp:522`](../mapguide/MgDev/Common/PlatformBase/MapLayer/SelectionBase.cpp#L522)).
- `SELECTIONMODE=ADD` server-side union.
- JSON selection documents (the response converter already exists for XML responses).

---

## 7. Rejected or deferred designs

| Design | Why not |
|---|---|
| **Server-issued selection token** in a shared cache | Reintroduces state, eviction, affinity and a new subsystem — the problem, not the solution |
| **Selection as a `Library://` resource** | Shareable and durable, but the library repository is single-opener and not the place for per-interaction state ([assessment §6.1](./mapguide-load-balancing-assessment.md)); also an authoring-like write per pick |
| **A new `SelectionSet` schema/class** | Duplicates semantics the `FeatureSet` XML already has, and every existing consumer (`GETFEATURESETENVELOPE`, `FEATUREFILTER`, `MgFeatureInformation`) would need a second parser |
| **Raw FDO filter text from the client** | Useful (Phase 4, and via the existing `SelectFeatures` API anyway) but it is a different, larger trust boundary; ids-only keeps v1 narrow |
| **Make `MgMap` hold its own selection** | Pushes the client's state into the server object and rebuilds the coupling we are removing; it also does nothing for a client that holds map state itself |
| **Deterministic ids now** | Correct direction, but it changes every object id in the system for a benefit names already deliver for selections; see §3.4 |

---

## 8. Verification plan

1. **Unit (Catch2, in-process).**
   `./mgserver test RenderingService UnitTestResults_RenderingService.xml` from
   `Server/src/Core` in the baseline container — `RenderingService` is in the suite list at
   [`run_mapguide_tests.sh:59`](../templates/scripts/container/run_mapguide_tests.sh#L59). The new
   round-trip case and the existing `RenderMapWithSelectionPNG*` cases must pass in **both** Release
   and Debug (Debug is ASan, so the `FromXml` leak fixes are visible there).
2. **HTTP.** Extend [`test/map_interaction_api.http`](../test/map_interaction_api.http) and run
   `npx httpyac map_interaction_api.http --all --bail --output headers` against a
   `mapguide_image_install.sh` deployment. Assertions that actually distinguish stateless from
   session behaviour:
   - a pick + overlay with no `SESSION` returns a non-empty selection;
   - the same document renders against a *second* server in the assessment's §9.5 stack and produces
     an image with the same selection colour;
   - a document with a renamed layer still renders the rest of the selection (lenient) and throws in
     strict mode;
   - a quote-containing string identity round-trips.
3. **No regression.** Every existing `.http` flow that uses `PERSIST=1` and `MAPNAME`
   ([`map_interaction_api.http:96-140`](../test/map_interaction_api.http#L96)) must be unchanged.
4. **Surface.** `Bindings/src/ApiDump/api.java.txt`, `api.dotnet.txt`, `api.php.txt` should diff
   clean — no binding signature changes are required by this design. If Phase 1 adds an internal
   helper or the `m_layerNames` member to `MgSelectionBase`, confirm both are private (IMake only
   emits `PUBLISHED_API`/`EXTERNAL_API`, so neither can reach a generated proxy).
5. **Repository writes.** Before/after listing of the session repository for a stateless run; it
   must not contain a `.Map` or `.Selection`.
6. **Security probes.** Truncated blob, no-NUL 1024-byte blob, quote in a string id, 100k `<ID>`
   elements, 50 MB document.

---

## 9. Open questions

1. **Name vs deterministic id.** Names solve selection portability; deterministic ids would *also*
   make the runtime map description and `SHOWLAYERS`-by-id portable. Is that worth the id sweep in
   the next cycle, or is name-based enough for the 4.0 viewer?
2. **Strict by default?** A renamed layer silently disappearing from a client-held selection is the
   same class of bug this document set out to remove. Consider strict by default for `MAPDEFINITION`
   requests and lenient for `MAPNAME`.
3. **New operations instead of parameters?** A `QUERYSELECTION`/`RENDERSELECTION` pair would be
   cleaner to document and to version, at the cost of two more operation names and registrations.
   The parameter route reuses the `SELECTION` constant that already exists.
4. **Version gating.** These are additive parameters on existing versions. Should they be restated
   as `VERSION=4.1.0`, or documented as available from 4.0.0? The MapGuide precedence is to add
   parameters without a version bump; confirm.
5. **`PERSIST` interaction.** Rejecting `PERSIST=1` without `MAPNAME` is the strict reading; keeping
   it as a silent no-op is friendlier to a client migrating from the old flow.
6. **Client work.** The viewer's double-`QUERYMAPFEATURES` append workaround and its session-keyed
   `localStorage` entry can both go, but that is a separate change in the client project.

---

## 10. Key references

| Topic | Where |
|---|---|
| RFC 157 (map creation with display parameters; `SetMap` addendum) | <https://trac.osgeo.org/mapguide/wiki/MapGuideRfc157> |
| Selection document schema | [`Common/Schema/FeatureSet-1.0.0.xsd`](../mapguide/MgDev/Common/Schema/FeatureSet-1.0.0.xsd) |
| Selection serialization and filter generation | [`SelectionBase.cpp`](../mapguide/MgDev/Common/PlatformBase/MapLayer/SelectionBase.cpp) |
| Session-backed selection | [`Selection.cpp`](../mapguide/MgDev/Common/MapGuideCommon/MapLayer/Selection.cpp) |
| Map state and session resource id | [`Map.cpp`](../mapguide/MgDev/Common/MapGuideCommon/MapLayer/Map.cpp) |
| Selection rendering and the selection-as-filter query | [`ServerRenderingService.cpp`](../mapguide/MgDev/Server/src/Services/Rendering/ServerRenderingService.cpp) |
| Map + selection over the wire | [`OpRenderMap.cpp`](../mapguide/MgDev/Server/src/Services/Rendering/OpRenderMap.cpp) |
| Web tier controllers | [`HtmlController.cpp`](../mapguide/MgDev/Common/MapGuideCommon/Controller/HtmlController.cpp) |
| Existing stateless render precedent (WMS) | [`HttpWmsGetMap.cpp`](../mapguide/MgDev/Web/src/HttpHandler/HttpWmsGetMap.cpp), [`WmsMapUtil.cpp`](../mapguide/MgDev/Web/src/HttpHandler/WmsMapUtil.cpp) |
| Runtime map creation (session-persisted today) | [`ServerMappingService.cpp`](../mapguide/MgDev/Server/src/Services/Mapping/ServerMappingService.cpp) |
| HTTP contract | [`openapi.yaml`](./openapi.yaml) |
| Load-balancing context | [mapguide-load-balancing-assessment.md](./mapguide-load-balancing-assessment.md) |

---

## 11. Notes / clean-up

- Nothing was modified to write this document; there are no temporary files to remove.
- The work spans two histories. Phase 1 and Phase 3 touch `Common/**`, `Server/**` and `Web/**`, which
  are SVN and are committed by the user from the working copy; Phase 2's `docs/openapi.yaml` and
  `test/*.http` changes are git and belong in a separate commit. Do not describe both in one message
  ([AGENTS.md § Commit messages](../AGENTS.md#commit-messages-one-scope-per-repository)).
- The API/ABI gate was read as `freeze`; the design needs no binding-visible change, so the gate is
  satisfied by the ApiDump check in §8 rather than by a revision-range audit.
