package audio

import (
	"encoding/binary"
	"fmt"
	"math"
	"os"
)

// ReadWAVMono loads a 16-bit PCM mono WAV file into []float32.
// Returns the samples and the sample rate from the fmt chunk.
// Walks the RIFF chunk list so optional LIST/INFO chunks before the
// data chunk don't trip up parsing.
func ReadWAVMono(path string) ([]float32, int, error) {
	data, err := os.ReadFile(path)
	if err != nil {
		return nil, 0, err
	}
	if len(data) < 44 || string(data[0:4]) != "RIFF" || string(data[8:12]) != "WAVE" {
		return nil, 0, fmt.Errorf("wav: not a RIFF/WAVE file: %s", path)
	}
	var sampleRate, channels, bitsPerSample int
	var pcm []byte
	for i := 12; i+8 <= len(data); {
		id := string(data[i : i+4])
		size := int(binary.LittleEndian.Uint32(data[i+4 : i+8]))
		if i+8+size > len(data) {
			return nil, 0, fmt.Errorf("wav: chunk %q overruns file", id)
		}
		switch id {
		case "fmt ":
			if size < 16 {
				return nil, 0, fmt.Errorf("wav: fmt chunk too small: %d", size)
			}
			channels = int(binary.LittleEndian.Uint16(data[i+10 : i+12]))
			sampleRate = int(binary.LittleEndian.Uint32(data[i+12 : i+16]))
			bitsPerSample = int(binary.LittleEndian.Uint16(data[i+22 : i+24]))
		case "data":
			pcm = data[i+8 : i+8+size]
		}
		next := i + 8 + size
		if size%2 == 1 {
			next++
		}
		i = next
		if pcm != nil && sampleRate != 0 {
			break
		}
	}
	if sampleRate == 0 || pcm == nil {
		return nil, 0, fmt.Errorf("wav: missing fmt or data chunk")
	}
	if channels != 1 || bitsPerSample != 16 {
		return nil, 0, fmt.Errorf("wav: only mono 16-bit PCM supported (got channels=%d bits=%d)", channels, bitsPerSample)
	}
	samples := make([]float32, len(pcm)/2)
	for j := range samples {
		v := int16(binary.LittleEndian.Uint16(pcm[j*2 : j*2+2]))
		samples[j] = float32(v) / float32(math.MaxInt16)
	}
	return samples, sampleRate, nil
}
