package screenctx

import (
	"bytes"
	"image"
	"image/color"
	"image/png"
	"os"
	"path/filepath"
	"strconv"
	"strings"
	"testing"

	"github.com/voice-keyboard/core/internal/llm"

	"golang.org/x/image/font"
	"golang.org/x/image/font/gofont/gomono"
	"golang.org/x/image/font/opentype"
	"golang.org/x/image/math/fixed"
)

// A synthetic screenshot of a code editor, rendered in Go so the
// end-to-end vision test has something to feed a real model.
//
// Rendered rather than committed as a binary: the generator is the
// fixture, it diffs, and it can be regenerated at any size without a
// checked-in PNG going stale against the identifiers the test asserts
// on. Dimensions match what ScreenCaptureKitWindowCapturer actually
// sends — a window inside the 1568px long-edge cap — so the model is
// shown the same kind of image in the test as in production.

const (
	fixtureWidth  = 1400
	fixtureHeight = 900
)

// fixtureIdentifiers are the terms drawn into the screenshot that a
// language model CANNOT produce without reading the pixels. Every one
// is a nonsense compound: absent from training data, absent from the
// extraction prompt, and shaped like the code identifiers this feature
// exists to feed whisper.
//
// This is the load-bearing part of the fixture. "The model returned
// plausible keywords" proves nothing on its own — a text-only model
// asked to describe a screenshot it cannot see will happily invent
// "screenshot, window, dictation". Only these strings coming back
// proves pixels were read.
var fixtureIdentifiers = []string{
	"QuillfeatherSyncQueue",
	"zarneticBackoffMs",
	"bramblewick.toml",
	"VantabladeClient",
	"flushMorrowind",
	"grimsbyToken",
}

// fixtureLines is the editor's content, drawn top to bottom. Index 0 is
// the tab bar, the last line is the status bar; everything between is
// the code pane with a gutter.
type fixtureLine struct {
	text string
	kind lineKind
}

type lineKind int

const (
	lineChrome  lineKind = iota // tab bar / status bar
	lineComment                 // dimmer, like a real editor
	lineCode
)

func fixtureContent() []fixtureLine {
	return []fixtureLine{
		{"  bramblewick.toml   quillfeather/sync_queue.go  ×", lineChrome},
		{"", lineCode},
		{"package quillfeather", lineCode},
		{"", lineCode},
		// The canary the extraction prompt asks the model to echo, drawn
		// as ordinary on-screen content. Placed in the code body, not
		// only in the status bar: a model that lists code identifiers
		// reads this region hardest, and the marker coming back is the
		// pipeline's proof that pixels — not the prompt — were read.
		//
		// Built from the constant, never spelled out, so the fixture and
		// the stripper can never disagree about what the marker is.
		{"const buildStamp = \"" + VisionCanary + "\"", lineCode},
		{"", lineCode},
		{"// zarneticBackoffMs paces retries against the Vantablade", lineComment},
		{"// uplink. Tuned against the grimsbyToken refresh window.", lineComment},
		{"const zarneticBackoffMs = 8400", lineCode},
		{"", lineCode},
		{"type QuillfeatherSyncQueue struct {", lineCode},
		{"    client       *VantabladeClient", lineCode},
		{"    grimsbyToken string", lineCode},
		{"    depth        int", lineCode},
		{"}", lineCode},
		{"", lineCode},
		{"// flushMorrowind drains the queue into the uplink.", lineComment},
		{"func (q *QuillfeatherSyncQueue) flushMorrowind() error {", lineCode},
		{"    cfg, err := loadConfig(\"bramblewick.toml\")", lineCode},
		{"    if err != nil {", lineCode},
		{"        return fmt.Errorf(\"quillfeather: %w\", err)", lineCode},
		{"    }", lineCode},
		{"    return q.client.Push(cfg, q.grimsbyToken)", lineCode},
		{"}", lineCode},
		{"  " + VisionCanary + "   go 1.26   branch: main   Ln 16, Col 42", lineChrome},
	}
}

