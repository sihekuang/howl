#!/usr/bin/env bash
# One-time per-clone setup: install dev tools + cgo Homebrew deps,
# wire the tracked git hooks under scripts/git-hooks/, and bootstrap
# the Go dylib so first-clone Xcode builds succeed without an
# opaque cgo link error. Idempotent — safe to re-run.
#
# Usage: ./scripts/setup-dev.sh
set -euo pipefail

cd "$(git rev-parse --show-toplevel)"

# --- Homebrew ---------------------------------------------------------
# Required for the Mac dev workflow. CI installs the same set in
# .github/workflows/build.yml — keep these two lists in sync.
if ! command -v brew >/dev/null 2>&1; then
  echo "error: Homebrew not found. Install from https://brew.sh and re-run." >&2
  exit 1
fi

# --- Build tools ------------------------------------------------------
# xcodegen materialises the .xcodeproj from project.yml; go is the Go
# compiler used by the cgo build of libvkb.dylib.
brew_install_if_missing() {
  local pkg="$1"
  if brew list --formula "$pkg" >/dev/null 2>&1; then
    echo "  [ok] $pkg already installed"
  else
    echo "  installing $pkg..."
    brew install "$pkg"
  fi
}

echo "Checking build tools..."
brew_install_if_missing xcodegen
brew_install_if_missing go

# --- Go cgo runtime deps ----------------------------------------------
# libvkb.dylib links against whisper-cpp + ggml (transcription) and
# onnxruntime (TSE pipeline). Without these the cgo build fails with
# linker errors that don't make the actual missing dep obvious.
echo "Checking Go cgo deps..."
brew_install_if_missing whisper-cpp
brew_install_if_missing ggml
brew_install_if_missing onnxruntime

# --- Tracked git hooks ------------------------------------------------
# Without this, the hooks under scripts/git-hooks/ are never executed —
# git defaults to per-clone .git/hooks/ which can't be tracked.
git config core.hooksPath scripts/git-hooks
echo "git core.hooksPath -> scripts/git-hooks (hooks now active for this clone)."

# --- Initial Xcode project regen --------------------------------------
# The .xcodeproj IS tracked, but post-pull hooks regenerate it on every
# input change, so a fresh clone may need an initial pass.
if [ -d mac ] && [ -f mac/project.yml ]; then
  ( cd mac && make project >/dev/null 2>&1 ) \
    && echo "Generated mac/VoiceKeyboard.xcodeproj." \
    || echo "warning: 'make project' failed - run 'cd mac && make project' to debug." >&2
fi

# --- Bootstrap libvkb.dylib -------------------------------------------
# Xcode's preBuild phase rebuilds this on every build, but doing it once
# up front means: (a) the user finds out NOW if their cgo toolchain is
# broken, with a clear error, instead of seeing it in an Xcode log; and
# (b) the first Xcode build is fast because the dylib's already warm.
echo "Bootstrapping libvkb.dylib..."
if ( cd core && make build-dylib >/dev/null 2>&1 ); then
  echo "  [ok] core/build/libvkb.dylib"
else
  echo "warning: 'make build-dylib' failed in core/ - run 'cd core && make build-dylib' to see the full error." >&2
  echo "         Common causes: missing brew deps (re-run setup-dev.sh),"  >&2
  echo "         or a stale Xcode CLI tools install ('xcode-select --install')." >&2
fi

echo ""
echo "Done. Next: 'cd mac && make run' to build + launch the app."
