# Streaming Whisper — Design Doc

**Date:** 2026-04-30
**Branch:** `feat/streaming-whisper`
**Status:** Approved

## Goal

Lower the post-PTT-release wait by chunking audio during recording and
running whisper.cpp on each chunk as it forms, so most transcription is
done by the time the user releases the hotkey. The cursor still only
sees text after release — no live preview, no visible backspaces. UX
matches Wispr Flow's "buffer until release, then paste" pattern, adapted
to a local one-shot whisper.cpp model.

**Non-goals (this spec):**
- Live transcript preview during recording (Wispr does this on iOS only;
  desktop is waveform-only).
- Streaming transcript tokens to the cursor as Whisper produces them.
- Replacing whisper.cpp with a true streaming ASR model.
- A side-by-side comparison harness (chunked vs. single-shot on the same
  audio).
- A "battery saver" mode that skips chunking on battery power.
- Wiring `whisper_full_params.abort_callback` for sub-chunk cancel.

## Background

Today's pipeline (`core/internal/pipeline/pipeline.go`) is strictly
sequential:

```
frames → drainAndDenoise (waits for close) → decimate → Transcribe(full)
       → dict → LLM stream → Result
```

`Transcriber.Transcribe(ctx, pcm16k)` is one-shot — it accepts the entire
recording's PCM and returns one string after a single blocking
`whisper_full` call. For a 30s recording, the user releases PTT and then
waits 5–15s while whisper.cpp chews through everything before the LLM
streaming phase can start. The win available: do most of that whisper
work **during** recording.

## Architecture

The Transcriber, Cleaner, Dict, and Pipeline.Run interfaces are
unchanged. All new logic lives inside `pipeline.Run`. No changes to the
host (Swift) `vkb_push_audio` / event loop API surface, except for one
new C export and one new event kind (Section 4).

```
frames ──→ denoise ──→ decimate ──→ chunker ──→ transcribe worker ──→ join ──→ dict ──→ LLM stream ──→ Result
                                       │              │                  ▲
                                       └─ emits ──────┘                  │
                                          chunks at                      │
                                          VAD silence                    │
                                          or 12s max                     │
                                                                         │
                                          on PTT release:                │
                                          flush tail chunk ──────────────┘
```

Three goroutines added inside `Pipeline.Run`:

1. **Denoiser** — drains the input frame channel, denoises in 480-sample
   frames, writes denoised 48k samples to an internal channel. Same
   logic as today's `drainAndDenoise`, just streaming instead of
   accumulating.
2. **Chunker** — reads denoised samples, decimates to 16k inline, runs
   VAD + max-time logic, emits closed chunks (`[]float32` 16k mono) to a
   bounded chunk channel.
3. **Transcribe worker** — single goroutine (whisper.cpp instances are
   not concurrency-safe per `whisper_cpp.go:64`), reads chunks in order,
   calls `Transcribe`, appends results to an in-order text accumulator.

`Pipeline.Run` blocks on the input channel closing → chunker flushes its
tail → transcribe worker drains → join → dict → LLM stream → return
`Result`. Function signature unchanged.

## Section 1 — Chunker

The chunker reads a stream of 16k mono samples and emits closed chunks.
Time is bucketed into **100ms windows** (1600 samples at 16k) — small
enough for responsive VAD, big enough to filter noise.

### State machine

```
state ∈ { idle, voiced }
silenceMs := 0
chunkBuf  := []float32

for each 100ms window w arriving:
    rms := RMS(w)
    voiced := rms > VOICE_THRESHOLD     // ~0.005 post-denoise

    if state == idle:
        if voiced:
            state = voiced
            chunkBuf = w
        else:
            // drop pre-speech silence on the floor — don't transcribe it
            continue

    else if state == voiced:
        chunkBuf = append(chunkBuf, w)
        if voiced:
            silenceMs = 0
        else:
            silenceMs += 100
            if silenceMs >= SILENCE_HANG_MS:    // 500ms default
                emit(chunkBuf, "vad-cut")
                state = idle
                silenceMs = 0
                chunkBuf = nil
                continue

        if duration(chunkBuf) >= MAX_CHUNK_MS:  // 12s default
            cut := findLowestEnergyPoint(chunkBuf[last 800ms])
            emit(chunkBuf[:cut], "force-cut")
            chunkBuf = chunkBuf[cut:]   // keep the tail in the next chunk
            silenceMs = 0
```

