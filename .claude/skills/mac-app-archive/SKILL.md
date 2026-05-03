---
name: mac-app-archive
description: Build a Release .xcarchive of the VoiceKeyboard Mac app and produce a distributable .app.zip. Use when the user asks to "archive the app", "make a release build", "package the app for distribution", or wants to bump the version and ship a new build.
---

# Mac App Archive

End-to-end recipe for producing a clean, signed, self-contained
`.xcarchive` of `mac/VoiceKeyboard.app` and a distributable
`.app.zip`. Tuned for this repo's specifics: arm64-only, signing
auto-detected from the local environment (Apple Development if
`DeveloperSettings.xcconfig` is present, ad-hoc otherwise), Go core
compiled at preBuild, ONNX runtime + Whisper Homebrew dylibs bundled
at postCompile.

## When to use

- User asks to archive, package, ship, or release the Mac app
- After a meaningful round of merged features, before tagging
- When verifying a clean cold build still produces a complete .app
  (e.g., after a refactor that changed bundling)

## Prerequisites (verify before starting)

1. Working tree clean or all intended changes committed.
2. `core/build/models/{tse_model,speaker_encoder,silero_vad}.onnx`
   exist (Release build copies them into the .app's Resources/).
   If missing, run `./enroll.sh` once from repo root.
3. Homebrew has `whisper-cpp ggml onnxruntime` installed
   (cgo runtime deps). `./scripts/setup-dev.sh` covers all of these.
4. We're on Apple Silicon (`uname -m` → `arm64`). The project pins
   `ARCHS: arm64` — universal builds aren't supported here because
   Homebrew dylibs ship arm64-only.

## Signing modes — pick before you archive

The recipe auto-detects which signing mode to use, but the choice
matters for what you get out the other end. Two modes:

| Mode | Trigger | TCC perms across rebuilds | Distributable to other Macs |
|---|---|---|---|
| **Apple Development** | `mac/Configs/DeveloperSettings.xcconfig` exists | ✅ sticky on this Mac | ❌ other Macs reject the cert |
| **Ad-hoc** | no `DeveloperSettings.xcconfig`, or `FORCE_ADHOC=1` | ❌ TCC resets every rebuild | Gatekeeper warns once, then OK |

Why this matters:

- **macOS TCC** (mic / accessibility / etc.) keys grants on `(bundle
  ID, code signature)`. Ad-hoc signatures embed a per-build hash, so
  each rebuild is "a new app" and prior grants are forgotten —
  meaning every test of a new ad-hoc archive needs a fresh permission
  approval. Apple Development signing keeps the same Team Identifier
  across rebuilds, so grants stick.
- **Other people's Macs** don't trust your Apple Development cert
  chain; only your own machine + machines provisioned via your Team
  do. So Apple Development archives are great for *your* iteration
  loop but not for handing the .app.zip to a friend. For that, use
  ad-hoc (or, eventually, Developer ID + notarization — out of scope
  for this skill).

Default behaviour:

- If `mac/Configs/DeveloperSettings.xcconfig` exists locally, the
  archive uses it (Apple Development, sticky perms, single-machine).
- If not, the archive falls back to ad-hoc (matches CI, what the
  GitHub Release ships).
- Override either way with `FORCE_ADHOC=1` (force ad-hoc regardless
  of local config).

When in doubt: **iteration build → let it auto-detect; release
build → run with `FORCE_ADHOC=1` so the artifact matches CI.**

## Process

### 1. Bump version

`mac/VoiceKeyboard/Info.plist` is the source of truth. Two keys:

- `CFBundleShortVersionString` — semver shown to users (e.g.
  `0.2.0`). For pre-1.0 work, keep major at `0`. Bump minor for
  feature batches, patch for fixes.
- `CFBundleVersion` — monotonic integer build number. Increment
  for every archive at the same marketing version.

Edit both, commit:

```bash
git commit -am "chore: bump version to <X.Y.Z> (build <N>)"
```

The commit message should briefly summarize what's in the bump
(features merged since the previous version) — useful when looking
back at release history without external release notes.

### 2. Optional: prove a clean cold build

If you want to verify Xcode's preBuild + postCompile phases all
work from a truly empty state (e.g., before tagging a release):

```bash
rm -f core/build/libvkb.dylib core/build/libvkb.h
rm -rf /tmp/vkb-archive-derived
```

Don't `rm -rf core/build/` — that wipes the TSE models (~30+ min
to retrace via PyTorch). Use `core/Makefile`'s `clean` target if
you need a Make-driven version.

### 3. Archive

The script auto-detects the signing mode (see "Signing modes"
above). Archive path matches what Xcode itself would use
(`~/Library/Developer/Xcode/Archives/<YYYY-MM-DD>/`) so the
result shows up in Window → Organizer alongside any other
archives — but with a version-stamped filename instead of
`VoiceKeyboard 5-1-26, 4.40 PM.xcarchive`:

