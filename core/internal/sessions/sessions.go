package sessions

import (
	"errors"
	"fmt"
	"log"
	"os"
	"path/filepath"
	"sort"
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
	return Read(s.SessionDir(id))
}
