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

## Endpoints

```text
DELETE /api/projects/{projectId}/file?path={encodedPath}

POST   /api/projects/{projectId}/move
Content-Type: application/json

{ "from": "{absolute path}", "to": "{absolute path}" }
```

`DELETE` takes no body. `path` is percent-encoded and must be absolute, exactly
as on the read and write routes.

A successful delete returns `200` with the path it removed:

```json
{ "success": true, "data": { "deleted": "/uploads/probe.txt" } }
```

`Content-Type: application/json`. This is the same `/file` route that serves
`GET` and `PUT`, so the verb is the whole difference. The move route is
separate and sits at the project root; it is covered under
[Rename / move](#rename--move).

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

**A rename route exists**, and it is at the **project root**, not under `/file`
or `/files`:

```text
POST /api/projects/{projectId}/move
Content-Type: application/json

{ "from": "/uploads/a.txt", "to": "/sync-probe/b.txt" }
```

```json
{ "success": true,
  "data": { "from": "/uploads/a.txt", "to": "/sync-probe/b.txt" } }
```

It was found by capturing a real UI rename from the DevTools Network panel.
Five guessed shapes had failed first, and they are worth recording because they
show where the route is *not*:

| Attempt | Status | Body |
| --- | --- | --- |
| `PATCH /file?path=…` with `newPath` | `405` | `method not allowed` |
| `POST /file/rename` with `path` + `newPath` | `404` | `not found` |
| `POST /file/move` with `path` + `newPath` | `404` | `not found` |
| `POST /files/rename` with `from` + `to` | `404` | `not found` |
| `PUT /file?path=…` with only `newPath` | `400` | `content must be a string` |

The `PUT` case is the most telling of the failures: the body carried `newPath`,
and the server rejected it for a missing `content` string, which proves it
looked for `content` and **ignored `newPath` entirely**.

### It honors an arbitrary destination path

This is the opposite of the upload flow, which discards the requested directory
and always lands at `/uploads/{basename}`
([binary-upload-protocol.md](binary-upload-protocol.md)). A move takes the
destination literally:

| Move | Result |
| --- | --- |
| `/uploads/a.txt` → `/sync-probe/b.txt` | `200`, moved; destination honored |
| `/uploads/a.txt` → `/sync-probe/b.txt` (same directory) | `200`, moved; destination honored |

A file can be relocated **out of `/uploads` entirely**, into any directory. This
is the only observed way to place a file at an arbitrary path, since `PUT /file`
cannot create and the upload flow cannot choose a path.

[#38](https://github.com/iNcredibleGM/rundot-game-studio-sync/issues/38)
refined this for the destinations that matter to a binary landing:

| Destination | Status | Listed after | Note |
| --- | --- | --- | --- |
| A nested path (`/sync-probe/src/assets/x.png`) | `200` | yes | honored verbatim |
| A **leading-dot** name (`/sync-probe/.x.png`) | `200` | yes | the dot is **preserved** |
| `/.git/x.png` | `404` `not found` | no | |
| `/.rundot-sync/x.png` | **`200`** | **yes** | server accepted |
| `/.rundot/x.png` | **`200`** | **yes** | server accepted |
| `/../x.png` | `400` | no | `to must be a normalized absolute project path` |

Two of these are worth calling out. A **leading dot survives a move** even
though the upload flow strips it from a filename — so a dotfile can reach its
real path, but the dot has to come from the move destination. And the server
does **not** uniformly guard reserved paths: `/.rundot-sync/…` and `/.rundot/…`
were created with `200`, while `/.git/…` returned `404`. The `404` is the same
one an absent path returns, so it must not be read as protection, and the
client-side reserved-path rule ([path-safety.md](path-safety.md)) stays
load-bearing on this route. See
[binary-place-protocol.md](binary-place-protocol.md).

### Bytes are preserved exactly

| Kind | SHA-256 before | SHA-256 after | Preserved |
| --- | --- | --- | --- |
| Text | `5b2e1b13…` | `5b2e1b13…` | yes |
| Binary (`image/png`) | `443059c4…` | `443059c4…` | yes |

A move works on binaries as well as text, and it does not re-encode. For
binaries this matters more than for text: the upload flow cannot target a path
and cannot replace a file, so **a move is the only way to relocate a binary**
short of delete + re-upload, which cannot restore the original path.

### It refuses to overwrite an existing destination

| Attempt | Status | Body | Source after | Destination after |
| --- | --- | --- | --- | --- |
| Move onto an existing path | `409` | `Something already exists at that destination.` | still listed | unchanged (`c28eafda…` before and after) |

This is a genuine safety property, and it is the opposite of `PUT /file`, which
silently replaces in place. A move **cannot clobber a file**, so it is not a
silent-destruction risk the way a write is. The destination's bytes were
byte-for-byte identical before and after the attempt.

### Failure and retry behavior

| Case | Status | Body |
| --- | --- | --- |
| Move from a path that does not exist | `404` | `not found` |
| Move a second time, after the first succeeded | `404` | `not found` |
| Move onto an existing destination | `409` | `ALREADY_EXISTS` |

A retry after an ambiguous failure returns `404` because the source is already
gone, and the destination **survives** — the retry does not undo or duplicate
the first move. As with delete, the effect is idempotent even though the status
is not: `404` here means "the move already happened", not "the move failed".

Note the difference in body shape: `404` is `text/plain` with the literal
`not found`, while `409` is JSON with an `error.code` of `ALREADY_EXISTS`. A
client must not assume JSON on every status.

### Consequences for `Push`

This reverses the earlier conclusion for this section. A rename **is**
expressible, and it is safer than a write:

- A local rename can be published as a single `POST /move`, not as a delete
  plus a create. The create half is no longer needed.
- It cannot silently clobber, because a move onto an existing destination is
  refused with `409` rather than replacing it.
- It preserves bytes exactly, for text and binaries alike.
- It can target any path, which is the one capability the upload flow lacks.

The remaining caveat is the same one that applies to every other route here:
there is no ETag, no version, and no honoured `If-Match`
([below](#etag-and-conditional-requests)), so a move cannot be made
conditional. A client must still verify that `from` is the file it expects
immediately before sending the request, and must still keep a recoverable copy,
because the server cannot refuse a move computed against a changed source.


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
| Is a rename possible? | **Yes.** `POST /api/projects/{id}/move` with `{from,to}`. |
| Does a move honor the destination path? | Yes, including moving out of `/uploads` entirely. |
| Can a move clobber an existing file? | **No.** It returns `409 ALREADY_EXISTS` and changes nothing. |
| Does a move preserve bytes? | Yes, exactly, for text and binaries alike. |
| Is there any revision identity? | No. `path`, `type`, `size` only. |
| Does a stale write over a deleted file resurrect it? | **No.** It returns `404`. |

## Summary for `Push` design

The four constraints that matter:

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

3. **A rename is expressible and is safer than a write.** A local rename can be
   published as one `POST /move`, and a move cannot clobber: it refuses an
   existing destination with `409` instead of replacing it. It also preserves
   bytes exactly and can target any path, which makes it the only way to
   relocate a binary.

4. **A move is still unversioned.** No ETag and no honoured `If-Match` means a
   move cannot be made conditional either, so the source must be verified
   client-side immediately before the request, exactly as for a write or a
   delete.

For [#17](https://github.com/iNcredibleGM/rundot-game-studio-sync/issues/17)
this means a `deleteRemoteCandidate` row could in principle be applied with a
client-side re-fingerprint immediately before the `DELETE`, plus a backup of
the bytes being removed — but only once the milestone permits remote mutation.
Nothing in this evidence authorizes emitting a standing `DELETE` today, and
`deleteRemoteCandidate` remains classification-only.

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

The rename section is complete. The route was found by capturing a real UI
rename from the DevTools Network panel after five guessed shapes failed, then
characterized live. Two probe bugs surfaced during that work and were fixed:
the capture extractor recorded the request method without its URL, and the
`-AllRuns` cleanup selected paths its own guard refused. Both are pinned by
assertions now.

Evidence files contain status codes, sizes, hashes, and response bodies only.
No tokens, credentials, or project file contents are recorded, and the probe
redacts credential-shaped text before writing evidence.

## Related contracts

- Read endpoints and the route index: [protocol.md](protocol.md).
- The text write route, which shares this route's preconditions and rules:
  [text-write-protocol.md](text-write-protocol.md).
- The binary upload flow, which cannot choose a path or replace a file:
  [binary-upload-protocol.md](binary-upload-protocol.md).
- The composed landing this route enables: [binary-place-protocol.md](binary-place-protocol.md).
- The deletion statuses that stay classification-only: [classifier.md](classifier.md).
- Plan fingerprints a future `Apply` must re-verify: [plan.md](plan.md).
- Local path safety and reserved paths: [path-safety.md](path-safety.md).
- Why the `GET /files` list is not atomic: [remote-snapshot.md](remote-snapshot.md).