### On PTT release (input channel close)

- If `state == voiced`, emit `chunkBuf` as the final chunk with reason
  `"tail"`. No min-length check — the last word matters even if it's
  just "yes".
- If `state == idle`, no tail to emit.
- Close the chunk channel → transcribe worker finishes and exits.

### Constants (defaults, tunable as `Pipeline` fields)

| Constant | Default | Rationale |
|---|---|---|
| `VOICE_THRESHOLD` | 0.005 | Post-denoise RMS. Above background, below normal speech. To be tuned with real recordings. |
| `SILENCE_HANG_MS` | 500 | Short enough to cut between sentences, long enough to ignore breaths and inter-word pauses. |
| `MAX_CHUNK_MS` | 12_000 | Whisper happiest on 5–30s windows; 12s gives strong latency wins without quality regression. |
| `FORCE_CUT_SCAN_MS` | 800 | When force-cutting, scan the last 800ms of the chunk for the lowest-energy 100ms window and cut there. Avoids mid-word slices on long unbroken speech. |

A debug-log flag emits per-window RMS so VOICE_THRESHOLD can be tuned
from real takes. Off by default.

### Edge cases handled

- Pre-speech silence dropped → no wasted whisper.cpp invocation on empty
  audio.
- Trailing silence absorbed into the chunk it ends → whisper sees
  natural utterance boundaries.
- Sub-500ms pauses (breaths, inter-word) don't trigger cuts.
- Long unbroken speech force-cut at the lowest-energy point in a sliding
  scan window — far less likely to slice mid-word than a hard cut.
- Mic check / ambient noise below threshold → no chunks emitted, no
  whisper compute.

### Edge cases NOT handled (acceptable)

- A perfectly-spoken 60-minute monologue without any inter-utterance
  pause would get force-cut every 12s. Worst case: 5 chunks per minute,
  occasional duplicated/missed word at seams. The LLM cleanup smooths
  most of it.
- Background music or constant noise above threshold blocks emission.
  Same failure mode as today's pipeline.

## Section 2 — Transcribe worker + result assembly

**Single worker, ordered queue.** Whisper.cpp instances are not
concurrency-safe (`whisper_cpp.go:64`), so chunks go through one worker
goroutine, in arrival order. Since chunker emission order = audio order,
transcript order is naturally preserved without any sequencing logic.

```go
// inside Pipeline.Run:
chunkCh   := make(chan []float32, 4)   // bounded — see backpressure below
chunkText := make([]string, 0, 8)
var workerErr error

// transcribe worker
go func() {
    for chunk := range chunkCh {
        text, err := p.transcriber.Transcribe(ctx, chunk)
        if err != nil {
            workerErr = err
            for range chunkCh {}    // drain to unblock chunker
            return
        }
        chunkText = append(chunkText, text)
    }
}()
```

(Real code mutex-guards `chunkText` and `workerErr`. Sketch elides that.)

**Joining chunks:**

```go
raw := strings.TrimSpace(strings.Join(chunkText, " "))
```

Each chunk is utterance-segmented by the chunker, so chunk text reads
naturally as fragments. Occasional capitalization or punctuation
artifacts at seams (`"… store. And bought milk."`) are smoothed by the
LLM cleanup stage.

**Backpressure.** `chunkCh` is bounded at 4 (≈48s of in-flight audio at
max chunk size). If Whisper falls behind:

1. Worker can't accept new chunks → chunker blocks on send.
2. Chunker can't accept new samples → denoise blocks.
3. Denoise can't accept new frames → input `frames` channel blocks.
4. `vkb_push_audio` finds the channel full → drops with warning event
   (existing behavior at `state.go:18-19`).

This cascade exists today for a different reason. We hook into it. No
new mechanism.

**LLM timing.** The streaming LLM stage starts only after:

- Input `frames` channel closes (PTT released).
- Chunker flushes its tail.
- Chunk channel closes.
- Worker finishes the last chunk.

Then `raw` is finalized → `dict.Match` → `cleaner.CleanStream`. The
token-stream-to-cursor UX is unchanged from today.

## Section 3 — Failure modes & cancellation

### Mid-recording transcribe failure

Whisper.cpp returns an error on chunk N of M:

- Worker captures the error, drains the remaining chunk channel without
  processing them, exits.
