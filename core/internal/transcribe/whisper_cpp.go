//go:build whispercpp

package transcribe

/*
#cgo darwin CFLAGS: -I/opt/homebrew/opt/whisper-cpp/include -I/opt/homebrew/include
#cgo darwin LDFLAGS: -L/opt/homebrew/opt/whisper-cpp/lib -L/opt/homebrew/lib -lwhisper -lggml -lggml-base
#cgo windows CFLAGS: -IC:/dev/whisper-dist/include
#cgo windows LDFLAGS: -LC:/dev/whisper-dist/lib -lwhisper -lggml -lggml-base

#include <stdlib.h>
#include "whisper.h"
#include "ggml.h"
#include "ggml-backend.h"

// noop_log is a no-op ggml/whisper log callback that discards all output.
static void noop_log(enum ggml_log_level level, const char *text, void *user_data) {
    (void)level; (void)text; (void)user_data;
}

// silence_whisper_logs disables whisper.cpp and ggml's default stderr
// logger by installing a no-op callback. Call once per process, before
// whisper_init_* and ggml_backend_load_all.
static void silence_whisper_logs(void) {
    whisper_log_set(noop_log, NULL);
    ggml_log_set(noop_log, NULL);
}

// Helper that calls whisper_full and returns the segment count.
// Lives here so we can pass Go-allocated float buffers cleanly.
static int run_whisper_full(struct whisper_context* ctx,
                             struct whisper_full_params params,
                             const float* samples, int n_samples) {
    int rc = whisper_full(ctx, params, samples, n_samples);
    if (rc != 0) return -1;
    return whisper_full_n_segments(ctx);
}
*/
import "C"

import (
	"context"
	"errors"
	"fmt"
	"strings"
	"sync"
	"unsafe"
)

// whisper-cpp v1.8.4 splits its compute backends (Metal, BLAS, CPU
// micro-arch) into dynamically-loaded .so files in
// /opt/homebrew/Cellar/ggml/0.10.0/libexec/. Without calling
// ggml_backend_load_all() once per process, whisper_init_from_file_*
// aborts with GGML_ASSERT(device) failed because make_buft_list finds
// no registered devices. sync.Once ensures we load exactly once.
var backendsOnce sync.Once

func loadBackends() {
	backendsOnce.Do(func() {
		C.silence_whisper_logs()
		C.ggml_backend_load_all()
	})
}

// WhisperCpp wraps a whisper.cpp context. NOT safe for concurrent calls
// to Transcribe on the same instance.
type WhisperCpp struct {
	ctx     *C.struct_whisper_context
	lang    string
	threads int
}

type WhisperOptions struct {
	ModelPath string
	Language  string // "en", "auto", etc.
	Threads   int    // 0 = default 4
}

// Compile-time interface assertion
var _ Transcriber = (*WhisperCpp)(nil)

func NewWhisperCpp(opts WhisperOptions) (*WhisperCpp, error) {
	if opts.ModelPath == "" {
		return nil, errors.New("whisper: ModelPath is required")
	}
	loadBackends()
	cPath := C.CString(opts.ModelPath)
	defer C.free(unsafe.Pointer(cPath))

	cparams := C.whisper_context_default_params()
	ctx := C.whisper_init_from_file_with_params(cPath, cparams)
	if ctx == nil {
		return nil, fmt.Errorf("whisper: failed to load model %q", opts.ModelPath)
	}
	threads := opts.Threads
	if threads <= 0 {
		threads = 4
	}
	lang := opts.Language
	if lang == "" {
		lang = "auto"
	}
	return &WhisperCpp{ctx: ctx, lang: lang, threads: threads}, nil
}

// Transcribe runs whisper.cpp inference synchronously. NOTE: ctx is
// accepted to satisfy the Transcriber interface, but whisper_full is
// a blocking C call that does not honor cancellation. Cancellation
// support would require wiring whisper_full_params.abort_callback to
// poll ctx.Done() — out of scope for v1.
func (w *WhisperCpp) Transcribe(ctx context.Context, pcm16k []float32) (string, error) {
	if w.ctx == nil {
		return "", errors.New("whisper: closed")
	}
	if len(pcm16k) == 0 {
		return "", nil
	}

	params := C.whisper_full_default_params(C.WHISPER_SAMPLING_GREEDY)
	params.n_threads = C.int(w.threads)
	params.print_progress = C.bool(false)
	params.print_realtime = C.bool(false)
	params.print_timestamps = C.bool(false)
	params.suppress_blank = C.bool(true)
	params.no_timestamps = C.bool(true)
	cLang := C.CString(w.lang)
	defer C.free(unsafe.Pointer(cLang))
	params.language = cLang

	nSegs := C.run_whisper_full(
		w.ctx, params,
		(*C.float)(unsafe.Pointer(&pcm16k[0])),
		C.int(len(pcm16k)),
	)
	if nSegs < 0 {
		return "", errors.New("whisper: inference failed")
	}

	var b strings.Builder
	for i := C.int(0); i < nSegs; i++ {
		cstr := C.whisper_full_get_segment_text(w.ctx, i)
		b.WriteString(C.GoString(cstr))
	}
	return strings.TrimSpace(b.String()), nil
}

func (w *WhisperCpp) Close() error {
	if w.ctx != nil {
		C.whisper_free(w.ctx)
		w.ctx = nil
	}
	return nil
}
