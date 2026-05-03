import Foundation

public enum SessionsClientError: Error {
    case engineUnavailable
    case decode(String)
    case backend(String)
}

/// Thin wrapper over the libvkb session-management C ABI. Constructed
/// against a CoreEngine because the C ABI is a singleton tied to the
/// engine instance — taking the engine as a dependency makes the
/// coupling explicit and lets tests substitute a SpyCoreEngine.
public protocol SessionsClient: Sendable {
    func list() async throws -> [SessionManifest]
    func get(_ id: String) async throws -> SessionManifest
    func delete(_ id: String) async throws
    func clear() async throws
}

/// Production impl backed by the real C ABI through CoreEngine.
public final class LibVKBSessionsClient: SessionsClient {
    private let engine: any CoreEngine

    public init(engine: any CoreEngine) {
        self.engine = engine
    }

    public func list() async throws -> [SessionManifest] {
        guard let json = await engine.sessionsListJSON() else {
            throw SessionsClientError.engineUnavailable
        }
        do {
            return try JSONDecoder().decode([SessionManifest].self, from: Data(json.utf8))
        } catch {
            throw SessionsClientError.decode(String(describing: error))
        }
    }

    public func get(_ id: String) async throws -> SessionManifest {
        guard let json = await engine.sessionGetJSON(id) else {
            throw SessionsClientError.backend(await engine.lastError() ?? "session not found")
        }
        do {
            return try JSONDecoder().decode(SessionManifest.self, from: Data(json.utf8))
        } catch {
            throw SessionsClientError.decode(String(describing: error))
        }
    }

    public func delete(_ id: String) async throws {
        let rc = await engine.sessionDelete(id)
        guard rc == 0 else {
            throw SessionsClientError.backend(await engine.lastError() ?? "delete rc=\(rc)")
        }
    }

    public func clear() async throws {
        let rc = await engine.sessionsClear()
        guard rc == 0 else {
            throw SessionsClientError.backend(await engine.lastError() ?? "clear rc=\(rc)")
        }
    }
}
