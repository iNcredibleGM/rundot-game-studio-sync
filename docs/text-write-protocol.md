# Studio text write protocol

Observed behavior of the one Studio route that can change a text file. These
are undocumented implementation details captured from a disposable project and
may change without notice.

This document is **evidence** for the one route `Push` may call: documented
`PUT /file` for utf8 text overwrites only ([push.md](push.md)). There is still
no `Apply` shortcut, and no binary create or adopt route is used.

Read paths are in [protocol.md](protocol.md); this document covers only the
write side. Binary create/overwrite is [#15](https://github.com/iNcredibleGM/rundot-game-studio-sync/issues/15),
and delete, rename, and concurrency are characterized in
[delete-rename-protocol.md](delete-rename-protocol.md).

## Endpoint

```text
PUT /api/projects/{projectId}/file?path={encodedPath}
Content-Type: application/json

{ "content": "..." }
```

`path` is percent-encoded as before. The `content` value is a JSON string.

### `path` must be absolute

The route requires a **leading `/`** on `path`. A relative path is rejected
before the body is examined:

```text
400  path must be an absolute project path
```

That response is `text/plain;charset=UTF-8`, not JSON. This is the first
difference from the read routes and it is easy to miss: the same relative
spelling that works for `GET /file` in this codebase's own tests is rejected on
write. Every write must send the API's own absolute spelling.

## This route cannot create a file

**`PUT` is overwrite-only.** A path that is not already in the project is
rejected, and no other verb on this route creates one:

| Attempt | Result |
| --- | --- |
| `PUT` to a path not in `GET /files` | `404 not found` |
| `PUT` to a directory-shaped path | `404 not found` |
| `POST` on the same route | `405` |

Creating a text file therefore needs a different mechanism that is **not
established by this investigation** (see [text-create-protocol.md](text-create-protocol.md)
for the #37 create characterization). `Plan` classifies a brand-new local file as
`upload` with a dash in REMOTE (`— / A / —`), so the create case is exactly the
case this route cannot serve.

**One create avenue does exist**, but not through this route: the binary upload
flow can create a text file at `/uploads/{basename}`
([binary-upload-protocol.md](binary-upload-protocol.md)). It cannot create a
file at an arbitrary path, and it collides rather than replaces, so it is a
narrow exception rather than a general create mechanism.

Consequence for [#17](https://github.com/iNcredibleGM/rundot-game-studio-sync/issues/17):
`Apply-SyncPlan` / `Push` **cannot publish a new file** using this route alone.
A create path must be found before `Push` can honour every `upload` row, or
`Push` must refuse new-file rows explicitly rather than failing them mid-run.
Do not assume the binary `upload-url` / `upload-adopt` flow covers text
generally; it covers only `/uploads/{basename}`, as
[#15](https://github.com/iNcredibleGM/rundot-game-studio-sync/issues/15) found.

## Overwrite semantics

Overwriting a path that exists succeeds and replaces the file **in place**:

```text
200
{ "path": "/README.md", "encoding": "utf8", "content": "<new content>",
  "mimeType": "text/plain", "size": 48 }
```

- **No collision rename.** Repeatedly overwriting one path never produced a
  suffixed sibling such as `README-1.md`. The path is the identity and the old
  bytes are gone. This is the opposite of the binary flow, where a second upload
  with the same name was observed to create `name-1.png`.
- **The response echoes the file back.** The write response carries the new
  `content`, `encoding`, `size`, and `mimeType`, so a writer can verify what the
  server recorded without a follow-up `GET`.
- **Empty content is accepted** and yields `size: 0`. An empty file and a missing
  file are therefore different states that a writer must not conflate.

### Content is preserved byte-for-byte

Each row below sent specific bytes and read them back through `GET /file`:

| Content sent | Bytes read back | Preserved |
| --- | --- | --- |
| `line one\r\nline two\r\n` | 20 | CRLF kept, not normalized to LF |
| `emoji <U+1F600> end` | 14 | 4-byte UTF-8 sequence intact |
| `<BOM>bom prefixed` | 15 | UTF-8 BOM kept |
| `no trailing newline` | 19 | trailing newline not added |
| `""` | 0 | empty file allowed |

There is no newline normalization, no encoding conversion, and no BOM
stripping. A writer can send the exact local bytes and get the exact bytes back,
which matches the byte-for-byte identity model the rest of the tool already uses
([classifier.md](classifier.md)).

### Idempotent

Three consecutive byte-identical writes produced the same SHA-256 and one file
row. Re-sending the same content is safe and does not multiply the file or
create a duplicate. There is no revision counter to bump, so a retry after an
ambiguous failure is not distinguishable from a first success by inspecting the
file — only by comparing hashes.

## No conditional requests, and no version identity

There is **no way to make a write conditional**, and no server-side field to
condition on.

### No ETag, no version, no revision

A `GET /files` row for a text file exposes only three fields:

```json
{ "path": "/README.md", "type": "file", "size": 3210 }
```

No `etag`, `hash`, `sha256`, `contentHash`, `version`, `revision`, or
`updatedAt`. Write responses carry no `ETag` header either. The identity fields
that [remote-snapshot.md](remote-snapshot.md) folds into a manifest fingerprint
when the API offers them are simply absent here.

### Conditional headers are ignored

| Request | Result |
| --- | --- |
| `If-Match: "<value that cannot match>"` | `200`, file overwritten |
| `If-Match: not-an-etag` (malformed) | `200`, file overwritten |
| `If-None-Match: *` on an existing file | `200`, file overwritten |

A `412` would have meant the header is enforced. Every attempt returned `200` and
replaced the content, including a syntactically invalid value. The server does
not implement preconditions on this route.

### Consequence: concurrent modification cannot be detected server-side

Because there is no ETag, no version field, and no honoured `If-Match`, the
server has no way to reject a write that was computed against stale content.

**This was confirmed live.** The sequence was:

1. Write a known baseline to `/README.md`.
2. Change `/README.md` to different content through the Studio editor and save.
3. Send the step-1 baseline bytes back through `PUT`, without any precondition.

| Step | Result |
| --- | --- |
| Remote content at step 3 (sha `a4c3ed04…`) | differs from the stale bytes (`c6f267dd…`) |
| `PUT` of the stale bytes | `200`, and the response echoes the stale content |
| Remote content after the write | sha `c6f267dd…` — the human edit is gone |

The write succeeded with no error, no warning, and no field in the response
indicating that the content it replaced was not what the writer expected. A
concurrent Studio edit is **silently clobbered**.

This is the single most important constraint for `Push`. The v0.1.3 plan
artifact records `expectedRemoteHash` and `remoteManifestHash` precisely so a
future `Apply` can re-verify before writing
([plan.md](plan.md)). This evidence shows that re-verification must happen
**entirely on the client, immediately before the write**, and that it can never
be delegated to the server. The window between "re-check remote hash" and "send
PUT" is unprotected; the only mitigations available are to keep that window as
small as possible, to compare the hash again after the write, and to keep a
backup of the bytes being replaced so a clobber is recoverable rather than
silent.

## Failure behavior

### Body validation

Every malformed body collapses to one error, so a client cannot tell the
failures apart:

```text
400
{ "success": false,
  "error": { "message": "content must be a string",
             "code": "VALIDATION_ERROR",
             "field": "content" } }
```

| Body sent | Status |
| --- | --- |
| `{"notContent":"x"}` (no `content`) | 400 `VALIDATION_ERROR` |
| `{"content":null}` | 400 `VALIDATION_ERROR` |
| `{"content":["a","b"]}` | 400 `VALIDATION_ERROR` |
| `{"content":{"a":1}}` | 400 `VALIDATION_ERROR` |
| `{"content":42}` | 400 `VALIDATION_ERROR` |
| `{not json` (unparseable) | 400 `VALIDATION_ERROR` |
| plain text with `Content-Type: text/plain` | 400 `VALIDATION_ERROR` |

Note that `content` must be a JSON **string**. A writer must not pass a raw
object or a pre-serialized blob.

### Authentication

| Request | Result |
| --- | --- |
| No `Authorization` header | `401 unauthorized` |
| Garbage bearer token | `401 unauthorized` |

### Size limit

The limit is **2,000,000 characters** of `content`, and it is inclusive:

| `content` length | Status |
| --- | --- |
| 1,999,999 | 200 |
| 2,000,000 | 200 |
| 2,000,001 | 413 |
| 4,194,304 | 413 |

```text
413
{ "success": false,
  "error": { "message": "This file is too large to save from the editor.",
             "code": "FILE_TOO_LARGE" } }
```

A failed oversized write left the previous content intact (the file still read
back as the last successful write), so a rejected write is not a partial write.
`Push` must still treat `413` as a refusal, not a retry.

### Path handling

| Path sent | Result | Note |
| --- | --- | --- |
| `/../escaped.txt` | 400 absolute-path error | traversal form is not normalized into a write |
| `/.git/probe.txt` | 404 `not found` | not a distinct "forbidden" |
| `/.rundot/probe.txt` | 404 `not found` | not a distinct "forbidden" |
| path containing a NUL | 400 absolute-path error | rejected |

The `404` for `.git` and `.rundot` is the same response as any other absent
path. **No server-side reserved-path guard was observed** — those paths simply
did not exist. A client must therefore enforce its own reserved-path rules and
must not read a `404` as protection. The local safety layer already does this
([path-safety.md](path-safety.md)); it is now load-bearing rather than
defense-in-depth.

## Summary for `Push` design

| Question | Answer from evidence |
| --- | --- |
| Can it create a new text file? | No single API route found ([#37](https://github.com/iNcredibleGM/rundot-game-studio-sync/issues/37): guessed creates fail; see [text-create-protocol.md](text-create-protocol.md)). `PUT` 404s; `POST` on `/file` is 405. Upload+move can compose a path but is not one create call. |
| Does overwrite replace in place? | Yes. No collision rename. |
| Are bytes preserved? | Yes, exactly: CRLF, BOM, emoji, empty, no trailing newline. |
| Is it idempotent? | Yes. Identical writes converge, no duplicates. |
| Can a write be made conditional? | No. No ETag, no version, `If-Match` ignored. |
| Can a stale write be detected server-side? | No. Confirmed live: a concurrent Studio edit is silently clobbered. |
| Does it return the new state? | Yes, the response echoes path/encoding/content/size/mimeType. |
| What refuses a write? | `400` body validation, `401` auth, `413` over 2,000,000 chars, `404` absent path. |
| Does a rejected write damage the file? | No partial write observed; prior content survived a `413`. |
| Are reserved paths protected server-side? | No guard observed; a client must enforce its own. |

The two hard constraints are that **create is unsolved** and that **staleness is
undetectable server-side, confirmed by a live silent clobber**. Both must be
resolved or explicitly refused before `Push` can claim a safe overwrite.

## How this was observed

A local probe script outside the repository sent the requests and recorded status
codes, response bodies, and read-back hashes. It ran against a disposable Studio
project only. Every mutating case read the original bytes first and restored them
afterwards, verifying the restore by SHA-256; the probe reported any path it
could not restore. The concurrency case additionally required a manual edit in
the Studio editor between two probe runs, so that observation is a live
end-to-end result rather than a simulated one. No tokens, credentials, or
project file contents are recorded here, and the evidence files contain only
status codes, sizes, and hashes.

The probe is deliberately not committed: this milestone's mutation ban covers
product PowerShell, and shipping a working `PUT` helper would sit awkwardly
against it. Re-running the investigation means rebuilding the probe from this
document.

## Related contracts

- Read endpoints and the route index: [protocol.md](protocol.md).
- Byte-identity model the write must match: [classifier.md](classifier.md).
- Plan fingerprints a write must re-verify: [plan.md](plan.md).
- Local path safety and reserved paths: [path-safety.md](path-safety.md).
- Why the `GET /files` list is not atomic: [remote-snapshot.md](remote-snapshot.md).
