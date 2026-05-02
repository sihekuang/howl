package pipeline

import "testing"

func TestEventKindString(t *testing.T) {
	cases := map[EventKind]string{
		EventStageProcessed:   "stage_processed",
		EventChunkEmitted:     "chunk_emitted",
		EventChunkTranscribed: "chunk_transcribed",
		EventLLMDelta:         "llm_delta",
		EventLLMFirstToken:    "llm_first_token",
	}
	for k, want := range cases {
		if got := k.String(); got != want {
			t.Errorf("EventKind(%d).String()=%q, want %q", k, got, want)
		}
	}
}
