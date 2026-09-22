# RUN.game Studio Sync

Unofficial tool for syncing a RUN Game Studio project with a local directory.

> This project is not affiliated with or endorsed by RUN, RUN.game, Series, Inc., or the maintainers of the official `rundot` CLI.

## What it does

`game-studio-sync.ps1` treats a Studio project and a local directory as two
sides that can drift apart, and helps you move changes **from Studio to your
machine** without guessing:

- **Init** builds a workspace and records a verified BASE
- **Plan** / **Status** show what a sync would do, without writing
- **Pull** applies clean remote-only changes, with a backup of everything it replaces
- **Push** publishes clean local text overwrites to Studio after confirmation,
  and applies confirmed remote deletes, with a backup of every remote original
  it replaces or removes

**Remote writes are narrow on purpose.** `Push` may overwrite existing utf8
text files and delete a remote file whose local copy is gone. It never creates
files and never uploads binaries. There is no `Apply` shortcut that skips the
plan fingerprint gates.

If all you want is a plain raw copy of a project, the original exporter
(`game-studio-export.ps1`) still does that into a new or empty directory —
see [Raw export](#raw-export-new-or-empty-directories-only).

## Prerequisites

- Windows
- Windows PowerShell 5.1 compatibility baseline
- Official `rundot` CLI ([installation / docs](https://github.com/series-ai/venus-sdk-docs/blob/main/rundot-developer-platform/getting-started.md))
- A RUN account with access to the Game Studio project
- Network access to RUN Game Studio

Install the official CLI on Windows:

```powershell
irm https://github.com/series-ai/rundot-cli-releases/releases/latest/download/install.ps1 | iex
```

Verify and authenticate:

```powershell
rundot --help
rundot login
```

Git is optional; it is only needed if you want to version your project files.

## Quick start

The public workflow is:

```text
Init → edit → Plan → Pull (only when remote changed) → Push (only when local should publish)
```

`Plan` is the hub: it compares BASE, LOCAL, and REMOTE and tells you which
command, if any, applies next. `Pull` and `Push` are conditional — run them
only when the plan report shows a clean row for that direction.

### 1. Initialize a workspace

Point `Init` at a **new or empty** directory. It downloads the project, proves
every file matches, and only then records BASE.

```powershell
.\game-studio-sync.ps1 `
    -ProjectId "YOUR_PROJECT_ID" `
    -LocalDir ".\dev" `
    -Command Init `
    -InitMode FromRemote
```

`-FromRemote` is accepted as a shorter alias for `-InitMode FromRemote`.

Already have the files? Use `-InitMode Adopt` to attach sync metadata to an
existing tree instead. Adopt records only paths that already match Studio
exactly, so it never claims agreement it did not verify.

**Already have a diverged folder?** `Init -InitMode FromRemote` only works on a
new or empty directory. On a tree that already has files, copy it first and run
`Init -InitMode Adopt` on the copy. Adopt records BASE only for byte-identical
paths; files that differ stay unresolved. A later `Push` still publishes only
clean text overwrites against that BASE — it will not publish conflicts, text
creates, or binaries.

### 2. Edit your files normally

Work in `.\dev` however you like. Nothing about the workspace is special: it is
an ordinary folder of project files.

### 3. See what would change

```powershell
# Dry run, and save the plan artifact to .rundot-sync/last-plan.json
.\game-studio-sync.ps1 -ProjectId "YOUR_PROJECT_ID" -LocalDir ".\dev" -Command Plan

# The same report without writing anything (no artifact — cannot feed Push)
.\game-studio-sync.ps1 -ProjectId "YOUR_PROJECT_ID" -LocalDir ".\dev" -Command Status
```

`Plan` uses three states: **BASE** (the last verified shared state), **LOCAL**
(your files), and **REMOTE** (Studio now). Neither LOCAL nor REMOTE is
authoritative — any ambiguity is reported as a conflict rather than guessed at.

Your local edits show up as `UPLOAD` candidates. Only a clean utf8 text
overwrite may be actionable, and only after you confirm a `Push` run (or pass
`-ForcePush` / `-ConfirmPush` to skip the prompt). **A plan is never
permission to write** — Push re-verifies every fingerprint, backs up every
remote original, and asks for confirmation before any `PUT`.

`Plan` writes `.rundot-sync/last-plan.json`, which `Push` consumes.
`Status` runs the same engine but writes nothing, so it cannot feed `Push`.

### 4. Pull clean remote-only changes (when remote changed)

Run `Pull` **only after `Plan`** when the report shows clean remote-only
`DOWNLOAD` rows — a file that moved on in Studio while your copy still matched
BASE (`BASE=A LOCAL=A REMOTE=B`), or a remote-only addition. Skip this step
when nothing on Studio changed since BASE.

```powershell
.\game-studio-sync.ps1 -ProjectId "YOUR_PROJECT_ID" -LocalDir ".\dev" -Command Pull
```

`Pull` applies **only** clean remote-only changes, meaning a file that moved on
in Studio while your copy still matched BASE. Your local edits, conflicts, and
deletions are reported and left alone.

Before replacing anything it copies the original into
`.rundot-sync/backups/<timestamp>/`, prints the backup root, and asks you to
type `yes`. `-ForcePull` skips the prompt for unattended runs but never skips a
backup.

### 5. Push clean local text overwrites (when local should publish)

Run `Push` **only after `Plan`** when the report shows a clean utf8 text
overwrite (`BASE=A LOCAL=B REMOTE=A`) and that row is applicable. Skip this
step when you have no local text change to publish.

Run `Plan` first so `.rundot-sync/last-plan.json` records the fingerprints
Push will check:

```powershell
.\game-studio-sync.ps1 -ProjectId "YOUR_PROJECT_ID" -LocalDir ".\dev" -Command Push
```

Type `yes` when Push lists the remote files it will overwrite. For unattended
runs:

```powershell
.\game-studio-sync.ps1 -ProjectId "YOUR_PROJECT_ID" -LocalDir ".\dev" -Command Push -ForcePush
```

`-ConfirmPush` is the same skip-prompt alias as `-ForcePush`.

`Push` publishes only utf8 text overwrites (`BASE=A LOCAL=B REMOTE=A`) and
applies confirmed remote deletes (`BASE=A LOCAL=— REMOTE=A`). Text creates,
binaries, conflicts, and local deletions are reported and left alone. Before
each overwrite or delete it copies the previous remote bytes into
`.rundot-sync/backups/<timestamp>/`. If anything changed since `Plan`, Push
refuses the whole run and asks you to plan again.

**Push will:**

- After you type `yes` (or pass `-ForcePush` / `-ConfirmPush`), overwrite
  existing utf8 text files whose remote bytes still match the plan
- Ask for a second, separate `yes` before removing any remote file, and list
  every path it would remove
- Copy each remote original into `.rundot-sync/backups/<timestamp>/` before any
  `PUT` or `DELETE`
- Move BASE only after every `PUT` echo-verifies and every delete is proven
  absent from `GET /files`

**Push will not:**

- Create files, upload binaries, or rename anything on Studio
- Delete a path under `.git`, `.gitignore`, `.rundot-sync`, or `.rundot`, or a
  directory-shaped path
- Merge divergent text or resolve a `CONFLICT` — conflicts are printed and
  skipped; there is no automatic conflict resolution in this version

## Your workspace metadata

Sync state lives in `<LocalDir>\.rundot-sync\`:

```text
<LocalDir>/.rundot-sync/
  base-manifest.json   # BASE: path, size, and SHA-256 per tracked file
  last-plan.json       # the most recent Plan artifact
  journal.jsonl        # metadata-only record of pulls and pushes
  backups/             # pre-overwrite and pre-delete copies; Pull stores local originals, Push stores previous remote bytes
  temp/                # torn-read staging, cleared after each run
```

**Metadata only: `base-manifest.json`, `last-plan.json`, `journal.jsonl`.**
These hold canonical paths, sizes, SHA-256 hashes, and counts. They never
contain file contents, access tokens, or refresh tokens.

**Full copies: `backups/<timestamp>/`.** This is the exception, and it matters.
Before `Pull` overwrites a local file, or before `Push` overwrites or deletes a
remote file, the tool copies the *entire original* into the backup set so you
can restore it. **A backup set can therefore contain complete file contents.**

Both are sensitive, and for different reasons. `.rundot-sync` reveals the
*names* of every file in your project, and a backup set may additionally hold
the full text of files you would rather not publish. A backup is also the only
copy of that content once Studio has moved on, so delete a backup set only when
you are sure you no longer need the original.

- **Do not commit it.** The repository ships a `.gitignore` with
  `.rundot-sync/` for this reason.
- **Do not paste it into bug reports** if your file names are private.

### One initialized workspace per project

BASE is bound to **one Studio project and one folder** (`projectId` plus a
fingerprint of the resolved local path). A `.rundot-sync` copied elsewhere does
not take effect: `Plan` and `Pull` hard-fail on an ownership mismatch rather
than acting on a BASE that describes a different project or folder.

So if you work on the same project from a **second machine**, do not copy
`.rundot-sync` to it. Instead:

1. Pick a new or empty directory on that machine.
2. Run `Init -InitMode FromRemote` there, which records that machine's own BASE.
3. Copy your in-progress work into it.
4. Run `Plan`. Your copied-in work appears as `UPLOAD` candidates and any
   diverged file as a `CONFLICT` — review them yourself.

Multi-machine BASE is a [non-goal](#not-in-this-version), so the two machines
each keep their own independent BASE.

## Commands

| Command | Writes | Purpose |
| --- | --- | --- |
| `Init -InitMode FromRemote` | LOCAL + BASE | Build a trusted workspace from Studio into an empty directory |
| `Init -InitMode Adopt` | BASE only | Attach sync metadata to an existing tree, recording only proven matches |
| `Plan` | `.rundot-sync/last-plan.json` | Dry-run report of what a future sync would consider |
| `Status` | nothing | The same report, without saving an artifact |
| `Pull` | LOCAL + BASE | Apply clean remote-only changes, with backups |
| `Push` | REMOTE + BASE | Publish clean local text overwrites from the last plan, with remote backups |

Full contracts: [Init](docs/init.md), [Plan / Status](docs/plan.md),
[Pull](docs/pull.md), [Push](docs/push.md), [BASE schema](docs/base-schema.md).

`Plan`, `Pull`, and `Push` **refuse without a BASE** and point you at `Init`:
without a recorded shared state there is no verified direction. The refusal
happens before authentication, so a workspace that cannot plan never asks for a
token.

Every dry run ends with:

```text
Dry run only. No remote files were modified.
This plan is a point-in-time observation, not permission to write.
WARNING: This tool uses unofficial remote API routes that may change.
```

## Default ignores

Sync skips a fixed set of paths so build output and editor junk do not look
like project files that were deleted:

| Path | Match |
| --- | --- |
| `.git/`, `.rundot-sync/`, `node_modules/` | directory segment |
| `dist/`, `build/`, `out/`, `.vs/`, `.idea/`, `.vscode/`, `.rundot-studio-export/` | directory segment |
| `Thumbs.db`, `desktop.ini`, `.DS_Store` | exact file name |
| `*.swp`, `*~`, `*.tmp`, `*.bak` | file name pattern |

There is **no `.rundotignore`** in this version. The list above is fixed and
documented in [docs/path-safety.md](docs/path-safety.md).

One important asymmetry: the **raw exporter does not apply these ignores**. It
downloads everything Studio lists. The ignore set applies to the local
inventory that `Plan` and `Pull` compare.

## Raw export: new or empty directories only

`game-studio-export.ps1` is the original bulk exporter. It writes the complete
editable project filesystem to disk, byte-for-byte, and can optionally archive
Studio conversation threads.

```powershell
.\game-studio-export.ps1 `
    -ProjectId "YOUR_PROJECT_ID" `
    -OutDir ".\raw-copy" `
    -IncludeThreads
```

It only writes into a **new or empty** `-OutDir`. Only `.git` and `.gitignore`
may already be present.

If the directory already contains project files, or a `.rundot-sync`
workspace, the exporter **refuses and writes nothing**. That is deliberate:
export was never a safe way to refresh an existing tree, because it would
overwrite local work with whatever Studio currently holds. You will get a
message pointing at the sync command instead:

```powershell
.\game-studio-sync.ps1 -ProjectId "YOUR_PROJECT_ID" -LocalDir ".\dev" -Command Pull
```

See [docs/export.md](docs/export.md) for the exact rules.

## Authentication

Authentication precedence:

1. Fresh official `rundot` CLI access token from `%APPDATA%\.rundot\prod.session.json`
2. Previously saved Firebase refresh credentials from `%APPDATA%\.rundot\studio-export.auth.json`
3. Firebase bootstrap JSON from clipboard
4. Studio bearer token from clipboard
5. Manual secure bearer-token paste

Notes:

- Studio validation is authoritative. A candidate token is always confirmed by
  requesting the project manifest.
- JWT decoding is used only locally to inspect expiry; signatures are not verified.
- A 5-minute safety window applies before the CLI token is attempted, because a
  near-expiry token previously produced HTTP 401.
- CLI refresh-token support is not yet implemented. If the CLI token is expired
  or near expiry, run `rundot login` again, or use the fallbacks above.
- Neither script modifies the official CLI session file, and neither runs
  `rundot login` for you.

## Privacy and the network

**This tool has no telemetry.** It does not phone home, check for updates, or
report usage. The only network requests it makes are:

- `GET` requests to RUN Game Studio (`venus-studio-prod.series-ai.workers.dev`)
  for the project manifest and file contents, and
- a `POST` to Google's `securetoken.googleapis.com` endpoint when refreshing
  saved Firebase credentials.

Both happen only when you run a command. No project data, file contents, paths,
or tokens are sent anywhere else.

Saved credentials are stored encrypted with Windows DPAPI. **Never include
access tokens, refresh tokens, or authentication files in bug reports.**

> Sync uses **unofficial** remote API routes observed from normal Studio
> traffic. They are undocumented and may change without notice, which would
> break the tool until it is updated.

## Troubleshooting

### CLI session found but Studio returns 401

1. Run `rundot login`
2. Rerun the command promptly
3. If it still fails, allow the tool to continue to its saved/clipboard/manual fallback methods

### "The remote project changed while being read"

Studio's file list is not known to be atomic, so a capture that changes
mid-read is discarded and retried, up to three times. This message means it
never settled: **nothing was written.** Try again when the project is idle.
See [docs/remote-snapshot.md](docs/remote-snapshot.md).

### "This workspace has no BASE manifest"

`Plan` and `Pull` need a recorded shared state. Run `Init` first. If you are
sure you want a report without one, `Plan -AllowNoBase` exists as an advanced
escape hatch, but it states plainly that every sync direction is untrusted.
`Pull` has no such mode.

### The exporter refuses my directory

That is the intended behavior. See
[Raw export](#raw-export-new-or-empty-directories-only).

## Not in this version

Deliberately out of scope, so nothing here does them by accident:

- Applying local changes without a fresh `Plan` (`Apply`)
- Automatic conflict resolution
- Remote create, binary upload, rename, or delete
- Binary upload or adopt
- Deleting anything automatically, locally or remotely
- `.rundotignore` custom patterns
- Newline or encoding normalization
- File watching, device IDs, or a shared multi-machine BASE

Direction is in [ROADMAP.md](ROADMAP.md); the acceptance evidence for this
milestone is in [docs/acceptance.md](docs/acceptance.md).

## Contributing

How to branch, open pull requests, and work on a milestone is in [CONTRIBUTING.md](CONTRIBUTING.md). Automated agents must also read [AGENTS.md](AGENTS.md).

## Development note

The original exporter and protocol investigation were iterated with OpenAI GPT-5.6 Sol/Terra/Luna while manually observing Studio network behavior. Subsequent local refactoring and the CLI-auth integration were developed in Cursor using local Ollama tooling with DeepSeek V4 Flash, with live behavior verified manually.
