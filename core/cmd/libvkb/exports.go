package main

/*
#include <stdlib.h>
*/
import "C"

import (
	"context"
	"encoding/json"
	"unsafe"

	"github.com/voice-keyboard/core/internal/config"
)

//export vkb_init
func vkb_init() C.int {
	if getEngine() != nil {
		return 0
	}
	setEngine(&engine{events: make(chan event, 32)})
	return 0
}

//export vkb_configure
func vkb_configure(jsonC *C.char) C.int {
	e := getEngine()
	if e == nil {
		return 1
	}
	gostr := C.GoString(jsonC)
	var cfg config.Config
	if err := json.Unmarshal([]byte(gostr), &cfg); err != nil {
		e.setLastError("vkb_configure: " + err.Error())
		return 2
	}
	config.WithDefaults(&cfg)
	e.mu.Lock()
	e.cfg = cfg
	e.mu.Unlock()
	if err := e.buildPipeline(); err != nil {
		e.setLastError("vkb_configure: " + err.Error())
		return 3
	}
	return 0
}

//export vkb_start_capture
func vkb_start_capture() C.int {
	e := getEngine()
	if e == nil || e.pipeline == nil {
		return 1
	}
	e.mu.Lock()
	if e.stopCh != nil {
		e.mu.Unlock()
		return 2
	}
	stopCh := make(chan struct{})
	ctx, cancel := context.WithCancel(context.Background())
	e.stopCh = stopCh
	e.cancel = cancel
	e.mu.Unlock()

	go func() {
		res, err := e.pipeline.Run(ctx, stopCh)
		if err != nil {
			select {
			case e.events <- event{Kind: "error", Msg: err.Error()}:
			default:
			}
			return
		}
		ev := event{Kind: "result", Text: res.Cleaned}
		select {
		case e.events <- ev:
		default:
		}
	}()
	return 0
}

//export vkb_stop_capture
func vkb_stop_capture() C.int {
	e := getEngine()
	if e == nil {
		return 1
	}
	e.mu.Lock()
	defer e.mu.Unlock()
	if e.stopCh != nil {
		close(e.stopCh)
		e.stopCh = nil
	}
	if e.cancel != nil {
		e.cancel = nil
	}
	return 0
}

//export vkb_poll_event
func vkb_poll_event() *C.char {
	e := getEngine()
	if e == nil {
		return nil
	}
	select {
	case ev := <-e.events:
		buf, err := json.Marshal(ev)
		if err != nil {
			return nil
		}
		return C.CString(string(buf))
	default:
		return nil
	}
}

//export vkb_destroy
func vkb_destroy() {
	e := getEngine()
	if e == nil {
		return
	}
	_ = vkb_stop_capture()
	setEngine(nil)
}

//export vkb_last_error
func vkb_last_error() *C.char {
	e := getEngine()
	if e == nil {
		return nil
	}
	e.mu.Lock()
	defer e.mu.Unlock()
	if e.lastErr == "" {
		return nil
	}
	return C.CString(e.lastErr)
}

//export vkb_free_string
func vkb_free_string(s *C.char) {
	if s != nil {
		C.free(unsafe.Pointer(s))
	}
}
