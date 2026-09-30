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
in `Plan` and are refused again at `Push` selection. Binaries **over Studio's
read limit** are refused for **replaces** but allowed for **creates** — see
below.

## Studio's read limit (2,000,000 bytes)

`GET /file` refuses any payload over **2,000,000 bytes** with HTTP 413
`file too large to view`. That is a property of the read route, not of the place
sequence, and no alternate large-file route exists ([protocol.md](protocol.md)).
A binary over the limit can therefore be **placed** but never **read back** by
`GET /file`.

The write path does not need that read. The presigned object `PUT` returns an
`ETag` that is the **MD5 of the exact stored bytes**, a plain digest even at
50 MB, unchanged by the rename route ([binary-place-protocol.md](binary-place-protocol.md)).
So a **create** is verifiable at any size by comparing the local file's MD5
against that `ETag`.

### Create: published and verified by ETag (#54)

An oversized binary **create** is publishable. The place sequence skips the
read-back and verifies instead against the upload `ETag`, accepted **only**
alongside the checks that already passed:

- the adopt response's recorded path equalled the expected staging path,
- the move landed on the planned destination,
- the recorded size equalled the uploaded byte count,
- the `ETag` is a plain 32-hex MD5 (a multipart `ETag` is refused, never compared),
- and that MD5 equals the local file's MD5.

BASE still records the local **SHA-256**: once the `ETag` has proven the stored
bytes equal the local bytes, the local SHA-256 is the shared identity. MD5 is
weaker than the SHA-256 used elsewhere, so it is used only here and only as one
of those checks.

### Replace: still refused

A binary **replace** over the limit stays refused, because its existing remote
bytes are needed for the pre-overwrite backup and the `expectedRemoteHash` gate,
and `GET /file` cannot return them. The refusal says so specifically rather than
reusing the create reason.

The tool refuses an oversized binary **replace** before any destructive step, at
every layer:

| Layer | Oversize create | Oversize replace |
| --- | --- | --- |
| `Plan` | `applicable: true` (ETag verify) | `applicable: false` with the replace reason |
| `Push` (default) | Selected and published | Throws before any `DELETE` or upload |
| `Push -LocalWins` | Selected and published | Excluded with the reason; the rest continues |
| REMOTE snapshot | Captured as `unverifiable` (path + size, no hash); the rest of the tree still snapshots | (same) |

A pre-existing oversize path on Studio no longer fails the whole snapshot: it is
captured as `unverifiable`, reported under `UNVERIFIABLE`, and never downloaded or
rewritten (#57, [remote-snapshot.md](remote-snapshot.md)). An oversize **replace**
whose path is already oversize on REMOTE is `unverifiable` rather than an
applicable replace, so it is never attempted.

The replace reason names the file's size, the limit, why it cannot work, and what
to do:

```text
'dev/audio/theme.wav' is over Studio's read limit. 3120444 bytes is over Studio's
2000000-byte read limit, and this is a replacement: GET /file returns 413
'file too large to view' above it, so the existing remote bytes cannot be read
for the pre-overwrite backup or the expectedRemoteHash check. An oversize create
is verifiable from the upload ETag, but a replacement is not. Delete the remote
copy first, or exclude this file.
```

### Excluding oversized files

There is no `.rundotignore` parser. Keep an oversized file out of the sync
folder: move it outside the workspace, or leave it out when you build the folder
you point `-LocalDir` at. A path absent from LOCAL is never an upload candidate,
so the rest of the tree syncs normally. A pre-existing oversized path already on
Studio is captured as `unverifiable` and does not block the rest of the project
([remote-snapshot.md](remote-snapshot.md)); it is reported under `UNVERIFIABLE`
so you can delete it on Studio when you choose to.

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
| Local binary **replace** over the 2,000,000-byte read limit | Refuse before any `DELETE` or upload; default `Push` aborts, `-LocalWins` excludes the path |
| Local binary **create** over the read limit | Published and verified from the upload `ETag` (#54) |
| Upload `ETag` is not a plain MD5, or does not match the local MD5 | Refuse after move; BASE unchanged; remote may hold the uploaded bytes |
| Adopt returns a suffixed sibling | Delete sibling when allowed; refuse; BASE unchanged |
| `POST` move returns `409` | Refuse; destination bytes unchanged |
| Move or hash verify fails after move | Abort; BASE unchanged; remote may hold new bytes; the wrapper names the failed check |
| Any step fails | Journal `push` failed with `backupSet` when a set exists |

## Related contracts

- Evidence: [binary-place-protocol.md](binary-place-protocol.md).
- Safe push overview: [push.md](push.md).
