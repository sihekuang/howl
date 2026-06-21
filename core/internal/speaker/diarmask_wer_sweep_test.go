//go:build cleanupeval && whispercpp

package speaker

import (
	"context"
	"encoding/json"
	"fmt"
	"math"
	"os"
	"path/filepath"
	"strings"
	"testing"

	"github.com/voice-keyboard/core/internal/transcribe"
)

// TestDiarMask_WERSweep quantifies the OG (TSE) flow vs the diarization
// (diar_mask) flow by WORD ERROR RATE — the metric that actually decides a
// dictation cleanup — across an SNR sweep and multi-voice conditions on
// synthesized speech.
//
// The reference is always the target's known sentence. Each candidate's output
// is transcribed with whisper.cpp (the production ASR) and scored with the
// existing computeWER. diar_mask runs on an ORACLE segmenter (ground-truth
// timeline), so its numbers are an upper bound, not a realistic diarizer.
//
// Honest by construction: diar_mask's selectTarget needs EXCLUSIVE (non-
// overlapping) frames per track, so on FULL-OVERLAP conditions it degenerates
// to passthrough (it cannot separate concurrent speech — only TSE can). The
// sweep includes those conditions so the comparison is not stacked.
//
// Run: go test -tags 'cleanupeval whispercpp' ./internal/speaker/ \
//        -run TestDiarMask_WERSweep -v   (set WHISPER_MODEL_PATH if needed)
func TestDiarMask_WERSweep(t *testing.T) {
	encoderPath := resolveModelPath(t, "SPEAKER_ENCODER_PATH", "speaker_encoder.onnx")
	tsePath := resolveModelPath(t, "TSE_MODEL_PATH", "tse_model.onnx")
	whisperPath := resolveModelPath(t, "WHISPER_MODEL_PATH", "ggml-small.en.bin")
	initONNXOnce(t)

	transcriber, err := transcribe.NewWhisperCpp(transcribe.WhisperOptions{ModelPath: whisperPath, Language: "en"})
	if err != nil {
		t.Fatalf("whisper: %v", err)
	}
	defer transcriber.Close()

	const targetText = "The quick brown fox jumps over the lazy dog."
	tgt := normTo(synthVoice(t, "Daniel", targetText), 0.08)
	i1 := normTo(synthVoice(t, "Samantha", "She sells seashells down by the rolling seashore."), 0.08)
	i2 := normTo(synthVoice(t, "Karen", "Mister wolf, please tell me what is the time today."), 0.08)
	Lt := len(tgt)

	refA, err := ComputeEmbedding(encoderPath, tgt, 192)
	if err != nil {
		t.Fatalf("embed target: %v", err)
	}
	embed := func(s []float32) ([]float32, error) { return ComputeEmbedding(encoderPath, s, 192) }

	// scaleTo returns clip at the RMS implied by an SNR (dB) relative to the
	// 0.08 target level: positive dB = interferer quieter than target.
	scaleTo := func(clip []float32, snrDB float64) []float32 {
		return normTo(clip, float32(0.08*math.Pow(10, -snrDB/20)))
	}

	type cond struct {
		label string
		mixed []float32
		spk   [][][2]int // oracle per-speaker intervals; nil for clean (single speaker)
	}
	conds := []cond{}

	// 1. clean — target only.
	{
		m := make([]float32, Lt)
		addAt(m, tgt, 0)
		conds = append(conds, cond{"clean (target only)", m, [][][2]int{{{0, Lt}}}})
	}
	// 2-4. full overlap, SNR sweep (target+interferer concurrent throughout).
	for _, snr := range []float64{6, 0, -6} {
		m := make([]float32, Lt)
		addAt(m, tgt, 0)
		in := scaleTo(i1, snr)
		if len(in) > Lt {
			in = in[:Lt]
		}
		addAt(m, in, 0)
		conds = append(conds, cond{fmt.Sprintf("overlap v+v %+ddB", int(snr)), m,
			[][][2]int{{{0, Lt}}, {{0, Lt}}}}) // both active everywhere → no exclusive frames
	}
	// 5-6. intermittent: target, then interferer-only tail. SNR on the tail.
	for _, snr := range []float64{0, -6} {
		tail := 2 * synthSR
		in := scaleTo(i1, snr)
		if len(in) > tail {
			in = in[:tail]
		}
		n := Lt + tail
		m := make([]float32, n)
		addAt(m, tgt, 0)
		addAt(m, in, Lt)
		conds = append(conds, cond{fmt.Sprintf("intermittent v+v %+ddB", int(snr)), m,
			[][][2]int{{{0, Lt}}, {{Lt, Lt + tail}}}})
	}
	// 7. multi-voice intermittent: target, then two interferers babbling in the tail.
	{
		tail := 2 * synthSR
		n := Lt + tail
		m := make([]float32, n)
		addAt(m, tgt, 0)
		a := scaleTo(i1, 0)
		if len(a) > tail {
			a = a[:tail]
		}
		b := scaleTo(i2, 0)
		if len(b) > tail {
			b = b[:tail]
		}
		addAt(m, a, Lt)
		addAt(m, b, Lt+synthSR) // i2 offset 1s so i1 has ≥0.5s exclusive frames (selectTarget needs ≥2 tracks)
		conds = append(conds, cond{"intermittent 3-voice 0dB", m,
			[][][2]int{{{0, Lt}}, {{Lt, Lt + tail}}, {{Lt + synthSR, Lt + tail}}}})
	}

	ctx := context.Background()
	werOf := func(out []float32) (float64, string) {
		hyp, err := transcriber.Transcribe(ctx, out)
		if err != nil {
			t.Fatalf("transcribe: %v", err)
		}
		return computeWER(targetText, hyp) * 100, hyp
	}
	// removedPct: how much of the passthrough energy diar_mask zeroed (0 ⇒ it
	// did not mask anything; high ⇒ it dropped non-target regions).
	removedPct := func(diar, pass []float32) float64 {
		var ed, ep float64
		for i := range pass {
			ep += float64(pass[i]) * float64(pass[i])
			if i < len(diar) {
				ed += float64(diar[i]) * float64(diar[i])
			}
		}
		if ep == 0 {
			return 0
		}
		return 100 * (1 - ed/ep)
	}
	trunc := func(s string, n int) string {
		if len(s) > n {
			return s[:n] + "…"
		}
		return s
	}

	regimeOf := func(label string) string {
		switch {
		case strings.Contains(label, "clean"):
			return "clean"
		case strings.Contains(label, "3-voice"):
			return "multi-voice"
		case strings.Contains(label, "overlap v+v"):
			return "full overlap"
		default:
			return "intermittent"
		}
	}

	t.Logf("WER sweep | target=Daniel %q | whisper=small.en | diar_mask on ORACLE segmenter", targetText)
	t.Logf("%-26s | %-9s | %-9s | %-9s | %-10s", "condition", "passWER", "tseWER", "diarWER", "diar removed")
	t.Logf("%s", "---------------------------+-----------+-----------+-----------+-----------")

	var rows []map[string]any
	for _, c := range conds {
		pWER, pHyp := werOf(c.mixed)

		tg, err := NewSpeakerGateAdapter(tsePath, refA)
		if err != nil {
			t.Fatalf("tse: %v", err)
		}
		tOut, err := tg.Process(ctx, c.mixed)
		_ = tg.Close()
		if err != nil {
			t.Fatalf("tse process: %v", err)
		}
		tWER, tHyp := werOf(tOut)

		oracle := &oracleSegmenter{hop: 256, spkIntervals: c.spk}
		dm, err := NewDiarMask(DiarMaskOptions{Segmenter: oracle, Embed: embed, Reference: refA,
			MinSelectCosine: 0.40, MinExclusiveSeconds: 0.5, FallbackPassthrough: true, BoundaryRampMs: 15})
		if err != nil {
			t.Fatalf("diar: %v", err)
		}
		dOut, err := dm.Process(ctx, c.mixed)
		_ = dm.Close()
		if err != nil {
			t.Fatalf("diar process: %v", err)
		}
		dWER, dHyp := werOf(dOut)
		removed := removedPct(dOut, c.mixed)

		t.Logf("%-26s | %8.1f%% | %8.1f%% | %8.1f%% | %8.1f%%", c.label, pWER, tWER, dWER, removed)
		t.Logf("    passthru heard: %q", trunc(pHyp, 90))
		t.Logf("    diar_mask heard: %q", trunc(dHyp, 90))

		rows = append(rows, map[string]any{
			"label": c.label, "regime": regimeOf(c.label), "removed": removed,
			"cands": []map[string]any{
				{"name": "passthrough", "wer": pWER, "heard": pHyp},
				{"name": "TSE (OG)", "wer": tWER, "heard": tHyp},
				{"name": "diar_mask", "wer": dWER, "heard": dHyp},
			},
		})
	}
	t.Logf("lower WER = better. 'diar removed' = %% of passthrough energy zeroed (0 ⇒ full overlap, diar can't mask).")

	if outPath := os.Getenv("DIAR_WER_HTML"); outPath != "" {
		data, _ := json.Marshal(map[string]any{
			"target": targetText, "whisper": "small.en", "rows": rows,
		})
		if err := os.WriteFile(outPath, []byte(renderWERHTML(string(data))), 0o644); err != nil {
			t.Fatalf("write wer html: %v", err)
		}
		t.Logf("wrote WER results HTML -> %s", outPath)
	} else {
		t.Logf("set DIAR_WER_HTML=%s to emit an HTML results page",
			filepath.Join(os.TempDir(), "diar-wer.html"))
	}
}

