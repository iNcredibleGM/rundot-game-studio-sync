# Studio large-file protocol

Observed behavior for publishing files larger than Studio's 2,000,000-byte
**read** limit, and the real ceiling on the **write** path. These are
undocumented implementation details captured from a disposable project and may
change without notice.

This document is **evidence**. It adds no product call. It exists to answer two
questions raised by a RUN Discord patch note claiming uploads "up to 200 MB":

1. What is the actual ceiling on `POST /upload-url`?
2. Can a file over the read limit be published, replaced, or edited?

Related: [binary-upload-protocol.md](binary-upload-protocol.md) (the upload
flow), [binary-place-protocol.md](binary-place-protocol.md) (the place sequence
and the read limit), [text-write-protocol.md](text-write-protocol.md) (the
2,000,000-character write limit), [protocol.md](protocol.md) (route index).

Probe: `tools/UploadCeilingProbe.ps1`. It writes only under
`/sync-probe/upload-ceiling-<runstamp>` and deletes every file it creates.

## 1. The write ceiling is 50 MiB, not 200 MB

`POST /upload-url` refuses any `declaredSize` over **52,428,800 bytes
(50 MiB)** with `413 FILE_TOO_LARGE`:

```text
413
{ "success": false,
  "error": { "message": "That file is 100MB - the limit is 50MB.",
             "code": "FILE_TOO_LARGE", "field": "file" } }
```

The message names the file and the limit, and it tracks the declared value
(`100MB`, `150MB`, `200MB`, `200.1MB` all report `the limit is 50MB`).

A binary search between the known-good 52,428,800 and the known-refused
104,857,600 pinned the boundary exactly:

| `declaredSize` | Result |
| --- | --- |
| 52,428,800 (50 MiB) | `200` |
| 52,428,801 | `413` |

**One byte over 50 MiB is refused.** The ceiling is exact, and it is a
`declaredSize` check on `upload-url`, before any byte moves — every probe in
the search returned `413` from the declaration alone.

**The 200 MB figure is not what the API enforces.** Whatever the patch note
described (a UI allowance, a future change, or a different product surface),
this route on this environment caps at 50 MiB. The earlier recorded data point
(104,857,600 → `413`) was consistent with this and is now explained by it.

## 2. A full 50 MiB body survives the place sequence

The largest accepted declaration is also a working upload. A real 52,428,800-byte
body through `upload-url` → presigned `PUT` → `upload-adopt` → `POST /move`:

| Step | Result |
| --- | --- |
| `upload-url` | `200` |
| presigned `PUT` | `200`, `ETag` `7fa16b6e9049a01be0e03f92c23da669` |
| `upload-adopt` | `200`, recorded `size` 52428800, `mimeType` `application/octet-stream` |
| `POST /move` | `200`, landed on the planned path |
| local MD5 | `7fa16b6e9049a01be0e03f92c23da669` |
| `GET /file` | **`413`** (over the read limit, as expected) |

The recorded size equalled the uploaded byte count, and the `ETag` equalled the
local MD5 exactly. So the #54 ETag-verify path — already used for oversized
**creates** — extends unchanged from 2 MB to the full 50 MiB ceiling.

## 3. The ETag stays a plain MD5 at 50 MiB

Object storage switches to a multipart `ETag` (`<md5>-<count>`) above some
threshold, which is **not** a content digest and cannot be compared to a local
MD5. That does not happen by 50 MiB:

| Size | `ETag` shape | Equals local MD5 |
| --- | --- | --- |
| 52,428,800 (50 MiB) | plain 32-hex | yes |

`Assert-SyncEtagMatchesLocalMd5` already refuses a non-plain digest rather than
comparing it, so a future multipart switch fails closed rather than silently
mismatching.

## 4. The 2,000,000 limit on `PUT /file` is on the stored file, not the new body

A large payload **can** be placed as editable text: uploading 2,850,030 bytes
with `Content-Type: text/plain` and moving it to a `.md` path records
`mimeType: text/plain` at the destination. But the path then behaves as a
large file everywhere else:

