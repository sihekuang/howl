//go:build whispercpp

package main

/*
#include <stdlib.h>
*/
import "C"

import (
	"encoding/json"
	"unsafe"

	"github.com/voice-keyboard/core/internal/sessions"
)

// sessionListGo calls vkb_list_sessions and decodes the result into a
// Go slice. Returns nil slice (not an error) when the engine is not
// initialized. Used by tests.
func sessionListGo() ([]sessions.Manifest, error) {
	cstr := vkb_list_sessions()
	if cstr == nil {
		return nil, nil
	}
	defer C.free(unsafe.Pointer(cstr))
	var out []sessions.Manifest
	if err := json.Unmarshal([]byte(C.GoString(cstr)), &out); err != nil {
		return nil, err
	}
	return out, nil
}

// sessionGetGo calls vkb_get_session and decodes the result.
// Returns nil manifest (not an error) when the session does not exist.
func sessionGetGo(id string) (*sessions.Manifest, error) {
	idC := C.CString(id)
	defer C.free(unsafe.Pointer(idC))
	cstr := vkb_get_session(idC)
	if cstr == nil {
		return nil, nil
	}
	defer C.free(unsafe.Pointer(cstr))
	var m sessions.Manifest
	if err := json.Unmarshal([]byte(C.GoString(cstr)), &m); err != nil {
		return nil, err
	}
	return &m, nil
}

// sessionDeleteGo calls vkb_delete_session with a Go string id.
// Returns the raw C return code (0, 1, 5, 6).
func sessionDeleteGo(id string) int {
	idC := C.CString(id)
	defer C.free(unsafe.Pointer(idC))
	return int(vkb_delete_session(idC))
}
