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

How to branch and open pull requests is in [CONTRIBUTING.md](CONTRIBUTING.md). How to ship a finished milestone is in [docs/releasing.md](docs/releasing.md). Labels and milestone naming are in [docs/github-labels.md](docs/github-labels.md). Versions live on milestones, not labels.

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

Shipped on `main`.

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

Shipped on `main`.

## v0.2.0 - Safe push

First version that can publish local changes to Studio the way export and pull bring files down.

Investigate the write protocol **before** implementing `Apply-SyncPlan` / `Push`. Do not call `PUT` merely because `Plan` shows `UPLOAD`.

The first work in this milestone is investigation, not implementation: the text
create/overwrite protocol, binary create/overwrite and collision names, and
delete/rename/concurrency semantics ([#14](https://github.com/iNcredibleGM/rundot-game-studio-sync/issues/14)–[#16](https://github.com/iNcredibleGM/rundot-game-studio-sync/issues/16))
have to be observed and written down first. `Apply-SyncPlan` / `Push`
([#17](https://github.com/iNcredibleGM/rundot-game-studio-sync/issues/17)) is
designed only from that evidence. The v0.1.3 plan artifact already records what
a future `Apply` must re-verify before writing: `planId`, `localRootFingerprint`,
`localManifestHash`, `remoteManifestHashBefore`/`After`, and a per-path
`expectedRemoteHash` ([docs/plan.md](docs/plan.md)).

Milestone: [v0.2.0 - Safe push](https://github.com/iNcredibleGM/rundot-game-studio-sync/milestone/3)

1. Investigate text create/overwrite — [#14](https://github.com/iNcredibleGM/rundot-game-studio-sync/issues/14)
2. Investigate binary create/overwrite and collision names — [#15](https://github.com/iNcredibleGM/rundot-game-studio-sync/issues/15)
3. Investigate delete, rename, concurrency, ETag / If-Match — [#16](https://github.com/iNcredibleGM/rundot-game-studio-sync/issues/16)
4. `Apply-SyncPlan` / `Push` using plan fingerprints — [#17](https://github.com/iNcredibleGM/rundot-game-studio-sync/issues/17)
5. Push confirmation, backups, journal, conflict refusal — [#18](https://github.com/iNcredibleGM/rundot-game-studio-sync/issues/18)
6. Public docs: Init → Plan → Pull → Push — [#19](https://github.com/iNcredibleGM/rundot-game-studio-sync/issues/19)

Do not mark v0.2.0 complete until a stranger can push one clean text change on a disposable project without a guessed clobber.

Shipped on `main`.

## v0.3.0 - Publish the local tree

v0.2.0 publishes one clean utf8 text overwrite. It does not create files, upload binaries, delete remote files, or choose a side on a conflict. Adopting a folder that already disagrees with Studio therefore plans many `upload` and `conflict` rows and an applicable count of zero.

This milestone is the confirmed publish that can make Studio match that local tree, for the operations the protocol actually allows.

**Guiding rule:** still no guessed clobber. Default `Push` stays the clean text overwrite. A diverged path is published only when a local-wins confirmation names it. Local-wins replaces remote bytes with local bytes. It does not merge.

**Hard ban:** do not add a create, binary upload, `DELETE`, or `POST /move` until the issue that owns that route has written down the evidence. A route that does not exist stays refused.

Milestone: [v0.3.0 - Publish the local tree](https://github.com/iNcredibleGM/rundot-game-studio-sync/milestone/4)

1. Investigate how Studio creates a text file — [#37](https://github.com/iNcredibleGM/rundot-game-studio-sync/issues/37)
2. Investigate placing a binary at its project path — [#38](https://github.com/iNcredibleGM/rundot-game-studio-sync/issues/38)
3. Delete remote files for `deleteRemoteCandidate` — [#39](https://github.com/iNcredibleGM/rundot-game-studio-sync/issues/39)
4. Push text creates when a create route exists — [#40](https://github.com/iNcredibleGM/rundot-game-studio-sync/issues/40)
5. Publish binaries only by a proven place-at-path sequence — [#41](https://github.com/iNcredibleGM/rundot-game-studio-sync/issues/41)
6. Confirmed local-wins publish for conflicts and remote-only files — [#42](https://github.com/iNcredibleGM/rundot-game-studio-sync/issues/42)
7. Show progress while hashing and publishing large trees — [#43](https://github.com/iNcredibleGM/rundot-game-studio-sync/issues/43)
8. Document and accept publishing a local tree — [#44](https://github.com/iNcredibleGM/rundot-game-studio-sync/issues/44)

Done when a stranger, on a disposable project, can confirm one publish that overwrites one utf8 text file, creates one text file or shows a clear refusal, deletes one remote-only file, places one binary or shows a clear refusal, and leaves every unconfirmed conflict untouched.

Cut integration branch `v0.3.0` from `main` after v0.2.0 ships. Do not land these issues on `v0.2.0` or on `main` before that.

## After v0.3.0

- browser bootstrap / bookmarklet helper
- official `rundot` CLI refresh-token handling beyond the current fresh-access-token path
- selective push of a path subset
- content merge of a conflict
- publish a detected rename as `POST /move` when delete-plus-create is the wrong shape
- distributed / multi-machine BASE
