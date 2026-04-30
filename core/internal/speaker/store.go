package speaker

import (
	"bytes"
	"encoding/binary"
	"encoding/json"
	"fmt"
	"os"
	"path/filepath"
	"time"
)

// Profile holds enrollment metadata and the path to the reference audio file.
type Profile struct {
	Version    int       `json:"version"`
	RefAudio   string    `json:"ref_audio"`
	EnrolledAt time.Time `json:"enrolled_at"`
	DurationS  float64   `json:"duration_s"`
}

// WriteProfileTo writes a Profile to an explicit path as JSON. Used directly
// when the caller needs to write to a temp file for atomic rename; SaveProfile
// is the convenience form for the canonical <dir>/speaker.json location.
func WriteProfileTo(path string, p Profile) error {
	data, err := json.MarshalIndent(p, "", "  ")
	if err != nil {
		return fmt.Errorf("store: marshal profile: %w", err)
	}
	return os.WriteFile(path, data, 0600)
}

// SaveProfile writes speaker.json to dir.
func SaveProfile(dir string, p Profile) error {
	return WriteProfileTo(filepath.Join(dir, "speaker.json"), p)
}

// LoadProfile reads speaker.json from dir. Returns an error if the file is absent.
func LoadProfile(dir string) (Profile, error) {
	data, err := os.ReadFile(filepath.Join(dir, "speaker.json"))
	if err != nil {
		return Profile{}, fmt.Errorf("store: read profile: %w", err)
	}
	var p Profile
	if err := json.Unmarshal(data, &p); err != nil {
		return Profile{}, fmt.Errorf("store: unmarshal profile: %w", err)
	}
	return p, nil
}

// SaveEmbedding writes a float32 embedding slice to path as raw little-endian binary.
func SaveEmbedding(path string, emb []float32) error {
	f, err := os.Create(path)
	if err != nil {
		return fmt.Errorf("store: create embedding: %w", err)
	}
	defer f.Close()
	return binary.Write(f, binary.LittleEndian, emb)
}

// LoadEmbedding reads a raw float32 little-endian binary written by SaveEmbedding
// (or by compute_enrollment_embedding.py).
func LoadEmbedding(path string) ([]float32, error) {
	data, err := os.ReadFile(path)
	if err != nil {
		return nil, fmt.Errorf("store: read embedding: %w", err)
	}
	if len(data)%4 != 0 {
		return nil, fmt.Errorf("store: embedding file size %d not a multiple of 4", len(data))
	}
	emb := make([]float32, len(data)/4)
	if err := binary.Read(bytes.NewReader(data), binary.LittleEndian, emb); err != nil {
		return nil, fmt.Errorf("store: decode embedding: %w", err)
	}
	return emb, nil
}

// SaveWAV writes samples as a 16kHz mono IEEE float32 WAV to path.
func SaveWAV(path string, samples []float32, sampleRate int) error {
	f, err := os.Create(path)
	if err != nil {
		return fmt.Errorf("store: create wav: %w", err)
	}
	defer f.Close()

	dataSize := uint32(len(samples) * 4)
	hdr := wavHeader{
		ChunkID:       [4]byte{'R', 'I', 'F', 'F'},
		ChunkSize:     36 + dataSize,
		Format:        [4]byte{'W', 'A', 'V', 'E'},
		Subchunk1ID:   [4]byte{'f', 'm', 't', ' '},
		Subchunk1Size: 16,
		AudioFormat:   3, // IEEE_FLOAT
		NumChannels:   1,
		SampleRate:    uint32(sampleRate),
		ByteRate:      uint32(sampleRate) * 4,
		BlockAlign:    4,
		BitsPerSample: 32,
		Subchunk2ID:   [4]byte{'d', 'a', 't', 'a'},
		Subchunk2Size: dataSize,
	}
	if err := binary.Write(f, binary.LittleEndian, hdr); err != nil {
		return fmt.Errorf("store: write wav header: %w", err)
	}
	if err := binary.Write(f, binary.LittleEndian, samples); err != nil {
		return fmt.Errorf("store: write wav data: %w", err)
	}
	return nil
}

// LoadWAV reads float32 samples from a WAV written by SaveWAV.
func LoadWAV(path string) ([]float32, error) {
	f, err := os.Open(path)
	if err != nil {
		return nil, fmt.Errorf("store: open wav: %w", err)
	}
	defer f.Close()

	var hdr wavHeader
	if err := binary.Read(f, binary.LittleEndian, &hdr); err != nil {
		return nil, fmt.Errorf("store: read wav header: %w", err)
	}
	n := int(hdr.Subchunk2Size) / 4
	samples := make([]float32, n)
	if err := binary.Read(f, binary.LittleEndian, samples); err != nil {
		return nil, fmt.Errorf("store: read wav data: %w", err)
	}
	return samples, nil
}

type wavHeader struct {
	ChunkID       [4]byte
	ChunkSize     uint32
	Format        [4]byte
	Subchunk1ID   [4]byte
	Subchunk1Size uint32
	AudioFormat   uint16
	NumChannels   uint16
	SampleRate    uint32
	ByteRate      uint32
	BlockAlign    uint16
	BitsPerSample uint16
	Subchunk2ID   [4]byte
	Subchunk2Size uint32
}
