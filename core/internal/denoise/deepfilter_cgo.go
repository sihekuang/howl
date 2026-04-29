//go:build deepfilter

package denoise

/*
#cgo CFLAGS: -I${SRCDIR}/../../third_party/deepfilter/include
#cgo LDFLAGS: -L${SRCDIR}/../../third_party/deepfilter/lib/macos-arm64 -ldf
#include <stdlib.h>
#include "deep_filter.h"
*/
import "C"

import (
	"errors"
	"runtime"
	"unsafe"
)

const defaultAttenLimDB = 100.0 // no attenuation cap; let the network decide

// DeepFilter wraps a libdf state. Each instance is single-threaded;
// concurrent callers must serialize externally or construct one per
// goroutine.
type DeepFilter struct {
	state *C.DFState
}

// NewDeepFilter constructs a denoiser from a DeepFilterNet model archive
// (.tar.gz file or unpacked directory). attenLimDB caps how much gain
// reduction the network applies; pass defaultAttenLimDB (100) for no cap.
func NewDeepFilter(modelPath string, attenLimDB float32) (*DeepFilter, error) {
	if modelPath == "" {
		return nil, errors.New("deep filter: modelPath is required")
	}
	cPath := C.CString(modelPath)
	defer C.free(unsafe.Pointer(cPath))

	st := C.df_create(cPath, C.float(attenLimDB))
	if st == nil {
		return nil, errors.New("deep filter: df_create returned NULL (bad model path?)")
	}
	if got := C.df_get_frame_length(st); int(got) != FrameSize {
		C.df_free(st)
		return nil, errors.New("deep filter: unexpected frame length from libdf")
	}

	d := &DeepFilter{state: st}
	runtime.SetFinalizer(d, func(d *DeepFilter) { _ = d.Close() })
	return d, nil
}

func (d *DeepFilter) Process(frame []float32) []float32 {
	if d.state == nil || len(frame) != FrameSize {
		out := make([]float32, len(frame))
		copy(out, frame)
		return out
	}
	out := make([]float32, FrameSize)
	C.df_process_frame(
		d.state,
		(*C.float)(unsafe.Pointer(&frame[0])),
		(*C.float)(unsafe.Pointer(&out[0])),
	)
	return out
}

func (d *DeepFilter) Close() error {
	if d.state != nil {
		C.df_free(d.state)
		d.state = nil
	}
	return nil
}
