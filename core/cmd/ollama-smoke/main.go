// Quick smoke test for Ollama integration.
// Run with:
//   cd core && go run /tmp/ollama_smoke.go
package main

import (
	"context"
	"fmt"
	"os"
	"time"

	"github.com/voice-keyboard/core/internal/llm"
)

func main() {
	model := "llama3.2"
	if len(os.Args) > 1 {
		model = os.Args[1]
	}

	p, err := llm.ProviderByName("ollama")
	if err != nil {
		fmt.Fprintln(os.Stderr, "ProviderByName:", err)
		os.Exit(1)
	}

	t0 := time.Now()
	c, err := p.New(llm.Options{Model: model})
	if err != nil {
		fmt.Fprintln(os.Stderr, "Provider.New:", err)
		os.Exit(1)
	}
	fmt.Fprintf(os.Stderr, "[smoke] constructed in %v\n", time.Since(t0))

	raw := "um so like basically I was uh thinking we should you know add some logging here"
	fmt.Fprintf(os.Stderr, "[smoke] raw:    %q\n", raw)

	t0 = time.Now()
	cleaned, err := c.Clean(context.Background(), raw, nil)
	fmt.Fprintf(os.Stderr, "[smoke] Clean took %v\n", time.Since(t0))
	if err != nil {
		fmt.Fprintln(os.Stderr, "Clean ERROR:", err)
		os.Exit(1)
	}
	fmt.Fprintf(os.Stderr, "[smoke] cleaned: %q\n", cleaned)

	// Streaming version
	if sc, ok := c.(llm.StreamingCleaner); ok {
		fmt.Fprintln(os.Stderr, "[smoke] testing CleanStream...")
		t0 = time.Now()
		first := time.Time{}
		var deltaCount int
		out, err := sc.CleanStream(context.Background(), raw, nil, func(d string) {
			if first.IsZero() {
				first = time.Now()
				fmt.Fprintf(os.Stderr, "[smoke] first delta after %v\n", first.Sub(t0))
			}
			deltaCount++
		})
		fmt.Fprintf(os.Stderr, "[smoke] CleanStream took %v, %d deltas\n", time.Since(t0), deltaCount)
		if err != nil {
			fmt.Fprintln(os.Stderr, "CleanStream ERROR:", err)
			os.Exit(1)
		}
		fmt.Fprintf(os.Stderr, "[smoke] streamed cleaned: %q\n", out)
	}
}
