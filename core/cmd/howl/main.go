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
	case "providers":
		os.Exit(runProviders(os.Args[2:]))
	case "presets":
		os.Exit(runPresets(os.Args[2:]))
	case "sessions":
		os.Exit(runSessions(os.Args[2:]))
	case "compare":
		os.Exit(runCompare(os.Args[2:]))
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
	fmt.Fprintf(os.Stderr, `howl — voice keyboard CLI test harness

Usage:
  howl check                          verify dependencies and config
  howl capture --out FILE [--secs N]  record from mic to WAV
  howl transcribe FILE                run Whisper on a WAV
  howl pipe FILE                      run full pipeline on a WAV
  howl pipe --live                    record from mic, full pipeline
  howl pipe [...] [--record-dir DIR --record audio,transcripts]
                                         tap audio stages / transcripts to DIR
  howl backends                       list registered TSE backends
                                         (--models-dir DIR also checks
                                         that each backend's files exist)
  howl providers                      list registered LLM providers
  howl presets {list|show|save|delete}
                                         manage bundled + user pipeline presets
  howl sessions {list|show|delete|clear}
                                         inspect captured per-stage sessions
  howl compare ID --presets a,b,c     A/B replay a captured session
                                         through one or more presets

Environment:
  ANTHROPIC_API_KEY   required for cleanup (anthropic provider only)
  HOWL_MODEL_PATH      path to Whisper ggml-*.bin file
  HOWL_LANGUAGE        defaults to "en"
`)
}
