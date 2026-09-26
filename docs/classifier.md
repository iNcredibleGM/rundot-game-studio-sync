# Three-way sync classifier

`lib/Classifier.ps1` classifies every path in `BASE ∪ LOCAL ∪ REMOTE` by
**exact SHA-256 content identity**. There is no `mtime` input: identity is the
hash of the file bytes, and no timestamp ever decides direction.

Neither LOCAL nor REMOTE is authoritative. BASE is the last verified shared
state. Any ambiguity is a conflict rather than a guess.

The classifier is a pure function over three in-memory maps. It performs no
network access and no filesystem access of its own, and it never mutates BASE
or any input map. `Plan`/`Status` ([#9](https://github.com/iNcredibleGM/rundot-game-studio-sync/issues/9))
compose it ([plan.md](plan.md)); `Pull` ([#10](https://github.com/iNcredibleGM/rundot-game-studio-sync/issues/10))
filters its rows for applicable downloads, and `Push`
([#17](https://github.com/iNcredibleGM/rundot-game-studio-sync/issues/17))
filters plan rows for applicable utf8 text overwrites and creates ([push.md](push.md)).

`Applicable` is the classifier's own view of a path. `Plan` is stricter for
publish work: utf8 text **overwrites** and **creates**, plus route-allowed
remote deletes, may stay `applicable: true` in the artifact. Binaries and
refused paths are forced to `applicable: false` with explicit reasons
([plan.md](plan.md)). A plan is never
permission to write: `Push` must still re-verify every fingerprint.

## Inputs

Callers already hold canonical identity maps keyed by `/`-separated NFC
relative paths:

| Side | Produced by | Entry spelling |
| --- | --- | --- |
| BASE | `Read-BaseManifest` (`files`) | lowercase `sha256`, `size`, `kind`, `lineEnding`, `hasBom` |
| LOCAL | `Get-LocalManifest` | `Sha256`, `Size`, `LocalDetectedKind`, `LineEnding`, `HasBom` |
| REMOTE | `Get-StableRemoteSnapshot` (`Files`) | `Sha256`, `Size`, `LocalDetectedKind`, `RemoteKind`, `Encoding`, `StagingPath` |

BASE may be `$null`, which is the `-AllowNoBase` case
([init.md](init.md)). A `$null` BASE classifies identically to an empty BASE
map. LOCAL and REMOTE must be real maps: a missing REMOTE means the snapshot
never completed, and reading it as an empty project would classify every path
as locally deleted, so both are hard-failed instead.

## Output

One row per union path, ordinal-sorted by canonical path:

```powershell
[pscustomobject]@{
    Path         = 'src/a.ts'
    Status       = 'upload'
    Applicable   = $true      # may this milestone act on it?
    Reason       = $null      # why not, when Applicable is false
    Warning      = $null      # equal hashes, disagreeing metadata
    Ignored      = $false
    KindChange   = $false
    BaseSha256   = '<hex or $null>'
    LocalSha256  = '<hex or $null>'
    RemoteSha256 = '<hex or $null>'
}
```

Hash comparison is ordinal and case-insensitive: the same bytes may be spelled
`ABC…` or `abc…`, and that is one identity.

## Status vocabulary

All ten statuses are literal strings exported as `$script:SyncStatus*`
constants so `Plan` renders one source of truth.

| Status | Meaning | Applicable |
| --- | --- | --- |
| `unchanged` | BASE, LOCAL, and REMOTE all agree | no |
| `synchronized-change` | LOCAL and REMOTE changed to the same new content | no |
| `synchronized-addition` | untracked in BASE, and LOCAL equals REMOTE | no |
| `settledAbsent` | tracked in BASE, now absent from both sides | no |
| `upload` | LOCAL differs from BASE while REMOTE still matches BASE | yes (text) |
| `download` | REMOTE differs from BASE while LOCAL still matches BASE | yes |
| `conflict` | no single safe direction | no |
| `ignored` | out of sync scope by the default ignore set | no |
| `deleteRemoteCandidate` | LOCAL gone, REMOTE still matches BASE | yes, when the path is route-allowed |
| `deleteLocalCandidate` | REMOTE gone, LOCAL still matches BASE | no |

`Applicable` is about **what a confirmed command may apply**, not about
correctness: this version can publish a utf8 text overwrite, create a utf8 text
file, and apply a route-allowed remote delete via `Push` ([text-create.md](text-create.md),
[delete.md](delete.md), [binary-place.md](binary-place.md)). It never deletes a local file, so a
`deleteLocalCandidate` is classified but never actionable. A reserved or
directory-shaped delete candidate is classified but refused by the route rules.

## Decision table

Notation: BASE / LOCAL / REMOTE. A dash means the path is missing on that
side.

| BASE | LOCAL | REMOTE | Status |
| --- | --- | --- | --- |
| A | A | A | `unchanged` |
| A | B | A | `upload` |
| A | A | B | `download` |
| A | B | C | `conflict` |
| A | B | B | `synchronized-change` |
| — | A | — | `upload` |
| — | — | A | `download` |
| — | A | A | `synchronized-addition` |
| — | A | B | `conflict` |
| A | — | A | `deleteRemoteCandidate` |
| A | A | — | `deleteLocalCandidate` |
| A | — | B | `conflict` |
| A | B | — | `conflict` |
| A | — | — | `settledAbsent` |

`A / — / —` is `settledAbsent`: a deletion already agreed on by both sides is
not a standing `DELETE`. A `deleteRemoteCandidate` is applied only by a
confirmed `Push` ([delete.md](delete.md)); the delete verb is characterized in
[delete-rename-protocol.md](delete-rename-protocol.md).

A delete candidate carries the reason that constrains a `Push` delete:

```text
Reason   : Pull never deletes anything, locally or remotely.
           A deletion candidate is reported here and applied only by a confirmed Push.
           Studio cannot make a delete conditional: there is no ETag or
           version field and If-Match is ignored, so a stale delete cannot be
           refused server-side.
```

That third line is the observed constraint, not a policy statement. Studio
exposes no ETag, no version, and no honoured `If-Match` on the delete route, so
a delete computed against content that has since changed cannot be refused by
the server. Any guard has to run on the client, immediately before the request
([delete-rename-protocol.md](delete-rename-protocol.md)).

## Ignore precedence

The ignore check runs **before** the decision table. A path matching
`Test-IgnoredSyncPath` ([path-safety.md](path-safety.md)) is classified
`ignored` regardless of what any side contains, so:

- an ignored BASE path never becomes `deleteRemoteCandidate`
- an ignored LOCAL path never becomes an `upload`
- an ignored REMOTE path never becomes a `download`
- an ignored path with divergent content is `ignored`, not `conflict`

This is why `.rundot-sync/` can never be an upload candidate.

## Post-processing

After the table, a row is adjusted in three ways.

**Metadata disagreement (equal hashes).** Content hash is the only decision
input, so equal hashes stay a no-op status. When two sides declare the same
field with different values, the row keeps its no-op status and gains a
`Warning`. Fields are `size`, `kind`, `lineEnding`, and `hasBom`, and a field
counts only when **both** sides declare it: BASE omits `lineEnding`/`hasBom`
for binary entries, and a remote snapshot entry carries no line-ending
diagnostics, so those absences are not disagreements.

```text
Content hashes agree, but recorded metadata disagrees for: size, kind.
```

**Unsupported kind change.** A same-path text ↔ binary change is not a normal
upload or download. When the kinds differ and the content genuinely differs,
the row becomes `conflict` with `KindChange = $true`. When the hashes are
equal, the kind disagreement is only metadata: equal bytes win, so the row
stays a no-op plus a `Warning`.

**Binary upload candidates.** A binary upload keeps `Status = 'upload'` and is
marked `Applicable = $true` at the classifier layer, same as text. Reserved
paths, directory-shaped paths, empty files, and kind mismatches are refused in
`Plan` and again in `Push` ([binary-place.md](binary-place.md)).

## Determinism and purity

- Classification depends only on the three identities, never on the path name
  or on other paths.
- Rows are ordinal-sorted by canonical path, and two calls over the same input
  produce the same order and statuses.
- Input maps are never modified, and no BASE file is written.
- A LOCAL file that appears after a scan simply appears in the next plan; an
  earlier result does not retroactively change.

## Related contracts

- Duplicate canonical paths in `GET /files` abort inside
  `Get-RemoteManifestFileRows` before any classification
  ([remote-snapshot.md](remote-snapshot.md)).
- A listed path that 404s mid-snapshot is a torn read, not a remote deletion;
  the snapshot retries and then aborts, so a partial map is never classified.
- `Plan` must call `Assert-BaseOwnership` before reading BASE
  ([base-schema.md](base-schema.md)).
- Why a delete candidate is applied only by a confirmed `Push`, and what the
  delete verb actually does: [delete.md](delete.md),
  [delete-rename-protocol.md](delete-rename-protocol.md).

Unit coverage lives in `tests/SyncEngine.Tests.ps1` and requires no network.
