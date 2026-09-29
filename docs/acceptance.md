# Acceptance: v0.1.3 pull, v0.2.0 Push, and v0.3.0 binary place

This is the acceptance record for the safe pull planner, the Push write routes,
and binary place. It maps each public gate to the evidence that proves it.

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

### Everything in one shot

`tests/Test-All.ps1` is a thin orchestrator over the three entry points below.
It runs each in a child process, streams the output, and prints one combined
summary:

```powershell
# Offline: unit suite + offline acceptance gates
powershell -NoProfile -File .\tests\Test-All.ps1 -SkipLive

# Everything, against a DISPOSABLE project
powershell -NoProfile -File .\tests\Test-All.ps1 -ProjectId <id>
```

| Phase | Script | Needs a project |
| --- | --- | --- |
| 1 | `tests/Run-Tests.ps1` (unit suite) | no |
| 2 | `tests/Acceptance.ps1 -SkipLive` (offline gates) | no |
| 3 | `tests/Live-RoundTrip.ps1` (live round-trip) | yes |

Exit code is 0 only when every phase that ran passed. A phase that cannot run
is reported `SKIP`, never a silent pass. `-KeepWorkspace` and
`-SkipRemoteCleanup` pass through to phase 3.

`Test-All.ps1` deliberately does **not** run `Acceptance.ps1`'s live gates:
gates 2-4 pause on `Read-Host` for a human Studio edit, so they cannot be
unattended. Phase 3 covers the same up/down/restore ground with no pause.

### Supplying the project id once

The live phase needs a disposable project id. Instead of passing `-ProjectId`
on every run, put it in a local-only config file:

```powershell
Copy-Item .rundot-test.local.example.json .rundot-test.local.json
# then edit .rundot-test.local.json and set your project id
```

```json
{ "projectId": "<your disposable project id>" }
```

Resolution order:

1. `-ProjectId` on the command line (wins)
2. `.rundot-test.local.json` at the repo root
3. the `RUNDOT_TEST_PROJECT_ID` environment variable

`.rundot-test.local.json` is git-ignored (both `.gitignore` and
`.git/info/exclude`), so it is never committed or published. A project id is an
identifier rather than a credential, but it is still not published. The
committed `.rundot-test.local.example.json` is the template, and it carries no
real id.

`tests/Live-RoundTrip.ps1` reads the same config, so it also runs without
`-ProjectId`.

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

### Fully automatic live round-trip

`tests/Acceptance.ps1` pauses for a human Studio edit. When you want an
end-to-end live run with **no manual step at all**, use
`tests/Live-RoundTrip.ps1`. It makes its own Studio-side change, so it runs
setup → up → down → restore → teardown unattended and asserts progress output
at every step:

```powershell
powershell -NoProfile -File .\tests\Live-RoundTrip.ps1 -ProjectId <id>
```

What it does, in order:

1. **Setup.** `Init -InitMode FromRemote` into an empty temp workspace.
2. **Adopt hashing progress.** `Init -InitMode Adopt` on a throwaway tree, the
   case #43 is about (it hashes before printing anything).
3. **Up.** Writes two new utf8 text files, `Plan`, then `Push -ForcePush`
   publishes them through the documented create sequence. A second edit plus
   `Push -ForcePush` exercises the overwrite path, then re-reads Studio to
   confirm the served bytes match.
4. **Down.** Rewrites one probe file **on Studio** using the documented
   `PUT /file` route (acting as a separate client), `Plan`, then
   `Pull -ForcePull`, and confirms the local file now holds the Studio bytes.
5. **Restore.** Confirms the Pull backup set reproduces the pre-pull local
   bytes, and that a plain copy back restores the original hash. Also confirms
   the Push backup set holds the **previous remote** bytes.
6. **Fail-closed.** Locks a local file and confirms `Plan` still aborts with
   non-zero exit *and* still printed the hashing line, so progress never
   softens a failure.
7. **Teardown.** Deletes the probe files from Studio via the documented
   `DELETE /file` route and proves they are gone from `GET /files`, then
   removes the temp workspace.

Everything it creates lives under one GUID probe folder (`sync-live/<id>/`),
so teardown removes exactly what setup made. It never creates a new Studio
write route: it only calls the documented `PUT` / `DELETE` helpers the product
already owns, and it never prints tokens, auth paths, or file contents.

Cleanup behavior:

- The temp workspace and scratch directory are removed at the end, including on
  an early abort.
