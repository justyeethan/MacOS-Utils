import AppKit
import CoreText
import SwiftUI

/// The bar for one display: workspace pills on the left, battery · volume · clock on the right.
struct BarView: View {
    let model: BarModel
    let displayID: CGDirectDisplayID

    private var style: BarStyle { model.style }
    private var geometry: BarModel.DisplayGeometry? { model.displays[displayID] }
    private var metrics: BarMetrics { BarMetrics(model: model, barHeight: geometry?.height ?? style.height) }

    var body: some View {
        let m = metrics
        ZStack {
            if style.blur { VisualEffectBackground() }
            Color(argb: style.backgroundARGB)

            // On a notched display: left items live left of the camera, right items right of it,
            // and nothing is drawn underneath. Without a notch: left / spacer / right as usual.
            HStack(spacing: 0) {
                HStack(spacing: m.itemSpacing) {
                    if style.showWorkspaces {
                        ForEach(workspaces, id: \.name) { ws in
                            WorkspacePill(workspace: ws,
                                          isFocused: ws.name == model.wm.focusedWorkspace,
                                          model: model, metrics: m)
                        }
                    }
                }
                .padding(.leading, m.edgePadding)
                .frame(width: leftWidth, alignment: .leading)
                .clipped(if: leftWidth != nil)

                Spacer(minLength: notchWidth)

                HStack(spacing: m.itemSpacing) {
                    if style.showBattery, let percent = model.system.battery {
                        StatusItem(icon: batteryIcon(percent), label: "\(percent)%", model: model, metrics: m)
                    }
                    if style.showVolume, let percent = model.system.volume {
                        StatusItem(icon: volumeIcon(percent), label: "\(percent)%", model: model, metrics: m)
                    }
                    if style.showClock {
                        StatusItem(icon: nil, label: model.system.clock, model: model, metrics: m)
                    }
                }
                .padding(.trailing, m.edgePadding)
                .frame(width: rightWidth, alignment: .trailing)
                .clipped(if: rightWidth != nil)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)   // the panel decides the size
        .contextMenu {
            Button("MacOSUtils Settings…") { model.onOpenSettings?() }
        }
    }

    // MARK: Notch layout

    /// Breathing room between items and the camera housing.
    private static let notchMargin: CGFloat = 8

    /// Width available left of the notch (nil = no notch, size to content).
    private var leftWidth: CGFloat? {
        geometry?.notch.map { max(0, $0.lowerBound - Self.notchMargin) }
    }

    private var rightWidth: CGFloat? {
        guard let g = geometry, let n = g.notch else { return nil }
        return max(0, g.width - n.upperBound - Self.notchMargin)
    }

    private var notchWidth: CGFloat {
        guard let n = geometry?.notch else { return 0 }
        return n.upperBound - n.lowerBound + 2 * Self.notchMargin
    }

    /// aerospace.sh: a pill is drawn when the workspace has windows or is focused, on the
    /// display the workspace lives on.
    private var workspaces: [WMStatus.WorkspaceInfo] {
        let mainID = CGMainDisplayID()
        return model.wm.workspaces.filter { ws in
            let onThisDisplay = (ws.monitorID ?? mainID) == displayID
            return onThisDisplay && (!ws.apps.isEmpty || ws.name == model.wm.focusedWorkspace)
        }
    }

    private func batteryIcon(_ percent: Int) -> StatusItem.Icon {
        if model.hasIconFont {
            return .glyph(BarStyle.batteryGlyph(percent: percent, onAC: model.system.isOnAC))
        }
        if model.system.isOnAC { return .symbol("battery.100percent.bolt") }
        switch percent {
        case 90...: return .symbol("battery.100percent")
        case 60..<90: return .symbol("battery.75percent")
        case 30..<60: return .symbol("battery.50percent")
        case 10..<30: return .symbol("battery.25percent")
        default: return .symbol("battery.0percent")
        }
    }

    private func volumeIcon(_ percent: Int) -> StatusItem.Icon {
        if model.hasIconFont {
            return .glyph(BarStyle.volumeGlyph(percent: percent, muted: model.system.isMuted))
        }
        if model.system.isMuted || percent == 0 { return .symbol("speaker.slash.fill") }
        switch percent {
        case 60...: return .symbol("speaker.wave.3.fill")
        case 30..<60: return .symbol("speaker.wave.2.fill")
        default: return .symbol("speaker.wave.1.fill")
        }
    }
}

// MARK: - Sizing

/// Sizes derived from the bar's actual height, so a menu-bar-height bar (≈24pt, or the notch
/// strip ≈32–38pt) gets proportionally smaller pills and text than SketchyBar's 40pt.
struct BarMetrics {
    let fontSize: CGFloat
    let pillHeight: CGFloat
    let pillCorner: CGFloat
    let pillLeading: CGFloat
    let pillTrailing: CGFloat
    let itemSpacing: CGFloat
    let edgePadding: CGFloat
    let appIconSize: CGFloat

