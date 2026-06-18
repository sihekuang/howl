# Howl — Windows App

The Windows client for Howl.

## Prerequisites

- **Go** — https://go.dev/dl/ (windows-amd64)
- **MSYS2 UCRT64** — https://www.msys2.org/ (MinGW-w64 C toolchain)
- **whisper.cpp** — built locally to C:/dev/whisper-dist (see core/third_party/whisper-cpp/VERSION.md)
- **ONNX Runtime** — DLL placed alongside the binary

## Build & run

From this directory (win/):

    (build instructions to be added as the Windows shell is built)

## Architecture: x64 only

The app targets x64-based Windows 10/11. ARM64 Windows support is not implemented yet.

## Project layout

    (to be filled in as the Windows shell is built)

For build phases, gotchas, and deeper internals, see win/CLAUDE.md (to be created).