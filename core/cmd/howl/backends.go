package main

import (
	"flag"
	"fmt"
	"os"
	"text/tabwriter"

	"github.com/voice-keyboard/core/internal/speaker"
)

// runBackends prints the registered TSE backends. Optionally checks whether
// each backend's ONNX files exist in --models-dir.
func runBackends(args []string) int {
	fs := flag.NewFlagSet("backends", flag.ContinueOnError)
	modelsDir := fs.String("models-dir", "", "if set, also check whether each backend's ONNX files exist there")
	if err := fs.Parse(args); err != nil {
		return 2
	}
	if *modelsDir == "" {
		*modelsDir = os.Getenv("HOWL_MODELS_DIR")
	}

	w := tabwriter.NewWriter(os.Stdout, 0, 0, 2, ' ', 0)
	if *modelsDir != "" {
		fmt.Fprintln(w, "NAME\tEMB DIM\tENCODER FILE\tTSE FILE\tFILES PRESENT")
	} else {
		fmt.Fprintln(w, "NAME\tEMB DIM\tENCODER FILE\tTSE FILE")
	}

	defaultName := speaker.Default.Name
	for _, name := range speaker.BackendNames() {
		b, _ := speaker.BackendByName(name)
		marker := name
		if name == defaultName {
			marker = name + " *"
		}
		if *modelsDir != "" {
			present := "yes"
			if !fileExists(b.EncoderPath(*modelsDir)) || !fileExists(b.TSEPath(*modelsDir)) {
				present = "MISSING"
			}
			fmt.Fprintf(w, "%s\t%d\t%s\t%s\t%s\n", marker, b.EmbeddingDim, b.EncoderModelFile, b.TSEModelFile, present)
		} else {
			fmt.Fprintf(w, "%s\t%d\t%s\t%s\n", marker, b.EmbeddingDim, b.EncoderModelFile, b.TSEModelFile)
		}
	}
	_ = w.Flush()
	fmt.Println()
	fmt.Println("* default; pass --tse-backend NAME to howl pipe to override.")
	return 0
}

func fileExists(path string) bool {
	_, err := os.Stat(path)
	return err == nil
}
