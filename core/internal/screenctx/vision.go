package screenctx

import (
	"context"
	"fmt"
	"sync"
	"time"

	"github.com/voice-keyboard/core/internal/config"
	"github.com/voice-keyboard/core/internal/llm"
)

const (
	// ExtractImageTimeout bounds the vision provider call. Longer than
	// ExtractTimeout because a vision request is a different animal: it
	// uploads a downscaled screenshot rather than a few KB of text, and
	// a local vision model (Ollama/LM Studio) JIT-loads a projector on
	// top of the language model on the first request after idle. Still
	// short enough that the result cannot outlive the user's interest
	// in the window by much.
	//
	// This is the one number in this file that is a guess rather than a
	// measurement — it should be tuned once the Swift side can report
	// real end-to-end latencies.
	ExtractImageTimeout = 12 * time.Second

	// MaxImageBytes bounds what leaves the process on the image path,
	// mirroring MaxWindowTextBytes' role on the text path. The design
	// puts a 1568px-long-edge PNG well under this; anything larger is a
	// capture bug, and shipping it would blow the timeout and the bill.
	// Anthropic's own per-image limit is 5MB, which is where this comes
	// from.
	MaxImageBytes = 5 << 20
)

// ExtractImagePrompt is the image counterpart of ExtractPrompt. It
// carries EVERY constraint the text prompt carries — comma-separated
// output, a cap on the count, verbatim-only terms, and the
// skip-anything-secret rule — because those constraints are what makes
// the output safe to feed to whisper, not an artefact of the input
// being text.
//
// Unlike ExtractPrompt it must NOT contain {{transcription}}: there is
// no transcription, and llm.RenderImagePrompt deliberately never
// appends one. It must still contain {{dictionary}}.
const ExtractImagePrompt = `You extract vocabulary hints for a speech-recognition system. The attached image is a screenshot of the user's focused window. The user is about to dictate while looking at it.

Read the screenshot and list the words and phrases a speech recogniser is most likely to get wrong: proper nouns, people's names, product and project names, code identifiers, acronyms, filenames, and domain jargon. Use the layout to judge what matters — a filename in a tab bar, a symbol in code, a heading — not just any text that happens to be visible.

Hard rules:
- Return ONLY a comma-separated list. No preamble, no numbering, no explanation.
- At most 20 items, most useful first.
- Every item must appear verbatim on the screen. Do not invent, translate, correct, or describe the image.
- Skip ordinary English words a recogniser already handles.
- Skip anything resembling a secret, password, API key, or token.
- These terms are already covered — do NOT repeat them: {{dictionary}}
- If nothing qualifies, return an empty string.`

// VisionKey identifies a (provider, model) pair for the text-only
// cache. It is deliberately the CONFIGURED pair, not a resolved one:
// the verdict must be invalidated by exactly the settings change that
// could make it wrong, and nothing else.
type VisionKey struct {
	Provider string
	Model    string
}

// VisionKeyFor builds the cache key for cfg, resolving an empty
// provider to the default provider's name so that "unset" and "set to
// the default" address the same slot.
//
// Known imprecision: an empty Model means Ollama/LM Studio auto-detect,
// so the verdict is keyed to the auto-detect slot rather than to
// whatever model was actually picked. A user who pulls a different
// model without touching Howl's settings can therefore inherit a stale
// verdict for the process lifetime. The cost is one feature degraded
// until restart; the alternative — asking the Cleaner which model it
// resolved to — would put a model accessor on an interface that exists
// to hide exactly that.
func VisionKeyFor(cfg config.Config) VisionKey {
	provider := cfg.LLMProvider
	if p, err := llm.ProviderByName(provider); err == nil {
		provider = p.Name
	}
	// On error the raw name is kept: an unknown provider fails long
	// before the cache matters, and inventing a name here would let two
	// different bad configs collide.
	return VisionKey{Provider: provider, Model: cfg.LLMModel}
}

// textOnlyModels records (provider, model) pairs that were empirically
// found to reject images. In memory only, for the process lifetime —
// per the design, a maintained capability table would rot immediately,
// and the verdict must not survive a settings change or a restart.
var (
	visionMu       sync.Mutex
	textOnlyModels = map[VisionKey]bool{}
)

// IsTextOnly reports whether k has already been found unable to accept
// images, so the caller can skip a request it knows will fail.
func IsTextOnly(k VisionKey) bool {
	visionMu.Lock()
	defer visionMu.Unlock()
	return textOnlyModels[k]
}

// MarkTextOnly records k as unable to accept images. Callers must call
// this ONLY for llm.ErrNoVision — never for a timeout, a rate limit, or
// an auth failure, or one flaky moment permanently downgrades the user.
func MarkTextOnly(k VisionKey) {
	visionMu.Lock()
	textOnlyModels[k] = true
	visionMu.Unlock()
}

// ExtractImage is Extract's image counterpart: it asks the provider for
// keywords describing a screenshot instead of window text, and returns
// the identical ExtractResult shape.
//
// The two paths differ ONLY in how the model is asked. Everything from
// the model's response onward — sanitizing, dedupe, the cap, the drop
// report — is the single shared implementation in extractResult, so the
// image path cannot drift from the text path.
//
// Returns a zero ExtractResult for an empty image without calling the
// provider. Returns an error wrapping llm.ErrNoVision when the model
// cannot accept images at all — either because the provider does not
// implement llm.VisionCleaner, or because it rejected the request as
// such.
func ExtractImage(ctx context.Context, cleaner llm.Cleaner, img llm.Image, dictTerms []string) (ExtractResult, error) {
	if len(img.Data) == 0 {
		return ExtractResult{}, nil
	}
	if len(img.Data) > MaxImageBytes {
		// An ordinary error, NOT ErrNoVision: an oversized capture is
		// our bug, and caching it as a model capability would disable
		// vision for a model that is perfectly capable.
		return ExtractResult{}, fmt.Errorf("screenctx: image is %d bytes, over the %d-byte limit", len(img.Data), MaxImageBytes)
	}
	// Capability discovery by type assertion, per llm.VisionCleaner's
	// doc comment — never by asking a registry which providers are
	// "vision providers".
	vc, ok := cleaner.(llm.VisionCleaner)
	if !ok {
		return ExtractResult{}, fmt.Errorf("screenctx: %w: provider %T has no image path", llm.ErrNoVision, cleaner)
	}
	// Tagged exactly as Extract tags its call — see
	// llm.WithScreenContextSource.
	raw, err := vc.CleanImage(llm.WithScreenContextSource(ctx), img, dictTerms)
	if err != nil {
		return ExtractResult{}, err
	}
	return extractResult(raw), nil
}

// NewImageExtractor is NewExtractor's counterpart for the image path:
// same provider, same model, same credentials, same timeout policy —
// only the prompt template differs. Returns an llm.Cleaner rather than
// an llm.VisionCleaner because whether the configured provider supports
// images is precisely what the caller discovers by asserting on the
// result.
func NewImageExtractor(cfg config.Config) (llm.Cleaner, error) {
	return newExtractor(cfg, ExtractImagePrompt, ExtractImageTimeout)
}
