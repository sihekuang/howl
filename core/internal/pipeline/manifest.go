package pipeline

import (
	"github.com/voice-keyboard/core/internal/sessions"
)

// WriteSessionManifest writes a session.json describing this pipeline's
// recorded output to dir. Walks FrameStages + ChunkStages to produce
// the StageEntry list with sample-rate tracking; populates the TSE
// stage's similarity if exposed via LastSimilarity().
//
// Single source of truth for the manifest schema both the live engine
// (libhowl's capture goroutine) and the replay package use. Without a
// shared writer, the schemas drifted — the replay path was missing
// session.json entirely, so the Mac Compare view's right pane couldn't
// load the replay's manifest after a Run.
//
// id: the session folder name relative to the sessions store base.
// For top-level sessions this is the RFC3339 timestamp; for replay
// sessions it's "<sourceID>/replay-<presetName>" so the path is
// resolvable via the same SessionPaths.dir(for:) helper.
func (p *Pipeline) WriteSessionManifest(dir, id, preset string) error {
	const inputRate = 48000
	stages := make([]sessions.StageEntry, 0, len(p.FrameStages)+len(p.ChunkStages))
	rate := inputRate
	for _, st := range p.FrameStages {
		r := rate
		if out := st.OutputRate(); out != 0 {
			r = out
		}
		stages = append(stages, sessions.StageEntry{
			Name:   st.Name(),
			Kind:   "frame",
			WavRel: st.Name() + ".wav",
			RateHz: r,
		})
		if out := st.OutputRate(); out != 0 {
			rate = out
		}
	}
	for _, st := range p.ChunkStages {
		r := rate
		if out := st.OutputRate(); out != 0 {
			r = out
		}
		entry := sessions.StageEntry{
			Name:   st.Name(),
			Kind:   "chunk",
			WavRel: st.Name() + ".wav",
			RateHz: r,
		}
		if st.Name() == "tse" {
			if g, ok := st.(interface{ LastSimilarity() float32 }); ok {
				sim := g.LastSimilarity()
				entry.TSESimilarity = &sim
			}
		}
		stages = append(stages, entry)
		if out := st.OutputRate(); out != 0 {
			rate = out
		}
	}

	m := sessions.Manifest{
		Version: sessions.CurrentManifestVersion,
		ID:      id,
		Preset:  preset,
		Stages:  stages,
		Transcripts: sessions.TranscriptEntries{
			Raw: "raw.txt", Dict: "dict.txt", Cleaned: "cleaned.txt",
		},
	}
	return m.Write(dir)
}
