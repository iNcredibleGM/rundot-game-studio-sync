# Stable remote snapshot

The Studio `GET /files` list is not known to be an atomic snapshot. A
REMOTE capture must detect torn reads before it is used as truth. This is
a point-in-time observation, not a remote lock.

`Get-StableRemoteSnapshot` in `lib/Snapshot.ps1` is the gate later Init
and Plan work must call. It does not write BASE. Malformed API payloads
are never fingerprinted into snapshot identity and never become BASE.

## Procedure

1. `ManifestBefore = GET /files` — validate and fingerprint
2. Download every listed `type=file` entry into
   `<LocalDir>/.rundot-sync/temp/remote-snapshot/<attempt>/`
3. `ManifestAfter = GET /files` — validate and fingerprint
4. If Before ≠ After, discard staging and retry
5. Maximum 3 attempts, then abort:

```text
The remote project changed while being read. No plan was generated.
Try again when the project is idle.
```

Downloads use the original API `path` string (Studio may require a
leading `/`). Staging keys and on-disk relative paths use canonical `/`
NFC identity from `ConvertTo-CanonicalSyncPath`. Default ignores do not
apply: every listed file is downloaded.

### Oversized remote files are captured as unverifiable

`GET /file` refuses a payload over **2,000,000 bytes** with HTTP 413
`file too large to view` ([protocol.md](protocol.md)). Such a path can never be
read back, but it is still visible in the listing with its `size`. The snapshot
does **not** fail the whole project for it (#57): the path is captured by its
list identity and marked `Unverifiable = $true` — path, `size`, and
`kind=binary`, with **no hash and no staged bytes**, and `GET /file` is never
called for it. The rest of the snapshot proceeds.

```text
Sha256            : (none)
Size              : 3120444
LocalDetectedKind : binary
RemoteKind        : binary
StagingPath       : (none)
Unverifiable      : True
```

`Plan` reports every such path under `UNVERIFIABLE` and never as `unchanged`, so
the tool never claims "in sync" for bytes it cannot verify
([classifier.md](classifier.md)). `Pull` never downloads one and `Push` never
rewrites one ([pull.md](pull.md), [push.md](push.md)). An oversize binary
**create** (remote path absent) is unaffected and still publishes through the
ETag route; an oversize **replace** stays refused
([binary-place.md](binary-place.md)).

Decoded bytes are written, then hashed with `Get-LocalFileIdentity`.
Identity is SHA-256 of those exact bytes, not of the JSON string. API
`encoding` `utf8` maps to `remoteKind` `utf8`; `base64` maps to
`binary`. Studio text `size` metadata may be character-oriented; torn-read
comparison uses API-reported list fields, not decoded UTF-8 byte length.

## Fingerprint

`Get-RemoteManifestFingerprint` hashes **validated** list identity, never
the raw HTTP body. Array order and JSON whitespace do not change the
hash.

Each `type=file` row is a tab-separated `name=value` line in this order.
A field is omitted when it is absent on that entry:

- `canonicalPath`
- `size`
- `encoding`
- `kind`
- `type`
- identity extras if the API provides them: `id`, `etag`, `hash`,
  `sha256`, `contentHash`, `version`, `revision`, `updatedAt`

Rows are sorted with ordinal comparison, then SHA-256 of the UTF-8
document (lowercase hex). Directory entries are not sync entities.

If the API has no per-file etag or hash, a same-path same-size content
swap is invisible to this protocol.

A valid snapshot stores both `remoteManifestHashBefore` and
`remoteManifestHashAfter`. They must be equivalent; both are kept for
audit. Callers persist them later (BASE / `last-plan.json`). This library
does not add those fields to BASE schema v1.

## Staging

```text
<LocalDir>/.rundot-sync/temp/remote-snapshot/<attempt>/
```

`.rundot-sync/` is in the default ignore set, so staging is never a local
inventory or upload candidate.

On retry or abort, staging is deleted so a partial tree cannot be
promoted. On success, the winning attempt directory is kept for the
caller to move into `LocalDir`.

`Init -InitMode FromRemote` consumes it by **renaming** each top-level
staging entry into `LocalDir`, then clears this staging tree once BASE is
written ([init.md](init.md)). The rename is same-volume, so there is no
partial-copy window; a rename that fails midway is rolled back into staging
and no BASE is written.

Returned file entries are hashes and diagnostics only (`Sha256`, `Size`,
`LocalDetectedKind`, `LineEnding`, `HasBom`, `RemoteKind`, `Encoding`,
`StagingPath`). They do not include `content` or tokens.

## Retry and abort

| Condition | Action |
| --- | --- |
| Duplicate canonical paths | Abort immediately (no ManifestAfter, no download) |
| Path safety / representability | Abort immediately |
| HTML, non-JSON, unexpected JSON shape | Abort immediately |
| Unknown `encoding` | Abort immediately |
| HTTP 401 / 403 | Abort immediately |
| ManifestBefore fingerprint ≠ ManifestAfter | Discard, retry; after 3: idle message |
| Listed path, `GET /file` returns 404 | Discard, retry; after 3: idle message. Not a remote deletion |
| Listed path over Studio's 2,000,000-byte read limit | Capture as `Unverifiable = $true` (path + size, no hash); never call `GET /file` for it; continue |
| Malformed base64 | Discard, retry; after 3: idle message |

A 404 while capturing a path that ManifestBefore listed means the project
changed while being read. It is not classified as `deleteRemoteCandidate`.
