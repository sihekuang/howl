package main

import (
	"fmt"
	"os"
)

func main() {
	if len(os.Args) < 2 {
		usage()
		os.Exit(2)
	}
	switch os.Args[1] {
	case "check":
		os.Exit(runCheck(os.Args[2:]))
	case "capture":
		os.Exit(runCapture(os.Args[2:]))
	case "transcribe":
		os.Exit(runTranscribe(os.Args[2:]))
	case "pipe":
		os.Exit(runPipe(os.Args[2:]))
	case "backends":
		os.Exit(runBackends(os.Args[2:]))
	case "-h", "--help", "help":
		usage()
		os.Exit(0)
	default:
		fmt.Fprintf(os.Stderr, "unknown subcommand: %s\n\n", os.Args[1])
		usage()
		os.Exit(2)
	}
}

func usage() {
	fmt.Fprintf(os.Stderr, `vkb-cli — voice keyboard CLI test harness

Usage:
  vkb-cli check                          verify dependencies and config
  vkb-cli capture --out FILE [--secs N]  record from mic to WAV
  vkb-cli transcribe FILE                run Whisper on a WAV
  vkb-cli pipe FILE                      run full pipeline on a WAV
  vkb-cli pipe --live                    record from mic, full pipeline
  vkb-cli backends                       list registered TSE backends
                                         (--models-dir DIR also checks
                                         that each backend's files exist)

Environment:
  ANTHROPIC_API_KEY   required for cleanup
  VKB_MODEL_PATH      path to Whisper ggml-*.bin file
  VKB_LANGUAGE        defaults to "en"
`)
}
