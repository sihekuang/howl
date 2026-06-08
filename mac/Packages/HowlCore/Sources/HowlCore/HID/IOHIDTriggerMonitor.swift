import Foundation
import IOKit
import IOKit.hid
import os

private let log = Logger(subsystem: "com.howl.app", category: "hid")

// HID usage-table values (IOHIDUsageTables.h). Declared locally as stable,
// well-known constants so we don't depend on them being surfaced into Swift.
private let kPageGenericDesktop = 0x01
private let kPageButton = 0x09
private let kUsageGD_X = 0x30
private let kUsageGD_Y = 0x31
private let kUsageGD_Wheel = 0x38

public enum HIDTriggerError: Error {
    case openFailed(IOReturn)
}

/// `IOHIDManager`-backed HID trigger monitor.
///
/// Opens a match-all manager in passive **listen** mode (`kIOHIDOptionsTypeNone`,
/// not seizing) so the device's normal function is preserved — we observe, we
/// never consume. Scheduled on the main run loop, so input callbacks arrive on
/// the main thread; all mutable state is therefore touched on one thread only,
/// which is why `@unchecked Sendable` is sound here (mirrors
/// `CarbonHotkeyMonitor`).
///
/// Three modes:
/// - `.bound`     → only the matching element's down/up fires press/release.
/// - `.discovery` → log every element edge so the user can read off the
///   device's vendor/product/usage (entered via `start(nil, …)`).
/// - `.learn`     → capture the next learnable edge (see `HIDLearnFilter`),
///   report it, then stop (entered via `learnNextBinding`).
public final class IOHIDTriggerMonitor: HIDTriggerMonitor, @unchecked Sendable {
    private var manager: IOHIDManager?
    private var mode: Mode?
    fileprivate var isHeld = false

    private enum Mode {
        case bound(HIDBinding, onPress: @Sendable () -> Void, onRelease: @Sendable () -> Void)
        case discovery
        case learn(@Sendable (HIDBinding) -> Void)

        var label: String {
            switch self {
            case .bound: return "bound"
            case .discovery: return "discovery"
            case .learn: return "learn"
            }
        }
    }

    public init() {}

    /// Backoff for `IOHIDManagerOpen`. Like the Accessibility tap, the Input
    /// Monitoring TCC trust cache can lag a fresh grant by up to a couple of
    /// seconds, so a just-granted permission may fail the first open.
    private static let openRetryDelaysNs: [UInt64] = [
        0,
        250_000_000,
        750_000_000,
        1_500_000_000,
        3_000_000_000,
    ]

    public func start(
        _ binding: HIDBinding?,
        onPress: @escaping @Sendable () -> Void,
        onRelease: @escaping @Sendable () -> Void
    ) async throws {
        let mode: Mode = binding.map { .bound($0, onPress: onPress, onRelease: onRelease) } ?? .discovery
        try await open(mode)
    }

    public func learnNextBinding(_ onLearned: @escaping @Sendable (HIDBinding) -> Void) async throws {
        try await open(.learn(onLearned))
    }

    /// Shared setup for all three modes: a match-all manager in listen mode,
    /// scheduled on the main run loop, opened with retry.
    private func open(_ mode: Mode) async throws {
        stop()
        self.mode = mode
        isHeld = false

        let mgr = IOHIDManagerCreate(kCFAllocatorDefault, IOOptionBits(kIOHIDOptionsTypeNone))
        IOHIDManagerSetDeviceMatching(mgr, nil)   // match all HID devices
        let selfPtr = Unmanaged.passUnretained(self).toOpaque()
        IOHIDManagerRegisterInputValueCallback(mgr, hidInputValueCallback, selfPtr)
        IOHIDManagerRegisterDeviceRemovalCallback(mgr, hidDeviceRemovalCallback, selfPtr)
        IOHIDManagerScheduleWithRunLoop(mgr, CFRunLoopGetMain(), CFRunLoopMode.defaultMode.rawValue)
        manager = mgr

        var lastRC: IOReturn = kIOReturnError
        for (idx, delay) in Self.openRetryDelaysNs.enumerated() {
            if delay > 0 { try? await Task.sleep(nanoseconds: delay) }
            let rc = IOHIDManagerOpen(mgr, IOOptionBits(kIOHIDOptionsTypeNone))
            if rc == kIOReturnSuccess {
                if idx > 0 { log.notice("HID open succeeded on attempt \(idx + 1, privacy: .public)") }
                log.notice("HID monitor started (\(mode.label, privacy: .public) mode)")
                return
            }
            lastRC = rc
            log.error("HID open attempt \(idx + 1, privacy: .public)/\(Self.openRetryDelaysNs.count, privacy: .public) rc=\(rc, privacy: .public) — Input Monitoring may not be granted yet")
        }
        stop()
        throw HIDTriggerError.openFailed(lastRC)
    }

