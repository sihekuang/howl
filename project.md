# Howl — Project Brief

## Vision

An open-source, privacy-first voice dictation tool. macOS first; Linux and Windows share the same Go core and are on the roadmap. Competes with Wispr Flow, SuperWhisper, and Voibe by being free, open source, and letting the user choose their own LLM — a local model (Ollama, LM Studio) for fully-offline operation, or a cloud model (Claude, GPT) when they want best-in-class cleanup. Whisper transcription always runs locally. Automatic filler-word removal and custom dictionary support are the core differentiators on the cleanup side.

---

## Competitive Landscape

| Product    | Price         | Local Transcription | Cloud-free option | Filler Removal | Open Source |
|------------|---------------|---------------------|-------------------|----------------|-------------|
| Wispr Flow | $15/mo        | ❌                  | ❌                | ✅             | ❌          |
| SuperWhisper | $250 lifetime | ✅                  | ✅                | ❌             | ❌          |
| Voibe      | $99 lifetime  | ✅                  | ✅                | ❌             | ❌          |
| **Howl**   | Free          | ✅                  | ✅ (Ollama / LM Studio) | ✅       | ✅          |

**Key gaps Howl fills:**
- Wispr Flow is cloud-only and paid
- SuperWhisper and Voibe leave filler words in — no automatic cleanup
- None are open source
- None let users choose their own LLM (cloud *or* local)

---

## Pipeline Architecture

```
Mic Input
   ↓
VAD (Silero VAD) — detect when user is speaking
   ↓
Noise Suppression (DeepFilterNet2 or RNNoise) — clean audio
   ↓
Transcription (Whisper — local, Go bindings)
   ↓
Dictionary Matching (fuzzy + phonetic) — fix niche terms
   ↓
LLM Cleanup (user-configurable) — remove fillers, fix grammar
   ↓
Text Output — inject at cursor, system-wide
```

---

## Tech Stack

### Core Library (Go)
- **Whisper bindings**: [`go-whisper`](https://github.com/mutablelogic/go-whisper) or similar Go bindings to whisper.cpp
- **VAD**: Silero VAD (ONNX runtime in Go)
- **Noise suppression**: DeepFilterNet2 or RNNoise (call via FFI or subprocess)
- **Dictionary matching**: Levenshtein distance for fuzzy matching; Metaphone/Soundex for phonetic matching
- **LLM integration**: Pluggable — Anthropic API (Claude), OpenAI API (GPT), Ollama or LM Studio for local models

### Mac UI (Swift / SwiftUI)
- Native Mac app — menu bar icon with dropdown
- Calls Go core via compiled shared library (`.dylib`) using CGo bindings
- System-wide text injection using Accessibility API

### Cross-platform (future)
- **Fyne** or **Wails** wrapping the same Go core for Windows/Linux

---

## Go Core — Exposed API (rough sketch)

```go
// Start listening for voice input
func StartListening(config Config) error

// Stop listening
func StopListening() error

// Register a callback when transcription is ready
func OnTranscription(cb func(text string))

// Config struct
type Config struct {
    WhisperModel   string   // "tiny", "base", "small", "medium", "large"
    LLMProvider    string   // "anthropic", "openai", "ollama", "lmstudio"
    LLMModel       string   // e.g. "claude-sonnet-4-20250514", "gpt-4o", "llama3"
    LLMAPIKey      string
    CustomDict     []string // user's custom vocabulary
    Language       string   // "en", "es", "zh", etc.
    NoiseFilter    string   // "deepfilter", "rnnoise", "none"
}
```

---

## Dictionary Matching

The custom dictionary solves the niche vocabulary problem (e.g. "MCP", "Wispr", "WebRTC"). Before passing the raw transcription to the LLM:

1. Tokenize transcription into words
2. For each word, run fuzzy match (Levenshtein distance) against custom dictionary
3. For phonetically ambiguous words, run Metaphone encoding and compare
4. Substitute matches above threshold
5. Inject only matched terms into the LLM cleanup prompt

**Token-efficient prompt injection:**
```
Fix grammar and remove filler words. Custom terms to preserve exactly: [MCP, WebRTC, Wispr]. Text: "{raw_transcription}"
```

---

## LLM Cleanup Prompt

```
You are a transcription editor. Clean up the following voice transcription:
- Remove filler words (um, uh, like, you know, basically)
- Fix grammar and punctuation
- Preserve technical terms exactly as listed: {custom_terms}
- Keep meaning intact, do not add new content
- Return only the cleaned text, nothing else

Raw transcription: {text}
```

---

## Whisper Model Sizes (tradeoff guide)

| Model | Size | Speed | Accuracy |
|---|---|---|---|
| tiny | 75MB | Very fast | Lower |
| base | 142MB | Fast | Decent |
| small | 466MB | Medium | Good |
| medium | 1.5GB | Slower | Great |
| large | 2.9GB | Slow | Best |

Recommended default: **small** — good balance of speed and accuracy for Mac.

---

## Noise Suppression Options

| Model | Size | Latency | Notes |
|---|---|---|---|
| RNNoise | ~100KB | Very low | Oldest, lightest |
| Silero NS | ~2MB | Low | Good, well maintained |
| DeepFilterNet2 | ~50MB | Medium | Most aggressive, best quality |

Recommended default: **DeepFilterNet2** for quality, **RNNoise** as lightweight fallback.

---

## VAD (Voice Activity Detection)

Use **Silero VAD** — lightweight ONNX model, well-maintained, works great in Go via ONNX runtime. Detects when the user starts/stops speaking so Whisper only processes actual speech, not silence or noise.

---

## Mac UI — Key Features (Phase 1)

- Menu bar icon (mic icon, animated when active)
- Push-to-talk or toggle always-on mode
- Settings panel: model size, LLM provider + API key, custom dictionary editor, language selector
- Works system-wide — injects text at cursor in any app

---

## Milestones

### Phase 1 — Mac MVP
- [ ] Go core: mic capture → VAD → Whisper transcription
- [ ] Basic LLM cleanup (Anthropic or OpenAI API)
- [ ] Custom dictionary with fuzzy matching
- [ ] SwiftUI menu bar app calling Go core via .dylib
- [ ] System-wide text injection on Mac

### Phase 2 — Polish
- [ ] Noise suppression (DeepFilterNet2)
- [ ] Ollama support (fully local LLM)
- [ ] Phonetic dictionary matching
- [ ] Multilingual support

### Phase 3 — Cross Platform
- [ ] Windows/Linux via Fyne or Wails
- [ ] Same Go core, different UI wrapper

---

## Key Open Source References

- Whisper.cpp: https://github.com/ggerganov/whisper.cpp
- go-whisper: https://github.com/mutablelogic/go-whisper
- Silero VAD: https://github.com/snakers4/silero-vad
- DeepFilterNet: https://github.com/Rikorose/DeepFilterNet
- RNNoise: https://github.com/xiph/rnnoise
- Fyne (Go UI): https://fyne.io
- Wails (Go + Web UI): https://wails.io