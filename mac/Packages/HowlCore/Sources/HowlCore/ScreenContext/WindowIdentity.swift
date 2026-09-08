import CoreGraphics
import Foundation

/// The CGWindowID of an app's largest on-screen, layer-0 window — the
/// same choice `chooseWindow` makes for screenshots, so the two readers
/// name the same window. Public CGWindowList API; nothing private.
///
/// Nil when the app has no such window, in which case the caller
/// falls back to the title (see `WindowSnapshot.windowKey`).
func frontmostWindowID(pid: pid_t) -> UInt32? {
    guard let list = CGWindowListCopyWindowInfo(
        [.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID
    ) as? [[String: Any]] else { return nil }
    var best: (id: UInt32, area: Double)?
    for info in list {
        guard let owner = info[kCGWindowOwnerPID as String] as? pid_t, owner == pid,
              (info[kCGWindowLayer as String] as? Int ?? 0) == 0,
              let number = info[kCGWindowNumber as String] as? UInt32,
              let bounds = info[kCGWindowBounds as String] as? [String: Double] else { continue }
        let area = (bounds["Width"] ?? 0) * (bounds["Height"] ?? 0)
        if best == nil || area > best!.area { best = (number, area) }
    }
    return best?.id
}
