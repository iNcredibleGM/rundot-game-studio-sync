# Init

Init is the first-run workflow. It is the command that creates a workspace and
records the first BASE ([pull.md](pull.md) covers the later, verified BASE
update that `Pull` performs).

A missing BASE is a normal first-run state, not an error. Neither LOCAL nor
REMOTE is authoritative: BASE records the last verified shared state, and any
ambiguity is a conflict rather than a guess.

Init is GET-only. It never creates, replaces, renames, or deletes anything on
Studio.

## Commands

```powershell
.\game-studio-sync.ps1 -ProjectId <id> -LocalDir <dir> -Command Init -InitMode FromRemote
.\game-studio-sync.ps1 -ProjectId <id> -LocalDir <dir> -Command Init -InitMode Adopt
```

`-FromRemote` is accepted as an alias for `-InitMode FromRemote`.

These are the only Init modes in this milestone. `FromLocal` and
`-AcceptRemoteAsBase` do not exist and are not planned here.

## `Init -InitMode FromRemote`

Builds a trusted local workspace from REMOTE.

1. **Destination pre-flight.** `LocalDir` must be empty, or contain only
   `.git` / `.gitignore`. A leftover `.rundot-sync/` with no BASE is
   tolerated so a re-run after a failed attempt needs no manual cleanup.
   (The raw exporter is stricter here and refuses any `.rundot-sync`, because
   for export it means "this is a workspace, do not re-dump over it" —
   [export.md](export.md).)
   The raw exporter deliberately does not share this tolerance: it refuses a
   `.rundot-sync/` outright, because a raw re-dump over a workspace is the
   destructive case ([export.md](export.md)).
2. **Stable snapshot.** `Get-StableRemoteSnapshot` downloads every listed
   file that Studio allows `GET /file` to return into
   `.rundot-sync/temp/remote-snapshot/<attempt>/`, validates paths, and proves
   `ManifestBefore == ManifestAfter` ([remote-snapshot.md](remote-snapshot.md)).
   A listed path over Studio's 2 MB (2,000,000-byte) read limit is captured as
   `Unverifiable` (path and size, no hash, no download) and does not fail the
   snapshot.
3. **Staging verification.** Staging is re-hashed against the snapshot's own
   hashes for every **verifiable** listed path. An unverifiable path must be
   absent from staging; bytes there abort. A verifiable path missing from
   staging, a staging file the snapshot does not list, or any hash disagreement
   aborts.
4. **Reserved-path check.** A remote path under `.git`, `.gitignore`, or
   `.rundot-sync` is refused, so retained local metadata and sync state are
   never overwritten.
5. **Promotion.** Staging entries move into `LocalDir` by same-volume rename,
   not copy. There is no partial-copy window; a rename that fails midway rolls
   the already-moved entries back to staging.
6. **Re-verification.** Every promoted file is re-hashed and compared to the
   snapshot. BASE is built from those bytes only. Unverifiable paths are
   reported by path and listed size; they are not promoted and are not written
   into BASE.
7. **Atomic BASE.** `Save-BaseManifest` writes BASE last
   ([base-schema.md](base-schema.md)), then staging is cleared.

### Any failure leaves no BASE

| Failure | Result |
| --- | --- |
| Non-empty destination | Refuse before contacting Studio |
| Unstable snapshot (3 attempts) | Abort, no BASE, nothing promoted |
| Listed path 404s during download | Abort, no BASE, nothing promoted |
| Hash mismatch against the snapshot | Abort, no BASE, nothing promoted |
| Reserved-path collision | Refuse, no BASE, existing metadata untouched |
| Path the destination cannot represent | Abort before promoting |
| Rename failure midway | Roll back to staging, no BASE |
| BASE write failure | Roll back to staging, report that no BASE was written |

"Any failure: no BASE" is the whole point. A partial or unverified tree must
never become recorded shared state.

## `Init -InitMode Adopt`

Attaches sync metadata to a tree that already exists, without claiming
agreement that was not proven.

Adopt compares `LOCAL ∪ REMOTE` by canonical path and exact content hash:

| LOCAL | REMOTE | Result |
| --- | --- | --- |
| present | same hash | `Identical` — the only BASE candidate |
| present | different hash | `Conflict` |
| present | absent | `LocalOnly` |
| present or absent | present, over read limit | `Unverifiable` |
| absent | present | `RemoteOnly` |
| absent | present, but ignored | `IgnoredRemote` |

`IgnoredRemote` covers paths matching the default ignore set
([path-safety.md](path-safety.md)) and anything under `.rundot-sync/`. They
are labelled IGNORED rather than REMOTE-ONLY so the report never implies the
user should fetch `dist/` or sync-state content.

**BASE receives only the `Identical` rows.** A `Conflict` has no known
direction, and a local-only or remote-only path has no agreement at all, so
none of them may be recorded as a safe sync direction. Adopt writes a partial
BASE rather than a complete one for that reason.

The unresolved-path report is printed naming every non-identical path with
short local and remote hashes:

```text
Init Adopt unresolved paths
===========================
IDENTICAL (BASE): 12      CONFLICT: 2      LOCAL-ONLY: 3
REMOTE-ONLY: 1            IGNORED: 1            UNVERIFIABLE: 1

CONFLICT
  src/edited.ts  local=d385701c...43be  remote=0709e9b0...eca2

LOCAL-ONLY
  notes.md  local=f15030cd...691e
...

UNVERIFIABLE (over Studio read limit)
  public/hero.fbx  size=3120444

BASE records only path+hash-identical entries: 12 of 19 paths.
Every path listed above is unresolved; it is not evidence of a safe sync direction.
```

