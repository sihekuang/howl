import Foundation
@preconcurrency import AVFoundation
import CoreAudio
import AppKit
import os

private let log = Logger(subsystem: "com.voicekeyboard.app", category: "AudioCapture")

/// Captures Float32 mono 48 kHz audio from the default system input
/// device and pushes frames to a callback. Lifetime: one start/stop
/// cycle per capture session.
public struct AudioInputDevice: Identifiable, Hashable, Sendable {
    public let id: String      // AVCaptureDevice.uniqueID == CoreAudio UID
    public let name: String

    public init(id: String, name: String) {
        self.id = id
        self.name = name
    }
}

public protocol AudioCapture: Sendable {
    /// Begin capturing from the device whose UID is `deviceUID`, or
    /// the system default if nil. The callback is invoked with each
    /// frame of Float32 mono 48 kHz samples until `stop()` is called.
    /// The callback may run on the audio thread — must NOT block.
    /// Throws if the user denied microphone access.
    func start(deviceUID: String?, onFrame: @escaping @Sendable ([Float]) -> Void) async throws

    /// End capturing. Idempotent; safe to call when not started.
    func stop()

    /// Whether the user has granted microphone access.
    func isAuthorized() -> Bool

    /// Open the System Settings → Privacy → Microphone pane.
    func openSystemSettings()

    /// Available input devices (in addition to the system default,
    /// which the caller can represent with a nil UID).
    func availableInputDevices() -> [AudioInputDevice]
}

public enum AudioCaptureError: Error, Equatable {
    case engineStartFailed(String)
    case formatUnavailable
    case permissionDenied
}

/// AVAudioEngine-backed capture. Installs a tap on the input node and
/// converts whatever the device delivers to Float32 mono 48 kHz before
/// invoking the callback.
public final class AVAudioInputCapture: AudioCapture, @unchecked Sendable {
    private let engine = AVAudioEngine()
    private var converter: AVAudioConverter?
    private var targetFormat: AVAudioFormat?
    private var isRunning = false

    // No lock: start/stop are driven serially from the
    // MainActor-isolated EngineCoordinator, so concurrent calls don't
    // happen. The audio-thread callback only reads `converter` and
    // `targetFormat` after start has completed; they're set once and
    // never reassigned during a session.

    public init() {}

    public func isAuthorized() -> Bool {
        AVCaptureDevice.authorizationStatus(for: .audio) == .authorized
    }

