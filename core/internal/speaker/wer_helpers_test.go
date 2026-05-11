//go:build cleanupeval

package speaker

import (
	"math"
	"strings"
	"testing"
	"unicode"
)

func TestNormalizeForWER_LowercaseStripsPunctuation(t *testing.T) {
	got := normalizeForWER("Hello, World! How are you?")
	want := "hello world how are you"
	if got != want {
		t.Errorf("got %q, want %q", got, want)
	}
}

func TestNormalizeForWER_CollapsesWhitespace(t *testing.T) {
	got := normalizeForWER("  the   quick\tbrown\nfox  ")
	want := "the quick brown fox"
	if got != want {
		t.Errorf("got %q, want %q", got, want)
	}
}

func TestNormalizeForWER_StripsNonAscii(t *testing.T) {
	got := normalizeForWER("café — résumé")
	// '—' becomes whitespace via punctuation strip; é stays (we don't strip diacritics).
	want := "café résumé"
	if got != want {
		t.Errorf("got %q, want %q", got, want)
	}
}

func TestTokenEditDistance_IdenticalIsZero(t *testing.T) {
	got := tokenEditDistance([]string{"a", "b", "c"}, []string{"a", "b", "c"})
	if got != 0 {
		t.Errorf("identical sequences: got %d, want 0", got)
	}
}

func TestTokenEditDistance_OneSubstitution(t *testing.T) {
	got := tokenEditDistance([]string{"a", "b", "c"}, []string{"a", "X", "c"})
	if got != 1 {
		t.Errorf("one sub: got %d, want 1", got)
	}
}

func TestTokenEditDistance_OneDeletion(t *testing.T) {
	got := tokenEditDistance([]string{"a", "b", "c"}, []string{"a", "c"})
	if got != 1 {
		t.Errorf("one del: got %d, want 1", got)
	}
}

func TestTokenEditDistance_OneInsertion(t *testing.T) {
	got := tokenEditDistance([]string{"a", "b"}, []string{"a", "X", "b"})
	if got != 1 {
		t.Errorf("one ins: got %d, want 1", got)
	}
}

func TestComputeWER_PerfectIsZero(t *testing.T) {
	got := computeWER("hello world", "hello world")
	if got != 0 {
		t.Errorf("perfect: got %f, want 0", got)
	}
}

func TestComputeWER_AllWrongIsOne(t *testing.T) {
	// Reference 3 words; hypothesis is 3 different words → 3 substitutions / 3 = 1.0.
	got := computeWER("foo bar baz", "qux quux corge")
	if math.Abs(got-1.0) > 1e-9 {
		t.Errorf("all wrong: got %f, want 1.0", got)
	}
}

func TestComputeWER_HandlesEmptyReference(t *testing.T) {
	// Edge case: empty reference, non-empty hypothesis.
	// Convention: WER = 1.0 (everything is an insertion error).
	got := computeWER("", "spurious words")
	if got != 1.0 {
		t.Errorf("empty ref: got %f, want 1.0", got)
	}
}

func TestComputeWER_HandlesNormalisation(t *testing.T) {
	// Punctuation + case differences should be normalised away.
	got := computeWER("Hello, World!", "hello world")
	if got != 0 {
		t.Errorf("normalised match: got %f, want 0", got)
	}
}

// normalizeForWER lowercases, strips punctuation, and collapses
// whitespace so reference and hypothesis strings can be compared
// without spurious differences from formatting. Diacritics are
// preserved (Whisper produces them; LibriSpeech rarely contains them).
func normalizeForWER(s string) string {
	var b strings.Builder
	b.Grow(len(s))
	for _, r := range s {
		switch {
		case unicode.IsLetter(r) || unicode.IsDigit(r):
			b.WriteRune(unicode.ToLower(r))
		case unicode.IsSpace(r) || unicode.IsPunct(r) || unicode.IsSymbol(r):
			b.WriteRune(' ')
		default:
			// Leave other runes (e.g. accented letters) lower-cased.
			b.WriteRune(unicode.ToLower(r))
		}
	}
	// Collapse runs of whitespace.
	return strings.Join(strings.Fields(b.String()), " ")
}

// tokenEditDistance returns the Levenshtein distance between two
// token sequences (substitutions + deletions + insertions, each
// cost 1).
func tokenEditDistance(ref, hyp []string) int {
	n, m := len(ref), len(hyp)
	if n == 0 {
		return m
	}
	if m == 0 {
		return n
	}
	prev := make([]int, m+1)
	curr := make([]int, m+1)
	for j := 0; j <= m; j++ {
		prev[j] = j
	}
	for i := 1; i <= n; i++ {
		curr[0] = i
		for j := 1; j <= m; j++ {
			cost := 1
			if ref[i-1] == hyp[j-1] {
				cost = 0
			}
			curr[j] = min3(
				prev[j]+1,      // deletion
				curr[j-1]+1,    // insertion
				prev[j-1]+cost, // substitution
			)
		}
		prev, curr = curr, prev
	}
	return prev[m]
}

func min3(a, b, c int) int {
	m := a
	if b < m {
		m = b
	}
	if c < m {
		m = c
	}
	return m
}

// computeWER returns the word error rate of hypothesis vs reference,
// after normalising both. Convention: empty reference + non-empty
// hypothesis → 1.0; both empty → 0.0.
func computeWER(reference, hypothesis string) float64 {
	ref := strings.Fields(normalizeForWER(reference))
	hyp := strings.Fields(normalizeForWER(hypothesis))
	if len(ref) == 0 {
		if len(hyp) == 0 {
			return 0
		}
		return 1.0
	}
	dist := tokenEditDistance(ref, hyp)
	return float64(dist) / float64(len(ref))
}
