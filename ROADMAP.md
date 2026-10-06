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

**Hard ban:** do not add a create, binary upload, or `POST /move` until the issue that owns that route has written down the evidence. A route that does not exist stays refused. The delete route is implemented in `lib/RemoteDelete.ps1` under [#39](https://github.com/iNcredibleGM/rundot-game-studio-sync/issues/39), on the evidence in [docs/delete-rename-protocol.md](docs/delete-rename-protocol.md).

Milestone: [v0.3.0 - Publish the local tree](https://github.com/iNcredibleGM/rundot-game-studio-sync/milestone/4)

1. Investigate how Studio creates a text file — [#37](https://github.com/iNcredibleGM/rundot-game-studio-sync/issues/37)
2. Investigate placing a binary at its project path — [#38](https://github.com/iNcredibleGM/rundot-game-studio-sync/issues/38)
3. Delete remote files for `deleteRemoteCandidate` — [#39](https://github.com/iNcredibleGM/rundot-game-studio-sync/issues/39) — shipped in `lib/RemoteDelete.ps1`
4. Push text creates when a create route exists — [#40](https://github.com/iNcredibleGM/rundot-game-studio-sync/issues/40)
5. Publish binaries only by a proven place-at-path sequence — [#41](https://github.com/iNcredibleGM/rundot-game-studio-sync/issues/41)
6. Confirmed local-wins publish for conflicts and remote-only files — [#42](https://github.com/iNcredibleGM/rundot-game-studio-sync/issues/42)
7. Show progress while hashing and publishing large trees — [#43](https://github.com/iNcredibleGM/rundot-game-studio-sync/issues/43)
8. Document and accept publishing a local tree — [#44](https://github.com/iNcredibleGM/rundot-game-studio-sync/issues/44)

Done when a stranger, on a disposable project, can confirm one publish that overwrites one utf8 text file, creates one text file or shows a clear refusal, deletes one remote-only file, places one binary or shows a clear refusal, and leaves every unconfirmed conflict untouched.

Shipped on `main`.

## v0.3.1 - Honor .gitignore and hardening

Patch on v0.3.0, expanded by the full-project review. Two halves: one shipped behavior fix, and the refactoring, performance, hygiene, and safety-net follow-ups the review surfaced.

**Half one — honor a present `.gitignore`.** The v0.3.0 production publish showed the fixed ignore set still treating gitignored paths as sync candidates — 70 paths (~946 MB) in an 18,642-file tree, including a `.env.local` secret ([#64](https://github.com/iNcredibleGM/rundot-game-studio-sync/issues/64)). This version honors a present **root** `.gitignore` during local sync inventory so those paths are not upload candidates.

**Scope is deliberately narrow:** `.gitignore` is an **additive floor** over the fixed built-in set — it never re-includes or overrides a built-in entry. No negation (`!pattern`) and no nested per-directory files. The ignore set stays deterministic and reported, a parse failure fails closed, and an ignore rule must never manufacture a `deleteRemoteCandidate`. No new Studio write route.

**Half two — hardening from the project review.** Measured findings, not guesses: an O(rows x remote files) delete-path check worth **22.1x**, a per-row array rebuild worth **1.8x**, a 3,233-line `Push.ps1` that needs splitting, duplicated helpers, one dead function, a layering leak in `Auth.ps1`, and the fact that the repository has **no CI and no branch protection** at all.

Milestone: [v0.3.1 - Honor .gitignore and hardening](https://github.com/iNcredibleGM/rundot-game-studio-sync/milestone/5)

1. Honor a present `.gitignore` during local sync inventory — [#64](https://github.com/iNcredibleGM/rundot-game-studio-sync/issues/64) — shipped in `lib/Ignore.ps1`
2. Precompute the ancestor-directory set for delete-path applicability — [#69](https://github.com/iNcredibleGM/rundot-game-studio-sync/issues/69)
3. Hoist the remote path list out of the per-row plan loop — [#66](https://github.com/iNcredibleGM/rundot-game-studio-sync/issues/66)
4. Add a regression guard for the binary place manifest reuse — [#75](https://github.com/iNcredibleGM/rundot-game-studio-sync/issues/75)
5. Split `Push.ps1` into focused publish-mode libraries — [#70](https://github.com/iNcredibleGM/rundot-game-studio-sync/issues/70)
6. Remove dead function and deduplicate the short-hash formatter — [#68](https://github.com/iNcredibleGM/rundot-game-studio-sync/issues/68)
7. Stop `lib/Auth.ps1` writing to the console — [#67](https://github.com/iNcredibleGM/rundot-game-studio-sync/issues/67)
8. Deduplicate shared test helpers — [#73](https://github.com/iNcredibleGM/rundot-game-studio-sync/issues/73)
9. Add CI that runs the unit suite and offline gates on every pull request — [#71](https://github.com/iNcredibleGM/rundot-game-studio-sync/issues/71)
10. Protect `main` and require the offline gates before merge — [#72](https://github.com/iNcredibleGM/rundot-game-studio-sync/issues/72)
11. Fix the stale `Get-SyncLocalFileMd5Hex` reference in `binary-place-protocol.md` — [#74](https://github.com/iNcredibleGM/rundot-game-studio-sync/issues/74)

**Done when** the suite is green, the two performance fixes are in with their measured gains, CI runs the offline gates on every PR, `Push.ps1` is split with no behavior change, and the mutation grep is still green.

Deferred to a later milestone: nested `.gitignore` files, negation / re-include semantics, full anchoring and `**` pattern semantics, and the built-in-vs-`.gitignore` precedence question beyond "additive floor".

Shipped on `main`.

## v0.3.2 - Pull parity and follow-ups

Patch on v0.3.1. Two directions of work: make `Pull` match `Push`, and be honest about large files.

**Pull parity** ([#90](https://github.com/iNcredibleGM/rundot-game-studio-sync/issues/90)). `Pull` is deliberately narrow — it applies only clean remote-only rows and reports everything else. That is the right default, but it leaves two gaps against `Push`:

1. A `conflict` row has no direction, so a local file that also changed in Studio can never be brought up to Studio's bytes. `Pull -RemoteWins` adds the confirmed replace mode that mirrors `Push -LocalWins` — backup first, concurrent-edit guard before each write, and defined BASE-update and rollback semantics. It never deletes and never rebuilds the tree; `Init -InitMode FromRemote` stays the only reset path.
2. `Push` gates on the last `Plan` artifact (`.rundot-sync/last-plan.json`); `Pull` does not. `Pull` reads and re-verifies the same artifact, so a pull changelist can be previewed, confirmed, and applied against one fingerprint set.

Neither ask mutates Studio. Both stay GET-only toward Studio.

**Large-file honesty.** Two follow-ups carved out of the tracked read-limit gap ([#87](https://github.com/iNcredibleGM/rundot-game-studio-sync/issues/87)):

3. A **named refusal for text over 2,000,000 bytes** ([#91](https://github.com/iNcredibleGM/rundot-game-studio-sync/issues/91)) — states that the path would be write-once, instead of an opaque 413.
4. **Large binary replace up to 50 MiB** ([#92](https://github.com/iNcredibleGM/rundot-game-studio-sync/issues/92)) — confirmed, opt-in delete-then-place with the upload `ETag` as the post-place identity and the `GET /files` size as the only pre-replace guard. It trades the backup and the `expectedRemoteHash` gate for the ability to replace at all, so it is never the default.

The 2 MB read limit itself is **not** addressed: no route returns the bytes. [#87](https://github.com/iNcredibleGM/rundot-game-studio-sync/issues/87) stays open as the tracked capability gap.

**Hard ban:** no new Studio write route. `Pull` adds no mutation, and #92 composes the existing delete route and the proven place-at-path sequence.

Milestone: [v0.3.2 - Pull parity and follow-ups](https://github.com/iNcredibleGM/rundot-game-studio-sync/milestone/6)

**Done when** a workspace with a conflict can preview and apply a pull that replaces the local bytes with Studio's and backs the original up first; `Pull` refuses or warns on a missing, expired, or drifted `last-plan.json`, matching `Push`'s gate; text over 2 MB is refused with a named write-once reason; a confirmed large-binary replace between 2 MB and 50 MiB places and verifies from the `ETag`; and the mutation grep and `NoRemoteMutation.Tests.ps1` are still green.

## After v0.3.2

- browser bootstrap / bookmarklet helper
- official `rundot` CLI refresh-token handling beyond the current fresh-access-token path
- selective push of a path subset
- content merge of a conflict
- publish a detected rename as `POST /move` when delete-plus-create is the wrong shape
- distributed / multi-machine BASE
- large binary replace up to 50 MiB — delete-then-place with the upload `ETag` as the post-place identity, and the `GET /files` size as the only pre-replace guard. Trades the backup and the `expectedRemoteHash` gate for the ability to replace at all ([large-file-protocol.md](docs/large-file-protocol.md))
- a named refusal for text over 2,000,000 bytes, stating that the path would be write-once ([large-file-protocol.md](docs/large-file-protocol.md))

The 2 MB read limit itself is not on this list: no route was found that returns
the bytes, so a file already on Studio over 2 MB stays unverifiable. See
[docs/limitations.md](docs/limitations.md).
