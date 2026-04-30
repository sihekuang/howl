import SwiftUI
import VoiceKeyboardCore

/// Modal recording UI used by VoiceTab to capture a voice enrollment.
struct EnrollmentSheet: View {
    enum Phase: Equatable {
        case ready
        case recording(remainingS: Int)
        case computing
        case done
        case failed(String)
    }

    let audioCapture: any AudioCapture
    let engine: any CoreEngine
    let inputDeviceUID: String?
    let onComplete: () -> Void
    let onCancel: () -> Void

    @State private var phase: Phase = .ready
    @State private var samples: [Float] = []
    @State private var levelPeak: Float = 0
    @State private var timerTask: Task<Void, Never>? = nil

    private let durationSeconds = 10
    private let prompt = """
        Please read this passage at a normal speaking pace:

        "The quick brown fox jumps over the lazy dog. Voice keyboards \
        work best when they have a sample of your speaking voice. \
        Read this paragraph in your typical speaking tone."
        """

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Record your voice").font(.title2.bold())
            Text(prompt).font(.body).foregroundStyle(.secondary)

            ProgressView(value: Double(levelPeak), total: 0.5)
                .progressViewStyle(.linear)

            statusLine

            HStack {
                Button("Cancel", role: .cancel) { cancel() }
                Spacer()
                primaryButton
            }
        }
        .padding(24)
        .frame(width: 460)
        .onDisappear { timerTask?.cancel(); audioCapture.stop() }
    }

    @ViewBuilder
    private var statusLine: some View {
        switch phase {
        case .ready:
            Text("Ready to record. Click Start when you're ready.").foregroundStyle(.secondary)
        case .recording(let remaining):
            Text("Recording... \(remaining)s remaining").foregroundStyle(.primary)
        case .computing:
            HStack { ProgressView().scaleEffect(0.6); Text("Computing voice profile…") }
        case .done:
            Label("Done", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
        case .failed(let msg):
            Label("Failed: \(msg)", systemImage: "xmark.octagon.fill").foregroundStyle(.red)
        }
    }

    @ViewBuilder
    private var primaryButton: some View {
        switch phase {
        case .ready:
            Button("Start") { Task { await start() } }.keyboardShortcut(.defaultAction)
        case .recording:
            Button("Stop") { Task { await stop() } }.keyboardShortcut(.defaultAction)
        case .computing:
            Button("Working…") { }.disabled(true)
        case .done:
            Button("Done") { onComplete() }.keyboardShortcut(.defaultAction)
        case .failed:
            Button("Try Again") { phase = .ready; samples = []; levelPeak = 0 }
        }
    }

    private func start() async {
        samples.removeAll(keepingCapacity: true)
        levelPeak = 0
        phase = .recording(remainingS: durationSeconds)

        do {
            try await audioCapture.start(deviceUID: inputDeviceUID) { frame in
                Task { @MainActor in
                    samples.append(contentsOf: frame)
                    var peak: Float = 0
                    for x in frame { let a = abs(x); if a > peak { peak = a } }
                    levelPeak = max(levelPeak * 0.7, peak)
                }
            }
        } catch {
            await MainActor.run { phase = .failed("microphone: \(error)") }
            return
        }

        timerTask = Task {
            for s in (1...durationSeconds).reversed() {
                try? await Task.sleep(nanoseconds: 1_000_000_000)
                if Task.isCancelled { return }
                await MainActor.run {
                    if case .recording = phase { phase = .recording(remainingS: s - 1) }
                }
            }
            await MainActor.run {
                if case .recording = phase { Task { await stop() } }
            }
        }
    }

    private func stop() async {
        timerTask?.cancel()
        audioCapture.stop()
        guard !samples.isEmpty else {
            phase = .failed("no audio captured")
            return
        }
        phase = .computing
        let bufferSnapshot = samples
        let dir = ModelPaths.voiceProfileDir.path
        do {
            try FileManager.default.createDirectory(
                at: ModelPaths.voiceProfileDir, withIntermediateDirectories: true)
            try await engine.computeEnrollment(
                samples: bufferSnapshot, sampleRate: 48000, profileDir: dir)
            await MainActor.run { phase = .done }
        } catch {
            await MainActor.run { phase = .failed("\(error)") }
        }
    }

    private func cancel() {
        timerTask?.cancel()
        audioCapture.stop()
        onCancel()
    }
}
