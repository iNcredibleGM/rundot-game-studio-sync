# Raw export

`game-studio-export.ps1` is the bulk exporter. It writes the complete editable
project filesystem from Studio to a local directory, byte-for-byte, and can
optionally archive Studio conversation threads.

It is a **dump**, not a sync command. This document covers where it is allowed
to write, and why it refuses everywhere else.

Export is GET-only, like every command in this milestone. It never creates,
replaces, renames, or deletes anything on Studio.

```powershell
.\game-studio-export.ps1 -ProjectId <id> -OutDir <dir> [-IncludeThreads] [-ForgetAuth]
```

## New or empty directories only

`-OutDir` must be **new or empty**. Only two names may already be present:

| Allowed already present | Notes |
| --- | --- |
| `.git` | Directory or pointer file (worktree / submodule layout) |
| `.gitignore` | |

Both are repository metadata rather than project content, so writing over the
directory does not replace a file export would also produce.

Anything else refuses. The check runs **before authentication**, so a refused
export never asks for a token and never reaches the network.

## What refuses

| `-OutDir` state | Result |
| --- | --- |
| Does not exist | Created, export proceeds |
| Empty | Export proceeds |
| Only `.git` / `.gitignore` | Export proceeds |
| `-OutDir` is a file | Refuse |
| `-OutDir` is a reparse point, symlink, or cloud placeholder | Refuse |
| Contains `.rundot-sync/` | Refuse; points at `Pull` |
| Contains an initialized workspace (`.rundot-sync/base-manifest.json`) | Refuse; points at `Pull` only |
| Contains any other file or directory | Refuse; names each offender |

A refusal writes nothing, deletes nothing, rewrites nothing, and does not plant
a `.rundot-sync` of its own.

## Why there is no "export to refresh"

Pointing the exporter at an existing tree overwrites local work with whatever
Studio currently holds, silently. A user who ran export as a refresh step would
lose local edits with no backup and no warning — export has no BASE, so it
cannot know which side changed.

Sync exists for that job, and it is safe precisely because it does know:
[Plan](plan.md) reports the direction, and [Pull](pull.md) backs up every
overwrite. So the exporter refuses, and the refusal says which command to use
instead.

If the directory is an initialized workspace:

```powershell
.\game-studio-sync.ps1 -ProjectId <id> -LocalDir <dir> -Command Pull
```

If it is an existing tree with no BASE, Adopt is the way in:

```powershell
.\game-studio-sync.ps1 -ProjectId <id> -LocalDir <dir> -Command Init -InitMode Adopt
.\game-studio-sync.ps1 -ProjectId <id> -LocalDir <dir> -Command Pull
```

Adopt records only paths that already match Studio exactly, so it never
overwrites your files. It is not offered for an already-initialized workspace,
because Adopt itself refuses a tree that already has a BASE.

There is deliberately **no force flag** to bypass this gate. Force would
recreate exactly the silent destructive workflow the gate removes.

## Two ways this differs from `Init`

The exporter's destination check is intentionally stricter than
[Init's](init.md). Both are correct for their own command:

**`.rundot-sync/` is tolerated by Init, refused by export.** Init tolerates a
leftover `.rundot-sync` so a re-run after a failed attempt needs no manual
cleanup — it holds no BASE, so nothing is claimed. For export the meaning is
the opposite: a `.rundot-sync` says this directory is a sync workspace, and a
raw re-dump over one is the destructive case. A `.rundot-sync` that is a *file*
is refused too.

**Export does not apply the default ignore set.** [Init](init.md) and the local
inventory consult the ignore matcher, so a stray `Thumbs.db` is simply out of
sync scope. Export must not: every ignore exception widens the set of existing
files it would overwrite. A lone `Thumbs.db` in `-OutDir` therefore refuses.

## What export does apply

Remote side path safety is unchanged: the manifest's path set is validated with
`Assert-SafeSyncPathSet`, and each path is checked to be representable in the
destination with `Assert-SyncPathRepresentable`. An existing destination tree is
still checked for reparse points with `Assert-LocalWorkspaceTreeSafe`.

Remote files whose names match the default ignore set are still **downloaded** —
the ignore set is about the local sync inventory, not about export.

## Verification while writing

Export does not merely write and hope:

- **Text** is written as the exact UTF-8 returned by Studio, without BOM and
  without newline normalization, then re-read and compared character-for-
  character. CRLF and lone-LF counts are compared separately.
- **Binary** assets are written byte-for-byte and the on-disk size is compared
  to the size Studio reports.
- Studio's text `size` metadata is character-oriented for some Unicode-heavy
  files, so a metadata difference is reported as a note, not a failure, when
  the exact round-trip already succeeded.

A non-zero exit code means at least one file failed verification.

## Thread archive

`-IncludeThreads` writes an archive under `<OutDir>/.rundot-studio-export/`:

```text
.rundot-studio-export/threads/
  index.json
  raw/<threadId>.json
  markdown/<threadId>.md
```

The raw JSON is the canonical archive; the Markdown is a readable rendering of
the same content. Because this directory is created by export inside the
destination, it is also why re-exporting into the same directory refuses: the
second run would see it as an unexpected entry.

## Related

- Initializing a workspace from Studio: [init.md](init.md)
- Dry-run planning: [plan.md](plan.md)
- Applying remote-only changes with backups: [pull.md](pull.md)
- Path identity and the default ignore set: [path-safety.md](path-safety.md)

Unit coverage for the destination gate lives in
`tests/Export.Tests.ps1` and requires no network. The exporter as a whole is not
unit-tested, because it authenticates and downloads from Studio; its live
verification is manual.
