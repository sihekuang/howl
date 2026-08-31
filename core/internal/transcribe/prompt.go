package transcribe

import (
	"strings"
	"unicode/utf8"
)

// MaxInitialPromptLen bounds the size (in bytes) of an initial prompt
// passed to whisper. whisper.cpp keeps only the last ~n_text_ctx/2
// prompt tokens internally, so an unbounded prompt is wasted work; we
// cap the input defensively to avoid pathological allocations and to
// keep the custom-vocabulary glossary within a sensible range. ~896
// bytes comfortably covers the useful token budget for the prompt.
const MaxInitialPromptLen = 896

// MaxScreenPromptLen is a loose byte pre-filter on the screen-derived
// portion of the prompt, applied in ContextPrompt (whose only
// production caller is WhisperCpp.SetContextPrompt; no howl-cli
// consumer exists). The authoritative bound is MaxScreenPromptTokens,
// enforced afterward in WhisperCpp.SetContextPrompt itself.
const MaxScreenPromptLen = 384

// MaxScreenPromptTokens caps the screen-derived portion of whisper's
// 224-token prompt window, leaving the majority for the custom
// dictionary. Deliberately conservative: an oversized initial_prompt is
// a documented cause of hallucinated words in the transcript.
const MaxScreenPromptTokens = 96

// boundInitialPrompt trims surrounding whitespace and truncates the
// prompt to at most MaxInitialPromptLen bytes on a UTF-8 rune boundary
// (so a multibyte rune is never split). An empty or whitespace-only
// prompt yields "", signalling "no initial prompt".
func boundInitialPrompt(prompt string) string {
	prompt = strings.TrimSpace(prompt)
	if len(prompt) <= MaxInitialPromptLen {
		return prompt
	}
	// Back off to the nearest rune boundary at or below the limit so we
	// don't slice through the middle of a multibyte rune.
	cut := MaxInitialPromptLen
	for cut > 0 && !utf8.RuneStart(prompt[cut]) {
		cut--
	}
	return strings.TrimSpace(prompt[:cut])
}

// cleanTerms trims each term and drops empty entries, preserving order.
func cleanTerms(terms []string) []string {
	out := make([]string, 0, len(terms))
	for _, t := range terms {
		if t = strings.TrimSpace(t); t != "" {
			out = append(out, t)
		}
	}
	return out
}

// boundTermsByBytes keeps terms from the front of `terms` whose
// comma-joined byte length (including ", " separators) fits within
// maxBytes, dropping the tail once it would not. A cheap byte-length
// pre-filter over a term LIST — distinct from (and coarser than) a
// token-count bound, and distinct from boundInitialPrompt (which
// operates on an already-joined string and can truncate mid-term,
// which is fine for free text but would corrupt a comma-separated
// term list). Existing callers needing the authoritative token bound
// still apply it afterward; this exists to make that check cheap by
// bounding how many terms it ever has to consider. Mirrors the
// accumulation loop ContextPrompt already uses for its screen-term
// byte cap.
func boundTermsByBytes(terms []string, maxBytes int) []string {
	kept := make([]string, 0, len(terms))
	used := 0
	for _, t := range terms {
		add := len(t)
		if len(kept) > 0 {
			add += 2 // ", " separator
		}
		if used+add > maxBytes {
			break
		}
		used += add
		kept = append(kept, t)
	}
	return kept
}

// DictionaryPrompt builds a whisper initial prompt from a list of custom
// vocabulary terms (names, jargon, acronyms). The terms are joined into
// a comma-separated glossary that biases whisper toward the spellings
// the user cares about. Empty/whitespace terms are skipped; an empty
// list yields "" (no prompt). The result is bounded to
// MaxInitialPromptLen.
func DictionaryPrompt(terms []string) string {
	cleaned := cleanTerms(terms)
	if len(cleaned) == 0 {
		return ""
	}
	return boundInitialPrompt(strings.Join(cleaned, ", "))
}

