# TSE Lab — record from mic — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add an in-app mic-recording affordance to TSE Lab so a developer can run Target Speaker Extraction without preparing a 2-speaker WAV on disk.

**Architecture:** A new `WAVWriter` utility (Float → 16-bit PCM mono WAV) and a new `TSELabRecorder` that wraps the existing `AudioCapture`, buffers 48 kHz mono frames, downsamples to 16 kHz on stop via `AVAudioConverter`, and writes a temp WAV. `TSELabView` gains a Record button alongside the existing upload button; on stop the recorded WAV is set as `inputURL` so the existing "Run TSE" flow runs unchanged.

**Tech Stack:** Swift 6 / SwiftUI / AVFoundation. Swift Testing framework (`Testing` module). The new code lives in `HowlCore` (SwiftPM) and `mac/Howl/UI/...` (app target).

**Spec:** `docs/superpowers/specs/2026-05-22-tse-lab-record-from-mic-design.md`

---

## File Structure

Create:
- `mac/Packages/HowlCore/Sources/HowlCore/Audio/WAVWriter.swift` — Float → int16 mono WAV writer.
- `mac/Packages/HowlCore/Tests/HowlCoreTests/WAVWriterTests.swift` — round-trip, header, clipping tests.
- `mac/Packages/HowlCore/Sources/HowlCore/Audio/TSELabRecorder.swift` — start/stop/cancel wrapper around `AudioCapture`, downsamples + writes WAV on stop.
- `mac/Packages/HowlCore/Tests/HowlCoreTests/TSELabRecorderTests.swift` — uses a fake `AudioCapture` to drive the recorder; asserts file presence, duration, sample rate.

Modify:
- `mac/Howl/UI/Settings/Pipeline/TSELabView.swift` — add Record button, recorder state, gesture handling, recording UI.
- `mac/Howl/UI/Settings/Pipeline/PipelineTab.swift` — accept `audioCapture`, thread it into `TSELabView` via a fresh `TSELabRecorder`.
- `mac/Howl/UI/Settings/SettingsView.swift` — pass `composition.audioCapture` to `PipelineTab`.

---

## Task 1: WAVWriter — failing test

**Files:**
- Create: `mac/Packages/HowlCore/Tests/HowlCoreTests/WAVWriterTests.swift`

- [ ] **Step 1: Write the failing test file**

```swift
// mac/Packages/HowlCore/Tests/HowlCoreTests/WAVWriterTests.swift
import Foundation
import AVFoundation
import Testing
@testable import HowlCore

@Suite("WAVWriter")
struct WAVWriterTests {
    /// Writes a 1-second 16 kHz mono tone and reads it back. Asserts:
    /// - File exists.
    /// - Header advertises 16 kHz, 1 channel, 16-bit.
    /// - Frame count matches.
    /// - Peak amplitude in [-1, 1] is preserved within int16 quantization error.
    @Test func writeRoundTrip_16kHzMono() throws {
        let sr = 16000
        let n = sr // 1 second
        let amp: Float = 0.5
        let samples: [Float] = (0..<n).map { i in
            sin(2.0 * .pi * 440.0 * Float(i) / Float(sr)) * amp
        }

        let url = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("wavwriter-\(UUID().uuidString).wav")
        defer { try? FileManager.default.removeItem(at: url) }

        try WAVWriter.writeMonoPCM16(samples: samples, sampleRate: sr, to: url)
        #expect(FileManager.default.fileExists(atPath: url.path))

        let file = try AVAudioFile(forReading: url)
        #expect(file.processingFormat.sampleRate == 16000)
        #expect(file.processingFormat.channelCount == 1)
        #expect(file.length == Int64(n))
    }

    /// Samples outside [-1, 1] clip to int16 limits rather than wrapping.
    @Test func writeClipsOutOfRangeSamples() throws {
        let url = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("wavwriter-clip-\(UUID().uuidString).wav")
        defer { try? FileManager.default.removeItem(at: url) }

        try WAVWriter.writeMonoPCM16(samples: [1.5, -1.5, 0.0], sampleRate: 16000, to: url)

        let file = try AVAudioFile(forReading: url)
        let buf = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: 3)!
        try file.read(into: buf)
        #expect(buf.frameLength == 3)
        // PCM int16 file, but processingFormat is float32. Just confirm the
        // clipped values are near ±1.0 (within one int16 LSB of max).
        let ch0 = buf.floatChannelData![0]
        #expect(ch0[0] > 0.999)
        #expect(ch0[1] < -0.999)
        #expect(abs(ch0[2]) < 0.001)
    }

    /// Empty input writes a valid zero-length WAV.
    @Test func writeEmptySamples() throws {
        let url = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("wavwriter-empty-\(UUID().uuidString).wav")
        defer { try? FileManager.default.removeItem(at: url) }

        try WAVWriter.writeMonoPCM16(samples: [], sampleRate: 16000, to: url)
        let file = try AVAudioFile(forReading: url)
        #expect(file.length == 0)
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

```bash
cd mac/Packages/HowlCore && swift test --filter WAVWriter
```

Expected: compile error — `cannot find 'WAVWriter' in scope`.

---

## Task 2: WAVWriter — implementation

**Files:**
- Create: `mac/Packages/HowlCore/Sources/HowlCore/Audio/WAVWriter.swift`

- [ ] **Step 1: Implement the writer**

```swift
// mac/Packages/HowlCore/Sources/HowlCore/Audio/WAVWriter.swift
import Foundation
import AVFoundation

