# Studio text-file create protocol

Observed behavior for placing a **new** utf8 text file at a project path. These
are undocumented implementation details captured from a disposable project and
may change without notice.

This document is **evidence** for [#37](https://github.com/iNcredibleGM/rundot-game-studio-sync/issues/37).
It does not add a product create call. Until a single create route is proven,
`Plan` / `Push` keep refusing text creates
([plan.md](plan.md), [push.md](push.md)).

Related prior work:

- [#14](https://github.com/iNcredibleGM/rundot-game-studio-sync/issues/14) /
  [text-write-protocol.md](text-write-protocol.md): `PUT /file` is overwrite-only;
  `POST` on that route is `405`.
- [#15](https://github.com/iNcredibleGM/rundot-game-studio-sync/issues/15) /
  [binary-upload-protocol.md](binary-upload-protocol.md): upload flow creates
  text only at `/uploads/{basename}`.
- [#16](https://github.com/iNcredibleGM/rundot-game-studio-sync/issues/16) /
  [delete-rename-protocol.md](delete-rename-protocol.md): `POST /move` relocates
  an existing file to an arbitrary path and refuses an occupied destination with
  `409 ALREADY_EXISTS`.

Read paths are in [protocol.md](protocol.md).

## Single-request create: not found (guessed routes)

The probe tried a small set of one-shot creates against absent paths under
`/sync-probe/`. None listed the target path afterward.

| Attempt | Status | Listed target after |
| --- | --- | --- |
| `POST /api/projects/{id}/files` with `{ path, content }` | `405` `method not allowed` | no |
| `POST /api/projects/{id}/file/create` with `{ path, content }` | `404` `not found` | no |
| `PUT /api/projects/{id}/files` with `{ path, content }` | `405` `method not allowed` | no |
| `POST /api/projects/{id}/create` with `{ path, content, type: file }` | `404` `not found` | no |
| `POST /api/projects/{id}/file?path=` (reconfirm #14) | `405` | no |

**Conclusion:** there is no observed HTTP create route matching these shapes.
The Studio UI may still use a different URL; that requires a DevTools capture
(`text-create-devtools-prepare` / `text-create-devtools-apply` in
[tools/StudioProbe.ps1](../tools/StudioProbe.ps1)). This investigation run
executed the automated scenarios only; **no UI capture was recorded**, so the
UI request shape is still unknown.

## Composition: upload then move (not a single create)

Bytes can reach a chosen path in **two steps**, using routes already
characterized in #15 and #16:

```text
POST /upload-url → PUT presigned URL → POST /upload-adopt   (creates /uploads/<name>.txt)
POST /api/projects/{id}/move   { "from": "...", "to": "..." }
```

Example observed compose to `/sync-probe/…-compose.txt`:

| Step | Status | Size / hash |
| --- | --- | --- |
| adopt | `200` | recorded at `/uploads/…-compose.txt`, sent size **47**, SHA-256 `65c05232…` |
| move | `200` | destination listed; read-back size **47**, SHA-256 `65c05232…` (preserved) |

This is **not** a single create API. It depends on upload collision semantics
and move destination rules.

### Idempotency (second compose onto same destination)

| Step | Status | Result |
| --- | --- | --- |
| First move onto empty destination | `200` | one file at destination, SHA-256 `811ad795…` |
| Second upload (same basename) | `200` | still recorded at `/uploads/…-idempotent.txt` (same path, not a sibling in this run) |
| Second move onto occupied destination | **`409`** `ALREADY_EXISTS` | destination SHA-256 unchanged (`811ad795…`); **two** related paths listed (`/sync-probe/…` and `/uploads/…`) |

A repeat create at the same path is **refused** with `409`, not silently merged.

### Bytes through compose

| Payload | Sent size | Read size | Sent SHA-256 | Read SHA-256 | Preserved |
| --- | --- | --- | --- | --- | --- |
| CRLF (`a` + CR + LF + `b` + CR + LF) | 6 | 6 | `58055bdc…` | `58055bdc…` | yes |
| UTF-8 BOM + `bom` | 6 | **3** | `2623148f…` | `23f3770b…` | **no** (BOM not read back) |
| Empty (`declaredSize: 0`) | 0 | — | `e3b0c442…` (empty) | — | upload-url **`400`** (`declaredSize` must be positive); compose not attempted |

Empty file create through upload was **not** observed in this run.

### Path appears between plan and create

Sequence: fingerprint `GET /files`, occupy destination with compose, then
attempt another compose onto the same path while occupied.

| Step | Status | Destination SHA-256 |
| --- | --- | --- |
| Occupy | move `200` | `20323a24…` |
| Create while occupied | move **`409`** | **`20323a24…` unchanged** |

Occupied bytes survived; no sibling path appeared.

### Conditional headers on `POST /move`

Tested on move (discover routes were all `404`/`405`, so no create verb to test).

| Header | Status | Move applied? |
| --- | --- | --- |
| `If-Match: "definitely-not-the-current-etag"` | `200` | yes |
| `If-Match: not-an-etag` | `200` | yes |
| `If-None-Match: *` | `200` | yes |

No `412`. Preconditions are **not** honored on `POST /move`, matching #14/#16 on
`PUT` / `DELETE`.

### Reserved paths, traversal, and client refusal

Moves onto reserved-shaped destinations (source created via upload):

| Destination | Move status | Listed after |
| --- | --- | --- |
| `/.git/<stamp>-reserved.txt` | **`404`** `not found` | no |
| `/.rundot-sync/<stamp>-reserved.txt` | **`200`** | **yes** (server accepted) |
| `/../<stamp>-escaped.txt` | **`400`** `to must be a normalized absolute project path` | no |

The server does **not** uniformly guard reserved paths. In particular,
`/.rundot-sync/…` was created by move even though the sync client must keep
refusing `.git/`, `.rundot-sync/`, and `..` locally
([path-safety.md](path-safety.md)). A `404` on `/.git/…` must not be read as
“safe”; the client rule stays load-bearing.

## A trustworthy place for source text

There is still no single create route. Source files can be placed exactly by
using the upload flow only to **bring a path into existence**, then `PUT /file`
to store the real bytes. `PUT` is overwrite-only (#14), so it cannot be the
first call. Once the path exists, it preserves the bytes the upload step does
not.

`text-place-exact` did this for four probe-owned files, `Content-Type:
text/plain`, each upload name unique for the run:

1. `POST /upload-url` → presigned `PUT` → `POST /upload-adopt`
2. `POST /move` from `/uploads/<unique>` to the chosen path (`/sync-probe/src/…` for the `.ts` case)
3. `PUT /file` with `{ "content": "<exact text>" }`
4. `GET /file` and compare size and SHA-256

| Case | After upload | After move | After `PUT /file` |
| --- | --- | --- | --- |
| `.ts`, CRLF, quotes, nested `src/` | 41 bytes, `0ea58a48…`, `utf8` | same hash, move `200` | same hash, `PUT` `200`, exact |
| `.ts` with a leading U+FEFF | **25 bytes, no BOM**, `b21c4879…` | same stripped hash | **28 bytes, BOM present**, `fcf75c2e…`, exact |
| empty `.ts` | upload of 0 bytes is rejected, so a 1-byte placeholder was uploaded (`2d711642…`) | move `200`, still 1 byte | **0 bytes**, `e3b0c442…` (empty digest), exact |
| `.json` | 14 bytes, `4300d4e4…`, `utf8` | same hash | same hash, exact |

Upload itself is already exact for ordinary UTF-8 source without a BOM. It is
not exact for a BOM, and it cannot create an empty file (`declaredSize: 0` is
`400`). The `PUT` after the path exists repairs both. A nested destination was
honored by `POST /move`.

That sequence is still not safe to call blindly:

- `POST /move` onto a path that already exists is `409` and changes nothing. A create must stop there, or switch to the existing overwrite rules, rather than assuming the move placed these bytes.
- `If-Match` is ignored, so the client still re-reads immediately before the `PUT`.
- `.git/`, `.rundot-sync/`, and `..` stay client refusals even though a move onto `/.rundot-sync/` returned `200`.
- Nothing in the product calls upload, move, or a create `PUT`. [#40](https://github.com/iNcredibleGM/rundot-game-studio-sync/issues/40) owns wiring this, if it is adopted.

## Summary for publish design

| Question | Answer from this evidence |
| --- | --- |
| Is there a single-request text create route? | **Not among guessed routes.** UI capture still outstanding. |
| Can a chosen path get new text bytes at all? | **Yes.** Unique upload, `POST /move` onto an absent path, then `PUT /file`. |
| Is upload alone byte-exact for source? | For ordinary UTF-8 without a BOM, yes. A BOM is stripped (28 sent, 25 stored). `PUT /file` restored 28 bytes, sha `fcf75c2e…`. |
| CRLF preserved through compose? | **Yes** (6 = 6, matching hashes). A `.ts` with CRLF was also exact after upload (41 bytes, `0ea58a48…`). |
| BOM preserved through compose? | **No** on upload or move. **Yes** after the follow-up `PUT /file`. |
| Empty file through compose? | Upload rejects `declaredSize: 0`. A 1-byte placeholder, move, then `PUT` of `""` read back as size 0, sha `e3b0c442…`. |
| Is compose idempotent on the same path? | **No.** Second move onto an existing destination → **`409`**, bytes unchanged. |
| Destination occupied before create? | **`409`**, occupied bytes preserved. |
| `If-Match` / `If-None-Match` on move? | **Ignored** (all `200`, no `412`). |
| Server guards `.rundot-sync/`? | **No** (`200` move). Client must still refuse. |

## Consequence for [#40](https://github.com/iNcredibleGM/rundot-game-studio-sync/issues/40)

This issue does **not** implement `Push` text creates. A trustworthy create,
if #40 adopts it, is: unique upload, `POST /move` onto an absent path, then
`PUT /file` so BOM and empty files match the local bytes. Product text creates
stay **`applicable: false`** until that issue lands.

## How this was observed

Scenario `run-text-create-all`, then `text-place-exact`, in [tools/StudioProbe.ps1](../tools/StudioProbe.ps1)
against a disposable Studio project. Evidence records status codes, sizes, and
SHA-256 only. No tokens, credentials, or file contents appear in this document.
A follow-up list showed no probe paths left behind.

## Related contracts

- Overwrite-only text route: [text-write-protocol.md](text-write-protocol.md).
- Upload create at `/uploads/` only: [binary-upload-protocol.md](binary-upload-protocol.md).
- Move semantics: [delete-rename-protocol.md](delete-rename-protocol.md).
- Route index: [protocol.md](protocol.md).
