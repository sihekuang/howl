// CVKB has no implementation of its own; the actual symbols come from
// libvkb.dylib at link time (Xcode app target supplies -lvkb). This
// translation unit exists only so SwiftPM has something to compile for
// the CVKB target — a header-only target produces no .o file, which
// breaks Xcode's link step when the package is consumed via
// project.yml.
//
// Stub implementations allow `swift test` to link without libvkb.dylib.
// In production the Xcode app target links against libvkb.dylib, whose
// real symbols override these stubs via link order.

#include "libvkb_shim.h"
#include <stdlib.h>

int vkb_init(void)            { return 0; }
int vkb_configure(char* json) { (void)json; return 0; }
int vkb_start_capture(void)   { return 0; }
int vkb_stop_capture(void)    { return 0; }
char* vkb_poll_event(void)    { return NULL; }
void vkb_destroy(void)        {}
char* vkb_last_error(void)    { return NULL; }
void vkb_free_string(char* s) { (void)s; }
