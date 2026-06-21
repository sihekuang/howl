//go:build cleanupeval

package speaker

import (
	"bytes"
	"context"
	"encoding/base64"
	"encoding/binary"
	"encoding/json"
	"math"
	"os"
	"path/filepath"
	"strings"
	"testing"
)

// TestDiarMask_SynthHTML renders a self-contained HTML stage-by-stage
// comparison of the OG cleanup flow (TSE / SpeakerGate) and the diarization
// flow (diar_mask) on the same synthesized mixture. It mirrors how the live
// pipeline records per-stage output (recorder.AppendStage + the session
// manifest's StageEntry list), but as a web inspector with waveforms, playable
// audio, and the diarization timeline + mask the OG flow has no equivalent of.
//
// Run:  DIAR_SYNTH_HTML=/tmp/diar-compare.html \
//         go test -tags cleanupeval ./internal/speaker/ -run TestDiarMask_SynthHTML -v
// (writes to ${TMPDIR}/diar-compare.html when the env var is unset).

// wavBytes builds an in-memory 16-bit PCM mono WAV.
func wavBytes(samples []float32, sr int) []byte {
	var b bytes.Buffer
	data := len(samples) * 2
	w := func(v any) { _ = binary.Write(&b, binary.LittleEndian, v) }
	b.WriteString("RIFF")
	w(uint32(36 + data))
	b.WriteString("WAVEfmt ")
	w(uint32(16))
	w(uint16(1))
	w(uint16(1))
	w(uint32(sr))
	w(uint32(sr * 2))
	w(uint16(2))
	w(uint16(16))
	b.WriteString("data")
	w(uint32(data))
	for _, s := range samples {
		if s > 1 {
			s = 1
		} else if s < -1 {
			s = -1
		}
		w(int16(s * math.MaxInt16))
	}
	return b.Bytes()
}

func wavDataURI(samples []float32, sr int) string {
	return "data:audio/wav;base64," + base64.StdEncoding.EncodeToString(wavBytes(samples, sr))
}

// peaks downsamples to `bins` min/max pairs for waveform drawing.
func peaks(s []float32, bins int) [][2]float32 {
	out := make([][2]float32, bins)
	if len(s) == 0 {
		return out
	}
	per := float64(len(s)) / float64(bins)
	for i := 0; i < bins; i++ {
		lo := int(float64(i) * per)
		hi := int(float64(i+1) * per)
		if hi > len(s) {
			hi = len(s)
		}
		mn, mx := float32(0), float32(0)
		if lo < hi {
			mn, mx = s[lo], s[lo]
			for _, v := range s[lo:hi] {
				if v < mn {
					mn = v
				}
				if v > mx {
					mx = v
				}
			}
		}
		out[i] = [2]float32{mn, mx}
	}
	return out
}

// avgBins downsamples a 0..1 gain curve to `bins` averages.
func avgBins(s []float32, bins int) []float32 {
	out := make([]float32, bins)
	if len(s) == 0 {
		return out
	}
	per := float64(len(s)) / float64(bins)
	for i := 0; i < bins; i++ {
		lo, hi := int(float64(i)*per), int(float64(i+1)*per)
		if hi > len(s) {
			hi = len(s)
		}
		var sum float32
		for j := lo; j < hi; j++ {
			sum += s[j]
		}
		if hi > lo {
			out[i] = sum / float32(hi-lo)
		}
	}
	return out
}

// frameClasses maps each diarization frame to 0=silence,1=target,2=interferer,3=overlap.
func frameClasses(act SpeakerActivity, targetIdx int) []int {
	cls := make([]int, len(act.Frames))
	for f, fr := range act.Frames {
		tgt := targetIdx >= 0 && targetIdx < len(fr) && fr[targetIdx]
		other := false
		for spk, on := range fr {
			if on && spk != targetIdx {
				other = true
			}
		}
		switch {
		case tgt && other:
			cls[f] = 3
		case tgt:
			cls[f] = 1
		case other:
			cls[f] = 2
		default:
			cls[f] = 0
		}
	}
	return cls
}

