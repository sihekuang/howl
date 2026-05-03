package presets

import (
	"encoding/json"
	"errors"
	"fmt"
	"log"
	"os"
	"path/filepath"
	"regexp"
	"strings"
)

// ErrReservedName is returned by SaveUserAt / DeleteUserAt when the
// caller tries to overwrite or delete a bundled preset.
var ErrReservedName = errors.New("presets: name collides with a bundled preset")

// ErrInvalidName is returned when the preset name doesn't match the
// allowed pattern (lowercase alphanumerics + dash/underscore, 1-40 chars).
var ErrInvalidName = errors.New("presets: invalid name (lowercase a-z0-9_-, 1-40 chars)")

var nameRE = regexp.MustCompile(`^[a-z0-9_-]{1,40}$`)

// reservedNames lists bundled preset names that user files must not
// shadow. Sourced from loadBundled at init so adding a bundled preset
// in JSON doesn't desync from the deny list.
var reservedNames = func() map[string]bool {
	out := map[string]bool{}
	if all, err := loadBundled(); err == nil {
		for _, p := range all {
			out[p.Name] = true
		}
	}
	return out
}()

// SaveUserAt writes preset p to <dir>/<name>.json. dir must exist.
// Returns ErrInvalidName for bad names, ErrReservedName if the name
// collides with a bundled preset.
func SaveUserAt(dir string, p Preset) error {
	if !nameRE.MatchString(p.Name) {
		return fmt.Errorf("%w: %q", ErrInvalidName, p.Name)
	}
	if reservedNames[p.Name] {
		return fmt.Errorf("%w: %q", ErrReservedName, p.Name)
	}
	buf, err := json.MarshalIndent(p, "", "  ")
	if err != nil {
		return fmt.Errorf("presets: marshal: %w", err)
	}
	return os.WriteFile(filepath.Join(dir, p.Name+".json"), buf, 0o644)
}

// LoadUserAt walks <dir>/*.json and returns the parsed presets. Files
// that fail to parse are skipped with a logged warning — one bad file
// doesn't break the picker.
func LoadUserAt(dir string) ([]Preset, error) {
	entries, err := os.ReadDir(dir)
	if err != nil {
		if errors.Is(err, os.ErrNotExist) {
			return nil, nil
		}
		return nil, fmt.Errorf("presets: read user dir: %w", err)
	}
	out := make([]Preset, 0, len(entries))
	for _, ent := range entries {
		if ent.IsDir() || !strings.HasSuffix(ent.Name(), ".json") {
			continue
		}
		path := filepath.Join(dir, ent.Name())
		buf, err := os.ReadFile(path)
		if err != nil {
			log.Printf("[vkb] presets: skipping %s: %v", path, err)
			continue
		}
		var p Preset
		if err := json.Unmarshal(buf, &p); err != nil {
			log.Printf("[vkb] presets: skipping %s: parse: %v", path, err)
			continue
		}
		out = append(out, p)
	}
	return out, nil
}

// DeleteUserAt removes <dir>/<name>.json. Idempotent: removing a
// non-existent name returns nil. Refuses to delete a bundled preset
// name (those don't live on disk anyway, so this is purely defensive).
func DeleteUserAt(dir, name string) error {
	if reservedNames[name] {
		return fmt.Errorf("%w: %q", ErrReservedName, name)
	}
	if !nameRE.MatchString(name) {
		return fmt.Errorf("%w: %q", ErrInvalidName, name)
	}
	err := os.Remove(filepath.Join(dir, name+".json"))
	if err != nil && !errors.Is(err, os.ErrNotExist) {
		return fmt.Errorf("presets: delete %q: %w", name, err)
	}
	return nil
}

// Load returns the union of bundled + user presets, bundled first.
// Used by the C ABI / CLI; production callers want this. Tests use the
// per-dir variants for isolation.
//
// User presets are loaded from `~/Library/Application Support/VoiceKeyboard/presets/`
// on macOS. Errors loading user presets are logged but not returned —
// the bundled list is always available even if disk is unreadable.
func Load() ([]Preset, error) {
	all, err := loadBundled()
	if err != nil {
		return nil, err
	}
	dir, err := defaultUserDir()
	if err != nil {
		log.Printf("[vkb] presets.Load: no user dir (%v); bundled only", err)
		return all, nil
	}
	user, err := LoadUserAt(dir)
	if err != nil {
		log.Printf("[vkb] presets.Load: LoadUserAt(%s): %v; bundled only", dir, err)
		return all, nil
	}
	// Skip user presets whose name collides with a bundled name —
	// bundled wins, by construction.
	seen := map[string]bool{}
	for _, p := range all {
		seen[p.Name] = true
	}
	for _, p := range user {
		if seen[p.Name] {
			log.Printf("[vkb] presets.Load: skipping user preset %q (collides with bundled)", p.Name)
			continue
		}
		all = append(all, p)
	}
	return all, nil
}

// defaultUserDir returns the on-disk location for user presets. Creates
// it if missing so the first save succeeds.
//
// Honors VKB_PRESETS_USER_DIR for tests so they can route writes away
// from the real ~/Library location.
func defaultUserDir() (string, error) {
	if dir := os.Getenv("VKB_PRESETS_USER_DIR"); dir != "" {
		if err := os.MkdirAll(dir, 0o755); err != nil {
			return "", err
		}
		return dir, nil
	}
	home, err := os.UserHomeDir()
	if err != nil {
		return "", err
	}
	dir := filepath.Join(home, "Library", "Application Support", "VoiceKeyboard", "presets")
	if err := os.MkdirAll(dir, 0o755); err != nil {
		return "", err
	}
	return dir, nil
}

// SaveUser saves to defaultUserDir.
func SaveUser(p Preset) error {
	dir, err := defaultUserDir()
	if err != nil {
		return err
	}
	return SaveUserAt(dir, p)
}

// DeleteUser deletes from defaultUserDir.
func DeleteUser(name string) error {
	dir, err := defaultUserDir()
	if err != nil {
		return err
	}
	return DeleteUserAt(dir, name)
}
