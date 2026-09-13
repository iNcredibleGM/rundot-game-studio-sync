# Roadmap

## v0.1.0

Stable Studio → local export.

- project files
- binary assets
- UTF-8 preservation
- Studio thread archive
- raw JSON + Markdown transcripts
- reusable local authentication

Shipped on `main`.

How to branch and open pull requests is in [CONTRIBUTING.md](CONTRIBUTING.md). Labels and milestone naming are in [docs/github-labels.md](docs/github-labels.md). Versions live on milestones, not labels.

## v0.1.2 - Sync foundations

Shared GET/auth libraries, path safety, hashing, BASE schema, and torn-read remote snapshots.

No new user commands. The product remains the exporter.

**Hard ban:** no Studio `PUT`, `DELETE`, rename, `upload-url`, or `upload-adopt`.

Milestone: [v0.1.2 - Sync foundations](https://github.com/iNcredibleGM/rundot-game-studio-sync/milestone/2)

1. Extract shared auth and GET-only remote API — [#3](https://github.com/iNcredibleGM/rundot-game-studio-sync/issues/3)
2. Canonical paths, safety validation, and default ignores — [#4](https://github.com/iNcredibleGM/rundot-game-studio-sync/issues/4)
3. Local manifests, streaming SHA-256, and BASE schema — [#5](https://github.com/iNcredibleGM/rundot-game-studio-sync/issues/5)
4. Stable remote snapshot with torn-read protection — [#6](https://github.com/iNcredibleGM/rundot-game-studio-sync/issues/6)

Done when the exporter still works, internals are reusable and tested, and mutation grep is green.

## v0.1.3 - Safe pull planner

Read-oriented sync: initialize a workspace, inspect BASE / LOCAL / REMOTE, generate a dry-run plan, and pull remote-only changes with confirmation and backups.

**Guiding rule:** neither LOCAL nor REMOTE is authoritative. BASE is the last verified shared state. Any ambiguity is a conflict, not a guess.

**Hard ban:** still no remote mutation. There is no `Apply` and no `Push`.

Public commands:

- `Init` (`FromRemote`, `Adopt`)
- `Plan`
- `Pull`
- `Status`

Milestone: [v0.1.3 - Safe pull planner](https://github.com/iNcredibleGM/rundot-game-studio-sync/milestone/1)

1. `Init -FromRemote` / `Adopt`; refuse `Plan` without BASE — [#7](https://github.com/iNcredibleGM/rundot-game-studio-sync/issues/7)
2. Three-way classifier — [#8](https://github.com/iNcredibleGM/rundot-game-studio-sync/issues/8)
3. `Plan` / `Status` dry-run CLI — [#9](https://github.com/iNcredibleGM/rundot-game-studio-sync/issues/9)
4. Safe `Pull` with backups and verified BASE update — [#10](https://github.com/iNcredibleGM/rundot-game-studio-sync/issues/10)
5. Public hardening: exporter safety, docs, acceptance — [#11](https://github.com/iNcredibleGM/rundot-game-studio-sync/issues/11)

Done when a stranger can init, edit one file, see exactly one upload candidate, pull a clean remote-only change with a backup, and verify there is still no remote mutation code path.

## v0.2.0 - Safe push

First version that can publish local changes to Studio the way export and pull bring files down.

Investigate the write protocol **before** implementing `Apply-SyncPlan` / `Push`. Do not call `PUT` merely because `Plan` shows `UPLOAD`.

Milestone: [v0.2.0 - Safe push](https://github.com/iNcredibleGM/rundot-game-studio-sync/milestone/3)

1. Investigate text create/overwrite — [#14](https://github.com/iNcredibleGM/rundot-game-studio-sync/issues/14)
2. Investigate binary create/overwrite and collision names — [#15](https://github.com/iNcredibleGM/rundot-game-studio-sync/issues/15)
3. Investigate delete, rename, concurrency, ETag / If-Match — [#16](https://github.com/iNcredibleGM/rundot-game-studio-sync/issues/16)
4. `Apply-SyncPlan` / `Push` using plan fingerprints — [#17](https://github.com/iNcredibleGM/rundot-game-studio-sync/issues/17)
5. Push confirmation, backups, journal, conflict refusal — [#18](https://github.com/iNcredibleGM/rundot-game-studio-sync/issues/18)
6. Public docs: Init → Plan → Pull → Push — [#19](https://github.com/iNcredibleGM/rundot-game-studio-sync/issues/19)

Done when a stranger can push one clean local text change on a disposable project without a guessed clobber.

## After v0.2.0

- browser bootstrap / bookmarklet helper
- official `rundot` CLI refresh-token handling beyond the current fresh-access-token path
- selective push
- automatic conflict resolution
- distributed / multi-machine BASE
