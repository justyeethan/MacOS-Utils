import AppKit
import CoreGraphics
import os

/// Global hotkeys via a keyboard event tap, with AeroSpace-style binding modes.
///
/// Runs on its own thread like `ScrollEventTap`. The callback only looks the chord up in an
/// immutable snapshot and, on a match, swallows the key and hands the commands to the main
/// actor. It never touches window-manager state, so a slow AX call can't delay typing.
///
/// Why a tap rather than Carbon `RegisterEventHotKey`: it gives exact modifier matching, lets
/// modes swallow bare keys (`esc`, `r`, `down` in service mode) and shares the permission the
/// scroll tap already needs.
nonisolated final class HotkeyTap: @unchecked Sendable {

    nonisolated struct Table: Sendable {
        var modes: [String: [KeyChord: [WMCommand]]] = [:]
        var currentMode = "main"
    }

    /// Called on the tap thread for each matched chord.
    var onCommands: (@Sendable ([WMCommand]) -> Void)?

    private let table = OSAllocatedUnfairLock(initialState: Table())
    private let lock = NSLock()
    private var tap: CFMachPort?
    private var runLoop: CFRunLoop?
    private var thread: Thread?
    /// Key codes whose keyDown we swallowed; their keyUp is swallowed too (tap thread only).
    private var swallowedKeyUps = Set<Int64>()

    private static let log = Logger(subsystem: "MacOSUtils", category: "Hotkeys")

    var isRunning: Bool { lock.withLock { thread != nil } }

    func setBindings(_ modes: [String: [KeyChord: [WMCommand]]]) {
        table.withLock {
            $0.modes = modes
            if $0.modes[$0.currentMode] == nil { $0.currentMode = "main" }
        }
    }

    func setMode(_ mode: String) {
        table.withLock { $0.currentMode = mode }
    }

    var currentMode: String { table.withLock { $0.currentMode } }

    // MARK: Lifecycle

    func start() throws {
        lock.lock()
        defer { lock.unlock() }
        guard thread == nil else { return }

        let mask = (CGEventMask(1) << CGEventType.keyDown.rawValue)
                 | (CGEventMask(1) << CGEventType.keyUp.rawValue)
        guard let port = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,          // see keys before other apps' taps
            options: .defaultTap,
            eventsOfInterest: mask,
            callback: hotkeyTapCallback,
            userInfo: Unmanaged.passUnretained(self).toOpaque()
        ) else {
            throw ScrollEventTap.StartError.notTrusted
        }
        tap = port

        let ready = DispatchSemaphore(value: 0)
        let thread = Thread { [self] in
            let rl = CFRunLoopGetCurrent()!
            // Read the port from self rather than capturing it: CFMachPort isn't Sendable.
            guard let port = self.tap else { ready.signal(); return }
            let src = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, port, 0)
            CFRunLoopAddSource(rl, src, .commonModes)
            CGEvent.tapEnable(tap: port, enable: true)
            self.lock.withLock { self.runLoop = rl }
            ready.signal()
            CFRunLoopRun()
        }
        thread.name = "MacOSUtils.HotkeyTap"
        thread.qualityOfService = .userInteractive
        self.thread = thread
        thread.start()

        lock.unlock()
        ready.wait()
        lock.lock()
    }

    func stop() {
        lock.lock()
        let rl = runLoop, port = tap
        runLoop = nil; tap = nil; thread = nil
        lock.unlock()
        if let port {
            CGEvent.tapEnable(tap: port, enable: false)
            CFMachPortInvalidate(port)
        }
        if let rl { CFRunLoopStop(rl) }
    }

    // MARK: Event handling (tap thread)

    fileprivate func handle(type: CGEventType, event: CGEvent) -> Unmanaged<CGEvent>? {
        switch type {
        case .tapDisabledByTimeout, .tapDisabledByUserInput:
            if let tap { CGEvent.tapEnable(tap: tap, enable: true) }
            return Unmanaged.passUnretained(event)

        case .keyDown:
            let code = event.getIntegerValueField(.keyboardEventKeycode)
            let chord = KeyChord(keyCode: UInt16(truncatingIfNeeded: code),
                                 modifiers: KeyChord.Modifiers(cgFlags: event.flags))
            let commands = table.withLock { $0.modes[$0.currentMode]?[chord] }
            guard let commands else { return Unmanaged.passUnretained(event) }
            swallowedKeyUps.insert(code)
            onCommands?(commands)
            return nil

        case .keyUp:
            let code = event.getIntegerValueField(.keyboardEventKeycode)
            if swallowedKeyUps.remove(code) != nil { return nil }
            return Unmanaged.passUnretained(event)

        default:
            return Unmanaged.passUnretained(event)
        }
    }
}

private nonisolated func hotkeyTapCallback(
    proxy: CGEventTapProxy,
    type: CGEventType,
    event: CGEvent,
    refcon: UnsafeMutableRawPointer?
) -> Unmanaged<CGEvent>? {
    guard let refcon else { return Unmanaged.passUnretained(event) }
    return Unmanaged<HotkeyTap>.fromOpaque(refcon).takeUnretainedValue().handle(type: type, event: event)
}
