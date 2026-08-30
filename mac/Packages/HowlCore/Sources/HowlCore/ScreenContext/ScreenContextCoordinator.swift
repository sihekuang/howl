import Foundation
import OSLog

/// Orchestrates denylist → read → cache → extract → apply.
///
/// Dependencies arrive as closures so the whole policy is testable
/// without AppKit, a live engine, or a network.
public actor ScreenContextCoordinator {
    private let reader: any WindowTextReader
    private let cache: ScreenContextCache
    private let denylist: @Sendable () -> ScreenContextDenylist
    private let isEnabled: @Sendable () -> Bool
    private let extract: @Sendable (String) async -> [String]
    private let apply: @Sendable ([String]) async -> Void

    private let log = Logger(subsystem: "com.howl.app", category: "screencontext")
    private var inFlight: Task<Void, Never>?

    public init(
        reader: any WindowTextReader,
        cache: ScreenContextCache,
        denylist: @escaping @Sendable () -> ScreenContextDenylist,
        isEnabled: @escaping @Sendable () -> Bool,
        extract: @escaping @Sendable (String) async -> [String],
        apply: @escaping @Sendable ([String]) async -> Void
    ) {
        self.reader = reader
        self.cache = cache
        self.denylist = denylist
        self.isEnabled = isEnabled
        self.extract = extract
        self.apply = apply
    }

    /// Re-derive keywords for whatever window is focused right now.
    /// Never throws and never blocks a dictation: every failure path
    /// ends in dictionary-only behaviour.
    public func refresh(now: Date = Date()) async {
        guard isEnabled() else { return }

        guard let snapshot = await reader.read() else {
            // No readable window — clear rather than leave the previous
            // window's keywords armed.
            await apply([])
            return
        }

        if denylist().shouldSkip(bundleID: snapshot.bundleID) {
            log.debug("screen context skipped for denylisted app")
            await apply([])
            return
        }

        let key = cache.key(
            bundleID: snapshot.bundleID,
            windowTitle: snapshot.windowTitle,
            text: snapshot.text
        )
        if let cached = cache.value(for: key, now: now) {
            await apply(cached)
            return
        }

        let keywords = await extract(snapshot.text)
        cache.store(keywords, for: key, now: now)
        await apply(keywords)
        // Deliberately logs the COUNT, never the terms or window text.
        log.debug("screen context applied \(keywords.count, privacy: .public) keyword(s)")
    }

    /// Schedule a refresh, superseding any still running — a newer
    /// window's context always wins over a stale in-flight extraction.
    public func scheduleRefresh() {
        inFlight?.cancel()
        inFlight = Task { [weak self] in
            await self?.refresh()
        }
    }
}