| Operation on the placed 2.85 MB text path | Result |
| --- | --- |
| `GET /file` | `413` (unreadable) |
| `PUT /file` with a **1-character** body | **`413`** |

The tiny `PUT` returning `413` is the important part. It means the write limit
is checked against the **stored file**, not against the length of the content
being sent. A size sweep confirms the threshold sits at 2,000,000:

| Placed size | Tiny `PUT /file` |
| --- | --- |
| 1,990,022 bytes | `200` |
| 2,000,012 bytes | `413` |
| 2,500,052 bytes | `413` |

**Consequence:** a text file published above 2,000,000 bytes becomes
permanently un-editable through `PUT /file`. It can be replaced only by
delete-then-place (the same route that created it), never edited in place. The
existing refusal at `lib/RemoteWrite.ps1` is therefore correct, and the product
should keep refusing to create a text file it could never edit again — or
accept, deliberately, that such a path is write-once.

## 5. A large binary replace is mechanically possible

Replace is delete-then-place. At 3 MB, both halves work:

| Step | Result |
| --- | --- |
| place #1 (3 MB) | `upload-url` `200`, `PUT` `200`, adopt `200`, move `200` |
| place #1 `ETag` vs local MD5 | equal |
| `DELETE` the path | `200`, `{"success":true,"data":{"deleted":"…"}}` |
| absent after `DELETE` | yes (proved from `GET /files`) |
| place #2 (different 3 MB) | `200` at every step |
| place #2 `ETag` vs local MD5 | equal |
| `GET /file` | `413` |

So the sequence itself has no size obstacle below 50 MiB. What the probe
**cannot** do is the two things the product's replace path requires:

- **Back up the pre-replace remote bytes.** They cannot be read (`413`).
- **Honor the `expectedRemoteHash` gate.** No route exposes a hash for a
  remote file over the read limit — not `/files`, not `upload-adopt`, not
  `move`.

The only identity available before a replace is the **size** from `GET /files`.
That is a real but weak guard: it catches a different-sized change and misses a
same-sized one.

## What this means for the product

| Case | Status today | Evidence here |
| --- | --- | --- |
| Binary **create** over 2 MB, up to 50 MiB | already published via the upload `ETag` (#54) | §2, §3 |
| Binary create over 50 MiB | impossible — `upload-url` refuses | §1 |
| Binary **replace** over 2 MB | refused (no backup, no hash gate) | §5 |
| Text over 2,000,000 bytes | refused at `PUT /file` | §4 |
| Remote file over 2 MB | `unverifiable`, never downloaded | §2 |

Two implementable changes fall out of this, each needing its own issue and its
own decision about the weakened safety net:

1. **Large binary replace up to 50 MiB**, using delete-then-place with the
   upload `ETag` as the post-place identity, and the `GET /files` size as the
   only pre-replace guard. This trades the backup and the `expectedRemoteHash`
   gate for the ability to replace at all — an explicit decision, not a silent
   fallback.
2. **A clear refusal (not an attempt) for text over 2,000,000 bytes**, naming
   that the path would be write-once. The current behavior already refuses;
   what is missing is a reason string that says why.

Neither changes the read limit: a file already on Studio over 2 MB stays
unverifiable, and no route was found that returns its bytes.

## How this was observed

`tools/UploadCeilingProbe.ps1` against a disposable Studio project:
`-Scenario`-free, `-ConfirmRemoteWrite -CeilingScan`. It records status codes,
sizes, and hashes only — no tokens, credentials, or file contents.

Cleanup note: the probe deletes every **file** it creates, and the empty
`/sync-probe/upload-ceiling-<stamp>` **directories** remain. Studio has no
directory-delete route (`DELETE` on a directory-shaped path is `404`;
[delete-rename-protocol.md](delete-rename-protocol.md)), so empty probe
directories are expected residue in a disposable project.