    /// Nerd Font (bold) for numerals and status glyphs; system bold if it isn't installed.
    let iconFont: NSFont
    /// SF Pro Semibold with tabular digits, like `label.font="SF Pro:Semibold:17.0"`.
    let labelFont: NSFont
    let appFont: NSFont?

    init(model: BarModel, barHeight: CGFloat) {
        let style = model.style
        let scale = min(1, barHeight / 40)          // SketchyBar config was designed for 40pt
        fontSize = min(style.fontSize, max(11, (barHeight * 0.48).rounded()))
        pillHeight = min(25, max(16, barHeight - 8))
        pillCorner = 5
        pillLeading = (10 * scale).rounded()
        pillTrailing = (20 * scale).rounded()
        itemSpacing = (10 * scale).rounded()
        edgePadding = 10
        appIconSize = (fontSize - 1).rounded()

        iconFont = model.hasIconFont
            ? NSFontManager.shared.font(withFamily: style.iconFont, traits: .boldFontMask, weight: 9, size: fontSize)
                ?? .boldSystemFont(ofSize: fontSize)
            : .boldSystemFont(ofSize: fontSize)
        labelFont = .monospacedDigitSystemFont(ofSize: fontSize, weight: .semibold)
        appFont = NSFont(name: "sketchybar-app-font", size: appIconSize)
            ?? NSFontManager.shared.font(withFamily: "sketchybar-app-font", traits: [], weight: 5, size: appIconSize)
    }
}

// MARK: - Optical vertical centring

/// Different fonts place their glyphs differently inside the line box (a CJK numeral from the
/// fallback font sits lower than an icon from sketchybar-app-font), so centring the *boxes*
/// leaves the visible shapes misaligned. This measures where the glyphs actually draw.
enum InkMetrics {
    private static var cache: [String: CGFloat] = [:]

    /// Height of the drawn glyphs' vertical centre above the baseline, in points.
    static func midline(of text: String, font: NSFont) -> CGFloat {
        let key = "\(font.fontName)|\(font.pointSize)|\(text)"
        if let cached = cache[key] { return cached }
        let line = CTLineCreateWithAttributedString(
            NSAttributedString(string: text, attributes: [.font: font]))
        let ink = CTLineGetBoundsWithOptions(line, .useGlyphPathBounds)   // baseline-relative, y up
        let mid = ink.isEmpty || !ink.midY.isFinite ? font.capHeight / 2 : ink.midY
        if cache.count > 500 { cache.removeAll() }   // the clock adds a key a minute
        cache[key] = mid
        return mid
    }
}

/// Renders icon-font text (Nerd Font glyphs, CJK numerals, sketchybar-app-font ligatures) into a
/// template image cropped to exactly the drawn shape.
///
/// Icon glyphs are often wider than their advance width, and SwiftUI's `Text` crops to the advance
/// — that's what cut the end off the battery. An ink-tight image can't be cropped, and because it
/// has no font padding, centring images centres what you actually see.
enum GlyphRenderer {
    private static var cache: [String: NSImage] = [:]

    static func image(_ text: String, font: NSFont) -> NSImage {
        let key = "\(font.fontName)|\(font.pointSize)|\(text)"
        if let cached = cache[key] { return cached }

        let line = CTLineCreateWithAttributedString(NSAttributedString(
            string: text, attributes: [.font: font, .foregroundColor: NSColor.black]))
        let ink = CTLineGetBoundsWithOptions(line, .useGlyphPathBounds)
        guard !ink.isEmpty, ink.width.isFinite, ink.height.isFinite else { return NSImage(size: .zero) }
        // Half a point of slack so antialiased edges aren't shaved off.
        let box = ink.insetBy(dx: -0.5, dy: -0.5)

        let image = NSImage(size: box.size, flipped: false) { _ in
            guard let ctx = NSGraphicsContext.current?.cgContext else { return false }
            ctx.textPosition = CGPoint(x: -box.minX, y: -box.minY)
            CTLineDraw(line, ctx)
            return true
        }
        image.isTemplate = true   // tinted by .foregroundStyle
        if cache.count > 300 { cache.removeAll() }
        cache[key] = image
        return image
    }
}

/// An icon-font string drawn as an ink-tight template image.
private struct GlyphImage: View {
    let text: String
    let font: NSFont

    var body: some View {
        Image(nsImage: GlyphRenderer.image(text, font: font))
            .renderingMode(.template)
            .fixedSize()
    }
}

private extension View {
    /// Clip only when there's a notch to keep clear of; otherwise nothing should be cut off.
    @ViewBuilder
    func clipped(if condition: Bool) -> some View {
        if condition { self.clipped() } else { self }
    }

