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
| Malformed base64 | Discard, retry; after 3: idle message |

A 404 while capturing a path that ManifestBefore listed means the project
changed while being read. It is not classified as `deleteRemoteCandidate`.
