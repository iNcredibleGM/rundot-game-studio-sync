# Safe Push

`Push` is the only command in this milestone that writes to REMOTE. It consumes
the last `Plan` artifact, re-verifies every fingerprint, and publishes only
clean utf8 text overwrites via documented `PUT /file`.

`Push` never changes LOCAL files, never creates remote files, never uploads
binaries, and never deletes anything ([classifier.md](classifier.md),
[text-write-protocol.md](text-write-protocol.md)).

```powershell
.\game-studio-sync.ps1 -ProjectId <id> -LocalDir <dir> -Command Plan
.\game-studio-sync.ps1 -ProjectId <id> -LocalDir <dir> -Command Push -ConfirmPush
```

## What a run does

1. **BASE gate.** `Resolve-RundotSyncPlanBase` runs **before** authentication
   ([init.md](init.md)). Push has no untrusted mode: without a verified BASE
   there is no shared state to push against, so `-AllowNoBase` is refused.
2. **Plan artifact.** `Read-PlanArtifact` loads `.rundot-sync/last-plan.json`.
   A missing or malformed artifact refuses before authentication.
3. **Authentication.** The shared token flow used by every command.
4. **LOCAL.** `Get-LocalManifest` inventories the workspace by exact bytes.
5. **REMOTE.** `Get-StableRemoteSnapshot` captures a torn-read-protected
   snapshot ([remote-snapshot.md](remote-snapshot.md)).
6. **Fingerprint gates.** The engine compares the artifact to the live BASE,
   LOCAL manifest hash, and REMOTE manifest hashes. Any drift refuses the
   whole run.
7. **Select.** Only applicable `upload` rows that are still clean utf8 text
   overwrites may be published.
8. **Confirm.** If any publishable row remains, `-ConfirmPush` is required.
   Without it the run fails closed before any `PUT`.
9. **Apply.** For each selected path: re-hash LOCAL, `GET` remote, verify
   `expectedRemoteHash`, `PUT` utf8 text, echo-verify the response hash.
10. **Update BASE.** After every `PUT` succeeds, BASE is overlaid additively
    with the published local identity.

## Allowed automatic remote writes

Exactly one classification may be published:

| BASE | LOCAL | REMOTE | Status | Push |
| --- | --- | --- | --- | --- |
| A | B | A | `upload` (utf8 text) | applies |

`BASE=A LOCAL=B REMOTE=A` means LOCAL moved on while REMOTE still matched the
last verified shared state. REMOTE owns no change, so nothing is lost on Studio.

## Must not publish

| BASE | LOCAL | REMOTE | Status | Push |
| --- | --- | --- | --- | --- |
| — | A | — | `upload` (text create) | skipped: no create route |
| — | A | — | `upload` (binary) | skipped: binary blocked |
| A | A | B | `download` | skipped: Push never downloads |
| A | B | C | `conflict` | skipped: no safe direction |
| A | B | B | `synchronized-change` | skipped: both sides already agree |
| A | — | A | `deleteRemoteCandidate` | skipped: Push does not delete |
| any | any | any | `ignored` | skipped: out of sync scope |
| text ↔ binary | | | `conflict` | skipped: `KindChange` |

Every skipped path is printed with its status and a reason. A skipped path is
never a silent no-op.

The plan artifact may mark only utf8 text overwrites as `applicable: true`
([plan.md](plan.md)). Even when a row is applicable in the artifact, Push
re-classifies it live and refuses the whole run if it is no longer a clean
upload.

## `-ConfirmPush`

Push is fail-closed without `-ConfirmPush`. The switch is not a way to bypass
fingerprint checks or the per-file `GET` hash gate; it only acknowledges that
the listed remote text files will be overwritten.

There is no `-ForcePush` in this milestone: unattended push is intentionally
not supported yet ([#18](https://github.com/iNcredibleGM/rundot-game-studio-sync/issues/18)).

### Concurrent-edit guard

Immediately before each `PUT`, Push re-hashes the local file and compares it to
the plan row. If the file changed since `Plan`, Push aborts without writing
that path. The remote hash is also re-checked with a live `GET` immediately
before each `PUT`.

## BASE update

BASE records the last verified shared state, so it moves only after every
selected `PUT` has echo-verified:

1. stable REMOTE snapshot
2. plan fingerprint gates
3. live selection
4. per-file `GET` + `PUT` + echo verify
5. additive overlay onto the existing BASE entries

The update is **additive**, like `Pull`: existing BASE entries are preserved
and only published paths are overlaid with the identity re-hashed from LOCAL.
BASE is not a tombstone log, so nothing silently drops out.

If any required step fails, the previous BASE remains authoritative. A failed
`Push` never partially updates BASE ([#17](https://github.com/iNcredibleGM/rundot-game-studio-sync/issues/17)).

## Report

The report prints applied paths (marked `overwrite`), skipped paths with
reasons, a summary, and the two closing lines:

```text
Push writes REMOTE only. It never changes LOCAL files.
WARNING: This tool uses unofficial remote API routes that may change.
```

Push is not a dry run, so it does not print the `Plan`/`Status` closing lines
([plan.md](plan.md)). A no-op push reports that no publishable text overwrite
remains and that BASE was not updated.

## Failure behavior

| Failure | Result |
| --- | --- |
| Missing BASE | Refuse before authentication; `-AllowNoBase` is rejected |
| Missing `last-plan.json` | Refuse before authentication |
| Expired or stale plan fingerprints | Refuse before any `PUT` |
| Applicable row no longer a clean upload | Refuse the whole run |
| Missing `-ConfirmPush` | Refuse before any `PUT` |
| Local file changed since the scan | Refuse before that `PUT` |
| Remote hash mismatch on `GET` | Refuse before that `PUT` |
| `PUT` or echo verify failure | Abort; BASE unchanged |
| Unstable snapshot (3 attempts) | Abort, no writes, old BASE |

## Related contracts

- The classifier and its status vocabulary: [classifier.md](classifier.md).
- Plan artifact shape and applicability: [plan.md](plan.md).
- Documented text `PUT` route: [text-write-protocol.md](text-write-protocol.md).
- BASE ownership, layout, and atomic writes: [base-schema.md](base-schema.md).
- Snapshot stability and the torn-read abort: [remote-snapshot.md](remote-snapshot.md).
- Safe local writes: [pull.md](pull.md).

Unit coverage lives in `tests/Push.Tests.ps1` (selection, apply, BASE update,
orchestration) and `tests/SyncCli.Tests.ps1` (CLI wiring), and requires no
network.
