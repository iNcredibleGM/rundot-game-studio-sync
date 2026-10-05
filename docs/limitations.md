# Known limitations

One place for what this tool **cannot** do, so a new user is not surprised by a
refusal — or, worse, by a workspace that looks complete but is not.

The most consequential limit is first. Each entry links to the deeper evidence.

## 1. Studio will not serve a file over 2 MB

`GET /file` refuses any payload over **2,000,000 bytes** with HTTP 413
`file too large to view`. Exactly 2,000,000 bytes still reads; 2,000,001 does
not. No other read route is known, and range requests, different headers, or
`POST` on the same URL do not return the bytes
([large-file-protocol.md](large-file-protocol.md), [binary-place.md](binary-place.md)).

This tool records a path as synced only when it has verified the exact bytes, so
**a file already on Studio over 2 MB can never be downloaded or re-verified.**

**What this means when you run `Init` or `Pull`:**

- The run finishes. It does not abort.
- The oversized path is reported and listed as `UNVERIFIABLE`.
- On `Init -InitMode FromRemote` it is **left out of the local workspace and out
  of BASE**.
- **Your local tree is therefore incomplete, and nothing about the folder says
  so.** Keep the list the run printed.

On a 3D project this is often an `.fbx` or `.glb` over the limit. Keep large
assets in the local tree or another store you already trust.

| Case | Result |
| --- | --- |
| File at or under 2 MB | syncs in both directions |
| New binary over 2 MB, up to 50 MiB | can be **published** (verified from the upload `ETag`) |
| File already on Studio over 2 MB | **cannot** be downloaded or re-verified |
| Binary **replace** over 2 MB | refused — the backup and hash gate need bytes that cannot be read |
| Text over 2,000,000 bytes | refused at `PUT /file` (see below) |

## 2. Write limits

- **Text over 2,000,000 bytes is write-once.** The `PUT /file` limit is checked
  against the **stored** file, not the incoming body: a one-character `PUT`
  against a 2.85 MB text path still returns 413. A text file published above the
  limit can never be edited in place, only replaced by delete-then-place. The
  product refuses to create one it could never edit again
  ([large-file-protocol.md](large-file-protocol.md) §4).
- **A binary create over 50 MiB is impossible.** `POST /upload-url` refuses any
  `declaredSize` over 52,428,800 bytes (50 MiB) with `413 FILE_TOO_LARGE`, from
  the declaration alone, before any byte moves. A RUN patch note claiming
  "up to 200 MB" is not what this route enforces
  ([large-file-protocol.md](large-file-protocol.md) §1).
- **A binary replace over 2 MB is refused.** Delete-then-place is mechanically
  possible below 50 MiB, but the pre-replace remote bytes cannot be backed up
  and no route exposes their hash, so the only guard available is the size from
  `GET /files` — too weak to ship as a default.

## 3. Sync semantics

- **No content merge.** A conflict is never resolved by combining bytes.
  `Push -LocalWins` replaces remote bytes with local bytes; it does not merge.
- **No automatic deletion.** `deleteLocalCandidate` leaves the local file in
  place. A remote delete happens only through a confirmed `Push`.
- **One workspace belongs to one project and one folder.** There is no
  multi-machine BASE.
- **`Push` consumes the last `Plan` artifact.** A plan is a point-in-time
  observation, not permission to write, and it expires (20 minutes by default),
  so a large publish may need to re-plan and resume.

## 4. Out of scope by design

- Applying local changes without a fresh `Plan` (`Apply`).
- Rename (`POST /move`) as a standalone operation — a rename publishes only as a
  confirmed create plus delete.
- `.rundotignore` custom patterns. A root `.gitignore` **is** honored, as an
  additive floor; nested per-directory `.gitignore` files and negation are not
  ([path-safety.md](path-safety.md)).
- Newline or encoding normalization. Text is preserved byte-for-byte.
- File watching, device IDs, or a shared multi-machine BASE.

## 5. Platform and API

- **Windows and Windows PowerShell 5.1** are the compatibility baseline.
- **The remote API is unofficial.** Every Studio route this tool uses is
  reverse-engineered and may change without notice. A missing route stays a
  refusal rather than a guess ([protocol.md](protocol.md)).
- **The raw exporter does not apply the ignore set.** It downloads everything
  Studio lists ([export.md](export.md)).
- **No telemetry.** The tool does not phone home, check for updates, or upload
  anything but the files you confirm.

## Related

- [Large-file protocol](large-file-protocol.md) — measured read and write ceilings
- [Binary place](binary-place.md) — the place sequence and its refusals
- [Path safety](path-safety.md) — ignores and unsafe paths
- [ROADMAP.md](../ROADMAP.md) — what is planned next
