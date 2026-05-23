# TSE Lab — record from mic

Date: 2026-05-22
Status: Design approved, implementation pending
Branch: `test/tse-mix-extract-integration`

## Goal

Let a developer test Target Speaker Extraction (TSE) from inside the
Mac app without first preparing a 2-speaker WAV on disk. Add an
in-app recording affordance to TSE Lab so the input can be either an
uploaded WAV (current behavior) or a freshly recorded mic capture.

The recorded WAV feeds into the existing `TSELabClient.extract(input:)`
flow unchanged — so this is purely an input-acquisition change.

## Non-goals

- Input device selection inside TSE Lab. Reuse the app's configured
  default mic.
- Encoding to non-WAV formats.
- Capturing or playing back an "interferer" signal alongside the
  record. The developer stages multi-speaker conditions in the room
  (TV, another person, etc.).
- Changing TSE's algorithm, model, or anything downstream of the
  WAV-in / WAV-out interface.

## User-facing flow

Settings → Pipeline → TSE Lab (Developer Mode only) now shows two
input controls side-by-side:

```
[ Choose WAV… ]  [ ● Record ]    filename.wav
```

- **Choose WAV…** — unchanged. Opens NSOpenPanel for a 16 kHz mono WAV.
- **● Record** — new. Two interaction modes on the same button:
  - Click → start recording. Click again → stop.
  - Press-and-hold the button → record while held; release → stop.

While recording:

- Button label changes to `Stop` with a pulsing red mic icon.
- Inline `mm:ss` elapsed timer next to the button.
- "Choose WAV…" and "Run TSE" are disabled.

On stop:

- Capture buffer is finalized, downsampled to 16 kHz mono, written to
  a temp WAV.
- `inputURL` is set to the temp WAV path; UI shows the filename like
  any other input.
- Existing "Run TSE" path takes over — no other behavioral change.

If recording fails (mic permission denied, AudioCapture error, WAV
write failure), the existing red error line under the run button
shows the message, and `status` returns to `.idle`.

## Architecture

Three pieces:

### 1. WAV writer (new)

`mac/Packages/HowlCore/Sources/HowlCore/Audio/WAVWriter.swift`

Pure utility, no dependencies on capture or UI.

```swift
public enum WAVWriter {
    /// Write 32-bit float mono samples as a 16-bit PCM mono WAV at
    /// the given sample rate. Overwrites the destination file.
    public static func writeMonoPCM16(
        samples: [Float],
        sampleRate: Int,
        to url: URL
    ) throws
}
```

Implementation: uses `AVAudioFile` with a `.pcmFormatInt16` output
format at the target sample rate. Samples are clipped to `[-1, 1]`
before write. No resampling here — caller passes samples that are
already at `sampleRate`.

Tested in `HowlCoreTests/WAVWriterTests.swift`:

- Round-trip: write known samples, read back via `AVAudioFile`,
  confirm sample count and approximate peak amplitude.
- 16 kHz output: header advertises sr=16000, bits=16, ch=1.
- Clipping: input `[1.5, -1.5]` round-trips to int16 clip limits.

### 2. Mic recorder (new)

`mac/Packages/HowlCore/Sources/HowlCore/Audio/TSELabRecorder.swift`

Wraps `AudioCapture` for the simple "start / stop / dump to WAV"
case TSE Lab needs. Lives next to AudioCapture because it depends on
nothing else.

```swift
@MainActor
public final class TSELabRecorder: ObservableObject {
    @Published public private(set) var isRecording: Bool = false
    @Published public private(set) var elapsed: TimeInterval = 0

    public init(audioCapture: any AudioCapture)
    public func start() async throws
    /// Stops, downsamples 48 kHz → 16 kHz, writes a temp WAV, returns its URL.
    public func stop() async throws -> URL
    public func cancel()
}
```

Internals:

- On `start`: calls `audioCapture.start(deviceUID: nil, onFrame:)`,
  appending each `[Float]` chunk to an internal `[Float]` buffer
  (already 48 kHz mono — see AudioCapture.swift:97). Starts a
  `Timer.publish(every: 0.1)` cancellable to update `elapsed` on the
  main actor.
- On `stop`: calls `audioCapture.stop()`, downsamples 48 → 16 kHz
  via `AVAudioConverter` (a single batch convert is fine — buffers
  are small for the scale of TSE Lab tests, ~tens of seconds), writes
  via `WAVWriter.writeMonoPCM16` to
  `FileManager.default.temporaryDirectory.appendingPathComponent("tse-lab-rec-\(UUID().uuidString).wav")`,
  and returns that URL.
