//go:build cleanupeval

package speaker

import (
	"context"
	"encoding/binary"
	"fmt"
	"math"
	"os"
	"os/exec"
	"path/filepath"
	"testing"

	"github.com/voice-keyboard/core/internal/audio"
)

// TestDiarMask_DiagnoseRealEnrollment runs diar_mask with the REAL pyannote
// segmenter against the user's REAL enrolled voice (target) mixed with a TTS
// interferer, across MULTIPLE 10 s windows, and logs per-window diagnostics:
// what pyannote detected, which track was selected, the cosine confidence, and
// how much got masked. This reproduces the app's offline path on realistic
// (non-TTS-target) audio to explain real-world behavior.
//
// Run:
//   HOWL_VOICE_DIR="$HOME/Library/Application Support/Howl/voice" \
//   PYANNOTE_SEG_PATH=.../pyannote_seg.onnx \
//   SPEAKER_ENCODER_PATH=.../speaker_encoder.onnx \
//   go test -tags cleanupeval ./internal/speaker/ -run TestDiarMask_DiagnoseRealEnrollment -v
func TestDiarMask_DiagnoseRealEnrollment(t *testing.T) {
	voiceDir := os.Getenv("HOWL_VOICE_DIR")
	if voiceDir == "" {
		t.Skip("set HOWL_VOICE_DIR to the Howl voice profile dir (enrollment.emb + enrollment.wav)")
	}
	encoderPath := resolveModelPath(t, "SPEAKER_ENCODER_PATH", "speaker_encoder.onnx")
	segPath := resolveModelPath(t, "PYANNOTE_SEG_PATH", "pyannote_seg.onnx")
	initONNXOnce(t)

	ref, err := LoadEmbedding(filepath.Join(voiceDir, "enrollment.emb"), 192)
	if err != nil {
		t.Fatalf("LoadEmbedding(enrollment.emb): %v", err)
	}
	// enrollment.wav is 32-bit float; decode to 16 kHz mono via ffmpeg.
	userVoice := readWav16k(t, filepath.Join(voiceDir, "enrollment.wav"))
	t.Logf("enrolled voice: %.1f s of real audio", float64(len(userVoice))/synthSR)

	interf := synthVoice(t, "Samantha",
		"She sells seashells by the seashore on a bright summer afternoon as the children "+
			"build tall sandcastles and the seagulls circle high above the rolling ocean waves "+
			"while a gentle breeze carries the salty air across the sunlit shore and distant cliffs.")

	// Segment length: as large as the available audio allows, so we span >1 window.
	seg := len(userVoice) / 3
	if b := len(interf) / 2; b < seg {
		seg = b
	}
	if seg < 2*synthSR {
		seg = 2 * synthSR
	}
	total := 4 * seg

	userVoice = normTo(userVoice, 0.08)
	interf = normTo(interf, 0.08)

	a1, a2, a3 := slice(userVoice, 0, seg), slice(userVoice, seg, 2*seg), slice(userVoice, 2*seg, 3*seg)
	b1, b2 := slice(interf, 0, seg), slice(interf, seg, 2*seg)

	// timeline: user[0,seg) | user+interf[seg,2seg) | interf[2seg,3seg) | user[3seg,4seg)
	mixed := make([]float32, total)
	cleanU := make([]float32, total)
	addAt(mixed, a1, 0)
	addAt(cleanU, a1, 0)
	addAt(mixed, a2, 1*seg)
	addAt(cleanU, a2, 1*seg)
	addAt(mixed, b1, 1*seg)
	addAt(mixed, b2, 2*seg)
	addAt(mixed, a3, 3*seg)
	addAt(cleanU, a3, 3*seg)

	uOnly := [][2]int{{0, 1 * seg}, {3 * seg, 4 * seg}}
	iOnly := [][2]int{{2 * seg, 3 * seg}}

	t.Logf("mix: %.1f s total (%d window(s) of 10 s) | seg=%.1fs | timeline U | U+I | I | U",
		float64(total)/synthSR, (total+diarWindowLen-1)/diarWindowLen, float64(seg)/synthSR)

	embed := func(s []float32) ([]float32, error) { return ComputeEmbedding(encoderPath, s, 192) }
	seg2, err := NewPyannoteSegmenter(segPath)
	if err != nil {
		t.Fatalf("NewPyannoteSegmenter: %v", err)
	}
	defer seg2.Close()

	minExclusive := int(0.5 * synthSR)
	ctx := context.Background()

	// Per-window diagnostics (mirrors DiarMask.Process windowing).
	for start, w := 0, 0; start < len(mixed); start, w = start+diarWindowLen, w+1 {
		end := start + diarWindowLen
		if end > len(mixed) {
			end = len(mixed)
		}
		window := mixed[start:end]
		act, err := seg2.Segment(ctx, window)
		if err != nil {
			t.Fatalf("window %d Segment: %v", w, err)
		}
		excl := exclusiveSeconds(act)
		idx, cos, ok, err := selectTarget(act, window, embed, ref, minExclusive)
		if err != nil {
			t.Fatalf("window %d selectTarget: %v", w, err)
		}
		t.Logf("window %d [%.1f-%.1fs]: pyannote frames=%d hop=%d | exclusive speech/spk = %s | select idx=%d cos=%.3f ok=%v",
			w, float64(start)/synthSR, float64(end)/synthSR, len(act.Frames), act.FrameHopSamples,
			fmtExcl(excl), idx, cos, ok)
	}

	// Full pipeline + retention/leak.
	dm, err := NewDiarMask(DiarMaskOptions{
		Segmenter: seg2, Embed: embed, Reference: ref,
		MinSelectCosine: 0.40, MinExclusiveSeconds: 0.5, FallbackPassthrough: true, BoundaryRampMs: 15,
	})
	if err != nil {
		t.Fatalf("NewDiarMask: %v", err)
	}
	out, err := dm.Process(ctx, mixed)
	if err != nil {
		t.Fatalf("Process: %v", err)
	}

	retU := ratioRMS(out, cleanU, uOnly)
	leakI := ratioRMS(out, mixed, iOnly)
	passLeakI := ratioRMS(mixed, mixed, iOnly)
	t.Logf("RESULT (real enrolled target): retentionUser-only=%.3f  Interferer-only-leak=%.3f (passthrough=%.3f)  lastSimilarity=%.3f",
		retU, leakI, passLeakI, dm.LastSimilarity())

	if dump := os.Getenv("DIAR_SYNTH_DUMP_DIR"); dump != "" {
		_ = os.MkdirAll(dump, 0o755)
		_ = audio.WriteWAVMono(filepath.Join(dump, "diag_mixed.wav"), mixed, synthSR)
		_ = audio.WriteWAVMono(filepath.Join(dump, "diag_out.wav"), out, synthSR)
		t.Logf("dumped diag_mixed/diag_out under %s", dump)
	}
}

