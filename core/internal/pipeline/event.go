package pipeline

// EventKind identifies which event a Listener received. Per-kind fields
// on Event are populated only for the relevant kind; the rest are zero.
type EventKind int

const (
	// EventStageProcessed fires after each Stage.Process call. Stage holds
	// the stage Name(); RMSIn/RMSOut are computed by the framework over
	// the input and output of that call.
	EventStageProcessed EventKind = iota

	// EventChunkEmitted fires when the Chunker emits a chunk. ChunkIdx
	// is 1-based, DurationMs is the chunk's audio length, Reason is the
	// chunker's emission reason — see ChunkReason constants in chunker.go
	// ("vad-cut" / "force-cut" / "tail").
	EventChunkEmitted

	// EventChunkTranscribed fires after each chunk's Transcribe call
	// returns. ChunkIdx is 1-based, ElapsedMs is wall time spent in
	// transcription for that chunk, Text is the chunk's transcribed text.
	EventChunkTranscribed

	// EventLLMDelta fires for each streamed LLM cleaned-text delta.
	// Text is the delta (not cumulative).
	EventLLMDelta

	// EventLLMFirstToken fires when the first LLM delta arrives. ElapsedMs
	// is the wall time from "transcription complete" to "first token".
	EventLLMFirstToken
)

func (k EventKind) String() string {
	switch k {
	case EventStageProcessed:
		return "stage_processed"
	case EventChunkEmitted:
		return "chunk_emitted"
	case EventChunkTranscribed:
		return "chunk_transcribed"
	case EventLLMDelta:
		return "llm_delta"
	case EventLLMFirstToken:
		return "llm_first_token"
	}
	return "unknown"
}

// Event is the one-shape payload delivered to a Listener.
//
// Field population by Kind:
//
//	EventStageProcessed   — Stage, RMSIn, RMSOut
//	EventChunkEmitted     — ChunkIdx, DurationMs, Reason
//	EventChunkTranscribed — ChunkIdx, ElapsedMs, Text
//	EventLLMDelta         — Text
//	EventLLMFirstToken    — ElapsedMs
type Event struct {
	Kind EventKind

	Stage  string
	RMSIn  float32
	RMSOut float32

	ChunkIdx   int
	DurationMs int
	Reason     string
	ElapsedMs  int
	Text       string

	// TSESimilarity, when non-nil, is the cosine similarity the TSE
	// chunk stage computed for this chunk. Populated only on
	// EventStageProcessed events for the "tse" stage.
	TSESimilarity *float32
}

// Listener observes pipeline events. Callbacks may fire concurrently
// from multiple goroutines (foreground frame loop and chunk worker);
// implementations must be safe under concurrent invocation. Best-effort:
// a slow Listener delays the pipeline.
type Listener func(Event)
