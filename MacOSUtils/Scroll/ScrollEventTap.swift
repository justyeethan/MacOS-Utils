import AppKit
import CoreGraphics
import os

/// Intercepts every scroll event in the login session and rewrites its direction per device.
///
/// Structure follows Scroll Reverser's MouseTap.m:
///
/// * a **passive** (listen-only) tap for gesture events, used only to count fingers on the
///   trackpad / Magic Mouse. Listen-only so it can never interfere with system gestures.
/// * an **active** tap for scroll-wheel events, which classifies the source and rewrites deltas.
///
/// Difference from Scroll Reverser: both taps run on a dedicated high-priority thread instead
/// of the main run loop. In an all-in-one app the window manager will make blocking
/// Accessibility calls on other threads and SwiftUI owns the main thread; if a tap callback
/// is delayed long enough, macOS disables the tap (`tapDisabledByTimeout`) and scrolling
/// stutters. Keeping input on its own thread avoids that. The keyboard tap for the window
/// manager's hotkeys can later join this same thread (see docs/TILING_WM_PLAN.md).
///
/// Threading: everything prefixed `tap…` and `classifier` is touched only on the tap thread.
nonisolated final class ScrollEventTap: @unchecked Sendable {

    enum StartError: Error {
        /// The process isn't trusted for Accessibility, so macOS refused to create the tap.
        case notTrusted
        case alreadyRunning
    }

    let settings: ScrollSettingsStore

    /// Called on the tap thread whenever the detected source changes. Hop to the main actor
    /// before touching UI.
    var onSourceChange: (@Sendable (ScrollSource) -> Void)?

    // Tap-thread state
    private var classifier = ScrollSourceClassifier()
    private var activeTap: CFMachPort?
    private var passiveTap: CFMachPort?

    // Lifecycle state (guarded by `lock`)
    private let lock = NSLock()
    private var thread: Thread?
    private var runLoop: CFRunLoop?

    init(settings: ScrollSettingsStore) {
        self.settings = settings
    }

    deinit {
        stop()
    }

    var isRunning: Bool {
        lock.withLock { thread != nil }
    }

    // MARK: - Lifecycle

    func start() throws {
        lock.lock()
        defer { lock.unlock() }
        guard thread == nil else { throw StartError.alreadyRunning }

        let refcon = Unmanaged.passUnretained(self).toOpaque()

        // Active tap: may modify scroll events. Requires Accessibility trust; returns nil without it.
        guard let active = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .tailAppendEventTap,
            options: .defaultTap,
            eventsOfInterest: CGEventMask(1) << CGEventType.scrollWheel.rawValue,
            callback: scrollTapCallback,
            userInfo: refcon
        ) else {
            throw StartError.notTrusted
        }

        // Passive tap: gesture events only, to count touches. Not fatal if it fails —
        // the classifier then falls back to "continuous vs discrete" only.
        let passive = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .tailAppendEventTap,
            options: .listenOnly,
            eventsOfInterest: CGEventMask(NSEvent.EventTypeMask.gesture.rawValue),
            callback: scrollTapCallback,
            userInfo: refcon
        )

        if passive == nil {
            Self.log.error("[scroll] gesture tap could not be created; trackpad detection falls back to scroll phases")
        }
        activeTap = active
        passiveTap = passive
        classifier = ScrollSourceClassifier()

        let ready = DispatchSemaphore(value: 0)
        let thread = Thread { [self] in
            let rl = CFRunLoopGetCurrent()!
            for port in [self.activeTap, self.passiveTap].compactMap({ $0 }) {
                let src = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, port, 0)
                CFRunLoopAddSource(rl, src, .commonModes)
                CGEvent.tapEnable(tap: port, enable: true)
            }
            self.lock.withLock { self.runLoop = rl }
            ready.signal()
            CFRunLoopRun()   // returns when stop() calls CFRunLoopStop
        }
        thread.name = "MacOSUtils.InputTap"
        thread.qualityOfService = .userInteractive
        self.thread = thread
        thread.start()

        // Wait for the run loop to exist so stop() can always find it. Unlock while waiting,
        // because the thread takes the lock to publish its run loop.
        lock.unlock()
        ready.wait()
        lock.lock()
    }

    /// macOS can leave event taps disabled across sleep without sending the usual
    /// "tap disabled" event; switch them back on if so.
    func ensureEnabled() {
        let ports = lock.withLock { [activeTap, passiveTap] }.compactMap { $0 }
        for port in ports where !CGEvent.tapIsEnabled(tap: port) {
            CGEvent.tapEnable(tap: port, enable: true)
        }
    }

    func stop() {
        lock.lock()
        let rl = runLoop
        let ports = [activeTap, passiveTap].compactMap { $0 }
        runLoop = nil
        thread = nil
        activeTap = nil
        passiveTap = nil
        lock.unlock()

        for port in ports {
            CGEvent.tapEnable(tap: port, enable: false)
            CFMachPortInvalidate(port)
        }
        if let rl { CFRunLoopStop(rl) }
    }

    // MARK: - Event handling (tap thread)

    fileprivate func handle(type: CGEventType, event: CGEvent) -> Unmanaged<CGEvent>? {
        switch type {
        case .tapDisabledByTimeout, .tapDisabledByUserInput:
            // macOS turns taps off if a callback is slow or the user hits the secure-input
            // kill switch. Turn them back on.
            if let activeTap { CGEvent.tapEnable(tap: activeTap, enable: true) }
            if let passiveTap { CGEvent.tapEnable(tap: passiveTap, enable: true) }

        case .scrollWheel:
            handleScroll(event)

        default:
            if UInt(type.rawValue) == NSEvent.EventType.gesture.rawValue {
                handleGesture(event)
            }
        }
        return Unmanaged.passUnretained(event)
    }

    private var lastLoggedTouches = -1

    private func handleGesture(_ event: CGEvent) {
        guard let ns = NSEvent(cgEvent: event) else { return }
        let touching = ns.touches(matching: .touching, in: nil).count
        if touching != lastLoggedTouches {
            lastLoggedTouches = touching
            Self.log.debug("[scroll] gesture touches=\(touching) allTouches=\(ns.allTouches().count)")
        }
        classifier.recordTouches(touching, at: Self.now())
    }

    private static let log = Logger(subsystem: "MacOSUtils", category: "Scroll")

    private func handleScroll(_ event: CGEvent) {
        let settings = self.settings.current
        let ns = NSEvent(cgEvent: event)

        let info = ScrollEventInfo(
            isContinuous: event.getIntegerValueField(.scrollWheelEventIsContinuous) != 0,
            scrollPhase: ScrollEventInfo.Phase(
                rawValue: event.getIntegerValueField(.scrollWheelEventScrollPhase)) ?? ScrollEventInfo.Phase.none,
            momentumPhase: ScrollEventInfo.MomentumPhase(
                rawValue: event.getIntegerValueField(.scrollWheelEventMomentumPhase)) ?? ScrollEventInfo.MomentumPhase.none,
            isDirectionInvertedFromDevice: ns?.isDirectionInvertedFromDevice ?? false,
            sourcePID: event.getIntegerValueField(.eventSourceUnixProcessID)
        )

        // Always classify, even when disabled, so the source state stays in sync with the
        // event stream and is correct the moment the user re-enables.
        let previous = classifier.lastSource
        let source = classifier.classify(info, now: Self.now())
        if source != previous { onSourceChange?(source) }

        let lineY = event.getIntegerValueField(.scrollWheelEventDeltaAxis1)
        let plan = ScrollTransform.plan(source: source, info: info, lineY: lineY, settings: settings)

        // One line per gesture start / wheel click / source change — enough to diagnose
        // detection without flooding the console. Filter Xcode's console with "[scroll]".
        if !info.isContinuous || info.scrollPhase == .began || info.scrollPhase == .mayBegin
            || info.momentumPhase == .begin || source != previous {
            Self.log.debug("""
                [scroll] source=\(source.rawValue, privacy: .public) \
                continuous=\(info.isContinuous) phase=\(info.scrollPhase.rawValue) \
                momentum=\(info.momentumPhase.rawValue) \
                macNatural=\(info.isDirectionInvertedFromDevice) \
                touchEventsSeen=\(self.classifier.touchEventCount) \
                gestureTap=\(self.passiveTap != nil) \
                dy=\(lineY) flipV=\(plan.vertical) flipH=\(plan.horizontal) \
                pid=\(info.sourcePID)
                """)
        }

        guard !plan.isIdentity else { return }

        let hid = IOHIDEventBridge.event(for: event)
        let deltas = ScrollDeltas(event: event, hid: hid)
        ScrollTransform.apply(plan, to: deltas).write(to: event, hid: hid, plan: plan)
    }

    private static func now() -> UInt64 {
        DispatchTime.now().uptimeNanoseconds
    }
}

/// C trampoline for both taps. Must not capture anything, so the instance travels in `refcon`.
private nonisolated func scrollTapCallback(
    proxy: CGEventTapProxy,
    type: CGEventType,
    event: CGEvent,
    refcon: UnsafeMutableRawPointer?
) -> Unmanaged<CGEvent>? {
    guard let refcon else { return Unmanaged.passUnretained(event) }
    let tap = Unmanaged<ScrollEventTap>.fromOpaque(refcon).takeUnretainedValue()
    return tap.handle(type: type, event: event)
}
