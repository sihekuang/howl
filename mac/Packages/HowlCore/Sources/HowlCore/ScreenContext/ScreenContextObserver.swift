import AppKit
import ApplicationServices
import Foundation
import OSLog

/// Holds the NSNotificationCenter observer token so `deinit` — which
/// is nonisolated even on a `@MainActor` class — can release it
/// without touching actor-isolated state. `NSObjectProtocol` isn't
/// Sendable, but the token is opaque and only ever passed to
/// `removeObserver`, never inspected, so `@unchecked` is safe here.
private final class ObserverToken: @unchecked Sendable {
    var value: NSObjectProtocol?
}

/// Context handed to the AX callback via `refcon`, since
/// `AXObserverCallback` is a C function pointer and cannot capture
/// Swift closures. Holds exactly what the callback needs to do its
/// (trivial) job. `@unchecked Sendable` because it's only ever
/// touched from the main run loop — both by AppKit, which delivers AX
/// notifications there, and by `ScreenContextObserver` itself, which
/// is `@MainActor` and therefore only ever deinitialized from the
/// main actor too — so the callback (main run loop) and `deinit`
/// (main actor) can never interleave; there is no thread on which
/// this could race.
private final class AXCallbackContext: @unchecked Sendable {
    let debouncer: Debouncer
    let action: @Sendable () async -> Void
    init(debouncer: Debouncer, action: @escaping @Sendable () async -> Void) {
        self.debouncer = debouncer
        self.action = action
    }
}

/// Holds the current `AXObserver` plus the pid it's attached to and
/// the context keeping its callback's refcon alive, so `deinit` can
/// tear it down without touching actor-isolated state (same reasoning
/// as `ObserverToken` above). One app's AX observer at a time — a new
/// pid means the previous one must be torn down first.
private final class AXObserverToken: @unchecked Sendable {
    var observer: AXObserver?
    var pid: pid_t?
    var context: AXCallbackContext?
}

/// Bundles the CF/AX references an in-flight attach attempt needs to
/// carry across the hop off the main actor. `AXObserver`/`AXUIElement`
/// aren't declared `Sendable` by the SDK, but the AX APIs are
/// documented as callable from any thread (that's the entire premise
/// of moving `AXObserverAddNotification` off main below) — `@unchecked`
/// reflects that the framework itself guarantees the safety the
/// compiler can't see.
///
/// Holds `context` strongly for the attempt's own lifetime — NOT via
/// `axToken.context` — so a concurrent, unrelated `reattachAXObserver()`
/// call for a different pid (which clears `axToken.context` as part of
/// tearing down whatever the token currently holds) can never drop the
/// only strong reference to `context` while THIS attempt's
/// `AXObserverAddNotification` calls are still using `refcon` (a raw
/// pointer into it). `axToken.context` is only assigned once this
/// specific attempt has actually succeeded and is confirmed still
/// relevant (see the completion block below).
private final class PendingAXAttach: @unchecked Sendable {
    let observer: AXObserver
    let appElement: AXUIElement
    let refcon: UnsafeMutableRawPointer
    let pid: pid_t
    let context: AXCallbackContext
    init(observer: AXObserver, appElement: AXUIElement, refcon: UnsafeMutableRawPointer, pid: pid_t, context: AXCallbackContext) {
        self.observer = observer
        self.appElement = appElement
        self.refcon = refcon
        self.pid = pid
        self.context = context
    }
}

/// Removes `token`'s AX observer from the main run loop and clears
/// it. A free function (not a method) so it can be called both from
/// `ScreenContextObserver`'s (actor-isolated) `stop()`/`teardownAXObserver()`
/// and from its nonisolated `deinit` — none of `CFRunLoopRemoveSource`,
/// `AXObserverGetRunLoopSource`, or `CFRunLoopGetMain` are
/// actor-isolated, so this is safe to call from either context,
/// exactly like the NSWorkspace removal a few lines below.
private func detachAXObserver(_ token: AXObserverToken) {
    if let observer = token.observer {
        CFRunLoopRemoveSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(observer), .commonModes)
    }
    token.observer = nil
    token.pid = nil
    token.context = nil
}

/// The AX callback itself. Kept deliberately trivial per the design
/// note: no AX walking or reading happens here — that stays
/// `ScreenContextCoordinator`'s job (via `WindowTextReader`), off the
/// main actor, after the debounce settles. This only hops to the
/// debouncer.
private func axScreenContextCallback(
    _ observer: AXObserver,
    _ element: AXUIElement,
    _ notification: CFString,
    _ refcon: UnsafeMutableRawPointer?
) {
    guard let refcon else { return }
    let context = Unmanaged<AXCallbackContext>.fromOpaque(refcon).takeUnretainedValue()
    context.debouncer.schedule(context.action)
}

