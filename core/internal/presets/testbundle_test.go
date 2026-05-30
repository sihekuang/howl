package presets

import (
	_ "embed"
	"testing"
)

//go:embed testdata/pipeline-presets.json
var testBundleJSON []byte

// loadTestBundle parses the test fixture in testdata/. Tests that
// hardcode assertions about specific preset values read from this
// fixture so production JSON tuning (e.g. flipping TSE on/off in
// default) doesn't ripple into test rewrites. Smoke tests that verify
// the real shipped JSON keep calling loadBundled().
func loadTestBundle(t *testing.T) []Preset {
	t.Helper()
	all, err := parseBundle(testBundleJSON)
	if err != nil {
		t.Fatalf("parse test bundle: %v", err)
	}
	return all
}
