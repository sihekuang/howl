# Rebuilding libdf.dylib

The `libdf.dylib` shipped under `third_party/deepfilter/lib/macos-arm64/` is built once by a maintainer and committed to the repo. Day-to-day contributors do not need Rust — they just consume the prebuilt binary.

This document describes how to regenerate the binary when bumping DeepFilterNet versions.

## Prerequisites
- Rust toolchain (`rustup`)
- Xcode command-line tools
- `cbindgen` (`cargo install cbindgen`) — used to generate `deep_filter.h`

## Steps

1. Install Rust if missing:
   ```bash
   curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs | sh
   source "$HOME/.cargo/env"
   ```

2. Install cbindgen:
   ```bash
   cargo install cbindgen
   ```

3. Clone DeepFilterNet at the desired tag:
   ```bash
   git clone --depth 1 --branch <TAG> https://github.com/Rikorose/DeepFilterNet.git
   cd DeepFilterNet
   ```

4. Apply the two local patches required as of `v0.5.6` (see `third_party/deepfilter/VERSION.md` for the latest known-good values):

   a. Refresh the `time` crate so it builds on modern rustc:
   ```bash
   cargo update -p time
   ```

   b. Add `cdylib` to the libDF crate-type so cargo emits a shared library. Edit `libDF/Cargo.toml`:
   ```toml
   [lib]
   name = "df"
   path = "src/lib.rs"
   crate-type = ["cdylib", "rlib"]
   ```
   (Upstream uses `cargo-c` to produce the shared library via the `[package.metadata.capi.*]` blocks; we bypass that toolchain and just build with stock cargo.)

5. Build for arm64 macOS:
   ```bash
   export MACOSX_DEPLOYMENT_TARGET=13.0
   cargo build --release -p deep_filter --features capi --target aarch64-apple-darwin
   ```

   First-time builds take 5–15 minutes.

6. Generate the C header with cbindgen (run from inside the cloned
   DeepFilterNet directory, where the upstream cbindgen.toml lives):
   ```bash
   cbindgen --config cbindgen.toml --crate deep_filter --output deep_filter.h
   ```

7. Copy the artifacts into the vendor directory:
   ```bash
   cp target/aarch64-apple-darwin/release/libdf.dylib \
      <REPO>/core/third_party/deepfilter/lib/macos-arm64/
   cp deep_filter.h \
      <REPO>/core/third_party/deepfilter/include/
   ```

8. Rewrite the install name:
   ```bash
   cd <REPO>/core/third_party/deepfilter/lib/macos-arm64
   install_name_tool -id "@rpath/libdf.dylib" libdf.dylib
   otool -D libdf.dylib   # should print @rpath/libdf.dylib
   ```

9. Update `third_party/deepfilter/VERSION.md` with the new tag, commit hash, build date, Rust version, and any new local patches.

10. Run the denoise tests:
    ```bash
    cd <REPO>/core
    make test-unit
    ```
