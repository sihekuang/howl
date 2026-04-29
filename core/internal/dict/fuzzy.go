package dict

import (
	"strings"
	"unicode"
)

// Fuzzy matches tokens to a small vocabulary using Levenshtein distance.
// Comparison is case-insensitive. Tokens shorter than three runes are
// skipped to avoid spurious matches on common short words.
type Fuzzy struct {
	terms    []string
	maxDist  int
	lowerSet []string // lowercase terms, parallel to `terms`
}

func NewFuzzy(terms []string, maxDist int) *Fuzzy {
	lowerSet := make([]string, len(terms))
	for i, t := range terms {
		lowerSet[i] = strings.ToLower(t)
	}
	return &Fuzzy{terms: terms, maxDist: maxDist, lowerSet: lowerSet}
}

func (f *Fuzzy) Match(text string) (string, []string) {
	if text == "" {
		return "", nil
	}

	matched := map[string]struct{}{}
	var b strings.Builder
	b.Grow(len(text))

	i := 0
	for i < len(text) {
		// pass through anything that isn't a letter or digit
		if !isWordRune(rune(text[i])) {
			b.WriteByte(text[i])
			i++
			continue
		}

		// find the next token boundary
		j := i
		for j < len(text) && isWordRune(rune(text[j])) {
			j++
		}
		token := text[i:j]
		canonical := f.canonicalFor(token)
		if canonical != "" {
			b.WriteString(canonical)
			matched[canonical] = struct{}{}
		} else {
			b.WriteString(token)
		}
		i = j
	}

	out := make([]string, 0, len(matched))
	for k := range matched {
		out = append(out, k)
	}
	return b.String(), out
}

func (f *Fuzzy) canonicalFor(token string) string {
	if len([]rune(token)) < 3 {
		return ""
	}
	tokenLower := strings.ToLower(token)
	bestIdx := -1
	bestDist := f.maxDist + 1
	for i, term := range f.lowerSet {
		d := levenshtein(tokenLower, term)
		if d <= f.maxDist && d < bestDist {
			bestDist = d
			bestIdx = i
		}
	}
	if bestIdx == -1 {
		return ""
	}
	return f.terms[bestIdx]
}

func isWordRune(r rune) bool {
	return unicode.IsLetter(r) || unicode.IsDigit(r)
}

// levenshtein returns the edit distance between two ASCII/UTF-8 strings.
// Uses the standard two-row dynamic programming approach: O(len(a)*len(b))
// time, O(min(len(a), len(b))) space.
func levenshtein(a, b string) int {
	ra := []rune(a)
	rb := []rune(b)
	if len(ra) == 0 {
		return len(rb)
	}
	if len(rb) == 0 {
		return len(ra)
	}
	prev := make([]int, len(rb)+1)
	curr := make([]int, len(rb)+1)
	for j := range prev {
		prev[j] = j
	}
	for i := 1; i <= len(ra); i++ {
		curr[0] = i
		for j := 1; j <= len(rb); j++ {
			cost := 1
			if ra[i-1] == rb[j-1] {
				cost = 0
			}
			curr[j] = min3(curr[j-1]+1, prev[j]+1, prev[j-1]+cost)
		}
		prev, curr = curr, prev
	}
	return prev[len(rb)]
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
