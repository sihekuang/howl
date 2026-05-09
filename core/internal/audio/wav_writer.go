package audio

import (
	"encoding/binary"
	"fmt"
	"math"
	"os"
)

// WriteWAVMono writes float32 samples as a mono LE 16-bit PCM WAV
// file at the given sample rate. Clamps to [-1, 1] then quantises
// to int16. Companion to ReadWAVMono.
func WriteWAVMono(path string, samples []float32, sampleRate int) error {
	if sampleRate <= 0 {
		return fmt.Errorf("wav: invalid sample rate %d", sampleRate)
	}
	f, err := os.Create(path)
	if err != nil {
		return err
	}
	defer f.Close()

	const bitsPerSample = 16
	const channels = 1
	dataLen := len(samples) * (bitsPerSample / 8)

	if _, err := f.Write([]byte("RIFF")); err != nil {
		return err
	}
	if err := binary.Write(f, binary.LittleEndian, uint32(36+dataLen)); err != nil {
		return err
	}
	if _, err := f.Write([]byte("WAVEfmt ")); err != nil {
		return err
	}
	if err := binary.Write(f, binary.LittleEndian, uint32(16)); err != nil {
		return err
	}
	if err := binary.Write(f, binary.LittleEndian, uint16(1)); err != nil { // PCM
		return err
	}
	if err := binary.Write(f, binary.LittleEndian, uint16(channels)); err != nil {
		return err
	}
	if err := binary.Write(f, binary.LittleEndian, uint32(sampleRate)); err != nil {
		return err
	}
	if err := binary.Write(f, binary.LittleEndian, uint32(sampleRate*channels*bitsPerSample/8)); err != nil {
		return err
	}
	if err := binary.Write(f, binary.LittleEndian, uint16(channels*bitsPerSample/8)); err != nil {
		return err
	}
	if err := binary.Write(f, binary.LittleEndian, uint16(bitsPerSample)); err != nil {
		return err
	}
	if _, err := f.Write([]byte("data")); err != nil {
		return err
	}
	if err := binary.Write(f, binary.LittleEndian, uint32(dataLen)); err != nil {
		return err
	}
	for _, s := range samples {
		if s > 1 {
			s = 1
		} else if s < -1 {
			s = -1
		}
		if err := binary.Write(f, binary.LittleEndian, int16(math.MaxInt16*s)); err != nil {
			return err
		}
	}
	return nil
}
