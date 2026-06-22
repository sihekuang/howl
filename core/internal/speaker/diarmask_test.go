package speaker

import (
	"context"
	"math"
	"reflect"
	"testing"
)

func TestPowersetToActivity_MapsClassesToSpeakerSets(t *testing.T) {
	// 3 frames, 7 classes each. Argmax picks class 1 ({0}), class 4 ({0,1}), class 0 (∅).
	hi := float32(9)
	data := []float32{
		0, hi, 0, 0, 0, 0, 0, // frame 0 → class 1 → {0}
		0, 0, 0, 0, hi, 0, 0, // frame 1 → class 4 → {0,1}
		hi, 0, 0, 0, 0, 0, 0, // frame 2 → class 0 → {}
	}
	act, err := powersetToActivity(data, []int64{1, 3, 7}, 256)
	if err != nil {
		t.Fatalf("powersetToActivity: %v", err)
	}
	if act.FrameHopSamples != 256 {
		t.Errorf("FrameHopSamples=%d, want 256", act.FrameHopSamples)
	}
	want := [][]bool{
		{true, false, false},
		{true, true, false},
		{false, false, false},
	}
	if !reflect.DeepEqual(act.Frames, want) {
		t.Errorf("Frames=%v, want %v", act.Frames, want)
	}
}

func TestPowersetToActivity_RejectsWrongClassCount(t *testing.T) {
	if _, err := powersetToActivity([]float32{0, 0, 0}, []int64{1, 3}, 256); err == nil {
		t.Errorf("expected error for last dim != 7")
	}
}

func TestBuildFrameMask_InclusionBias(t *testing.T) {
	act := SpeakerActivity{Frames: [][]bool{
		{true, false, false}, // target 0 active
		{true, true, false},  // target 0 + spk1 overlap → still kept
		{false, true, false}, // only spk1 → dropped
	}}
	got := buildFrameMask(act, 0)
	want := []bool{true, true, false}
	for i := range want {
		if got[i] != want[i] {
			t.Errorf("frame %d: got %v want %v", i, got[i], want[i])
		}
	}
}

func TestFrameMaskToSamples_RampEndpointsAndPlateau(t *testing.T) {
	// One active frame of 100 samples, hop=100, ramp=10. Gain rises 0→1, plateaus, no fall (ends active).
	gain := frameMaskToSamples([]bool{true}, 100, 100, 10)
	if len(gain) != 100 {
		t.Fatalf("len=%d want 100", len(gain))
	}
	if gain[0] != 0 {
		t.Errorf("gain[0]=%f want 0 (ramp start)", gain[0])
	}
	if math.Abs(float64(gain[50]-1)) > 1e-6 {
		t.Errorf("gain[50]=%f want 1 (plateau)", gain[50])
	}
	for i := 1; i < 10; i++ { // ramp is monotonic non-decreasing
		if gain[i] < gain[i-1] {
			t.Errorf("ramp not monotonic at %d: %f < %f", i, gain[i], gain[i-1])
		}
	}
}

func TestApplyMask_ScalesAndCopies(t *testing.T) {
	in := []float32{1, 1, 1, 1}
	gain := []float32{0, 0.5, 1, 0}
	out := applyMask(in, gain)
	want := []float32{0, 0.5, 1, 0}
	for i := range want {
		if out[i] != want[i] {
			t.Errorf("out[%d]=%f want %f", i, out[i], want[i])
		}
	}
	in[0] = 9 // mutation must not affect out
	if out[0] != 0 {
		t.Errorf("applyMask aliased input")
	}
}

