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

Observed:

PUT /api/projects/{projectId}/file?path={encodedPath}

Content-Type: application/json

{
  "content": "..."
}

Status: observed, not yet part of the supported tool.

## Threads

GET /api/projects/{projectId}/threads

GET /agents/chat-thread/{uid}:{projectId}:{threadId}/get-messages

## Binary upload

Observed flow:

1. POST /api/projects/{projectId}/upload-url
2. PUT raw bytes to returned presigned object-storage URL
3. POST /api/projects/{projectId}/upload-adopt

Uploading a second binary with the same filename was observed to create a
collision-safe renamed file such as `name-1.png`, rather than replacing the
existing file.

Status: observed, not yet part of the supported tool.
