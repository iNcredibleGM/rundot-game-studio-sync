# Path identity, safety, and default ignores

Sync compares files by one canonical path form. Every remote and local path
must pass safety validation. Identity ambiguity hard-fails the run. Partial
trees look like deletions, so unsafe paths are never skipped.

This matcher is the documented default set. There is no `.rundotignore`
parser in this milestone.

## Canonical form

Identity keys are:

- relative to the workspace root
- `/` separators
- no leading slash
- no trailing slash for files
- NFC (`FormC`)
- no `.` or `..` segments

Never compare an absolute Windows path to a remote API path. Convert both
sides with `ConvertTo-CanonicalSyncPath` or
`ConvertTo-CanonicalSyncPathFromLocal` first.

Remote Studio paths may arrive with one leading `/`. That slash is stripped
as input adaptation. The resulting identity still has no leading slash.

## Hard-fail the entire run

- `../foo`, `..\foo`, `/` after adaptation, `C:\foo`, `\\server\share`
- embedded NUL
- empty segments such as `foo//bar` (do not collapse them)
- Win32 reserved components, including extensions: `CON`, `PRN`, `AUX`,
  `NUL`, `COM1`–`COM9`, `LPT1`–`LPT9` (`CON.txt`, `foo/PRN`, `foo/NUL.json`)
- case-insensitive collisions (`Foo.ts` vs `foo.ts`)
- Unicode NFC/NFD identity collisions (two distinct inputs, one NFC key)
- paths this runtime cannot represent (invalid filename characters, or a
  combined path longer than MAX_PATH without `\\?\`)
- reparse points, junctions, symlinks, and OneDrive/cloud placeholders
  (`ReparsePoint`, `Offline`, recall-on-open, recall-on-data-access)

`CONSOLE.ts` is not a reserved device name.

## Default ignore matcher

`Get-DefaultSyncIgnorePatterns` / `Test-IgnoredSyncPath` match canonical
`/` paths, case-insensitively. Directory patterns match that segment
anywhere. Globs and exact names match the final component only.

| Pattern | Kind |
| --- | --- |
| `.git/` | directory segment |
| `.rundot-sync/` | directory segment |
| `node_modules/` | directory segment |
| `dist/` | directory segment |
| `build/` | directory segment |
| `out/` | directory segment |
| `.vs/` | directory segment |
| `.idea/` | directory segment |
| `.vscode/` | directory segment |
| `.rundot-studio-export/` | directory segment |
| `Thumbs.db` | exact name |
| `desktop.ini` | exact name |
| `.DS_Store` | exact name |
| `*.swp` | glob on final component |
| `*~` | glob on final component |
| `*.tmp` | glob on final component |
| `*.bak` | glob on final component |

`out.ts` does not match `out/`.

These ignores apply to local inventory for later Plan/Pull. Export still
downloads remote files even when their names match this set, and the raw
exporter does **not** consult this matcher when checking its destination: every
ignore exception would widen the set of existing files it could overwrite
([export.md](export.md)).

## Classifier contracts

- `.rundot-sync/` must never become an upload candidate.
- If `Test-IgnoredSyncPath` is true for a BASE path, never emit
  `deleteRemoteCandidate`. Classify it as ignored instead.

These are implemented by the ignore-first rule in
[classifier.md](classifier.md): the ignore check runs before the three-way
decision table, so an ignored path is `ignored` and is never an upload,
a download, a delete candidate, or a conflict.
