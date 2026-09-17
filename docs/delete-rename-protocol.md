# Studio delete, rename, and concurrency protocol

Observed behavior of the Studio routes that remove a file, and of the
concurrency and revision-identity controls around them. These are undocumented
implementation details captured from a disposable project and may change
without notice.

This document is **evidence only**. Nothing in the product calls a delete:
`game-studio-sync.ps1` remains GET-only, and `Push`/`Apply` do not exist. The
purpose of the record is to constrain the design of
[#17](https://github.com/iNcredibleGM/rundot-game-studio-sync/issues/17), not to
permit a mutation. `deleteRemoteCandidate` stays classification-only.

Read paths are in [protocol.md](protocol.md). The text write route is
[text-write-protocol.md](text-write-protocol.md) and the binary upload flow is
[binary-upload-protocol.md](binary-upload-protocol.md); this document covers
the delete verb, rename, and the concurrency controls.

## Endpoint

```text
DELETE /api/projects/{projectId}/file?path={encodedPath}
```

No request body. `path` is percent-encoded and must be absolute, exactly as on
the read and write routes.

A successful delete returns `200` with the path it removed:

```json
{ "success": true, "data": { "deleted": "/uploads/probe.txt" } }
```

`Content-Type: application/json`. This is the same `/file` route that serves
`GET` and `PUT`, so the verb is the whole difference.

### The status is not the proof

`200` means the server accepted the request. The proof that the file is gone is
that the path disappears from `GET /files` and `GET /file` stops returning it.
Every case below was checked that way, and the probe never treats a status as
the finding.

## Delete semantics

### It deletes exactly the named file

Deleting one path left an unrelated sibling byte-for-byte intact, and the
sibling remained listed. There is no directory sweep and no globbing:

| Case | Result |
| --- | --- |
| Target `/uploads/probe-…-del-basic.txt` | `200`, removed |
| Bystander `/uploads/probe-…-del-bystander.txt` | still listed, unchanged |

### Idempotency: the effect is idempotent, the status is not

| Attempt | Status | Body | File listed after |
| --- | --- | --- | --- |
| First `DELETE` on an existing file | `200` | `{"success":true,"data":{"deleted":"…"}}` | no |
| Second `DELETE` on the same path | `404` | `not found` | no |
| `DELETE` on a path that never existed | `404` | `not found` | no |

The second attempt is **not** an error state that a caller has to distinguish
from the first: in both cases the postcondition is the same, and the file is
absent. A `404` after a `200` therefore means "already gone", not "the delete
failed". This is what makes a retry after an ambiguous failure safe — a retry
cannot destroy something else, because the verb only ever addresses the one
named path.

Note the body shape changes with the outcome: success is JSON, `404` is
`text/plain;charset=UTF-8` with the literal text `not found`. A client parsing
the response must not assume JSON on every status.

### A directory-shaped path is not a file

| Case | Status | Body | Child/bystander |
| --- | --- | --- | --- |
| `DELETE` a directory-shaped path | `404` | `not found` | survived |

A directory-shaped path returns the same `404` as any absent path. **No
recursion was observed and no directory was created or removed.** A client
cannot use this verb to remove a folder, and must not read the `404` as
"forbidden".

### Reserved paths have no distinct guard

| Path | Status | Body |
| --- | --- | --- |
| `/.git/probe-….txt` | `404` | `not found` |
| `/.rundot/probe-….txt` | `404` | `not found` |

These are the same `404` an absent path returns. As on the write route
([text-write-protocol.md](text-write-protocol.md)), **no server-side
reserved-path guard was observed** — the paths simply did not exist. A client
must enforce its own reserved-path rules and must not treat a `404` here as
protection. The local safety layer already does this
([path-safety.md](path-safety.md)); on delete it is load-bearing rather than
defense-in-depth, because the consequence of a mistake is a lost file.

### Path encoding follows the read and write rules

| `path` sent | Status | Body |
| --- | --- | --- |
| relative (`relative-probe.txt`) | `400` | `path must be an absolute project path` |
| escaped traversal (`/%2e%2e/escaped.txt`) | `400` | `path must be an absolute project path` |
| percent-encoded space in the name | `200` | the real file was removed |

The absolute-path rule and the `400` body text are identical to the write
route's. A correctly encoded space addressed the real file and removed it,
which confirms the encoder is required rather than optional.

### Authentication

| Request | Status | Body |
| --- | --- | --- |
| No `Authorization` header | `401` | `unauthorized` |
| Garbage bearer token | `401` | `unauthorized` |

Neither unauthenticated attempt removed anything: the target was still listed
afterwards and was then removed by an authenticated delete. Both failures are
the same `401` the other mutating routes return.

## Rename / move

**No rename route was found.** Five plausible shapes were tried against a
freshly created probe-owned file each time, and every one failed without moving
anything:

| Attempt | Status | Body | Old path gone | New path present |
| --- | --- | --- | --- | --- |
| `PATCH /file?path=…` with `newPath` | `405` | `method not allowed` | no | no |
| `POST /file/rename` with `path` + `newPath` | `404` | `not found` | no | no |
| `POST /file/move` with `path` + `newPath` | `404` | `not found` | no | no |
| `POST /files/rename` with `from` + `to` | `404` | `not found` | no | no |
| `PUT /file?path=…` with only `newPath` | `400` | `{"success":false,"error":{"message":"content must be a string","code":"VALIDATION_ERROR","field":"content"}}` | no | no |

Two of these are informative beyond the failure:

- `PATCH` returns `405`, which means the route exists but does not accept that
  verb. The `/file` route is `GET`/`PUT`/`DELETE` only.
- The `PUT` case is the most telling. The body carried `newPath`, and the
  server rejected it with "content must be a string" — it looked for `content`
  and **ignored `newPath` entirely**. There is no rename shape on the write
  route.

### A rename can only compose as delete + create, and create is unsolved

Because no server-side move exists, a rename has to be expressed as
delete-the-old-path plus create-the-new-path. The create half is the problem:

- `PUT /file` **cannot create** a file. A path that is not already in the
  project returns `404`, and `POST` on the same route is `405`
  ([text-write-protocol.md](text-write-protocol.md)).
- The binary upload flow can create a file, but it **cannot choose the path** —
  the requested path is ignored and the file always lands at
  `/uploads/{basename}` ([binary-upload-protocol.md](binary-upload-protocol.md)).

So for any path outside `/uploads/{basename}`, a rename is not expressible at
all today. `Push` must treat a local rename as a delete candidate plus an
upload that it cannot serve, rather than silently performing half of it.

**The route is not proven absent, only unfound.** A real rename performed in
the Studio UI would settle it, and the probe supports capturing one from the
DevTools Network panel (`rename-devtools-prepare` / `rename-devtools-apply`).
That capture is the outstanding step for this section; until it exists, treat
"Studio has no rename API" as strongly suggested but not established.

## Revision identity

A `GET /files` row for a text file exposes **only three fields**, before and
after a write:

```json
{ "path": "/uploads/probe-….txt", "type": "file", "size": 26 }
```

| Observation | Result |
| --- | --- |
| Fields after create | `path`, `type`, `size` |
| Fields after overwrite | `path`, `type`, `size` (size changed) |
| Fields after delete | row absent |
| Any `etag`/`hash`/`sha256`/`contentHash`/`version`/`revision`/`id`/`updatedAt` | **none** |

There is no server-side revision counter, no content hash, and no
`updatedAt`. The identity vocabulary is path and size only, exactly as #14 and
#15 found on the other two routes. A client that wants to know whether content
changed must fetch the file and hash it itself.

## ETag and conditional requests

### No identity headers on any response

Response headers were recorded for `GET /file`, `GET /files`, `PUT /file`, and
`DELETE /file`. Every one returned only `Content-Type` and `Content-Length`:

| Request | Headers observed |
| --- | --- |
| `GET /file` | `Content-Type`, `Content-Length` |
| `GET /files` | `Content-Type`, `Content-Length` |
| `PUT /file` | `Content-Type`, `Content-Length` |
| `DELETE /file` | `Content-Type`, `Content-Length` |

No `ETag`, no `Last-Modified`, no `Vary` that would imply a cached identity.
There is nothing to condition on.

### Preconditions are ignored on DELETE

| Request | Status | File after |
| --- | --- | --- |
| `If-Match: "definitely-not-the-current-etag"` | `200` | **deleted** |
| `If-Match: not-an-etag` (malformed) | `200` | **deleted** |
| `If-None-Match: *` on an existing file | `200` | **deleted** |

A `412` would have meant the header is enforced. Every attempt returned `200`
and removed the file, including a syntactically invalid value. This matches
#14's finding on `PUT`: the server implements no preconditions on this route
family, on either the write verb or the delete verb.

**Consequence:** a delete cannot be made conditional. There is no way for a
client to tell the server "remove this only if it is still the file I saw".
Any guard has to be built entirely on the client, immediately before the
request.

## Concurrency

### A stale write over a deleted file fails safely

This is the case that matters most for `Push`, and it is the good news.

The sequence: read a file's bytes, delete the file remotely, then send the
bytes read before the delete through `PUT`.

| Step | Result |
| --- | --- |
| `DELETE` the target | `200`, file gone from `GET /files` |
| `PUT` the stale bytes | **`404 not found`** |
| File listed after the `PUT` | no |
| Resurrected | **no** |

The stale write did **not** re-create the file. It failed with `404`, which is
the same response `PUT` gives for any path that does not exist — consistent
with #14's finding that the write route is overwrite-only.

This is a genuinely different outcome from the concurrent-*edit* case in
[text-write-protocol.md](text-write-protocol.md), where a stale `PUT` over a
file that still existed silently clobbered a human edit with no error at all.
Put together, the two observations say:

- A stale write against a path that **still exists** is silently accepted and
  destroys whatever was there. The server cannot detect it.
- A stale write against a path that has been **deleted** is refused with `404`.
  The delete happens to make the write safe.

So a deletion race is self-protecting, but an edit race is not. `Push` still
needs its own client-side re-verification for the edit case; it does not need
to fear a delete race producing a silent undelete.

### A captured list is invalidated by a delete, and the client can see it

The plan artifact records `remoteManifestHashBefore`/`After` so a future
`Apply` can re-check ([plan.md](plan.md)). That check was exercised directly:
fingerprint `GET /files`, delete a listed path, fingerprint again.

| Step | Result |
| --- | --- |
| Path listed before | yes |
| `DELETE` | `200` |
| Path listed after | no |
| Manifest fingerprint before | `c606e1cd444ab582868f004931e6fa950ba454d7773426463a45304a1c0cf6f7` |
| Manifest fingerprint after | `246ed8053d3bb098126bbfa87c44542daf0fe370c97468ef3d587e29584f0b1f` |
| Fingerprint changed | **yes** |

The fingerprint moves when a path disappears, so the client-side
re-verification the plan promises is sound for deletions: a delete between plan
and apply is detectable without any server-side support. The unprotected window
between the check and the mutation is unchanged, and cannot be closed by this
protocol.

## Failure, retry, and idempotency

| Question | Answer from evidence |
| --- | --- |
| Does `DELETE` remove exactly the named path? | Yes. No recursion, no globbing, siblings untouched. |
| Is a repeated `DELETE` safe? | Yes in effect. `200` then `404`, and the postcondition is identical. |
| Does a `404` mean the delete failed? | No. It means the path is already absent. |
| Can a delete be conditional? | No. No ETag, no version, `If-Match`/`If-None-Match` ignored. |
| Can a delete be detected as stale? | Not server-side. Client-side, by re-fingerprinting `GET /files`. |
| Does it remove a directory? | No. A directory-shaped path returns the same `404` as absent. |
| Are reserved paths protected server-side? | No guard observed. The client must enforce its own. |
| Does it echo what it removed? | Yes, `{"success":true,"data":{"deleted":"<path>"}}` on success. |
| What refuses a delete? | `400` non-absolute path, `401` auth, `404` absent path. |
| Does a failed delete damage anything? | No. Every rejection left the file in place. |
| Is a rename possible? | **No route found.** Delete + create, and create is unsolved. |
| Is there any revision identity? | No. `path`, `type`, `size` only. |
| Does a stale write over a deleted file resurrect it? | **No.** It returns `404`. |

## Summary for `Push` design

The three constraints that matter:

1. **A delete is unguarded and unversioned.** Nothing server-side prevents
   deleting a file that changed since the plan was made. Any safety has to be
   client-side, and the plan's `expectedRemoteHash` cannot be sent to the
   server for enforcement — it can only be compared locally just before the
   request.

2. **A delete is retry-safe, and a delete race cannot cause a silent
   undelete.** A `404` after an ambiguous failure means the postcondition
   already holds, and a stale write against a deleted path is refused. This is
   the opposite of the write case, and it means `Push` may retry a delete
   without risking a duplicate or a resurrection.

3. **A rename is not expressible.** With no move route, a rename is a delete
   plus a create, and create is unsolved for any path outside
   `/uploads/{basename}`. `Push` must refuse a rename it cannot express rather
   than performing the delete half and stranding the content.

For [#17](https://github.com/iNcredibleGM/rundot-game-studio-sync/issues/17)
this means a `deleteRemoteCandidate` row could in principle be applied with a
client-side re-fingerprint immediately before the `DELETE`, plus a backup of
the bytes being removed — but only once the milestone permits remote mutation.
Nothing in this evidence authorizes emitting a standing `DELETE` today.

## How this was observed

Every case ran through `tools/StudioProbe.ps1`, the opt-in probe committed for
these investigations, against a disposable Studio project only. The probe
refuses to send anything without `-ConfirmRemoteWrite`.

A full `run-delete-rename-all` pass recorded 61 evidence cases with no errors
and no aborted steps. Every destructive case created its own probe-owned target
through the binary upload flow, because the text route cannot create a file,
and every target carried a per-run stamp so cleanup was exact. The run ended by
deleting what it had created and verifying none of it remained: 4 paths were
left at survey time and 4 of 4 were deleted, with 0 remaining.

Two safeguards made the delete cases safe to run:

- A delete may only target a path the probe owns: `/sync-probe`, a run-stamped
  `/uploads` path, or a run-stamped reserved-shaped path. A bare directory is
  never eligible, because binary uploads flatten into `/uploads` and a
  recursive delete there would destroy real project files.
- The directory case deliberately does not target a real parent directory, for
  the same reason.

The rename section is the one incomplete part. The five guessed shapes were
tried and all failed; the DevTools capture of a real UI rename has not been
performed yet, so "no rename route exists" is a strong inference from the
probe results rather than a confirmed absence.

Evidence files contain status codes, sizes, hashes, and response bodies only.
No tokens, credentials, or project file contents are recorded, and the probe
redacts credential-shaped text before writing evidence.

## Related contracts

- Read endpoints and the route index: [protocol.md](protocol.md).
- The text write route, which shares this route's preconditions and rules:
  [text-write-protocol.md](text-write-protocol.md).
- The binary upload flow, which cannot choose a path or replace a file:
  [binary-upload-protocol.md](binary-upload-protocol.md).
- The deletion statuses that stay classification-only: [classifier.md](classifier.md).
- Plan fingerprints a future `Apply` must re-verify: [plan.md](plan.md).
- Local path safety and reserved paths: [path-safety.md](path-safety.md).
- Why the `GET /files` list is not atomic: [remote-snapshot.md](remote-snapshot.md).
