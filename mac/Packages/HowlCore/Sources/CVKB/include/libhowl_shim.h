// CVKB — bridges the Plan 1 libhowl C ABI into Swift via SwiftPM.
//
// Forward-declares the libhowl C ABI so the package's tests can compile
// against the symbols without actually linking. The real header at
// core/build/libhowl.h is the source of truth; if the ABI changes, update
// here. Linkage against libhowl.dylib is configured by the Xcode app
// target (OTHER_LDFLAGS: -lhowl), not by SwiftPM.
#ifndef CVKB_LIBHOWL_SHIM_H
#define CVKB_LIBHOWL_SHIM_H

int howl_init(void);
int howl_configure(char* json);
int howl_start_capture(void);
int howl_push_audio(const float* samples, int count);
int howl_stop_capture(void);
int howl_cancel_capture(void);
char* howl_poll_event(void);
void howl_destroy(void);
char* howl_last_error(void);
void howl_free_string(char* s);

int howl_enroll_compute(const float* samples, int count, int sample_rate, const char* profile_dir);

char* howl_list_sessions(void);
char* howl_get_session(const char* id);
int   howl_delete_session(const char* id);
int   howl_clear_sessions(void);

// Preset management.
char* howl_list_presets(void);
char* howl_get_preset(const char* name);
int   howl_save_preset(const char* name, const char* description, const char* body);
int   howl_delete_preset(const char* name);

// Compare / replay.
char* howl_replay(const char* source_id, const char* presets_csv);

// TSE Lab — run Target Speaker Extraction on an arbitrary WAV file.
// Returns 0 on success, non-zero on failure (use howl_last_error for detail).
int howl_tse_extract_file(char* inputPath, char* outputPath, char* modelsDir, char* voiceDir, char* onnxLibPath);

#endif
