// mac/Packages/VoiceKeyboardCore/Sources/VoiceKeyboardCore/Bridge/PresetsClient.swift
import Foundation

public enum PresetsClientError: Error {
    case engineUnavailable
    case decode(String)
    case backend(String)
}

public protocol PresetsClient: Sendable {
    func list() async throws -> [Preset]
    func get(_ name: String) async throws -> Preset
    func save(_ preset: Preset) async throws
    func delete(_ name: String) async throws
}

public final class LibVKBPresetsClient: PresetsClient {
    private let engine: any CoreEngine

    public init(engine: any CoreEngine) {
        self.engine = engine
    }

    public func list() async throws -> [Preset] {
        guard let json = await engine.presetsListJSON() else {
            throw PresetsClientError.engineUnavailable
        }
        do {
            return try JSONDecoder().decode([Preset].self, from: Data(json.utf8))
        } catch {
            throw PresetsClientError.decode(String(describing: error))
        }
    }

    public func get(_ name: String) async throws -> Preset {
        guard let json = await engine.presetGetJSON(name) else {
            throw PresetsClientError.backend(await engine.lastError() ?? "preset not found")
        }
        do {
            return try JSONDecoder().decode(Preset.self, from: Data(json.utf8))
        } catch {
            throw PresetsClientError.decode(String(describing: error))
        }
    }

    public func save(_ preset: Preset) async throws {
        let body = try JSONEncoder().encode(preset)
        let bodyStr = String(decoding: body, as: UTF8.self)
        let rc = await engine.presetSaveJSON(name: preset.name, description: preset.description, body: bodyStr)
        guard rc == 0 else {
            throw PresetsClientError.backend(await engine.lastError() ?? "save rc=\(rc)")
        }
    }

    public func delete(_ name: String) async throws {
        let rc = await engine.presetDelete(name)
        guard rc == 0 else {
            throw PresetsClientError.backend(await engine.lastError() ?? "delete rc=\(rc)")
        }
    }
}