func TestDiarMask_SynthHTML(t *testing.T) {
	encoderPath := resolveModelPath(t, "SPEAKER_ENCODER_PATH", "speaker_encoder.onnx")
	tsePath := resolveModelPath(t, "TSE_MODEL_PATH", "tse_model.onnx")
	initONNXOnce(t)

	const seg = 2 * synthSR
	const total = 4 * seg

	aFull := synthVoice(t, "Daniel",
		"The quick brown fox jumps over the lazy dog while the morning sun rises slowly "+
			"above the quiet hills and the river winds gently through the green valley below.")
	bFull := synthVoice(t, "Samantha",
		"She sells seashells by the seashore on a bright summer afternoon as the children "+
			"build tall sandcastles and the seagulls circle high above the rolling ocean waves.")
	if len(aFull) < 3*seg || len(bFull) < 2*seg {
		t.Fatalf("clips too short: A=%d B=%d", len(aFull), len(bFull))
	}
	aFull = normTo(aFull, 0.08)
	bFull = normTo(bFull, 0.08)

	a1, a2, a3 := aFull[0:seg], aFull[seg:2*seg], aFull[2*seg:3*seg]
	b1, b2 := bFull[0:seg], bFull[seg:2*seg]

	mixed := make([]float32, total)
	addAt(mixed, a1, 0)
	addAt(mixed, a2, 1*seg)
	addAt(mixed, b1, 1*seg)
	addAt(mixed, b2, 2*seg)
	addAt(mixed, a3, 3*seg)

	refA, err := ComputeEmbedding(encoderPath, aFull, 192)
	if err != nil {
		t.Fatalf("embed A: %v", err)
	}
	refB, err := ComputeEmbedding(encoderPath, bFull, 192)
	if err != nil {
		t.Fatalf("embed B: %v", err)
	}
	embed := func(s []float32) ([]float32, error) { return ComputeEmbedding(encoderPath, s, 192) }

	aActive := [][2]int{{0, 2 * seg}, {3 * seg, 4 * seg}}
	bActive := [][2]int{{1 * seg, 3 * seg}}
	oracle := &oracleSegmenter{hop: 256, spkIntervals: [][][2]int{aActive, bActive}}

	ctx := context.Background()

	// --- Diarization flow: run each stage explicitly to capture intermediates ---
	act, err := oracle.Segment(ctx, mixed)
	if err != nil {
		t.Fatalf("segment: %v", err)
	}
	tIdx, selCos, ok, err := selectTarget(act, mixed, embed, refA, int(0.5*float64(synthSR)))
	if err != nil || !ok {
		t.Fatalf("selectTarget: idx=%d cos=%.3f ok=%v err=%v", tIdx, selCos, ok, err)
	}
	frameMask := buildFrameMask(act, tIdx)
	gain := frameMaskToSamples(frameMask, act.FrameHopSamples, len(mixed), 15*synthSR/1000)
	diarOut := applyMask(mixed, gain)

	// Sanity: the explicit stages equal DiarMask.Process output.
	dm, _ := NewDiarMask(DiarMaskOptions{Segmenter: oracle, Embed: embed, Reference: refA,
		MinSelectCosine: 0.40, MinExclusiveSeconds: 0.5, FallbackPassthrough: true, BoundaryRampMs: 15})
	defer dm.Close()
	official, _ := dm.Process(ctx, mixed)
	if len(official) == len(diarOut) {
		var maxDiff float32
		for i := range official {
			if d := float32(math.Abs(float64(official[i] - diarOut[i]))); d > maxDiff {
				maxDiff = d
			}
		}
		t.Logf("explicit-stage vs DiarMask.Process max sample diff = %.6g", maxDiff)
	}

	// --- OG flow: TSE SpeakerGate ---
	tse, err := NewSpeakerGateAdapter(tsePath, refA)
	if err != nil {
		t.Fatalf("tse: %v", err)
	}
	defer tse.Close()
	tseOut, err := tse.Process(ctx, mixed)
	if err != nil {
		t.Fatalf("tse process: %v", err)
	}

	cos := func(out, ref []float32) float64 {
		e, err := ComputeEmbedding(encoderPath, out, 192)
		if err != nil {
			return 0
		}
		return float64(cosineSimilarity(ref, e))
	}
	energyRatio := func(num, den []float32, regions [][2]int) float64 { return ratioRMS(num, den, regions) }
	aOnly := [][2]int{{0, seg}, {3 * seg, 4 * seg}}
	bOnly := [][2]int{{2 * seg, 3 * seg}}

	const wbins = 1100
	type stageAudio struct {
		Wav   string       `json:"wav"`
		Peaks [][2]float32 `json:"peaks"`
		RMS   float64      `json:"rms"`
		CosA  float64      `json:"cosA"`
		CosB  float64      `json:"cosB"`
	}
	mk := func(s []float32) stageAudio {
		return stageAudio{Wav: wavDataURI(s, synthSR), Peaks: peaks(s, wbins),
			RMS: float64(rms(s)), CosA: cos(s, refA), CosB: cos(s, refB)}
	}

	data := map[string]any{
		"meta": map[string]any{
			"target": "Daniel", "interferer": "Samantha",
			"durationS": float64(total) / float64(synthSR), "sampleRate": synthSR,
			"timeline": "A[0-2s] · A+B[2-4s] · B[4-6s] · A[6-8s]  (equal level)",
			"selectCos": selCos, "targetTrack": tIdx,
		},
		"input": mk(mixed),
		"tse":   mk(tseOut),
		"diar":  mk(diarOut),
		"timelineStrip": map[string]any{
			"hop": act.FrameHopSamples, "total": total, "classes": frameClasses(act, tIdx),
		},
		"maskStrip": map[string]any{"bins": avgBins(gain, 550)},
		"metrics": []map[string]any{
			{"name": "passthrough", "retAOnly": energyRatio(mixed, mixed, aOnly), "leakB": energyRatio(mixed, mixed, bOnly), "cosA": cos(mixed, refA), "cosB": cos(mixed, refB)},
			{"name": "tse (OG)", "retAOnly": energyRatio(tseOut, mixed, aOnly), "leakB": energyRatio(tseOut, mixed, bOnly), "cosA": cos(tseOut, refA), "cosB": cos(tseOut, refB)},
			{"name": "diar_mask", "retAOnly": energyRatio(diarOut, mixed, aOnly), "leakB": energyRatio(diarOut, mixed, bOnly), "cosA": cos(diarOut, refA), "cosB": cos(diarOut, refB)},
		},
	}
	// retention vs the clean target (A placed where A active) is more honest
	// than vs mixed; recompute A-only retention against cleanA for the table.
	cleanA := make([]float32, total)
	addAt(cleanA, a1, 0)
	addAt(cleanA, a2, 1*seg)
	addAt(cleanA, a3, 3*seg)
	for _, row := range data["metrics"].([]map[string]any) {
		var out []float32
		switch row["name"] {
		case "passthrough":
			out = mixed
		case "tse (OG)":
			out = tseOut
		default:
			out = diarOut
		}
		row["retAOnly"] = energyRatio(out, cleanA, aOnly)
	}

	js, err := json.Marshal(data)
	if err != nil {
		t.Fatalf("marshal: %v", err)
	}

	outPath := os.Getenv("DIAR_SYNTH_HTML")
	if outPath == "" {
		outPath = filepath.Join(os.TempDir(), "diar-compare.html")
	}
	if err := os.WriteFile(outPath, []byte(renderHTML(string(js))), 0o644); err != nil {
		t.Fatalf("write html: %v", err)
	}
	t.Logf("wrote stage-by-stage comparison HTML -> %s", outPath)
	t.Logf("open it: open %q", outPath)
}