- `-KeepWorkspace` leaves them in place for inspection.
- `-SkipRemoteCleanup` leaves the probe files on Studio (for debugging a failed
  teardown) instead of deleting them.


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
| 14 | Binary create via documented place sequence | `tests/Acceptance.ps1` gate 14 + live check | Both |
| 15 | Binary replace with remote backup | `tests/Acceptance.ps1` gate 15 + live check | Both |
| 16 | Host-visible progress for hashing, download, and publish | `tests/Progress.Tests.ps1`, `tests/Manifest.Tests.ps1`, `tests/Snapshot.Tests.ps1` + `tests/Live-RoundTrip.ps1` | Both |

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

### 14. Binary create via documented place sequence

| Property | Evidence |
| --- | --- |
| Plan marks one applicable binary `upload` for a new path | `tests/SyncPlan.Tests.ps1`, `tests/Acceptance.ps1` gate 14 |
| Non-interactive `Push` refuses before mutation | gate 14a |
| `Push -ForcePush` places bytes at the planned path | gate 14b |
| Journal records `push-binary` | gate 14b |

**Live check:** run the full harness on a disposable project. Before gate 2, the harness deletes unpublished files it previously wrote under `sync-acceptance/` so a re-run is not an extra upload. After gates 2–13, no other upload rows should remain. Gate 14 writes `sync-acceptance/acceptance-*.bin` (bytes that are not valid UTF-8),
plans, declines a non-interactive push, then `-ForcePush` creates the file.
Expect `BINARY` / `(binary create)` in the report, `BASE updated: true`, and a
`push-binary` journal line for that path.

### 15. Binary replace with remote backup (via `Push -LocalWins`)

| Property | Evidence |
| --- | --- |
| Replace plans with `expectedRemoteHash` | `tests/SyncPlan.Tests.ps1` |
| `Push -LocalWins -ForcePush` applies the replace | gate 15 |
| Backup holds pre-replace remote bytes | gate 15 |
| BASE records the new local hash and moves | gate 15 |
| Journal records `push-backup` and `push-binary` | gate 15 |
| A binary over the 2,000,000-byte read limit is refused before mutation | `tests/Push.Tests.ps1`, `tests/SyncPlan.Tests.ps1`, `tests/Snapshot.Tests.ps1` |

**Live check:** gate 15 rewrites the gate 14 file, plans one binary replace,
and runs `Push -LocalWins -ForcePush` (the mode a real publish of a diverged
tree uses). Expect `(binary replace)` in the `BINARY` section, `BASE updated:
true`, a backup whose SHA matches the pre-replace remote content (not the new
local bytes), and both journal events. The fully automatic
`tests/Live-RoundTrip.ps1 -BinaryAssetPath <real image>` covers the same ground
with a real image and a direct remote read-back hash, including a
post-move failure-evidence block.

The read limit is the reason the replace must be verified rather than assumed:
`GET /file` returns 413 above 2,000,000 bytes, so the place could succeed while
the read-back cannot ([binary-place.md](binary-place.md)).

### 16. Host-visible progress for hashing, download, and publish

| Property | Evidence |
| --- | --- |
| Plain start and final lines for local hashing | `tests/Progress.Tests.ps1`, `tests/Manifest.Tests.ps1` |
| Plain start and final lines for remote download | `tests/Progress.Tests.ps1`, `tests/Snapshot.Tests.ps1` |
| Intermediate lines are throttled; `-Force` bypasses it | `tests/Progress.Tests.ps1` |
| Each published path is named with applied/remaining counts | `tests/Progress.Tests.ps1`, `tests/Push.Tests.ps1`, `tests/Pull.Tests.ps1` |
| Progress carries a path and integers only, never tokens or contents | `tests/Progress.Tests.ps1`, source scan |
| A progress write never softens fail-closed behavior | `tests/Manifest.Tests.ps1`, `tests/Push.Tests.ps1`, live round-trip |
| The CLI requests progress for Init, Plan/Status, Pull, and Push | `tests/SyncCli.Tests.ps1` |

The plain lines are what make progress visible in hosts that hide
`Write-Progress`; the bar is still updated where the host shows it. The output
contract is asserted on captured CLI output by `tests/Live-RoundTrip.ps1`, so
it holds end to end rather than only at the helper boundary.

**Live check:** run `tests/Live-RoundTrip.ps1 -ProjectId <id>`. Expect every
`progress lines: ...` step to pass, and the fail-closed step to pass with a
non-zero exit for the locked file.

## What this record deliberately does not claim

- No content merge of a conflict, and no guessed sibling path as success.
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
- Publishing local changes: [push.md](push.md)
- Placing binaries: [binary-place.md](binary-place.md)
- BASE ownership and atomic writes: [base-schema.md](base-schema.md)
- Canonical paths, safety, and ignores: [path-safety.md](path-safety.md)
- Torn-read protection: [remote-snapshot.md](remote-snapshot.md)
- Classifier vocabulary: [classifier.md](classifier.md)
- Raw export destination rules: [export.md](export.md)
