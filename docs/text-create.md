# Create remote text files

`Push` is the only command that creates a remote utf8 text file at a project
path. It applies an applicable `upload` row (`BASE=— LOCAL=A REMOTE=—`) from a
verified plan artifact, using the documented place sequence in
[text-create-protocol.md](text-create-protocol.md).

`Push` never overwrites an existing remote file on this path and never downloads.
Binaries use the separate place sequence ([binary-place.md](binary-place.md)).

```powershell
.\game-studio-sync.ps1 -ProjectId <id> -LocalDir <dir> -Command Plan
.\game-studio-sync.ps1 -ProjectId <id> -LocalDir <dir> -Command Push
```

## What a create does

For each selected path, immediately before any network create step:

1. Re-hash LOCAL and refuse if the file changed since `Plan`.
2. `GET /file` the destination. **404** means the path is still absent. Any
   other outcome refuses without uploading, moving, or `PUT`ting.

Then, in order:

1. `POST /upload-url` with `{ "declaredSize": <positive int> }` only.
2. Presigned `PUT` of staging bytes (no Studio auth). Empty local files upload
   one placeholder byte; the final `PUT /file` restores exact bytes.
3. `POST /upload-adopt` with `{ "uploadId", "name" }` using a unique
   `rundot-sync-<guid>.txt` basename.
4. `POST /move` from the adopt response `path` onto the planned path.
5. `PUT /file` with exact local text and echo-verify the response hash.

BASE gains the path only after the `PUT` echo succeeds. There is no remote
backup for a create (nothing existed to copy).

## Confirmation

Text creates get their own `yes` prompt after overwrites and before deletes.
A declined create, or a non-interactive run without `-ForcePush`, changes
nothing: no upload, no move, no `PUT`, no backup set, no journal record.

## Refused paths

Reserved roots (`.git`, `.gitignore`, `.rundot-sync`, `.rundot`) and
directory-shaped destinations are not applicable in `Plan` and are refused
again at `Push` selection. The server does not uniformly guard reserved paths;
the client rule is load-bearing ([path-safety.md](path-safety.md)).

## Failure behavior

| Failure | Result |
| --- | --- |
| Destination occupied before create | Refuse before upload |
| `POST /move` returns `409` | Refuse; destination bytes unchanged |
| Move succeeded, `PUT` or echo failed | Abort; BASE unchanged; remote may hold staging bytes |
| Adopt succeeded, move failed | Best-effort delete of staging under `/uploads/rundot-sync-…` only |

## Related contracts

- Evidence and byte semantics: [text-create-protocol.md](text-create-protocol.md).
- Overwrite-only `PUT /file`: [text-write-protocol.md](text-write-protocol.md).
- Upload and move evidence: [binary-upload-protocol.md](binary-upload-protocol.md), [delete-rename-protocol.md](delete-rename-protocol.md).
- Safe push overview: [push.md](push.md).
