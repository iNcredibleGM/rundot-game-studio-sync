# Acceptance: v0.1.3 safe pull planner and v0.2.0 Push

This is the acceptance record for the safe pull planner milestone and the Push
write route shipped on the v0.2.0 integration branch. It maps each public gate
to the evidence that proves it, so a reviewer can check the claims without
trusting the release notes.

Two kinds of evidence appear below:

- **Automated** — a named assertion in `tests/*.Tests.ps1`, run by
  `tests/Run-Tests.ps1`. No network and no Pester required.
- **Live** — a manual run against a disposable Studio project. These need a real
  account, so they are performed by hand and are not part of the test suite.

Live steps use a **disposable** project. Never record tokens, refresh tokens,
`%APPDATA%\.rundot\` paths, or file contents from a real project in an issue,
a pull request, or this document.

## Running the automated gates

```powershell
powershell -NoProfile -File .\tests\Run-Tests.ps1
```

The runner dot-sources every `tests/*.Tests.ps1` into one scope and exits
non-zero if any assertion failed. It prints the pass and fail counts.

### Running the final acceptance harness

`tests/Acceptance.ps1` executes the gates below and prints a PASS/FAIL table.
It is named `Acceptance.ps1` rather than `*.Tests.ps1` on purpose, so the fast
unit suite does not pick it up: some gates spawn child processes and hold a file
lock.

```powershell
# Offline gates only: no network, no account
powershell -NoProfile -File .\tests\Acceptance.ps1 -SkipLive

# Everything, against a DISPOSABLE Studio project
powershell -NoProfile -File .\tests\Acceptance.ps1 -ProjectId <id> -LocalDir <dir>
```

The live Pull gates pause and tell you which file to change in Studio, because
automating Studio writes is a non-goal of this milestone. The live Push gates
reuse the Gate 2 local edit after Pull and publish it with documented
`PUT /file` (no extra Studio pause). The harness only ever reads from Studio
for Pull, prints no tokens or file contents, and exits non-zero if any gate
failed.

**The run leaves sensitive state behind, so run it into a throwaway
directory.** A live run creates a `.rundot-sync` workspace, which names every
file in the project, and its `backups/` set holds the **full contents** of any
file `Pull` or `Push` overwrote ([pull.md](pull.md), [push.md](push.md)). This
matters on a public repository.

Cleanup behavior:

- If you omit `-LocalDir`, the harness uses a temporary directory and removes it
  at the end (inside or outside the repository).
- If you pass a `-LocalDir` that **this run created** (missing at start), the
  harness removes it at the end regardless of location.
- A **pre-existing** `-LocalDir` you pointed at is always left in place and
  reported, because it now contains sensitive state.
- `-KeepWorkspace` leaves everything in place for inspection.
- The scratch directory used for offline lock tests is always removed unless
  `-KeepWorkspace` was asked for.

`.gitignore` covers `.rundot-sync/` in this repository, but that is a backstop,
not a license to leave workspace state lying around.

## Gate map

| # | Gate | Evidence | Kind |
| --- | --- | --- | --- |
| 1 | `Run-Tests.ps1` green | Runner output: 0 failed, exit code 0 | Automated |
| 2 | Init, one local edit → one upload, zero invented deletes | Three-way table + live check | Both |
| 3 | One remote change → download or conflict | Three-way table + live check | Both |
| 4 | Pull a clean remote-only change; backup exists and restores by copy | Backup tests + live check | Both |
| 5 | Case collision hard-fails | `tests/Paths.Tests.ps1` | Automated |
| 6 | Unstable snapshot retries/aborts | `tests/Snapshot.Tests.ps1` + harness gate 6 | Automated |
| 7 | Unreadable local file aborts Plan | `tests/Manifest.Tests.ps1` + harness gate 7a/7b | Automated |
| 8 | Plan without BASE refuses | `tests/SyncPlan.Tests.ps1`, `tests/Workspace.Tests.ps1` | Automated |
| 9 | Plan shows `expiresAt` | `tests/SyncPlan.Tests.ps1` | Automated |
| 10 | Mutation grep allows only the documented write routes | `tests/NoRemoteMutation.Tests.ps1` + harness gate 10 | Automated |
| 11 | Push without force refuses in a non-interactive run | `tests/Push.Tests.ps1` + live check | Both |
| 12 | Push `-ForcePush` applies with remote backup and BASE update | `tests/Push.Tests.ps1` + live check | Both |
| 13 | Push journals success and `push-backup` without secrets | `tests/Journal.Tests.ps1`, `tests/Push.Tests.ps1` + live check | Both |

### 1. Test suite green

Windows PowerShell 5.1 compatibility is the baseline. `tests/Run-Tests.ps1`
requires no Pester and no network for the unit files.

### 2. One local edit produces exactly one upload candidate, and no invented deletes

Editing one tracked file in place, leaving BASE and REMOTE untouched, is the
`A / B / A` row of the three-way table:

| Evidence | Location |
| --- | --- |
| `A / B / A` classifies as `upload` | `tests/SyncEngine.Tests.ps1`, three-way table |
| A text overwrite keeps `status: upload` and is `applicable: true`; a text create is `applicable: false` | `tests/SyncPlan.Tests.ps1`, publish policy |
| A path present in BASE and LOCAL is never a delete candidate | `tests/SyncEngine.Tests.ps1`, deletion cases |

**Zero invented deletes** is structural, not incidental: `deleteRemoteCandidate`
requires LOCAL to be genuinely absent (`A / - / A`). An edit in place cannot
reach that row, so an unchanged-but-edited project cannot produce a delete
candidate. A delete candidate is applied only by a confirmed `Push` with its own
confirmation, a client-side hash guard, and a backup first ([delete.md](delete.md));
`Pull` never deletes anything (see gate 10 and the non-goals).

**Live check:** initialize a disposable project with `Init -InitMode FromRemote`,
edit one file, run `Plan`. Expect exactly one `UPLOAD` row for that path, no
`STAGED DELETES` section, and no other path moving.

### 3. One remote change classifies as download or conflict

The distinction depends on whether the local copy still matches BASE:

| Situation | Row | Evidence |
| --- | --- | --- |
| LOCAL still matches BASE, REMOTE moved on | `A / A / B` → `download` | `tests/SyncEngine.Tests.ps1` |
| LOCAL also changed | `A / B / C` → `conflict` | `tests/SyncEngine.Tests.ps1` |

A `download` is the only remotely-changing status marked applicable in this
milestone. A `conflict` is never applicable and always carries a reason.

**Live check:** change one file in Studio only, run `Plan`. Expect `DOWNLOAD` if
your local copy still matches BASE, otherwise `CONFLICT`.

### 4. Pull applies a clean remote-only change, and the backup restores by copy

| Property | Evidence |
| --- | --- |
| A clean download is applied | `tests/Pull.Tests.ps1` selection cases |
| The original is copied before any overwrite | `tests/Pull.Tests.ps1`, `tests/Backup.Tests.ps1` |
| The backup is verified (temp write, re-hash, then rename) | `tests/Backup.Tests.ps1` |
| Restoring the backup puts the original bytes back | `tests/Backup.Tests.ps1`, restore cases |
| A failed restore leaves the destination untouched | `tests/Backup.Tests.ps1` |
| The backup set is never itself sync content | `tests/Backup.Tests.ps1`, `tests/Journal.Tests.ps1` |

Backups land at `.rundot-sync/backups/<timestamp>/<canonical-path>`, using the
same `/`-separated path identity as everywhere else. That is what makes the
restore a plain file copy.

**Live check:** with a clean remote-only change pending, run `Pull`. Confirm the
printed backup root, then copy the file back out of
`.rundot-sync/backups/<timestamp>/` and verify the original content returns.
Confirm BASE was updated only after the write was verified.

### 5. Case collision hard-fails

`Foo.ts` and `foo.ts` in one path set is an identity ambiguity, not two files.
`Assert-SafeSyncPathSet` hard-fails the whole run rather than picking one, so a
partial tree can never be mistaken for deletions. Covered in
`tests/Paths.Tests.ps1`, alongside the Unicode NFC/NFD collision case.

### 6. Unstable snapshot retries, then aborts

`tests/Snapshot.Tests.ps1` covers: an add, a remove, a size change, and an
encoding change each triggering a retry before succeeding; three consecutive
unstable captures aborting; each attempt issuing both `Before` and `After`
list calls; and failed staging being discarded so it can never be promoted.

### 7. An unreadable local file aborts Plan

`tests/Manifest.Tests.ps1` locks a file and asserts that `Get-LocalManifest`
throws rather than returning a partial map. A partial map would later look like
deleted files, so the local inventory fails closed. The same file also covers a
junction aborting the inventory.

The harness splits the CLI half of this gate in two, and the split is
deliberate:

- **7a** runs the real abort: a locked file makes `Get-LocalManifest` throw.
- **7b** asserts source order in `game-studio-sync.ps1`:
  `Get-LocalManifest` runs before `New-RundotSyncPlanAnalysis`, and the failure
  path exits non-zero.

At startup the harness prints the canonical gate map (numbers 1–13) and the
**execution order** for the current run (offline gates first, then live gates
2→9→3→6→4→11–13). Gate numbers are not execution order: 5–10 are Pull-era
offline checks; 11–13 were added for Push without renumbering.

7b is an order assertion rather than a live end-to-end abort because `Plan`
authenticates **before** it reads LOCAL. Triggering the real abort through the
CLI therefore needs a token, and asserting only on the exit code would be a
false pass: `Plan` also exits non-zero when BASE is missing, which would
"prove" this gate for the wrong reason. `tests/SyncCli.Tests.ps1` asserts the
same ordering from the unit suite.

The harness repeats both halves: gate 7a locks a file and asserts the inventory
throws, and gate 7b asserts the CLI ordering. Gate 7b is an ordering assertion
rather than an end-to-end abort, which is a deliberate limit — `Plan`
authenticates **before** it reads LOCAL, so provoking the real abort through the
CLI would need a live token in the test path. Asserting only the exit code would
be worse than useless here, because `Plan` also exits non-zero when BASE is
missing, which would appear to prove this gate for the wrong reason.

### 8. Plan without BASE refuses

Covered in `tests/SyncPlan.Tests.ps1` (refusal, and no artifact left behind) and
`tests/Workspace.Tests.ps1` (the gate itself, the untrusted banner, and the rule
that `-AllowNoBase` never launders an ownership mismatch). The gate runs before
authentication, so a workspace that cannot plan never asks for a token. `Pull`
refuses `-AllowNoBase` entirely.

### 9. Plan shows `expiresAt`

`tests/SyncPlan.Tests.ps1` asserts the artifact's `expiresAt` is after
`createdAt`, that an explicit TTL controls it, and that the console report
prints it so expiry is visible rather than buried in the JSON.

### 10. Mutation grep allows only the documented write routes

`tests/NoRemoteMutation.Tests.ps1` scans `game-studio-sync.ps1`,
`game-studio-export.ps1`, and `lib/**/*.ps1` for Studio write helpers: HTTP
`PUT` outside `lib/RemoteWrite.ps1`, HTTP `DELETE` outside
`lib/RemoteDelete.ps1`, `upload-url`, `upload-adopt`, `/move`, reachability to
the non-product `StudioProbe`, and any `Set-*` / `Remove-*` function in
`lib/RemoteApi.ps1`. Two documented write routes exist: `PUT /file` in
`lib/RemoteWrite.ps1` and `DELETE /file` in `lib/RemoteDelete.ps1`
([push.md](push.md), [delete.md](delete.md)).

The plan layer enforces publish policy at runtime:
`tests/SyncPlan.Tests.ps1` asserts that only a utf8 text overwrite and a
route-allowed remote delete may be applicable among remote-mutating rows, that
every blocked remote-mutating row carries a reason, and that a download is not
remote-mutating.

### 11. Push without force refuses in a non-interactive run

| Property | Evidence |
| --- | --- |
| Applicable uploads require confirmation or `-ForcePush` | `tests/Push.Tests.ps1`, confirmation cases |
| A declined or non-interactive run changes nothing | `tests/Push.Tests.ps1`, cancelled run |
| No backup set, journal, or BASE move on decline | `tests/Push.Tests.ps1`, orchestrator cases |

**Live check:** after Gates 2–4 and a fresh `Plan`, run `Push` in a child
process with `-NonInteractive` and without `-ForcePush`. Expect a non-zero
exit, unchanged BASE `capturedAt`, no new backup set, and no new `push` /
`push-backup` journal records. The harness uses `-NonInteractive` so the child
cannot prompt for `yes` on the parent console.

### 12. Push `-ForcePush` applies with remote backup and BASE update

| Property | Evidence |
| --- | --- |
| A clean text overwrite is applied via `PUT /file` | `tests/Push.Tests.ps1`, apply cases |
| The remote original is copied before any PUT | `tests/Push.Tests.ps1`, backup-before-write |
| The backup holds remote bytes, not the local publish payload | `tests/Push.Tests.ps1`, backup content |
| BASE moves only after verified apply | `tests/Push.Tests.ps1`, BASE update cases |

**Live check:** run `Push -ForcePush` on a **fresh** post-decline `Plan` (the
harness re-plans before gate 12). Expect `applied ≥ 1`, `BASE updated: true`, a
printed backup root and this-run set, and a backup copy that restores by plain
file copy and does not match the local file bytes.

### 13. Push journals success and `push-backup` without secrets

| Property | Evidence |
| --- | --- |
| A successful push writes one `push` success record | `tests/Push.Tests.ps1`, journal cases |
| Each backed-up path writes a `push-backup` record | `tests/Push.Tests.ps1`, journal cases |
| Journal lines never carry tokens or file contents | `tests/Journal.Tests.ps1`, `tests/Push.Tests.ps1` |

**Live check:** after Gate 12, read `.rundot-sync/journal.jsonl` (do not paste
it). Expect at least one `push` record with `status: success` and one
`push-backup` record per backed-up path, with no credential or `"content"`
patterns in the raw file.

## What this milestone deliberately does not do

Confirmed absent, not merely undocumented:

- No remote create except the documented utf8 text overwrite route (`Push`).
- No binary upload or adopt.
- No automatic local deletion. `deleteLocalCandidate` leaves the file in place.
  A remote delete happens only through a confirmed `Push` delete
  ([delete.md](delete.md)).
- No `.rundotignore`. The default ignore set is fixed and documented.
- No newline or encoding normalization; text is preserved byte-for-byte.
- No FileSystemWatcher, device IDs, or multi-machine BASE. One initialized
  workspace belongs to one project and one folder.

Direction beyond this milestone is in [ROADMAP.md](../ROADMAP.md).

## Related contracts

- Initializing a workspace: [init.md](init.md)
- Dry-run planning and the artifact: [plan.md](plan.md)
- Applying remote-only changes: [pull.md](pull.md)
- Publishing local text overwrites: [push.md](push.md)
- BASE ownership and atomic writes: [base-schema.md](base-schema.md)
- Canonical paths, safety, and ignores: [path-safety.md](path-safety.md)
- Torn-read protection: [remote-snapshot.md](remote-snapshot.md)
- Classifier vocabulary: [classifier.md](classifier.md)
- Raw export destination rules: [export.md](export.md)
