# Safe Pull

`Pull` is the only command in this milestone that writes to LOCAL. It applies
remote-only changes, backs up every file it replaces, and moves BASE only
after the result is verified.

`Pull` never mutates Studio. It is GET-only, like `Init`, `Plan`, and
`Status` ([classifier.md](classifier.md)).

```powershell
.\game-studio-sync.ps1 -ProjectId <id> -LocalDir <dir> -Command Pull
.\game-studio-sync.ps1 -ProjectId <id> -LocalDir <dir> -Command Pull -ForcePull
```

## What a run does

1. **BASE gate.** `Resolve-RundotSyncPlanBase` runs **before** authentication
   ([init.md](init.md)). Pull has no untrusted mode: without a verified BASE
   there is no shared state to pull against, so `-AllowNoBase` is refused.
2. **Authentication.** The shared GET-only token flow.
3. **LOCAL.** `Get-LocalManifest` inventories the workspace by exact bytes.
4. **REMOTE.** `Get-StableRemoteSnapshot` captures a torn-read-protected
   snapshot ([remote-snapshot.md](remote-snapshot.md)). The staged bytes it
   verified are what Pull writes.
5. **Select.** Only a clean download may be applied (see below).
6. **Confirm.** If an existing local file would be replaced, Pull prints the
   count and requires confirmation.
7. **Back up.** Every original that will be replaced is copied into a backup
   set first. A backup failure aborts the pull before anything is written.
8. **Apply.** Each file is written atomically and re-hashed immediately.
9. **Verify and update BASE.** Every applied path is re-hashed against REMOTE.
   Only then is BASE replaced atomically.
10. **Journal and prune.** A metadata-only record is appended, then old backup
    sets are pruned best-effort.

## Allowed automatic local writes

Exactly one classification is applied without asking:

| BASE | LOCAL | REMOTE | Status | Pull |
| --- | --- | --- | --- | --- |
| A | A | B | `download` | applies |

`BASE=A LOCAL=A REMOTE=B` means REMOTE moved on while LOCAL still matched the
last verified shared state. LOCAL owns no change, so nothing is lost.

A remote-only addition (`— / — / A`) is also applied, and needs no
confirmation because there is no existing file to preserve.

## Must not overwrite

| BASE | LOCAL | REMOTE | Status | Pull |
| --- | --- | --- | --- | --- |
| A | B | A | `upload` | skipped: LOCAL change is never overwritten |
| A | B | C | `conflict` | skipped: no safe direction |
| A | B | B | `synchronized-change` | skipped: both sides already agree |
| — | A | A | `synchronized-addition` | skipped: both sides already agree |
| A | — | A | `deleteRemoteCandidate` | reported only |
| A | A | — | `deleteLocalCandidate` | **reported, local file left in place** |
| A | — | — | `settledAbsent` | reported only |
| — | A | — | `upload` | skipped: future push work |
| any | any | any | `ignored` | skipped: out of sync scope |
| text ↔ binary | | | `conflict` | skipped: `KindChange` |

Every skipped path is printed with its status and a reason. A skipped path is
never a silent no-op.

Pull never deletes anything. `deleteLocalCandidate` and
`deleteRemoteCandidate` are classification-only in this milestone
([classifier.md](classifier.md)).

## Confirmation and `-ForcePull`

If any existing differing LOCAL file would be overwritten, Pull prints the
count and the paths, and requires the whole word `yes` before continuing.
Anything else cancels: no file is written, no backup set is created, and BASE
does not move.

`-ForcePull` skips the prompt. It never skips a backup, and it never bypasses
the concurrent-edit guard below. Force is not a way to disable safety; it is a
way to run unattended.

With overwrites to make and neither `-ForcePull` nor a console to confirm on,
Pull **fails closed**: it aborts rather than writing without consent.

### Concurrent-edit guard

Immediately before a file is replaced, Pull re-hashes it and compares that to
the LOCAL manifest it captured for this run. If the file changed in between,
Pull aborts without writing and reports it. `-ForcePull` does not override
this, because it is a correctness check rather than a preference: the file on
disk is no longer the file that was proven to match BASE.

## Backups

Before the first write, every file Pull is about to replace is copied to:

```text
.rundot-sync/backups/<timestamp>/<canonical-path>
```

`<canonical-path>` is the same `/`-separated NFC identity used everywhere else
([path-safety.md](path-safety.md)), so a backup restores by a plain file copy.

The copy is verified: the backup is written to a temporary file, re-hashed
against the original, and only then renamed into place. A failed backup leaves
no partial file, and a failed backup aborts the pull before any overwrite.

