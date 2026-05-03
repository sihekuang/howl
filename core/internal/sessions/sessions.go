package sessions

import (
	"errors"
	"fmt"
	"log"
	"os"
	"path/filepath"
	"sort"
	"strings"
)

// Store owns the on-disk session folder layout under a base directory
// (typically /tmp/voicekeyboard/sessions/). All operations are safe to
// call when base does not exist — they treat that as "no sessions".
type Store struct {
	base string
}

// NewStore returns a Store rooted at the given base directory. The
// directory is created lazily on first write; List/Get on a missing
// base returns the empty/error result without complaint.
func NewStore(base string) *Store {
	return &Store{base: base}
}

// Base returns the underlying base directory. Useful for callers that
// need to construct child paths (e.g. the recorder).
func (s *Store) Base() string { return s.base }

// SessionDir returns the absolute path to a session folder.
func (s *Store) SessionDir(id string) string {
	return filepath.Join(s.base, id)
}

// List returns all valid sessions newest-first. Folders without a
// session.json are silently skipped. Folders with a corrupt manifest
// are skipped + logged, but never fail the whole list.
func (s *Store) List() ([]Manifest, error) {
	entries, err := os.ReadDir(s.base)
	if err != nil {
		if errors.Is(err, os.ErrNotExist) {
			return nil, nil
		}
		return nil, fmt.Errorf("sessions: read base: %w", err)
	}
	out := make([]Manifest, 0, len(entries))
	for _, ent := range entries {
		if !ent.IsDir() {
			continue
		}
		dir := filepath.Join(s.base, ent.Name())
		m, err := Read(dir)
		if err != nil {
			// Tolerant: missing manifest = unfinished session = skip silently.
			// Other errors (corrupt JSON, unknown version) are logged so
			// the user sees them in /tmp/vkb.log but the picker still works.
			if !errors.Is(err, ErrManifestNotFound) {
				log.Printf("[vkb] sessions.List: skipping %s: %v", dir, err)
			}
			continue
		}
		out = append(out, *m)
	}
	// Newest first by ID (which is an RFC3339 timestamp; lexical sort = chronological sort).
	sort.Slice(out, func(i, j int) bool { return out[i].ID > out[j].ID })
	return out, nil
}

// Get returns the manifest for a single session. Returns an error if
// the session does not exist or its manifest is unreadable.
func (s *Store) Get(id string) (*Manifest, error) {
	if !validSessionID(id) {
		return nil, fmt.Errorf("sessions: invalid id %q", id)
	}
	return Read(s.SessionDir(id))
}

// Delete removes a single session folder. Idempotent: deleting a
// nonexistent ID is a no-op, not an error. Rejects IDs that look like
// path traversal — defense-in-depth, the C ABI is not the place to
// trust caller input.
func (s *Store) Delete(id string) error {
	if !validSessionID(id) {
		return fmt.Errorf("sessions: invalid id %q", id)
	}
	dir := filepath.Join(s.base, id)
	err := os.RemoveAll(dir)
	if err != nil && !errors.Is(err, os.ErrNotExist) {
		return fmt.Errorf("sessions: delete %q: %w", id, err)
	}
	return nil
}

// Clear removes every session folder under base. Base directory itself
// is preserved (recreated empty if it already existed).
func (s *Store) Clear() error {
	entries, err := os.ReadDir(s.base)
	if err != nil {
		if errors.Is(err, os.ErrNotExist) {
			return nil
		}
		return fmt.Errorf("sessions: read base: %w", err)
	}
	for _, ent := range entries {
		if !ent.IsDir() {
			continue
		}
		if err := os.RemoveAll(filepath.Join(s.base, ent.Name())); err != nil {
			return fmt.Errorf("sessions: clear %q: %w", ent.Name(), err)
		}
	}
	return nil
}

// Prune keeps the keep-most-recent sessions and removes the rest.
// keep <= 0 is treated as "remove nothing" (defensive — never want a
// caller bug to wipe the whole list). When the existing count is at or
// below keep, Prune is a no-op.
func (s *Store) Prune(keep int) error {
	if keep <= 0 {
		return nil
	}
	all, err := s.List()
	if err != nil {
		return err
	}
	if len(all) <= keep {
		return nil
	}
	// List returns newest-first; older sessions live at the tail.
	for _, m := range all[keep:] {
		if err := s.Delete(m.ID); err != nil {
			return err
		}
	}
	return nil
}

// validSessionID enforces a conservative whitelist for IDs we will
// translate into filesystem paths. Allows the digits, dashes, colons,
// and 'T'/'Z' that RFC3339 timestamps use, plus optional fractional
// seconds (period). Rejects path-separator characters and ".." etc.
func validSessionID(id string) bool {
	if id == "" || id == "." || id == ".." {
		return false
	}
	if strings.ContainsAny(id, `/\`+"\x00") {
		return false
	}
	for _, r := range id {
		switch {
		case r >= '0' && r <= '9',
			r >= 'A' && r <= 'Z',
			r >= 'a' && r <= 'z',
			r == '-' || r == ':' || r == '.' || r == '_':
			// ok
		default:
			return false
		}
	}
	return true
}