- After the chunker finishes flushing, `Pipeline.Run` checks the worker
  error → if non-nil, returns `Result{}, err` immediately. No partial-
  text fallback.
- Same loud-failure semantics as today — Whisper failures are rare and
  indicate something serious (OOM, model corruption, GPU disappearing).

### Mid-pipeline cancel (in scope)

The chunked design makes cancel meaningfully better than today: each
`Transcribe` call is independent, `ctx` is checked between chunks. End-
to-end cancel latency goes from "could be 15s mid-whisper" to "≤one
chunk + first-token RTT" with no new code in the chunker.

To expose this:

1. **New C export `vkb_cancel_capture()`** in `core/cmd/libvkb/` →
   calls existing `engine.cancel` (already at `state.go:35`), then
   nils `pushCh` so further `vkb_push_audio` calls no-op.
2. **New event kind `kind: "cancelled"`** emitted from the engine when
   the pipeline returns due to a cancelled context. The Swift host
   treats this as a no-op (no text typed, no error toast).
3. **Swift handler:** pressing Esc while
   `appState.captureState == .recording` calls `vkb_cancel_capture`.
4. `whisper_full_params.abort_callback` wiring is **out of scope** —
   chunk-level cancel granularity (≤12s) is sufficient for v1.

### Other corner cases

| Case | Behavior |
|---|---|
| Empty (silence-only) input | chunker stays in `idle`, no chunks, worker exits, `raw == ""`, returns `Result{}` with no error. Matches today's `pipeline.go:91-94`. |
| Tail too short (PTT release mid-word) | tail chunk is short (e.g. 200ms), whisper returns junk or `""`. Acceptable — same outcome as today. |
| Empty chunk (breath above threshold) | whisper returns `""`. Append anyway; `TrimSpace(Join(...))` cleans up. |
| Backpressure exhaustion | already covered above — propagates to `vkb_push_audio` warning. |
| State leakage between PTT cycles | each `Pipeline.Run` allocates fresh chunker state and channels. No carry-over. |

## Section 4 — Testing strategy

### Chunker (highest-risk new code)

Pure function over a stream of 16k samples, no dependencies. Test in
`core/internal/pipeline/chunker_test.go`:

| Test | Audio fixture | Expected emission |
|---|---|---|
| pre-speech silence is dropped | 1s silence + 1s tone @ -20dB | 1 chunk, ~1s long |
| sub-threshold pauses don't split | tone, 200ms gap, tone | 1 chunk |
| ≥500ms silence splits | tone, 600ms gap, tone | 2 chunks |
| force-cut at 12s | 30s continuous tone | 3 chunks (~12s, ~12s, ~6s) |
| force-cut prefers low-energy point | 12s tone with a 200ms quiet dip near 11.5s | chunk 1 ends at the dip, not at 12s |
| trailing silence absorbed into chunk | tone + 400ms tail silence (under SILENCE_HANG) | 1 chunk including the silence |
| empty input | channel closed immediately | 0 chunks |
| only silence | 5s silence | 0 chunks |

Audio fixtures synthesized in-test (sine generation + zero-fill) — no
.wav files committed. Tests run in milliseconds.

### Pipeline

`pipeline_test.go` already covers the streaming path with a fake
`Transcriber` and fake `StreamingCleaner`. Extend with:

- Multiple chunks → joined raw text fed to cleaner exactly once (assert
  call count + concatenated input).
- Worker error on chunk 2 of 3 → `Pipeline.Run` returns the error, no
  LLM call.
- Cancellation mid-recording → `Pipeline.Run` returns `context.Canceled`
  within one fake-transcribe invocation.
- Empty (silence-only) input → returns `Result{}`, nil; no LLM call
  (existing behavior preserved).

### Whisper integration

The existing `whisper_cpp_test.go` runs against real audio with build
tag `whispercpp`. Add one new case: same audio fed in 12s chunks vs.
single shot, assert text similarity within an edit-distance budget
(Levenshtein ≤ 5% of length). Catches regressions if VAD/MAX_CHUNK
tuning goes sideways.

### Cancel surface

Extend `core/cmd/libvkb/streaming_test.go`:

- `vkb_cancel_capture` mid-recording → emits `kind: "cancelled"`, no
  `result` event.
- `vkb_cancel_capture` with no active recording → no-op, no event.

### Swift side

`Tests/VoiceKeyboardCoreTests/EngineEventTests.swift` already covers
event decoding; add a case for `kind: "cancelled"`.

