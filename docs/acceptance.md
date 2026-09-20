# Acceptance: v0.1.3 safe pull planner

This is the acceptance record for the safe pull planner milestone. It maps each
public gate to the evidence that proves it, so a reviewer can check the claims
without trusting the release notes.

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

The live gates pause and tell you which file to change in Studio, because
automating Studio writes is a non-goal of this milestone. The harness only ever
reads from Studio, prints no tokens or file contents, and exits non-zero if any
gate failed.

**The run leaves sensitive state behind, so run it into a throwaway
directory.** A live run creates a `.rundot-sync` workspace, which names every
file in the project, and its `backups/` set holds the **full contents** of any
file `Pull` overwrote ([pull.md](pull.md)). This matters on a public
repository.

Cleanup behavior:

- If you omit `-LocalDir`, the harness uses a temporary directory and removes it
  at the end.
- If you pass a `-LocalDir` **inside the repository** that does not exist yet,
  the harness removes it at the end.
- A **pre-existing** `-LocalDir` is always left in place, and a `-LocalDir`
  **outside** the repository is left in place. Both are reported, because they
  now contain sensitive state.
- `-KeepWorkspace` leaves everything in place for inspection.

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
| 10 | Mutation grep still zero | `tests/NoRemoteMutation.Tests.ps1` | Automated |

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
candidate. Deletion candidates are also classification-only here — no command
deletes anything (see gate 10 and the non-goals).

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

### 10. Mutation grep still zero

`tests/NoRemoteMutation.Tests.ps1` scans `game-studio-sync.ps1`,
`game-studio-export.ps1`, and `lib/**/*.ps1` for Studio write helpers: HTTP
`PUT`, HTTP `DELETE`, `upload-url`, `upload-adopt`, and any `Set-*` / `Remove-*`
function in the remote API library. This milestone ships none.

The plan layer enforces publish policy at runtime:
`tests/SyncPlan.Tests.ps1` asserts that only a utf8 text overwrite may be
applicable among remote-mutating rows, that every blocked remote-mutating row
carries a reason, and that a download is not remote-mutating.

## What this milestone deliberately does not do

Confirmed absent, not merely undocumented:

- No remote create, replace, rename, or delete. No `Apply`, no `Push`.
- No binary upload or adopt.
- No automatic deletion, locally or remotely. `deleteLocalCandidate` leaves the
  file in place; `deleteRemoteCandidate` is reported only.
- No `.rundotignore`. The default ignore set is fixed and documented.
- No newline or encoding normalization; text is preserved byte-for-byte.
- No FileSystemWatcher, device IDs, or multi-machine BASE. One initialized
  workspace belongs to one project and one folder.

Direction beyond this milestone is in [ROADMAP.md](../ROADMAP.md): the next pass
is write-protocol **investigation**, not `Apply`.

## Related contracts

- Initializing a workspace: [init.md](init.md)
- Dry-run planning and the artifact: [plan.md](plan.md)
- Applying remote-only changes: [pull.md](pull.md)
- BASE ownership and atomic writes: [base-schema.md](base-schema.md)
- Canonical paths, safety, and ignores: [path-safety.md](path-safety.md)
- Torn-read protection: [remote-snapshot.md](remote-snapshot.md)
- Classifier vocabulary: [classifier.md](classifier.md)
- Raw export destination rules: [export.md](export.md)
