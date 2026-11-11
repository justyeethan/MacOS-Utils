import CoreGraphics

/// All the delta values a scroll event carries. Apps read different ones, so every one
/// has to be rewritten consistently or some apps will scroll the "wrong" way:
///
/// * `line*`  — `kCGScrollWheelEventDeltaAxis1/2`, integer lines (classic wheel apps)
/// * `point*` — `kCGScrollWheelEventPointDeltaAxis1/2`, pixels (most Cocoa views)
/// * `fixed*` — `kCGScrollWheelEventFixedPtDeltaAxis1/2`, 16.16 fixed-point lines
/// * `hid*`   — the underlying IOHIDEvent's ScrollY/ScrollX (read directly by some apps,
///              e.g. Safari/WebKit). Only present when the private bridge is available.
///
/// Axis 1 is vertical, axis 2 is horizontal.
nonisolated struct ScrollDeltas: Equatable, Sendable {
    var lineY: Int64
    var lineX: Int64
    var pointY: Int64
    var pointX: Int64
    var fixedY: Double
    var fixedX: Double
    var hidY: Double?
    var hidX: Double?
}

/// What to do to one event.
nonisolated struct ScrollPlan: Equatable, Sendable {
    /// Multiplier for the vertical axis. ±1 flips or keeps; ±N is a discrete step-size override.
    var vertical: Int64 = 1
    var horizontal: Int64 = 1
    /// True when `vertical` is a step-size override for a single wheel click. In that case only
    /// the line delta is written and macOS recomputes the point/fixed values from it.
    var isDiscreteStep = false

    var isIdentity: Bool { vertical == 1 && horizontal == 1 }
}

nonisolated enum ScrollTransform {

    /// Decide how to transform an event from `source` given the user's settings.
    static func plan(source: ScrollSource,
                     info: ScrollEventInfo,
                     lineY: Int64,
                     settings: ScrollSettings) -> ScrollPlan {
        guard settings.enabled else { return ScrollPlan() }
        if settings.onlyHardwareEvents && info.sourcePID != 0 { return ScrollPlan() }

        let s = settings[source]
        var plan = ScrollPlan(
            vertical: sign(for: s.vertical, systemIsNatural: info.isDirectionInvertedFromDevice),
            horizontal: sign(for: s.horizontal, systemIsNatural: info.isDirectionInvertedFromDevice)
        )

        // Scroll Reverser's "step size": a single wheel click scrolls a fixed number of lines
        // instead of macOS's accelerated amount. Only when the click is exactly ±1 line —
        // faster spins already carry acceleration and are just flipped.
        if source == .wheelMouse,
           !info.isContinuous,
           s.discreteStepSize > 0,
           abs(lineY) == 1 {
            plan.vertical *= Int64(min(s.discreteStepSize, 100))
            plan.isDiscreteStep = true
        }
        return plan
    }

    /// +1 keeps the event as macOS delivered it, -1 flips it.
    ///
    /// `isDirectionInvertedFromDevice` is true when macOS has already inverted the deltas
    /// (Natural scrolling on). macOS has one global setting for mouse and trackpad, so we
    /// compare what the user wants for this device against what macOS already did.
    static func sign(for direction: ScrollDirection, systemIsNatural: Bool) -> Int64 {
        switch direction {
        case .system:  1
        case .natural: systemIsNatural ? 1 : -1
        case .classic: systemIsNatural ? -1 : 1
        }
    }

    static func apply(_ plan: ScrollPlan, to d: ScrollDeltas) -> ScrollDeltas {
        guard !plan.isIdentity else { return d }
        var out = d
        if plan.vertical != 1 {
            out.lineY = d.lineY * plan.vertical
            if !plan.isDiscreteStep {
                let m = Double(plan.vertical)
                out.pointY = d.pointY * plan.vertical
                out.fixedY = d.fixedY * m
                out.hidY = d.hidY.map { $0 * m }
            }
        }
        if plan.horizontal != 1 {
            let m = Double(plan.horizontal)
            out.lineX = d.lineX * plan.horizontal
            out.pointX = d.pointX * plan.horizontal
            out.fixedX = d.fixedX * m
            out.hidX = d.hidX.map { $0 * m }
        }
        return out
    }
}

// MARK: - CGEvent bridging

nonisolated extension ScrollDeltas {
    init(event: CGEvent, hid: IOHIDEventBridge.Event?) {
        lineY  = event.getIntegerValueField(.scrollWheelEventDeltaAxis1)
        lineX  = event.getIntegerValueField(.scrollWheelEventDeltaAxis2)
        pointY = event.getIntegerValueField(.scrollWheelEventPointDeltaAxis1)
        pointX = event.getIntegerValueField(.scrollWheelEventPointDeltaAxis2)
        fixedY = event.getDoubleValueField(.scrollWheelEventFixedPtDeltaAxis1)
        fixedX = event.getDoubleValueField(.scrollWheelEventFixedPtDeltaAxis2)
        hidY   = hid?.value(for: .scrollY)
        hidX   = hid?.value(for: .scrollX)
    }

    /// Write back only what the plan changed.
    ///
    /// Order matters: setting a DeltaAxis field makes CoreGraphics recompute that axis's
    /// point and fixed-point deltas, so the line delta goes first and the precise values
    /// overwrite the recomputed ones afterwards (same as Scroll Reverser).
    func write(to event: CGEvent, hid: IOHIDEventBridge.Event?, plan: ScrollPlan) {
        if plan.vertical != 1 {
            event.setIntegerValueField(.scrollWheelEventDeltaAxis1, value: lineY)
            if !plan.isDiscreteStep {
                event.setDoubleValueField(.scrollWheelEventFixedPtDeltaAxis1, value: fixedY)
                event.setIntegerValueField(.scrollWheelEventPointDeltaAxis1, value: pointY)
                if let hidY { hid?.set(hidY, for: .scrollY) }
            }
        }
        if plan.horizontal != 1 {
            event.setIntegerValueField(.scrollWheelEventDeltaAxis2, value: lineX)
            event.setDoubleValueField(.scrollWheelEventFixedPtDeltaAxis2, value: fixedX)
            event.setIntegerValueField(.scrollWheelEventPointDeltaAxis2, value: pointX)
            if let hidX { hid?.set(hidX, for: .scrollX) }
        }
    }
}