### Explicitly NOT tested

- Real-world VAD threshold accuracy across different microphones,
  accents, ambient conditions. Tune-with-real-recordings task, with the
  debug RMS log behind a flag.
- whisper.cpp force-cut quality regression in the absolute worst case
  (a 30s tongue-twister with no pauses). Acceptable known limitation;
  the integration similarity test catches egregious breakage.

## Section 5 — CLI test harness

The existing `run.sh` keeps working as a regression check (no script
change needed; chunking is invisible at the Pipeline.Run boundary).

Add new script `run-streaming.sh` for development and latency
measurement.

### Behavior

```
$ ./run-streaming.sh
🎙  Recording — press any key to stop and transcribe, or 'q' to cancel.
[vkb] chunk emitted #1: 8.7s (vad-cut)
[vkb] chunk #1 transcribe: 384ms → "the quick brown fox"
[vkb] chunk emitted #2: 12.0s (force-cut)
[vkb] chunk #2 transcribe: 521ms → "jumps over the lazy dog and runs"
   ← user presses Space (any non-'q' key)
✓ Stopping...
[vkb] chunk emitted #3: 3.1s (tail)
[vkb] chunk #3 transcribe: 142ms → "back to the forest"
[vkb] LLM stream first token: 312ms after stop
[vkb] LLM stream complete: 1180ms after stop
[vkb] === latency report ===
[vkb]   recording duration:    23.8s
[vkb]   transcribe-during-rec: 905ms
[vkb]   post-stop-transcribe:  142ms
[vkb]   total post-stop wait:  454ms

The quick brown fox jumps over the lazy dog and runs back to the forest.
```

If the user presses 'q':

```
   ← user presses 'q'
🚫 Cancelled. No transcript produced.
```

### Implementation

The CLI's `--live` mode already exits on a newline on stdin
(`run.sh:73`). Add a new sentinel: `cancel\n` triggers
`vkb_cancel_capture` instead of stop.

Script flow:

```bash
mkfifo "$FIFO"
core/build/vkb-cli pipe --dict "$DICT" --live --latency-report < "$FIFO" &
PID=$!
exec 3>"$FIFO"
echo "🎙  Recording — press any key to stop and transcribe, or 'q' to cancel." >&2
while IFS= read -rsn1 key; do
    if [[ "$key" == "q" ]]; then
        echo "cancel" >&3
    else
        echo "" >&3
    fi
    break
done
exec 3>&-
wait "$PID"
rm -f "$FIFO"
```

### Required CLI changes

1. **`pipeline.go`**: per-chunk `log.Printf("[vkb] chunk emitted #N: Xs (vad-cut|force-cut|tail)")` and per-chunk transcribe-time logs. Pure additive.
2. **`vkb-cli pipe`**: new `--latency-report` flag emits the summary block at end. Reads chunk-emit timestamps from a structured event stream (or from the existing `[vkb]` log lines via a callback the CLI registers).
3. **`vkb-cli pipe --live`**: recognize `cancel\n` sentinel on stdin, route to `vkb_cancel_capture` path.
4. **`run-streaming.sh`**: new script per above.

## Implementation order

Suggested order for the implementation plan (writing-plans skill will
turn these into concrete steps):

1. Chunker (pure function, fully unit-testable, no whisper.cpp needed).
2. Pipeline restructure to use chunker + transcribe worker.
3. CLI per-chunk logging + `--latency-report`.
4. Cancel C export + `cancelled` event kind.
5. CLI `cancel\n` sentinel + Swift Esc handler.
6. `run-streaming.sh`.
7. Whisper integration similarity test.

## What this design does NOT change

- `Transcriber`, `Cleaner`, `StreamingCleaner`, `Dict`, `Denoiser` interfaces.
- `Pipeline.Run` signature and `Result` struct.
- `Pipeline.New` constructor.
- `vkb_push_audio` / `vkb_start_capture` / `vkb_stop_capture` / `vkb_poll_event` C API surface (only adds `vkb_cancel_capture`).
- Existing event kinds: `chunk`, `result`, `warning`, `error`, `level`. Adds `cancelled`.
- LLM streaming UX (still types tokens at the cursor as the LLM generates).
- Mac app UI flow (only adds Esc-during-recording as a cancel trigger).
- `run.sh` (left untouched as a regression check).
