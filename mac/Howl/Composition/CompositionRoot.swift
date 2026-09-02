import AppKit
import Foundation
import HowlCore

@MainActor
public final class CompositionRoot {
    public let appState: AppState
    public let engine: any CoreEngine
    public let audioCapture: any AudioCapture
    public let hotkey: any HotkeyMonitor
    public let hidTrigger: any HIDTriggerMonitor
    public let hidPermission: any HIDInputMonitoringPermission
    public let injector: any TextInjector
    public let streamTyper: any StreamingTextInjector
    public let settings: any SettingsStore
    public let secrets: any SecretStore
    public let permissions: any AccessibilityPermissions
    public var cancelKeyMonitor: CancelKeyMonitor { _cancelKeyMonitor }

    public init() {
        self.appState = AppState()
        self.engine = LibhowlEngine()
        self.audioCapture = AVAudioInputCapture()
        self.hotkey = CarbonHotkeyMonitor()
        self.hidTrigger = IOHIDTriggerMonitor()
        self.hidPermission = DefaultHIDInputMonitoringPermission()
        self.injector = ClipboardPasteInjector(
            pasteboard: SystemPasteboard(),
            keystroke: CGEventKeystrokeSender()
        )
        self.streamTyper = CGEventTextTyper()
        self.settings = UserDefaultsSettingsStore()
        self.secrets = KeychainSecretStore()
        self.permissions = DefaultAccessibilityPermissions()
    }

    // The global key-down monitor fires on the main thread. Hop onto the
    // MainActor synchronously (no Task round-trip) and route to the
    // coordinator so cancel teardown — stopping capture + mic and showing
    // the "Cancelled" pill — happens the instant a key is pressed, rather
    // than waiting for the Go `cancelled` event to come back.
    private lazy var _cancelKeyMonitor: CancelKeyMonitor = CancelKeyMonitor { [weak self] in
        // assumeIsolated asserts we're already on the MainActor. Global
        // key-down monitors are delivered on the main run loop, so this holds;
        // if that contract were ever violated it traps (a deterministic crash),
        // not silent corruption. We accept that over a Task hop, which would
        // defeat the "instant synchronous cancel" goal.
        MainActor.assumeIsolated {
            guard let self else { return }
            self.coordinator.cancelFromKey()
        }
    }

    public lazy var overlay = RecordingOverlayController(appState: appState)
    public lazy var coordinator = EngineCoordinator(composition: self)

    /// Session-scoped selection for the Pipeline editor's preset picker.
    /// App-lifetime + in-memory so a manual pick survives the editor view
    /// being recreated during navigation, and resets to the active preset
    /// on relaunch. Internal: only the app's UI layer touches it.
    lazy var pipelineEditorState = PipelineEditorState()

    public lazy var conflictChecker: any SymbolicHotkeyChecker = DefaultSymbolicHotkeyChecker()

    let screenContextCache = ScreenContextCache()

    // One denylist source, shared by the capturer, the fallback reader
    // AND the coordinator. The capturer and reader need their own copy
    // because the guarantee is enforced at the point of capture — a
    // capturer that refuses a denylisted app is safe by construction,
    // whereas a check only in the coordinator can be outrun when the
    // user switches apps between the gate and the capture.
    //
    // Fail-closed on a settings read failure — deliberately NOT the same
    // `(try? settings.get())?.… ?? default` shape `isEnabled` below uses.
    // `UserDefaultsSettingsStore.get()` does NOT throw for "no settings
    // file yet" (a fresh install): it returns `UserSettings()` directly,
    // which already carries the correct spec default (`screenContextDenylist
    // == []`, i.e. built-ins only). `get()` throwing means something more
    // specific went wrong — the stored bytes exist but failed to decode
    // (corrupted data, a future/incompatible format) — and at that point
    // we genuinely don't know what the user's denylist additions were.
    // Falling back to `ScreenContextDenylist(userAdditions: [])` in that
    // case would silently drop protection for any app the user explicitly
    // added, while still reading everything else. `.skipEverything` is
    // the safe failure mode: go quiet rather than read under an unknown
    // configuration. `isEnabled` below is intentionally left fail-open —
    // it's a plain on/off, and failing it closed wouldn't add any privacy
    // protection beyond what this provider's fail-closed default already
    // gives (the denylist itself refuses every window in that state, so
    // whether `isEnabled` says true or false, nothing gets read).
    lazy var screenContextDenylistProvider: @Sendable () -> ScreenContextDenylist = { [settings] in
        guard let stored = try? settings.get() else {
            return .skipEverything
        }
        return ScreenContextDenylist(userAdditions: stored.screenContextDenylist)
    }

