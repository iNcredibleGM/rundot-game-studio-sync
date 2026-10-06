# Contributing

This is the source of truth for how work lands in this repository. Read it before opening a pull request.

Issue labels and milestone naming are in [docs/github-labels.md](docs/github-labels.md). Product direction is in [ROADMAP.md](ROADMAP.md). Closing out a finished milestone (ship PR, tag, GitHub Release, next integration branch) is in [docs/releasing.md](docs/releasing.md).

## Platform

- Windows
- Windows PowerShell 5.1 compatibility baseline
- Do not add code that requires PowerShell 7+ unless an issue explicitly says so

## Branches and pull requests

`main` is the released product. Do not merge in-progress milestone work there.

Each unreleased milestone has an **integration branch** named after the version (`v0.1.2`, `v0.1.3`, …). Cut that branch from `main` when the milestone starts. All issue work for that milestone merges **into the integration branch**.

Issue branches are cut from the current integration branch, not from `main`:

```text
main
v0.3.2
  └── issue/90-pull-remote-wins
```

Naming: `issue/<number>-<short-slug>` (example: `issue/64-gitignore-inventory`).

Open each issue pull request with **base = the integration branch** (for v0.3.2 work, that is `v0.3.2`). When every issue on the milestone is merged and the milestone is ready to ship, follow [docs/releasing.md](docs/releasing.md): **one** pull request from the integration branch to `main`, then tag, GitHub Release, close the milestone, and cut the next integration branch.

v0.3.1 (#64, #66–#75) shipped through one PR from `v0.3.1` to `main`. Current milestone work is v0.3.2 (#90–#93) on integration branch `v0.3.2`. Do not land v0.3.2 issues on `main` before that version ships.

## Tests

When `tests/Run-Tests.ps1` exists, run it with Windows PowerShell before you consider a change done:

```powershell
powershell -NoProfile -File .\tests\Run-Tests.ps1
```

Tests must not require Pester to be installed.

Every pull request runs the unit suite and offline acceptance gates on a
Windows runner (Windows PowerShell 5.1) via
[`.github/workflows/offline-gates.yml`](.github/workflows/offline-gates.yml).
A non-zero exit from either command fails the **Offline gates** check:

```powershell
powershell -NoProfile -File .\tests\Run-Tests.ps1
powershell -NoProfile -File .\tests\Acceptance.ps1 -SkipLive
```

## File and function length

Product PowerShell is budgeted at **500 lines per file** and **150 lines per function**. A file or function over budget is a refactoring target, not a place to add more.

`tests/FileLength.Tests.ps1` enforces the budget as a ratchet: anything already over budget is frozen in that test's allowlist at its current size, so it may shrink but never grow, and it must be removed from the allowlist once it drops under budget. Add new code to a focused file that fits the budget, or split the file you are touching.

## Safety

- Never print, log, or commit access tokens, refresh tokens, or auth files (`%APPDATA%\.rundot\`).
- Do not include those values in bug reports, PR bodies, or issue comments.
- v0.2.0 on `main` adds the documented text overwrite route only: `PUT /api/projects/{projectId}/file` in `lib/RemoteWrite.ps1`. v0.3.0 adds the documented delete route (`lib/RemoteDelete.ps1`, #39) and utf8 text create (`lib/RemoteUpload.ps1`, `lib/RemoteMove.ps1`, `lib/RemoteTextCreate.ps1`, #40), each only after its protocol evidence exists. A further Studio write route may be added only in the issue that owns it. A missing route stays a refusal. Firebase `securetoken` POST for token refresh is allowed.
