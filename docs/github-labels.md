# GitHub labels and milestones

Branching and pull-request bases are documented in [CONTRIBUTING.md](../CONTRIBUTING.md). This file is only labels and milestones.

Versions live on **milestones**, never on labels (name or description).

Milestone title format: `vX.Y.Z - Short name`.

Do not file tracking issues that restate a milestone. Child issues on that milestone are the work.

## How to file

Add one **type** label and one **area** label. Add `safety` if data loss is possible. Add `remote-write` only if Studio would be mutated. Use `Depends on` between issues for implementation order, not parent epics.

## Type

| Label | Color | Meaning |
| --- | --- | --- |
| `bug` | `#D73A4A` | Something already shipped is wrong |
| `feature` | `#1D76DB` | New user-facing or product behavior |
| `docs` | `#0075CA` | README, ROADMAP, protocol notes, process docs |
| `tests` | `#0E8A16` | Test runner, fixtures, coverage gaps |
| `chore` | `#C5DEF5` | Refactor/extract with no user-facing change |

## Area

| Label | Color | Meaning |
| --- | --- | --- |
| `auth` | `#5319E7` | CLI token, DPAPI, clipboard, bearer |
| `export` | `#0052CC` | `game-studio-export.ps1` dump path |
| `sync` | `#006B75` | BASE / LOCAL / REMOTE, Init, Plan, Pull, Status |
| `push` | `#D93F0B` | Local → Studio publish |
| `protocol` | `#3E4B9E` | Unofficial Studio API investigation |

## Safety

| Label | Color | Meaning |
| --- | --- | --- |
| `safety` | `#E99695` | Data-loss risk: paths, overwrites, backups, ignores, torn snapshots |
| `remote-write` | `#B60205` | Would create, replace, rename, or delete files on Studio |

## Status

| Label | Color | Meaning |
| --- | --- | --- |
| `blocked` | `#FBCA04` | Waiting on another issue or unknown API behavior |
| `investigation` | `#F9D0C4` | Need evidence before designing |
| `duplicate` | `#CFD3D7` | Same as another issue |
| `invalid` | `#E4E669` | Not actionable / not a bug |
| `wontfix` | `#FFFFFF` | Explicitly declined |
