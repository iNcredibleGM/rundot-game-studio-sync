# BASE schema version 1

BASE is the last verified shared snapshot of a local workspace. Neither
LOCAL nor REMOTE is authoritative. Identity is SHA-256 of exact file
bytes. `mtime` never decides direction.

This schema is hashes and metadata only. It does not store file contents,
access tokens, refresh tokens, or `%APPDATA%\.rundot\` auth paths.

`Plan` and `Pull` must call `Assert-BaseOwnership` before using a BASE. Both do
so through `Resolve-RundotSyncPlanBase`, which also applies the no-BASE gate
([plan.md](plan.md)). `Pull` additionally refuses `-AllowNoBase`: it has no
untrusted mode ([pull.md](pull.md)).

## Writers

Two commands write BASE: `Init` creates it, and `Pull` replaces it after a
fully verified success ([init.md](init.md), [pull.md](pull.md)).

- `Init -InitMode FromRemote` records every verified remote file.
- `Init -InitMode Adopt` records only paths whose content hash matched
  exactly on LOCAL and REMOTE, so an Adopted BASE may be a partial one. A
  differing, local-only, or remote-only path is unresolved and never becomes
  a BASE claim.
- `Pull` overlays the re-verified identity of each path it applied onto the
  existing entries, additively. It writes BASE only after every written file
  has been re-hashed against REMOTE, and never drops an existing entry.

`Plan` reads BASE but never writes it. It persists only
`.rundot-sync/last-plan.json` ([plan.md](plan.md)), so a plan can never change
recorded shared state. A failed `Pull`, like a failed `Init`, leaves the
previous BASE authoritative.

## Layout

Workspace state lives under `<LocalDir>/.rundot-sync/`:

```text
<LocalDir>/.rundot-sync/
  base-manifest.json
  last-plan.json
  journal.jsonl
  backups/
  temp/
```

`Initialize-RundotSyncLayout` creates `backups/` and `temp/` only. It does
not plant `last-plan.json` or `journal.jsonl`; `Plan` creates `last-plan.json`
when it runs ([plan.md](plan.md)). `.rundot-sync/` is in the
default ignore set, so it is never a local inventory or upload candidate.

## `base-manifest.json`

```json
{
  "schemaVersion": 1,
  "toolVersion": "0.1.3",
  "projectId": "<studio project id>",
  "localRootFingerprint": "<64 lowercase hex>",
  "capturedAt": "<ISO-8601 UTC>",
  "files": {
    "src/foo.ts": {
      "sha256": "<64 lowercase hex>",
      "size": 123,
      "kind": "utf8",
      "lineEnding": "lf",
      "hasBom": false
    },
    "public/logo.png": {
      "sha256": "<64 lowercase hex>",
      "size": 999,
      "kind": "binary"
    }
  }
}
```

`schemaVersion` is `1`. `toolVersion` names the milestone string that produced
the manifest, and is independent of the schema number. `Init` first wrote BASE
in v0.1.3, so no v0.1.2 manifest exists in practice. `Assert-BaseOwnership`
checks `schemaVersion`, not `toolVersion`: a workspace written by a different
tool version stays readable.

`files` is a complete map of files that existed after the last successful
verified pull or init. Keys are canonical `/` NFC paths. Missing paths are
simply absent. BASE is not a tombstone log. Empty directories are not sync
entities.

Binary entries omit `lineEnding` and `hasBom`. Text `lineEnding` is `lf`,
`crlf`, `mixed`, or `none`. Size is diagnostic only. There is no `mtime`.

`Save-BaseManifest` writes only allowed keys. Extra fields such as
`content` are stripped and must never appear on disk.

## Ownership

One BASE binds one Studio `projectId`, one local workspace root, and schema
version 1.

`localRootFingerprint` is SHA-256 of the UTF-8 bytes of the NFC, resolved
full path of `LocalDir` with no trailing slash, using on-disk casing from
`Get-Item`.

`Assert-BaseOwnership` hard-fails unless all three match:

- `schemaVersion` is `1`
- `projectId` is an exact ordinal match
- `localRootFingerprint` matches this folder

Copied `.rundot-sync` metadata cannot drive a different project or folder.

## Atomic write

A crash must not leave a truncated live BASE.

1. Ensure `.rundot-sync/backups` and `temp`.
2. Write UTF-8 with no BOM to `base-manifest.json.tmp`.
3. Flush to disk and close.
4. If `base-manifest.json` exists, atomically replace it (this runtime
   requires a same-directory backup name; the `.bak` is deleted after a
   successful replace). If it does not exist, move the tmp into place.
5. Never write `base-manifest.json` in place.

A leftover `.tmp` after a crash is acceptable. `Read-BaseManifest` reads
only the complete live file and returns `$null` when that file is missing.

## Local identity vs BASE

Local inventory (`Get-LocalManifest`) records `localDetectedKind` from
bytes. The API `encoding` maps to `remoteKind` (`utf8` or `base64` →
`binary`) separately. Same-path text ↔ binary is an unsupported kind
change, not a normal upload: the classifier
([classifier.md](classifier.md)) reports a text ↔ binary change with
differing content as `conflict` with `KindChange = $true`, and keeps a
hash-equal one as a no-op with a metadata warning.
