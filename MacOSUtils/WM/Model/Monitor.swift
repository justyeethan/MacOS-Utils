import AppKit

/// A display, with frames converted to AX coordinates (origin top-left of the main display,
/// y increasing downwards) so they can be compared with window frames directly.
struct Monitor: Equatable {
    let id: CGDirectDisplayID
    let name: String
    let frame: CGRect
    let visibleFrame: CGRect
    let isMain: Bool
    /// 1-based position, sorted left-to-right then top-to-bottom (AeroSpace monitor numbering).
    var index: Int = 0

    var center: CGPoint { CGPoint(x: frame.midX, y: frame.midY) }

    /// Wider than tall → horizontal root, for `default-root-container-orientation = 'auto'`.
    var autoOrientation: Orientation { frame.width >= frame.height ? .horizontal : .vertical }

    static func current() -> [Monitor] {
        let screens = NSScreen.screens
        guard let primary = screens.first else { return [] }
        let primaryHeight = primary.frame.height

        func toAX(_ r: CGRect) -> CGRect {
            CGRect(x: r.minX, y: primaryHeight - r.maxY, width: r.width, height: r.height)
        }

        var monitors = screens.compactMap { screen -> Monitor? in
            guard let number = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber else {
                return nil
            }
            return Monitor(id: CGDirectDisplayID(number.uint32Value),
                           name: screen.localizedName,
                           frame: toAX(screen.frame),
                           visibleFrame: toAX(screen.visibleFrame),
                           isMain: screen == primary)
        }
        let order = monitors.sorted { ($0.frame.minX, $0.frame.minY) < ($1.frame.minX, $1.frame.minY) }
        for (i, m) in order.enumerated() {
            if let j = monitors.firstIndex(where: { $0.id == m.id }) { monitors[j].index = i + 1 }
        }
        return monitors
    }

    /// AeroSpace monitor pattern: `main`, `secondary`, a 1-based number, or a case-insensitive
    /// regex matched anywhere in the monitor's name.
    func matches(pattern: String, among all: [Monitor]) -> Bool {
        switch pattern.lowercased() {
        case "main": return isMain
        case "secondary": return !isMain && all.count == 2
        default:
            if let n = Int(pattern) { return index == n }
            return name.range(of: pattern, options: [.regularExpression, .caseInsensitive]) != nil
        }
    }

    /// The nearest monitor in `direction` from this one, if any.
    func neighbor(_ direction: Direction, in all: [Monitor]) -> Monitor? {
        let candidates = all.filter { other in
            guard other.id != id else { return false }
            switch direction {
            case .left:  return other.frame.midX < frame.minX + 1
            case .right: return other.frame.midX > frame.maxX - 1
            case .up:    return other.frame.midY < frame.minY + 1
            case .down:  return other.frame.midY > frame.maxY - 1
            }
        }
        return candidates.min { a, b in
            hypot(a.center.x - center.x, a.center.y - center.y) < hypot(b.center.x - center.x, b.center.y - center.y)
        }
    }

    /// Where to park windows of hidden workspaces: a 1px sliver in a bottom corner that doesn't
    /// spill onto a neighbouring display (AeroSpace's trick; macOS won't place a window fully off-screen).
    func parkingOrigin(for windowSize: CGSize, among all: [Monitor]) -> CGPoint {
        let y = frame.maxY - 1
        let rightProbe = CGPoint(x: frame.maxX + 10, y: frame.maxY - 10)
        let rightIsFree = !all.contains { $0.id != id && $0.frame.contains(rightProbe) }
        if rightIsFree {
            return CGPoint(x: frame.maxX - 1, y: y)
        }
        return CGPoint(x: frame.minX - windowSize.width + 1, y: y)
    }
}
