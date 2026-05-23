import Foundation
import Observation

@MainActor
@Observable
public final class ModelDownloader {
    public enum State {
        case idle
        case downloading(Double) // 0...1
        case completed
        case failed(String)
    }

    public var state: State = .idle

    public init() {}

    public func download(size: String, to dest: URL) async {
        state = .downloading(0)
        let url = URL(string: "https://huggingface.co/ggerganov/whisper.cpp/resolve/main/ggml-\(size).en.bin")!
        do {
            try FileManager.default.createDirectory(at: dest.deletingLastPathComponent(),
                                                    withIntermediateDirectories: true)
            let (tempURL, response) = try await URLSession.shared.download(from: url)
            guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
                state = .failed("HTTP \((response as? HTTPURLResponse)?.statusCode ?? 0)")
                return
            }
            if FileManager.default.fileExists(atPath: dest.path) {
                try FileManager.default.removeItem(at: dest)
            }
            try FileManager.default.moveItem(at: tempURL, to: dest)
            state = .completed
        } catch {
            state = .failed(error.localizedDescription)
        }
    }
}
