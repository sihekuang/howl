// CVKB — bridges the Plan 1 libvkb C ABI into Swift via SwiftPM.
//
// Forward-declares the libvkb C ABI so the package's tests can compile
// against the symbols without actually linking. The real header at
// core/build/libvkb.h is the source of truth; if the ABI changes, update
// here. Linkage against libvkb.dylib is configured by the Xcode app
// target (OTHER_LDFLAGS: -lvkb), not by SwiftPM.
#ifndef CVKB_LIBVKB_SHIM_H
#define CVKB_LIBVKB_SHIM_H

int vkb_init(void);
int vkb_configure(char* json);
int vkb_start_capture(void);
int vkb_push_audio(const float* samples, int count);
int vkb_stop_capture(void);
int vkb_cancel_capture(void);
char* vkb_poll_event(void);
void vkb_destroy(void);
char* vkb_last_error(void);
void vkb_free_string(char* s);

int vkb_enroll_compute(const float* samples, int count, int sample_rate, const char* profile_dir);

char* vkb_list_sessions(void);
char* vkb_get_session(const char* id);
int   vkb_delete_session(const char* id);
int   vkb_clear_sessions(void);

// Preset management.
char* vkb_list_presets(void);
char* vkb_get_preset(const char* name);
int   vkb_save_preset(const char* name, const char* description, const char* body);
int   vkb_delete_preset(const char* name);

// Compare / replay.
char* vkb_replay(const char* source_id, const char* presets_csv);

// TSE Lab — run Target Speaker Extraction on an arbitrary WAV file.
// Returns 0 on success, non-zero on failure (use vkb_last_error for detail).
int vkb_tse_extract_file(char* inputPath, char* outputPath, char* modelsDir, char* voiceDir, char* onnxLibPath);

#endif
