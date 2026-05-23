package main

import (
	"errors"
	"flag"
	"fmt"
	"os"
	"strings"
	"text/tabwriter"

	"github.com/voice-keyboard/core/internal/llm"
)

// runProviders prints the registered LLM providers — name, default model,
// whether an API key is required. With --models, also enumerates the
// models each provider can serve right now (where the provider supports
// that capability — currently only Ollama).
func runProviders(args []string) int {
	fs := flag.NewFlagSet("providers", flag.ContinueOnError)
	showModels := fs.Bool("models", false, "also list models each provider can serve right now (e.g. installed Ollama models)")
	baseURL := fs.String("llm-base-url", "", "override base URL when listing models (e.g. http://10.0.0.5:11434 for remote Ollama)")
	if err := fs.Parse(args); err != nil {
		return 2
	}

	w := tabwriter.NewWriter(os.Stdout, 0, 0, 2, ' ', 0)
	if *showModels {
		fmt.Fprintln(w, "NAME\tDEFAULT MODEL\tNEEDS API KEY\tAVAILABLE")
	} else {
		fmt.Fprintln(w, "NAME\tDEFAULT MODEL\tNEEDS API KEY")
	}

	defaultName := ""
	if llm.Default != nil {
		defaultName = llm.Default.Name
	}
	for _, name := range llm.ProviderNames() {
		p, _ := llm.ProviderByName(name)
		marker := name
		if name == defaultName {
			marker = name + " *"
		}
		dm := p.DefaultModel
		if dm == "" {
			dm = "(none — auto-detect or --llm-model)"
		}
		needs := "no"
		if p.NeedsAPIKey {
			needs = "yes"
		}
		if *showModels {
			avail := availableModelsLine(p, *baseURL)
			fmt.Fprintf(w, "%s\t%s\t%s\t%s\n", marker, dm, needs, avail)
		} else {
			fmt.Fprintf(w, "%s\t%s\t%s\n", marker, dm, needs)
		}
	}
	_ = w.Flush()
	fmt.Println()
	fmt.Println("* default; pass --llm-provider NAME to howl-cli pipe to override.")
	if !*showModels {
		fmt.Println("Pass --models to also list each provider's available models.")
	}
	return 0
}

// availableModelsLine returns a one-cell description of what models the
// provider can serve right now. Handles the three cases:
//   - provider doesn't support enumeration → "(N/A — cloud)"
//   - provider supports it but the call failed (e.g. Ollama not running)
//     → short "(error: …)"
//   - provider listed N models → comma-joined names (truncated past 6 to
//     keep the table readable).
func availableModelsLine(p *llm.Provider, baseURL string) string {
	models, err := p.LocalModels(llm.Options{BaseURL: baseURL})
	if errors.Is(err, llm.ErrNotSupported) {
		return "(N/A — cloud)"
	}
	if err != nil {
		// Truncate noisy network errors to keep the table aligned.
		msg := err.Error()
		if len(msg) > 60 {
			msg = msg[:57] + "..."
		}
		return "(error: " + msg + ")"
	}
	if len(models) == 0 {
		return "(none installed)"
	}
	const cap = 6
	if len(models) > cap {
		return strings.Join(models[:cap], ", ") + fmt.Sprintf(", … (%d total)", len(models))
	}
	return strings.Join(models, ", ")
}
