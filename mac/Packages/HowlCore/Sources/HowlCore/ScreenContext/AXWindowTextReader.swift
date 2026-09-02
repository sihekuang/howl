import AppKit
import ApplicationServices
import Foundation

/// Reads the focused window's text through the Accessibility API.
///
/// Requires no new TCC permission — Howl already holds Accessibility
/// for text injection. Returns nil for apps that expose no usable AX
/// text (Electron without AXManualAccessibility, Canvas apps, most
/// terminals).
///
/// DEMOTED, NOT LEGACY. The primary screen-context path is now a
/// screenshot sent to a vision model
/// (`ScreenCaptureKitWindowCapturer`), and this reader runs whenever
/// pixels are unavailable: either the configured provider+model turns
/// out to reject images (the `no_vision` verdict Go reports), or no
/// screenshot could be taken at all (Screen Recording denied, no
/// on-screen window, the window vanished mid-capture). Keep it
/// healthy: it is the only zero-prompt path (no Screen Recording TCC),
/// the only path that works at all for the text-only local models
/// people run under Ollama and LM Studio, and the only thing standing
/// between "the user declined the Screen Recording prompt" and "screen
/// context silently never works again". Its denylist enforcement is
/// identical to the capturer's and is not weakened by the demotion.
/// Serial queue for the blocking half of an AX read.
///
/// `AXUIElementCopyAttributeValue` is SYNCHRONOUS cross-process IPC: it
/// blocks the calling thread until the target app's accessibility
/// server answers, which for a browser with many tabs is routinely
/// seconds per call. Running that on a Swift cooperative-pool thread is
/// forbidden. The pool is sized to the core count, a blocked thread is
/// never reclaimed while it waits, and once the pool drains EVERY task
/// in the process starves — MainActor UI work included.
///
/// That is not theoretical. Before this queue existed, the walk ran
/// inline on the cooperative thread that resumed `read()`'s only
/// `await`, and with the vision model reporting `no_vision` (so every
/// focus change fell back to this reader) the app froze solid in about
/// three minutes. macOS logged the hang with eleven of eleven samples
/// parked in `AXUIElementCopyAttributeValue`, on a cooperative thread
/// that had last run 135 seconds earlier.
///
/// Serial rather than concurrent on purpose: it also caps concurrent
/// walks at one, so a burst of focus changes queues instead of piling
/// up. Blocking THIS queue's thread is fine — it is ours, and nothing
/// else depends on it.
private let axWalkQueue = DispatchQueue(
    label: "com.howl.app.screencontext-axwalk", qos: .utility
)

/// Ceiling on a single AX IPC round trip. Set on the application
/// element, which per the Accessibility API applies it to every element
/// obtained from that app.
///
/// Without this an unresponsive target blocks each call indefinitely.
/// `maxNodes` does NOT protect against that: it bounds how many nodes
/// are visited, not how long any one of them takes, so a 3000-node cap
/// against a slow server is still unbounded wall-clock time. That gap
/// is exactly what the freeze fell through.
private let axMessagingTimeout: Float = 2.0

/// Ceiling on the whole walk, for the case where many calls are merely
/// slow rather than hung — a per-call timeout alone still multiplies by
/// the node count.
private let axWalkBudget: DispatchTimeInterval = .seconds(5)

public struct AXWindowTextReader: WindowTextReader {
    /// Never construct this without a denylist. There is deliberately
    /// no default: a reader that silently reads everything is the
    /// failure this parameter exists to prevent, so the type refuses to
    /// be built rather than defaulting to a weaker guarantee.
    private let denylist: @Sendable () -> ScreenContextDenylist
    private let frontmostApp: FrontmostAppLookup
    /// Caps the AX tree walk so a pathological hierarchy can't stall
    /// the extraction path.
    private let maxNodes: Int
    private let maxChars: Int

    public init(denylist: @escaping @Sendable () -> ScreenContextDenylist,
                maxNodes: Int = 3000,
                maxChars: Int = 8192,
                frontmostApp: @escaping FrontmostAppLookup = defaultFrontmostApp) {
        self.denylist = denylist
        self.frontmostApp = frontmostApp
        self.maxNodes = maxNodes
        self.maxChars = maxChars
    }

