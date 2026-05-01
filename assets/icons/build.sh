#!/usr/bin/env bash
#
# Rasterize assets/icons/*.svg into platform-specific icon files.
#
# Outputs:
#   generated/png/<name>-<size>.png       — every size we generate (gitignored)
#   generated/voicekeyboard.icns          — macOS app icon  (Mac builds consume)
#   generated/voicekeyboard.ico           — Windows app icon (future Windows builds consume)
#   generated/menubar/{16,32}.png         — macOS template image variants
#   mac/VoiceKeyboard/Assets.xcassets/AppIcon.appiconset/*  — populated by this script
#   mac/VoiceKeyboard/Assets.xcassets/MenuBarIcon.imageset/* — same
#
# Dependencies:
#   librsvg     (brew install librsvg)            — SVG → PNG rasterization
#   iconutil    (preinstalled on macOS)           — PNG set → .icns
#   ImageMagick (brew install imagemagick) — only needed for .ico (skipped if missing)
#
# Run from repo root:  ./assets/icons/build.sh
# Idempotent: re-running is safe.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

APP_SVG="$SCRIPT_DIR/app-icon.svg"
MENU_SVG="$SCRIPT_DIR/menubar-icon.svg"
OUT="$SCRIPT_DIR/generated"
PNG_DIR="$OUT/png"
ICONSET="$OUT/voicekeyboard.iconset"

if ! command -v rsvg-convert >/dev/null 2>&1; then
  echo "error: rsvg-convert not found. Install with: brew install librsvg" >&2
  exit 1
fi
if ! command -v iconutil >/dev/null 2>&1; then
  echo "error: iconutil not found (should ship with macOS)" >&2
  exit 1
fi

mkdir -p "$PNG_DIR" "$ICONSET" "$OUT/menubar"

rasterize() {
  local svg="$1" size="$2" out="$3"
  rsvg-convert --width="$size" --height="$size" --keep-aspect-ratio \
               --output="$out" "$svg"
}

# ---------- macOS .icns ----------
# iconutil expects a .iconset directory with these exact filenames.
# Each size has 1x and 2x variants, except for the largest 1024.
echo "==> Rasterizing app icon to PNGs (1x + 2x for each size)"
declare -a SIZES=(16 32 128 256 512)
for size in "${SIZES[@]}"; do
  rasterize "$APP_SVG" "$size"        "$ICONSET/icon_${size}x${size}.png"
  rasterize "$APP_SVG" $((size * 2))  "$ICONSET/icon_${size}x${size}@2x.png"
  cp "$ICONSET/icon_${size}x${size}.png"   "$PNG_DIR/app-${size}.png"
done
# 1024 standalone (no @2x equivalent in .icns).
rasterize "$APP_SVG" 1024 "$ICONSET/icon_512x512@2x.png"
cp "$ICONSET/icon_512x512@2x.png" "$PNG_DIR/app-1024.png"

echo "==> Building voicekeyboard.icns"
iconutil --convert icns "$ICONSET" --output "$OUT/voicekeyboard.icns"

# ---------- Linux freedesktop PNGs ----------
# Standard icon-theme sizes; symlink-friendly naming for hicolor theme.
echo "==> Generating Linux PNG set"
for size in 16 24 32 48 64 128 256 512; do
  rasterize "$APP_SVG" "$size" "$PNG_DIR/app-${size}.png" 2>/dev/null || true
done

# ---------- Windows .ico ----------
# ImageMagick can pack multiple PNG resolutions into a single .ico.
# Skip if not installed — Windows builds aren't part of the current
# CI matrix anyway. The PNG set above is enough for any future tool
# (icoutils, png2ico, etc.) to assemble.
if command -v magick >/dev/null 2>&1; then
  echo "==> Building voicekeyboard.ico (ImageMagick)"
  magick "$PNG_DIR/app-16.png" "$PNG_DIR/app-32.png" \
         "$PNG_DIR/app-48.png" "$PNG_DIR/app-64.png" \
         "$PNG_DIR/app-128.png" "$PNG_DIR/app-256.png" \
         "$OUT/voicekeyboard.ico"