// renderHTML returns the self-contained comparison page with DATA injected.
// Uses a literal token (not fmt) so the CSS '%' units survive verbatim.
func renderHTML(dataJSON string) string {
	return strings.Replace(htmlTemplate, "__DATA__", dataJSON, 1)
}

const htmlTemplate = `<!doctype html><html lang="en"><head><meta charset="utf-8">
<meta name="viewport" content="width=device-width,initial-scale=1">
<title>diar_mask vs TSE — stage-by-stage</title>
<style>
:root{--bg:#0e1116;--panel:#161b22;--line:#30363d;--txt:#c9d1d9;--dim:#8b949e;
--in:#58a6ff;--tse:#d29922;--diar:#3fb950;--A:#4aa3ff;--B:#ff8c42;--ov:#b07cff;--sil:#2d333b}
*{box-sizing:border-box}body{margin:0;background:var(--bg);color:var(--txt);
font:14px/1.5 -apple-system,Segoe UI,Roboto,sans-serif}
.wrap{max-width:1200px;margin:0 auto;padding:28px 20px 60px}
h1{font-size:22px;margin:0 0 4px}.sub{color:var(--dim);margin:0 0 18px}
.cols{display:grid;grid-template-columns:1fr 1fr;gap:18px;margin-top:10px}
@media(max-width:880px){.cols{grid-template-columns:1fr}}
.col h2{font-size:15px;margin:0 0 10px;padding-bottom:8px;border-bottom:1px solid var(--line)}
.colTSE h2{color:var(--tse)}.colDiar h2{color:var(--diar)}
.card{background:var(--panel);border:1px solid var(--line);border-radius:10px;padding:12px 14px;margin:0 0 12px}
.card.shared{border-style:dashed;opacity:.85}
.st{display:flex;justify-content:space-between;align-items:baseline;gap:8px}
.stname{font-weight:600}.sttag{font-size:11px;color:var(--dim);text-transform:uppercase;letter-spacing:.04em}
.note{color:var(--dim);font-size:12.5px;margin:6px 0 2px}
canvas{width:100%;height:74px;display:block;margin:8px 0 6px;background:#0b0e13;border-radius:6px}
canvas.strip{height:34px}
.meta{display:flex;flex-wrap:wrap;gap:6px 14px;font-size:12.5px;color:var(--dim)}
.meta b{color:var(--txt);font-weight:600}
audio{width:100%;height:30px;margin-top:6px}
.legend{display:flex;gap:14px;font-size:12px;color:var(--dim);margin:2px 0 0;flex-wrap:wrap}
.sw{display:inline-block;width:11px;height:11px;border-radius:2px;vertical-align:-1px;margin-right:5px}
.arrow{color:var(--dim);text-align:center;font-size:18px;margin:-4px 0 6px}
table{width:100%;border-collapse:collapse;margin-top:22px;font-size:13px}
th,td{padding:7px 10px;border-bottom:1px solid var(--line);text-align:right}
th:first-child,td:first-child{text-align:left}thead th{color:var(--dim);font-weight:600}
.good{color:var(--diar)}.warn{color:var(--tse)}
.banner{background:#11161d;border:1px solid var(--line);border-radius:10px;padding:10px 14px;margin-bottom:14px;color:var(--dim);font-size:12.5px}
.tl{position:relative}.tlticks{display:flex;justify-content:space-between;color:var(--dim);font-size:10.5px;margin-top:-2px}
</style></head><body><div class="wrap">
<h1>diar_mask vs TSE — stage-by-stage on synthesized audio</h1>
<p class="sub" id="sub"></p>
<div class="banner" id="banner"></div>
<div class="card shared"><div class="st"><span class="stname">Shared frame stages</span><span class="sttag">denoise → decimate3 (48k→16k)</span></div>
<div class="note">Identical preprocessing for both flows. Both cleanup stages below receive the same 16&nbsp;kHz chunk — the input shown at the top of each column.</div></div>
<div class="cols">
  <div class="col colTSE">
    <h2>OG cleanup — TSE (SpeakerGate)</h2>
    <div class="card"><div class="st"><span class="stname">input chunk</span><span class="sttag">16 kHz · chunk</span></div>
      <canvas data-wave="input"></canvas><audio controls data-audio="input"></audio></div>
    <div class="arrow">↓</div>
    <div class="card"><div class="st"><span class="stname">tse — separate + cosine-pick</span><span class="sttag">fused ONNX</span></div>
      <div class="note">ConvTasNet separates the mixture into sources, ECAPA embeds each, and hard-selects the source closest to the enrolled embedding. The output is a <b>reconstructed</b> waveform (new samples everywhere).</div></div>
    <div class="arrow">↓</div>
    <div class="card"><div class="st"><span class="stname">tse output → Whisper</span><span class="sttag">reconstructed</span></div>
      <canvas data-wave="tse"></canvas><audio controls data-audio="tse"></audio>
      <div class="meta" data-meta="tse"></div></div>
  </div>
  <div class="col colDiar">
    <h2>Diarization cleanup — diar_mask</h2>
    <div class="card"><div class="st"><span class="stname">input chunk</span><span class="sttag">16 kHz · chunk</span></div>
      <canvas data-wave="input2"></canvas><audio controls data-audio="input2"></audio></div>
    <div class="arrow">↓</div>
    <div class="card"><div class="st"><span class="stname">segment — speaker activity</span><span class="sttag">who speaks when</span></div>
      <canvas class="strip" id="timeline"></canvas>
      <div class="tlticks" id="ticks"></div>
      <div class="legend"><span><i class="sw" style="background:var(--A)"></i>target</span><span><i class="sw" style="background:var(--B)"></i>interferer</span><span><i class="sw" style="background:var(--ov)"></i>overlap</span><span><i class="sw" style="background:var(--sil)"></i>silence</span></div></div>
    <div class="arrow">↓</div>
    <div class="card"><div class="st"><span class="stname">select — cosine target track</span><span class="sttag" id="selTag"></span></div>
      <div class="note" id="selNote"></div></div>
    <div class="arrow">↓</div>
    <div class="card"><div class="st"><span class="stname">mask — target activity (inclusion bias)</span><span class="sttag">keep / drop</span></div>
      <canvas class="strip" id="mask"></canvas>
      <div class="legend"><span><i class="sw" style="background:var(--diar)"></i>keep target audio</span><span><i class="sw" style="background:#21262d"></i>drop (zero)</span></div></div>
    <div class="arrow">↓</div>
    <div class="card"><div class="st"><span class="stname">masked output → Whisper</span><span class="sttag">original, regions zeroed</span></div>
      <div class="note">Original samples preserved where the target is active (notice the waveform is <b>identical</b> to the input there), zeroed in the interferer-only region.</div>
      <canvas data-wave="diar"></canvas><audio controls data-audio="diar"></audio>
      <div class="meta" data-meta="diar"></div></div>
  </div>
</div>
<table id="metrics"><thead><tr><th>candidate</th><th>retention (A-only)</th><th>B-only leak</th><th>cos→target</th><th>cos→interferer</th></tr></thead><tbody></tbody></table>
<p class="sub" style="margin-top:10px">retention 1.0 = target kept · leak 0 = interferer removed · cos→target high &amp; cos→interferer low = isolated.</p>
<script>
const DATA=__DATA__;
function cssv(n){return getComputedStyle(document.documentElement).getPropertyValue(n).trim();}
function drawWave(cv,peaks,color){const r=window.devicePixelRatio||1;const w=cv.clientWidth,h=cv.clientHeight;cv.width=w*r;cv.height=h*r;const x=cv.getContext('2d');x.scale(r,r);x.clearRect(0,0,w,h);x.strokeStyle=cssv('--line');x.beginPath();x.moveTo(0,h/2);x.lineTo(w,h/2);x.stroke();x.strokeStyle=color;x.lineWidth=1;const n=peaks.length;for(let i=0;i<n;i++){const px=i/n*w;const mn=peaks[i][0],mx=peaks[i][1];x.beginPath();x.moveTo(px,h/2-mx*h*0.46);x.lineTo(px,h/2-mn*h*0.46);x.stroke();}}
function drawTimeline(cv,classes){const r=window.devicePixelRatio||1;const w=cv.clientWidth,h=cv.clientHeight;cv.width=w*r;cv.height=h*r;const x=cv.getContext('2d');x.scale(r,r);const cols={0:cssv('--sil'),1:cssv('--A'),2:cssv('--B'),3:cssv('--ov')};const n=classes.length;const bw=w/n;for(let i=0;i<n;i++){x.fillStyle=cols[classes[i]];x.fillRect(i*bw,0,bw+0.6,h);}}
function drawMask(cv,bins){const r=window.devicePixelRatio||1;const w=cv.clientWidth,h=cv.clientHeight;cv.width=w*r;cv.height=h*r;const x=cv.getContext('2d');x.scale(r,r);x.fillStyle='#21262d';x.fillRect(0,0,w,h);const n=bins.length;const bw=w/n;const g=cssv('--diar');for(let i=0;i<n;i++){const v=bins[i];if(v<=0.001)continue;x.globalAlpha=Math.max(0.12,v);x.fillStyle=g;x.fillRect(i*bw,0,bw+0.6,h);}x.globalAlpha=1;}
function metaHTML(s){return '<span>RMS <b>'+s.rms.toFixed(3)+'</b></span><span>cos→target <b>'+s.cosA.toFixed(3)+'</b></span><span>cos→interferer <b>'+s.cosB.toFixed(3)+'</b></span>';}
function init(){
 const m=DATA.meta;
 document.getElementById('sub').textContent='target = '+m.target+'   ·   interferer = '+m.interferer+'   ·   '+m.durationS.toFixed(0)+'s @ '+m.sampleRate+' Hz';
 document.getElementById('banner').innerHTML='Timeline: <b>'+m.timeline+'</b>. The OG flow (left) reconstructs a waveform; the diarization flow (right) keeps the original audio and zeros non-target regions.';
 for(const k of ['input','input2']){const cv=document.querySelector('[data-wave="'+k+'"]');drawWave(cv,DATA.input.peaks,cssv('--in'));document.querySelector('[data-audio="'+k+'"]').src=DATA.input.wav;}
 drawWave(document.querySelector('[data-wave="tse"]'),DATA.tse.peaks,cssv('--tse'));
 document.querySelector('[data-audio="tse"]').src=DATA.tse.wav;
 document.querySelector('[data-meta="tse"]').innerHTML=metaHTML(DATA.tse);
 drawWave(document.querySelector('[data-wave="diar"]'),DATA.diar.peaks,cssv('--diar'));
 document.querySelector('[data-audio="diar"]').src=DATA.diar.wav;
 document.querySelector('[data-meta="diar"]').innerHTML=metaHTML(DATA.diar);
 drawTimeline(document.getElementById('timeline'),DATA.timelineStrip.classes);
 drawMask(document.getElementById('mask'),DATA.maskStrip.bins);
 const secs=Math.round(m.durationS);let ticks='';for(let i=0;i<=secs;i++)ticks+='<span>'+i+'s</span>';document.getElementById('ticks').innerHTML=ticks;
 document.getElementById('selTag').textContent='selected track '+m.targetTrack+' · cos '+m.selectCos.toFixed(3);
 document.getElementById('selNote').innerHTML='Each diarized track is embedded (ECAPA) and scored by cosine against the enrolled target. The highest-scoring track is <b>kept</b> — cosine is a SELECTOR here, not a gate, so it can never silence the target.';
 const tb=document.querySelector('#metrics tbody');tb.innerHTML='';
 for(const row of DATA.metrics){const tr=document.createElement('tr');
  const ret=row.retAOnly, leak=row.leakB;
  tr.innerHTML='<td>'+row.name+'</td>'+
   '<td class="'+(ret>=0.95?'good':'')+'">'+ret.toFixed(3)+'</td>'+
   '<td class="'+(leak<=0.05?'good':(leak>=0.9?'warn':''))+'">'+leak.toFixed(3)+'</td>'+
   '<td>'+row.cosA.toFixed(3)+'</td>'+'<td>'+row.cosB.toFixed(3)+'</td>';
  tb.appendChild(tr);}
}
window.addEventListener('resize',init);init();
</script></div></body></html>`
