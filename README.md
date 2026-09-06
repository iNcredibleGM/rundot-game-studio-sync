# RUN.game Studio Sync

Unofficial tool for exporting RUN Game Studio projects to a local filesystem.

## Current status

### Supported

- Export a RUN Game Studio project to a local directory
- Preserve UTF-8 text correctly
- Export binary assets byte-for-byte
- Export Studio conversation threads
- Preserve raw thread JSON
- Generate readable Markdown thread transcripts
- Reuse locally encrypted Studio authentication

### Under investigation

- Easier browser authentication/bootstrap helpers
- Bookmarklet-assisted authentication
- Official `rundot` CLI authentication compatibility
- Local → Studio text-file push
- Local → Studio binary-file push
- Remote file replacement, deletion, and rename behavior
- Safe bidirectional synchronization

## Quick start

```powershell
.\game-studio-export.ps1 `
    -ProjectId "YOUR_PROJECT_ID" `
    -OutDir ".\dev" `
    -IncludeThreads
```

> This project is not affiliated with or endorsed by RUN, RUN.game, Series, Inc., or the maintainers of the official `rundot` CLI.