# RUN.game Studio Sync

Unofficial tool for exporting RUN Game Studio projects to a local filesystem.

> This project is not affiliated with or endorsed by RUN, RUN.game, Series, Inc., or the maintainers of the official `rundot` CLI.

## What it does

- Exports the editable RUN Game Studio filesystem to a local directory
- Preserves UTF-8 text correctly
- Exports binary assets byte-for-byte
- Optionally exports Studio conversation threads with raw JSON and readable Markdown
- Supports automatic authentication through a fresh official `rundot` CLI session, with existing fallback authentication mechanisms

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

Git is optional; it is only needed if you want to version/control your exported project.

## Quick start

```powershell
.\game-studio-export.ps1 `
    -ProjectId "YOUR_PROJECT_ID" `
    -OutDir ".\dev" `
    -IncludeThreads
```

The exporter reads the official CLI session from `%APPDATA%\.rundot\prod.session.json` and uses its `accessToken` directly against Studio. The token must be fresh enough to pass the exporter's 5-minute safety window; otherwise the tool suggests running `rundot login` again and falls through to the other authentication methods.

The exporter does not modify the official CLI session file, and it does not run `rundot login` automatically.

## Authentication

Authentication precedence:

1. Fresh official `rundot` CLI access token from `%APPDATA%\.rundot\prod.session.json`
2. Previously saved exporter Firebase refresh credentials from `%APPDATA%\.rundot\studio-export.auth.json`
3. Firebase bootstrap JSON from clipboard
4. Studio bearer token from clipboard
5. Manual secure bearer-token paste

Notes:

- Studio validation is authoritative. The exporter always confirms a candidate token by requesting the project manifest.
- JWT decoding is used only locally to inspect expiry; signatures are not verified.
- The exporter applies a 5-minute safety window before attempting the CLI token, because a near-expiry token previously produced HTTP 401.
- CLI refresh-token support is not yet implemented. If the official CLI token is expired or near expiry, the tool suggests running `rundot login` and then falls through to the existing authentication methods.
- Browser/clipboard/manual authentication remains available as a fallback.

## Sync (work in progress)

`game-studio-sync.ps1` is a separate entrypoint for syncing a Studio project
with a local directory. **Only `Init` is implemented today**; `Plan`, `Status`,
and `Pull` land in later v0.1.3 issues. Run `-Command Init` and nothing else.

Sync is read-oriented. Neither LOCAL nor REMOTE is authoritative: BASE records
the last verified shared state. This milestone has no remote mutation - there
is no `Apply` and no `Push`.

Initialize a workspace:

```powershell
# Build a trusted workspace from REMOTE into an empty directory
.\game-studio-sync.ps1 -ProjectId "YOUR_PROJECT_ID" -LocalDir ".\dev" -Command Init -InitMode FromRemote

# Or attach sync metadata to a directory that already has your files
.\game-studio-sync.ps1 -ProjectId "YOUR_PROJECT_ID" -LocalDir ".\dev" -Command Init -InitMode Adopt
```

- `FromRemote` requires an empty `LocalDir` (only `.git` / `.gitignore` may be
  present). It verifies every downloaded file before writing BASE, and any
  failure leaves no BASE.
- `Adopt` records only paths whose content hash already matched REMOTE
  exactly, and prints an unresolved-path report for everything else. It never
  claims agreement that was not proven.

See [docs/init.md](docs/init.md) for the full behavior, including the failure
table and the `Plan`-without-BASE refusal.

`Plan` and `Status` require a BASE and will refuse without one, pointing at
`Init`. Until those commands ship, they apply that check and stop rather than
producing a plan.

> Sync uses unofficial remote API routes that may change without notice.

## Troubleshooting

### CLI session found but Studio returns 401

1. Run `rundot login`
2. Rerun the exporter promptly
3. If it still fails, allow the exporter to continue to its saved/clipboard/manual fallback methods

> Never include access tokens, refresh tokens, or authentication files in bug reports.

## Contributing

How to branch, open pull requests, and work on a milestone is in [CONTRIBUTING.md](CONTRIBUTING.md). Automated agents must also read [AGENTS.md](AGENTS.md).

## Development note

The original exporter and protocol investigation were iterated with OpenAI GPT-5.6 Sol/Terra/Luna while manually observing Studio network behavior. Subsequent local refactoring and the CLI-auth integration were developed in Cursor using local Ollama tooling with DeepSeek V4 Flash, with live behavior verified manually.
