# Known mapagent issues to fix

# ENUMERATEREPOSITORIES

`ENUMERATEREPOSITORIES` has no entry in the mapagent's dispatch table:
`MgHttpRequest::InitializeStaticData()` never registers `MgHttpEnumerateRepositories`, so the
operation is unknown to the agent even though the handler class exists
(`Web/src/HttpHandler/HttpEnumerateRepositories.cpp`, listed in `HttpHandler.vcxproj` but not in the
web tier `CMakeLists.txt`).

Until r10219 this segfaulted the mapagent. The NULL-creator guard in
`MgHttpRequest::CreateRequestResponseHandler` allocated the exception with a bare `new` instead of
`throw new`, then fell through to `(*createFunc)(this)` and called a NULL function pointer. Apache
logged `child pid N exit signal Segmentation fault (11)`, the client saw an empty reply, and the
request produced no MapGuide log entry because the operation never ran. r10219 added the `throw`, so
the operation now returns `559 MgInvalidOperationException`.

It is no longer documented in the OpenAPI spec (`Web/src/openapi/openapi.yaml`): the mapagent does
not advertise the operation, so the spec should not either -- a generated client method that can
only ever return `559` is worse than no method at all. That leaves the product-side choice:

- Register the operation (add
  `httpClassCreators[opEnumerateRepositories] = MgHttpEnumerateRepositories::CreateObject;` and list
  `HttpEnumerateRepositories.cpp` in the CMake build), or delete the handler class and the
  `opEnumerateRepositories` string. Until one of those happens the class is dead code.
- Nothing tests it: it is out of the OpenAPI spec and out of the web tier runner. If it is ever
  registered, add the spec entry back and a test that exercises it.
