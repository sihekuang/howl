import SwiftUI
import AppKit
import Carbon
import os
import HowlCore

private let log = Logger(subsystem: "com.howl.app", category: "Hotkey")

struct HotkeyTab: View {
    @Binding var settings: UserSettings
    let onSave: (UserSettings) -> Void
    let onRecordingStart: () -> Void
    let onRecordingEnd: () -> Void
    let conflictChecker: any SymbolicHotkeyChecker
    let permissions: any AccessibilityPermissions
    let audioCapture: any AudioCapture
    let hidPermission: any HIDInputMonitoringPermission
    let appState: AppState
    let coordinator: EngineCoordinator

    @State private var isRecording = false
    @State private var conflicts: [SymbolicHotkeyConflict] = []
    @State private var lastSeen: String? = nil
    @State private var isTrusted = false
    @State private var micGranted = false
    @State private var hidInputGranted = false

    var body: some View {
        SettingsPane {
            permissionRow(
                label: "Accessibility",
                granted: isTrusted,
                grantedText: "Granted",
                missingText: "Required for paste injection",
                onOpen: { permissions.openSystemSettings() }
            )
            permissionRow(
                label: "Microphone",
                granted: micGranted,
                grantedText: "Granted",
                missingText: "Required to record audio",
                onOpen: { audioCapture.openSystemSettings() }
            )
            Text("After granting Accessibility — or after rebuilding the app — toggle the switch **off then on** so macOS picks up the new binary. Standard hotkeys (key + modifiers) work without any permission, but paste injection still needs Accessibility.")
                .font(.caption)
                .foregroundStyle(.secondary)

            Divider()

            HStack {
                Text("Push-to-talk")
                Spacer()
                Button {
                    isRecording.toggle()
                    lastSeen = nil
                    log.info("HotkeyTab: record toggled isRecording=\(isRecording, privacy: .public)")
                    if isRecording { onRecordingStart() } else { onRecordingEnd() }
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
                                    onSave(settings)  // onSave calls reapplyConfig which restarts hotkey
                                    isRecording = false
                                    refreshConflicts()
                                },
                                onCancel: {
                                    log.info("HotkeyTab: record cancelled")
                                    isRecording = false
                                    onRecordingEnd()  // restart hotkey (onSave not called on cancel)
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

            if settings.hotkey.isModifierOnly,
               !settings.hotkey.requiredModifiers.intersection([.shift, .command]).isEmpty {
                Text("This key is also used in normal shortcuts — dictation will trigger whenever you hold it.")
                    .font(.caption)
                    .foregroundStyle(.orange)
            }

            if !conflicts.isEmpty {
                Divider()
                Label {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("This shortcut conflicts with macOS").bold()
                        ForEach(conflicts, id: \.id) { c in
                            Text("• \(c.name)").font(.caption)
                        }
                        Text("macOS will intercept the keypress before Howl sees it. Disable the conflicting shortcut in System Settings → Keyboard → Keyboard Shortcuts, or pick a different binding above.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                } icon: {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                }
            }

            Divider()

            permissionRow(
                label: "Input Monitoring",
                granted: hidInputGranted,
                grantedText: "Granted",
                missingText: "Required for HID triggers",
                onOpen: { hidPermission.openSystemSettings() }
            )

            HStack {
                Text("HID trigger")
                Spacer()
                if appState.hidLearning {
                    Text("Press a button…")
                        .font(.caption.monospaced())
                        .foregroundStyle(.secondary)
                    Button("Cancel") {
                        Task { @MainActor in await coordinator.cancelHIDLearn() }
                    }
                } else {
                    Text(settings.hidBinding.map(hidBindingLabel) ?? "None")
                        .font(.system(.body, design: .monospaced))
                        .foregroundStyle(settings.hidBinding == nil ? .secondary : .primary)
                    if settings.hidBinding != nil {
                        Button("Clear") {
                            Task { @MainActor in await coordinator.clearHIDBinding() }
                        }
                    }
                    Button("Learn…") {
                        Task { @MainActor in await coordinator.learnHIDBinding() }
                    }
                }
            }
            Text("Bind a **non-keyboard** HID element — a foot pedal, an extra mouse button, or a gamepad button — to start dictation alongside your keyboard shortcut. Listen-only, so the device keeps its normal function. Use a digital button (not an analog trigger or stick).")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .task {
            refreshConflicts()
            isTrusted = permissions.isTrusted()
            micGranted = audioCapture.isAuthorized()
            hidInputGranted = hidPermission.isGranted()
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            isTrusted = permissions.isTrusted()
            micGranted = audioCapture.isAuthorized()
            hidInputGranted = hidPermission.isGranted()
        }
        // Mirror learn/clear (which update the store via the coordinator) into
        // our local settings copy so the row updates live, and a later save of
        // another field can't clobber the binding.
        .onChange(of: appState.hidBinding) { _, newValue in
            settings.hidBinding = newValue
        }
    }

    /// Compact human-readable label for a bound HID element.
    private func hidBindingLabel(_ b: HIDBinding) -> String {
        let dev = String(format: "%04X:%04X", b.vendorID, b.productID)
        if b.usagePage == 0x09 { return "Button \(b.usage) · \(dev)" }
        return String(format: "u%02X/%02X · %@", b.usagePage, b.usage, dev)
    }

    private func refreshConflicts() {
        conflicts = conflictChecker.conflicts(for: settings.hotkey)
    }

    /// One label-aligned permission row (Accessibility / Microphone) with
    /// status icon, status text, and an Open… button. Replaces the
    /// previous LabeledContent rows which only laid out cleanly inside
    /// a `Form { … }.formStyle(.grouped)` container.
    @ViewBuilder
    private func permissionRow(
        label: String,
        granted: Bool,
        grantedText: String,
        missingText: String,
        onOpen: @escaping () -> Void
    ) -> some View {
        HStack(spacing: 8) {
            Text(label)
            Image(systemName: granted ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                .foregroundStyle(granted ? .green : .orange)
            Text(granted ? grantedText : missingText)
                .font(.caption)
            Spacer()
            Button("Open…", action: onOpen)
        }
    }
}

// MARK: - NSView-based key listener

private struct HotkeyListener: NSViewRepresentable {
    let onRecord: (HowlCore.KeyboardShortcut) -> Void
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
    var onRecord: ((HowlCore.KeyboardShortcut) -> Void)?
    var onCancel: (() -> Void)?
    var onKeySeen: ((String) -> Void)?

    // Local NSEvent monitor for fn/Globe key. flagsChanged is not reliably
    // delivered to SwiftUI-hosted NSViews through the responder chain, so
    // we install a local monitor that fires before sendEvent dispatches.
    private var localFlagsMonitor: Any?
    // Composing state: any monitored modifier down starts composing; full
    // release commits a modifier-only trigger (⌃ alone, ⌃⌥, fn, fn+⇧, …).
    private var composing = false
    private var composedNSFlags: NSEvent.ModifierFlags = []
    // Set when a key+modifier combo is committed via keyDown, so the trailing
    // modifier release in flagsChanged does not also commit a modifier-only trigger.
    private var committedCombo = false
    // Modifiers we treat as triggers (incl. fn/Globe via .function).
    private let monitoredFlags: NSEvent.ModifierFlags = [.control, .option, .command, .shift, .function]

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

    // No deinit cleanup: NSView is @MainActor in Swift 6 and deinit is
    // implicitly nonisolated, so calling removeLocalMonitor() from here
    // is a strict-concurrency error. AppKit reliably calls
    // viewWillMove(toWindow: nil) before the view is deallocated, so
    // the monitor is removed there. Worst case if a teardown path skips
    // that hook, the unremoved monitor leaks a closure (~tens of bytes).

    private func removeLocalMonitor() {
        if let m = localFlagsMonitor {
            NSEvent.removeMonitor(m)
            localFlagsMonitor = nil
        }
        composing = false
        composedNSFlags = []
        committedCombo = false
        log.info("KeyListenerView: removed local flagsChanged monitor")
    }

    // Called by both the local monitor and the responder-chain override.
    // Any monitored modifier down enters composing; full release commits the
    // held modifier set as a modifier-only trigger (unless a combo was just
    // committed via keyDown).
    private func handleFlagsChanged(_ event: NSEvent) {
        let flags = event.modifierFlags.intersection(monitoredFlags)
        if !flags.isEmpty {
            composing = true
            composedNSFlags = flags
            let desc = composedDisplay(flags)
            log.info("KeyListenerView composing: \(desc, privacy: .public)")
            onKeySeen?(desc)
        } else if composing {
            composing = false
            if committedCombo {
                committedCombo = false
                return
            }
            let shortcut = modifierOnlyShortcut(from: composedNSFlags)
            log.info("KeyListenerView modifier-only committed: \(shortcut.displayString, privacy: .public)")
            onRecord?(shortcut)
        }
    }

    private func composedDisplay(_ flags: NSEvent.ModifierFlags) -> String {
        var s = ""
        if flags.contains(.function) { s += "fn" }
        if flags.contains(.control)  { s += "⌃" }
        if flags.contains(.option)   { s += "⌥" }
        if flags.contains(.shift)    { s += "⇧" }
        if flags.contains(.command)  { s += "⌘" }
        return s
    }

    private func mappedModifiers(_ flags: NSEvent.ModifierFlags) -> ModifierFlags {
        var mods: ModifierFlags = []
        if flags.contains(.shift)    { mods.insert(.shift) }
        if flags.contains(.control)  { mods.insert(.control) }
        if flags.contains(.option)   { mods.insert(.option) }
        if flags.contains(.command)  { mods.insert(.command) }
        if flags.contains(.function) { mods.insert(.fn) }
        return mods
    }

    /// Build a modifier-only trigger from a flags-only hold. fn-based holds keep
    /// the legacy kVK_Function representation; non-fn holds use kVK_None.
    private func modifierOnlyShortcut(from flags: NSEvent.ModifierFlags) -> HowlCore.KeyboardShortcut {
        let mods = mappedModifiers(flags)
        if mods.contains(.fn) {
            return HowlCore.KeyboardShortcut(
                keyCode: HowlCore.KeyboardShortcut.kVK_Function,
                modifiers: mods.subtracting(.fn)
            )
        }
        return HowlCore.KeyboardShortcut(
            keyCode: HowlCore.KeyboardShortcut.kVK_None,
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

        // Escape cancels — ignore fn if it's held alongside.
        let nonFnFlags = flags.subtracting(.function)
        if event.keyCode == UInt16(kVK_Escape) && nonFnFlags.isEmpty {
            composing = false
            committedCombo = false
            onCancel?()
            return
        }

        onKeySeen?(desc)

        // A bare key with no modifier is not a valid trigger (it would capture
        // ordinary typing). Require at least one monitored modifier — including
        // fn, which makes fn+letter valid.
        guard !flags.intersection(monitoredFlags).isEmpty else {
            log.debug("KeyListenerView: ignoring key with no modifiers")
            return
        }

        let shortcut = HowlCore.KeyboardShortcut(keyCode: event.keyCode, modifiers: mappedModifiers(flags))
        committedCombo = true
        log.info("KeyListenerView combo committed: \(shortcut.displayString, privacy: .public)")
        onRecord?(shortcut)
    }

    // Some hosts route key events through performKeyEquivalent first
    // (e.g. when Cmd is held). Capture them here too.
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        log.info("KeyListenerView.performKeyEquivalent kc=\(event.keyCode, privacy: .public)")
        keyDown(with: event)
        return true
    }
}