```bash
VERSION=<X.Y.Z>
DATE=$(date +%Y-%m-%d)
ARCHIVE_DIR="$HOME/Library/Developer/Xcode/Archives/$DATE"
mkdir -p "$ARCHIVE_DIR"
ARCHIVE_PATH="$ARCHIVE_DIR/VoiceKeyboard-$VERSION.xcarchive"

# Pick signing mode. Apple Development if user has a local
# DeveloperSettings.xcconfig and didn't request ad-hoc explicitly.
SIGN_FLAGS=()
if [ -n "$FORCE_ADHOC" ] || [ ! -f mac/Configs/DeveloperSettings.xcconfig ]; then
  SIGN_FLAGS=(CODE_SIGN_IDENTITY=- CODE_SIGN_STYLE=Manual DEVELOPMENT_TEAM=)
  echo "[archive] signing mode: ad-hoc"
else
  echo "[archive] signing mode: Apple Development (from DeveloperSettings.xcconfig)"
fi

# Wipe prior archive at the same path + derived data so codesign
# actually re-runs (prevents "I changed signing flags but the .app
# still has the old signature" surprises).
rm -rf "$ARCHIVE_PATH" /tmp/vkb-archive-derived

cd mac
xcodebuild \
  -project VoiceKeyboard.xcodeproj \
  -scheme VoiceKeyboard \
  -configuration Release \
  -destination 'platform=macOS' \
  -derivedDataPath /tmp/vkb-archive-derived \
  -archivePath "$ARCHIVE_PATH" \
  "${SIGN_FLAGS[@]}" \
  archive
```

Why these flags:

- `-archivePath ~/Library/Developer/Xcode/Archives/<date>/...`
  is what Xcode itself uses, so Organizer's archive list picks it
  up. Sub-folder must be `<YYYY-MM-DD>` for Organizer's grouping;
  the filename can be anything (we use the version stamp for
  scripting and visual scanability).
- `-derivedDataPath /tmp/...` keeps the user's normal Xcode caches
  untouched — no spurious incremental rebuilds afterwards.
- `${SIGN_FLAGS[@]}` is empty in Apple-Development mode (xcconfig
  drives) and `CODE_SIGN_IDENTITY=- CODE_SIGN_STYLE=Manual
  DEVELOPMENT_TEAM=` in ad-hoc mode (overrides any xcconfig that
  might still be present on disk).
- `-configuration Release` triggers the heavy postCompile phases
  the Debug build skips: TSE model copy + Homebrew dylib closure
  bundle + install_name_tool rewrites + re-codesign. Cold this
  takes ~80 s; warm it's sentinel-guarded.

Watch for `** ARCHIVE SUCCEEDED **` in the last few lines. A
warning about "App Category not set" is benign — ignore it.

### 4. Verify the archive

The archive can succeed structurally but still ship a broken .app
(missing dylibs, dangling @rpath references, broken codesign).
Always run all five checks:

```bash
APP="$ARCHIVE_PATH/Products/Applications/VoiceKeyboard.app"

# A. Versions match what you bumped
/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" "$APP/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Print :CFBundleVersion"            "$APP/Contents/Info.plist"

# B. Codesign accepts the bundle as a whole
codesign --verify --deep --strict "$APP"

# C. Confirm the signing mode you actually got. Compare against
#    what you intended from "Signing modes" above:
#      - Apple Development: TeamIdentifier=<10-char>, Authority=Apple Development: <name>
#      - Ad-hoc:            TeamIdentifier=not set,   Signature=adhoc, flags=...adhoc...
codesign -dvv "$APP" 2>&1 | grep -E "Authority|Identifier|TeamIdentifier|flags|Signature"

# D. Every @rpath dep in every bundled dylib resolves to a real
#    file in Frameworks/. Catches a class of bundling regressions
#    without launching the app.
missing=0
for d in "$APP/Contents/Frameworks/"*.dylib; do
  [ -L "$d" ] && continue
  for ref in $(otool -L "$d" 2>/dev/null | tail -n +2 | awk '{print $1}' | grep '^@rpath/' || true); do
    name="${ref#@rpath/}"
    [ ! -e "$APP/Contents/Frameworks/$name" ] && { echo "MISSING: $(basename "$d") -> @rpath/$name"; missing=$((missing+1)); }
  done
done
echo "$missing missing @rpath references"

# E. TSE models bundled
ls "$APP/Contents/Resources/"*.onnx
```

Expected: B exits 0, C reports the mode you intended, D reports
`0 missing`, E lists `tse_model.onnx` and `speaker_encoder.onnx`.
App size is typically ~130 MB (16 MB libvkb + ~70 MB Homebrew
dylib closure + ~70 MB TSE models).

### 5. Produce the distributable zip

