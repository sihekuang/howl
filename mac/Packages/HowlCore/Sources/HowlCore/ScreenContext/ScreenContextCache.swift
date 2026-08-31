import CryptoKit
import Foundation

/// Keyword results keyed by window identity + content hash, so
/// re-focusing an unchanged window costs no LLM call.
///
/// `now` is injected on every access rather than read from the clock so
/// TTL behaviour is deterministic under test.
public final class ScreenContextCache: @unchecked Sendable {
    private struct Entry {
        let keywords: [String]
        let storedAt: Date
        var lastUsedSequence: UInt64
    }

    private let limit: Int
    private let ttl: TimeInterval
    private let lock = NSLock()
    private var entries: [String: Entry] = [:]

    // Monotonic counter for recency tracking. `now` is caller-supplied
    // and may repeat or go backwards across calls (tests hold it fixed),
    // so wall-clock time cannot be used to break ties between entries
    // touched at the same `now`. This counter always advances.
    private var sequence: UInt64 = 0

    public init(limit: Int = 32, ttl: TimeInterval = 600) {
        self.limit = limit
        self.ttl = ttl
    }

    /// Identity of a window's *content*. Hashing means the raw window
    /// text is never retained in memory beyond the extraction call.
    public func key(bundleID: String, windowTitle: String, text: String) -> String {
        key(bundleID: bundleID, windowTitle: windowTitle, content: Data(text.utf8))
    }

    /// Identity of a captured window *screenshot*. Same construction as
    /// the text key — the image bytes are hashed, never retained — so
    /// the two paths cannot collide on a shared window identity while
    /// disagreeing about the content behind it.
    ///
    /// Screenshots are inherently a weaker cache key than text: any
    /// pixel that moves (a caret, a clock, a progress spinner) is a new
    /// key, so re-focusing a live window hits less often than the text
    /// path did. That is accepted — the alternative, keying on window
    /// identity alone, would serve stale keywords for a document the
    /// user has scrolled or edited, which is the failure that actually
    /// hurts dictation.
    public func key(bundleID: String, windowTitle: String, imageData: Data) -> String {
        key(bundleID: bundleID, windowTitle: windowTitle, content: imageData)
    }

    private func key(bundleID: String, windowTitle: String, content: Data) -> String {
        var payload = Data("\(bundleID)\u{0}\(windowTitle)\u{0}".utf8)
        payload.append(content)
        let digest = SHA256.hash(data: payload)
        return digest.map { String(format: "%02x", $0) }.joined()
    }

    /// Looks up a cached result, evicting it first if it has expired.
    ///
    /// TTL boundary is inclusive: an entry is still valid when exactly
    /// `ttl` seconds old (`now - storedAt == ttl`), and only expires once
    /// strictly older than that (`>`, not `>=`).
    public func value(for key: String, now: Date) -> [String]? {
        lock.lock()
        defer { lock.unlock() }
        guard var entry = entries[key] else { return nil }
        if now.timeIntervalSince(entry.storedAt) > ttl {
            entries.removeValue(forKey: key)
            return nil
        }
        sequence += 1
        entry.lastUsedSequence = sequence
        entries[key] = entry
        return entry.keywords
    }

    public func store(_ keywords: [String], for key: String, now: Date) {
        lock.lock()
        defer { lock.unlock() }
        sequence += 1
        entries[key] = Entry(keywords: keywords, storedAt: now, lastUsedSequence: sequence)
        guard entries.count > limit else { return }
        // Evict least-recently-used until back within the limit.
        let ordered = entries.sorted { $0.value.lastUsedSequence < $1.value.lastUsedSequence }
        for (k, _) in ordered.prefix(entries.count - limit) {
            entries.removeValue(forKey: k)
        }
    }
}