    public func stop() {
        if let mgr = manager {
            IOHIDManagerUnscheduleFromRunLoop(mgr, CFRunLoopGetMain(), CFRunLoopMode.defaultMode.rawValue)
            IOHIDManagerClose(mgr, IOOptionBits(kIOHIDOptionsTypeNone))
            manager = nil
        }
        mode = nil
        isHeld = false
    }

    fileprivate func handleInputValue(_ value: IOHIDValue) {
        guard let mode else { return }
        let element = IOHIDValueGetElement(value)
        let usagePage = Int(IOHIDElementGetUsagePage(element))
        let usage = Int(IOHIDElementGetUsage(element))
        let intValue = IOHIDValueGetIntegerValue(value)
        let device = IOHIDElementGetDevice(element)
        let vid = Self.intProperty(device, kIOHIDVendorIDKey)
        let pid = Self.intProperty(device, kIOHIDProductIDKey)

        switch mode {
        case let .bound(binding, onPress, onRelease):
            guard vid == binding.vendorID, pid == binding.productID,
                  usagePage == binding.usagePage, usage == binding.usage else { return }
            let down = intValue != 0
            if down, !isHeld {
                isHeld = true
                log.info("HID bound element down → press")
                onPress()
            } else if !down, isHeld {
                isHeld = false
                log.info("HID bound element up → release")
                onRelease()
            }

        case .discovery:
            // Suppress the continuous pointer axes (mouse X/Y/wheel) so the
            // button edges the user is hunting for aren't buried; surface
            // buttons at `.notice` so they stand out from other elements.
            if usagePage == kPageGenericDesktop,
               usage == kUsageGD_X || usage == kUsageGD_Y || usage == kUsageGD_Wheel {
                return
            }
            if usagePage == kPageButton {
                log.notice("HID discovery BUTTON vid=0x\(UInt(vid), format: .hex, privacy: .public) pid=0x\(UInt(pid), format: .hex, privacy: .public) button=\(usage, privacy: .public) value=\(intValue, privacy: .public)")
            } else {
                log.info("HID discovery element vid=0x\(UInt(vid), format: .hex, privacy: .public) pid=0x\(UInt(pid), format: .hex, privacy: .public) usagePage=0x\(UInt(usagePage), format: .hex, privacy: .public) usage=0x\(UInt(usage), format: .hex, privacy: .public) value=\(intValue, privacy: .public)")
            }

        case let .learn(onLearned):
            guard let binding = HIDLearnFilter.binding(
                vendorID: vid, productID: pid, usagePage: usagePage, usage: usage, value: intValue
            ) else { return }
            // Capture exactly one: clear the mode so any further edges before
            // the caller rebinds are ignored. We deliberately do NOT close the
            // manager here — that's unsafe from inside its own callback, and
            // the caller releases/reopens the device via stop()+start (bound)
            // as one ordered step, avoiding a stop/start race on this instance.
            self.mode = nil
            log.notice("HID learned binding vid=0x\(UInt(vid), format: .hex, privacy: .public) pid=0x\(UInt(pid), format: .hex, privacy: .public) usagePage=0x\(UInt(usagePage), format: .hex, privacy: .public) usage=0x\(UInt(usage), format: .hex, privacy: .public)")
            onLearned(binding)
        }
    }

    fileprivate func handleRemoval(_ device: IOHIDDevice) {
        guard isHeld, let mode, case let .bound(binding, _, onRelease) = mode else { return }
        let vid = Self.intProperty(device, kIOHIDVendorIDKey)
        let pid = Self.intProperty(device, kIOHIDProductIDKey)
        guard vid == binding.vendorID, pid == binding.productID else { return }
        isHeld = false
        log.notice("HID bound device removed mid-hold → synthetic release")
        onRelease()
    }

    private static func intProperty(_ device: IOHIDDevice, _ key: String) -> Int {
        guard let prop = IOHIDDeviceGetProperty(device, key as CFString) else { return 0 }
        return (prop as? Int) ?? 0
    }
}

// File-scope C callbacks. `context` is an unretained `IOHIDTriggerMonitor`.
// Both fire on the main run loop (the manager is scheduled there), so they
// touch the monitor's state on the main thread only.
private func hidInputValueCallback(
    _ context: UnsafeMutableRawPointer?,
    _ result: IOReturn,
    _ sender: UnsafeMutableRawPointer?,
    _ value: IOHIDValue
) {
    guard let context else { return }
    Unmanaged<IOHIDTriggerMonitor>.fromOpaque(context).takeUnretainedValue().handleInputValue(value)
}

private func hidDeviceRemovalCallback(
    _ context: UnsafeMutableRawPointer?,
    _ result: IOReturn,
    _ sender: UnsafeMutableRawPointer?,
    _ device: IOHIDDevice
) {
    guard let context else { return }
    Unmanaged<IOHIDTriggerMonitor>.fromOpaque(context).takeUnretainedValue().handleRemoval(device)
}
