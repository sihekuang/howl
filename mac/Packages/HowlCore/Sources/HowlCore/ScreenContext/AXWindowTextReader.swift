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
    /// Caps the AX tree walk so a pathological hierarchy can't stall
    /// the extraction path.
    private let maxNodes: Int
    private let maxChars: Int

    public init(maxNodes: Int = 3000, maxChars: Int = 8192) {
        self.maxNodes = maxNodes
        self.maxChars = maxChars
    }

    public func read() async -> WindowSnapshot? {
        // `NSWorkspace.frontmostApplication`'s thread affinity is not
        // documented by Apple. AppKit is documented as requiring a run
        // loop and not being daemon-safe; `NSRunningApplication`'s
        // properties are documented as atomic, but that guarantees the
        // returned object's consistency, not which thread may call the
        // accessor. Nothing certifies this is safe off the main thread
        // — and nothing in the Swift 6 checker enforces it either,
        // since NSWorkspace carries no actor-isolation annotation for
        // the compiler to catch a mistake against. A clean `swift
        // build` here is not a safety certificate. Hop explicitly
        // rather than lean on that silence; do not remove this as
        // "redundant" without documented evidence to the contrary.
        guard let (bundleID, pid) = await MainActor.run(body: { () -> (String, pid_t)? in
            guard let app = NSWorkspace.shared.frontmostApplication,
                  let bundleID = app.bundleIdentifier else { return nil }
            return (bundleID, app.processIdentifier)
        }) else { return nil }

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
