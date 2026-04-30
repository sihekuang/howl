package speaker

import (
	"fmt"

	ort "github.com/yalue/onnxruntime_go"
)

// ComputeEmbedding runs speaker_encoder.onnx on samples (16 kHz mono PCM)
// and returns a 256-dim L2-normalised float32 embedding.
//
// The caller is responsible for InitONNXRuntime; ComputeEmbedding opens
// and closes the session itself. Callable safely on demand.
func ComputeEmbedding(modelPath string, samples16k []float32) ([]float32, error) {
	if len(samples16k) == 0 {
		return nil, fmt.Errorf("compute_embedding: empty input")
	}
	session, err := ort.NewDynamicAdvancedSession(
		modelPath,
		[]string{"audio"},
		[]string{"embedding"},
		nil,
	)
	if err != nil {
		return nil, fmt.Errorf("compute_embedding: load %q: %w", modelPath, err)
	}
	defer session.Destroy()

	inT, err := ort.NewTensor(ort.NewShape(1, int64(len(samples16k))), samples16k)
	if err != nil {
		return nil, fmt.Errorf("compute_embedding: input tensor: %w", err)
	}
	defer inT.Destroy()

	outT, err := ort.NewEmptyTensor[float32](ort.NewShape(1, 256))
	if err != nil {
		return nil, fmt.Errorf("compute_embedding: output tensor: %w", err)
	}
	defer outT.Destroy()

	if err := session.Run(
		[]ort.Value{inT},
		[]ort.Value{outT},
	); err != nil {
		return nil, fmt.Errorf("compute_embedding: inference: %w", err)
	}

	emb := make([]float32, 256)
	copy(emb, outT.GetData())
	return emb, nil
}
