# Agent instructions

Before changing this repository, **read [CONTRIBUTING.md](CONTRIBUTING.md) and follow it.** That file is the source of truth for humans and automated agents. This file only restates constraints that are easy to miss.

## Must follow

- Branch from the current **milestone integration branch** (`v0.2.0` for issues #14–#19), never from `main` while that milestone is in progress.
- Name issue branches `issue/<number>-<short-slug>`. Open pull requests against the integration branch, not `main`.
- Ship a completed milestone per [docs/releasing.md](docs/releasing.md): one PR `vX.Y.Z` → `main`, then tag, GitHub Release, close the milestone, cut the next integration branch. Do not land unfinished milestone work on `main`. Do not tag `main` before the ship PR merges.
- Windows PowerShell 5.1 is the compatibility baseline.
- Never print, write, or commit access tokens, refresh tokens, clipboard secrets, or `%APPDATA%\.rundot\` auth files. Do not put them in manifests, plans, journals, logs, or PR text.
- Studio writes are limited to the documented text overwrite route (`PUT /file` in `lib/RemoteWrite.ps1`). Do not add `DELETE`, `upload-url`, `upload-adopt`, or `POST /move`. Token refresh via Google `securetoken` POST is allowed.
- When `tests/Run-Tests.ps1` exists, run it and keep it green.
- Labels and milestones: [docs/github-labels.md](docs/github-labels.md). Product sequence: [ROADMAP.md](ROADMAP.md).
