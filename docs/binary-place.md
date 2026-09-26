# Place remote binary files

`Push` is the only command that places a binary at a project path. It applies an
applicable `upload` row with `kind: binary` from a verified plan artifact, using
the documented place sequence in [binary-place-protocol.md](binary-place-protocol.md).

`Push` never merges conflict bytes and never treats a collision-suffixed staging
name as success.

```powershell
.\game-studio-sync.ps1 -ProjectId <id> -LocalDir <dir> -Command Plan
.\game-studio-sync.ps1 -ProjectId <id> -LocalDir <dir> -Command Push
```

## What a place does

For each selected path, immediately before every mutating step the engine
re-verifies plan fingerprints and the live remote hash (or absence) for that
path.

**Create** (`BASE=— LOCAL=A REMOTE=—`):

1. `POST` mint upload with `{ "declaredSize": <positive int> }` only.
2. Presigned `PUT` of exact local bytes (`application/octet-stream`).
3. `POST` adopt with a unique `rundot-sync-<guid>.bin` basename.
4. If adopt records any path other than `/uploads/rundot-sync-<guid>.bin`, delete
   that staging path when it matches the run-stamped pattern, then refuse.
5. `POST` move from the recorded staging path onto the planned path.
6. `GET` the destination and verify base64 SHA-256 matches LOCAL.
7. Prove staging is gone from `GET /files`.

**Replace** (`BASE=A LOCAL=B REMOTE=A`, both binary):

1. Back up REMOTE into `.rundot-sync/backups/<timestamp>/` (backup failure aborts
   before delete or upload).
2. Re-read REMOTE and verify `expectedRemoteHash`.
3. `DELETE` the path and prove absence.
4. Run the create sequence above on the now-absent path.

BASE gains the path only after the final hash verify succeeds.

## Confirmation

Binary creates and replaces share one `yes` prompt after text create and before
delete. The prompt lists every path with `(create)` or `(replace)`. A declined
prompt changes nothing: no backup set, no journal record, BASE unchanged.

## Refused paths

Reserved roots (`.git`, `.gitignore`, `.rundot-sync`, `.rundot`),
directory-shaped destinations, and **empty** local binaries are not applicable
in `Plan` and are refused again at `Push` selection.

## Failure behavior

| Failure | Result |
| --- | --- |
| Adopt returns a suffixed sibling | Delete sibling when allowed; refuse; BASE unchanged |
| `POST` move returns `409` | Refuse; destination bytes unchanged |
| Move or hash verify fails after move | Abort; BASE unchanged; remote may hold new bytes |
| Any step fails | Journal `push` failed with `backupSet` when a set exists |

## Related contracts

- Evidence: [binary-place-protocol.md](binary-place-protocol.md).
- Safe push overview: [push.md](push.md).
