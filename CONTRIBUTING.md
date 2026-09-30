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
v0.3.1
  └── issue/64-gitignore-inventory
```

Naming: `issue/<number>-<short-slug>` (example: `issue/64-gitignore-inventory`).

Open each issue pull request with **base = the integration branch** (for v0.3.1 work, that is `v0.3.1`). When every issue on the milestone is merged and the milestone is ready to ship, follow [docs/releasing.md](docs/releasing.md): **one** pull request from the integration branch to `main`, then tag, GitHub Release, close the milestone, and cut the next integration branch.

v0.3.0 (#37–#44) shipped through one PR from `v0.3.0` to `main`. Current milestone work is v0.3.1 (#64) on integration branch `v0.3.1`. Do not land v0.3.1 issues on `main` before that version ships.

## Tests

When `tests/Run-Tests.ps1` exists, run it with Windows PowerShell before you consider a change done:

```powershell
powershell -NoProfile -File .\tests\Run-Tests.ps1
```

Tests must not require Pester to be installed.

## Safety

- Never print, log, or commit access tokens, refresh tokens, or auth files (`%APPDATA%\.rundot\`).
- Do not include those values in bug reports, PR bodies, or issue comments.
- v0.2.0 on `main` adds the documented text overwrite route only: `PUT /api/projects/{projectId}/file` in `lib/RemoteWrite.ps1`. v0.3.0 adds the documented delete route (`lib/RemoteDelete.ps1`, #39) and utf8 text create (`lib/RemoteUpload.ps1`, `lib/RemoteMove.ps1`, `lib/RemoteTextCreate.ps1`, #40), each only after its protocol evidence exists. A further Studio write route may be added only in the issue that owns it. A missing route stays a refusal. Firebase `securetoken` POST for token refresh is allowed.
