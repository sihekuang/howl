package speaker

import (
	"testing"
)

// fakeVAD satisfies the VAD interface for tests.
type fakeVAD struct{ voiced bool }

func (f *fakeVAD) IsVoiced(_ []float32) bool { return f.voiced }

func TestFakeVAD_ImplementsInterface(t *testing.T) {
	var _ VAD = &fakeVAD{}
}

func TestFakeVAD_ReturnsConfiguredValue(t *testing.T) {
	v := &fakeVAD{voiced: true}
	if !v.IsVoiced(nil) {
		t.Fatalf("expected IsVoiced true")
	}
	v.voiced = false
	if v.IsVoiced(nil) {
		t.Fatalf("expected IsVoiced false")
	}
}
