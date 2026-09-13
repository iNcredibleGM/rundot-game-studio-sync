# Shipping a milestone

This is the close-out checklist after every child issue on a GitHub
milestone is merged into that version’s integration branch. Follow it
the same way for each release.

Branching rules live in [CONTRIBUTING.md](../CONTRIBUTING.md). Versions
live on GitHub milestones, not labels
([github-labels.md](github-labels.md)).

`main` is the released product. Issue pull requests never target `main`.
A version reaches users only through **one** ship PR (integration branch
→ `main`), then a git tag and a GitHub Release.

Do not close the GitHub milestone when the last issue closes. Close it
only after the GitHub Release exists.

## 1. Confirm the work is actually done

On the integration branch (`vX.Y.Z`):

- Every child issue on the GitHub milestone is closed.
- Every issue PR for that milestone is merged into the integration
  branch (not into `main`).
- The integration branch is ahead of `main` and not behind it.
- ROADMAP “Done when” for that version is true.
- `powershell -NoProfile -File .\tests\Run-Tests.ps1` is green on
  Windows PowerShell 5.1.
- The diff does not add Studio `PUT`, `DELETE`, `upload-url`, or
  `upload-adopt` before the push milestone. Mutation grep must stay
  green.
- No access tokens, refresh tokens, or `%APPDATA%\.rundot\` auth files
  appear in the diff, PR text, or release notes.

```text
git fetch origin
git log --oneline origin/main..origin/vX.Y.Z
git merge-base --is-ancestor origin/main origin/vX.Y.Z
```

The last command must succeed (exit 0): `main` is an ancestor of the
integration branch.

## 2. Last docs on the integration branch

Land these on the integration branch **before** opening the ship PR.
Once that PR merges, they are true on `main`.

- [ROADMAP.md](../ROADMAP.md): under the shipped version, add
  `Shipped on main.` the same way v0.1.0 is marked.
- [CONTRIBUTING.md](../CONTRIBUTING.md) and [AGENTS.md](../AGENTS.md):
  change the “current integration branch” sentence from this version to
  the **next** one (the branch you will cut in step 8).
- [README.md](../README.md): only if user-facing behavior changed.

Do not retarget those files in a separate PR to `main`. They ride along
with the ship PR.

## 3. Open the ship PR

One pull request: **base `main`**, **head the integration branch**.

Title: the milestone title (`vX.Y.Z - Short name`).

Body:

```markdown
## Summary
- Ship <milestone title> to main (#issue, #issue, …).
- <one line on what the product can and cannot do in this version>

## Test plan
- [ ] `powershell -NoProfile -File .\tests\Run-Tests.ps1`
- [ ] Mutation grep green (until the push milestone)
- [ ] Live exporter still authenticates and downloads (if this version
      still ships the exporter)
- [ ] Release notes drafted; no tokens

Closes the GitHub milestone **after** merge + tag + release, not from
this PR.
```

```bash
gh pr create --base main --head vX.Y.Z --title "vX.Y.Z - Short name" --body "$(cat <<'EOF'
...
EOF
)"
```

## 4. Merge to `main`

Use a **merge commit**, not squash and not rebase. Issue PRs were
already squash-merged onto the integration branch; squashing the ship
PR would hide those commits on `main`. v0.1.1 was a single-issue squash
onto `main` — that does not apply to a multi-issue milestone.

```bash
gh pr merge <ship-pr-number> --merge
```

Do not delete the integration branch in this step. The tag is created
next.

## 5. Tag the commit that is now `main`

Annotated tags, matching v0.1.0 and v0.1.1. Tag **after** the ship PR
is merged, on the commit `origin/main` points at — not on a stale local
`main`.

```bash
git checkout main
git pull origin main
git tag -a vX.Y.Z -m "vX.Y.Z - Short name"
git push origin vX.Y.Z
```

Do not move or force-push a version tag. Do not tag the integration
branch instead of `main`.

## 6. GitHub Release

Create the GitHub Release **from that tag**. Mark it latest unless you
are shipping a patch behind a newer latest.

Keep the same three sections as v0.1.1:

```markdown
## What's new

- …

## Verified

- …

## Limitations

- …
```

```bash
gh release create vX.Y.Z --title "vX.Y.Z - Short name" --notes "$(cat <<'EOF'
## What's new

- …

## Verified

- …

## Limitations

- …

EOF
)"
```

Never paste tokens, session JSON, or auth file paths with secrets into
the notes.

## 7. Close the GitHub milestone

Only after the GitHub Release URL exists.

```bash
gh api -X PATCH "repos/iNcredibleGM/rundot-game-studio-sync/milestones/<number>" -f state=closed
```

`<number>` is the milestone number from its GitHub URL
(`/milestone/2` → `2`), not the version string.

## 8. Cut the next integration branch

From the tagged `main`, not from the old integration branch:

```bash
git checkout main
git pull origin main
git checkout -b vA.B.C
git push -u origin vA.B.C
```

`vA.B.C` is the next ROADMAP version (after v0.1.2 that is `v0.1.3`).
The GitHub milestone for that version should already exist with its
child issues. Do not file a tracking issue that restates the milestone.

New issue branches now cut from this branch, and new issue PRs use it
as base.

## 9. Optional cleanup

After the tag exists on `origin`:

- Delete merged `issue/<n>-*` remote branches if they are still around.
- Leave the old integration branch (`vX.Y.Z`) or delete it. The tag is
  the record; the branch is not required after the release.

Do not delete `main`. Do not force-push.

## Next-time reminder

The cycle is: cut integration branch from `main` → merge issue PRs into
it → this checklist → repeat. Do not start issue work for the next
version on `main` while that version is unreleased.