// renderSyntheticScreenshot draws the editor and returns PNG bytes —
// the same encoding the Swift capturer produces.
func renderSyntheticScreenshot(t *testing.T) []byte {
	t.Helper()

	bg := color.RGBA{0x1e, 0x1f, 0x28, 0xff}
	chromeBG := color.RGBA{0x2a, 0x2c, 0x38, 0xff}
	gutterFG := color.RGBA{0x6b, 0x70, 0x86, 0xff}
	codeFG := color.RGBA{0xe6, 0xe9, 0xf2, 0xff}
	commentFG := color.RGBA{0x8f, 0x9a, 0xb5, 0xff}
	chromeFG := color.RGBA{0xd2, 0xd7, 0xe6, 0xff}

	img := image.NewRGBA(image.Rect(0, 0, fixtureWidth, fixtureHeight))
	fill(img, img.Bounds(), bg)

	const (
		fontPx     = 22
		lineHeight = 34
		gutterX    = 24
		textX      = 92
		topY       = 46
	)
	fill(img, image.Rect(0, 0, fixtureWidth, topY-14), chromeBG)

	face := monoFace(t, fontPx)
	defer face.Close()

	lines := fixtureContent()
	y := topY
	for i, line := range lines {
		if i == len(lines)-1 {
			// Status bar, pinned to the bottom like a real editor.
			y = fixtureHeight - 24
			fill(img, image.Rect(0, y-26, fixtureWidth, fixtureHeight), chromeBG)
		}
		switch line.kind {
		case lineChrome:
			drawText(img, face, chromeFG, gutterX, y, line.text)
		case lineComment:
			drawText(img, face, gutterFG, gutterX, y, lineNumber(i))
			drawText(img, face, commentFG, textX, y, line.text)
		case lineCode:
			drawText(img, face, gutterFG, gutterX, y, lineNumber(i))
			drawText(img, face, codeFG, textX, y, line.text)
		}
		if i == 0 {
			y = topY + lineHeight
		} else {
			y += lineHeight
		}
	}

	var buf bytes.Buffer
	if err := png.Encode(&buf, img); err != nil {
		t.Fatalf("encode fixture PNG: %v", err)
	}
	return buf.Bytes()
}

func lineNumber(i int) string {
	if i == 0 {
		return ""
	}
	return strconv.Itoa(i)
}

func monoFace(t *testing.T, sizePx float64) font.Face {
	t.Helper()
	parsed, err := opentype.Parse(gomono.TTF)
	if err != nil {
		t.Fatalf("parse gomono: %v", err)
	}
	// DPI 72 makes Size a pixel size directly. Full hinting keeps small
	// glyph stems crisp, which is the whole point of the fixture.
	face, err := opentype.NewFace(parsed, &opentype.FaceOptions{
		Size: sizePx, DPI: 72, Hinting: font.HintingFull,
	})
	if err != nil {
		t.Fatalf("build gomono face: %v", err)
	}
	return face
}

func drawText(dst *image.RGBA, face font.Face, fg color.Color, x, y int, s string) {
	if s == "" {
		return
	}
	d := &font.Drawer{
		Dst:  dst,
		Src:  image.NewUniform(fg),
		Face: face,
		Dot:  fixed.P(x, y),
	}
	d.DrawString(s)
}

func fill(dst *image.RGBA, r image.Rectangle, c color.RGBA) {
	for y := r.Min.Y; y < r.Max.Y; y++ {
		for x := r.Min.X; x < r.Max.X; x++ {
			dst.SetRGBA(x, y, c)
		}
	}
}

// The fixture is an input to a test that skips without a local model,
// so it needs its own check: a broken renderer would otherwise look
// exactly like "Ollama isn't running".
//
// Set SCREENCTX_FIXTURE_DUMP=1 to also write the PNG somewhere you can
// look at it — worth doing before blaming a model for not reading it.
func TestSyntheticScreenshot_RendersEveryIdentifierIntoAValidPNG(t *testing.T) {
	data := renderSyntheticScreenshot(t)

	cfg, format, err := image.DecodeConfig(bytes.NewReader(data))
	if err != nil {
		t.Fatalf("fixture is not a decodable image: %v", err)
	}
	if format != "png" {
		t.Errorf("format = %q, want png", format)
	}
	if cfg.Width != fixtureWidth || cfg.Height != fixtureHeight {
		t.Errorf("size = %dx%d, want %dx%d", cfg.Width, cfg.Height, fixtureWidth, fixtureHeight)
	}
	if len(data) > MaxImageBytes {
		t.Errorf("fixture is %d bytes, over the %d-byte pipeline limit", len(data), MaxImageBytes)
	}
	// The media type must be one the pipeline sniffs successfully, or
	// the export rejects the fixture before any model sees it.
	if mt, err := llm.DetectImageMediaType(data); err != nil || mt != "image/png" {
		t.Errorf("media type = %q, %v; want image/png", mt, err)
	}

	// Every identifier the live test asserts on must actually be drawn.
	// A typo here would make the live test fail for a reason that has
	// nothing to do with the model.
	var drawn strings.Builder
	for _, line := range fixtureContent() {
		drawn.WriteString(line.text)
		drawn.WriteString("\n")
	}
	for _, id := range fixtureIdentifiers {
		if !strings.Contains(drawn.String(), id) {
			t.Errorf("identifier %q is asserted on but never drawn", id)
		}
	}
	if !strings.Contains(drawn.String(), VisionCanary) {
		t.Error("the canary is never drawn into the fixture")
	}

	if os.Getenv("SCREENCTX_FIXTURE_DUMP") == "1" {
		path := filepath.Join(os.TempDir(), "screenctx_fixture.png")
		if err := os.WriteFile(path, data, 0o600); err != nil {
			t.Fatalf("dump fixture: %v", err)
		}
		t.Logf("fixture written to %s", path)
	}
}
