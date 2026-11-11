import AppKit
import Observation
import SwiftUI

/// Everything a bar view needs. One instance shared by the bars on all displays.
@Observable
final class BarModel {
    var style = BarStyle()
    var wm = WMStatus()
    let system = SystemStatus()
    /// Called when a workspace pill is clicked (SketchyBar's `click_script="aerospace workspace N"`).
    /// Per-display layout facts the view needs (width, where the notch is).
    var displays: [CGDirectDisplayID: DisplayGeometry] = [:]

    struct DisplayGeometry: Equatable {
        var width: CGFloat
        /// Actual bar height on this display.
        var height: CGFloat
        /// Horizontal span of the camera housing, in points from the display's left edge.
        /// nil on displays without a notch.
        var notch: ClosedRange<CGFloat>?
    }

    @ObservationIgnored var onSelectWorkspace: ((String) -> Void)?
    @ObservationIgnored var onOpenSettings: (() -> Void)?

    /// Whether the app-font ligatures can be used (font installed and not overridden).
    var usesAppFont: Bool {
        switch style.appIcons {
        case .appFont: true
        case .automatic: Self.hasAppFont
        case .appIcons, .none: false
        }
    }

    static let hasAppFont = NSFontManager.shared.availableFontFamilies.contains("sketchybar-app-font")

    var hasIconFont: Bool { NSFontManager.shared.availableFontFamilies.contains(style.iconFont) }
}

/// One borderless, non-activating panel along the top of each display, hosting `BarView`.
final class BarController {
    let model = BarModel()
    /// Bar height per display, after notch adjustment, for the window manager to tile below.
    /// Empty when the bar is off. Called after every rebuild.
    var onReservedHeightsChange: (([CGDirectDisplayID: CGFloat]) -> Void)?
    private var panels: [CGDirectDisplayID: BarPanel] = [:]
    private var screenObserver: NSObjectProtocol?

