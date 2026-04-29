# DeepFilterNet vendored binary

| Field | Value |
|---|---|
| Upstream | https://github.com/Rikorose/DeepFilterNet |
| Tag | v0.5.6 |
| Commit | 978576aa8400552a4ce9730838c635aa30db5e61 |
| Build target | aarch64-apple-darwin |
| MACOSX_DEPLOYMENT_TARGET | 13.0 |
| Rust version | rustc 1.95.0 (59807616e 2026-04-14) |
| Cargo package | deep_filter |
| Cargo features | capi |
| cbindgen version | 0.29.2 |
| Build date | 2026-04-29T18:18:37Z |

## Build notes

Two adjustments were required against an unmodified `v0.5.6` clone:

1. `cargo update -p time` to pull `time v0.3.28 -> v0.3.44`. The pinned version in the upstream `Cargo.lock` does not compile on rustc 1.95.
2. Added `crate-type = ["cdylib", "rlib"]` to `libDF/Cargo.toml`'s `[lib]` section so a `.dylib` is emitted. Upstream relies on `cargo-c` to produce the shared library; we bypass that and use plain `cargo build` plus `cbindgen` for the header.

The C header was generated separately with `cbindgen --config cbindgen.toml --crate deep_filter --output deep_filter.h` (cbindgen 0.29.2). Static helpers `df_coef_size` and `df_gain_size` are intentionally excluded by upstream from the C ABI (no `#[no_mangle]`) and do not appear in the header.

## How this was built

See `BUILDING_DENOISE.md`.
