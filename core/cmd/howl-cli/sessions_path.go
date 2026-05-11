package main

import "os"

// defaultSessionsBase returns the on-disk root that the recorder and
// libhowl engine write to (and read from). HOWL_SESSIONS_DIR is honored
// for tests so they can route reads/writes to a tempdir without
// stomping on /tmp/voicekeyboard/sessions/.
func defaultSessionsBase() string {
	if dir := os.Getenv("HOWL_SESSIONS_DIR"); dir != "" {
		return dir
	}
	return "/tmp/voicekeyboard/sessions"
}
