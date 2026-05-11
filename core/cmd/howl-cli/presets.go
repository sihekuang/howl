package main

import (
	"encoding/json"
	"errors"
	"flag"
	"fmt"
	"os"
	"path/filepath"
	"text/tabwriter"

	"github.com/voice-keyboard/core/internal/presets"
	"github.com/voice-keyboard/core/internal/sessions"
)

// runPresets dispatches `howl-cli presets <action>` to per-action helpers.
// All actions return:
//   - 0 on success
//   - 1 on runtime/IO error
//   - 2 on usage / validation error
func runPresets(args []string) int {
	if len(args) == 0 {
		fmt.Fprintln(os.Stderr, "usage: howl-cli presets {list|show|save|delete} ...")
		return 2
	}
	switch args[0] {
	case "list":
		return presetsList(args[1:])
	case "show":
		return presetsShow(args[1:])
	case "save":
		return presetsSave(args[1:])
	case "delete":
		return presetsDelete(args[1:])
	default:
		fmt.Fprintf(os.Stderr, "unknown presets action: %s\n", args[0])
		return 2
	}
}

func presetsList(args []string) int {
	fs := flag.NewFlagSet("presets list", flag.ContinueOnError)
	asJSON := fs.Bool("json", false, "emit JSON array instead of a table")
	if err := fs.Parse(args); err != nil {
		return 2
	}
	all, err := presets.Load()
	if err != nil {
		fmt.Fprintf(os.Stderr, "load presets: %v\n", err)
		return 1
	}
	if *asJSON {
		buf, err := json.MarshalIndent(all, "", "  ")
		if err != nil {
			fmt.Fprintf(os.Stderr, "marshal: %v\n", err)
			return 1
		}
		fmt.Println(string(buf))
		return 0
	}
	bundled := bundledNameSet()
	w := tabwriter.NewWriter(os.Stdout, 0, 0, 2, ' ', 0)
	fmt.Fprintln(w, "NAME\tSOURCE\tDESCRIPTION")
	for _, p := range all {
		source := "user"
		if bundled[p.Name] {
			source = "bundled"
		}
		fmt.Fprintf(w, "%s\t%s\t%s\n", p.Name, source, p.Description)
	}
	_ = w.Flush()
	return 0
}

func presetsShow(args []string) int {
	fs := flag.NewFlagSet("presets show", flag.ContinueOnError)
	asJSON := fs.Bool("json", false, "emit preset JSON instead of human format")
	if err := fs.Parse(args); err != nil {
		return 2
	}
	if fs.NArg() != 1 {
		fmt.Fprintln(os.Stderr, "usage: howl-cli presets show <name> [--json]")
		return 2
	}
	name := fs.Arg(0)
	p, err := lookupPreset(name)
	if err != nil {
		fmt.Fprintf(os.Stderr, "%v\n", err)
		return 1
	}
	if *asJSON {
		buf, err := json.MarshalIndent(p, "", "  ")
		if err != nil {
			fmt.Fprintf(os.Stderr, "marshal: %v\n", err)
			return 1
		}
		fmt.Println(string(buf))
		return 0
	}
	printPresetHuman(p)
	return 0
}

func presetsSave(args []string) int {
	fs := flag.NewFlagSet("presets save", flag.ContinueOnError)
	desc := fs.String("description", "", "preset description (overrides cloned source)")
	from := fs.String("from", "", "session id to clone preset from (otherwise clones bundled 'default')")
	if err := fs.Parse(args); err != nil {
		return 2
	}
	if fs.NArg() != 1 {
		fmt.Fprintln(os.Stderr, "usage: howl-cli presets save <name> [--description \"...\"] [--from <session-id>]")
		return 2
	}
	name := fs.Arg(0)

	var src presets.Preset
	if *from != "" {
		store := sessions.NewStore(defaultSessionsBase())
		m, err := store.Get(*from)
		if err != nil {
			fmt.Fprintf(os.Stderr, "session %q: %v\n", *from, err)
			return 1
		}
		clone, err := lookupPreset(m.Preset)
		if err != nil {
			fmt.Fprintf(os.Stderr, "session %q referenced preset %q which is unavailable: %v\n", *from, m.Preset, err)
			return 1
		}
		src = clone
	} else {
		clone, err := lookupPreset("default")
		if err != nil {
			fmt.Fprintf(os.Stderr, "load default preset: %v\n", err)
			return 1
		}
		src = clone
	}

	src.Name = name
	if *desc != "" {
		src.Description = *desc
	}

	if err := presets.SaveUser(src); err != nil {
		fmt.Fprintf(os.Stderr, "save: %v\n", err)
		if errors.Is(err, presets.ErrInvalidName) || errors.Is(err, presets.ErrReservedName) {
			return 2
		}
		return 1
	}
	dir := userPresetsDirForReport()
	fmt.Fprintf(os.Stderr, "[howl] saved user preset %q to %s\n", name, filepath.Join(dir, name+".json"))
	return 0
}

