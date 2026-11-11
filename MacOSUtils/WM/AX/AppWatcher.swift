import AppKit
import ApplicationServices

/// One running application: its AX element and an AXObserver delivering window events.
///
/// Observer callbacks are delivered on the main run loop, so everything here is main-actor.
/// (AeroSpace's planned thread-per-app is the upgrade path if a hung app proves a problem;
/// for now the global AX messaging timeout bounds the damage.)
final class AppWatcher {
    let pid: pid_t
    let app: NSRunningApplication
    let element: AXUIElement
    let bundleID: String?
    let name: String

    /// Called for every AX notification: (notification name, element it's about).
    var onNotification: ((String, AXUIElement) -> Void)?

    private var observer: AXObserver?
    private var observedWindows = Set<CGWindowID>()

    static let appNotifications = ["AXWindowCreated", "AXFocusedWindowChanged", "AXMainWindowChanged"]
    static let windowNotifications = ["AXUIElementDestroyed", "AXWindowMoved", "AXWindowResized",
                                      "AXWindowMiniaturized", "AXWindowDeminiaturized"]

    init(app: NSRunningApplication) {
        self.app = app
        self.pid = app.processIdentifier
        self.element = AXUIElementCreateApplication(app.processIdentifier)
        self.bundleID = app.bundleIdentifier
        self.name = app.localizedName ?? app.bundleIdentifier ?? "pid \(app.processIdentifier)"
    }

    var isHidden: Bool { app.isHidden }
    var isObserving: Bool { observer != nil }

    /// Creates the observer if needed. Can fail for an app that has only just launched and
    /// isn't answering AX yet — the window manager retries on its next scan.
    @discardableResult
    func ensureObserver() -> Bool {
        if observer != nil { return true }
        var obs: AXObserver?
        guard AXObserverCreate(pid, axObserverCallback, &obs) == .success, let obs else { return false }

        let refcon = Unmanaged.passUnretained(self).toOpaque()
        var registered = false
        for n in Self.appNotifications {
            if AXObserverAddNotification(obs, element, n as CFString, refcon) == .success { registered = true }
        }
        guard registered else { return false }

        CFRunLoopAddSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(obs), .commonModes)
        observer = obs
        return true
    }

    func observe(window: AXUIElement, id: CGWindowID) {
        guard let observer, !observedWindows.contains(id) else { return }
        let refcon = Unmanaged.passUnretained(self).toOpaque()
        for n in Self.windowNotifications {
            AXObserverAddNotification(observer, window, n as CFString, refcon)
        }
        observedWindows.insert(id)
    }

    func forget(windowID: CGWindowID) {
        observedWindows.remove(windowID)
    }

    func invalidate() {
        if let observer {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(observer), .commonModes)
        }
        observer = nil
        observedWindows.removeAll()
        onNotification = nil
    }

    // MARK: Queries

    var windows: [AXUIElement] { AX.elements(element, "AXWindows") }
    var focusedWindow: AXUIElement? { AX.element(element, "AXFocusedWindow") }

    fileprivate func deliver(_ notification: String, _ element: AXUIElement) {
        onNotification?(notification, element)
    }
}

/// C callback for all AXObservers. Runs on the main run loop (the source was added there).
private nonisolated func axObserverCallback(
    _ observer: AXObserver,
    _ element: AXUIElement,
    _ notification: CFString,
    _ refcon: UnsafeMutableRawPointer?
) {
    guard let refcon else { return }
    let name = notification as String
    MainActor.assumeIsolated {
        Unmanaged<AppWatcher>.fromOpaque(refcon).takeUnretainedValue().deliver(name, element)
    }
}
