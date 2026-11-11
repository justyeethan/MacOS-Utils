import Foundation
import CoreGraphics

/// The window manager's configuration, read from an AeroSpace-format TOML file so an existing
/// `~/.aerospace.toml` works unchanged.
nonisolated struct WMConfig: Sendable {

    nonisolated struct WindowRule: Sendable {
        var appID: String?
        var appNameRegex: String?
        var windowTitleRegex: String?
        var duringStartup: Bool?
        var commands: [WMCommand]
        var checkFurtherCallbacks = false
    }

    /// A gap that may vary by monitor: `[{ monitor.main = 16 }, { monitor."LG" = 32 }, 24]`.
    nonisolated struct GapValue: Sendable {
        var perMonitor: [(pattern: String, value: CGFloat)] = []
        var fallback: CGFloat = 0
    }

    nonisolated struct Gaps: Sendable {
        var innerHorizontal = GapValue()
        var innerVertical = GapValue()
        var outerLeft = GapValue()
        var outerRight = GapValue()
        var outerTop = GapValue()
        var outerBottom = GapValue()
    }

    nonisolated enum RootOrientation: String, Sendable { case horizontal, vertical, auto }

    var afterStartupCommands: [WMCommand] = []
    /// Built-in focus border style, taken from a `borders …` (JankyBorders) startup command if present.
    var border: BorderStyle?
    var execOnWorkspaceChange: [String] = []
    var onFocusedMonitorChanged: [WMCommand] = []
    var flattenContainers = true
    var oppositeOrientationForNested = true
    var accordionPadding: CGFloat = 30
    var defaultRootLayout: LayoutKind = .tiles
    var defaultRootOrientation: RootOrientation = .auto
    var automaticallyUnhideHiddenApps = false
    var gaps = Gaps()
    /// mode name → chord → commands
    var modes: [String: [KeyChord: [WMCommand]]] = ["main": [:]]
    var windowRules: [WindowRule] = []
    /// Workspace names that appear in bindings, in a stable order ("1"…"9" for most configs).
    var workspaceNames: [String] = []

    /// Where the config came from, for the UI.
    var source = "built-in default"
    var errors: [String] = []
}

// MARK: - Loading

