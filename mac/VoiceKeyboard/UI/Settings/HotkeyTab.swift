import SwiftUI
import AppKit
import Carbon
import os
import VoiceKeyboardCore

private let log = Logger(subsystem: "com.voicekeyboard.app", category: "Hotkey")

struct HotkeyTab: View {
    @Binding var settings: UserSettings
    let onSave: (UserSettings) -> Void
    let conflictChecker: any SymbolicHotkeyChecker
    let permissions: any AccessibilityPermissions
    let audioCapture: any AudioCapture

    @State private var isRecording = false
    @State private var conflicts: [SymbolicHotkeyConflict] = []
    @State private var lastSeen: String? = nil
    @State private var isTrusted = false
    @State private var micGranted = false

    var body: some View {
        Form {
            LabeledContent("Accessibility") {
                HStack(spacing: 8) {
                    Image(systemName: isTrusted ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                        .foregroundStyle(isTrusted ? .green : .orange)
                    Text(isTrusted ? "Granted" : "Required for paste injection")
                        .font(.caption)
                    Spacer()
                    Button("Open…") { permissions.openSystemSettings() }
                }
            }
            LabeledContent("Input Monitoring") {
                HStack(spacing: 8) {
                    Image(systemName: "questionmark.circle")
                        .foregroundStyle(.secondary)
                    Text("Required for global hotkey listening")
                        .font(.caption)
                    Spacer()
                    Button("Open…") { permissions.openInputMonitoringSettings() }
                }
            }
            LabeledContent("Microphone") {
                HStack(spacing: 8) {
                    Image(systemName: micGranted ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                        .foregroundStyle(micGranted ? .green : .orange)
                    Text(micGranted ? "Granted" : "Required to record audio")
                        .font(.caption)
                    Spacer()
                    Button("Open…") { audioCapture.openSystemSettings() }
                }
            }
            Section {
                Text("After granting either permission — or after rebuilding the app — toggle the switch **off then on** so macOS picks up the new binary. The PTT hotkey still won't fire until both panes have VoiceKeyboard enabled.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            LabeledContent("Push-to-talk") {
                Button {
                    isRecording.toggle()
                    lastSeen = nil
                    log.info("HotkeyTab: record toggled isRecording=\(isRecording, privacy: .public)")
                } label: {
                    Text(isRecording ? "Press a shortcut… (Esc to cancel)" : settings.hotkey.displayString)
                        .font(.system(.body, design: .monospaced))
                        .frame(minWidth: 180)
                        .padding(.vertical, 4)
                }
                .buttonStyle(.bordered)
                .overlay(
                    RoundedRectangle(cornerRadius: 6)
                        .strokeBorder(isRecording ? Color.accentColor : Color.clear, lineWidth: 1.5)
                )
                .background(
                    Group {
                        if isRecording {
                            HotkeyListener(
                                onRecord: { shortcut in
                                    log.info("HotkeyTab: recorded kc=\(shortcut.keyCode, privacy: .public) mods=\(String(format: "0x%X", shortcut.modifiers.rawValue), privacy: .public)")
                                    settings.hotkey = shortcut
                                    onSave(settings)
                                    isRecording = false
                                    refreshConflicts()
                                },
                                onCancel: {
                                    log.info("HotkeyTab: record cancelled")
                                    isRecording = false
                                },
                                onKeySeen: { description in
                                    lastSeen = description
                                }
                            )
                        }
                    }
                )
            }

            if isRecording, let lastSeen {
                Text("Last key seen: \(lastSeen)")
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
            }

            if !conflicts.isEmpty {
                Section {
                    Label {
                        VStack(alignment: .leading, spacing: 4) {
                            Text("This shortcut conflicts with macOS").bold()
                            ForEach(conflicts, id: \.id) { c in
                                Text("• \(c.name)").font(.caption)
                            }
                            Text("macOS will intercept the keypress before VoiceKeyboard sees it. Disable the conflicting shortcut in System Settings → Keyboard → Keyboard Shortcuts, or pick a different binding above.")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    } icon: {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .foregroundStyle(.orange)
                    }
                }
            }
        }
        .formStyle(.grouped)
        .padding()
        .task {
            refreshConflicts()
            isTrusted = permissions.isTrusted()
            micGranted = audioCapture.isAuthorized()
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            isTrusted = permissions.isTrusted()
            micGranted = audioCapture.isAuthorized()
        }
    }

    private func refreshConflicts() {
        conflicts = conflictChecker.conflicts(for: settings.hotkey)
    }
}

// MARK: - NSView-based key listener

private struct HotkeyListener: NSViewRepresentable {
    let onRecord: (VoiceKeyboardCore.KeyboardShortcut) -> Void
    let onCancel: () -> Void
    let onKeySeen: (String) -> Void

    func makeNSView(context: Context) -> KeyListenerView {
        let view = KeyListenerView()
        view.onRecord = onRecord
        view.onCancel = onCancel
        view.onKeySeen = onKeySeen
        log.info("HotkeyListener: makeNSView")
        return view
    }

    func updateNSView(_ nsView: KeyListenerView, context: Context) {
        nsView.onRecord = onRecord
        nsView.onCancel = onCancel
        nsView.onKeySeen = onKeySeen
    }
}

final class KeyListenerView: NSView {
    var onRecord: ((VoiceKeyboardCore.KeyboardShortcut) -> Void)?
    var onCancel: (() -> Void)?
    var onKeySeen: ((String) -> Void)?

    // Local NSEvent monitor for fn/Globe key. flagsChanged is not reliably
    // delivered to SwiftUI-hosted NSViews through the responder chain, so
    // we install a local monitor that fires before sendEvent dispatches.
    private var localFlagsMonitor: Any?
    // Composing state: fn-press starts composing; fn-release commits the
    // recorded combo (fn alone, fn+Shift, fn+Control, etc.).
    private var pendingFn = false
    private var pendingFnNSFlags: NSEvent.ModifierFlags = []
    // Shared debounce guard (local monitor + responder override).
    private var fnSeen = false

    override var acceptsFirstResponder: Bool { true }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        guard let window else {
            log.error("KeyListenerView: viewDidMoveToWindow but no window")
            return
        }
        localFlagsMonitor = NSEvent.addLocalMonitorForEvents(matching: .flagsChanged) { [weak self] event in
            self?.handleFlagsChanged(event)
            return event
        }
        log.info("KeyListenerView: installed local flagsChanged monitor")
        // Defer until the run loop ticks once — the SwiftUI hosting view
        // sometimes installs its own first responder right after we mount.
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            let ok = window.makeFirstResponder(self)
            log.info("KeyListenerView: makeFirstResponder -> \(ok, privacy: .public). currentFirstResponder=\(String(describing: window.firstResponder), privacy: .public)")
        }
    }

    override func viewWillMove(toWindow newWindow: NSWindow?) {
        super.viewWillMove(toWindow: newWindow)
        if newWindow == nil { removeLocalMonitor() }
    }

    deinit { removeLocalMonitor() }

    private func removeLocalMonitor() {
        if let m = localFlagsMonitor {
            NSEvent.removeMonitor(m)
            localFlagsMonitor = nil
        }
        pendingFn = false
        pendingFnNSFlags = []
        fnSeen = false
        log.info("KeyListenerView: removed local flagsChanged monitor")
    }

    // Called by both the local monitor and the responder-chain override.
    // fn-press enters composing mode; fn-release commits whatever modifier
    // combo was held alongside fn (fn alone, fn+Shift, fn+Control, etc.).
    private func handleFlagsChanged(_ event: NSEvent) {
        let flags = event.modifierFlags
        let fnDown = flags.contains(.function)

        if fnDown {
            // fn pressed or a co-modifier changed while fn is held.
            pendingFn = true
            fnSeen = true
            pendingFnNSFlags = flags   // track latest modifier state while fn held
            let desc = composedFnDisplay(flags)
            log.info("KeyListenerView fn composing: \(desc, privacy: .public)")
            onKeySeen?(desc)
        } else if pendingFn {
            // fn released — commit the recorded combination.
            pendingFn = false
            fnSeen = false
            let shortcut = fnShortcut(from: pendingFnNSFlags)
            log.info("KeyListenerView fn committed: \(shortcut.displayString, privacy: .public)")
            onRecord?(shortcut)
        }
    }

    private func composedFnDisplay(_ flags: NSEvent.ModifierFlags) -> String {
        var s = "fn"
        if flags.contains(.control) { s += "⌃" }
        if flags.contains(.option)  { s += "⌥" }
        if flags.contains(.shift)   { s += "⇧" }
        if flags.contains(.command) { s += "⌘" }
        return s
    }

    private func fnShortcut(from flags: NSEvent.ModifierFlags) -> VoiceKeyboardCore.KeyboardShortcut {
        var mods: ModifierFlags = []
        if flags.contains(.shift)   { mods.insert(.shift) }
        if flags.contains(.control) { mods.insert(.control) }
        if flags.contains(.option)  { mods.insert(.option) }
        if flags.contains(.command) { mods.insert(.command) }
        return VoiceKeyboardCore.KeyboardShortcut(
            keyCode: VoiceKeyboardCore.KeyboardShortcut.kVK_Function,
            modifiers: mods
        )
    }

    override func flagsChanged(with event: NSEvent) {
        handleFlagsChanged(event)
    }

    override func keyDown(with event: NSEvent) {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        let desc = "kc=\(event.keyCode) flags=0x\(String(flags.rawValue, radix: 16))"
        log.info("KeyListenerView.keyDown \(desc, privacy: .public)")
        onKeySeen?(desc)

        // Escape cancels — ignore fn if it's held alongside.
        let nonFnFlags = flags.subtracting(.function)
        if event.keyCode == UInt16(kVK_Escape) && nonFnFlags.isEmpty {
            pendingFn = false
            fnSeen = false
            onCancel?()
            return
        }

        // While fn is composing, ignore regular key presses.
        // fn+modifier combos are committed on fn-release via handleFlagsChanged.
        if pendingFn { return }

        guard !nonFnFlags.isEmpty else {
            log.debug("KeyListenerView: ignoring — no modifiers")
            return
        }

        var modifiers: ModifierFlags = []
        if flags.contains(.shift)   { modifiers.insert(.shift) }
        if flags.contains(.control) { modifiers.insert(.control) }
        if flags.contains(.option)  { modifiers.insert(.option) }
        if flags.contains(.command) { modifiers.insert(.command) }

        onRecord?(VoiceKeyboardCore.KeyboardShortcut(keyCode: event.keyCode, modifiers: modifiers))
    }

    // Some hosts route key events through performKeyEquivalent first
    // (e.g. when Cmd is held). Capture them here too.
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        log.info("KeyListenerView.performKeyEquivalent kc=\(event.keyCode, privacy: .public)")
        keyDown(with: event)
        return true
    }
}