// ContextPrompt composes a whisper initial prompt from the user's custom
// dictionary and keywords derived from the focused window.
//
// Dictionary terms are emitted first and screen terms second, because
// every truncation path in this package drops from the tail — so an
// oversized prompt sacrifices screen keywords and never the dictionary
// the user explicitly configured.
//
// Screen terms are deduped case-insensitively against the dictionary
// (and against each other) and bounded to MaxScreenPromptLen; the whole
// result is bounded to MaxInitialPromptLen. Both are byte bounds, and
// deliberately loose — a cheap pre-filter, not the authoritative one.
//
// The returned PROMPT STRING is not what governs what whisper actually
// sees, and not what production uses: WhisperCpp.SetContextPrompt, the
// only production caller, discards it outright
// (`_, screen := ContextPrompt(...)`) and re-trims the returned screen
// SLICE against whisper's real token window (MaxScreenPromptTokens,
// then MaxPromptTokens) — that token-based pass is what actually
// governs the prompt whisper sees and what ends up in the session
// manifest. This function's tests exercise the string return directly
// (its normal Go contract), but no caller does.
func ContextPrompt(dictTerms, screenTerms []string) (string, []string) {
	dict := cleanTerms(dictTerms)
	screen := cleanTerms(screenTerms)

	seen := make(map[string]struct{}, len(dict)+len(screen))
	for _, t := range dict {
		seen[strings.ToLower(t)] = struct{}{}
	}

	// Screen terms: dedupe, then fill up to the screen sub-cap.
	kept := make([]string, 0, len(screen))
	used := 0
	for _, t := range screen {
		key := strings.ToLower(t)
		if _, dup := seen[key]; dup {
			continue
		}
		add := len(t)
		if len(kept) > 0 {
			add += 2 // ", " separator
		}
		if used+add > MaxScreenPromptLen {
			break
		}
		seen[key] = struct{}{}
		used += add
		kept = append(kept, t)
	}

	all := make([]string, 0, len(dict)+len(kept))
	all = append(all, dict...)
	all = append(all, kept...)
	if len(all) == 0 {
		return "", nil
	}

	prompt := boundInitialPrompt(strings.Join(all, ", "))

	// Re-derive which screen terms survived the overall byte bound by
	// walking the same join the bound was applied to.
	surviving := make([]string, 0, len(kept))
	running := 0
	for i, t := range all {
		add := len(t)
		if i > 0 {
			add += 2
		}
		if running+add > len(prompt) {
			break
		}
		running += add
		if i >= len(dict) {
			surviving = append(surviving, t)
		}
	}
	return prompt, surviving
}

// Prompt-drop stages. Every one names a specific filter in the
// composition, in the order the composition applies them. Together they
// account for every term that is offered to a context prompt but does
// not reach whisper.
const (
	// DropEmptyTerm: blank once trimmed (cleanTerms).
	DropEmptyTerm = "empty"
	// DropDuplicateOfDictionary: a screen term the user's custom
	// dictionary already covers, deduped case-insensitively by
	// ContextPrompt.
	DropDuplicateOfDictionary = "duplicate_of_dictionary"
	// DropDuplicate: a screen term repeating an earlier screen term,
	// case-insensitively.
	DropDuplicate = "duplicate"
	// DropBytePreFilter: a screen term cut by ContextPrompt's byte
	// pre-filters (MaxScreenPromptLen on the screen slice, then
	// MaxInitialPromptLen on the whole join). Coarse and deliberately
	// loose — the token stages below are the authoritative bound.
	DropBytePreFilter = "byte_prefilter"
	// DropDictByteCap: a dictionary term cut by boundTermsByBytes at
	// MaxInitialPromptLen, the pre-filter that keeps the stage-2 token
	// loop from going quadratic on a large custom dictionary.
	DropDictByteCap = "dict_byte_cap"
	// DropScreenTokenCap: a screen term cut by stage 1, the real
	// token-count bound on the screen slice alone
	// (MaxScreenPromptTokens).
	DropScreenTokenCap = "screen_token_cap"
	// DropPromptTokenCap: a term cut by stage 2, the real token-count
	// bound on the whole prompt (MaxPromptTokens). Drops from the tail,
	// so screen terms go before any dictionary term is touched.
	DropPromptTokenCap = "prompt_token_cap"
)

// Prompt-drop sources.
const (
	SourceDictionary = "dictionary"
	SourceScreen     = "screen"
)

// PromptDrop is one term that was offered to a context prompt and did
// not reach whisper, tagged with where it came from and which filter
// removed it.
type PromptDrop struct {
	Term   string `json:"term"`
	Source string `json:"source"` // SourceDictionary | SourceScreen
	Stage  string `json:"stage"`  // one of the Drop* constants above
}