func TestSelectTarget_PicksHighestCosineTrack(t *testing.T) {
	// Frames: spk0 exclusive on [0,2), spk1 exclusive on [2,4). hop=100 → 200 samples each.
	act := SpeakerActivity{
		Frames: [][]bool{
			{true, false, false}, {true, false, false},
			{false, true, false}, {false, true, false},
		},
		FrameHopSamples: 100,
	}
	window := make([]float32, 400)
	ref := []float32{1, 0}
	embed := func(s []float32) ([]float32, error) {
		// Embedding encodes which half had energy via length heuristic:
		// caller hands us spk0's samples (idx 0..199) vs spk1's (200..399).
		// We can't see indices, so key off a marker: spk0 region is all 0.25,
		// spk1 region all 0.75 (set below).
		if s[0] == 0.25 {
			return []float32{1, 0}, nil // matches ref
		}
		return []float32{0, 1}, nil // orthogonal to ref
	}
	for i := 0; i < 200; i++ {
		window[i] = 0.25
	}
	for i := 200; i < 400; i++ {
		window[i] = 0.75
	}
	idx, cos, ok, err := selectTarget(act, window, embed, ref, 100)
	if err != nil {
		t.Fatalf("selectTarget: %v", err)
	}
	if !ok {
		t.Fatalf("ok=false, want true (two qualifying tracks)")
	}
	if idx != 0 {
		t.Errorf("idx=%d want 0 (spk0 matches ref)", idx)
	}
	if cos < 0.99 {
		t.Errorf("cos=%f want ~1.0", cos)
	}
}

func TestSelectTarget_SingleSpeakerNotOK(t *testing.T) {
	act := SpeakerActivity{
		Frames:          [][]bool{{true, false, false}, {true, false, false}},
		FrameHopSamples: 100,
	}
	window := make([]float32, 200)
	embed := func(s []float32) ([]float32, error) { return []float32{1, 0}, nil }
	_, _, ok, err := selectTarget(act, window, embed, []float32{1, 0}, 100)
	if err != nil {
		t.Fatalf("selectTarget: %v", err)
	}
	if ok {
		t.Errorf("ok=true, want false (only one track)")
	}
}

// fakeSegmenter returns a scripted activity, ignoring audio content.
type fakeSegmenter struct {
	act SpeakerActivity
}

func (f *fakeSegmenter) Segment(_ context.Context, _ []float32) (SpeakerActivity, error) {
	return f.act, nil
}
func (f *fakeSegmenter) Close() error { return nil }

func newTestDiarMask(t *testing.T, seg Segmenter, embed func([]float32) ([]float32, error), fallback bool) *DiarMask {
	t.Helper()
	d, err := NewDiarMask(DiarMaskOptions{
		Segmenter:           seg,
		Embed:               embed,
		Reference:           []float32{1, 0},
		MinSelectCosine:     0.40,
		MinExclusiveSeconds: 0, // 0 → any non-empty exclusive audio qualifies
		FallbackPassthrough: fallback,
		// BoundaryRampMs unset → defaults to 15 ms; assertions below sample
		// run interiors, where gain is exactly 1 regardless of edge ramps.
	})
	if err != nil {
		t.Fatalf("NewDiarMask: %v", err)
	}
	return d
}

func TestDiarMask_MasksNonTargetFramesKeepsTarget(t *testing.T) {
	// hop = diarWindowLen / 4 so 4 frames cover a full 10 s window.
	hop := diarWindowLen / 4
	act := SpeakerActivity{
		Frames: [][]bool{
			{true, false, false},  // target only → keep
			{true, true, false},   // overlap → keep
			{false, true, false},  // interferer only → drop
			{false, false, false}, // silence → drop
		},
		FrameHopSamples: hop,
	}
	embed := func(s []float32) ([]float32, error) {
		// spk0 exclusive region is marked 0.5; spk1 region 0.9.
		if len(s) > 0 && s[0] == 0.5 {
			return []float32{1, 0}, nil
		}
		return []float32{0, 1}, nil
	}
	mixed := make([]float32, diarWindowLen)
	for i := 0; i < hop; i++ {
		mixed[i] = 0.5 // spk0 exclusive frame 0
	}
	for i := 2 * hop; i < 3*hop; i++ {
		mixed[i] = 0.9 // spk1 exclusive frame 2
	}
	d := newTestDiarMask(t, &fakeSegmenter{act: act}, embed, true)
	out, err := d.Process(context.Background(), mixed)
	if err != nil {
		t.Fatalf("Process: %v", err)
	}
	if len(out) != len(mixed) {
		t.Fatalf("len(out)=%d want %d", len(out), len(mixed))
	}
	// Sample run interiors (gain is exactly 1 inside an active run, 0 inside a
	// dropped run) so the assertions are robust to the default edge ramp.
	if out[hop/2] != 0.5 { // target frame kept verbatim
		t.Errorf("target sample dropped: out[%d]=%f want 0.5", hop/2, out[hop/2])
	}
	if out[2*hop+hop/2] != 0 { // interferer frame silenced
		t.Errorf("interferer sample kept: out[%d]=%f want 0", 2*hop+hop/2, out[2*hop+hop/2])
	}
	if got := d.LastSimilarity(); got < 0.99 {
		t.Errorf("LastSimilarity=%f want ~1.0", got)
	}
}

