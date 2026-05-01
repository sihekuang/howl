package main

import (
	"flag"
	"fmt"
	"os"
	"text/tabwriter"

	"github.com/voice-keyboard/core/internal/llm"
)

// runProviders prints the registered LLM providers — name, default model,
// whether an API key is required.
func runProviders(args []string) int {
	fs := flag.NewFlagSet("providers", flag.ContinueOnError)
	if err := fs.Parse(args); err != nil {
		return 2
	}

	w := tabwriter.NewWriter(os.Stdout, 0, 0, 2, ' ', 0)
	fmt.Fprintln(w, "NAME\tDEFAULT MODEL\tNEEDS API KEY")

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
			dm = "(none — must specify --llm-model)"
		}
		needs := "no"
		if p.NeedsAPIKey {
			needs = "yes"
		}
		fmt.Fprintf(w, "%s\t%s\t%s\n", marker, dm, needs)
	}
	_ = w.Flush()
	fmt.Println()
	fmt.Println("* default; pass --llm-provider NAME to vkb-cli pipe to override.")
	return 0
}
