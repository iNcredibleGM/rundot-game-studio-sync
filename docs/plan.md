# Plan and Status (dry run)

`Plan` and `Status` observe a workspace and report what a future `Apply` would
consider. Both are read-only: they never mutate Studio, never write BASE, and
never change a local file.

`Plan` persists a dry-run artifact at `.rundot-sync/last-plan.json`. `Status`
runs the identical engine and persists nothing.

```powershell
.\game-studio-sync.ps1 -ProjectId <id> -LocalDir <dir> -Command Plan
.\game-studio-sync.ps1 -ProjectId <id> -LocalDir <dir> -Command Status
```

## What a run does

1. **BASE gate.** `Resolve-RundotSyncPlanBase` runs **before** authentication
   ([init.md](init.md), [base-schema.md](base-schema.md)). A missing BASE is a
   normal first-run state, so a workspace that cannot plan never asks for a
   token.
2. **Authentication.** The shared GET-only token flow
   (`Get-RundotAccessToken`). Every request below reads.
3. **LOCAL.** `Get-LocalManifest` inventories the workspace by exact bytes,
   skipping the default ignore set ([path-safety.md](path-safety.md)).
4. **REMOTE.** `Get-StableRemoteSnapshot` captures a torn-read-protected
   snapshot and returns `RemoteManifestHashBefore` and
   `RemoteManifestHashAfter` ([remote-snapshot.md](remote-snapshot.md)).
5. **Classify.** `Get-SyncPlanChanges` produces one row per path in
   `BASE ∪ LOCAL ∪ REMOTE` ([classifier.md](classifier.md)).
6. **Report.** The plan report prints to the console. Only `Plan` writes the
   artifact. Snapshot staging is then cleared.

## No plan is permission to write

This milestone has **no `Apply` and no `Push`**. Every remote-mutating
operation is forced to `applicable: false`, even when the classifier considers
the path actionable in principle:

| Status | Applicable | Why |
| --- | --- | --- |
| `upload` (text) | no | Remote mutation is not implemented in this milestone. |
| `upload` (binary) | no | Remote binary replacement semantics are unverified. |
| `deleteRemoteCandidate` | no | Deletion is classification-only in this milestone. |
| `download` | yes | Pulling a remote change is the milestone's read-only work. |

A text upload stays `Status = upload` so the plan still shows the candidate,
but it is never marked applicable, and it always carries a reason. The
[classifier](classifier.md) still reports text uploads as applicable for a
future `Push`; the plan layer is what blocks them here.

## Console layout

Sections appear only when they have rows:

- `UPLOAD` — local changes a future push would publish
- `DOWNLOAD` — remote-only changes
- `CONFLICT` — no single safe direction
- `STAGED DELETES` — `deleteRemoteCandidate` / `deleteLocalCandidate`,
  classification only
- `IGNORED` — out of sync scope by the default ignore set
- `UNSUPPORTED` — text ↔ binary kind changes
- `DIAGNOSTIC` — see below
- `SUMMARY` — a count per status, the union total, and the applicable total

`UNCHANGED` paths are listed only with `-Verbose`. Every row shows short BASE,
LOCAL, and REMOTE hashes plus its reason and any metadata warning.

Every `Plan` and `Status` report ends with these three lines:

```text
Dry run only. No remote files were modified.
This plan is a point-in-time observation, not permission to write.
WARNING: This tool uses unofficial remote API routes that may change.
```

### `-Verbose`

`-Verbose` adds an `UNCHANGED` section. It cannot be declared in the script's
param block, because that name collides with PowerShell's common parameter, so
the script reads it from `$PSBoundParameters`. `powershell -File` does not
accept `-Verbose:$false`; pass a bare `-Verbose`.

## BOM and newline diagnostics

Two text files that differ **only** by a UTF-8 BOM, by newline style, or by
both are reported under `DIAGNOSTIC`, naming the path and the difference
(`bom`, `newline`, or `bom+newline`).