// readWav16k decodes any WAV (incl. 32-bit float) to 16 kHz mono float32 via ffmpeg.
func readWav16k(t *testing.T, path string) []float32 {
	t.Helper()
	ff, err := exec.LookPath("ffmpeg")
	if err != nil {
		t.Skip("ffmpeg not available — skipping")
	}
	raw := filepath.Join(t.TempDir(), "x.f32")
	if out, err := exec.Command(ff, "-nostdin", "-loglevel", "error",
		"-i", path, "-ar", "16000", "-ac", "1", "-f", "f32le", raw).CombinedOutput(); err != nil {
		t.Fatalf("ffmpeg decode %s: %v\n%s", path, err, out)
	}
	b, err := os.ReadFile(raw)
	if err != nil {
		t.Fatalf("read pcm: %v", err)
	}
	n := len(b) / 4
	s := make([]float32, n)
	for i := 0; i < n; i++ {
		s[i] = math.Float32frombits(binary.LittleEndian.Uint32(b[4*i : 4*i+4]))
	}
	return s
}

func slice(s []float32, a, b int) []float32 {
	if a > len(s) {
		a = len(s)
	}
	if b > len(s) {
		b = len(s)
	}
	return s[a:b]
}

// exclusiveSeconds returns per-local-speaker exclusive (solo) speech duration.
func exclusiveSeconds(act SpeakerActivity) [diarMaxSpeakers]float64 {
	var out [diarMaxSpeakers]float64
	for _, fr := range act.Frames {
		n, only := 0, -1
		for spk, on := range fr {
			if on {
				n++
				only = spk
			}
		}
		if n == 1 {
			out[only] += float64(act.FrameHopSamples) / synthSR
		}
	}
	return out
}

func fmtExcl(e [diarMaxSpeakers]float64) string {
	return fmt.Sprintf("[spk0=%.2fs spk1=%.2fs spk2=%.2fs]", e[0], e[1], e[2])
}
