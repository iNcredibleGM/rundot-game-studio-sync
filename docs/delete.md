# Delete remote files

`Push` is the only command that removes a remote file. It applies a
`deleteRemoteCandidate` row (`BASE=A LOCAL=— REMOTE=A`) from a verified plan
artifact, using the documented `DELETE /api/projects/{id}/file` route.

A delete candidate means LOCAL no longer has the path while REMOTE still matches
the last verified shared state. REMOTE owns no change, so removing it destroys
nothing that was not already gone locally.

`Push` never deletes LOCAL files, never creates remote files, and never uploads
binaries. Text creates, binary placement, conflict clobber, and rename
detection stay out of scope.

```powershell
.\game-studio-sync.ps1 -ProjectId <id> -LocalDir <dir> -Command Plan
.\game-studio-sync.ps1 -ProjectId <id> -LocalDir <dir> -Command Push
.\game-studio-sync.ps1 -ProjectId <id> -LocalDir <dir> -Command Push -ForcePush
```

## Why the guard is client-side

The delete route is **unversioned**. `GET /files` exposes only `path`, `type`,
and `size`; there is no ETag, no revision field, and no `updatedAt`, and a
`DELETE` carrying `If-Match` is **ignored** — even a malformed value returned
`200` and removed the file ([delete-rename-protocol.md](delete-rename-protocol.md)).
The server therefore cannot be asked to "remove this only if it is still the
file I saw."

Every guard is therefore built here, immediately before the request:

1. Re-read the remote bytes and compare them to the plan row's
   `expectedRemoteHash`.
2. Copy those exact bytes into `.rundot-sync/backups/<timestamp>/`.
3. Send `DELETE`.
4. Prove the path is gone by re-reading `GET /files`.

A `200` is not the proof. The proof is that the path disappeared from the file
list, which is the same standard the protocol investigation used.

## What a run does

1. **BASE gate.** `Resolve-RundotSyncPlanBase` runs **before** authentication.
   Push has no untrusted mode: `-AllowNoBase` is refused.
2. **Plan artifact.** `Read-PlanArtifact` loads `.rundot-sync/last-plan.json`.
   A missing or malformed artifact refuses before authentication.
3. **Authentication.** The shared token flow used by every command.
4. **LOCAL.** `Get-LocalManifest` inventories the workspace by exact bytes.
5. **REMOTE.** `Get-StableRemoteSnapshot` captures a torn-read-protected
   snapshot ([remote-snapshot.md](remote-snapshot.md)).
6. **Fingerprint gates.** The artifact is compared to the live BASE, LOCAL
   manifest hash, and REMOTE manifest hashes. Any drift refuses the whole run.
7. **Select.** A delete row is selected only when it is still a clean delete
   live: LOCAL still absent, REMOTE still equal to BASE, and
   `expectedRemoteHash` matching. The route rules are re-checked against the
   live remote list rather than trusted from the artifact.
8. **Confirm.** Overwrites and deletes each get their own confirmation. Both
   confirmations are collected before any backup or mutation.
9. **Back up.** Every remote original that will be replaced **or deleted** is
   copied into a backup set first. A backup failure aborts before any `DELETE`.
10. **Apply.** For each delete path: re-read remote and verify
    `expectedRemoteHash`, `DELETE`, then verify the path is absent from
    `GET /files`.
11. **Update BASE.** After every delete is verified, the deleted path is
    dropped from BASE.
12. **Journal and prune.** Metadata-only records are appended, then old backup
    sets are pruned best-effort.

## Applicable rows

| BASE | LOCAL | REMOTE | Status | Push |
| --- | --- | --- | --- | --- |
| A | — | A | `deleteRemoteCandidate` | applies |

Only a `deleteRemoteCandidate` row the plan marked `applicable` may be applied.
`Push` re-classifies it live and refuses the whole run if it is no longer a
clean delete.

## Refused paths

Two path shapes are refused before any request. Neither is a server-side
protection: the protocol record shows a directory-shaped path returns the same
`404` as an absent path, and the server accepted a move onto `/.rundot-sync/`
and `/.rundot/`, so the reserved-path rule is load-bearing.

| Path shape | Why it is refused |
| --- | --- |
| Reserved root (`.git`, `.gitignore`, `.rundot-sync`, `.rundot`) | A delete must never touch sync state or repository metadata. |
| Directory-shaped (a prefix of a listed remote file) | This route deletes exactly one file. A directory-shaped `404` is not a recursive delete and must not be read as permission. |

A refused path keeps its `deleteRemoteCandidate` status in the report, is not
applicable in the plan artifact, and carries the reason it was refused. It is
never silently skipped.

## Confirmation and `-ForcePush`

If any remote file would be deleted, Push prints the count and **every path**,
and requires the whole word `yes` before continuing. The delete confirmation is
separate from the overwrite confirmation, so accepting an overwrite does not
accept a delete. Anything else cancels: no `DELETE` runs, no backup set is
created, BASE does not move, and no journal record is written.

`-ForcePush` (and its `-ConfirmPush` alias) skips both prompts. It never skips a
backup, and it never bypasses the live hash guard or the path-shape refusal.
Force is not a way to disable safety; it is a way to run unattended.

With deletes to make and no `-ForcePush` and no console to confirm on, Push
**fails closed**: it aborts rather than deleting without consent.

### Concurrent-delete guard