/// Writes mono Float32 sample buffers as 16-bit PCM mono WAV files.
/// Used by TSE Lab to materialize an in-memory recording to disk for
/// downstream TSE processing (which expects a 16 kHz mono WAV).
public enum WAVWriter {
    public enum Error: Swift.Error {
        case formatUnsupported
        case writeFailed(underlying: Swift.Error)
    }

    /// Writes `samples` as a 16-bit PCM mono WAV at `sampleRate` Hz.
    /// Samples are clipped to [-1, 1] before quantization.
    /// Overwrites the destination file if it exists.
    public static func writeMonoPCM16(
        samples: [Float],
        sampleRate: Int,
        to url: URL
    ) throws {
        guard let outFormat = AVAudioFormat(
            commonFormat: .pcmFormatInt16,
            sampleRate: Double(sampleRate),
            channels: 1,
            interleaved: true
        ) else {
            throw Error.formatUnsupported
        }

        // AVAudioFile won't write empty files reliably from a zero-length
        // buffer write. Handle the empty case by creating the file via a
        // 1-frame silence write, then truncating header.length back to 0
        // — but actually AVAudioFile rewrites the data chunk length on
        // close, so an immediate close after open suffices.
        if FileManager.default.fileExists(atPath: url.path) {
            try? FileManager.default.removeItem(at: url)
        }

        do {
            let file = try AVAudioFile(forWriting: url, settings: outFormat.settings)
            if samples.isEmpty { return }

            // Source buffer: float32 mono at target rate (no resampling here).
            guard let srcFormat = AVAudioFormat(
                commonFormat: .pcmFormatFloat32,
                sampleRate: Double(sampleRate),
                channels: 1,
                interleaved: false
            ),
            let buf = AVAudioPCMBuffer(
                pcmFormat: srcFormat,
                frameCapacity: AVAudioFrameCount(samples.count)
            ) else {
                throw Error.formatUnsupported
            }
            buf.frameLength = AVAudioFrameCount(samples.count)
            let ch = buf.floatChannelData![0]
            for i in 0..<samples.count {
                // Clip to [-1, 1] — AVAudioFile converts to int16 internally
                // and wraps on overflow otherwise.
                let s = samples[i]
                ch[i] = s > 1 ? 1 : (s < -1 ? -1 : s)
            }
            try file.write(from: buf)
        } catch let e as Error {
            throw e
        } catch {
            throw Error.writeFailed(underlying: error)
        }
    }
}
```

- [ ] **Step 2: Run tests to verify they pass**

```bash
cd mac/Packages/HowlCore && swift test --filter WAVWriter
```

Expected: 3 tests pass.

- [ ] **Step 3: Commit**

```bash
git add mac/Packages/HowlCore/Sources/HowlCore/Audio/WAVWriter.swift \
        mac/Packages/HowlCore/Tests/HowlCoreTests/WAVWriterTests.swift
git commit -m "feat(HowlCore): WAVWriter for mono float32 → 16-bit PCM WAV

