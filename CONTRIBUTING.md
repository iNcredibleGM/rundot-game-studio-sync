# Contributing

This is the source of truth for how work lands in this repository. Read it before opening a pull request.

Issue labels and milestone naming are in [docs/github-labels.md](docs/github-labels.md). Product direction is in [ROADMAP.md](ROADMAP.md).

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
v0.1.2
  └── issue/3-extract-auth-api
```

Naming: `issue/<number>-<short-slug>` (example: `issue/3-extract-auth-api`).

Open each issue pull request with **base = the integration branch** (for v0.1.2 work, that is `v0.1.2`). When every issue on the milestone is merged and the milestone is ready to ship, open **one** pull request: integration branch → `main`.

Current foundations work (#3–#6) uses integration branch `v0.1.2`. Do not land those issues on `main` until that ship PR.

## Tests

When `tests/Run-Tests.ps1` exists, run it with Windows PowerShell before you consider a change done:

```powershell
powershell -NoProfile -File .\tests\Run-Tests.ps1
```

Tests must not require Pester to be installed.

## Safety

- Never print, log, or commit access tokens, refresh tokens, or auth files (`%APPDATA%\.rundot\`).
- Do not include those values in bug reports, PR bodies, or issue comments.
- Until the v0.2.0 push work, do not add Studio mutation helpers (`PUT`, `DELETE`, `upload-url`, `upload-adopt`). Firebase `securetoken` POST for token refresh is allowed.
