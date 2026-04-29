package llm

import (
	"fmt"
	"strings"
)

const cleanupPrompt = `You are a transcription editor. Clean up the following voice transcription:
- Remove filler words (um, uh, like, you know, basically)
- Fix grammar and punctuation
- Preserve technical terms exactly as listed: %s
- Keep meaning intact, do not add new content
- Return only the cleaned text, nothing else

Raw transcription: %s`

// renderPrompt produces the user message sent to the LLM.
func renderPrompt(raw string, preserveTerms []string) string {
	terms := "(none)"
	if len(preserveTerms) > 0 {
		terms = strings.Join(preserveTerms, ", ")
	}
	return fmt.Sprintf(cleanupPrompt, terms, raw)
}
