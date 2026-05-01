# Icons

Master SVG sources + a build script that fan out to the platform-specific
formats every desktop OS expects.

## Layout

```
assets/icons/
├── app-icon.svg       — color, full-bleed app icon (1024×1024 logical)
├── menubar-icon.svg   — single-color template (32×32 logical)
├── build.sh           — rasterizes SVGs → PNG / .icns / .ico, populates Xcode catalog
├── README.md          — this file
└── generated/         — build outputs (gitignored)
    ├── voicekeyboard.icns
    ├── voicekeyboard.ico         (only when ImageMagick is installed)
    ├── png/app-{16,24,32,48,64,128,256,512,1024}.png
    └── menubar/{16,32}.png
```

## Editing

Both source files are hand-written SVG. Open in any vector tool (Sketch,
Figma, Affinity, Inkscape) or a text editor. Re-run `build.sh` after
changes to refresh every platform's outputs.

The 1024×1024 / 32×32 viewBoxes are the design canvases — no internal
margin, the icons are full-bleed by modern macOS convention.

## Building

From the repo root:

```bash
./assets/icons/build.sh
```

### Dependencies

| Tool         | Used for                | Install                          |
|--------------|-------------------------|----------------------------------|
| `rsvg-convert` | SVG → PNG             | `brew install librsvg`           |
| `iconutil`   | PNG set → `.icns`       | preinstalled on macOS            |
| `magick` (or `convert`) | PNG set → `.ico` | `brew install imagemagick` (optional, only needed for Windows builds) |

If `librsvg` is missing the script aborts with a clear message. If
ImageMagick is missing the script skips the `.ico` step and notes it —
the PNG set is still produced and any future Windows packaging tool
(`png2ico`, `icoutils`) can assemble from there.

## Linux

The build script writes the standard freedesktop `hicolor` size set
(`16, 24, 32, 48, 64, 128, 256, 512`) to `generated/png/`. Drop those
into a Linux package's `usr/share/icons/hicolor/<size>x<size>/apps/`
hierarchy (or use the freedesktop `xdg-icon-resource` tool).

## Windows

Same SVG → `voicekeyboard.ico` (multi-resolution) when ImageMagick is
present. Future Windows installer setup (Inno Setup, MSIX, etc.) can
reference the .ico directly.

## macOS integration

`build.sh` also writes into `mac/VoiceKeyboard/Assets.xcassets/`:

- `AppIcon.appiconset/` — all sizes Xcode expects, plus the `Contents.json`.
- `MenuBarIcon.imageset/` — template image (single color, auto-tinted by macOS).

The asset catalog is regenerated from scratch each run, so the script is
the source of truth — don't hand-edit the catalog files. `project.yml`
references `Assets.xcassets` as a source path, so xcodegen + xcodebuild
pick the icons up automatically.
