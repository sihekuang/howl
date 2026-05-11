package main

import (
	"encoding/json"
	"flag"
	"fmt"
	"os"
	"path/filepath"
	"text/tabwriter"

	"github.com/voice-keyboard/core/internal/sessions"
)

// runSessions dispatches `howl sessions <action>` to per-action helpers.
// Same rc convention as runPresets:
//   - 0 on success
//   - 1 on runtime/IO error
//   - 2 on usage / validation error
func runSessions(args []string) int {
	if len(args) == 0 {
		fmt.Fprintln(os.Stderr, "usage: howl sessions {list|show|delete|clear} ...")
		return 2
	}
	switch args[0] {
	case "list":
		return sessionsList(args[1:])
	case "show":
		return sessionsShow(args[1:])
	case "delete":
		return sessionsDelete(args[1:])
	case "clear":
		return sessionsClear(args[1:])
	default:
		fmt.Fprintf(os.Stderr, "unknown sessions action: %s\n", args[0])
		return 2
	}
}

func sessionsList(args []string) int {
	fs := flag.NewFlagSet("sessions list", flag.ContinueOnError)
	asJSON := fs.Bool("json", false, "emit JSON array instead of a table")
	if err := fs.Parse(args); err != nil {
		return 2
	}
	store := sessions.NewStore(defaultSessionsBase())
	all, err := store.List()
	if err != nil {
		fmt.Fprintf(os.Stderr, "list: %v\n", err)
		return 1
	}
	if *asJSON {
		// Always emit a JSON array (never null) — easier for tooling to parse.
		if all == nil {
			all = []sessions.Manifest{}
		}
		buf, err := json.MarshalIndent(all, "", "  ")
		if err != nil {
			fmt.Fprintf(os.Stderr, "marshal: %v\n", err)
			return 1
		}
		fmt.Println(string(buf))
		return 0
	}
	w := tabwriter.NewWriter(os.Stdout, 0, 0, 2, ' ', 0)
	fmt.Fprintln(w, "ID\tPRESET\tDURATION\tCLEANED")
	for _, m := range all {
		preview := readTranscriptPreview(store.SessionDir(m.ID), m.Transcripts.Cleaned, 60)
		fmt.Fprintf(w, "%s\t%s\t%.2fs\t%s\n", m.ID, m.Preset, m.DurationSec, preview)
	}
	_ = w.Flush()
	return 0
}

func sessionsShow(args []string) int {
	fs := flag.NewFlagSet("sessions show", flag.ContinueOnError)
	asJSON := fs.Bool("json", false, "emit manifest JSON instead of human format")
	if err := fs.Parse(args); err != nil {
		return 2
	}
	if fs.NArg() != 1 {
		fmt.Fprintln(os.Stderr, "usage: howl sessions show [--json] <id>")
		return 2
	}
	id := fs.Arg(0)
	store := sessions.NewStore(defaultSessionsBase())
	m, err := store.Get(id)
	if err != nil {
		fmt.Fprintf(os.Stderr, "show: %v\n", err)
		return 1
	}
	if *asJSON {
		buf, err := json.MarshalIndent(m, "", "  ")
		if err != nil {
			fmt.Fprintf(os.Stderr, "marshal: %v\n", err)
			return 1
		}
		fmt.Println(string(buf))
		return 0
	}
	printSessionHuman(store.SessionDir(id), m)
	return 0
}

func sessionsDelete(args []string) int {
	fs := flag.NewFlagSet("sessions delete", flag.ContinueOnError)
	if err := fs.Parse(args); err != nil {
		return 2
	}
	if fs.NArg() != 1 {
		fmt.Fprintln(os.Stderr, "usage: howl sessions delete <id>")
		return 2
	}
	store := sessions.NewStore(defaultSessionsBase())
	if err := store.Delete(fs.Arg(0)); err != nil {
		fmt.Fprintf(os.Stderr, "delete: %v\n", err)
		return 1
	}
	return 0
}

func sessionsClear(args []string) int {
	fs := flag.NewFlagSet("sessions clear", flag.ContinueOnError)
	force := fs.Bool("force", false, "required to actually delete")
	if err := fs.Parse(args); err != nil {
		return 2
	}
	if !*force {
		fmt.Fprintln(os.Stderr, "refusing to clear without --force")
		return 2
	}
	store := sessions.NewStore(defaultSessionsBase())
	if err := store.Clear(); err != nil {
		fmt.Fprintf(os.Stderr, "clear: %v\n", err)
		return 1
	}
	return 0
}

// readTranscriptPreview reads up to max bytes from <sessionDir>/<rel>,
// returning a trimmed-with-ellipsis preview. Empty rel or read errors
// return "" — the table cell stays blank rather than surfacing an error.
func readTranscriptPreview(sessionDir, rel string, max int) string {
	if rel == "" {
		return ""
	}
	buf, err := os.ReadFile(filepath.Join(sessionDir, rel))
	if err != nil {
		return ""
	}
	s := string(buf)
	if len(s) > max {
		return s[:max] + "…"
	}
	return s
}

func printSessionHuman(sessionDir string, m *sessions.Manifest) {
	fmt.Printf("ID:           %s\n", m.ID)
	fmt.Printf("Preset:       %s\n", m.Preset)
	fmt.Printf("Duration:     %.2fs\n", m.DurationSec)
	fmt.Println("Stages:")
	for _, st := range m.Stages {
		fmt.Printf("  - %-12s kind=%-6s rate=%dHz wav=%s\n", st.Name, st.Kind, st.RateHz, st.WavRel)
	}
	if cleaned := readTranscriptPreview(sessionDir, m.Transcripts.Cleaned, 240); cleaned != "" {
		fmt.Printf("Cleaned:      %s\n", cleaned)
	}
}