func presetsDelete(args []string) int {
	fs := flag.NewFlagSet("presets delete", flag.ContinueOnError)
	if err := fs.Parse(args); err != nil {
		return 2
	}
	if fs.NArg() != 1 {
		fmt.Fprintln(os.Stderr, "usage: howl-cli presets delete <name>")
		return 2
	}
	name := fs.Arg(0)
	if err := presets.DeleteUser(name); err != nil {
		fmt.Fprintf(os.Stderr, "delete: %v\n", err)
		if errors.Is(err, presets.ErrInvalidName) || errors.Is(err, presets.ErrReservedName) {
			return 2
		}
		return 1
	}
	return 0
}

// lookupPreset returns the named preset (bundled or user). Errors with a
// human-friendly message when the name is unknown.
func lookupPreset(name string) (presets.Preset, error) {
	all, err := presets.Load()
	if err != nil {
		return presets.Preset{}, fmt.Errorf("load presets: %w", err)
	}
	for _, p := range all {
		if p.Name == name {
			return p, nil
		}
	}
	return presets.Preset{}, fmt.Errorf("preset not found: %q", name)
}

// bundledNameSet enumerates bundled names so the 'list' table can mark
// each row's source. The presets package keeps reservedNames unexported,
// so we hard-code the bundled names for cosmetic labelling. Real
// validation lives in presets.SaveUser which checks reservedNames itself.
func bundledNameSet() map[string]bool {
	return map[string]bool{
		"default":    true,
		"minimal":    true,
		"aggressive": true,
		"paranoid":   true,
	}
}

// userPresetsDirForReport returns the directory the save message should
// reference. Mirrors presets.defaultUserDir() lookup logic so the message
// shows the actual on-disk path the user can inspect.
func userPresetsDirForReport() string {
	if dir := os.Getenv("HOWL_PRESETS_USER_DIR"); dir != "" {
		return dir
	}
	home, err := os.UserHomeDir()
	if err != nil {
		return "<user dir>"
	}
	return filepath.Join(home, "Library", "Application Support", "VoiceKeyboard", "presets")
}

func printPresetHuman(p presets.Preset) {
	fmt.Printf("Name:        %s\n", p.Name)
	fmt.Printf("Description: %s\n", p.Description)
	if p.TimeoutSec != nil {
		fmt.Printf("Timeout:     %ds\n", *p.TimeoutSec)
	} else {
		fmt.Println("Timeout:     (unset; engine default)")
	}
	fmt.Printf("Transcribe:  model_size=%s\n", p.Transcribe.ModelSize)
	fmt.Printf("LLM:         provider=%s\n", p.LLM.Provider)
	fmt.Println("Frame stages:")
	for _, st := range p.FrameStages {
		fmt.Printf("  - %-10s enabled=%t\n", st.Name, st.Enabled)
	}
	fmt.Println("Chunk stages:")
	for _, st := range p.ChunkStages {
		thr := "(unset)"
		if st.Threshold != nil {
			thr = fmt.Sprintf("%.2f", *st.Threshold)
		}
		fmt.Printf("  - %-10s enabled=%t backend=%s threshold=%s\n", st.Name, st.Enabled, st.Backend, thr)
	}
}