    /// Diagnostic ring buffer backing the Screen Context inspector
    /// (Settings → General). In-memory only — dies with the app.
    public lazy var screenContextActivityStore = ScreenContextActivityStore()

    /// THE screen-context strategy, and the only place it is chosen.
    ///
    /// This one expression decides how the focused window is read.
    /// `ScreenContentSource` is the seam: the coordinator sees only the
    /// SHAPE of what comes back, so swapping strategies changes nothing
    /// else anywhere.
    ///
    ///   - today: OCR the screenshot locally, and use the accessibility
    ///     tree when there is no screenshot at all.
    ///   - send the pixels to the provider's vision model instead:
    ///     replace `OCRScreenContentSource` with
    ///     `VisionModelScreenContentSource` — same arguments, nothing
    ///     else edited.
    ///   - accessibility only (no Screen Recording prompt, ever): drop
    ///     the wrapper and pass `AXScreenContentSource` directly.
    lazy var screenContentSource: any ScreenContentSource = FallbackScreenContentSource(
        primary: OCRScreenContentSource(denylist: screenContextDenylistProvider),
        secondary: AXScreenContentSource(denylist: screenContextDenylistProvider),
        reasonWhenSecondaryUsed: .screenshotUnavailable
    )

    lazy var screenContextCoordinator = ScreenContextCoordinator(
        source: screenContentSource,
        cache: screenContextCache,
        denylist: screenContextDenylistProvider,
        isEnabled: { [settings] in
            (try? settings.get())?.screenContextEnabled ?? true
        },
        // MUST hop to the main actor. Every other
        // NSWorkspace.frontmostApplication access in this feature does
        // (see defaultFrontmostApp, whose comment explicitly says not to
        // remove the hop as "redundant"), and `refresh()` runs on the
        // coordinator's own actor, not main. Do NOT "simplify" this to a
        // bare synchronous NSWorkspace read — it would compile, every
        // unit test would still pass, and it would silently violate the
        // invariant the capturer and reader depend on.
        frontmostBundleID: {
            await MainActor.run { NSWorkspace.shared.frontmostApplication?.bundleIdentifier }
        },
        extractImage: { [engine] png in await engine.extractScreenKeywords(image: png) },
        extractText: { [engine] text in await engine.extractScreenKeywords(text: text) },
        apply: { [engine] keywords in await engine.setScreenKeywords(keywords) },
        // `record(_:)` is `@MainActor`-isolated (the whole store is);
        // this `await` is the hop off the coordinator's own actor onto
        // main, the same shape as `frontmostBundleID` above.
        onActivity: { [screenContextActivityStore] activity in
            await screenContextActivityStore.record(activity)
        }
    )

    lazy var screenContextObserver = ScreenContextObserver(onFocusSettled: makeScreenContextFocusSettledAction())

    // Deliberately a method, not the `lazy var` initializer expression
    // above, despite building the exact same closure `screenContextObserver`
    // needs. A closure literal that captures an actor-typed value (here,
    // `screenContextCoordinator`) cannot be written directly inside a
    // `lazy var`'s initializer on a `@MainActor` type — the Swift 6.3
    // compiler rejects it with "default argument cannot be both main
    // actor-isolated and actor-isolated" (confirmed via a minimal repro:
    // the same closure body compiles fine once it's built inside an
    // ordinary method, and fails again the moment it's inlined back into
    // any `lazy var =` initializer, `debounce` default present or not).
    // Moving construction into a method body sidesteps the compiler
    // limitation without changing behaviour — the capture still happens
    // once, synchronously, on the main actor, at first access of
    // `screenContextObserver`.
    private func makeScreenContextFocusSettledAction() -> @Sendable () async -> Void {
        let coordinator = screenContextCoordinator
        return {
            // scheduleRefresh, not refresh: it cancels a still-running
            // extraction for a window the user has already left, so a newer
            // window's context always wins.
            await coordinator.scheduleRefresh()
        }
    }
}