func renderWERHTML(dataJSON string) string {
	return strings.Replace(werHTMLTemplate, "__DATA__", dataJSON, 1)
}

const werHTMLTemplate = `<!doctype html><html lang="en"><head><meta charset="utf-8">
<meta name="viewport" content="width=device-width,initial-scale=1">
<title>WER sweep — TSE vs diar_mask</title>
<style>
:root{--bg:#0e1116;--panel:#161b22;--line:#30363d;--txt:#c9d1d9;--dim:#8b949e;
--good:#3fb950;--warn:#d29922;--bad:#f85149;--pass:#58a6ff;--tse:#d29922;--diar:#3fb950}
*{box-sizing:border-box}body{margin:0;background:var(--bg);color:var(--txt);
font:14px/1.5 -apple-system,Segoe UI,Roboto,sans-serif}
.wrap{max-width:1080px;margin:0 auto;padding:28px 20px 60px}
h1{font-size:22px;margin:0 0 4px}.sub{color:var(--dim);margin:0 0 16px}
.verdict{background:#11161d;border:1px solid var(--line);border-radius:10px;padding:14px 16px;margin:0 0 20px}
.verdict h3{margin:0 0 8px;font-size:14px}.verdict ul{margin:0;padding-left:18px}.verdict li{margin:3px 0;color:var(--dim)}
.verdict b{color:var(--txt)}
.cond{background:var(--panel);border:1px solid var(--line);border-radius:10px;padding:12px 14px;margin:0 0 12px}
.ch{display:flex;align-items:center;gap:10px;margin-bottom:10px}
.clabel{font-weight:600}.chip{font-size:11px;color:var(--dim);border:1px solid var(--line);border-radius:20px;padding:1px 9px}
.removed{margin-left:auto;font-size:12px;color:var(--dim)}
.row{display:grid;grid-template-columns:96px 1fr 56px;align-items:center;gap:10px;margin:5px 0}
.cand{font-size:12.5px;color:var(--dim)}
.bar{height:18px;background:#0b0e13;border-radius:5px;overflow:hidden;position:relative}
.fill{height:100%;border-radius:5px}
.wer{text-align:right;font-variant-numeric:tabular-nums;font-weight:600;font-size:13px}
.heard{grid-column:2/4;font-size:12px;color:var(--dim);font-style:italic;margin:-2px 0 4px;white-space:nowrap;overflow:hidden;text-overflow:ellipsis}
.best{color:var(--good)}.hurt{color:var(--bad)}
.legend{display:flex;gap:16px;font-size:12px;color:var(--dim);margin:6px 0 18px;flex-wrap:wrap}
.sw{display:inline-block;width:11px;height:11px;border-radius:2px;vertical-align:-1px;margin-right:5px}
</style></head><body><div class="wrap">
<h1>WER sweep — TSE (OG) vs diar_mask</h1>
<p class="sub" id="sub"></p>
<div class="verdict"><h3>What the numbers say (lower WER = better)</h3><ul>
<li><b>Whisper is robust</b> — passthrough is 0% on most conditions, so cleanup rarely has any WER to fix.</li>
<li><b>TSE is the only one that recovers a broken case</b> (loud full overlap) — but it also <b>hurts</b> via reconstruction artifacts (clean target, loud intermittent).</li>
<li><b>diar_mask never hurts</b> — it ties passthrough everywhere and safely drops interferer energy, but can't help full overlap (no exclusive frames).</li>
<li>Caveat: easy synthesized conditions; diar_mask runs on an <b>oracle diarizer</b> (upper bound).</li>
</ul></div>
<div class="legend"><span>WER:</span><span><i class="sw" style="background:var(--good)"></i>low / good</span><span><i class="sw" style="background:var(--warn)"></i>moderate</span><span><i class="sw" style="background:var(--bad)"></i>high / bad</span><span style="margin-left:10px">✓ = best in row · ✗ = worse than doing nothing</span></div>
<div id="conds"></div>
<script>
const DATA=__DATA__;
function werColor(w){return w<10?'var(--good)':(w<40?'var(--warn)':'var(--bad)');}
function esc(s){const d=document.createElement('div');d.textContent=s;return d.innerHTML;}
function render(){
 document.getElementById('sub').textContent='target sentence: "'+DATA.target+'"   ·   ASR: whisper '+DATA.whisper+'   ·   diar_mask on oracle diarization';
 const root=document.getElementById('conds');
 for(const c of DATA.rows){
  const best=Math.min(...c.cands.map(x=>x.wer));
  const pass=c.cands.find(x=>x.name==='passthrough').wer;
  let h='<div class="cond"><div class="ch"><span class="clabel">'+esc(c.label)+'</span>'+
        '<span class="chip">'+esc(c.regime)+'</span>'+
        '<span class="removed">diar removed '+c.removed.toFixed(0)+'% energy</span></div>';
  for(const x of c.cands){
   const badge = (x.wer<=best+0.01?' <span class="best">✓</span>':'') + (x.wer>pass+0.01?' <span class="hurt">✗</span>':'');
   h+='<div class="row"><span class="cand">'+esc(x.name)+'</span>'+
      '<div class="bar"><div class="fill" style="width:'+Math.max(2,x.wer)+'%;background:'+werColor(x.wer)+'"></div></div>'+
      '<span class="wer" style="color:'+werColor(x.wer)+'">'+x.wer.toFixed(1)+'%'+badge+'</span></div>'+
      '<div class="heard">heard: '+esc(x.heard||'(silence)')+'</div>';
  }
  h+='</div>';
  root.insertAdjacentHTML('beforeend',h);
 }
}
render();
</script></div></body></html>`
