#!/usr/bin/env bash
# One-time per-clone setup: install dev tools and wire up the
# tracked git hooks under scripts/git-hooks/. Idempotent — safe
# to re-run.
#
# Usage: ./scripts/setup-dev.sh
set -euo pipefail

cd "$(git rev-parse --show-toplevel)"

# 1. Install xcodegen (needed to materialise the Xcode project from
#    project.yml; the .xcodeproj directory itself is gitignored).
if ! command -v xcodegen >/dev/null 2>&1; then
  if command -v brew >/dev/null 2>&1; then
    echo "Installing xcodegen via Homebrew..."
    brew install xcodegen
  else
    echo "warning: xcodegen not installed and Homebrew not found." >&2
    echo "        Install xcodegen manually before running 'make project'." >&2
  fi
else
  echo "xcodegen already installed."
fi

# 2. Point git at the tracked hooks directory. Without this, the hooks
#    sitting under scripts/git-hooks/ are never executed; git defaults
#    to the per-clone .git/hooks/ which can't be tracked.
git config core.hooksPath scripts/git-hooks
echo "git core.hooksPath → scripts/git-hooks (hooks now active for this clone)."

# 3. First-time project generation so the user can open Xcode immediately.
if [ -d mac ] && [ -f mac/project.yml ]; then
  ( cd mac && make project >/dev/null 2>&1 ) \
    && echo "Generated mac/VoiceKeyboard.xcodeproj." \
    || echo "warning: 'make project' failed — run 'cd mac && make project' to debug." >&2
fi

echo ""
echo "Done. The Xcode project is now auto-regenerated on git pull / checkout"
echo "when project.yml or any tracked Swift source changes."