    public func openSystemSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone") {
            NSWorkspace.shared.open(url)
        }
    }

    public func availableInputDevices() -> [AudioInputDevice] {
        let session = AVCaptureDevice.DiscoverySession(
            deviceTypes: [.microphone, .external],
            mediaType: .audio,
            position: .unspecified
        )
        return session.devices.map { AudioInputDevice(id: $0.uniqueID, name: $0.localizedName) }
    }

    public func start(deviceUID: String?, onFrame: @escaping @Sendable ([Float]) -> Void) async throws {
        // 1. Resolve mic authorization. AVAudioEngine on macOS does NOT
        //    reliably trigger the system prompt — we must call
        //    requestAccess explicitly the first time.
        let status = AVCaptureDevice.authorizationStatus(for: .audio)
        log.info("AVAudioInputCapture.start: auth status=\(status.rawValue, privacy: .public)")
        switch status {
        case .authorized:
            break
        case .notDetermined:
            let granted = await withCheckedContinuation { (cont: CheckedContinuation<Bool, Never>) in
                AVCaptureDevice.requestAccess(for: .audio) { granted in
                    cont.resume(returning: granted)
                }
            }
            log.info("AVAudioInputCapture.start: requestAccess granted=\(granted, privacy: .public)")
            if !granted {
                throw AudioCaptureError.permissionDenied
            }
        case .denied, .restricted:
            log.error("AVAudioInputCapture.start: mic permission denied or restricted")
            throw AudioCaptureError.permissionDenied
        @unknown default:
            throw AudioCaptureError.permissionDenied
        }

        if isRunning { return }

        let inputNode = engine.inputNode

        // Optional explicit device. Resolve the AVCaptureDevice UID
        // to a CoreAudio AudioDeviceID and tell the input AU to use
        // it. With `nil` we don't touch deviceID — the AU follows
        // whatever the system default is.
        if let uid = deviceUID, !uid.isEmpty {
            if let devID = audioDeviceID(forUID: uid) {
                do {
                    try inputNode.auAudioUnit.setDeviceID(devID)
                    log.info("AVAudioInputCapture.start: using device uid=\(uid, privacy: .public) id=\(devID, privacy: .public)")
                } catch {
                    log.error("AVAudioInputCapture.start: setDeviceID failed: \(String(describing: error), privacy: .public)")
                }
            } else {
                log.error("AVAudioInputCapture.start: no AudioDeviceID for UID=\(uid, privacy: .public); falling back to default")
            }
        } else {
            log.info("AVAudioInputCapture.start: using system default input device")
        }

        let inputFormat = inputNode.inputFormat(forBus: 0)
        log.info("AVAudioInputCapture.start: input format sr=\(inputFormat.sampleRate, privacy: .public) ch=\(inputFormat.channelCount, privacy: .public)")

        guard let target = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: 48000,
            channels: 1,
            interleaved: false
        ) else {
            throw AudioCaptureError.formatUnavailable
        }
        guard let conv = AVAudioConverter(from: inputFormat, to: target) else {
            throw AudioCaptureError.formatUnavailable
        }
        targetFormat = target
        converter = conv

        // Install a tap on the input node. Tap buffer size (4096) is a
        // hint; the system may give us fewer samples per call.
        inputNode.installTap(onBus: 0, bufferSize: 4096, format: inputFormat) { [weak self] buffer, _ in
            guard let self else { return }
            self.deliver(buffer: buffer, onFrame: onFrame)
        }

        do {
            try engine.start()
            isRunning = true
            log.info("AVAudioInputCapture.start: engine started")
        } catch {
            inputNode.removeTap(onBus: 0)
            throw AudioCaptureError.engineStartFailed(String(describing: error))
        }
    }

    public func stop() {
        guard isRunning else { return }
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        isRunning = false
        log.info("AVAudioInputCapture.stop: engine stopped")
    }

    private func deliver(buffer: AVAudioPCMBuffer, onFrame: @Sendable ([Float]) -> Void) {
        guard let converter, let targetFormat else { return }

        // Convert to 48 kHz mono Float32. Estimate output capacity
        // generously so AVAudioConverter never truncates a buffer.
        let ratio = targetFormat.sampleRate / buffer.format.sampleRate
        let outCapacity = AVAudioFrameCount(Double(buffer.frameLength) * ratio + 64)
        guard let outBuffer = AVAudioPCMBuffer(pcmFormat: targetFormat, frameCapacity: outCapacity) else {
            return
        }

        // The converter input block is invoked synchronously inside
        // `converter.convert(...)`, so a class-wrapped flag is fine.
        // Marked @unchecked Sendable to satisfy strict concurrency —
        // the runtime never escapes this method.
        final class Once: @unchecked Sendable { var done = false }
        let once = Once()
        var error: NSError?
        let status = converter.convert(to: outBuffer, error: &error) { _, outStatus in
            if once.done {
                outStatus.pointee = .endOfStream
                return nil
            }
            once.done = true
            outStatus.pointee = .haveData
            return buffer
        }
        if status == .error {
            log.error("AVAudioInputCapture: convert FAILED: \(String(describing: error), privacy: .public)")
            return
        }
        guard let channelData = outBuffer.floatChannelData?[0] else { return }
        let count = Int(outBuffer.frameLength)
        if count == 0 { return }
        let samples = Array(UnsafeBufferPointer(start: channelData, count: count))
        onFrame(samples)
    }

    /// Resolve an AVCaptureDevice / CoreAudio UID string to its
    /// AudioDeviceID. Returns nil if no device with that UID exists.
    private func audioDeviceID(forUID uid: String) -> AudioDeviceID? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyTranslateUIDToDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var devID = AudioDeviceID(0)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        let cf = uid as CFString
        let status = withUnsafePointer(to: cf) { uidPtr -> OSStatus in
            AudioObjectGetPropertyData(
                AudioObjectID(kAudioObjectSystemObject),
                &address,
                UInt32(MemoryLayout<CFString>.size),
                uidPtr,
                &size,
                &devID
            )
        }
        guard status == noErr, devID != 0 else { return nil }
        return devID
    }
}