nonisolated extension WMConfig {

    /// Search order: our own file, then AeroSpace's two standard locations, then the built-in copy.
    static var candidatePaths: [String] {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let xdg = ProcessInfo.processInfo.environment["XDG_CONFIG_HOME"] ?? "\(home)/.config"
        return [
            "\(xdg)/macosutils/macosutils.toml",
            "\(home)/.aerospace.toml",
            "\(xdg)/aerospace/aerospace.toml",
        ]
    }

    /// MacOSUtils' own config file, written by the settings window. Checked before AeroSpace's.
    static var ownConfigPath: String { candidatePaths[0] }

    /// Text of the config in effect and where it came from (nil path = built-in default).
    static func currentSource() -> (text: String, path: String?) {
        for path in candidatePaths where FileManager.default.fileExists(atPath: path) {
            if let text = try? String(contentsOfFile: path, encoding: .utf8) { return (text, path) }
        }
        return (defaultConfigTOML, nil)
    }

    static func load() -> WMConfig {
        for path in candidatePaths where FileManager.default.fileExists(atPath: path) {
            do {
                let text = try String(contentsOfFile: path, encoding: .utf8)
                var config = try parse(text)
                config.source = path
                return config
            } catch {
                var fallback = (try? parse(defaultConfigTOML)) ?? WMConfig()
                fallback.source = "built-in default (failed to read \(path))"
                fallback.errors.insert("\(path): \(error)", at: 0)
                return fallback
            }
        }
        var config = (try? parse(defaultConfigTOML)) ?? WMConfig()
        config.source = "built-in default"
        return config
    }

    static func parse(_ text: String) throws -> WMConfig {
        let toml = try TOMLParser.parse(text)
        var c = WMConfig()
        var errors: [String] = []

        func commands(_ value: TOMLValue?, _ context: String) -> [WMCommand] {
            guard let list = value?.stringList else { return [] }
            return list.compactMap { text in
                do { return try WMCommand.parse(text) } catch {
                    errors.append("\(context): \(error)")
                    return nil
                }
            }
        }

        c.afterStartupCommands = commands(toml["after-startup-command"], "after-startup-command")
        for case .execAndForget(let shell) in c.afterStartupCommands {
            if let style = BorderStyle.fromBordersCommand(shell) { c.border = style }
        }
        // MacOSUtils' own [border] table (written by the settings window) wins over `borders …`.
        if let b = toml["border"]?.table {
            var style = c.border ?? BorderStyle()
            if let s = b["active-color"]?.string, let v = BorderStyle.parseHex(s) { style.activeARGB = v }
            if let s = b["inactive-color"]?.string {
                style.inactiveARGB = (s == "none" || s.isEmpty) ? nil : (BorderStyle.parseHex(s) ?? style.inactiveARGB)
            }
            if let w = b["width"]?.number { style.width = CGFloat(w) }
            if let r = b["corner-radius"]?.number { style.cornerRadius = CGFloat(r) }
            c.border = style
        }
        c.onFocusedMonitorChanged = commands(toml["on-focused-monitor-changed"], "on-focused-monitor-changed")
        c.execOnWorkspaceChange = toml["exec-on-workspace-change"]?.stringList ?? []

        if let v = toml["enable-normalization-flatten-containers"]?.bool { c.flattenContainers = v }
        if let v = toml["enable-normalization-opposite-orientation-for-nested-containers"]?.bool {
            c.oppositeOrientationForNested = v
        }
        if let v = toml["accordion-padding"]?.number { c.accordionPadding = CGFloat(v) }
        if let v = toml["default-root-container-layout"]?.string, let k = LayoutKind(rawValue: v) {
            c.defaultRootLayout = k
        }
        if let v = toml["default-root-container-orientation"]?.string, let o = RootOrientation(rawValue: v) {
            c.defaultRootOrientation = o
        }
        if let v = toml["automatically-unhide-macos-hidden-apps"]?.bool { c.automaticallyUnhideHiddenApps = v }

        if let preset = toml["key-mapping"]?.table?["preset"]?.string, preset != "qwerty" {
            errors.append("key-mapping.preset '\(preset)' isn't supported yet; using qwerty")
        }

        // Gaps
        if let g = toml["gaps"]?.table {
            func gap(_ group: String, _ key: String) -> GapValue {
                guard let v = g[group]?.table?[key] else { return GapValue() }
                return parseGap(v)
            }
            c.gaps.innerHorizontal = gap("inner", "horizontal")
            c.gaps.innerVertical   = gap("inner", "vertical")
            c.gaps.outerLeft       = gap("outer", "left")
            c.gaps.outerRight      = gap("outer", "right")
            c.gaps.outerTop        = gap("outer", "top")
            c.gaps.outerBottom     = gap("outer", "bottom")
        }

        // Modes and bindings
        var modes: [String: [KeyChord: [WMCommand]]] = ["main": [:]]
        var workspaceNames: [String] = []
        if let modeTable = toml["mode"]?.table {
            for (modeName, modeValue) in modeTable {
                var bindings: [KeyChord: [WMCommand]] = [:]
                for (key, value) in modeValue.table?["binding"]?.table ?? [:] {
                    guard let chord = KeyChord.parse(key) else {
                        errors.append("mode.\(modeName): unknown key '\(key)'")
                        continue
                    }
                    let cmds = commands(value, "mode.\(modeName).\(key)")
                    guard !cmds.isEmpty else { continue }
                    bindings[chord] = cmds
                    for cmd in cmds {
                        switch cmd {
                        case .workspace(let n), .moveNodeToWorkspace(let n):
                            if !workspaceNames.contains(n) { workspaceNames.append(n) }
                        default: break
                        }
                    }
                }
                modes[modeName] = bindings
            }
        }
        c.modes = modes
        c.workspaceNames = workspaceNames.sorted { a, b in
            switch (Int(a), Int(b)) {
            case let (x?, y?): x < y
            case (_?, nil):    true
            case (nil, _?):    false
            default:           a < b
            }
        }

        // on-window-detected
        for (index, entry) in (toml["on-window-detected"]?.array ?? []).enumerated() {
            guard let t = entry.table else { continue }
            let cond = t["if"]?.table ?? [:]
            var rule = WindowRule(commands: commands(t["run"], "on-window-detected[\(index)]"))
            rule.appID = cond["app-id"]?.string
            rule.appNameRegex = cond["app-name-regex-substring"]?.string
            rule.windowTitleRegex = cond["window-title-regex-substring"]?.string
            rule.duringStartup = cond["during-aerospace-startup"]?.bool
            rule.checkFurtherCallbacks = t["check-further-callbacks"]?.bool ?? false
            c.windowRules.append(rule)
        }

        c.errors = errors
        return c
    }

    private static func parseGap(_ value: TOMLValue) -> GapValue {
        if let n = value.number { return GapValue(fallback: CGFloat(n)) }
        var g = GapValue()
        for item in value.array ?? [] {
            if let n = item.number {
                g.fallback = CGFloat(n)
            } else if let monitors = item.table?["monitor"]?.table {
                for (pattern, v) in monitors {
                    if let n = v.number { g.perMonitor.append((pattern, CGFloat(n))) }
                }
            }
        }
        return g
    }
}

// MARK: - Built-in default