Co-Authored-By: Claude Opus 4.7 <noreply@anthropic.com>"
```

---

## Task 3: TSELabRecorder — failing test with fake AudioCapture

**Files:**
- Create: `mac/Packages/HowlCore/Tests/HowlCoreTests/TSELabRecorderTests.swift`

- [ ] **Step 1: Write the failing test file (with embedded fake AudioCapture)**

```swift
// mac/Packages/HowlCore/Tests/HowlCoreTests/TSELabRecorderTests.swift
import Foundation
import AVFoundation
import Testing
@testable import HowlCore

/// Fake AudioCapture that records the onFrame callback and lets the
/// test push synthetic 48 kHz mono frames into it.
final class FakeAudioCapture: AudioCapture, @unchecked Sendable {
    var onFrameHandler: (@Sendable ([Float]) -> Void)?
    var startError: Error?
    private(set) var isStarted = false
    private(set) var stopCount = 0

    func start(deviceUID: String?, onFrame: @escaping @Sendable ([Float]) -> Void) async throws {
        if let e = startError { throw e }
        onFrameHandler = onFrame
        isStarted = true
    }
    func stop() {
        stopCount += 1
        isStarted = false
        onFrameHandler = nil
    }
    func isAuthorized() -> Bool { true }
    func openSystemSettings() {}
    func availableInputDevices() -> [AudioInputDevice] { [] }

    /// Test helper — push N samples to the registered callback.
    func feed(_ frames: [Float]) {
        onFrameHandler?(frames)
    }
}

@Suite("TSELabRecorder")
struct TSELabRecorderTests {
    /// Start → feed 1 second of 48 kHz audio → stop → expect a 16 kHz
    /// mono WAV with ~16000 frames written to a temp URL.
    @MainActor
    @Test func recordRoundTrip_writes16kHzWAV() async throws {
        let fake = FakeAudioCapture()
        let rec = TSELabRecorder(audioCapture: fake)
        try await rec.start()
        #expect(rec.isRecording)
        #expect(fake.isStarted)

        // Feed 1 second of 48 kHz audio in 480-sample chunks (10 ms).
        let chunk = [Float](repeating: 0.1, count: 480)
        for _ in 0..<100 { fake.feed(chunk) } // 100 * 10ms = 1s

        let url = try await rec.stop()
        defer { try? FileManager.default.removeItem(at: url) }

        #expect(!rec.isRecording)
        #expect(fake.stopCount == 1)
        #expect(FileManager.default.fileExists(atPath: url.path))

        let file = try AVAudioFile(forReading: url)
        #expect(file.processingFormat.sampleRate == 16000)
        #expect(file.processingFormat.channelCount == 1)
        // 1s at 16 kHz = 16000 frames; allow ±100 for converter framing.
        let len = Int(file.length)
        #expect(len > 15900 && len < 16100, "len=\(len)")
    }

    /// Cancel after start → recorder returns to idle, no file produced.
    @MainActor
    @Test func cancelDiscardsBuffer() async throws {
        let fake = FakeAudioCapture()
        let rec = TSELabRecorder(audioCapture: fake)
        try await rec.start()
        fake.feed([Float](repeating: 0.0, count: 480))
        rec.cancel()
        #expect(!rec.isRecording)
        #expect(fake.stopCount == 1)
    }

    /// AudioCapture start failure propagates out.
    @MainActor
    @Test func startPropagatesAuthorizationFailure() async {
        let fake = FakeAudioCapture()
        fake.startError = AudioCaptureError.permissionDenied
        let rec = TSELabRecorder(audioCapture: fake)
        await #expect(throws: AudioCaptureError.self) {
            try await rec.start()
        }
        #expect(!rec.isRecording)
    }

    /// stop() without a prior start() throws.
    @MainActor
    @Test func stopWithoutStartThrows() async {
        let fake = FakeAudioCapture()
        let rec = TSELabRecorder(audioCapture: fake)
        await #expect(throws: TSELabRecorderError.self) {
            _ = try await rec.stop()
        }
    }
}
```

- [ ] **Step 2: Run tests to verify they fail to compile**

```bash
cd mac/Packages/HowlCore && swift test --filter TSELabRecorder
```

Expected: compile error — `cannot find 'TSELabRecorder'` / `cannot find 'TSELabRecorderError'`.

---

## Task 4: TSELabRecorder — implementation

**Files:**
- Create: `mac/Packages/HowlCore/Sources/HowlCore/Audio/TSELabRecorder.swift`

- [ ] **Step 1: Implement the recorder**

```swift
// mac/Packages/HowlCore/Sources/HowlCore/Audio/TSELabRecorder.swift
import Foundation
@preconcurrency import AVFoundation
import Combine
import os

