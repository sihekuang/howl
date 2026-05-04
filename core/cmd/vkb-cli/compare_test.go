//go:build whispercpp

package main

import (
	"testing"
)

func TestCompare_NoArgs_ShowsUsage(t *testing.T) {
	if rc := runCompare(nil); rc == 0 {
		t.Errorf("expected non-zero rc")
	}
}

func TestCompare_RequiresPresetsFlag(t *testing.T) {
	if rc := runCompare([]string{"some-id"}); rc == 0 {
		t.Errorf("expected non-zero rc when --presets is empty")
	}
}

func TestCompare_UnknownSession(t *testing.T) {
	dir := t.TempDir()
	t.Setenv("VKB_SESSIONS_DIR", dir)
	rc := runCompare([]string{"--presets", "default", "no-such-id"})
	if rc == 0 {
		t.Errorf("expected non-zero rc for unknown session")
	}
}

func TestCompare_SplitPresetCSV(t *testing.T) {
	cases := []struct {
		in   string
		want []string
	}{
		{"", nil},
		{"a", []string{"a"}},
		{"a,b,c", []string{"a", "b", "c"}},
		{"  a  , ,b ,", []string{"a", "b"}},
	}
	for _, c := range cases {
		got := splitPresetCSV(c.in)
		if len(got) != len(c.want) {
			t.Errorf("splitPresetCSV(%q) = %v; want %v", c.in, got, c.want)
			continue
		}
		for i := range got {
			if got[i] != c.want[i] {
				t.Errorf("splitPresetCSV(%q)[%d] = %q; want %q", c.in, i, got[i], c.want[i])
			}
		}
	}
}