/// Fires `onFocusSettled` once the frontmost app OR its focused
/// window/title has stayed settled for `debounce` seconds, so
/// alt-tabbing (and rapid tab-switching within one app) costs nothing.
///
/// Two AppKit/AX sources feed the same debounce:
/// - `NSWorkspace.didActivateApplicationNotification` — the frontmost
///   app changed.
/// - An `AXObserver` on the frontmost app, watching
///   `kAXFocusedWindowChangedNotification` (a new window became
///   focused within that app) and `kAXTitleChangedNotification` (the
///   focused window's title changed — the signal for tab/document
///   switches within a single window: VS Code, Xcode, Sublime,
///   browsers, and terminals all keep one window and swap documents
///   by tab, and update the window title when they do so;
///   focused-window-changed alone never fires for that case). Being
///   chatty here is safe: `Debouncer` has its own maxDelay backstop
///   against a sustained retitling stream, and the content-hash cache
///   means an unchanged window costs a hash and no LLM call.
///
/// Thin AppKit/AX shim — the timing lives in `Debouncer` and the
/// policy in `ScreenContextCoordinator`, which is where the tests are;
/// this file is intentionally untested per the design doc (there's no
/// practical way to fake a live AX server for a unit test).
@MainActor
public final class ScreenContextObserver {
    private let debouncer: Debouncer
    private let onFocusSettled: @Sendable () async -> Void
    private let token = ObserverToken()
    private let axToken = AXObserverToken()
    private let log = Logger(subsystem: "com.howl.app", category: "screencontext")
    /// Identifies the most recent attach attempt. Registration happens
    /// off the main actor, so several attempts can be in flight at
    /// once — including several for the SAME pid, because `axToken` is
    /// still empty while the first one is in flight and so the
    /// same-pid short-circuit in `reattachAXObserver` cannot fire.
    /// Only the newest attempt may install its run-loop source: an
    /// older one installing after a newer one has already written
    /// `axToken` would overwrite the token's strong reference to the
    /// newer `AXObserver` while that observer's source is still in the
    /// run loop. `AXObserverGetRunLoopSource` is a *Get* — the
    /// observer owns the source — so that leaves the run loop holding
    /// a source whose owner has been freed, with a `refcon` aimed at a
    /// context freed on the next line. `stop()` bumps this too, so an
    /// in-flight attempt cannot repopulate the token after stop.
    /// Compared only for equality, so `&+` wraparound is harmless.
    private var attachGeneration: UInt64 = 0

    public init(debounce: TimeInterval = 0.8,
                onFocusSettled: @escaping @Sendable () async -> Void) {
        self.debouncer = Debouncer(interval: debounce)
        self.onFocusSettled = onFocusSettled
    }

