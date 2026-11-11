import Foundation
import os

/// Fire-and-forget process launching for `exec-and-forget`, `exec-on-workspace-change` and
/// `volume`. GUI apps don't inherit the shell's PATH, so Homebrew's prefixes are added —
/// otherwise `borders` and `sketchybar` from your config wouldn't be found.
enum Exec {
    private static let log = Logger(subsystem: "MacOSUtils", category: "Exec")

    static var environment: [String: String] {
        var env = ProcessInfo.processInfo.environment
        let base = env["PATH"] ?? "/usr/bin:/bin:/usr/sbin:/sbin"
        env["PATH"] = "/opt/homebrew/bin:/opt/homebrew/sbin:/usr/local/bin:" + base
        return env
    }

    static func run(_ argv: [String], extraEnvironment: [String: String] = [:]) {
        guard let first = argv.first else { return }
        let p = Process()
        if first.hasPrefix("/") {
            p.executableURL = URL(fileURLWithPath: first)
            p.arguments = Array(argv.dropFirst())
        } else {
            p.executableURL = URL(fileURLWithPath: "/usr/bin/env")
            p.arguments = argv
        }
        p.environment = environment.merging(extraEnvironment) { $1 }
        p.standardInput = FileHandle.nullDevice
        p.standardOutput = FileHandle.nullDevice
        p.standardError = FileHandle.nullDevice
        do {
            try p.run()
        } catch {
            log.error("failed to run \(argv.joined(separator: " "), privacy: .public): \(error.localizedDescription, privacy: .public)")
        }
    }

    static func shell(_ command: String, extraEnvironment: [String: String] = [:]) {
        run(["/bin/bash", "-c", command], extraEnvironment: extraEnvironment)
    }

    static func appleScript(_ source: String) {
        run(["/usr/bin/osascript", "-e", source])
    }

    static func volume(_ action: WMCommand.VolumeAction) {
        switch action {
        case .up:
            appleScript("set volume output volume ((output volume of (get volume settings)) + 6)")
        case .down:
            appleScript("set volume output volume ((output volume of (get volume settings)) - 6)")
        case .muteToggle:
            appleScript("set volume output muted (not (output muted of (get volume settings)))")
        case .set(let v):
            appleScript("set volume output volume \(max(0, min(100, v)))")
        }
    }
}