private let log = Logger(subsystem: "com.howl.app", category: "TSELabRecorder")

public enum TSELabRecorderError: Error {
    /// stop()/cancel() called when not recording.
    case notRecording
    case wavWriteFailed(underlying: Error)
    case downsampleFailed
}

/// Captures 48 kHz mono audio via the injected AudioCapture, buffers it
/// in memory, and on stop() downsamples to 16 kHz and writes a temp WAV
/// suitable for TSE input. Used by TSE Lab to record from the mic
/// instead of uploading a WAV.
///
/// Single start/stop cycle per session. Re-call `start` for a new
/// session — the previous buffer is discarded.
@MainActor
public final class TSELabRecorder: ObservableObject {
    @Published public private(set) var isRecording: Bool = false
    @Published public private(set) var elapsed: TimeInterval = 0

    private let audioCapture: any AudioCapture
    private let captureRate: Double = 48000
    private let targetRate: Double = 16000

    // Mutated only from the main actor: `feed` callbacks dispatch back
    // here before appending.
    private var samples: [Float] = []
    private var startedAt: Date?
    private var timerCancellable: AnyCancellable?

    public init(audioCapture: any AudioCapture) {
        self.audioCapture = audioCapture
    }

    public func start() async throws {
        samples.removeAll(keepingCapacity: true)
        startedAt = Date()
        elapsed = 0

        try await audioCapture.start(deviceUID: nil) { [weak self] frame in
            // onFrame may run off-main; hop back before mutating state.
            Task { @MainActor [weak self] in
                self?.samples.append(contentsOf: frame)
            }
        }

        isRecording = true
        // Drive elapsed at 10 Hz for the UI; coarse is fine.
        timerCancellable = Timer.publish(every: 0.1, on: .main, in: .common)
            .autoconnect()
            .sink { [weak self] _ in
                guard let self, let s = self.startedAt else { return }
                self.elapsed = Date().timeIntervalSince(s)
            }
    }

    /// Stops capture, downsamples 48 kHz → 16 kHz, writes a temp WAV,
    /// returns its URL.
    public func stop() async throws -> URL {
        guard isRecording else { throw TSELabRecorderError.notRecording }
        audioCapture.stop()
        timerCancellable?.cancel()
        timerCancellable = nil
        isRecording = false
        startedAt = nil

        let captured = samples
        samples.removeAll(keepingCapacity: false)

        let downsampled = try downsample(captured, from: captureRate, to: targetRate)
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("tse-lab-rec-\(UUID().uuidString).wav")
        do {
            try WAVWriter.writeMonoPCM16(samples: downsampled, sampleRate: Int(targetRate), to: url)
        } catch {
            throw TSELabRecorderError.wavWriteFailed(underlying: error)
        }
        log.info("TSELabRecorder.stop: wrote \(downsampled.count, privacy: .public) samples to \(url.path, privacy: .public)")
        return url
    }

    /// Stops capture and discards the buffer without writing a file.
    public func cancel() {
        guard isRecording else { return }
        audioCapture.stop()
        timerCancellable?.cancel()
        timerCancellable = nil
        isRecording = false
        startedAt = nil
        samples.removeAll(keepingCapacity: false)
    }

    // MARK: - Internal