If nothing is identical, Adopt still writes BASE but warns that
synchronization direction is untrusted for every path. It does not stay
silent.

Adopt also:

- refuses a tree that already has a BASE, because re-adopting would replace a
  verified shared state with a weaker one
- never modifies the tree it attaches to, and does not download remote-only
  files

BASE entries for Adopt use the local byte-derived identity (`size`, `kind`,
`lineEnding`, `hasBom`). The hashes matched by definition, so local
diagnostics are the accurate ones.

## Plan without BASE

`Plan` and `Status` refuse when BASE is missing, and point at Init:

```text
This workspace has no BASE manifest, so there is no verified shared state.

Initialize it first:
  .\game-studio-sync.ps1 -ProjectId <id> -LocalDir <dir> -Command Init -InitMode FromRemote
  .\game-studio-sync.ps1 -ProjectId <id> -LocalDir <dir> -Command Init -InitMode Adopt

Advanced: -AllowNoBase plans without BASE. Synchronization direction is then untrusted.
```

The gate is consulted **before** authentication, so a missing BASE never asks
the user for a token.

`-AllowNoBase` is an advanced escape hatch. Output must state that
synchronization direction is untrusted:

```text
WARNING: No BASE manifest. Synchronization direction is untrusted.
LOCAL and REMOTE agreement has not been proven, so every path is a guess.
```

`-AllowNoBase` bypasses a *missing* BASE only. A present BASE is still
ownership-checked, so the flag can never accept a BASE belonging to a
different project or folder.

## Progress output

Init hashes the whole local tree before it prints a report, and Adopt does
that over an existing tree. On a large workspace that can look hung, so the
commands print plain progress lines that do not depend on `Write-Progress`:

```text
Hashing local files: C:\work\project
Hashed 412 local file(s).
Downloading 412 remote file(s)...
Downloading remote project: 37 of 412: src/game/level-12.ts
Downloaded 412 remote file(s).
```

- Local hashing prints a start line, then a throttled `count: path` line (at
  most about once per second) and a final count.
- Remote download prints a start line, a throttled `index of total: path`
  line, and a final count.
- The `Write-Progress` bar is still updated where the host shows it. The plain
  lines are what make progress visible in hosts that do not.

Progress output contains a canonical path and integer counts only. It never
prints file contents, access tokens, refresh tokens, or `Authorization`
headers. Printing progress is best effort and never changes fail-closed
behavior: a failed hash or download still aborts, and a progress write can
never mask that error.

## Limitation: files over Studio's read limit

`GET /file` returns HTTP 413 `file too large to view` for any payload over **2 MB (2,000,000 bytes)**. Exactly 2,000,000 bytes still reads; 2,000,001 does not. No other read route is known, and the refusal is not changed by request headers or by `POST` on the same URL. `Init -InitMode FromRemote` therefore does not download those paths and does not write them into BASE. It reports each one by path and listed size and still records every file it could verify. `Init -InitMode Adopt` reports the same paths as `Unverifiable` and does not record them as identical.

A later `Plan` lists them under `UNVERIFIABLE`. `Pull` does not download them. `Push` can publish a **new** binary over the limit (verified from the upload `ETag`) and refuses to replace one that is already over the limit. See [Known limitations](limitations.md), [README](../README.md#large-files-studio-read-limit), and [protocol.md](protocol.md).

## Limitation: API hash fields

REMOTE is verified by byte-hashing staged and promoted files against the
snapshot's own decoded-byte hashes, plus the `Before == After` manifest
fingerprint. Per-file `sha256`/`hash`/`contentHash` fields the API may return
are folded into that fingerprint but are not decoded: their algorithm and
format are undocumented. Init does not treat them as an independent
verification.

## One workspace per project, and a second machine

BASE binds one Studio `projectId` to one local folder, so a workspace is not
portable: copying `.rundot-sync` to another machine or directory does not carry
the shared state over. `Plan` and `Pull` hard-fail on an ownership mismatch
([base-schema.md](base-schema.md)).

On a second machine, initialize a fresh workspace rather than copying state:

1. `Init -InitMode FromRemote` into a new or empty directory.
2. Copy your in-progress files in.
3. Run `Plan`. Copied-in work appears as `UPLOAD` candidates and diverged files
   as `CONFLICT` rows, for you to review.

Multi-machine BASE is not in this milestone, so each machine keeps its own
independent BASE.

## Raw export is not init

`game-studio-export.ps1` writes into a new or empty directory too, but it does
**not** create a workspace and it does not record BASE: it is a raw dump. It
also refuses a directory that already contains `.rundot-sync`, where Init
tolerates a BASE-less leftover. Use `Init` when you want sync, and export when
you want a disposable copy ([export.md](export.md)).

## Next

Once BASE exists, `Plan` and `Status` are the read commands
([plan.md](plan.md)). `Pull` applies remote-only changes with backups
([pull.md](pull.md)). `Push` is the command that writes REMOTE, and only for a
confirmed utf8 text overwrite ([push.md](push.md)). `Plan` generates the
dry-run report and persists `.rundot-sync/last-plan.json`; `Status` runs the
same engine and writes nothing. A workspace is bound to one project and one
folder, and a second machine needs its own ([base-schema.md](base-schema.md)).
