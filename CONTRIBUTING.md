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
v0.2.0
  └── issue/14-text-write-protocol
```

Naming: `issue/<number>-<short-slug>` (example: `issue/14-text-write-protocol`).

Open each issue pull request with **base = the integration branch** (for v0.2.0 work, that is `v0.2.0`). When every issue on the milestone is merged and the milestone is ready to ship, follow [docs/releasing.md](docs/releasing.md): **one** pull request from the integration branch to `main`, then tag, GitHub Release, close the milestone, and cut the next integration branch.

Current push work (#14–#19) uses integration branch `v0.2.0`. Cut that branch from `main` after v0.1.3 ships. Do not land those issues on `main` until the v0.2.0 ship PR.

## Tests

When `tests/Run-Tests.ps1` exists, run it with Windows PowerShell before you consider a change done:

```powershell
powershell -NoProfile -File .\tests\Run-Tests.ps1
```

Tests must not require Pester to be installed.

## Safety

- Never print, log, or commit access tokens, refresh tokens, or auth files (`%APPDATA%\.rundot\`).
- Do not include those values in bug reports, PR bodies, or issue comments.
- v0.2.0 push work may add the documented text overwrite route only: `PUT /api/projects/{projectId}/file` in `lib/RemoteWrite.ps1`. Do not add `DELETE`, `upload-url`, `upload-adopt`, or `POST /move`. Firebase `securetoken` POST for token refresh is allowed.
