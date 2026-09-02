package llm

import (
	"context"
	"errors"
	"fmt"
	"net/http"
	"strings"
)

// Image is one image handed to a VisionCleaner. Data is the raw encoded
// image (PNG/JPEG/GIF/WebP) — NOT base64. Each provider applies
// whatever encoding its own wire format wants: Anthropic and Ollama
// want bare base64, OpenAI wants a `data:` URL. Keeping the interface
// in raw bytes means the caller never has to know which.
type Image struct {
	// Data is the encoded image, exactly as it will be re-encoded for
	// the provider.
	Data []byte
	// MediaType is the IANA type of Data — one of ImageMediaTypes.
	MediaType string
}

// VisionCleaner is an optional extension for providers whose model can
// accept an image alongside the prompt, and is the sibling of
// StreamingCleaner: the same discovery mechanism (type assertion on a
// Cleaner, never a registry lookup), for a different capability.
//
// "The provider implements this interface" is a statement about the
// PROVIDER's wire protocol, not about the configured MODEL. Ollama and
// LM Studio serve arbitrary user-pulled models, and a text-only one
// behind a vision-capable provider is rejected at request time, not at
// construction time — see ErrNoVision.
type VisionCleaner interface {
	Cleaner
	// CleanImage asks the model to answer the configured prompt about
	// img. preserveTerms fills the prompt's {{dictionary}} placeholder,
	// exactly as in Clean. Returns ErrNoVision (wrapped) when the
	// provider rejected the request specifically because the model
	// cannot accept images.
	CleanImage(ctx context.Context, img Image, preserveTerms []string) (string, error)
}

// ErrNoVision reports that the request was rejected because the model
// cannot accept image input. Callers detect it with errors.Is and may
// cache the verdict for the (provider, model) pair; every OTHER failure
// must be treated as transient, because caching a network blip as "this
// model has no vision" permanently downgrades the user until they
// change a setting.
var ErrNoVision = errors.New("model does not accept image input")

// ImageMediaTypes is the set of media types every supported provider
// accepts. Anthropic's Base64ImageSourceMediaType enum is the binding
// constraint — it is exactly these four — and the OpenAI/Ollama
// surfaces are supersets, so validating once here is enough.
var ImageMediaTypes = map[string]bool{
	"image/png":  true,
	"image/jpeg": true,
	"image/gif":  true,
	"image/webp": true,
}

// validateImage checks img before it costs a round trip. provider names
// the caller so the error reads like every other error in that file.
//
// Deliberately NOT an ErrNoVision: a malformed or unsupported image is
// our bug or a bad capture, and caching it as a model capability would
// permanently disable vision for a model that is perfectly capable.
func validateImage(provider string, img Image) error {
	if len(img.Data) == 0 {
		return fmt.Errorf("%s: empty image", provider)
	}
	if !ImageMediaTypes[img.MediaType] {
		return fmt.Errorf("%s: unsupported image media type %q", provider, img.MediaType)
	}
	return nil
}

// DetectImageMediaType sniffs the media type of an encoded image from
// its magic bytes and returns it only if it is one every provider
// accepts. Sniffing rather than trusting a caller-supplied label means
// the C ABI carries bytes and a length and nothing else — a host that
// switches PNG→JPEG cannot get out of sync with Go.
func DetectImageMediaType(data []byte) (string, error) {
	if len(data) == 0 {
		return "", errors.New("llm: empty image")
	}
	// http.DetectContentType implements the WHATWG sniffing algorithm
	// and reads at most the first 512 bytes. It returns
	// "application/octet-stream" for anything it can't place.
	mt := http.DetectContentType(data)
	// It can append parameters (e.g. "text/plain; charset=utf-8");
	// none of the image types carry one today, but strip defensively.
	if i := strings.IndexByte(mt, ';'); i >= 0 {
		mt = strings.TrimSpace(mt[:i])
	}
	if !ImageMediaTypes[mt] {
		return "", fmt.Errorf("llm: unsupported or unrecognised image type %q", mt)
	}
	return mt, nil
}

// RenderImagePrompt produces the user message sent alongside an image.
// Unlike RenderPrompt there is no transcription to substitute — the
// image IS the input — so only {{dictionary}} is filled in and the
// "Raw transcription:" trailer RenderPrompt appends for a missing
// placeholder is never added. Appending it would instruct the model to
// read text that isn't there.
func RenderImagePrompt(promptTemplate string, preserveTerms []string) string {
	terms := "(none)"
	if len(preserveTerms) > 0 {
		terms = strings.Join(preserveTerms, ", ")
	}
	if strings.Contains(promptTemplate, PlaceholderDictionary) {
		return strings.Replace(promptTemplate, PlaceholderDictionary, terms, 1)
	}
	return promptTemplate + "\n\nThese terms are already covered: " + terms
}

// noVisionStatuses are the HTTP statuses a provider uses to say "your
// request is not something this model can process". Deliberately narrow.
//
// Excluded, and why each exclusion matters: 401/403 (a wrong or expired
// key the user will fix), 404 (a model name typo — the message never
// mentions images, but keeping the status out is a second line of
// defence), 408/429 (transient load), and every 5xx including
// Anthropic's 529 overloaded (the provider's problem, not the model's).
// Caching any of these as "no vision" would downgrade the user
// permanently over one flaky moment.
var noVisionStatuses = map[int]bool{
	http.StatusBadRequest:          true, // Anthropic, OpenAI, Ollama, LM Studio all use this
	http.StatusUnprocessableEntity: true, // some OpenAI-compatible servers prefer 422
}

// imageSubjectPhrases: the message must actually be about image input.
// Substrings, lowercased — "image" covers "images", "image_url" and
// "image content blocks".
var imageSubjectPhrases = []string{"image", "vision", "multimodal", "multi-modal"}

// unsupportedPhrases: ...and must actually be saying it isn't accepted.
var unsupportedPhrases = []string{
	"not support", "unsupported", "does not accept", "cannot accept",
	"only supported by", "not capable", "no vision",
}

// isNoVisionRejection reports whether an HTTP status and a provider
// error message together mean "this model cannot accept images".
//
// Two axes, both required: a status from noVisionStatuses AND a message
// that mentions image input (imageSubjectPhrases) while saying it is
// not supported (unsupportedPhrases). Neither axis alone is safe —
// "Rate limit reached for images per minute" is 429 and mentions
// images; "max_tokens must be greater than 0" is 400 and says nothing
// about images.
//
// Known imprecision, accepted on purpose: a 400 reading "unsupported
// image media type" (a genuinely corrupt or mislabelled capture) also
// matches, and would be cached as no-vision. That is why the image is
// validated and its type sniffed before the request is ever built —
// by the time these bytes reach a provider they are a well-formed PNG,
// JPEG, GIF or WebP.
//
// Everything not matched is treated as an ordinary, retryable failure.
// When in doubt, that is always the correct side to err on: the cost is
// one wasted request per focus change, versus a permanently disabled
// feature.
func isNoVisionRejection(status int, message string) bool {
	if !noVisionStatuses[status] {
		return false
	}
	m := strings.ToLower(message)
	return containsAny(m, imageSubjectPhrases) && containsAny(m, unsupportedPhrases)
}

func containsAny(haystack string, needles []string) bool {
	for _, n := range needles {
		if strings.Contains(haystack, n) {
			return true
		}
	}
	return false
}
