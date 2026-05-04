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

// abiVersionGo is a test-friendly wrapper around vkb_abi_version that
// returns a Go string. Avoids the "import \"C\" not allowed in test
// files" rule by living in a non-_test.go file alongside the other
// session helpers.
func abiVersionGo() string {
	cstr := vkb_abi_version()
	defer vkb_free_string(cstr)
	return C.GoString(cstr)
}

// presetListGo wraps vkb_list_presets and returns the JSON body as a
// Go string (empty if nil/error).
func presetListGo() string {
	cstr := vkb_list_presets()
	if cstr == nil {
		return ""
	}
	defer vkb_free_string(cstr)
	return C.GoString(cstr)
}

// presetGetGo wraps vkb_get_preset.
func presetGetGo(name string) string {
	cn := C.CString(name)
	defer C.free(unsafe.Pointer(cn))
	cstr := vkb_get_preset(cn)
	if cstr == nil {
		return ""
	}
	defer vkb_free_string(cstr)
	return C.GoString(cstr)
}

// presetSaveGo wraps vkb_save_preset. body is a JSON-encoded Preset.
func presetSaveGo(name, description, body string) int {
	cn := C.CString(name)
	cd := C.CString(description)
	cb := C.CString(body)
	defer C.free(unsafe.Pointer(cn))
	defer C.free(unsafe.Pointer(cd))
	defer C.free(unsafe.Pointer(cb))
	return int(vkb_save_preset(cn, cd, cb))
}

// presetDeleteGo wraps vkb_delete_preset.
func presetDeleteGo(name string) int {
	cn := C.CString(name)
	defer C.free(unsafe.Pointer(cn))
	return int(vkb_delete_preset(cn))
}

// replayGo wraps vkb_replay and returns the JSON string.
func replayGo(sourceID, presetsCSV string) string {
	csid := C.CString(sourceID)
	ccsv := C.CString(presetsCSV)
	defer C.free(unsafe.Pointer(csid))
	defer C.free(unsafe.Pointer(ccsv))
	cstr := vkb_replay(csid, ccsv)
	if cstr == nil {
		return ""
	}
	defer vkb_free_string(cstr)
	return C.GoString(cstr)
}
