# Safe Push

`Push` is the only command that writes to REMOTE. It consumes the last `Plan`
artifact, re-verifies every fingerprint, and applies three classifications:
a clean utf8 text overwrite via documented `PUT /file`, a utf8 text create via
the documented upload + move + `PUT /file` place sequence, and a
`deleteRemoteCandidate` via documented `DELETE /file`.

`Push` never changes LOCAL files and never uploads binaries
([classifier.md](classifier.md), [text-write-protocol.md](text-write-protocol.md),
[text-create.md](text-create.md), [delete.md](delete.md)).

```powershell
.\game-studio-sync.ps1 -ProjectId <id> -LocalDir <dir> -Command Plan
.\game-studio-sync.ps1 -ProjectId <id> -LocalDir <dir> -Command Push
.\game-studio-sync.ps1 -ProjectId <id> -LocalDir <dir> -Command Push -ForcePush
```

## What a run does

1. **BASE gate.** `Resolve-RundotSyncPlanBase` runs **before** authentication
   ([init.md](init.md)). Push has no untrusted mode: without a verified BASE
   there is no shared state to push against, so `-AllowNoBase` is refused.
2. **Plan artifact.** `Read-PlanArtifact` loads `.rundot-sync/last-plan.json`.
   A missing or malformed artifact refuses before authentication.
3. **Authentication.** The shared token flow used by every command.
4. **LOCAL.** `Get-LocalManifest` inventories the workspace by exact bytes.
5. **REMOTE.** `Get-StableRemoteSnapshot` captures a torn-read-protected
   snapshot ([remote-snapshot.md](remote-snapshot.md)).
6. **Fingerprint gates.** The engine compares the artifact to the live BASE,
   LOCAL manifest hash, and REMOTE manifest hashes. Any drift refuses the
   whole run.
7. **Select.** An applicable `upload` row that is still a clean utf8 text
   overwrite or create, or an applicable `deleteRemoteCandidate` row that is
   still a clean remote delete, may be published. Every other plan row is
   reported in `SKIPPED` with a reason.
8. **Confirm.** If any publishable row remains, Push prints the remote
   overwrite list, then the create list, then the delete list, and requires
   the whole word `yes` for each. All confirmations are collected before any
   backup or mutation.
9. **Back up.** Every remote original that will be replaced **or deleted** is
   copied into a backup set first. A backup failure aborts the push before any
   `PUT` or `DELETE`.
10. **Apply.** For each selected overwrite: re-hash LOCAL, `GET` remote, verify
    `expectedRemoteHash`, `PUT` utf8 text, echo-verify the response hash. For
    each selected create: prove the path is absent, run the upload + move +
    `PUT /file` sequence, echo-verify. For each selected delete: re-read remote
    and verify `expectedRemoteHash`, `DELETE`, then prove the path is absent
    from `GET /files`.
11. **Update BASE.** After every write, create, and delete succeeds, BASE is overlaid
    additively with the published local identities, and each deleted path is
    **dropped** from BASE.
12. **Journal and prune.** Metadata-only records are appended, then old backup
    sets are pruned best-effort.

## Allowed automatic remote writes

Three classifications may be published:

| BASE | LOCAL | REMOTE | Status | Push |
| --- | --- | --- | --- | --- |
| A | B | A | `upload` (utf8 text overwrite) | applies |
| — | A | — | `upload` (utf8 text create) | applies |
| A | — | A | `deleteRemoteCandidate` | applies |

`BASE=A LOCAL=B REMOTE=A` means LOCAL moved on while REMOTE still matched the
last verified shared state. REMOTE owns no change, so nothing is lost on Studio.

`BASE=A LOCAL=— REMOTE=A` means LOCAL no longer has the path while REMOTE still
matches the last verified shared state. Removing it destroys nothing that was
not already gone locally. A delete is applied with the documented `DELETE /file`
route and its own client-side guard; see [delete.md](delete.md).

## Must not publish

| BASE | LOCAL | REMOTE | Status | Push |
| --- | --- | --- | --- | --- |
| — | A | — | `upload` (text create) | applies |
| — | A | — | `upload` (binary) | skipped: binary blocked |
| A | A | B | `download` | skipped: Push never downloads |
| A | B | C | `conflict` | skipped: no safe direction |
| A | B | B | `synchronized-change` | skipped: both sides already agree |
| A | — | A | `deleteRemoteCandidate` (reserved or directory-shaped path) | skipped: route refuses it |
| any | any | any | `ignored` | skipped: out of sync scope |
| text ↔ binary | | | `conflict` | skipped: `KindChange` |

Every skipped path is printed with its status and a reason. A skipped path is
never a silent no-op.

The plan artifact may mark utf8 text overwrites, utf8 text creates, and
route-allowed remote deletes as `applicable: true` ([plan.md](plan.md)). Even when a row is
applicable in the artifact, Push re-classifies it live and refuses the whole run
if it is no longer the clean action it was planned as.

## Confirmation and `-ForcePush`

If any remote text file would be overwritten, Push prints the count and the
paths, and requires the whole word `yes` before continuing. If any remote text
file would be created, Push prints a separate list and requires `yes` again. If
any remote file would be deleted, Push prints a third list and requires `yes`:
accepting an overwrite never accepts a create or delete. Anything declined cancels the
run: no `PUT` or `DELETE` runs, no backup set is created, BASE does not move,
and no journal record is written.

`-ForcePush` skips both prompts. It never skips a backup, and it never bypasses
the concurrent-edit guard, the live hash guard, or the path-shape refusal.
Force is not a way to disable safety; it is a way to run unattended.

`-ConfirmPush` is a skip-prompt alias for `-ForcePush`, kept so existing
examples still work.

