// mac/Packages/VoiceKeyboardCore/Sources/VoiceKeyboardCore/Bridge/TSELabClient.swift
import Foundation

public enum TSELabClientError: Error {
    case backend(String)
}

/// Runs Target Speaker Extraction on a WAV file using the user's
/// enrolled embedding. Used by the Settings → Pipeline → TSE Lab
/// debug surface to verify TSE works on arbitrary inputs without
/// going through the live capture pipeline.
public protocol TSELabClient: Sendable {
    /// Runs TSE on `input` (a 16 kHz mono WAV) and returns the URL of
    /// the extracted output WAV. The output file lives under the
    /// caller's temp directory; it's the caller's responsibility to
    /// clean up if they care.
    func extract(input: URL) async throws -> URL
}

/// libvkb-backed implementation. Construct against a CoreEngine that
/// has already been configured (i.e. somewhere downstream of
/// CompositionRoot, where Engine is alive).
public final class LibVKBTSELabClient: TSELabClient {
    private let engine: any CoreEngine
    private let modelsDir: URL
    private let voiceDir: URL
    private let onnxLibPath: String

    public init(engine: any CoreEngine, modelsDir: URL, voiceDir: URL, onnxLibPath: String) {
        self.engine = engine
        self.modelsDir = modelsDir
        self.voiceDir = voiceDir
        self.onnxLibPath = onnxLibPath
    }

    public func extract(input: URL) async throws -> URL {
        let outURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("tse-lab-\(UUID().uuidString).wav")

        let rc = await engine.tseExtractFile(
            inputPath: input.path,
            outputPath: outURL.path,
            modelsDir: modelsDir.path,
            voiceDir: voiceDir.path,
            onnxLibPath: onnxLibPath
        )
        guard rc == 0 else {
            let detail = await engine.lastError() ?? "vkb_tse_extract_file failed (rc=\(rc))"
            throw TSELabClientError.backend("rc=\(rc): \(detail)")
        }
        return outURL
    }
}
