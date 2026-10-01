# Safe Push: publish clean local text overwrites, utf8 text creates, binary
# places, and confirmed remote deletes; optional -LocalWins publish for
# conflicts and remote-only paths after one confirmation.
#
# Push applies four classifications from a verified plan artifact: a clean text
# overwrite (BASE=A LOCAL=B REMOTE=A, utf8 kind, expectedRemoteHash set), a
# utf8 text create (BASE=- LOCAL=A REMOTE=-, documented upload + move + PUT /file),
# a binary create or replace (documented upload + move place sequence, #41), and
# a remote delete (BASE=A LOCAL=- REMOTE=A, expectedRemoteHash set, path not
# reserved and not directory-shaped). Conflicts and kind mismatches are refused.
#
# A delete cannot be made conditional: Studio exposes no ETag or version and
# ignores If-Match (docs/delete-rename-protocol.md), so the guard is a client
# re-read of the remote bytes immediately before the request, plus a backup of
# those bytes first. A 404 after a 200 means the path is already absent, and
# absence is proven from GET /files rather than from a status code.
#
# This file is the Push entrypoint. The implementation lives in the focused
# Push.*.ps1 parts, dot-sourced below so every existing caller keeps loading
# only lib\Push.ps1 and Invoke-RundotSyncPush stays the one call site.
#
# The parts, in load order:
#
#   1. PlanGate             - plan artifact fingerprints and live state gates
#   2. Selection            - which plan rows default Push may apply, and why not
#   3. LocalWinsSelection   - the same for -LocalWins, with drift as per-path refusal
#   4. LocalWinsRow /       - the local-wins per-row classifiers
#      LocalWinsConflictRow
#   5. ApplySupport /       - remote read+verify+backup primitives, the shared
#      WriteDispatch           pre-write gates, and the shared write loop
#   6. ActionInvokers       - one invoker per action (overwrite, create, binary, delete)
#   7. Apply / LocalWinsApply - the two apply paths
#   8. BaseUpdate           - the verified BASE move
#   9. Report               - the CLI report text
#  10. Journal              - apply-phase failure handling, BASE move, journal
#  11. Orchestrate          - Invoke-RundotSyncPush and its confirmation gates
#
# Callers must load Paths.ps1, Ignore.ps1, Hashing.ps1, Workspace.ps1,
# Manifest.ps1, Snapshot.ps1, Classifier.ps1, Plan.ps1, Backup.ps1, Journal.ps1,
# RemoteApi.ps1, RemoteWrite.ps1, RemoteDelete.ps1, RemoteUpload.ps1,
# RemoteMove.ps1, RemoteTextCreate.ps1, RemoteBinaryPlace.ps1, and Push.ps1 first.

. (Join-Path $PSScriptRoot "Push.PlanGate.ps1")
. (Join-Path $PSScriptRoot "Push.Selection.ps1")
. (Join-Path $PSScriptRoot "Push.LocalWinsSelection.ps1")
. (Join-Path $PSScriptRoot "Push.LocalWinsRow.ps1")
. (Join-Path $PSScriptRoot "Push.LocalWinsConflictRow.ps1")
. (Join-Path $PSScriptRoot "Push.ApplySupport.ps1")
. (Join-Path $PSScriptRoot "Push.WriteDispatch.ps1")
. (Join-Path $PSScriptRoot "Push.ActionInvokers.ps1")
. (Join-Path $PSScriptRoot "Push.Apply.ps1")
. (Join-Path $PSScriptRoot "Push.LocalWinsApply.ps1")
. (Join-Path $PSScriptRoot "Push.BaseUpdate.ps1")
. (Join-Path $PSScriptRoot "Push.Report.ps1")
. (Join-Path $PSScriptRoot "Push.Journal.ps1")
. (Join-Path $PSScriptRoot "Push.Orchestrate.ps1")