    /// Makes this text's vertical-centre alignment guide the centre of its drawn glyphs.
    func centeredOnInk(_ text: String, font: NSFont) -> some View {
        let mid = InkMetrics.midline(of: text, font: font)
        return alignmentGuide(VerticalAlignment.center) { d in d[.firstTextBaseline] - mid }
    }
}

// MARK: - Items

/// A right-side item: optional icon (Nerd Font glyph, or SF Symbol if the font is missing) + label.
private struct StatusItem: View {
    enum Icon { case glyph(String), symbol(String) }
    let icon: Icon?
    let label: String
    let model: BarModel
    let metrics: BarMetrics

    var body: some View {
        HStack(alignment: .center, spacing: (metrics.fontSize * 0.45).rounded()) {
            if let icon {
                switch icon {
                case .glyph(let g):
                    GlyphImage(text: g, font: metrics.iconFont)
                case .symbol(let name):
                    Image(systemName: name)
                        .font(.system(size: metrics.fontSize - 2, weight: .semibold))
                }
            }
            Text(label)
                .font(Font(metrics.labelFont as CTFont))
                .centeredOnInk(label, font: metrics.labelFont)
        }
        .foregroundStyle(Color(argb: model.style.textARGB))
        .padding(.horizontal, 4)
        .fixedSize()
    }
}

/// plugins/aerospace.sh: numeral + strip of app icons, translucent pill; the focused one gets a
/// 2pt outline and drop shadows instead.
private struct WorkspacePill: View {
    let workspace: WMStatus.WorkspaceInfo
    let isFocused: Bool
    let model: BarModel
    let metrics: BarMetrics

    private var shadow: Color { isFocused ? Color.black.opacity(0.63) : .clear }

    var body: some View {
        let style = model.style
        let numeral = BarStyle.numeral(for: workspace.name, style: style.numerals)
        HStack(alignment: .center, spacing: 0) {
            GlyphImage(text: numeral, font: metrics.iconFont)
                .foregroundStyle(Color(argb: style.workspaceTextARGB))
                .shadow(color: shadow, radius: 0, x: 3, y: 2)
                .padding(.leading, metrics.pillLeading)
                .padding(.trailing, 6)

            appIcons
                .padding(.trailing, workspace.apps.isEmpty ? metrics.pillLeading : metrics.pillTrailing)
        }
        // The frame centres the row's ink-centred alignment guide, not its line boxes.
        .frame(height: metrics.pillHeight, alignment: .center)
        .background(
            RoundedRectangle(cornerRadius: metrics.pillCorner)
                .fill(Color(argb: isFocused ? style.focusedPillARGB : style.pillARGB))
        )
        .overlay(
            RoundedRectangle(cornerRadius: metrics.pillCorner)
                .strokeBorder(Color(argb: style.focusedOutlineARGB),
                              lineWidth: isFocused ? style.focusedOutlineWidth : 0)
        )
        .contentShape(Rectangle())
        .onTapGesture { model.onSelectWorkspace?(workspace.name) }
        .help("Workspace \(workspace.name)")
    }

    @ViewBuilder
    private var appIcons: some View {
        if workspace.apps.isEmpty || model.style.appIcons == .none {
            EmptyView()
        } else if model.usesAppFont, let appFont = metrics.appFont {
            // Same icons as aerospace.sh's strip (one sketchybar-app-font ligature per window),
            // each drawn ink-tight and centred, with even gaps.
            HStack(alignment: .center, spacing: (metrics.appIconSize * 0.45).rounded()) {
                ForEach(Array(workspace.apps.enumerated()), id: \.offset) { _, app in
                    GlyphImage(text: AppFontIconMap.ligature(for: app.name), font: appFont)
                }
            }
            .foregroundStyle(Color(argb: model.style.textARGB))
            .shadow(color: shadow, radius: 0, x: 3, y: 2)
        } else {
            HStack(spacing: 4) {
                ForEach(Array(workspace.apps.enumerated()), id: \.offset) { _, app in
                    if let icon = NSRunningApplication(processIdentifier: app.pid)?.icon {
                        Image(nsImage: icon)
                            .resizable()
                            .frame(width: metrics.appIconSize + 2, height: metrics.appIconSize + 2)
                    }
                }
            }
        }
    }
}

private struct VisualEffectBackground: NSViewRepresentable {
    func makeNSView(context: Context) -> NSVisualEffectView {
        let v = NSVisualEffectView()
        v.material = .hudWindow
        v.blendingMode = .behindWindow
        v.state = .active
        return v
    }
    func updateNSView(_ nsView: NSVisualEffectView, context: Context) {}
}

extension Color {
    /// 0xAARRGGBB, SketchyBar/JankyBorders notation.
    init(argb: UInt32) {
        self.init(.sRGB,
                  red: Double((argb >> 16) & 0xff) / 255,
                  green: Double((argb >> 8) & 0xff) / 255,
                  blue: Double(argb & 0xff) / 255,
                  opacity: Double((argb >> 24) & 0xff) / 255)
    }
}
