// mac/Packages/HowlCore/Sources/HowlCore/Bridge/ReplayClient.swift
import Foundation

public enum ReplayClientError: Error {
    case engineUnavailable
    case decode(String)
    case backend(String)
}

public protocol ReplayClient: Sendable {
    func run(sourceID: String, presets: [String]) async throws -> [ReplayResult]
}

public final class LibVKBReplayClient: ReplayClient {
    private let engine: any CoreEngine

    public init(engine: any CoreEngine) {
        self.engine = engine
    }

    public func run(sourceID: String, presets: [String]) async throws -> [ReplayResult] {
        let csv = presets.joined(separator: ",")
        guard let json = await engine.replayJSON(sourceID: sourceID, presetsCSV: csv) else {
            throw ReplayClientError.engineUnavailable
        }
        let data = Data(json.utf8)
        if let arr = try? JSONDecoder().decode([ReplayResult].self, from: data) {
            return arr
        }
        if let env = try? JSONDecoder().decode(ReplayError.self, from: data) {
            throw ReplayClientError.backend(env.error)
        }
        throw ReplayClientError.decode("unexpected JSON: \(json.prefix(200))")
    }
}