    public func read() async -> WindowSnapshot? {
        // Identity resolved and denylist-checked in one main-actor hop,
        // so the pid walked below is the pid that was cleared. See
        // `resolveReadableFrontmostApp` for why the check lives there
        // and not only in the coordinator.
        guard let (bundleID, pid) = await resolveReadableFrontmostApp(
            denylist: denylist, lookup: frontmostApp
        ) else { return nil }

        // Everything below this line blocks. Get off the cooperative
        // pool before any of it runs — see `axWalkQueue`.
        return await withCheckedContinuation { continuation in
            axWalkQueue.async {
                continuation.resume(
                    returning: self.readBlocking(bundleID: bundleID, pid: pid)
                )
            }
        }
    }

    /// The blocking half. Only ever called on `axWalkQueue`.
    private func readBlocking(bundleID: String, pid: pid_t) -> WindowSnapshot? {
        let appElement = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(appElement, axMessagingTimeout)
        guard let window = copyElement(appElement, kAXFocusedWindowAttribute) else { return nil }

        let title = copyString(window, kAXTitleAttribute) ?? ""
        var collected = ""
        var visited = 0
        var charCount = 0
        walk(window, into: &collected, charCount: &charCount, visited: &visited,
             deadline: .now() + axWalkBudget)

        let text = collected.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.isEmpty { return nil }
        return WindowSnapshot(bundleID: bundleID, windowTitle: title, text: text, source: .accessibility)
    }

    /// Depth-first walk accumulating AXValue and AXTitle strings.
    ///
    /// `charCount` is a running total maintained incrementally rather
    /// than re-deriving it from `out.count` on every check. `String.count`
    /// is an O(length) grapheme-cluster scan, not O(1) — calling it up
    /// to 3 times per node (entry, post-attribute, post-child) across up
    /// to `maxNodes` (3000) nodes on a string growing toward `maxChars`
    /// (8192) made the whole walk O(n²) in the accumulated text length.
    ///
    /// The running total preserves IDENTICAL `maxChars` semantics to
    /// the original `out.count` check — not an approximation. Every
    /// chunk this appends is immediately followed by a newline, and a
    /// newline is always its own extended grapheme cluster (Unicode
    /// never merges a line feed with a neighboring character), so every
    /// append lands on a hard grapheme-boundary on both sides: what
    /// precedes it (the newline from the previous append, or the empty
    /// string at the very start) and what follows it (the newline this
    /// append itself adds). Grapheme-cluster segmentation is local to a
    /// small neighborhood around each boundary, so a chunk's own
    /// `trimmed.count`, computed standalone, is unaffected by anything
    /// outside those hard breaks — summing it in is exactly equivalent
    /// to re-counting the whole accumulated string, not just close to
    /// it.
    private func walk(_ element: AXUIElement, into out: inout String, charCount: inout Int, visited: inout Int, deadline: DispatchTime) {
        if visited >= maxNodes || charCount >= maxChars || .now() > deadline { return }
        visited += 1

        for attr in [kAXValueAttribute, kAXTitleAttribute] {
            if let s = copyString(element, attr) {
                let trimmed = s.trimmingCharacters(in: .whitespacesAndNewlines)
                if !trimmed.isEmpty {
                    out += trimmed + "\n"
                    charCount += trimmed.count + 1 // +1 for the trailing "\n"
                    if charCount >= maxChars { return }
                }
            }
        }

        var childrenRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXChildrenAttribute as CFString, &childrenRef) == .success,
              let children = childrenRef as? [AXUIElement] else { return }
        for child in children {
            walk(child, into: &out, charCount: &charCount, visited: &visited, deadline: deadline)
            if visited >= maxNodes || charCount >= maxChars || .now() > deadline { return }
        }
    }

    private func copyElement(_ element: AXUIElement, _ attribute: String) -> AXUIElement? {
        var ref: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &ref) == .success else { return nil }
        guard let value = ref, CFGetTypeID(value) == AXUIElementGetTypeID() else { return nil }
        return (value as! AXUIElement)
    }

    private func copyString(_ element: AXUIElement, _ attribute: String) -> String? {
        var ref: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &ref) == .success else { return nil }
        return ref as? String
    }
}