With overwrites or deletes to make and neither `-ForcePush` nor `-ConfirmPush`
nor a console to confirm on, Push **fails closed**: it aborts rather than
mutating without consent.

### Concurrent-edit guard

Immediately before each `PUT`, Push re-hashes the local file and compares it to
the plan row. If the file changed since `Plan`, Push aborts without writing
that path. The remote hash is also re-checked with a live `GET` immediately
before each `PUT`. `-ForcePush` does not override this, because it is a
correctness check rather than a preference.

## Backups

Before the first `PUT`, every remote original Push is about to replace is copied
to:

```text
.rundot-sync/backups/<timestamp>/<canonical-path>
```

`<canonical-path>` is the same `/`-separated NFC identity used everywhere else
([path-safety.md](path-safety.md)), so a backup restores by a plain file copy.

The copy is verified: the backup is written to a temporary file, re-hashed
against the live `GET` bytes, and only then renamed into place. A failed backup
leaves no partial file, and a failed backup aborts the push before any `PUT`.

Push stores the **previous remote bytes** locally. It never backs up LOCAL,
because Push never writes LOCAL.

If the push cannot complete, the backup set is kept so the overwritten remote
originals can still be recovered. Push does not `PUT` backup bytes back to
Studio automatically; recovery is a plain file copy out of the backup set when
you choose to restore.

### Retention

After a successful push, old backup sets are pruned best-effort, keeping the
union of:

- the last 10 backup sets, and
- every set from the last 7 days

Whichever gives more recovery. The set created by the in-flight push is never
pruned, and a directory that is not a recognized backup set is never touched.
Pull and Push share the same backup root.

The backup root is printed after every mutating push.

## Journal

Every mutating push appends metadata-only records to
`.rundot-sync/journal.jsonl`, one compact JSON object per line, UTF-8 with no
BOM:

```json
{"timestamp":"<ISO-8601 UTC>","event":"push","status":"success","projectId":"<id>","planId":"<GUID>","backupSet":"<name>","applied":1,"overwritten":1,"skipped":3,"baseUpdated":true}
{"timestamp":"<ISO-8601 UTC>","event":"push-backup","status":"success","projectId":"<id>","planId":"<GUID>","backupSet":"<name>","path":"src/a.ts"}
```

A failed push still journals a `push` record with `status: "failed"`,
`baseUpdated: false`, a `backupSet` name when one was created, and a reason, so
a mutating run is always accountable.

The journal records **metadata only**: paths relative to the workspace, counts,
and set names. It never records file contents, access tokens, refresh tokens, or
`Authorization` headers. Fields are written from a fixed allowlist, and an
absolute path is refused rather than recorded.

`Pull` and `Push` are the writers of the journal. A cancelled confirmation and
a no-op push write no record. The journal lives under `.rundot-sync/`, which is
in the default ignore set, so it is never an upload candidate.

## BASE update

BASE records the last verified shared state, so it moves only after every
selected `PUT` has echo-verified:

1. stable REMOTE snapshot
2. plan fingerprint gates
3. live selection
4. confirmation
5. back up every remote original
6. per-file `GET` + `PUT` + echo verify
7. additive overlay onto the existing BASE entries

The update is **additive**, like `Pull`: existing BASE entries are preserved
and only published paths are overlaid with the identity re-hashed from LOCAL.
BASE is not a tombstone log, so nothing silently drops out.

If any required step fails, the previous BASE remains authoritative. A failed
`Push` never partially updates BASE ([#17](https://github.com/iNcredibleGM/rundot-game-studio-sync/issues/17)).

## Report

The report prints applied paths (marked `overwrite`), skipped paths with
reasons, a summary, the backup root, and the two closing lines:

```text
Push writes REMOTE only. It never changes LOCAL files.
WARNING: This tool uses unofficial remote API routes that may change.
```

Push is not a dry run, so it does not print the `Plan`/`Status` closing lines
([plan.md](plan.md)). A no-op push reports that no publishable text overwrite
remains and that BASE was not updated.

## Failure behavior

| Failure | Result |
| --- | --- |
| Missing BASE | Refuse before authentication; `-AllowNoBase` is rejected |
| Missing `last-plan.json` | Refuse before authentication |
| Expired or stale plan fingerprints | Refuse before any `PUT` |
| Applicable row no longer a clean upload | Refuse the whole run |
| Overwrite declined | Abort, no `PUT`, no backup set, no journal record |
| Overwrite with no confirmation possible | Fail closed, no `PUT` |
| Backup failure | Abort before any `PUT`; old BASE |
| Local file changed since the scan | Refuse before that `PUT` |
| Remote hash mismatch on `GET` | Refuse before that `PUT` |
| `PUT` or echo verify failure | Abort; BASE unchanged; backup set kept |
| BASE update fails | Journaled as failed; old BASE remains authoritative |
| Retention failure | Ignored; a successful push is never failed by pruning |
| Unstable snapshot (3 attempts) | Abort, no writes, old BASE |

## Related contracts

- The classifier and its status vocabulary: [classifier.md](classifier.md).
- Plan artifact shape and applicability: [plan.md](plan.md).
- Documented text `PUT` route: [text-write-protocol.md](text-write-protocol.md).
- BASE ownership, layout, and atomic writes: [base-schema.md](base-schema.md).
- Snapshot stability and the torn-read abort: [remote-snapshot.md](remote-snapshot.md).
- Safe local writes: [pull.md](pull.md).

Unit coverage lives in `tests/Push.Tests.ps1` (selection, apply, BASE update,
orchestration, confirmation, backups, journal), `tests/Backup.Tests.ps1`
(backup sets and retention), `tests/Journal.Tests.ps1` (journal),
and `tests/SyncCli.Tests.ps1` (CLI wiring), and requires no network.