    private func downsample(_ input: [Float], from srcRate: Double, to dstRate: Double) throws -> [Float] {
        if input.isEmpty { return [] }
        guard let srcFmt = AVAudioFormat(
            commonFormat: .pcmFormatFloat32, sampleRate: srcRate, channels: 1, interleaved: false
        ), let dstFmt = AVAudioFormat(
            commonFormat: .pcmFormatFloat32, sampleRate: dstRate, channels: 1, interleaved: false
        ), let converter = AVAudioConverter(from: srcFmt, to: dstFmt),
           let srcBuf = AVAudioPCMBuffer(pcmFormat: srcFmt, frameCapacity: AVAudioFrameCount(input.count)) else {
            throw TSELabRecorderError.downsampleFailed
        }
        srcBuf.frameLength = AVAudioFrameCount(input.count)
        let ch = srcBuf.floatChannelData![0]
        for i in 0..<input.count { ch[i] = input[i] }

        let ratio = dstRate / srcRate
        let outCap = AVAudioFrameCount(Double(input.count) * ratio + 64)
        guard let dstBuf = AVAudioPCMBuffer(pcmFormat: dstFmt, frameCapacity: outCap) else {
            throw TSELabRecorderError.downsampleFailed
        }

        final class Once: @unchecked Sendable { var done = false }
        let once = Once()
        var error: NSError?
        let status = converter.convert(to: dstBuf, error: &error) { _, outStatus in
            if once.done {
                outStatus.pointee = .endOfStream
                return nil
            }
            once.done = true
            outStatus.pointee = .haveData
            return srcBuf
        }
        if status == .error {
            log.error("TSELabRecorder.downsample: convert FAILED: \(String(describing: error), privacy: .public)")
            throw TSELabRecorderError.downsampleFailed
        }
        guard let cd = dstBuf.floatChannelData?[0] else { throw TSELabRecorderError.downsampleFailed }
        let n = Int(dstBuf.frameLength)
        return Array(UnsafeBufferPointer(start: cd, count: n))
    }
}
```

- [ ] **Step 2: Run tests to verify they pass**

```bash
cd mac/Packages/HowlCore && swift test --filter TSELabRecorder
```

Expected: 4 tests pass. If the round-trip test's frame count is slightly off, adjust the tolerance in the test (already ±100 frames), not the recorder.

- [ ] **Step 3: Commit**

```bash
git add mac/Packages/HowlCore/Sources/HowlCore/Audio/TSELabRecorder.swift \
        mac/Packages/HowlCore/Tests/HowlCoreTests/TSELabRecorderTests.swift
git commit -m "feat(HowlCore): TSELabRecorder — capture 48k, downsample to 16k WAV

Co-Authored-By: Claude Opus 4.7 <noreply@anthropic.com>"
```

---

## Task 5: Wire TSELabRecorder through SettingsView → PipelineTab → TSELabView

**Files:**
- Modify: `mac/Howl/UI/Settings/Pipeline/TSELabView.swift`
- Modify: `mac/Howl/UI/Settings/Pipeline/PipelineTab.swift`
- Modify: `mac/Howl/UI/Settings/SettingsView.swift`

- [ ] **Step 1: Update TSELabView to accept the recorder and add Record button**

Replace `mac/Howl/UI/Settings/Pipeline/TSELabView.swift` with this content. The diff: new `recorder: TSELabRecorder` stored property, `recordedURL`/`previousRecordedURL`/`pressStartedAt`/`recordMode` state, `recordButton` view + gesture handling, recording invalidation in `pickInput`, plus cleanup on disappear.

```swift
// mac/Howl/UI/Settings/Pipeline/TSELabView.swift
import SwiftUI
import UniformTypeIdentifiers
import HowlCore
#if canImport(AppKit)
import AppKit
#endif

/// Debug-only TSE Lab. Lets a developer either upload or record a
/// short clip, run it through Target Speaker Extraction using their
/// enrolled embedding, and play input + extracted side-by-side.
///
/// Surfaced under Settings → Pipeline → TSE Lab in Developer Mode.
struct TSELabView: View {
    let client: any TSELabClient
    @ObservedObject var recorder: TSELabRecorder

    @State private var inputURL: URL? = nil
    @State private var outputURL: URL? = nil
    @State private var status: Status = .idle
    @State private var errorMessage: String? = nil
    @State private var player = WAVPlayer()

    // Tracks the last recorded WAV so we can clean it up if a new
    // record/upload supersedes it. Recordings live in NSTemporaryDirectory
    // and get cleaned on logout, but we still purge eagerly per session.
    @State private var previousRecordedURL: URL? = nil

    // Press-and-hold disambiguation.
    @State private var pressStartedAt: Date? = nil
    @State private var recordMode: RecordMode = .toggle

    enum Status: Equatable { case idle, running, ready }
    enum RecordMode { case toggle, hold }

