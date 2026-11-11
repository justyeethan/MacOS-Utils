import CoreGraphics
import Foundation

/// Everything the built-in bar draws, with defaults reproducing Ethan's SketchyBar setup
/// (sketchybarrc + plugins/aerospace.sh). Stored as a `[bar]` table in the config file.
nonisolated struct BarStyle: Equatable, Sendable {

    nonisolated enum Numerals: String, CaseIterable, Sendable { case chinese, arabic }
    nonisolated enum AppIcons: String, CaseIterable, Sendable {
        /// sketchybar-app-font if installed, otherwise real app icons.
        case automatic
        case appFont = "app-font"
        case appIcons = "app-icons"
        case none
    }

    var enabled = true
    // Bar — SketchyBar had `height=40 blur_radius=30 color=0x40000000`; now fully transparent.
    var height: CGFloat = 40
    /// Size the bar like the macOS menu bar (the notch strip on notched displays) instead of
    /// using `height`.
    var matchMenuBar = true
    var backgroundARGB: UInt32 = 0x0000_0000
    var blur = false
    /// SketchyBar's `topmost`: draw above the macOS menu bar instead of under it.
    var drawOverMenuBar = false
    /// Keep tiled windows below the bar (SketchyBar can't do this; AeroSpace needed a gap).
    var reserveSpace = true

    // Workspace pills — plugins/aerospace.sh
    var showWorkspaces = true
    var numerals: Numerals = .chinese
    var appIcons: AppIcons = .automatic
    var workspaceTextARGB: UInt32 = 0xffb0_b0b0
    var pillARGB: UInt32 = 0x44ff_ffff
    /// aerospace.sh sets `0x0C10F5`, which SketchyBar reads as ARGB with alpha 0: transparent.
    var focusedPillARGB: UInt32 = 0x000C_10F5
    var focusedOutlineARGB: UInt32 = 0xAAFF_FFFF
    var focusedOutlineWidth: CGFloat = 2

    // Right side — clock, volume, battery (right to left, as added in sketchybarrc)
    var showClock = true
    var showVolume = true
    var showBattery = true
    var textARGB: UInt32 = 0xffff_ffff
    /// `icon.font="Hack Nerd Font:Bold:17.0"`, `label.font="SF Pro:Semibold:17.0"`
    var iconFont = "Hack Nerd Font"
    var fontSize: CGFloat = 17

    // MARK: TOML

    init() {}

    /// Overlays values from a `[bar]` table onto the defaults.
    init(table t: [String: TOMLValue]) {
        func color(_ key: String, _ current: UInt32) -> UInt32 {
            t[key]?.string.flatMap(Self.parseARGB) ?? current
        }
        func number(_ key: String, _ current: CGFloat) -> CGFloat {
            t[key]?.number.map { CGFloat($0) } ?? current
        }
        func flag(_ key: String, _ current: Bool) -> Bool { t[key]?.bool ?? current }

        enabled = flag("enabled", enabled)
        height = number("height", height)
        matchMenuBar = flag("match-menu-bar", matchMenuBar)
        backgroundARGB = color("color", backgroundARGB)
        blur = flag("blur", blur)
        drawOverMenuBar = flag("topmost", drawOverMenuBar)
        reserveSpace = flag("reserve-space", reserveSpace)
        showWorkspaces = flag("workspaces", showWorkspaces)
        if let v = t["numerals"]?.string, let n = Numerals(rawValue: v) { numerals = n }
        if let v = t["app-icons"]?.string, let a = AppIcons(rawValue: v) { appIcons = a }
        workspaceTextARGB = color("workspace-color", workspaceTextARGB)
        pillARGB = color("pill-color", pillARGB)
        focusedPillARGB = color("focused-pill-color", focusedPillARGB)
        focusedOutlineARGB = color("focused-border-color", focusedOutlineARGB)
        focusedOutlineWidth = number("focused-border-width", focusedOutlineWidth)
        showClock = flag("clock", showClock)
        showVolume = flag("volume", showVolume)
        showBattery = flag("battery", showBattery)
        textARGB = color("text-color", textARGB)
        if let f = t["icon-font"]?.string, !f.isEmpty { iconFont = f }
        fontSize = number("font-size", fontSize)
    }

    var table: [String: TOMLValue] {
        func hex(_ v: UInt32) -> TOMLValue { .string(BorderStyle.hexString(v)) }
        return [
            "enabled": .bool(enabled),
            "height": .double(Double(height)),
            "match-menu-bar": .bool(matchMenuBar),
            "color": hex(backgroundARGB),
            "blur": .bool(blur),
            "topmost": .bool(drawOverMenuBar),
            "reserve-space": .bool(reserveSpace),
            "workspaces": .bool(showWorkspaces),
            "numerals": .string(numerals.rawValue),
            "app-icons": .string(appIcons.rawValue),
            "workspace-color": hex(workspaceTextARGB),
            "pill-color": hex(pillARGB),
            "focused-pill-color": hex(focusedPillARGB),
            "focused-border-color": hex(focusedOutlineARGB),
            "focused-border-width": .double(Double(focusedOutlineWidth)),
            "clock": .bool(showClock),
            "volume": .bool(showVolume),
            "battery": .bool(showBattery),
            "text-color": hex(textARGB),
            "icon-font": .string(iconFont),
            "font-size": .double(Double(fontSize)),
        ]
    }

    /// Always 8 hex digits (AARRGGBB) here, like SketchyBar — so `0x0C10F5` is transparent.
    static func parseARGB(_ text: String) -> UInt32? {
        var s = text.trimmingCharacters(in: .whitespaces).lowercased()
        if s.hasPrefix("0x") { s.removeFirst(2) } else if s.hasPrefix("#") { s.removeFirst() }
        return UInt32(s, radix: 16)
    }

    // MARK: Display helpers

    static func numeral(for workspace: String, style: Numerals) -> String {
        guard style == .chinese, let n = Int(workspace), (1...10).contains(n) else { return workspace }
        return ["一", "二", "三", "四", "五", "六", "七", "八", "九", "十"][n - 1]
    }

    /// Glyphs from plugins/battery.sh (Font Awesome range of Nerd Fonts).
    static func batteryGlyph(percent: Int, onAC: Bool) -> String {
        if onAC { return "\u{f0e7}" }
        switch percent {
        case 90...: return "\u{f240}"
        case 60..<90: return "\u{f241}"
        case 30..<60: return "\u{f242}"
        case 10..<30: return "\u{f243}"
        default: return "\u{f244}"
        }
    }

    /// Glyphs from plugins/volume.sh (Material Design range of Nerd Fonts).
    static func volumeGlyph(percent: Int, muted: Bool) -> String {
        if muted { return "\u{f0581}" }
        switch percent {
        case 60...: return "\u{f057e}"
        case 30..<60: return "\u{f0580}"
        case 1..<30: return "\u{f057f}"
        default: return "\u{f0581}"
        }
    }
}