elif command -v convert >/dev/null 2>&1; then
  echo "==> Building voicekeyboard.ico (ImageMagick legacy convert)"
  convert "$PNG_DIR/app-16.png" "$PNG_DIR/app-32.png" \
          "$PNG_DIR/app-48.png" "$PNG_DIR/app-64.png" \
          "$PNG_DIR/app-128.png" "$PNG_DIR/app-256.png" \
          "$OUT/voicekeyboard.ico"
else
  echo "==> Skipping .ico — install ImageMagick (brew install imagemagick) when shipping Windows"
fi

# ---------- Menu bar template image (Mac) ----------
# Two PNGs: 16×16 (1x) and 32×32 (2x). macOS Assets.xcassets renders
# them as a template (auto-tinted by system).
echo "==> Rasterizing menu bar template"
rasterize "$MENU_SVG" 16 "$OUT/menubar/16.png"
rasterize "$MENU_SVG" 32 "$OUT/menubar/32.png"

# ---------- Wire artifacts into the macOS Xcode asset catalog ----------
# Asset catalogs need a Contents.json + the PNGs side-by-side. We
# regenerate the AppIcon.appiconset from scratch so the script remains
# the source of truth.
ASSETS="$REPO_ROOT/mac/VoiceKeyboard/Assets.xcassets"
APPICON="$ASSETS/AppIcon.appiconset"
MENUICON="$ASSETS/MenuBarIcon.imageset"

mkdir -p "$APPICON" "$MENUICON"

# Top-level catalog metadata.
cat > "$ASSETS/Contents.json" <<'EOF'
{
  "info" : { "author" : "xcode", "version" : 1 }
}
EOF

# AppIcon.appiconset — sizes / scales matching macOS expectations.
cat > "$APPICON/Contents.json" <<'EOF'
{
  "images" : [
    { "size" : "16x16",   "idiom" : "mac", "filename" : "16.png",       "scale" : "1x" },
    { "size" : "16x16",   "idiom" : "mac", "filename" : "32.png",       "scale" : "2x" },
    { "size" : "32x32",   "idiom" : "mac", "filename" : "32.png",       "scale" : "1x" },
    { "size" : "32x32",   "idiom" : "mac", "filename" : "64.png",       "scale" : "2x" },
    { "size" : "128x128", "idiom" : "mac", "filename" : "128.png",      "scale" : "1x" },
    { "size" : "128x128", "idiom" : "mac", "filename" : "256.png",      "scale" : "2x" },
    { "size" : "256x256", "idiom" : "mac", "filename" : "256.png",      "scale" : "1x" },
    { "size" : "256x256", "idiom" : "mac", "filename" : "512.png",      "scale" : "2x" },
    { "size" : "512x512", "idiom" : "mac", "filename" : "512.png",      "scale" : "1x" },
    { "size" : "512x512", "idiom" : "mac", "filename" : "1024.png",     "scale" : "2x" }
  ],
  "info" : { "author" : "xcode", "version" : 1 }
}
EOF

# Each AppIcon entry expects its PNG by raw size — produce all of them.
for s in 16 32 64 128 256 512 1024; do
  rasterize "$APP_SVG" "$s" "$APPICON/${s}.png"
done

# MenuBarIcon.imageset — a single template image.
cat > "$MENUICON/Contents.json" <<'EOF'
{
  "images" : [
    { "idiom" : "universal", "filename" : "menubar-16.png", "scale" : "1x" },
    { "idiom" : "universal", "filename" : "menubar-32.png", "scale" : "2x" }
  ],
  "info" : { "author" : "xcode", "version" : 1 },
  "properties" : { "template-rendering-intent" : "template" }
}
EOF
cp "$OUT/menubar/16.png" "$MENUICON/menubar-16.png"
cp "$OUT/menubar/32.png" "$MENUICON/menubar-32.png"

echo ""
echo "✓ Done. Outputs:"
echo "  $OUT/voicekeyboard.icns"
[ -f "$OUT/voicekeyboard.ico" ] && echo "  $OUT/voicekeyboard.ico"
echo "  $PNG_DIR/app-{16,24,32,48,64,128,256,512}.png  (Linux)"
echo "  $ASSETS/AppIcon.appiconset/                     (Mac, in Xcode catalog)"
echo "  $ASSETS/MenuBarIcon.imageset/                   (Mac, template image)"
