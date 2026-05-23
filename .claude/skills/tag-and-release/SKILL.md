---
name: tag-and-release
description: Tag a new Howl Mac app release on main, bump the version, push, and monitor the GitHub Actions build until the release is live. Use when the user says "tag", "release", "ship it", "bump and tag", or when a PR has just been merged and the user wants a new release cut.
---

# Tag and Release

Bumps the Mac app version, tags main, pushes, and monitors the CI
build until `Howl.app.zip` is attached to the GitHub Release.

## Prerequisites

- On the `main` branch, up to date with `origin/main`.
- The PR whose changes you're releasing must already be merged.
- `gh` CLI authenticated with push + release access.

## Steps

### 1. Pull main

```bash
git checkout main && git pull --ff-only origin main
```

Confirm the merge commit is at HEAD.

### 2. Determine the next version

Read the current version from `mac/Howl/Info.plist`:

```
CFBundleShortVersionString → current marketing version (e.g. 0.6.2)
CFBundleVersion            → current build number (e.g. 15)
```

Bump rules (ask the user if unclear):

| Change type | Bump |
|---|---|
| New feature | minor (0.6.0 → 0.7.0) |
| Bug fix / polish | patch (0.6.2 → 0.6.3) |
| Major milestone | major (0.x → 1.0) |

Always increment the build number by 1.

### 3. Edit Info.plist

Update `CFBundleShortVersionString` and `CFBundleVersion` in
`mac/Howl/Info.plist`.

### 4. Commit the bump

```bash
git add mac/Howl/Info.plist
git commit -m "chore: bump version to X.Y.Z (build N)

<one-line summary of what's in this release>.

Co-Authored-By: Claude Opus 4.7 <noreply@anthropic.com>"
```

### 5. Push to main + tag

```bash
git push origin main
git tag -a mac-vX.Y.Z -m "mac-vX.Y.Z — <summary>"
git push origin mac-vX.Y.Z
```

Tag format is always `mac-vX.Y.Z` (annotated, not lightweight).

### 6. Monitor the Build .app workflow

The tag push triggers the `Build .app` GitHub Actions workflow
(defined in `.github/workflows/build.yml`). It builds, signs,
notarizes, and uploads `Howl.app.zip` to the GitHub Release.

```bash
# Find the run triggered by the tag
gh run list --limit 3

# Watch it (typical runtime ~5-7 min)
gh run view <run-id> --json status,conclusion
```

Poll every ~90 seconds. The build has these phases:
1. Go core compile (~30s)
2. xcodebuild Release (~60s)
3. Code signing + notarization (~2-3 min)
4. Zip + upload to GitHub Release (~30s)

### 7. Confirm the release

```bash
gh release view mac-vX.Y.Z
```

Verify:
- `draft: false`
- `asset: Howl.app.zip` present
- Release notes reference the PR(s)

Report the release URL to the user:
`https://github.com/sihekuang/howl/releases/tag/mac-vX.Y.Z`

## Troubleshooting

### "Bad credentials" on the release upload step

The repo's default workflow permissions may be set to read-only.
Check and fix:

```bash
# Check current setting
gh api repos/sihekuang/howl/actions/permissions/workflow

# If default_workflow_permissions is "read", update to "write"
gh api repos/sihekuang/howl/actions/permissions/workflow \
  -X PUT -f default_workflow_permissions=write \
  -F can_approve_pull_request_reviews=false

# Then re-run the failed job
gh run rerun <run-id>
```

### Build fails before the release step

Check the failed step's logs:

```bash
gh run view <run-id> --log-failed | tail -60
```

Common causes:
- Go build failure → check `core/` for compile errors
- xcodebuild failure → check `mac/` for Swift errors
- Notarization failure → Apple API key secrets may have expired
- Signing failure → certificate secrets may need rotation

### Tag already exists

If you need to re-tag (e.g., wrong commit):

```bash
git tag -d mac-vX.Y.Z
git push origin :refs/tags/mac-vX.Y.Z
# Then re-tag on the correct commit
```

## Monitoring shortcut

For the common case of "merge → tag → wait → confirm":

```bash
# One-shot: poll until the build finishes
gh run watch <run-id>
```

This streams the build log and exits when done. Saves the
poll-sleep-check loop.