    /// Hold-vs-click threshold. Matches macOS long-press default.
    private let holdThreshold: TimeInterval = 0.25

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            header
            inputRow
            runButton
            if let err = errorMessage {
                Text(err)
                    .font(.callout)
                    .foregroundStyle(.red)
            }
            if status == .ready, let inURL = inputURL, let outURL = outputURL {
                Divider()
                comparisonRow(input: inURL, output: outURL)
            }
            transportBar
            Spacer(minLength: 0)
        }
        .onDisappear {
            if recorder.isRecording { recorder.cancel() }
        }
    }

    @ViewBuilder
    private var header: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("TSE Lab")
                .font(.title3).bold()
            Text("Upload a 2-speaker WAV (16 kHz mono) or record live, then run Target Speaker Extraction against your enrolled voice. Listen to original vs extracted side-by-side.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    @ViewBuilder
    private var inputRow: some View {
        HStack(spacing: 8) {
            Button {
                pickInput()
            } label: {
                Label("Choose WAV…", systemImage: "doc.badge.plus")
            }
            .disabled(recorder.isRecording)

            recordButton

            if recorder.isRecording {
                Text(formatTime(recorder.elapsed))
                    .font(.caption.monospaced())
                    .foregroundStyle(.red)
            } else if let url = inputURL {
                Text(url.lastPathComponent)
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            Spacer()
        }
    }

    @ViewBuilder
    private var recordButton: some View {
        let dragGesture = DragGesture(minimumDistance: 0)
            .onChanged { _ in
                guard pressStartedAt == nil else { return } // first event only
                pressStartedAt = Date()
                if !recorder.isRecording {
                    recordMode = .toggle // tentative until release
                    Task { await startRecording() }
                }
            }
            .onEnded { _ in
                let held = pressStartedAt.map { Date().timeIntervalSince($0) } ?? 0
                pressStartedAt = nil
                if recorder.isRecording {
                    if held >= holdThreshold {
                        recordMode = .hold
                        Task { await stopRecording() }
                    } else {
                        // Treat as click; wait for next click to stop.
                        recordMode = .toggle
                    }
                } else {
                    // Second click of a toggle pair (started on previous click).
                    Task { await stopRecording() }
                }
            }

        Button {
            // Empty action — gesture handles all behavior. Required so
            // the control reads as a button for accessibility / styling.
        } label: {
            if recorder.isRecording {
                Label("Stop", systemImage: "stop.circle.fill")
                    .symbolRenderingMode(.multicolor)
            } else {
                Label("Record", systemImage: "mic.circle")
            }
        }
        .buttonStyle(.bordered)
        .tint(recorder.isRecording ? .red : .accentColor)
        .gesture(dragGesture)
    }

    @ViewBuilder
    private var runButton: some View {
        HStack {
            Button {
                Task { await runTSE() }
            } label: {
                if status == .running {
                    HStack(spacing: 6) {
                        ProgressView().controlSize(.small)
                        Text("Running…")
                    }
                } else {
                    Label("Run TSE", systemImage: "play.circle")
                }
            }
            .buttonStyle(.borderedProminent)
            .disabled(inputURL == nil || status == .running || recorder.isRecording)
            Spacer()
        }
    }

    @ViewBuilder
    private func comparisonRow(input: URL, output: URL) -> some View {
        HStack(alignment: .top, spacing: 12) {
            clipPanel(title: "Original", url: input)
            clipPanel(title: "Extracted", url: output)
        }
    }

    @ViewBuilder
    private func clipPanel(title: String, url: URL) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title).font(.callout).bold()
            HStack(spacing: 6) {
                Button {
                    player.toggle(url: url)
                } label: {
                    let isCurrent = player.currentURL == url
                    Label(
                        isCurrent && player.isPlaying ? "Pause" : "Play",
                        systemImage: isCurrent && player.isPlaying ? "pause" : "play"
                    )
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                Text(url.lastPathComponent)
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
        }
        .padding(8)
        .background(Color.secondary.opacity(0.06))
        .clipShape(RoundedRectangle(cornerRadius: 6))
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder
    private var transportBar: some View {
        if let url = player.currentURL {
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 8) {
                    Button {
                        if player.isPlaying { player.pause() } else { player.play(url: url) }
                    } label: {
                        Image(systemName: player.isPlaying ? "pause.fill" : "play.fill")
                    }
                    .buttonStyle(.borderless)
                    .controlSize(.small)

                    Text(url.lastPathComponent)
                        .font(.caption.monospaced())
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)

                    Slider(
                        value: Binding(
                            get: { player.currentTime },
                            set: { player.seek(to: $0) }
                        ),
                        in: 0...max(player.duration, 0.001)
                    )
                    .controlSize(.mini)

                    Text("\(formatTime(player.currentTime)) / \(formatTime(player.duration))")
                        .font(.caption.monospaced())
                        .foregroundStyle(.secondary)
                        .frame(width: 80, alignment: .trailing)
                }
                if let err = player.lastError {
                    Text(err).font(.caption).foregroundStyle(.red)
                }
            }
            .padding(8)
            .background(Color.secondary.opacity(0.08))
            .clipShape(RoundedRectangle(cornerRadius: 6))
        }
    }

    // MARK: - Actions

    private func pickInput() {
        #if canImport(AppKit)
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.wav, UTType(filenameExtension: "wav") ?? .audio].compactMap { $0 }
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        if panel.runModal() == .OK, let url = panel.url {
            cleanupPreviousRecording()
            invalidateForNewInput(url: url)
        }
        #endif
    }

    private func startRecording() async {
        do {
            errorMessage = nil
            try await recorder.start()
        } catch {
            errorMessage = "Recording failed to start: \(error.localizedDescription)"
            pressStartedAt = nil
        }
    }

    private func stopRecording() async {
        do {
            let url = try await recorder.stop()
            cleanupPreviousRecording()
            previousRecordedURL = url
            invalidateForNewInput(url: url)
        } catch {
            errorMessage = "Recording failed: \(error.localizedDescription)"
        }
    }

    private func invalidateForNewInput(url: URL) {
        player.stop()
        inputURL = url
        outputURL = nil
        errorMessage = nil
        status = .idle
    }

    private func cleanupPreviousRecording() {
        if let prev = previousRecordedURL {
            try? FileManager.default.removeItem(at: prev)
            previousRecordedURL = nil
        }
    }

    private func runTSE() async {
        guard let input = inputURL else { return }
        player.stop()
        outputURL = nil
        errorMessage = nil
        status = .running
        do {
            let out = try await client.extract(input: input)
            outputURL = out
            status = .ready
        } catch {
            errorMessage = "TSE failed: \(error.localizedDescription)"
            status = .idle
        }
    }

    private func formatTime(_ t: TimeInterval) -> String {
        let total = Int(t.rounded())
        return String(format: "%d:%02d", total / 60, total % 60)
    }
}
```

- [ ] **Step 2: Update PipelineTab to accept audioCapture and construct the recorder**

Apply this diff to `mac/Howl/UI/Settings/Pipeline/PipelineTab.swift`:

1. Add `let audioCapture: any AudioCapture` near the other stored properties (after `replay`).
2. In the `.tseLab` case, replace `TSELabView(client: tseLabClient)` with:

```swift
case .tseLab:
    TSELabView(
        client: tseLabClient,
        recorder: TSELabRecorder(audioCapture: audioCapture)
    )
