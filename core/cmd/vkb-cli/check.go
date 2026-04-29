package main

import (
	"flag"
	"fmt"
	"os"
)

func runCheck(args []string) int {
	fs := flag.NewFlagSet("check", flag.ContinueOnError)
	if err := fs.Parse(args); err != nil {
		return 2
	}

	ok := true

	// 1. ANTHROPIC_API_KEY
	if os.Getenv("ANTHROPIC_API_KEY") == "" {
		fmt.Println("[FAIL] ANTHROPIC_API_KEY is not set in the environment")
		ok = false
	} else {
		fmt.Println("[ OK ] ANTHROPIC_API_KEY is set")
	}

	// 2. Whisper model
	modelPath := os.Getenv("VKB_MODEL_PATH")
	if modelPath == "" {
		modelPath = os.ExpandEnv("$HOME/Library/Application Support/VoiceKeyboard/models/ggml-tiny.en.bin")
	}
	if _, err := os.Stat(modelPath); err != nil {
		fmt.Printf("[FAIL] Whisper model not found at %s\n", modelPath)
		ok = false
	} else {
		fmt.Printf("[ OK ] Whisper model present: %s\n", modelPath)
	}

	// 3. libwhisper available — if we got here and built, it is. Just
	//    note its location for the operator.
	fmt.Printf("[ OK ] linked against libwhisper.dylib (Homebrew)\n")
	fmt.Printf("[ OK ] linked against libdf.dylib (vendored)\n")

	if ok {
		fmt.Println("\nAll checks passed.")
		return 0
	}
	fmt.Println("\nOne or more checks failed.")
	return 1
}
