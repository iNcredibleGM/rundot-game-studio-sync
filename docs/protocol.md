# Observed RUN Game Studio Protocol

These endpoints were observed from normal RUN Game Studio browser traffic.

They are undocumented implementation details and may change without notice.

## Project manifest

GET /api/projects/{projectId}/files

This list is not known to be atomic. Sync must capture REMOTE through
`Get-StableRemoteSnapshot` (see [remote-snapshot.md](remote-snapshot.md))
rather than treating a single `/files` response as truth.

## Read file

GET /api/projects/{projectId}/file?path={encodedPath}

## Write text file

PUT /api/projects/{projectId}/file?path={encodedPath}

Content-Type: application/json

{
  "content": "..."
}

Status: observed and characterized in
[text-write-protocol.md](text-write-protocol.md), but not part of the supported
tool. It is **overwrite-only**: a path that is not already in the project
returns 404, and there is no ETag, version field, or honoured `If-Match`. Nothing
in the product calls this route.

## Create text file

Status: investigated in [#37](https://github.com/iNcredibleGM/rundot-game-studio-sync/issues/37)
([text-create-protocol.md](text-create-protocol.md)). **No single-request create
route** was found among guessed API shapes; `PUT /file` remains overwrite-only
(#14). Studio’s UI does not expose a new text-file create (and does not offer
text upload; binary upload is separate). New source text at a chosen path was
observed only through the **API**: unique **upload adopt**, **`POST /move`**, then
**`PUT /file`** for exact bytes. Nothing in the product creates remote text files.

## Delete file

DELETE /api/projects/{projectId}/file?path={encodedPath}

Status: implemented by a confirmed `Push` in `lib/RemoteDelete.ps1` for a
route-allowed `deleteRemoteCandidate` row, and characterized in
[delete-rename-protocol.md](delete-rename-protocol.md). It removes exactly the
named file and returns
`{"success":true,"data":{"deleted":"<path>"}}`. A repeated delete returns 404
rather than an error, a directory-shaped path is 404 rather than recursive, and
`If-Match` / `If-None-Match` are ignored exactly as they are on the write
route, so the guard is client-side ([delete.md](delete.md)). A rename or move is
`POST /api/projects/{id}/move` with `{from,to}`, characterized in
[delete-rename-protocol.md](delete-rename-protocol.md). It honors an arbitrary
destination path, preserves bytes, and refuses to overwrite an existing
destination with `409 ALREADY_EXISTS`. Rename is not emitted by any command.

## Move / rename file

POST /api/projects/{projectId}/move

Content-Type: application/json

{
  "from": "/uploads/a.txt",
  "to": "/sync-probe/b.txt"
}

Status: observed and characterized in
[delete-rename-protocol.md](delete-rename-protocol.md), but not part of the
supported tool. It honors an arbitrary destination path (unlike the upload
flow), preserves bytes exactly for text and binaries, and **refuses to
overwrite**: a destination that already exists returns `409 ALREADY_EXISTS` and
changes nothing. A move from a path that does not exist is `404`. Nothing in
the product calls this route.

## Threads

GET /api/projects/{projectId}/threads

GET /agents/chat-thread/{uid}:{projectId}:{threadId}/get-messages

## Binary upload

Observed flow:

1. POST /api/projects/{projectId}/upload-url
2. PUT raw bytes to returned presigned object-storage URL
3. POST /api/projects/{projectId}/upload-adopt

Status: observed and characterized in
[binary-upload-protocol.md](binary-upload-protocol.md), but not part of the
supported tool. Three findings dominate: the requested `path` is **ignored**,
so the file is always recorded at `/uploads/{basename}`; a repeated filename
**never replaces** the existing file, it creates a numeric-suffixed sibling
(`name-1.png`); and the flow **can create a text file** at that path, which
`PUT /file` cannot. Replacement was not achievable by any attempt. Nothing in
the product calls these routes.

## Place a binary at a chosen project path

Status: investigated in [#38](https://github.com/iNcredibleGM/rundot-game-studio-sync/issues/38)
([binary-place-protocol.md](binary-place-protocol.md)). The upload flow cannot
choose a path, but a composed sequence can: upload a unique name, `POST /move`
to the chosen path, and the staging copy is gone — one binary at the requested
path, with bytes preserved. A repeated upload name still collides, and the
adopt response names the suffixed path it actually recorded, so the sibling is
visible and can be deleted. Replacement is **delete-then-place**, not an
in-place overwrite: a move onto an occupied destination is refused with `409`
and changes nothing. A move honors a leading-dot destination (which the upload
flow strips) and any nested path, but the server does not uniformly guard
reserved paths (`/.rundot-sync/…` and `/.rundot/…` returned `200` while
`/.git/…` returned `404`), so the client-side rule stays load-bearing. Nothing
in the product calls these routes.
