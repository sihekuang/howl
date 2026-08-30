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
/// touched from the main actor — by AppKit, which delivers AX
/// notifications on the main run loop, and by the attach/teardown
/// paths, which are all main-actor-isolated. The callback and a
/// teardown therefore can never interleave.
///
/// Note what this does NOT rest on: `ScreenContextObserver` being
/// `@MainActor` does not mean it is *deallocated* on the main actor.
/// `deinit` is nonisolated and runs on whichever thread drops the last
/// reference, which is exactly why `deinit` hands its teardown to the
/// main actor instead of doing it inline — see `deinit` below. Were it
/// to release this object off-main, it could free the very memory the
/// main run loop was mid-callout dereferencing through `refcon`.
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

/// The attach-attempt generation counter, in a lock-guarded box
/// rather than as plain `@MainActor` stored state on the observer.
///
/// Two readers live off the main actor: the AX registration queue
/// re-checks it *before* paying for its IPC (see `axRegistrationQueue`),
/// and `deinit` — nonisolated, and running wherever the last reference
/// happened to drop — bumps it so a still-queued attempt skips that
/// IPC entirely. Attempts are still only ever *started* from the main
/// actor, so this box provides synchronization, not ownership.
private final class AttachGeneration: @unchecked Sendable {
    private let lock = NSLock()
    private var value: UInt64 = 0

    /// Invalidates every attempt currently in flight and returns the
    /// id of the new one. `&+` wraps rather than traps; the counter is
    /// only ever compared for equality, never for ordering, so
    /// wraparound (which needs 2^64 activations) is harmless anyway.
    @discardableResult
    func bump() -> UInt64 {
        lock.lock(); defer { lock.unlock() }
        value &+= 1
        return value
    }

    func isCurrent(_ id: UInt64) -> Bool {
        lock.lock(); defer { lock.unlock() }
        return id == value
    }
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
/// it. A free function (not a method) so it can be called without a
/// `ScreenContextObserver` in hand: `stop()` and the completion of an
/// attach attempt both call it on the main actor, and `deinit`'s
/// main-actor teardown hop calls it holding only the token, never the
/// (already dying) observer object.
///
/// Every caller is on the main actor. That is a requirement, not a
/// convenience: `CFRunLoopRemoveSource` is thread-safe but does NOT
/// wait for an in-progress callout, so clearing `token.context` off
/// the main thread could release the `AXCallbackContext` while the
/// main run loop is still dereferencing that same `refcon` inside
/// `axScreenContextCallback`.
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
    /// context freed on the next line. `stop()` and `deinit` bump it
    /// too, so an in-flight attempt cannot repopulate the token after
    /// teardown.
    private let attachGeneration = AttachGeneration()