nonisolated extension WMConfig {
    /// Used when no config file exists. This is Ethan's AeroSpace config, so the app behaves the
    /// same with or without ~/.aerospace.toml.
    static let defaultConfigTOML = #"""
    after-login-command = []
    after-startup-command = [
      'exec-and-forget borders active_color=0xff6EA3FE inactive_color=0xff494d64 width=5'
    ]
    exec-on-workspace-change = ['/bin/bash', '-c',
        'sketchybar --trigger aerospace_workspace_change FOCUSED_WORKSPACE=$AEROSPACE_FOCUSED_WORKSPACE PREV_WORKSPACE=$AEROSPACE_PREV_WORKSPACE'
    ]
    start-at-login = true
    enable-normalization-flatten-containers = true
    enable-normalization-opposite-orientation-for-nested-containers = true
    accordion-padding = 10
    default-root-container-layout = 'tiles'
    default-root-container-orientation = 'auto'
    on-focused-monitor-changed = ['move-mouse monitor-lazy-center']
    automatically-unhide-macos-hidden-apps = false

    [key-mapping]
    preset = 'qwerty'

    [gaps]
    inner.horizontal = 15
    inner.vertical =   15
    outer.left =       10
    outer.bottom =     10
    outer.top =        [{monitor."Virtual 16:9" = 50}, 15]
    outer.right =      10

    [mode.main.binding]
    alt-slash = 'layout tiles horizontal vertical'
    alt-comma = 'layout accordion horizontal vertical'
    alt-shift-m = 'layout tiles accordion'
    alt-shift-t = 'layout floating tiles'
    alt-h = 'focus left'
    alt-j = 'focus down'
    alt-k = 'focus up'
    alt-l = 'focus right'
    alt-shift-h = 'move left'
    alt-shift-j = 'move down'
    alt-shift-k = 'move up'
    alt-shift-l = 'move right'
    alt-shift-minus = 'resize smart -50'
    alt-shift-equal = 'resize smart +50'
    alt-1 = 'workspace 1'
    alt-2 = 'workspace 2'
    alt-3 = 'workspace 3'
    alt-4 = 'workspace 4'
    alt-5 = 'workspace 5'
    alt-6 = 'workspace 6'
    alt-7 = 'workspace 7'
    alt-8 = 'workspace 8'
    alt-9 = 'workspace 9'
    alt-shift-1 = 'move-node-to-workspace 1'
    alt-shift-2 = 'move-node-to-workspace 2'
    alt-shift-3 = 'move-node-to-workspace 3'
    alt-shift-4 = 'move-node-to-workspace 4'
    alt-shift-5 = 'move-node-to-workspace 5'
    alt-shift-6 = 'move-node-to-workspace 6'
    alt-shift-7 = 'move-node-to-workspace 7'
    alt-shift-8 = 'move-node-to-workspace 8'
    alt-shift-9 = 'move-node-to-workspace 9'
    alt-shift-semicolon = 'mode service'

    [mode.service.binding]
    esc = ['reload-config', 'mode main']
    r = ['flatten-workspace-tree', 'mode main']
    f = ['layout floating tiling', 'mode main']
    backspace = ['close-all-windows-but-current', 'mode main']
    alt-shift-h = ['join-with left', 'mode main']
    alt-shift-j = ['join-with down', 'mode main']
    alt-shift-k = ['join-with up', 'mode main']
    alt-shift-l = ['join-with right', 'mode main']
    down = 'volume down'
    up = 'volume up'
    shift-down = ['volume set 0', 'mode main']

    [[on-window-detected]]
    if.app-id = 'app.zen-browser.zen'
    run = 'move-node-to-workspace 1'

    [[on-window-detected]]
    if.app-id = 'net.kovidgoyal.kitty'
    run = 'move-node-to-workspace 2'

    [[on-window-detected]]
    if.app-id = 'com.microsoft.VSCode'
    run = 'move-node-to-workspace 2'

    [[on-window-detected]]
    if.app-id = 'com.apple.mail'
    run = 'move-node-to-workspace 3'

    [[on-window-detected]]
    if.app-id = 'com.seriflabs.affinityphoto2'
    run = 'move-node-to-workspace 4'

    [[on-window-detected]]
    if.app-id = 'com.seriflabs.affinitypublisher2'
    run = 'move-node-to-workspace 4'

    [[on-window-detected]]
    if.app-id = 'com.seriflabs.affinitydesigner2'
    run = 'move-node-to-workspace 4'

    [[on-window-detected]]
    if.app-id = 'com.electron.dockerdesktop'
    run = 'move-node-to-workspace 4'

    [[on-window-detected]]
    if.app-id = 'com.valvesoftware.steam'
    run = 'move-node-to-workspace 4'

    [[on-window-detected]]
    if.app-id = 'com.valvesoftware.steam.helper'
    run = 'move-node-to-workspace 4'

    [[on-window-detected]]
    if.app-id = 'com.apple.Preview'
    run = 'move-node-to-workspace 5'

    [[on-window-detected]]
    if.app-id = 'com.hnc.Discord'
    run = 'move-node-to-workspace 4'

    [[on-window-detected]]
    if.app-id = 'com.apple.finder'
    run = 'move-node-to-workspace 5'

    [[on-window-detected]]
    if.app-id = 'com.nordvpn.macos'
    run = 'move-node-to-workspace 6'
    """#
}
