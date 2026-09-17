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

## Delete file

DELETE /api/projects/{projectId}/file?path={encodedPath}

Status: observed and characterized in
[delete-rename-protocol.md](delete-rename-protocol.md), but not part of the
supported tool. It removes exactly the named file and returns
`{"success":true,"data":{"deleted":"<path>"}}`. A repeated delete returns 404
rather than an error, a directory-shaped path is 404 rather than recursive, and
`If-Match` / `If-None-Match` are ignored exactly as they are on the write
route. **No rename or move route was found**; a rename would have to compose as
delete + create, and create is unsolved outside `/uploads/{basename}`. Nothing
in the product calls this route, and `deleteRemoteCandidate` remains
classification-only.

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