    /// Dedicated serial queue for the blocking
    /// `AXObserverAddNotification` IPC.
    ///
    /// Mirrors `LibhowlEngine.screenContextQueue` and for the same
    /// reason: getting a blocking call off the main actor is only half
    /// the job, because a `Task.detached` still parks a
    /// Swift-concurrency cooperative-pool thread, and that pool is
    /// small and shared across the whole process. Two
    /// `AXObserverAddNotification` calls at a 0.25s messaging timeout
    /// can block for ~0.5s against a hung or mid-launch app, and rapid
    /// alt-tabbing across several such apps would otherwise occupy
    /// several pool threads at once.
    ///
    /// Serial, not concurrent, and that buys a second thing: because a
    /// queued attempt re-checks `attachGeneration` before doing any
    /// IPC, a burst of activations collapses to roughly ONE real
    /// registration — every attempt but the newest finds itself
    /// already superseded and returns without touching AX at all.
    /// The generation counter is what makes that safe.
    ///
    /// The trade, accepted deliberately: one hung app's ~0.5s delays
    /// the *next* app's attach by up to ~0.5s. Attach is not on the
    /// dictation path and the focus debounce is 0.8s anyway, so this
    /// is invisible — the same trade the LLM extraction queue already
    /// makes.
    private static let axRegistrationQueue = DispatchQueue(
        label: "com.howl.app.screencontext-axregister", qos: .utility
    )

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
        attachGeneration.bump()
        detachAXObserver(axToken)
    }

    deinit {
        // `deinit` is nonisolated even on a `@MainActor` class: it
        // runs on whichever thread drops the last reference, NOT
        // necessarily the main one. The previous version tore the AX
        // observer down inline on the strength of a comment asserting
        // otherwise, and that assertion is not something the type
        // system enforces or a future owner is obliged to honour.
        //
        // The race it left open is concrete. `CFRunLoopRemoveSource`
        // is thread-safe but does NOT wait for an in-progress callout,
        // so clearing `token.context` from another thread can release
        // the `AXCallbackContext` while the main run loop is still
        // inside `axScreenContextCallback` dereferencing that same
        // `refcon` — a use-after-free reached by a different door than
        // the one the generation counter closed.
        //
        // So the CF/AppKit teardown is handed to the main actor. What
        // makes that legal from a dying object is capturing the TOKEN
        // OBJECTS rather than `self`: both are independent
        // `@unchecked Sendable` reference types, so the closure keeps
        // exactly the state it needs alive on its own refcount without
        // resurrecting the observer.
        let notificationToken = token
        let observerToken = axToken
        let debouncer = self.debouncer

        // Synchronous, and first: invalidates any attempt sitting on
        // the registration queue so it skips its IPC and can never
        // install into a token that is about to be torn down.
        attachGeneration.bump()
        debouncer.cancel()

        Task { @MainActor in
            if let observer = notificationToken.value {
                NSWorkspace.shared.notificationCenter.removeObserver(observer)
            }
            notificationToken.value = nil
            detachAXObserver(observerToken)
            // Again, after the source is gone. The hop above is a
            // window in which the run loop can still deliver one AX
            // notification, and that callback would schedule a fresh
            // debounced run through the context it still (legally)
            // holds. Cancelling once more here retires it. Only a main
            // thread stalled longer than the whole debounce interval
            // could get an action out, and even that would be
            // memory-safe — every object the callback touches is kept
            // alive by these captures.
            debouncer.cancel()
        }
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
    /// messaging timeout otherwise bounding it — runs on
    /// `axRegistrationQueue` below, so a hung, beachballing, or
    /// mid-launch app can block neither Howl's UI thread nor a
    /// cooperative-pool thread on activation.
    private func reattachAXObserver() {
        // Bumped at the very top, deliberately covering the two early
        // returns below as well: both leave the observer state in a
        // shape that no older in-flight attempt should be allowed to
        // finish writing into.
        let myAttach = attachGeneration.bump()

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

        // Deliberately captures the token objects and the generation
        // box rather than `self`. Nothing below needs the observer
        // object itself, and not holding it means an attempt in flight
        // neither keeps a dying observer alive nor has to reason about
        // a half-torn-down one: `deinit` bumps the generation, so a
        // queued attempt is superseded exactly the way `stop()`
        // supersedes one, and the token it would have written into is
        // kept alive independently by these captures.
        let generation = self.attachGeneration
        let axToken = self.axToken
        let log = self.log

        Self.axRegistrationQueue.async {
            // Cheap supersede check BEFORE the expensive IPC. This is
            // what collapses a burst of activations to roughly one
            // real registration: on a serial queue every attempt but
            // the newest arrives already superseded and skips AX
            // entirely. Correctness does not depend on it — the
            // main-actor check below is the one that guards the
            // install — so a race here costs at worst one wasted IPC.
            guard generation.isCurrent(myAttach) else { return }

            let addedFocusedWindow = AXObserverAddNotification(
                attach.observer, attach.appElement,
                kAXFocusedWindowChangedNotification as CFString, attach.refcon
            ) == .success
            let addedTitle = AXObserverAddNotification(
                attach.observer, attach.appElement,
                kAXTitleChangedNotification as CFString, attach.refcon
            ) == .success

            Task { @MainActor in
                // Is this still the newest attach attempt? Checked
                // BEFORE the frontmost-app test, because the pid test
                // cannot catch the dangerous case: two attempts for
                // the SAME pid both see that pid frontmost and both
                // pass it. That happens on ordinary alt-tabbing
                // (A -> B -> A), and on an activation arriving just
                // after `start()`'s own priming call — the in-flight
                // window is up to ~0.5s for exactly the hung or
                // mid-launch apps the messaging timeout exists for.
                // It also catches `stop()` and `deinit`, both of which
                // bump the generation.
                //
                // Discarding here is always safe: nothing was added to
                // the run loop, so releasing `attach` releases the
                // observer, its (uninstalled) source, and `context`
                // together, and the `refcon` is never dereferenced.
                // It is also always self-healing, though by two
                // different routes — either this attempt was
                // superseded by one that has already attached (so the
                // app IS observed, and `axToken` holds that newer
                // observer and its pid), or no attach succeeded and
                // `axToken.pid` is nil, so the next activation
                // retries.
                guard generation.isCurrent(myAttach) else { return }
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
                    log.debug("screen context AX add-notification failed")
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
                detachAXObserver(axToken)
                CFRunLoopAddSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(attach.observer), .commonModes)
                axToken.observer = attach.observer
                axToken.pid = attach.pid
                // Ownership of `context` transfers to the token now
                // that registration has actually succeeded — `detachAXObserver`
                // will release it on the next teardown.
                axToken.context = attach.context
            }
        }
    }
}
