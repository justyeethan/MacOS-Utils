import AppKit

/// Appearance of the window borders. Plain values (ARGB as UInt32) so it can live in `WMConfig`.
/// Defaults match the JankyBorders line in Ethan's AeroSpace config.
nonisolated struct BorderStyle: Equatable, Sendable {
    /// Focused window, 0xAARRGGBB (JankyBorders notation).
    var activeARGB: UInt32 = 0xff6E_A3FE
    /// Every other visible window; nil = no outline on unfocused windows.
    var inactiveARGB: UInt32? = 0xff49_4D64
    var width: CGFloat = 5
    /// Radius of the window's own corners; the border's outer radius adds `width` to it.
    var cornerRadius: CGFloat = 12

    /// True for `borders …` / `/opt/homebrew/bin/borders …` — the JankyBorders CLI.
    static func isBordersCommand(_ command: String) -> Bool {
        guard let first = command.split(whereSeparator: \.isWhitespace).first else { return false }
        return first == "borders" || first.hasSuffix("/borders")
    }

    /// Reads JankyBorders arguments (`active_color=0xff6EA3FE inactive_color=0xff494d64 width=5
    /// style=round`) so an existing `after-startup-command` line configures the built-in borders
    /// unchanged. Unsupported values (`gradient(…)`, `glow(…)`) keep the default.
    static func fromBordersCommand(_ command: String) -> BorderStyle? {
        guard isBordersCommand(command) else { return nil }
        var style = BorderStyle()
        for token in command.split(whereSeparator: \.isWhitespace).dropFirst() {
            let parts = token.split(separator: "=", maxSplits: 1).map(String.init)
            guard parts.count == 2 else { continue }
            switch parts[0] {
            case "active_color":   if let v = parseHex(parts[1]) { style.activeARGB = v }
            case "inactive_color": if let v = parseHex(parts[1]) { style.inactiveARGB = v }
            case "width":          if let w = Double(parts[1]) { style.width = CGFloat(w) }
            case "style":          if parts[1] == "square" { style.cornerRadius = 0 }
            default: break
            }
        }
        return style
    }

    /// `0xff6EA3FE`, `ff6EA3FE` or `#6EA3FE` → value. Six digits are treated as opaque RGB.
    static func parseHex(_ text: String) -> UInt32? {
        var s = text.trimmingCharacters(in: .whitespaces).lowercased()
        if s.hasPrefix("0x") { s.removeFirst(2) } else if s.hasPrefix("#") { s.removeFirst() }
        guard let v = UInt32(s, radix: 16) else { return nil }
        return s.count == 6 ? 0xff00_0000 | v : v
    }

    static func hexString(_ argb: UInt32) -> String {
        let digits = String(argb, radix: 16, uppercase: true)
        return "0x" + String(repeating: "0", count: max(0, 8 - digits.count)) + digits
    }

    static func cgColor(_ argb: UInt32) -> CGColor {
        CGColor(srgbRed: CGFloat((argb >> 16) & 0xff) / 255,
                green: CGFloat((argb >> 8) & 0xff) / 255,
                blue: CGFloat(argb & 0xff) / 255,
                alpha: CGFloat((argb >> 24) & 0xff) / 255)
    }
}

/// One outline: a transparent, click-through window slightly larger than its target and ordered
/// just above it. The stroke sits entirely outside the target's frame (in the tiling gap), so it
/// never covers window content.
private final class BorderOverlay {
    private let window: NSWindow

    init() {
        let w = NSWindow(contentRect: .zero, styleMask: [.borderless], backing: .buffered, defer: false)
        w.isOpaque = false
        w.backgroundColor = .clear
        w.hasShadow = false
        w.ignoresMouseEvents = true
        w.isReleasedWhenClosed = false
        w.animationBehavior = .none
        w.level = .normal
        w.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle]
        let view = NSView()
        view.wantsLayer = true
        w.contentView = view
        window = w
    }

    func show(around axFrame: CGRect, above windowID: CGWindowID, color: CGColor,
              style: BorderStyle, primaryHeight: CGFloat) {
        let outer = axFrame.insetBy(dx: -style.width, dy: -style.width)
        // AX is top-left origin; AppKit is bottom-left of the primary display.
        let frame = CGRect(x: outer.minX, y: primaryHeight - outer.maxY,
                           width: outer.width, height: outer.height)
        if let layer = window.contentView?.layer {
            layer.backgroundColor = .clear
            layer.borderWidth = style.width
            layer.cornerRadius = style.cornerRadius == 0 ? 0 : style.cornerRadius + style.width
            layer.borderColor = color
        }
        if window.frame != frame { window.setFrame(frame, display: true) }
        window.order(.above, relativeTo: Int(windowID))
        // If the window server refused relative ordering, still show it at its level.
        if !window.isVisible { window.orderFrontRegardless() }
    }

    func hide() { window.orderOut(nil) }
}

/// Draws the active border on the focused window and the inactive border on every other visible
/// window, like JankyBorders.
final class BorderManager {
    var style = BorderStyle()
    private var overlays: [CGWindowID: BorderOverlay] = [:]

    var showsInactive: Bool { style.inactiveARGB != nil }

    /// `active`: focused window and its AX frame (nil when nothing should look focused).
    /// `inactive`: other visible windows; ignored when the style has no inactive colour.
    func update(active: (id: CGWindowID, frame: CGRect)?, inactive: [(id: CGWindowID, frame: CGRect)]) {
        guard let primary = NSScreen.screens.first else { return }
        let h = primary.frame.height
        var keep = Set<CGWindowID>()

        if let inactiveARGB = style.inactiveARGB {
            let color = BorderStyle.cgColor(inactiveARGB)
            for target in inactive {
                overlay(for: target.id).show(around: target.frame, above: target.id, color: color,
                                             style: style, primaryHeight: h)
                keep.insert(target.id)
            }
        }
        if let active {
            overlay(for: active.id).show(around: active.frame, above: active.id,
                                         color: BorderStyle.cgColor(style.activeARGB),
                                         style: style, primaryHeight: h)
            keep.insert(active.id)
        }

        for (id, o) in overlays where !keep.contains(id) {
            o.hide()
            overlays[id] = nil
        }
    }

    func hideAll() {
        for o in overlays.values { o.hide() }
        overlays = [:]
    }

    private func overlay(for id: CGWindowID) -> BorderOverlay {
        if let o = overlays[id] { return o }
        let o = BorderOverlay()
        overlays[id] = o
        return o
    }
}
