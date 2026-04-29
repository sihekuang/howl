// CVKB has no implementation of its own; the actual symbols come from
// libvkb.dylib at link time (Xcode app target supplies -lvkb). This
// translation unit exists only so SwiftPM has something to compile for
// the CVKB target — a header-only target produces no .o file, which
// breaks Xcode's link step when the package is consumed via
// project.yml.
//
// Stub implementations allow `swift test` to link without libvkb.dylib.
// All stubs are __attribute__((weak)) so libvkb.dylib's strong symbols
// always win at link time in the Xcode app build. The stubs only get
// used when no other definition is present (i.e., during `swift test`).

#include "libvkb_shim.h"
#include <stdlib.h>

__attribute__((weak)) int vkb_init(void)            { return 0; }
__attribute__((weak)) int vkb_configure(char* json) { (void)json; return 0; }
__attribute__((weak)) int vkb_start_capture(void)   { return 0; }
__attribute__((weak)) int vkb_stop_capture(void)    { return 0; }
__attribute__((weak)) char* vkb_poll_event(void)    { return NULL; }
__attribute__((weak)) void vkb_destroy(void)        {}
__attribute__((weak)) char* vkb_last_error(void)    { return NULL; }
__attribute__((weak)) void vkb_free_string(char* s) { (void)s; }
