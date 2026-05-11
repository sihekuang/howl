// CVKB has no implementation of its own. The howl_* C ABI is provided
// by libhowl.dylib at link time (Xcode app target supplies -lhowl).
//
// This translation unit exists only because SwiftPM needs *something*
// to compile for the CVKB target — a header-only target produces no
// .o file, which breaks Xcode's link step when the package is consumed
// via project.yml.
//
// We deliberately do NOT define stub howl_* implementations here. The
// previous version did, marked __attribute__((weak)); when libCVKB.a
// was static-archived into the app binary, the in-binary weak symbols
// took precedence over libhowl.dylib's strong symbols at runtime, so
// every call into howl_* silently returned 0 without invoking any Go
// code. The weak stubs needed only for `swift test` now live in the
// CVKBStubs target, which is wired only into the test target's
// dependencies.

static int cvkb_placeholder(void) { return 0; }
