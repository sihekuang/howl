package llm

import (
	"fmt"
	"strings"
)

// DefaultPrompt is the built-in cleanup instruction. Used when no
// custom prompt is configured.
const DefaultPrompt = `You are a transcription editor. Your job is to MINIMALLY edit the transcription below, not to rewrite it. Apply only these changes:
- Remove filler words: um, uh, er, ah, like, you know, basically, I mean, sort of, kind of (when used as fillers)
- Fix obvious grammar and punctuation
- Drop any bracketed sound/music annotations Whisper inserts: (music), (water splashing), [Applause], [Laughter], etc. — these are NOT what the speaker said
- Preserve technical terms verbatim: %s

Hard rules:
- Do NOT paraphrase or restructure sentences. Keep the speaker's exact phrasing.
- Do NOT add words, ideas, or context the speaker did not say.
- Do NOT turn fragments into complete sentences if the speaker spoke fragments.
- If the input is empty, dropped to nothing after cleanup, or only sound annotations, return an empty string.
- Return ONLY the cleaned text — no preamble, no explanation, no quotes around the output.

Raw transcription:
%s`

func renderPrompt(promptTemplate, raw string, preserveTerms []string) string {
	terms := "(none)"
	if len(preserveTerms) > 0 {
		terms = strings.Join(preserveTerms, ", ")
	}
	nVerbs := strings.Count(promptTemplate, "%s")
	switch nVerbs {
	case 0:
		return promptTemplate + "\n\nPreserve these terms verbatim: " + terms + "\n\nRaw transcription:\n" + raw
	case 1:
		return fmt.Sprintf(promptTemplate, terms) + "\n\nRaw transcription:\n" + raw
	default:
		return fmt.Sprintf(promptTemplate, terms, raw)
	}
}
