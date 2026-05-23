// Weak stubs for vkb_* C ABI symbols, used ONLY when running
// `swift test` against the package — the test binary doesn't link
// libhowl.dylib, so it needs something to resolve VoiceKeyboardCore's
// references to `howl_start_capture` etc. This translation unit is in
// its own target so the app build never picks it up: when the Xcode
// app links VoiceKeyboardCore, it pulls in the (empty) CVKB target
// for the umbrella module, and resolves the C symbols from
// libhowl.dylib via `-lhowl`. CVKBStubs is wired only into the test
// target's dependencies, keeping the symbol-shadowing footgun
// localized to test builds.

#include <stdlib.h>

int howl_init(void)            { return 0; }
int howl_configure(char* json) { (void)json; return 0; }
int howl_start_capture(void)   { return 0; }
int howl_push_audio(const float* samples, int count) { (void)samples; (void)count; return 0; }
int howl_stop_capture(void)    { return 0; }
int howl_cancel_capture(void)  { return 0; }
char* howl_poll_event(void)    { return NULL; }
void howl_destroy(void)        {}
char* howl_last_error(void)    { return NULL; }
void howl_free_string(char* s) { (void)s; }
int howl_enroll_compute(const float* samples, int count, int sample_rate, const char* profile_dir) { (void)samples; (void)count; (void)sample_rate; (void)profile_dir; return 0; }
char* howl_list_sessions(void)            { return NULL; }
char* howl_get_session(const char* id)    { (void)id; return NULL; }
int   howl_delete_session(const char* id) { (void)id; return 0; }
int   howl_clear_sessions(void)           { return 0; }

// Preset management — Slice 2 stubs.
char* howl_list_presets(void)             { return NULL; }
char* howl_get_preset(const char* name)   { (void)name; return NULL; }
int   howl_save_preset(const char* name, const char* description, const char* body) {
    (void)name; (void)description; (void)body; return 1;
}
int   howl_delete_preset(const char* name) { (void)name; return 1; }

// Compare / replay — Slice 4 stub.
char* howl_replay(const char* source_id, const char* presets_csv) {
    (void)source_id; (void)presets_csv; return NULL;
}

// TSE Lab — Slice debug stub. Tests don't actually invoke the model;
// they exercise error paths so returning -1 is the most useful default.
int howl_tse_extract_file(char* inputPath, char* outputPath, char* modelsDir, char* voiceDir, char* onnxLibPath) {
    (void)inputPath; (void)outputPath; (void)modelsDir; (void)voiceDir; (void)onnxLibPath;
    return -1;
}
