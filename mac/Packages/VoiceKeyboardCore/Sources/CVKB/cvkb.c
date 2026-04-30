// CVKB has no implementation of its own. The vkb_* C ABI is provided
// by libvkb.dylib at link time (Xcode app target supplies -lvkb).
//
// This translation unit exists only because SwiftPM needs *something*
// to compile for the CVKB target — a header-only target produces no
// .o file, which breaks Xcode's link step when the package is consumed
// via project.yml.
//
// We deliberately do NOT define stub vkb_* implementations here. The
// previous version did, marked __attribute__((weak)); when libCVKB.a
// was static-archived into the app binary, the in-binary weak symbols
// took precedence over libvkb.dylib's strong symbols at runtime, so
// every call into vkb_* silently returned 0 without invoking any Go
// code. The weak stubs needed only for `swift test` now live in the
// CVKBStubs target, which is wired only into the test target's
// dependencies.

static int cvkb_placeholder(void) { return 0; }
