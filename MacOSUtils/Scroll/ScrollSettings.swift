import Foundation
import os

/// The kind of device that produced a scroll event.
///
/// macOS does not tell an event tap which physical device a scroll came from, so
/// this is inferred from the shape of the event stream (see `ScrollSourceClassifier`).
nonisolated enum ScrollSource: String, CaseIterable, Codable, Sendable, Identifiable {
    /// Built-in trackpad or Magic Trackpad (two-finger scroll, continuous, with gesture touches).
    case trackpad
    /// Magic Mouse (continuous, one-finger touch on the surface).
    case magicMouse
    /// A regular wheel mouse, or any continuous source with no touch data
    /// (e.g. a smooth-scrolling driver).
    case wheelMouse

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .trackpad:   "Trackpad"
        case .magicMouse: "Magic Mouse"
        case .wheelMouse: "Mouse wheel"
        }
    }
}

/// What direction the user wants for one axis of one source.
nonisolated enum ScrollDirection: String, CaseIterable, Codable, Sendable, Identifiable {
    /// Leave whatever macOS does untouched.
    case system
    /// Content follows the fingers ("Natural scrolling" on).
    case natural
    /// Classic: scrolling down moves the view down (content moves up).
    case classic

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .system:  "System"
        case .natural: "Natural"
        case .classic: "Classic"
        }
    }
}

nonisolated struct SourceSettings: Codable, Sendable, Equatable {
    var vertical: ScrollDirection = .system
    var horizontal: ScrollDirection = .system
    /// Lines per wheel click for discrete wheel mice. 0 = leave macOS acceleration alone.
    /// Only applied to `.wheelMouse` events that are not continuous.
    var discreteStepSize: Int = 0
}

nonisolated struct ScrollSettings: Codable, Sendable, Equatable {
    var enabled: Bool = true
    /// When true, only events coming straight from hardware are changed; scroll events
    /// synthesised by other apps (remote desktop, BetterTouchTool, etc.) pass through.
    /// Mirrors Scroll Reverser's `ReverseOnlyRawInput`.
    var onlyHardwareEvents: Bool = false

    var perSource: [ScrollSource: SourceSettings] = [
        // Common setup: natural on the trackpad, classic on a wheel mouse.
        .trackpad:   SourceSettings(vertical: .natural, horizontal: .natural),
        .magicMouse: SourceSettings(vertical: .natural, horizontal: .natural),
        .wheelMouse: SourceSettings(vertical: .classic, horizontal: .classic),
    ]

    subscript(source: ScrollSource) -> SourceSettings {
        get { perSource[source] ?? SourceSettings() }
        set { perSource[source] = newValue }
    }
}

/// Lock-protected settings snapshot.
///
/// The UI writes on the main actor; the event-tap thread reads on every scroll event.
/// Reads must be cheap and must never wait on the main thread, otherwise macOS
/// disables the tap for being too slow.
nonisolated final class ScrollSettingsStore: Sendable {
    private let state: OSAllocatedUnfairLock<ScrollSettings>

    init(_ initial: ScrollSettings = ScrollSettings()) {
        state = OSAllocatedUnfairLock(initialState: initial)
    }

    var current: ScrollSettings {
        state.withLock { $0 }
    }

    func update(_ body: @Sendable (inout ScrollSettings) -> Void) {
        state.withLock { body(&$0) }
    }

    func replace(with settings: ScrollSettings) {
        state.withLock { $0 = settings }
    }
}