    init() {
        screenObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main
        ) { [unowned self] _ in
            MainActor.assumeIsolated { self.rebuild() }
        }
    }

    private var pendingStyle: BarStyle?

    /// Applies a style on the next run-loop turn, never synchronously.
    ///
    /// Callers include SwiftUI itself (AppModel is created during SwiftUI's scene update, and
    /// Settings previews from `onChange`). Changing the bar's observed state or creating/resizing
    /// its hosting views *inside* another SwiftUI update trips AttributeGraph's
    /// "setting value during update" precondition and aborts. Deferring avoids that, and
    /// coalesces rapid slider changes into one rebuild.
    func apply(_ style: BarStyle) {
        let alreadyScheduled = pendingStyle != nil
        pendingStyle = style
        guard !alreadyScheduled else { return }
        DispatchQueue.main.async { [unowned self] in
            MainActor.assumeIsolated { self.applyPending() }
        }
    }

    private func applyPending() {
        guard let style = pendingStyle else { return }
        pendingStyle = nil
        let wasEnabled = model.style.enabled
        if model.style != style { model.style = style }
        if style.enabled {
            model.system.start()
            rebuild()
        } else {
            if wasEnabled { model.system.stop() }
            closeAll()
        }
    }

    private func rebuild() {
        guard model.style.enabled else { closeAll(); return }
        var seen = Set<CGDirectDisplayID>()
        var heights: [CGDirectDisplayID: CGFloat] = [:]
        var geometry: [CGDirectDisplayID: BarModel.DisplayGeometry] = [:]
        for screen in NSScreen.screens {
            guard let number = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber
            else { continue }
            let id = CGDirectDisplayID(number.uint32Value)
            seen.insert(id)

            let notch = Self.notchSpan(of: screen)
            var h: CGFloat
            if model.style.matchMenuBar {
                h = Self.menuBarHeight(of: screen)
            } else {
                h = max(16, min(120, model.style.height.isFinite ? model.style.height : 40))
            }
            // On a notched display the bar must at least cover the notch strip (the menu-bar
            // row), otherwise a black band shows above it.
            if notch != nil { h = max(h, screen.safeAreaInsets.top) }
            h = h.rounded()
            heights[id] = h
            geometry[id] = .init(width: screen.frame.width, height: h, notch: notch)

            let frame = NSRect(x: screen.frame.minX, y: screen.frame.maxY - h,
                               width: screen.frame.width, height: h).integral
            let panel: BarPanel
            if let existing = panels[id] {
                panel = existing
                // Only on a display or height change. No forced redraw here: let AppKit lay the
                // SwiftUI content out in its normal pass.
                if panel.frame != frame { panel.setFrame(frame, display: false) }
            } else {
                // Created at its final size, so there's no 0×0 → full-width resize with SwiftUI
                // content attached (where it was aborting).
                panel = makePanel(for: id, frame: frame)
                panels[id] = panel
            }
            panel.level = model.style.drawOverMenuBar
                ? NSWindow.Level(rawValue: NSWindow.Level.mainMenu.rawValue + 1)   // over the menu bar
                : NSWindow.Level(rawValue: NSWindow.Level.mainMenu.rawValue - 1)   // auto-hidden menu bar slides over it
            panel.orderFrontRegardless()

            // macOS keeps ordinary windows out of the notch strip. `BarPanel` opts out of AppKit's
            // constraint; if the window server still pushed it down, go one level higher (above
            // the menu bar), which is allowed there.
            if panel.frame.maxY < screen.frame.maxY - 1 {
                panel.level = NSWindow.Level(rawValue: NSWindow.Level.mainMenu.rawValue + 1)
                panel.setFrame(frame, display: false)
                panel.orderFrontRegardless()
            }
        }
        for (id, panel) in panels where !seen.contains(id) {
            panel.orderOut(nil)
            panels[id] = nil
        }
        if model.displays != geometry { model.displays = geometry }
        onReservedHeightsChange?(model.style.reserveSpace ? heights : [:])
    }

    private func closeAll() {
        for panel in panels.values { panel.orderOut(nil) }
        panels = [:]
        onReservedHeightsChange?([:])
    }

    /// Height of the macOS menu bar on this display: the notch strip on notched displays,
    /// otherwise the menu bar's thickness (measured when it's showing, else the system value).
    static func menuBarHeight(of screen: NSScreen) -> CGFloat {
        if screen.safeAreaInsets.top > 0 { return screen.safeAreaInsets.top }
        let shown = screen.frame.maxY - screen.visibleFrame.maxY
        if shown > 0 { return shown }
        return NSStatusBar.system.thickness
    }

    /// Where the camera housing is, from the unobscured areas either side of it (macOS 12+).
    /// nil for displays without a notch (external monitors, older Macs).
    static func notchSpan(of screen: NSScreen) -> ClosedRange<CGFloat>? {
        guard screen.safeAreaInsets.top > 0,
              let left = screen.auxiliaryTopLeftArea,
              let right = screen.auxiliaryTopRightArea else { return nil }
        // Measured as widths so it doesn't matter which coordinate space the areas use.
        let start = left.width
        let end = screen.frame.width - right.width
        return end > start ? start...end : nil
    }

    private func makePanel(for displayID: CGDirectDisplayID, frame: NSRect) -> BarPanel {
        let panel = BarPanel(contentRect: frame,
                            styleMask: [.borderless, .nonactivatingPanel],
                            backing: .buffered, defer: false)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.becomesKeyOnlyIfNeeded = true
        panel.animationBehavior = .none
        panel.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle]

        let host = FirstClickHostingView(rootView: BarView(model: model, displayID: displayID))
        host.frame = NSRect(origin: .zero, size: frame.size)
        // The window owns its size (full display width × bar height). Without this, SwiftUI
        // also tries to size the window to its content; the two fight and AppKit aborts with
        // "more Update Constraints in Window passes than there are views".
        host.sizingOptions = []
        host.translatesAutoresizingMaskIntoConstraints = true
        host.autoresizingMask = [.width, .height]
        panel.contentView = host
        return panel
    }
}

/// A panel AppKit won't push below the menu bar / notch strip.
private final class BarPanel: NSPanel {
    override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect { frameRect }
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

/// The bar never becomes key, so let the very first click hit the workspace pills.
private final class FirstClickHostingView<Content: View>: NSHostingView<Content> {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}
