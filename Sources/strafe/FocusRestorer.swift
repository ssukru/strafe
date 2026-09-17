import AppKit
import ApplicationServices

/// Re-activates the app you last used on a Space after switching to it.
///
/// macOS does not always do this on its own: after a swipe, the app from the
/// previous Space can stay frontmost even though none of its windows are
/// visible, and you have to click before typing. This watches for Space
/// changes and, when the frontmost app has no visible window on the new Space,
/// activates the owner of the topmost visible window there. The WindowServer
/// keeps per-Space z-order, so that window is the one you used last.
///
/// With "Displays have separate Spaces" a swipe changes only the Space on the
/// display under the cursor, so only windows on that display are considered.
/// Otherwise the topmost window on the other display would steal focus.
///
/// Reads only the on-screen window list (owner pid, layer, alpha, bounds) and
/// the cursor position, and writes nothing.
@MainActor
final class FocusRestorer {
    private var observer: NSObjectProtocol?

    func start() {
        guard observer == nil else { return }
        observer = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.activeSpaceDidChangeNotification,
            object: nil,
            queue: .main
        ) { _ in
            // The window list can lag the notification by a frame.
            DispatchQueue.main.asyncAfter(deadline: .now() + .milliseconds(50)) {
                MainActor.assumeIsolated { Self.restore() }
            }
        }
    }

    func stop() {
        if let observer {
            NSWorkspace.shared.notificationCenter.removeObserver(observer)
        }
        observer = nil
    }

    private static func restore() {
        let pids = visibleWindowOwners()
        guard let topPid = pids.first else { return }

        if let front = NSWorkspace.shared.frontmostApplication,
           pids.contains(front.processIdentifier) {
            return
        }

        guard let app = NSRunningApplication(processIdentifier: topPid),
              app.activationPolicy == .regular
        else { return }

        let element = AXUIElementCreateApplication(topPid)
        let result = AXUIElementSetAttributeValue(
            element, kAXFrontmostAttribute as CFString, true as CFBoolean
        )
        if result != .success {
            FileHandle.standardError.write(
                Data("[FocusRestorer] failed to activate pid \(topPid): \(result.rawValue)\n".utf8)
            )
        }
    }

    /// Owner pids of on-screen, normal-layer windows on the display under the
    /// cursor, front to back. Tiny or fully transparent windows (helper windows
    /// some apps keep open) are skipped so they cannot claim focus.
    private static func visibleWindowOwners() -> [pid_t] {
        let options: CGWindowListOption = [.optionOnScreenOnly, .excludeDesktopElements]
        guard let list = CGWindowListCopyWindowInfo(options, kCGNullWindowID) as? [[String: Any]]
        else { return [] }

        let display = cursorDisplayBounds()
        let selfPid = ProcessInfo.processInfo.processIdentifier
        var owners: [pid_t] = []
        for info in list {
            guard let layer = info["kCGWindowLayer"] as? Int, layer == 0,
                  let pid = info["kCGWindowOwnerPID"] as? pid_t, pid != selfPid,
                  let alpha = info["kCGWindowAlpha"] as? Double, alpha > 0,
                  let bounds = info["kCGWindowBounds"] as? [String: Double],
                  let x = bounds["X"], let y = bounds["Y"],
                  let width = bounds["Width"], let height = bounds["Height"],
                  width >= 50, height >= 50
            else { continue }
            if let display {
                let center = CGPoint(x: x + width / 2, y: y + height / 2)
                if !display.contains(center) { continue }
            }
            owners.append(pid)
        }
        return owners
    }

    /// Bounds of the display under the cursor, in the same top-left
    /// coordinate space as `kCGWindowBounds`. Nil if the lookup fails, in
    /// which case every display is considered.
    private static func cursorDisplayBounds() -> CGRect? {
        guard let event = CGEvent(source: nil) else { return nil }
        var display: CGDirectDisplayID = 0
        var count: UInt32 = 0
        guard CGGetDisplaysWithPoint(event.location, 1, &display, &count) == .success,
              count > 0
        else { return nil }
        return CGDisplayBounds(display)
    }
}