- On `cancel`: same as stop but discards the buffer and returns
  nothing. Used if the view disappears mid-record.

Tested in `HowlCoreTests/TSELabRecorderTests.swift`:

- Inject a fake `AudioCapture` that feeds synthetic 48 kHz frames.
- Start → feed N frames → stop → assert returned WAV exists, has
  expected duration (within ±50 ms), and is 16 kHz mono.
- Cancel after start → no file produced, recorder returns to idle.

### 3. TSELabView changes

`mac/Howl/UI/Settings/Pipeline/TSELabView.swift`

- New stored param: `recorder: TSELabRecorder`. Passed in by
  `CompositionRoot` alongside `client`.
- `inputRow` gains a second button between "Choose WAV…" and the
  filename label. Button styling matches the existing "Choose WAV…"
  control; when recording, swaps to `.bordered` with `.tint(.red)`,
  shows pulsing `mic.fill` SF Symbol via `.symbolEffect(.variableColor)`,
  and an inline `Text(elapsed)`.
- Gesture: a single `DragGesture(minimumDistance: 0)` on the button
  resolves both interaction modes via this rule, tracked in
  `@State private var pressStartedAt: Date?` and an enum
  `RecordMode { case toggle, hold }`:

  1. `.onChanged` (first event of a press) — record `pressStartedAt`.
     If not currently recording, call `recorder.start()` and set
     `mode = .toggle` (tentative).
  2. `.onEnded` —
     - If duration since `pressStartedAt` ≥ 250 ms **and** recorder
       is recording, treat as `.hold`: stop recording now.
     - If duration < 250 ms, treat as `.toggle`: leave recorder
       running; the next short press stops it.
  3. While `mode == .toggle` and recorder is recording, the next
     `.onEnded` of any duration stops it.

  Effect: a quick click toggles start/stop; a deliberate hold records
  while held and stops on release. The 250 ms threshold matches macOS's
  long-press default and keeps the behavior unambiguous from the
  user's POV (a "tap" feels instant, a "hold" feels deliberate).
- On stop returning a URL: same invalidation as `pickInput` —
  `player.stop()`, `inputURL = recordedURL`, `outputURL = nil`,
  `errorMessage = nil`, `status = .idle`.
- While `recorder.isRecording`, "Choose WAV…" and "Run TSE" are
  disabled.
- Cleanup: when the view's `.task` is cancelled (settings tab
  switched away), `recorder.cancel()` is called. No accumulation of
  stale temp WAVs in a single session — old recordings get
  overwritten by name only if they share a UUID, which they won't;
  instead we delete the previous temp recording (tracked in
  `@State private var previousRecordedURL: URL?`) when a new
  recording supersedes it.

### 4. Composition wiring

`mac/Howl/Composition/CompositionRoot.swift` — construct one
`TSELabRecorder(audioCapture: audioCapture)` (the existing
`AVAudioInputCapture` instance) and hand it to `TSELabView` along
with the existing `TSELabClient`. No new dependencies in the DI
graph beyond what's already there.

## Error handling

- **Mic permission denied** — `audioCapture.start` throws; recorder
  surfaces the error to the view, which renders it in the existing
  red error line. No special UI for "go to System Settings"; this is
  a dev-only lab and the broader app already handles mic-permission
  onboarding in FirstRun.
- **AudioCapture start fails for other reasons** — same path: thrown
  error → red error line, status returns to `.idle`.
- **WAVWriter throws** (disk full, etc.) — same path. Capture buffer
  is discarded.
- **View disappears mid-record** — recorder's `cancel()` runs in
  `.onDisappear`. No file written. AudioCapture is stopped so the mic
  light goes off.

## Tests

- `HowlCoreTests/WAVWriterTests.swift` — covered above.
- `HowlCoreTests/TSELabRecorderTests.swift` — covered above, with a
  fake `AudioCapture`.
- No new SwiftUI snapshot tests; the existing TSELabView has none and
  the change is a button + state additions.

Manual verification:

- Build Debug, open Settings → Pipeline → TSE Lab.
- Click "Record" → say something for 3 s → click again to stop.
  Filename appears, "Run TSE" enables, runs against enrolled voice.
- Hold "Record" mouse-down for 2 s, release. Same result.
- Run TSE on a fresh recording. Compare "Original" vs "Extracted" in
  the side-by-side player.
- Pick a WAV via "Choose WAV…" after recording — recorded temp file
  is invalidated; previous-recording cleanup deletes the old file.

## What this doesn't change

- `TSELabClient.extract(input:)` signature.
- The 16 kHz mono WAV contract.
- Existing upload flow.
- Voice enrollment, TSE backend selection, or anything in the Go
  core.