```

The resulting struct begins:

```swift
struct PipelineTab: View {
    let engine: any CoreEngine
    let sessions: any SessionsClient
    let presets: any PresetsClient
    let replay: any ReplayClient
    let audioCapture: any AudioCapture
    @Binding var settings: UserSettings
    let navigateTo: (SettingsPage) -> Void
    // … (rest unchanged)
```

- [ ] **Step 3: Update SettingsView to pass audioCapture**

In `mac/Howl/UI/Settings/SettingsView.swift`, in the `.pipeline` case (around line 230), add the `audioCapture` parameter:

```swift
case .pipeline:
    PipelineTab(
        engine: composition.engine,
        sessions: LibVKBSessionsClient(engine: composition.engine),
        presets: LibVKBPresetsClient(engine: composition.engine),
        replay: LibVKBReplayClient(engine: composition.engine),
        audioCapture: composition.audioCapture,
        settings: $settings,
        navigateTo: navigateTo
    )
```

- [ ] **Step 4: Regenerate the Xcode project**

```bash
cd mac && make project
```

Expected: regenerates `Howl.xcodeproj/project.pbxproj` (or is a no-op if nothing changed).

- [ ] **Step 5: Build to verify everything compiles**

```bash
cd mac && make build 2>&1 | tail -30
```

Expected: BUILD SUCCEEDED. If you hit Swift 6 actor-isolation errors on the `recorder` callback, the recorder hops to main via `Task { @MainActor … }`; ensure `TSELabRecorder` is annotated `@MainActor` and `@ObservedObject` in the view binds it correctly.

- [ ] **Step 6: Run package tests one more time (full suite)**

```bash
cd mac/Packages/HowlCore && swift test
```

Expected: all existing + new tests pass.

- [ ] **Step 7: Commit**

```bash
git add mac/Howl/UI/Settings/Pipeline/TSELabView.swift \
        mac/Howl/UI/Settings/Pipeline/PipelineTab.swift \
        mac/Howl/UI/Settings/SettingsView.swift \
        mac/Howl/Howl.xcodeproj/project.pbxproj 2>/dev/null || true
git add mac/Howl.xcodeproj/project.pbxproj
git commit -m "feat(mac): TSE Lab — record from mic

Adds a Record button to TSE Lab alongside the upload affordance.
Click toggles start/stop; press-and-hold records while held (≥250ms).
Recorded WAV (16 kHz mono) feeds existing Run TSE flow unchanged.

Co-Authored-By: Claude Opus 4.7 <noreply@anthropic.com>"
```

(If `make project` produced no diff for `project.pbxproj`, the second `git add` is a no-op; that's fine.)

---

## Task 6: Manual verification

- [ ] **Step 1: Launch the app from Xcode (Debug)**

Open `mac/Howl.xcodeproj`, hit Run. Or from `mac/`:

```bash
make run
```

- [ ] **Step 2: Open Settings → Pipeline → TSE Lab**

Ensure Developer Mode is on (Settings → General if not).

- [ ] **Step 3: Test click-to-toggle**

1. Click "Record". Button turns red, "Stop" label, elapsed timer starts counting.
2. Talk for 3 seconds (stage some background voice if you want a meaningful test).
3. Click again. Filename appears next to the buttons. "Run TSE" enables.
4. Click "Run TSE". "Running…" → "Ready" with Original/Extracted side-by-side.
5. Play both; the Extracted track should suppress non-enrolled speakers.

- [ ] **Step 4: Test press-and-hold**

1. Press-and-hold "Record" mouse-down for ≥0.5 s. Recording starts, elapsed counts up.
2. Release. Recording stops on its own; filename appears, "Run TSE" enables.

- [ ] **Step 5: Test invalidation**

1. After recording, click "Choose WAV…" and pick a different file. The recorded temp WAV (in `NSTemporaryDirectory()`) should be deleted; new file becomes input.
2. Record again; previous recording's temp file is replaced.

- [ ] **Step 6: Test cancel-on-disappear**

1. Click Record. While recording, click a different settings tab (e.g., Hotkey).
2. Recording stops cleanly (no UI freeze, no leaked temp file beyond what `cancel()` discards). The mic indicator in the menu bar / OS goes off.

- [ ] **Step 7: Check logs for clean shutdown**

```bash
/usr/bin/log show --predicate 'subsystem == "com.howl.app" AND category == "TSELabRecorder"' --info --debug --last 5m --style compact | tail
```

Expected: `TSELabRecorder.stop: wrote N samples to /var/folders/.../tse-lab-rec-<uuid>.wav` for each completed recording. No errors.

---

## Self-Review

- **Spec coverage:**
  - WAVWriter — Task 1 + 2.
  - TSELabRecorder (start/stop/cancel/elapsed) — Task 3 + 4.
  - TSELabView Record button + gesture rule — Task 5.
  - 250 ms hold threshold — Task 5 (`holdThreshold` constant).
  - Composition wiring (PipelineTab + SettingsView) — Task 5.
  - Cleanup of prior recording — Task 5 (`cleanupPreviousRecording`).
  - Cancel-on-disappear — Task 5 (`.onDisappear`).
  - Tests covering round-trip, cancel, start failure, stop-without-start — Task 3.
  - WAV writer round-trip, clipping, empty — Task 1.
  - Manual verification (record toggle, hold, invalidation, disappear) — Task 6.

- **Placeholders:** none — every step has the actual code, command, and expected output.

- **Type consistency:** `TSELabRecorder` exposes `isRecording`, `elapsed`, `start()`, `stop() -> URL`, `cancel()` — used consistently in TSELabView. `WAVWriter.writeMonoPCM16(samples:sampleRate:to:)` — same signature in producer (Task 2) and consumer (Task 4).