func TestDiarMask_SingleSpeakerPassesThrough(t *testing.T) {
	hop := diarWindowLen / 2
	act := SpeakerActivity{
		Frames:          [][]bool{{true, false, false}, {true, false, false}},
		FrameHopSamples: hop,
	}
	embed := func(s []float32) ([]float32, error) { return []float32{1, 0}, nil }
	mixed := make([]float32, diarWindowLen)
	for i := range mixed {
		mixed[i] = 0.3
	}
	d := newTestDiarMask(t, &fakeSegmenter{act: act}, embed, true)
	out, err := d.Process(context.Background(), mixed)
	if err != nil {
		t.Fatalf("Process: %v", err)
	}
	for i := range out {
		if out[i] != mixed[i] {
			t.Fatalf("single-speaker should pass through; out[%d]=%f", i, out[i])
		}
	}
}

func TestDiarMask_LowConfidenceFallbackPassthrough(t *testing.T) {
	hop := diarWindowLen / 4
	act := SpeakerActivity{
		Frames: [][]bool{
			{true, false, false}, {false, true, false},
			{true, false, false}, {false, true, false},
		},
		FrameHopSamples: hop,
	}
	// Both tracks orthogonal to ref → best cos ~0 < MinSelectCosine.
	embed := func(s []float32) ([]float32, error) { return []float32{0, 1}, nil }
	mixed := make([]float32, diarWindowLen)
	for i := range mixed {
		mixed[i] = 0.2
	}
	d := newTestDiarMask(t, &fakeSegmenter{act: act}, embed, true)
	out, err := d.Process(context.Background(), mixed)
	if err != nil {
		t.Fatalf("Process: %v", err)
	}
	for i := range out {
		if out[i] != mixed[i] {
			t.Fatalf("low-confidence should pass through; out[%d]=%f", i, out[i])
		}
	}
}

func TestFramesFromShape(t *testing.T) {
	cases := []struct {
		name    string
		shape   []int64
		want    int
		wantErr bool
	}{
		{name: "normal [1,625,7]", shape: []int64{1, 625, 7}, want: 625, wantErr: false},
		{name: "empty shape", shape: []int64{}, want: 0, wantErr: true},
		{name: "rank-1 [7]", shape: []int64{7}, want: 0, wantErr: true},
		{name: "negative dim [1,-3,7]", shape: []int64{1, -3, 7}, want: 0, wantErr: true},
		{name: "zero dim [1,0,7]", shape: []int64{1, 0, 7}, want: 0, wantErr: true},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			got, err := framesFromShape(tc.shape)
			if tc.wantErr {
				if err == nil {
					t.Errorf("framesFromShape(%v) = %d, nil; want error", tc.shape, got)
				}
				return
			}
			if err != nil {
				t.Fatalf("framesFromShape(%v): unexpected error: %v", tc.shape, err)
			}
			if got != tc.want {
				t.Errorf("framesFromShape(%v) = %d, want %d", tc.shape, got, tc.want)
			}
		})
	}
}

func TestDiarMask_InterfaceCompliance(t *testing.T) {
	d := newTestDiarMask(t, &fakeSegmenter{}, func(s []float32) ([]float32, error) { return []float32{1, 0}, nil }, true)
	if d.Name() != "audio_filter" {
		t.Errorf("Name() = %q, want audio_filter", d.Name())
	}
	if d.OutputRate() != 0 {
		t.Errorf("OutputRate()=%d want 0", d.OutputRate())
	}
}
