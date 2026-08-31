package screenctx

import (
	"context"
	"fmt"
	"regexp"
	"strings"
	"sync"
	"time"

	"github.com/voice-keyboard/core/internal/config"
	"github.com/voice-keyboard/core/internal/llm"
)

const (
	// ExtractImageTimeout bounds the vision provider call. Far longer
	// than ExtractTimeout because a vision request is a different
	// animal: it uploads a downscaled screenshot rather than a few KB of
	// text, and a local vision model (Ollama/LM Studio) JIT-loads a
	// projector on top of the language model on the first request after
	// idle.
	//
	// Measured end-to-end through this exact path, not guessed:
	// LM Studio qwen2.5-vl-7b ran 1.5-24s; Ollama qwen3-vl:8b ran
	// 45-162s. The 12s this used to be was below even the working
	// configuration's worst case, so a local-vision user's every
	// extraction timed out and the feature produced nothing.
	//
	// 90s is deliberately generous, because the cost is lopsided. Too
	// short silently kills the feature for local-vision users and looks
	// exactly like "no keywords found". Too long costs at most ONE hung
	// HTTP call: extraction runs off the dictation path entirely, and
	// the coordinator cancels the previous in-flight task on every new
	// refresh, so requests cannot pile up. Late keywords are also not
	// wasted — the generation counter drops them if the user has moved
	// on, and they still bias the next dictation if the user has not.
	ExtractImageTimeout = 90 * time.Second

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
//
// The marker instruction is concatenated from VisionCanary rather than
// spelled out, so the prompt and the stripper can never disagree about
// what the marker is. It is called a "marker" and never a "token" —
// the skip-secrets rule below already uses "token", and a model told to
// skip tokens may well skip the marker too.
const ExtractImagePrompt = `You extract vocabulary hints for a speech-recognition system. The attached image is a screenshot of the user's focused window. The user is about to dictate while looking at it.

Read the screenshot and list the words and phrases a speech recogniser is most likely to get wrong: proper nouns, people's names, product and project names, code identifiers, acronyms, filenames, and domain jargon. Use the layout to judge what matters — a filename in a tab bar, a symbol in code, a heading — not just any text that happens to be visible.

Hard rules:
- Begin your reply with the exact marker ` + VisionCanary + ` followed by a comma — but ONLY if an image is actually attached and you can see it. If no image is visible to you, omit the marker and say so instead.
- After the marker, return ONLY a comma-separated list. No preamble, no numbering, no explanation.
- At most 20 items, most useful first.
- Every item must appear verbatim on the screen. Do not invent, translate, correct, or describe the image.
- Skip ordinary English words a recogniser already handles.
- Skip anything resembling a secret, password, API key, or token.
- These terms are already covered — do NOT repeat them: {{dictionary}}
- If nothing qualifies, the list is an empty string: return the marker and nothing else.`

// VisionCanary is a sentinel the model is instructed to emit first, and
// ONLY if it can actually see the attached image.
//
// It exists because "the provider accepted the request" does not mean
// "the model looked at the image". Some Ollama versions accept an
// `images` array on a text-only model and silently DISCARD it, and any
// OpenAI-compatible server is free to do the same. The model then sees
// only a prompt asking it to read a screenshot, with no screenshot, and
// answers from the instructions alone — a refusal, a hallucination, or
// generic filler like "screenshot, window, dictation". Sanitize keeps
// whatever of that is term-shaped, and those invented terms go on to
// bias whisper's initial_prompt. The user gets silently worse dictation,
// no_vision stays false so we never fall back, and the AX text path that
// would have worked is never tried. That is strictly worse than a clean
// failure, and it persists until they change models.
//
// The marker turns that silent corruption into a detectable one. It
// catches ANY backend that drops the image, not just the Ollama
// versions that prompted it, and costs one token per call.
//
// THE FAILURE DIRECTION IS DELIBERATE. A vision-capable model that
// simply ignores the instruction and omits the marker is falsely marked
// text-only, and we fall back to AX text: degraded but correct. The
// opposite default — assume vision worked unless proven otherwise —
// silently feeds whisper terms the model invented. Do not "fix" this by
// defaulting the other way; being wrong towards the text path is the
// point.
//
// The hex suffix is not decoration: it makes accidental occurrence in
// real screen text or in a model's spontaneous output effectively
// impossible. Do not tidy it away.
const VisionCanary = "HOWL-VISION-OK-7F3A"

// canaryPattern matches the marker case-insensitively along with the
// separator debris models wrap it in — a leading newline or bullet, a
// trailing comma, period, or colon. Models are sloppy about exact
// formatting, so detection is deliberately tolerant; what must be exact
// is that nothing resembling the marker survives into the keyword list.
var canaryPattern = regexp.MustCompile(
	`(?i)[\s,;]*(?:[-*\x{2022}]\s*)?` + regexp.QuoteMeta(VisionCanary) + `[\s.,;:!]*`,
)

// stripVisionCanary removes every occurrence of the marker and reports
// whether there was at least one.
//
// Occurrences are replaced with a comma rather than deleted so a marker
// a model puts mid-list cannot fuse its neighbours into one bogus term.
// Every occurrence is stripped, not just the first: the instruction says
// to emit it once, and a model that repeats it must not have the repeat
// treated as a keyword.
func stripVisionCanary(raw string) (string, bool) {
	if !canaryPattern.MatchString(raw) {
		return raw, false
	}
	out := canaryPattern.ReplaceAllString(raw, ", ")
	return strings.Trim(out, " \t\r\n,;.:"), true
}

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
// did not read the image — because the provider does not implement
// llm.VisionCleaner, because it rejected the request as such, or
// because the response carried no VisionCanary and so cannot be trusted
// to describe anything that was on screen.
//
// Raw on the returned result is the response with the marker removed;
// see VisionCanary.
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
	// The marker is the proof the model actually saw the image. Absent
	// it, the response is invented from the prompt alone and must never
	// reach whisper — see VisionCanary for why this is reported as a
	// capability verdict and why erring towards the text path is
	// deliberate.
	stripped, sawImage := stripVisionCanary(raw)
	if !sawImage {
		return ExtractResult{}, fmt.Errorf(
			"screenctx: %w: response carried no vision marker, so the image was not read",
			llm.ErrNoVision)
	}
	// Strip before extractResult, so the marker is a candidate for
	// neither Keywords nor Dropped, and out of Raw too: Raw is the
	// diagnostic "what did the model actually say", and the marker is
	// protocol, not something the model saw on screen. That also keeps
	// the image path byte-identical to the text path for the same
	// content — see TestExtractImage_ConvergesWithTextPath.
	return extractResult(stripped), nil
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
