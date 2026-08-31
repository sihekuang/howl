//go:build whispercpp

package transcribe

/*
#cgo CFLAGS: -I/opt/homebrew/opt/whisper-cpp/include -I/opt/homebrew/include
#cgo LDFLAGS: -L/opt/homebrew/opt/whisper-cpp/lib -L/opt/homebrew/lib -lwhisper -lggml -lggml-base

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

	// mu guards initialPrompt, which SetContextPrompt rewrites between
	// captures while Transcribe reads it.
	mu            sync.Mutex
	initialPrompt string
}

type WhisperOptions struct {
	ModelPath string
	Language  string // "en", "auto", etc.
	Threads   int    // 0 = default 4
	// InitialPrompt is an optional custom-vocabulary prompt passed to
	// whisper.cpp's whisper_full_params.initial_prompt. It biases the
	// decoder toward the spellings of domain terms (names, jargon,
	// acronyms). Empty means no prompt. The value is trimmed and
	// truncated to MaxInitialPromptLen on a UTF-8 boundary; build one
	// from a term list with DictionaryPrompt.
	InitialPrompt string
}

// Compile-time interface assertions
var _ Transcriber = (*WhisperCpp)(nil)
var _ PromptSetter = (*WhisperCpp)(nil)

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
	return &WhisperCpp{
		ctx:           ctx,
		lang:          lang,
		threads:       threads,
		initialPrompt: boundInitialPrompt(opts.InitialPrompt),
	}, nil
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

	// Optional custom-vocabulary prompt. Left nil (whisper's default)
	// when no prompt was configured. Read under the lock because
	// SetContextPrompt can rewrite initialPrompt between captures.
	w.mu.Lock()
	prompt := w.initialPrompt
	w.mu.Unlock()
	if prompt != "" {
		cPrompt := C.CString(prompt)
		defer C.free(unsafe.Pointer(cPrompt))
		params.initial_prompt = cPrompt
	}

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

// tokenCount returns how many whisper tokens text occupies in THIS
// model's vocabulary. Byte-length heuristics are not a substitute:
// jargon and CamelCase identifiers tokenize far denser than prose.
//
// mu is held across the nil-check and the whisper_token_count call so
// a concurrent Close cannot free w.ctx between the two: whisper_token_count
// runs on a freed *C.struct_whisper_context otherwise -- a hard crash
// with no Go-level signal. The call itself is short and non-blocking
// (unlike run_whisper_full), so holding the lock across it is fine.
func (w *WhisperCpp) tokenCount(text string) int {
	if text == "" {
		return 0
	}
	w.mu.Lock()
	defer w.mu.Unlock()
	if w.ctx == nil {
		return 0
	}
	cText := C.CString(text)
	defer C.free(unsafe.Pointer(cText))
	return int(C.whisper_token_count(w.ctx, cText))
}

// SetContextPrompt recomposes the initial prompt from the custom
// dictionary and screen-derived keywords, then trims it to whisper's
// real token window by dropping whole terms from the tail.
//
// Two stages, both dropping from the tail so screen keywords are always
// sacrificed before dictionary terms:
//  1. screen keywords alone must fit MaxScreenPromptTokens
//  2. the whole prompt must fit MaxPromptTokens
//
// Returns the screen-derived terms that survived BOTH stages — i.e.
// what actually ended up in the prompt whisper sees, not what was
// offered. Callers (howl_start_capture) record this return value, not
// the input screenTerms, in the session manifest: the manifest exists
// so a developer can trust what biased recognition, and a diagnostic
// that reports terms that were silently dropped for token-budget
// reasons is worse than no diagnostic at all.
//
// Safe to call while a PREVIOUS Transcribe is still running on this
// instance: both sides take `w.mu` around their access to
// `initialPrompt` (Transcribe snapshots it at the start of a run, this
// rewrites it under the same lock), so there's no data race. What that
// does NOT prevent is a logical race one level up: the engine calls
// this from howl_start_capture, whose only guarantee is "no audio is
// currently being pushed for a new capture" — not "no capture is in
// flight". A prior capture's pipeline goroutine (whisper drain + LLM
// cleanup) can still be mid-flight when the next one calls this, so
// the returned screen-keyword slice — which the caller stamps onto a
// pipeline object shared across captures for the session manifest —
// can end up recorded against the wrong capture. See the comment at
// the howl_start_capture call site.
//
// The composition itself lives in composeContextPrompt, which
// PreviewContextPrompt also calls. This method is only that plus the
// assignment, so the diagnostic preview and the real prompt can never
// disagree.
func (w *WhisperCpp) SetContextPrompt(dictTerms, screenTerms []string) []string {
	plan := w.composeContextPrompt(dictTerms, screenTerms)
	w.mu.Lock()
	w.initialPrompt = plan.Prompt
	w.mu.Unlock()
	return plan.ScreenApplied
}

// PreviewContextPrompt composes exactly what SetContextPrompt would
// compose for the same inputs and returns the full plan WITHOUT
// touching w.initialPrompt. Both go through composeContextPrompt, so
// the preview cannot drift from what whisper actually receives — that
// equivalence is the entire reason this method exists, and it is
// pinned by TestWhisperCpp_PreviewMatchesSetContextPrompt.
//
// It does take w.mu, transiently, inside each tokenCount call — so it
// is safe alongside an in-flight Transcribe for the same reason
// SetContextPrompt is, but it is NOT free: it runs the same
// whisper_token_count work. Call it for diagnostics, not per frame.
func (w *WhisperCpp) PreviewContextPrompt(dictTerms, screenTerms []string) ContextPromptPlan {
	return w.composeContextPrompt(dictTerms, screenTerms)
}

// composeContextPrompt is the single composition behind both
// SetContextPrompt and PreviewContextPrompt. Pure with respect to
// WhisperCpp's mutable state: it reads the model (via tokenCount) but
// assigns nothing.
//
// The trim logic below is the original SetContextPrompt body,
// unchanged, with a drop recorded after each stage. It must stay the
// only copy: a preview computed by a parallel path would disagree with
// the prompt whisper really gets, and would disagree exactly when
// someone is using it to work out why recognition went wrong.
func (w *WhisperCpp) composeContextPrompt(dictTerms, screenTerms []string) ContextPromptPlan {
	plan := ContextPromptPlan{
		Dictionary:            dictTerms,
		ScreenKeywords:        screenTerms,
		MaxScreenPromptTokens: MaxScreenPromptTokens,
		MaxPromptTokens:       MaxPromptTokens,
	}

	_, screen := ContextPrompt(dictTerms, screenTerms)
	dict := cleanTerms(dictTerms)

	plan.Dropped = append(plan.Dropped, blankTermDrops(dictTerms, SourceDictionary)...)
	plan.Dropped = append(plan.Dropped, screenPreFilterDrops(dictTerms, screenTerms, screen)...)

	screenOffered := screen
	for len(screen) > 0 && w.tokenCount(strings.Join(screen, ", ")) > MaxScreenPromptTokens {
		screen = screen[:len(screen)-1]
	}
	for _, t := range screenOffered[len(screen):] {
		plan.Dropped = append(plan.Dropped, PromptDrop{Term: t, Source: SourceScreen, Stage: DropScreenTokenCap})
	}

	// Byte-bound `dict` before the token-count loop below, unlike
	// `dict` above which is otherwise unbounded (cleanTerms alone,
	// not DictionaryPrompt's boundInitialPrompt). Without this, a
	// large custom dictionary (a few hundred terms) makes that loop
	// O(n²): every iteration re-joins and re-tokenises the WHOLE
	// remaining prompt just to drop one term — synchronously on the
	// PTT path, holding e.mu in howl_start_capture, for every user
	// regardless of whether screen context is even enabled.
	// MaxInitialPromptLen (896 bytes) is a generous upper bound for
	// MaxPromptTokens (224 tokens) at whisper's typical ~4 bytes/token
	// — the same relationship DictionaryPrompt already relies on — so
	// this narrows the loop below to at most a few dozen candidate
	// terms to refine, not hundreds. It's a pre-filter, not a
	// replacement for the token-count loop: byte length and token
	// count aren't identical, so the loop below remains the
	// authoritative bound.
	dictBounded := boundTermsByBytes(dict, MaxInitialPromptLen)
	for _, t := range dict[len(dictBounded):] {
		plan.Dropped = append(plan.Dropped, PromptDrop{Term: t, Source: SourceDictionary, Stage: DropDictByteCap})
	}
	plan.DictBounded = dictBounded

	all := make([]string, 0, len(dictBounded)+len(screen))
	all = append(all, dictBounded...)
	all = append(all, screen...)
	allOffered := all
	for len(all) > 0 && w.tokenCount(strings.Join(all, ", ")) > MaxPromptTokens {
		all = all[:len(all)-1]
	}
	for i := len(all); i < len(allOffered); i++ {
		source := SourceScreen
		if i < len(dictBounded) {
			source = SourceDictionary
		}
		plan.Dropped = append(plan.Dropped, PromptDrop{Term: allOffered[i], Source: source, Stage: DropPromptTokenCap})
	}

	plan.Prompt = strings.Join(all, ", ")
	// One extra whisper_token_count on an already-bounded string
	// (<= MaxInitialPromptLen bytes), so the plan can report the real
	// size of the prompt rather than an estimate. Deliberately not
	// folded into the loop condition above: that loop is the reviewed,
	// load-bearing trim and is left byte-for-byte as it was.
	plan.TokenCount = w.tokenCount(plan.Prompt)

	// dictBounded is always the head of `all` and screen the tail (see
	// the append order above), and both trim loops only ever shrink
	// from the tail — so whatever remains of `all` past
	// len(dictBounded) is exactly the screen terms that survived both
	// stages, in original order.
	if len(all) <= len(dictBounded) {
		plan.DictApplied = all
	} else {
		plan.DictApplied = all[:len(dictBounded)]
		plan.ScreenApplied = all[len(dictBounded):]
	}
	return plan
}

func (w *WhisperCpp) Close() error {
	// The nil-transition is guarded by mu so tokenCount's check-then-call
	// against w.ctx can't race THIS transition: either tokenCount
	// completes its whisper_token_count call while ctx is still valid, or
	// it observes ctx already nil and returns 0 -- never a call on a
	// freed context.
	//
	// That guarantee does NOT extend to Transcribe -- a known,
	// pre-existing gap this comment previously asserted away. Transcribe
	// reads w.ctx unlocked (its own nil-check, and again at the
	// run_whisper_full and whisper_full_get_segment_text call sites), so
	// it can still be holding and using the OLD pointer value after this
	// method nils the field below: a Close() racing an in-flight
	// Transcribe CAN free ctx out from under it. whisper_free is safe to
	// run outside the lock with respect to tokenCount specifically; it
	// is NOT safe with respect to a concurrent Transcribe.
	w.mu.Lock()
	ctx := w.ctx
	w.ctx = nil
	w.mu.Unlock()
	if ctx != nil {
		C.whisper_free(ctx)
	}
	return nil
}
