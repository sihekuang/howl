import AppKit
import ApplicationServices
import Foundation

/// Reads the focused window's text through the Accessibility API.
///
/// Requires no new TCC permission — Howl already holds Accessibility
/// for text injection. Returns nil for apps that expose no usable AX
/// text (Electron without AXManualAccessibility, Canvas apps, most
/// terminals); the caller falls back to OCR.
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

        let appElement = AXUIElementCreateApplication(pid)
        guard let window = copyElement(appElement, kAXFocusedWindowAttribute) else { return nil }

        let title = copyString(window, kAXTitleAttribute) ?? ""
        var collected = ""
        var visited = 0
        walk(window, into: &collected, visited: &visited)

        let text = collected.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.isEmpty { return nil }
        return WindowSnapshot(bundleID: bundleID, windowTitle: title, text: text)
    }

    /// Depth-first walk accumulating AXValue and AXTitle strings.
    private func walk(_ element: AXUIElement, into out: inout String, visited: inout Int) {
        if visited >= maxNodes || out.count >= maxChars { return }
        visited += 1

        for attr in [kAXValueAttribute, kAXTitleAttribute] {
            if let s = copyString(element, attr) {
                let trimmed = s.trimmingCharacters(in: .whitespacesAndNewlines)
                if !trimmed.isEmpty {
                    out += trimmed + "\n"
                    if out.count >= maxChars { return }
                }
            }
        }

        var childrenRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXChildrenAttribute as CFString, &childrenRef) == .success,
              let children = childrenRef as? [AXUIElement] else { return }
        for child in children {
            walk(child, into: &out, visited: &visited)
            if visited >= maxNodes || out.count >= maxChars { return }
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