    public func start() {
        guard token.value == nil else { return }
        let action = onFocusSettled
        let debouncer = self.debouncer
        token.value = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            debouncer.schedule(action)
            // A new app is frontmost: the AX observer is per-pid, so
            // the previous app's observer (if any) must be torn down
            // and a fresh one attached to the new frontmost app.
            // `queue: .main` guarantees this closure runs on the main
            // thread (what backs the main actor), but
            // NSNotificationCenter's block-based API isn't statically
            // MainActor-isolated — tell the compiler what's
            // operationally already true rather than spawning an
            // extra Task hop for something this cheap and synchronous.
            MainActor.assumeIsolated {
                self?.reattachAXObserver()
            }
        }
        // Prime with whatever is already focused at startup.
        debouncer.schedule(action)
        reattachAXObserver()
    }

    public func stop() {
        if let observer = token.value {
            NSWorkspace.shared.notificationCenter.removeObserver(observer)
        }
        token.value = nil
        debouncer.cancel()
        // Invalidate any attach attempt still in flight BEFORE tearing
        // the token down. Registration is asynchronous now, so an
        // attempt whose pid is still frontmost would otherwise sail
        // through its own guard, install a run-loop source, and
        // repopulate `axToken` after stop() — leaving the observer
        // firing (and its source installed) past the point the caller
        // asked for it to be gone.
        attachGeneration &+= 1
        detachAXObserver(axToken)
    }

    deinit {
        if let observer = token.value {
            NSWorkspace.shared.notificationCenter.removeObserver(observer)
        }
        debouncer.cancel()
        // Safe without extra synchronization: `ScreenContextObserver`
        // is `@MainActor`, so it is only ever deallocated from the
        // main actor, on the main thread — the same thread the AX
        // callback (`axScreenContextCallback`) and the run loop
        // deliver on. deinit and the callback can never run
        // concurrently with each other; there is nothing to race.
        detachAXObserver(axToken)
    }

    /// Tears down any existing AX observer and attaches a fresh one to
    /// whatever app is frontmost right now. Degrades silently on any
    /// failure (most commonly: no Accessibility permission) — the
    /// existing `NSWorkspace` path keeps working either way, just
    /// without within-app tab/document granularity.
    ///
    /// The local setup (frontmost lookup, tearing down the previous
    /// observer, `AXObserverCreate`) stays synchronous on the main
    /// actor — none of it is IPC into another process. Only
    /// `AXObserverAddNotification` — genuine Mach IPC into the
    /// just-activated app's own accessibility server, with no
    /// messaging timeout otherwise bounding it — is moved off the
    /// main actor below, so a hung, beachballing, or mid-launch app
    /// can never block Howl's UI thread on activation.
    private func reattachAXObserver() {
        // Bumped at the very top, deliberately covering the two early
        // returns below as well: both leave the observer state in a
        // shape that no older in-flight attempt should be allowed to
        // finish writing into.
        attachGeneration &+= 1
        let myAttach = attachGeneration

        guard let app = NSWorkspace.shared.frontmostApplication else {
            detachAXObserver(axToken)
            return
        }
        let pid = app.processIdentifier
        // Already attached to this exact app — nothing to do. Avoids
        // needless teardown/recreate on a redundant activation event.
        if axToken.pid == pid, axToken.observer != nil { return }
        detachAXObserver(axToken)

        var observerRef: AXObserver?
        guard AXObserverCreate(pid, axScreenContextCallback, &observerRef) == .success,
              let observer = observerRef else {
            // No Accessibility permission, or an app AXObserverCreate
            // otherwise refuses — never throw, never surface UI, just
            // keep the NSWorkspace-only behaviour already in effect.
            log.debug("screen context AX observer create failed")
            return
        }

        let context = AXCallbackContext(debouncer: debouncer, action: onFocusSettled)
        let refcon = Unmanaged.passUnretained(context).toOpaque()
        let appElement = AXUIElementCreateApplication(pid)

        // Bounds AXObserverAddNotification below: without this, a
        // hung/beachballing/mid-launch target app can block the
        // calling thread for the full (unbounded-feeling) AX default
        // timeout. This call itself is local/synchronous — it just
        // configures the timeout used by future calls through
        // `appElement` — so it's fine to leave on the main actor.
        AXUIElementSetMessagingTimeout(appElement, 0.25)

        let attach = PendingAXAttach(observer: observer, appElement: appElement, refcon: refcon, pid: pid, context: context)

        Task.detached { [weak self] in
            let addedFocusedWindow = AXObserverAddNotification(
                attach.observer, attach.appElement,
                kAXFocusedWindowChangedNotification as CFString, attach.refcon
            ) == .success
            let addedTitle = AXObserverAddNotification(
                attach.observer, attach.appElement,
                kAXTitleChangedNotification as CFString, attach.refcon
            ) == .success

            await MainActor.run {
                guard let self else { return }
                // Is this still the newest attach attempt? Checked
                // BEFORE the frontmost-app test, because the pid test
                // cannot catch the dangerous case: two attempts for
                // the SAME pid both see that pid frontmost and both
                // pass it. That happens on ordinary alt-tabbing
                // (A -> B -> A), and on an activation arriving just
                // after `start()`'s own priming call — the in-flight
                // window is up to ~0.5s for exactly the hung or
                // mid-launch apps the messaging timeout exists for.
                // It also catches `stop()`, which bumps the
                // generation. Discarding here is safe and self-healing
                // in every case: nothing was added to the run loop, so
                // releasing `attach` releases the observer, its
                // (uninstalled) source, and `context` together, and
                // `axToken.pid` stays nil so the next activation
                // retries.
                guard myAttach == self.attachGeneration else { return }
                // The frontmost app may have changed again while this
                // was in flight (another activation dispatched its own
                // reattachAXObserver, which may already have attached
                // a newer observer, or none at all). Only finish
                // attaching if this attempt's target is STILL
                // frontmost — otherwise this result is stale and must
                // be discarded. A wrongly-discarded attach still
                // self-heals: the next activation (or this same app
                // regaining focus) attempts again.
                guard NSWorkspace.shared.frontmostApplication?.processIdentifier == attach.pid else {
                    return
                }
                guard addedFocusedWindow || addedTitle else {
                    // Neither notification could be registered —
                    // nothing to observe on this app. Degrade
                    // silently. `context` is owned by `attach` and is
                    // released when this attempt ends; nothing was
                    // registered and no source was installed, so the
                    // `refcon` can never be dereferenced.
                    self.log.debug("screen context AX add-notification failed")
                    return
                }
                // Belt-and-braces: never install a second source while
                // the token still holds one. The generation guard
                // above already makes this unreachable (the token is
                // emptied synchronously before each attempt is
                // dispatched, and only the newest attempt gets here),
                // but installing over a live token is precisely the
                // use-after-free this fix removes, so refuse to do it
                // structurally rather than by argument. NOT a
                // replacement for the generation guard: on its own it
                // would still allow a post-`stop()` install.
                detachAXObserver(self.axToken)
                CFRunLoopAddSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(attach.observer), .commonModes)
                self.axToken.observer = attach.observer
                self.axToken.pid = attach.pid
                // Ownership of `context` transfers to the token now
                // that registration has actually succeeded — `detachAXObserver`
                // will release it on the next teardown.
                self.axToken.context = attach.context
            }
        }
    }
}
