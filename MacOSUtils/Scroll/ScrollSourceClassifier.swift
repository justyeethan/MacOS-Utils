import Foundation

/// Infers which device produced a scroll event.
///
/// This is the same heuristic Scroll Reverser uses (MouseTap.m), extended to tell a
/// Magic Mouse apart from a wheel mouse:
///
/// 1. A *discrete* (non-continuous) scroll event can only come from a wheel → `.wheelMouse`.
/// 2. Trackpads emit gesture events (NSEvent type `.gesture`) carrying touches alongside
///    their scroll events. If two or more fingers were touching very recently → `.trackpad`.
/// 3. One finger touching very recently on a continuous source → `.magicMouse`.
/// 4. A continuous event with no scroll/momentum phase → some smooth-scroll mouse driver →
///    `.wheelMouse` (only multitouch devices attach phases).
/// 5. A phased gesture *starting* with no touch data → `.trackpad`, never an inherited wheel.
/// 6. Anything else (mid-gesture, or momentum frames after the fingers have lifted) keeps the
///    previous source, so a fling that *started* on the trackpad stays a trackpad scroll
///    all the way to the end of its momentum.
///
/// Not thread-safe: it lives on the event-tap thread, which is the only place both the
/// gesture tap and the scroll tap call into it.
nonisolated struct ScrollSourceClassifier {
    /// Touches older than this don't count as "currently touching" (Scroll Reverser: 222 ms).
    var touchWindow: UInt64 = 222_000_000
    private(set) var lastSource: ScrollSource = .wheelMouse
    /// Total gesture events seen with ≥1 touch. Stays 0 if the gesture tap never delivers
    /// touches — the key thing to check when the trackpad is misdetected.
    private(set) var touchEventCount = 0

    /// Highest finger count seen in gesture events since the previous scroll event.
    private var touchesSinceLastScroll = 0
    private var lastTouchCount = 0
    private var lastTouchTime: UInt64 = 0

    /// Call for every gesture event with the number of touches in the `.touching` phase.
    mutating func recordTouches(_ count: Int, at now: UInt64) {
        guard count > 0 else { return }
        touchEventCount &+= 1
        touchesSinceLastScroll = max(touchesSinceLastScroll, count)
        lastTouchCount = count
        lastTouchTime = now
    }

    /// Call once per scroll event.
    mutating func classify(_ event: ScrollEventInfo, now: UInt64) -> ScrollSource {
        defer { touchesSinceLastScroll = 0 }

        let source: ScrollSource
        let elapsed = now &- lastTouchTime
        let recentTouch = lastTouchTime != 0 && elapsed < touchWindow
        // Gesture events don't arrive with every scroll event, so fall back to the most
        // recent touch count while it's still fresh.
        let touches = touchesSinceLastScroll > 0 ? touchesSinceLastScroll
                                                 : (recentTouch ? lastTouchCount : 0)

        let hasPhase = event.scrollPhase != .none || event.momentumPhase != .none
        let gestureStart = event.scrollPhase == .began || event.scrollPhase == .mayBegin

        if !event.isContinuous {
            source = .wheelMouse
        } else if touches >= 2 && recentTouch {
            source = .trackpad
        } else if touches == 1 && recentTouch {
            source = .magicMouse
        } else if !hasPhase {
            // Continuous but phase-less: a smooth-scrolling mouse driver. Trackpads and
            // Magic Mouse always attach a scroll or momentum phase.
            source = .wheelMouse
        } else if gestureStart && lastSource == .wheelMouse {
            // A phased gesture is starting but no touch data arrived (gesture tap missing
            // or silent). Only multitouch devices produce phases, so this can't be a wheel —
            // assume trackpad rather than inheriting the wheel from an earlier scroll.
            source = .trackpad
        } else {
            // Mid-gesture or momentum after the fingers lifted: keep the gesture's source.
            source = lastSource
        }

        lastSource = source
        return source
    }
}

/// The subset of a scroll event the classifier and transform need. Plain value type so the
/// logic can be unit-tested without real CGEvents.
nonisolated struct ScrollEventInfo: Sendable, Equatable {
    /// `kCGScrollWheelEventScrollPhase` values.
    nonisolated enum Phase: Int64, Sendable {
        case none = 0, began = 1, changed = 2, ended = 4, cancelled = 8, mayBegin = 128
    }
    /// `kCGScrollWheelEventMomentumPhase` values.
    nonisolated enum MomentumPhase: Int64, Sendable {
        case none = 0, begin = 1, `continue` = 2, end = 3
    }

    var isContinuous: Bool
    var scrollPhase: Phase
    var momentumPhase: MomentumPhase
    /// `NSEvent.isDirectionInvertedFromDevice` — true when macOS "Natural scrolling" is on.
    var isDirectionInvertedFromDevice: Bool
    /// PID of the process that posted the event; 0 for real hardware input.
    var sourcePID: Int64
}
