// Weak stubs for vkb_* C ABI symbols, used ONLY when running
// `swift test` against the package — the test binary doesn't link
// libvkb.dylib, so it needs something to resolve VoiceKeyboardCore's
// references to `vkb_start_capture` etc. This translation unit is in
// its own target so the app build never picks it up: when the Xcode
// app links VoiceKeyboardCore, it pulls in the (empty) CVKB target
// for the umbrella module, and resolves the C symbols from
// libvkb.dylib via `-lvkb`. CVKBStubs is wired only into the test
// target's dependencies, keeping the symbol-shadowing footgun
// localized to test builds.

#include <stdlib.h>

int vkb_init(void)            { return 0; }
int vkb_configure(char* json) { (void)json; return 0; }
int vkb_start_capture(void)   { return 0; }
int vkb_push_audio(const float* samples, int count) { (void)samples; (void)count; return 0; }
int vkb_stop_capture(void)    { return 0; }
char* vkb_poll_event(void)    { return NULL; }
void vkb_destroy(void)        {}
char* vkb_last_error(void)    { return NULL; }
void vkb_free_string(char* s) { (void)s; }