Immediately before each `DELETE`, Push re-reads the remote bytes and compares
them to the plan row's `expectedRemoteHash`. If REMOTE changed since `Plan`,
Push aborts without deleting that path. `-ForcePush` does not override this,
because it is a correctness check rather than a preference.

## Idempotency: a 404 is not a new failure

The effect of a delete is idempotent even though the status is not. A first
`DELETE` returns `200`; a second on the same path returns `404` with a
`text/plain` `not found` body.

A `404` therefore means "the path is already absent", not "the delete failed".
Push treats it as success **only when the postcondition holds**: the path must
also be gone from `GET /files`. A `404` whose path is still listed is a real
failure, not a silent success.

## Backups

Before the first `DELETE`, every remote original that will be removed is copied
to:

```text
.rundot-sync/backups/<timestamp>/<canonical-path>
```

`<canonical-path>` is the same `/`-separated NFC identity used everywhere else
([path-safety.md](path-safety.md)), so a deleted file restores by a plain file
copy back into the workspace. The copy is verified: it is written to a
temporary file, re-hashed against the live `GET` bytes, and only then renamed
into place.

This is the only recovery path for a delete. Studio does not keep a version
history for the route, so a delete with no backup is unrecoverable.

Push stores the **previous remote bytes** locally. It never backs up LOCAL,
because Push never writes LOCAL. If the push cannot complete, the backup set is
kept.

### Retention

After a successful push, old backup sets are pruned best-effort, keeping the
union of:

- the last 10 backup sets, and
- every set from the last 7 days

Whichever gives more recovery. The in-flight set is never pruned, and a
directory that is not a recognized backup set is never touched. Pull and Push
share the same backup root.

## BASE update

BASE records the last verified shared state, so it moves only after every
delete is verified:

1. stable REMOTE snapshot
2. plan fingerprint gates
3. live selection
4. both confirmations
5. back up every remote original
6. per-path re-read, `DELETE`, and absence verify
7. **drop** the deleted path from BASE

A deleted path is dropped rather than retained as a tombstone. The path is gone
from both LOCAL and REMOTE, so keeping a stale entry would only make a later
identical re-create in Studio classify as another delete candidate instead of a
download. Published overwrites are still overlaid additively; only deleted
paths are removed.

If any required step fails, the previous BASE remains authoritative. A failed
push never partially updates BASE.

## Journal

Every mutating push appends metadata-only records to
`.rundot-sync/journal.jsonl`, one compact JSON object per line, UTF-8 with no
BOM:

```json
{"timestamp":"<ISO-8601 UTC>","event":"push","status":"success","projectId":"<id>","planId":"<GUID>","backupSet":"<name>","applied":1,"overwritten":1,"deleted":1,"skipped":3,"baseUpdated":true}
{"timestamp":"<ISO-8601 UTC>","event":"push-delete","status":"success","projectId":"<id>","planId":"<GUID>","backupSet":"<name>","path":"src/gone.ts"}
```

A failed push still journals a `push` record with `status: "failed"`,
`baseUpdated: false`, the counts that did complete, a `backupSet` name when one
was created, and a reason.

The journal records **metadata only**: paths relative to the workspace, counts,
and set names. It never records file contents, access tokens, refresh tokens, or
`Authorization` headers. Fields are written from a fixed allowlist, and an
absolute path is refused rather than recorded.

## Report

The report prints applied paths (marked `overwrite`), deleted paths (marked
`delete`), skipped paths with reasons, a summary, the backup root, and the two
closing lines:

```text
Push writes REMOTE only. It never changes LOCAL files.
WARNING: This tool uses unofficial remote API routes that may change.
```

## Failure behavior

| Failure | Result |
| --- | --- |
| Missing BASE | Refuse before authentication; `-AllowNoBase` is rejected |
| Missing `last-plan.json` | Refuse before authentication |
| Expired or stale plan fingerprints | Refuse before any request |
| Row no longer a clean delete | Refuse the whole run |
| Reserved or directory-shaped path | Refuse that path; never send `DELETE` |
| Delete declined | Abort, no `DELETE`, no backup set, no journal record, old BASE |
| Delete with no confirmation possible | Fail closed, no `DELETE` |
| Backup failure | Abort before any `DELETE`; old BASE |
| Remote hash mismatch on re-read | Refuse before that `DELETE` |
| `DELETE` returns `404` and the path is absent | Success: already gone |
| `DELETE` returns `404` and the path is still listed | Failure; BASE unchanged |
| `200` but the path is still listed | Failure: the absence proof failed |
| BASE update fails | Journaled as failed; old BASE remains authoritative |
| Retention failure | Ignored; a successful push is never failed by pruning |

## Related contracts

- The classifier and its status vocabulary: [classifier.md](classifier.md).
- Plan artifact shape and applicability: [plan.md](plan.md).
- The delete route evidence: [delete-rename-protocol.md](delete-rename-protocol.md).
- Publishing text overwrites: [push.md](push.md).
- BASE ownership, layout, and atomic writes: [base-schema.md](base-schema.md).
- Canonical paths, safety, and ignores: [path-safety.md](path-safety.md).

Unit coverage lives in `tests/RemoteDelete.Tests.ps1` (URI shape, reserved and
directory-shaped refusal, absence proof), `tests/Push.Tests.ps1` (delete
selection, confirmation, backup, apply, BASE drop, journal), and
`tests/Journal.Tests.ps1` (the `deleted` field and `push-delete` records), and
requires no network.
