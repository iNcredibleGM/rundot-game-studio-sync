# Init

Init is the first-run workflow. It is the only command that creates a
workspace and the only writer of BASE.

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
2. **Stable snapshot.** `Get-StableRemoteSnapshot` downloads every listed
   file into `.rundot-sync/temp/remote-snapshot/<attempt>/`, validates paths,
   and proves `ManifestBefore == ManifestAfter`
   ([remote-snapshot.md](remote-snapshot.md)).
3. **Staging verification.** Staging is re-hashed against the snapshot's own
   hashes. A listed path missing from staging, a staging file the snapshot
   does not list, or any hash disagreement aborts.
4. **Reserved-path check.** A remote path under `.git`, `.gitignore`, or
   `.rundot-sync` is refused, so retained local metadata and sync state are
   never overwritten.
5. **Promotion.** Staging entries move into `LocalDir` by same-volume rename,
   not copy. There is no partial-copy window; a rename that fails midway rolls
   the already-moved entries back to staging.
6. **Re-verification.** Every promoted file is re-hashed and compared to the
   snapshot. BASE is built from the bytes now on disk, not from what was
   expected to land.
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
REMOTE-ONLY: 1            IGNORED: 1

CONFLICT
  src/edited.ts  local=d385701c...43be  remote=0709e9b0...eca2

LOCAL-ONLY
  notes.md  local=f15030cd...691e
...

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

## Limitation: API hash fields

REMOTE is verified by byte-hashing staged and promoted files against the
snapshot's own decoded-byte hashes, plus the `Before == After` manifest
fingerprint. Per-file `sha256`/`hash`/`contentHash` fields the API may return
are folded into that fingerprint but are not decoded: their algorithm and
format are undocumented. Init does not treat them as an independent
verification.

## Next

Once BASE exists, `Plan` and `Status` are the read commands
([plan.md](plan.md)). `Plan` generates the dry-run report and persists
`.rundot-sync/last-plan.json`; `Status` runs the same engine and writes
nothing. Neither mutates Studio, and `Init` remains the only writer of BASE.
