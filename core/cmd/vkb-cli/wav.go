package main

import (
	"encoding/binary"
	"io"
	"math"
	"os"
)

// writeWavMonoFloat writes float32 PCM samples as 16-bit signed PCM WAV.
// Whisper expects 16-bit at 16kHz; for capture we keep 48kHz so users
// can hear what was recorded, which is fine — file is just a debug aid.
func writeWavMonoFloat(path string, samples []float32, sampleRate int) error {
	f, err := os.Create(path)
	if err != nil {
		return err
	}
	defer f.Close()

	const bitsPerSample = 16
	const channels = 1

	dataLen := len(samples) * (bitsPerSample / 8)
	chunkLen := 36 + dataLen

	w := f
	if _, err := w.Write([]byte("RIFF")); err != nil {
		return err
	}
	binary.Write(w, binary.LittleEndian, uint32(chunkLen))
	w.Write([]byte("WAVEfmt "))
	binary.Write(w, binary.LittleEndian, uint32(16))                        // fmt chunk size
	binary.Write(w, binary.LittleEndian, uint16(1))                         // PCM
	binary.Write(w, binary.LittleEndian, uint16(channels))
	binary.Write(w, binary.LittleEndian, uint32(sampleRate))
	binary.Write(w, binary.LittleEndian, uint32(sampleRate*channels*bitsPerSample/8))
	binary.Write(w, binary.LittleEndian, uint16(channels*bitsPerSample/8))
	binary.Write(w, binary.LittleEndian, uint16(bitsPerSample))
	w.Write([]byte("data"))
	binary.Write(w, binary.LittleEndian, uint32(dataLen))
	for _, s := range samples {
		v := int16(math.MaxInt16 * clamp(s, -1, 1))
		binary.Write(w, binary.LittleEndian, v)
	}
	return nil
}

func clamp(v, lo, hi float32) float32 {
	if v < lo {
		return lo
	}
	if v > hi {
		return hi
	}
	return v
}

// readWavMonoFloat reads a 16-bit PCM mono WAV into float32. Walks RIFF
// chunks properly so files with LIST/INFO chunks before "data" work.
func readWavMonoFloat(path string) ([]float32, int, error) {
	f, err := os.Open(path)
	if err != nil {
		return nil, 0, err
	}
	defer f.Close()
	data, err := io.ReadAll(f)
	if err != nil {
		return nil, 0, err
	}
	if len(data) < 44 {
		return nil, 0, os.ErrInvalid
	}
	if string(data[0:4]) != "RIFF" || string(data[8:12]) != "WAVE" {
		return nil, 0, os.ErrInvalid
	}
	sampleRate := int(binary.LittleEndian.Uint32(data[24:28]))

	// Walk chunks starting at offset 12, looking for "data".
	for i := 12; i+8 <= len(data); {
		chunkID := string(data[i : i+4])
		size := int(binary.LittleEndian.Uint32(data[i+4 : i+8]))
		if chunkID == "data" {
			if i+8+size > len(data) {
				return nil, 0, os.ErrInvalid
			}
			pcm := data[i+8 : i+8+size]
			samples := make([]float32, len(pcm)/2)
			for j := range samples {
				v := int16(binary.LittleEndian.Uint16(pcm[j*2 : j*2+2]))
				samples[j] = float32(v) / float32(math.MaxInt16)
			}
			return samples, sampleRate, nil
		}
		next := i + 8 + size
		if size%2 == 1 {
			next++ // RIFF chunks are word-aligned; pad odd sizes
		}
		if next <= i {
			return nil, 0, os.ErrInvalid
		}
		i = next
	}
	return nil, 0, os.ErrInvalid
}