// ContextPromptPlan is the complete record of one context-prompt
// composition: what was offered, what survived each filter, what
// whisper actually receives, and the caps that governed it.
//
// It is produced by exactly one function
// (WhisperCpp.composeContextPrompt), which both the mutating
// SetContextPrompt and the read-only preview go through. That is
// deliberate: a preview computed by a parallel code path would drift
// from the prompt whisper really gets and would mislead exactly when
// someone is using it to debug recognition.
type ContextPromptPlan struct {
	// Dictionary and ScreenKeywords are the inputs as offered, before
	// any trimming.
	Dictionary     []string `json:"dictionary"`
	ScreenKeywords []string `json:"screen_keywords"`

	// DictBounded is the dictionary after blank-stripping and the
	// MaxInitialPromptLen byte pre-filter — what entered the stage-2
	// token loop.
	DictBounded []string `json:"dictionary_bounded"`

	// DictApplied and ScreenApplied are the terms that actually reach
	// whisper, in prompt order (dictionary first, screen second).
	// ScreenApplied is exactly SetContextPrompt's return value.
	DictApplied   []string `json:"dictionary_applied"`
	ScreenApplied []string `json:"screen_applied"`

	// Dropped lists every term that did not make it, in the order the
	// stages ran: screen pre-filter, then screen token cap, then
	// dictionary byte cap, then the whole-prompt token cap.
	Dropped []PromptDrop `json:"dropped"`

	// Prompt is the exact string assigned to whisper's initial_prompt,
	// and TokenCount is its length measured by whisper_token_count
	// against the loaded model — not an estimate.
	Prompt     string `json:"prompt"`
	TokenCount int    `json:"token_count"`

	// The two caps that governed this composition, echoed so a consumer
	// can render "N of M tokens" without hardcoding them.
	MaxScreenPromptTokens int `json:"max_screen_prompt_tokens"`
	MaxPromptTokens       int `json:"max_prompt_tokens"`
}

// NonNil returns a copy of the plan with every nil slice replaced by an
// empty one, so JSON encoding always yields arrays rather than nulls.
// Go callers should use the plan as-is (nil is meaningful there — it is
// what SetContextPrompt returns when no screen term survived); this
// exists for the C-ABI boundary, where a consumer decoding `[]` is
// simpler than one decoding `null`.
func (p ContextPromptPlan) NonNil() ContextPromptPlan {
	if p.Dictionary == nil {
		p.Dictionary = []string{}
	}
	if p.ScreenKeywords == nil {
		p.ScreenKeywords = []string{}
	}
	if p.DictBounded == nil {
		p.DictBounded = []string{}
	}
	if p.DictApplied == nil {
		p.DictApplied = []string{}
	}
	if p.ScreenApplied == nil {
		p.ScreenApplied = []string{}
	}
	if p.Dropped == nil {
		p.Dropped = []PromptDrop{}
	}
	return p
}

// blankTermDrops reports the entries of terms that cleanTerms discards
// for being blank once trimmed.
func blankTermDrops(terms []string, source string) []PromptDrop {
	var drops []PromptDrop
	for _, t := range terms {
		if strings.TrimSpace(t) == "" {
			drops = append(drops, PromptDrop{Term: t, Source: source, Stage: DropEmptyTerm})
		}
	}
	return drops
}

// screenPreFilterDrops explains which of screenTerms ContextPrompt
// discarded, given the slice it kept. It classifies rather than
// re-implements: `kept` is ContextPrompt's own output and is always an
// order-preserving subsequence of the non-blank screenTerms, so a
// single walk identifies the drops, and each one is labelled by
// checking the two conditions ContextPrompt can reject on (already
// covered by the dictionary, or a repeat of an earlier screen term) —
// anything else was cut by a byte cap.
func screenPreFilterDrops(dictTerms, screenTerms, kept []string) []PromptDrop {
	dictSeen := make(map[string]struct{}, len(dictTerms))
	for _, t := range dictTerms {
		if t = strings.TrimSpace(t); t != "" {
			dictSeen[strings.ToLower(t)] = struct{}{}
		}
	}

	var drops []PromptDrop
	screenSeen := make(map[string]struct{}, len(screenTerms))
	k := 0
	for _, raw := range screenTerms {
		t := strings.TrimSpace(raw)
		if t == "" {
			drops = append(drops, PromptDrop{Term: raw, Source: SourceScreen, Stage: DropEmptyTerm})
			continue
		}
		if k < len(kept) && kept[k] == t {
			k++
			screenSeen[strings.ToLower(t)] = struct{}{}
			continue
		}
		key := strings.ToLower(t)
		stage := DropBytePreFilter
		if _, dup := dictSeen[key]; dup {
			stage = DropDuplicateOfDictionary
		} else if _, dup := screenSeen[key]; dup {
			stage = DropDuplicate
		}
		drops = append(drops, PromptDrop{Term: t, Source: SourceScreen, Stage: stage})
	}
	return drops
}
