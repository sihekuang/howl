//go:build whispercpp

package transcribe

import (
	"context"
	"math"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"unicode"
)

// TestWhisperCpp_ChunkedMatchesFull verifies that transcribing audio in
// three sequential chunks and concatenating the results is within 5% edit
// distance (≥ 3) of the single-shot full transcription. This guards against
// regressions where chunked streaming diverges significantly from the
// single-batch baseline.
func TestWhisperCpp_ChunkedMatchesFull(t *testing.T) {
	modelPath := os.ExpandEnv("$HOME/Library/Application Support/VoiceKeyboard/models/ggml-tiny.en.bin")
	if _, err := os.Stat(modelPath); err != nil {
		t.Skipf("model not available at %s", modelPath)
	}

	wavPath := filepath.Join("..", "..", "test", "integration", "testdata", "hello-world.wav")
	pcm, err := readWavMono16k(wavPath)
	if err != nil {
		t.Skipf("test fixture not available: %v", err)
	}

	w, err := NewWhisperCpp(WhisperOptions{ModelPath: modelPath, Language: "en"})
	if err != nil {
		t.Fatalf("NewWhisperCpp: %v", err)
	}
	defer w.Close()

	fullText, err := w.Transcribe(context.Background(), pcm)
	if err != nil {
		t.Fatalf("full Transcribe: %v", err)
	}

	// Split into 3 roughly equal chunks and transcribe each sequentially.
	n := len(pcm)
	cuts := [4]int{0, n / 3, 2 * n / 3, n}
	var parts []string
	for i := 0; i < 3; i++ {
		text, err := w.Transcribe(context.Background(), pcm[cuts[i]:cuts[i+1]])
		if err != nil {
			t.Fatalf("chunk %d Transcribe: %v", i, err)
		}
		if s := strings.TrimSpace(text); s != "" {
			parts = append(parts, s)
		}
	}
	chunkedText := strings.Join(parts, " ")

	full := chunkNormalize(fullText)
	chunked := chunkNormalize(chunkedText)

	dist := chunkLevenshtein(full, chunked)
	budget := int(math.Max(3, float64(len([]rune(full)))*0.05))
	t.Logf("full:          %q", full)
	t.Logf("chunked (3×):  %q", chunked)
	t.Logf("edit distance: %d  budget: %d", dist, budget)
	if dist > budget {
		t.Errorf("chunked transcript drifted: edit distance %d > budget %d", dist, budget)
	}
}

// chunkNormalize lowercases and collapses punctuation to single spaces so
// minor punctuation differences don't inflate the edit distance.
func chunkNormalize(s string) string {
	s = strings.ToLower(s)
	var b strings.Builder
	inWord := false
	for _, r := range s {
		if unicode.IsLetter(r) || unicode.IsDigit(r) {
			b.WriteRune(r)
			inWord = true
		} else if inWord {
			b.WriteRune(' ')
			inWord = false
		}
	}
	return strings.TrimSpace(b.String())
}

// chunkLevenshtein computes the edit distance between two strings using a
// two-row rolling DP to keep memory O(min(m,n)).
func chunkLevenshtein(a, b string) int {
	ra, rb := []rune(a), []rune(b)
	m, n := len(ra), len(rb)
	prev := make([]int, n+1)
	curr := make([]int, n+1)
	for j := range prev {
		prev[j] = j
	}
	for i := 1; i <= m; i++ {
		curr[0] = i
		for j := 1; j <= n; j++ {
			if ra[i-1] == rb[j-1] {
				curr[j] = prev[j-1]
			} else {
				curr[j] = 1 + chunkMinInt(prev[j], curr[j-1], prev[j-1])
			}
		}
		prev, curr = curr, prev
	}
	return prev[n]
}

func chunkMinInt(a, b, c int) int {
	if a <= b && a <= c {
		return a
	}
	if b <= c {
		return b
	}
	return c
}