`ditto` is the right tool — `zip -r` corrupts macOS bundles
(strips xattrs, breaks symlinks, breaks codesign). Drop the zip in
`/tmp/` for easy scripting; the archive itself stays in
`~/Library/Developer/Xcode/Archives/` so Organizer can see it:

```bash
ditto -c -k --keepParent "$APP" "/tmp/VoiceKeyboard-$VERSION.app.zip"
ls -lh "/tmp/VoiceKeyboard-$VERSION.app.zip"
```

Expected size: ~80 MB compressed (the 130 MB .app compresses well
because the dylibs have a lot of redundant string tables).

What users will see depends on the signing mode of this archive:

- **Ad-hoc archives**: Gatekeeper blocks first launch with "can't
  be opened because Apple cannot check it for malicious software".
  Right-click → Open → Open dismisses it. Every fresh download
  re-prompts for TCC permissions (mic / accessibility) because the
  signature hash differs per build. This is expected for the
  unsigned, undistributed-via-Apple flow.
- **Apple Development archives**: only your own Mac (and machines
  in your Apple Developer team's provisioning profile) can launch
  the .app. Useful for personal iteration where you don't want to
  re-grant TCC every rebuild; useless as something to share.

A real Developer ID + notarization flow (sticky perms *and*
distributable to anyone) is documented as a future task in the
project's CLAUDE.md.

## Tagging a release (optional)

If this archive corresponds to an actual release (not just a local
verification build), tag with the platform-scoped prefix:

```bash
git tag mac-v<X.Y.Z>
git push origin mac-v<X.Y.Z>
```

The `.github/workflows/build.yml` workflow triggers on `mac-v*`,
runs the archive sequence on a clean macos-15 runner (which has
no `DeveloperSettings.xcconfig`, so always ad-hoc), and attaches
the resulting zip to a GitHub Release. That's the source of truth
for distributable builds; local archives are for verification.

If you're tagging a release after iterating with Apple Development
signing, run the local archive once more with `FORCE_ADHOC=1` and
confirm it still verifies — that's what CI will produce on the tag.

## Common pitfalls

- **"I rebuilt and macOS asked for permissions again"**: you're on
  ad-hoc signing. Ad-hoc embeds a per-build hash that differs every
  rebuild, and TCC keys grants on signature. Either (a) drop in
  `mac/Configs/DeveloperSettings.xcconfig` to sign with Apple
  Development (sticky perms on this Mac), or (b) accept the prompt
  as the cost of distributable builds.
- **"I changed signing settings but the .app still has the old
  signature"**: Xcode caches signed binaries aggressively. The
  archive script wipes `$ARCHIVE_PATH` and `/tmp/vkb-archive-derived`
  before each run for this reason — if you adapt the script, keep
  those `rm -rf`s.
- **Archive succeeds but launching the .app crashes with
  "library not loaded: @rpath/libonnxruntime.X.Y.Z.dylib"**:
  the postCompile dylib bundle phase didn't run or was incomplete.
  Re-archive with `rm -rf /tmp/vkb-archive-derived` to force the
  cold path; check the build log for `Bundle Homebrew dylibs` step
  output.
- **Codesign verify fails with "code object is not signed at all"
  on a file inside Frameworks/**: a sentinel or non-Mach-O file
  ended up there. The bundle phase should put sentinels in
  `BUILT_PRODUCTS_DIR`, not Frameworks/. Look for stray files in
  `$APP/Contents/Frameworks/` that aren't `.dylib`.
- **TSE models missing in Resources/**: `core/build/models/` is
  empty or the Release-only "Copy TSE models into Resources" phase
  errored. Run `./enroll.sh` to regenerate models, then re-archive.
- **App rebuilt but Info.plist version unchanged**: Xcode's
  incremental build sometimes reuses a cached Info.plist. Force
  it with `rm -rf /tmp/vkb-archive-derived` before re-archiving
  (the script already does this — the gotcha applies if you adapt
  the script).
- **Universal-arch prompt from Xcode IDE**: the project pins
  `ARCHS: arm64` (Apple Silicon only) because Homebrew cgo
  dylibs are arm64-only. Click "Build" in the prompt to keep the
  current configuration; "Update and Build" would either fail to
  link or get reverted by the next `make project`.

## Reference

- Project docs: `mac/CLAUDE.md` (build phases), `mac/README.md`
  (signing, architecture)
- CI source: `.github/workflows/build.yml` — archives without any
  `DeveloperSettings.xcconfig` so always ad-hoc; runs on every
  `mac-v*` tag
- Versioning: `mac/VoiceKeyboard/Info.plist` `CFBundleShortVersionString`
  + `CFBundleVersion`
- Local signing override: `mac/Configs/DeveloperSettings.xcconfig`
  (gitignored; sample at `DeveloperSettings.xcconfig.sample`)