If the pull cannot complete, the backup set is kept so the overwritten
originals can still be recovered.

### Retention

After a successful pull, old backup sets are pruned best-effort, keeping the
union of:

- the last 10 pull backup sets, and
- every set from the last 7 days

Whichever gives more recovery. The set created by the in-flight pull is never
pruned, and a directory that is not a recognized backup set is never touched.

The backup root is printed after every mutating pull.

## Journal

Every mutating pull appends metadata-only records to
`.rundot-sync/journal.jsonl`, one compact JSON object per line, UTF-8 with no
BOM:

```json
{"timestamp":"<ISO-8601 UTC>","event":"pull","status":"success","projectId":"<id>","planId":"<GUID>","backupSet":"<name>","applied":1,"overwritten":1,"created":0,"skipped":3,"baseUpdated":true}
{"timestamp":"<ISO-8601 UTC>","event":"pull-backup","status":"success","projectId":"<id>","planId":"<GUID>","backupSet":"<name>","path":"src/a.ts"}
```

A failed pull still journals a `pull` record with `status: "failed"`,
`baseUpdated: false`, and a reason, so a mutating run is always accountable.

The journal records **metadata only**: paths relative to the workspace, hashes,
counts, and set names. It never records file contents, access tokens, refresh
tokens, or `Authorization` headers. Fields are written from a fixed allowlist,
and an absolute path is refused rather than recorded.

`Pull` and `Push` append metadata-only records to the journal. A no-op pull
writes no record. The journal lives under `.rundot-sync/`, which is in the
default ignore set, so it is never an upload candidate.

## BASE update

BASE records the last verified shared state, so it is replaced only after every
required operation has succeeded:

1. stable REMOTE
2. compute Pull actions
3. back up every original
4. apply the confirmed local writes, atomically, each re-hashed as it lands
5. re-hash the final LOCAL: every applied path must match REMOTE
6. atomically replace BASE

The update is **additive**: existing BASE entries are preserved and only
applied paths are overlaid with the identity re-hashed from disk. BASE is not a
tombstone log, so a `deleteLocalCandidate` keeps its entry and no path silently
drops out.

If any required operation fails, the previous BASE remains authoritative.
`Plan`, `Status`, a failed `Init`, a failed `Pull`, and an incomplete snapshot
never update BASE ([base-schema.md](base-schema.md)).

## Report

The report prints applied paths (marked `create` or `overwrite`), skipped paths
with reasons, a summary, the backup root, and the two closing lines:

```text
Pull writes LOCAL only. It never mutates Studio.
WARNING: This tool uses unofficial remote API routes that may change.
```

Pull is not a dry run, so it does not print the `Plan`/`Status` closing lines
([plan.md](plan.md)). A no-op pull reports that LOCAL already matches REMOTE
for every remote-only change and that BASE was not updated.

## Failure behavior

| Failure | Result |
| --- | --- |
| Missing BASE | Refuse before authentication; `-AllowNoBase` is rejected |
| Unstable snapshot (3 attempts) | Abort, no writes, old BASE |
| Overwrite declined | Abort, no writes, no backup set, no journal record |
| Overwrite with no confirmation possible | Fail closed, no writes |
| Local file changed since the scan | Abort, no writes, old BASE |
| Backup failure | Abort before any overwrite; tree untouched, old BASE |
| Write failure partway | Roll back: restore overwritten files, delete files created, prune created directories, old BASE |
| Written bytes do not match REMOTE | Roll back, old BASE |
| BASE update fails | Journaled as failed; old BASE remains authoritative |
| Retention failure | Ignored; a successful pull is never failed by pruning |

Rollback is best effort and runs in reverse order. If a rollback step itself
fails, the original error is still reported and the backup set is kept for
manual recovery.

## Related contracts

- The classifier and its status vocabulary: [classifier.md](classifier.md).
- BASE ownership, layout, and atomic writes: [base-schema.md](base-schema.md).
- Snapshot stability and the torn-read abort: [remote-snapshot.md](remote-snapshot.md).
- Path identity, safety, and ignores: [path-safety.md](path-safety.md).
- `Plan` and `Status` dry runs: [plan.md](plan.md).

Unit coverage lives in `tests/Pull.Tests.ps1` (selection, apply/rollback,
BASE update, orchestration), `tests/Backup.Tests.ps1` (backup sets and
retention), `tests/Journal.Tests.ps1` (journal), and `tests/SyncCli.Tests.ps1`
(CLI wiring), and requires no network.
