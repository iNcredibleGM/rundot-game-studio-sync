# RUN.game Studio Sync

Unofficial tool for exporting RUN Game Studio projects to a local filesystem.

> This project is not affiliated with or endorsed by RUN, RUN.game, Series, Inc., or the maintainers of the official `rundot` CLI.

## Current status

### Supported

- Export a RUN Game Studio project to a local directory
- Preserve UTF-8 text correctly
- Export binary assets byte-for-byte
- Export Studio conversation threads
- Preserve raw thread JSON
- Generate readable Markdown thread transcripts
- Reuse locally encrypted Studio authentication
- Automatic use of a fresh official `rundot` CLI session

### Under investigation

- Easier browser authentication/bootstrap helpers
- Bookmarklet-assisted authentication
- Official `rundot` CLI refresh-token handling
- Local → Studio text-file push
- Local → Studio binary-file push
- Remote file replacement, deletion, and rename behavior
- Safe bidirectional synchronization

## Prerequisites / tested environment

The tool was developed and verified in this general environment:

- Windows 11
- Windows PowerShell 5.1 is the compatibility baseline used during development
- Official `rundot` CLI installed
- Authenticated RUN account for the project being exported
- Network access to RUN Game Studio
- Git is only needed if you want to version/control your exported project; it is not required for the exporter itself

## Quick start

The simplest supported first authentication path on Windows is a fresh official `rundot` login:

```powershell
rundot login
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

## Troubleshooting

### CLI session found but Studio returns 401

1. Run `rundot login`
2. Rerun the exporter promptly
3. If it still fails, allow the exporter to continue to its saved/clipboard/manual fallback methods

## Development note

The original exporter and protocol investigation were iterated with OpenAI GPT-5.6 Sol/Terra/Luna while manually observing Studio network behavior. Subsequent local refactoring and the CLI-auth integration were developed in Cursor using local Ollama tooling with DeepSeek V4 Flash, with live behavior verified manually.
