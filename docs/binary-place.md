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
directory-shaped destinations, **empty** local binaries, and binaries **over
Studio's read limit** are not applicable in `Plan` and are refused again at
`Push` selection.

## Studio's read limit (2,000,000 bytes)

`GET /file` refuses any payload over **2,000,000 bytes** with HTTP 413
`file too large to view`. That is a property of the read route, not of the place
sequence, and no alternate large-file route exists ([protocol.md](protocol.md)).
A binary over the limit can therefore be **placed** but never **read back**, so
its byte identity can never be verified — the post-move verify would fail and
leave an ambiguous remote state.

The tool refuses an oversized binary **before** any destructive step, at every
layer:

| Layer | Behavior |
| --- | --- |
| `Plan` | A binary create or replace over the limit is `applicable: false` with the read-limit reason |
| `Push` (default) | Throws and refuses the whole run before any `DELETE` or upload |
| `Push -LocalWins` | Excludes that path with the read-limit reason and continues with the rest |
| REMOTE snapshot | Aborts before downloading when the remote manifest lists an oversized file |

The reason names the file's size, the limit, why it cannot work, and what to do:

```text
'dev/audio/theme.wav' is over Studio's read limit. 3120444 bytes is over Studio's
2000000-byte read limit: GET /file returns 413 'file too large to view' above it,
so the bytes could be placed but never read back or verified. Exclude this file
from the sync folder to sync the rest.
```

### Excluding oversized files

There is no `.rundotignore` parser. Keep an oversized file out of the sync
folder: move it outside the workspace, or leave it out when you build the folder
you point `-LocalDir` at. A path absent from LOCAL is never an upload candidate,
so the rest of the tree syncs normally. A pre-existing oversized path already on
Studio blocks every REMOTE read ([remote-snapshot.md](remote-snapshot.md)); the
snapshot abort names the paths so you can delete them on Studio first.

## Recovery when a place fails after move

A failure after `POST /move` (a verify mismatch, or a read that returns 413)
leaves an ambiguous remote state: the destination may hold the new bytes while
BASE still records the old ones. The wrapper message now names the check that
failed, so the report row is actionable (#51):

```text
  dev/audio/theme.wav  [upload]  Binary place failed after move for 'dev/audio/theme.wav'.
  The remote path may hold the new bytes; BASE was not updated. Verify failure:
  Remote request failed with HTTP 413
```

To recover:

1. Re-run `Plan`. It observes REMOTE as it is now; never trust the pre-failure
   plan.
2. If the destination holds bytes you did not intend, restore the pre-move bytes
   from the backup set by plain copy:

   ```powershell
   Copy-Item '.rundot-sync\backups\<timestamp>\<canonical-path>' `
             '<workspace>\<canonical-path>' -Force
   ```

   The backup holds the previous remote bytes under the same canonical path
   ([push.md](push.md)).
3. `Pull` is safe only when the re-`Plan` classifies the path as `download`
   (LOCAL still matches BASE and REMOTE moved on). If it is a `conflict`, choose
   a direction deliberately: `Pull -ForcePull` or `Push -LocalWins` applies that
   choice with a backup.

BASE never moves on a failed place, so the re-`Plan` after restoring is the
source of truth.

## Failure behavior

| Failure | Result |
| --- | --- |
| Local binary over the 2,000,000-byte read limit | Refuse before any `DELETE` or upload; default `Push` aborts, `-LocalWins` excludes the path |
| Adopt returns a suffixed sibling | Delete sibling when allowed; refuse; BASE unchanged |
| `POST` move returns `409` | Refuse; destination bytes unchanged |
| Move or hash verify fails after move | Abort; BASE unchanged; remote may hold new bytes; the wrapper names the failed check |
| Any step fails | Journal `push` failed with `backupSet` when a set exists |

## Related contracts

- Evidence: [binary-place-protocol.md](binary-place-protocol.md).
- Safe push overview: [push.md](push.md).
