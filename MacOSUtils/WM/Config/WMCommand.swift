import CoreGraphics
import Foundation

nonisolated enum Direction: String, Sendable, CaseIterable {
    case left, down, up, right

    var orientation: Orientation { self == .left || self == .right ? .horizontal : .vertical }
    /// +1 towards the end of a container's children (right/down), -1 towards the start.
    var step: Int { self == .right || self == .down ? 1 : -1 }
    var isPositive: Bool { step > 0 }
}

nonisolated enum Orientation: String, Sendable {
    case horizontal, vertical
    var opposite: Orientation { self == .horizontal ? .vertical : .horizontal }
}

nonisolated enum LayoutKind: String, Sendable {
    case tiles, accordion
}

/// One argument of AeroSpace's `layout` command.
nonisolated enum LayoutArg: String, Sendable {
    case tiles, accordion, horizontal, vertical, floating, tiling
    case hTiles = "h_tiles", vTiles = "v_tiles", hAccordion = "h_accordion", vAccordion = "v_accordion"

    init?(token: String) {
        // AeroSpace accepts `tiles` for the tiling side of `layout floating tiles`.
        self.init(rawValue: token)
    }
}

nonisolated enum ResizeDimension: String, Sendable {
    case smart, width, height
}

/// A window-manager command, written the same way as in an AeroSpace config.
nonisolated enum WMCommand: Equatable, Sendable {
    case focus(Direction)
    case move(Direction)
    case joinWith(Direction)
    case layout([LayoutArg])
    case resize(ResizeDimension, amount: CGFloat, relative: Bool)
    case balanceSizes
    case fullscreen
    case workspace(String)
    case workspaceNext, workspacePrev
    case workspaceBackAndForth
    case moveNodeToWorkspace(String)
    case mode(String)
    case reloadConfig
    case flattenWorkspaceTree
    case closeAllWindowsButCurrent
    case close
    case volume(VolumeAction)
    case execAndForget(String)
    case moveMouseMonitorLazyCenter
    case moveMouseWindowLazyCenter

    nonisolated enum VolumeAction: Equatable, Sendable {
        case up, down, muteToggle, set(Int)
    }

    /// Parses one command string such as `move left`, `layout tiles horizontal vertical`,
    /// `resize smart -50`, `exec-and-forget borders width=5`.
    static func parse(_ text: String) throws -> WMCommand {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        // exec-and-forget keeps the rest of the line verbatim (it's a shell command).
        if trimmed.hasPrefix("exec-and-forget") {
            let rest = trimmed.dropFirst("exec-and-forget".count).trimmingCharacters(in: .whitespaces)
            guard !rest.isEmpty else { throw CommandError(text, "missing shell command") }
            return .execAndForget(rest)
        }

        // Drop --flags (e.g. `workspace --auto-back-and-forth 1`); we accept and ignore them.
        let words = trimmed.split(whereSeparator: \.isWhitespace).map(String.init)
        let args = words.dropFirst().filter { !$0.hasPrefix("--") }
        guard let name = words.first else { throw CommandError(text, "empty command") }

        func direction() throws -> Direction {
            guard let a = args.first, let d = Direction(rawValue: a) else {
                throw CommandError(text, "expected left|down|up|right")
            }
            return d
        }

        switch name {
        case "focus":     return .focus(try direction())
        case "move":      return .move(try direction())
        case "join-with": return .joinWith(try direction())

        case "layout":
            let parsed = args.compactMap(LayoutArg.init(token:))
            guard !parsed.isEmpty, parsed.count == args.count else {
                throw CommandError(text, "unknown layout argument")
            }
            return .layout(parsed)

        case "resize":
            guard args.count == 2,
                  let dim = ResizeDimension(rawValue: args[args.startIndex]) else {
                throw CommandError(text, "expected: resize smart|width|height [+|-]N")
            }
            let amountText = args[args.startIndex + 1]
            guard let amount = Double(amountText) else { throw CommandError(text, "bad amount") }
            let relative = amountText.hasPrefix("+") || amountText.hasPrefix("-")
            return .resize(dim, amount: CGFloat(amount), relative: relative)

        case "balance-sizes": return .balanceSizes
        case "fullscreen":    return .fullscreen

        case "workspace":
            guard let ws = args.first else { throw CommandError(text, "missing workspace name") }
            switch ws {
            case "next": return .workspaceNext
            case "prev": return .workspacePrev
            default:     return .workspace(ws)
            }

        case "workspace-back-and-forth": return .workspaceBackAndForth

        case "move-node-to-workspace":
            guard let ws = args.first else { throw CommandError(text, "missing workspace name") }
            return .moveNodeToWorkspace(ws)

        case "mode":
            guard let m = args.first else { throw CommandError(text, "missing mode name") }
            return .mode(m)

        case "reload-config":                 return .reloadConfig
        case "flatten-workspace-tree":        return .flattenWorkspaceTree
        case "close-all-windows-but-current": return .closeAllWindowsButCurrent
        case "close":                         return .close

        case "volume":
            switch args.first {
            case "up":          return .volume(.up)
            case "down":        return .volume(.down)
            case "mute-toggle": return .volume(.muteToggle)
            case "set":
                guard args.count >= 2, let v = Int(args[args.startIndex + 1]) else {
                    throw CommandError(text, "expected: volume set N")
                }
                return .volume(.set(v))
            default: throw CommandError(text, "expected: volume up|down|mute-toggle|set N")
            }

        case "move-mouse":
            switch args.first {
            case "monitor-lazy-center": return .moveMouseMonitorLazyCenter
            case "window-lazy-center":  return .moveMouseWindowLazyCenter
            default: throw CommandError(text, "expected: move-mouse monitor-lazy-center|window-lazy-center")
            }

        default:
            throw CommandError(text, "unsupported command '\(name)'")
        }
    }
}

nonisolated struct CommandError: Error, CustomStringConvertible, Sendable {
    let command: String
    let reason: String
    init(_ command: String, _ reason: String) { self.command = command; self.reason = reason }
    var description: String { "'\(command)': \(reason)" }
}