This is a diagnostic, not a classification input. **Classification stays
exact-byte based**, so the row keeps its real `upload`, `download`, or
`conflict` status. A genuinely different file produces no diagnostic, and a
read failure is skipped rather than failing the plan.

## `.rundot-sync/last-plan.json`

Written by `Plan` only, atomically (tmp + replace, mirroring
[BASE](base-schema.md)). It holds hashes, metadata, and reasons: no file
contents, no tokens, no staging paths, no absolute local paths.

```json
{
  "schemaVersion": 1,
  "toolVersion": "0.1.3",
  "planId": "<GUID>",
  "projectId": "<studio project id>",
  "localRootFingerprint": "<64 lowercase hex>",
  "createdAt": "<ISO-8601 UTC>",
  "expiresAt": "<createdAt + 20 minutes>",
  "basePresent": true,
  "untrusted": false,
  "baseCapturedAt": "<ISO-8601 UTC or null>",
  "remoteManifestHashBefore": "<64 lowercase hex>",
  "remoteManifestHashAfter": "<64 lowercase hex>",
  "localManifestHash": "<64 lowercase hex>",
  "operations": [
    {
      "path": "src/a.ts",
      "status": "upload",
      "kind": "utf8",
      "kinds": { "base": "utf8", "local": "utf8", "remote": "utf8" },
      "applicable": false,
      "remoteMutating": true,
      "reason": "Remote mutation is not implemented in this milestone.",
      "warning": null,
      "ignored": false,
      "kindChange": false,
      "baseSha256": "<hex or null>",
      "localSha256": "<hex or null>",
      "remoteSha256": "<hex or null>",
      "expectedRemoteHash": "<hex or null>"
    }
  ]
}
```

`operations[]` carries **one row per union path**, including no-ops, so the
artifact is a complete audit trail.

### Expiry

`expiresAt` defaults to 20 minutes after `createdAt` and is shown in the
console header. The TTL is an engine parameter, not a command-line flag. An
expired plan is stale: REMOTE is a point-in-time observation, and a future
`Apply` must re-check rather than trust it.

### Future Apply evidence

No `Apply` exists yet. The artifact stores what a future one must re-verify
before writing anything:

- `planId` — the plan these fingerprints belong to
- `localRootFingerprint` — the workspace folder this plan was built for
- `localManifestHash` — the LOCAL tree the plan was computed against
- `remoteManifestHashBefore` / `remoteManifestHashAfter` — the remote state
- `operations[].expectedRemoteHash` — the remote hash a write must still match

## Refusing without BASE

Without a BASE there is no verified shared state, so `Plan` refuses and points
at `Init` ([init.md](init.md)). The refusal is printed before authentication,
and no artifact is written.

`-AllowNoBase` is an advanced escape hatch. It plans anyway and persists the
artifact with `basePresent: false`, `untrusted: true`, and
`baseCapturedAt: null`, and the report carries the untrusted banner:

```text
WARNING: No BASE manifest. Synchronization direction is untrusted.
LOCAL and REMOTE agreement has not been proven, so every path is a guess.
```

`-AllowNoBase` bypasses a *missing* BASE only. A present BASE is still
ownership-checked, so the flag can never accept a BASE belonging to a
different project or folder.

## Plan never updates BASE

`Init` remains the only writer of BASE ([base-schema.md](base-schema.md)).
`Plan` reads BASE identity from the resolver's manifest and writes only
`last-plan.json`. `.rundot-sync/` is in the default ignore set, so the artifact
is never a local inventory entry or an upload candidate.

## Related contracts

- The classifier and its status vocabulary: [classifier.md](classifier.md).
- BASE ownership and atomic writes: [base-schema.md](base-schema.md).
- Snapshot stability and the torn-read abort: [remote-snapshot.md](remote-snapshot.md).
- Path identity, safety, and ignores: [path-safety.md](path-safety.md).

Unit coverage lives in `tests/SyncPlan.Tests.ps1` (engine) and
`tests/SyncCli.Tests.ps1` (CLI wiring), and requires no network.
