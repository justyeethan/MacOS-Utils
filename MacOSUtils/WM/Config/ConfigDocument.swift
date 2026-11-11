import Foundation
import Observation

/// Editable copy of the window-manager config for the settings window.
///
/// Loads whichever config is in effect (MacOSUtils' own file, else ~/.aerospace.toml, else the
/// built-in default), lets the UI edit bindings and borders, and saves the *whole* config —
/// every other setting carried over untouched — to ~/.config/macosutils/macosutils.toml.
/// The AeroSpace file is never modified, so AeroSpace keeps working with it.
@Observable
final class ConfigDocument {

    struct BindingRow: Identifiable, Equatable {
        var id = UUID()
        /// AeroSpace notation, e.g. `alt-shift-h`.
        var chord: String
        /// One or more commands separated by `;`, e.g. `join-with left; mode main`.
        var commands: String
    }

    private(set) var modeNames: [String] = ["main"]
    var bindings: [String: [BindingRow]] = [:]
    var border = BorderStyle()
    var bar = BarStyle()

    private(set) var sourcePath: String?
    /// Set when the config on disk couldn't be parsed; saving is disabled so it isn't clobbered.
    private(set) var loadError: String?

    @ObservationIgnored private var tree: [String: TOMLValue] = [:]
    private var savedBindings: [String: [BindingRow]] = [:]
    private var savedBorder = BorderStyle()
    private var savedBar = BarStyle()

    init() { load() }

    var isDirty: Bool { bindings != savedBindings || border != savedBorder || bar != savedBar }
    var savedBorderStyle: BorderStyle { savedBorder }
    var savedBarStyle: BarStyle { savedBar }
    var isUsingOwnFile: Bool { sourcePath == WMConfig.ownConfigPath }

    var sourceDescription: String {
        guard let sourcePath else { return "built-in default" }
        return (sourcePath as NSString).abbreviatingWithTildeInPath
    }

    // MARK: Load / revert

    func load() {
        let (text, path) = WMConfig.currentSource()
        sourcePath = path
        do {
            tree = try TOMLParser.parse(text)
            loadError = nil
        } catch {
            tree = [:]
            loadError = "\(sourceDescription): \(error)"
        }
        let config = (try? WMConfig.parse(text)) ?? WMConfig()
        border = config.border ?? BorderStyle()
        bar = config.bar

        var result: [String: [BindingRow]] = [:]
        for (mode, value) in tree["mode"]?.table ?? [:] {
            let table = value.table?["binding"]?.table ?? [:]
            result[mode] = table.keys.sorted(by: KeyChord.displayOrder).map { chord in
                BindingRow(chord: chord, commands: (table[chord]?.stringList ?? []).joined(separator: "; "))
            }
        }
        if result["main"] == nil { result["main"] = [] }
        bindings = result
        modeNames = ["main"] + result.keys.filter { $0 != "main" }.sorted()

        savedBindings = bindings
        savedBorder = border
        savedBar = bar
    }

    func revert() {
        bindings = savedBindings
        border = savedBorder
        bar = savedBar
    }

    // MARK: Editing

    @discardableResult
    func addBinding(to mode: String) -> UUID {
        let row = BindingRow(chord: "", commands: "")
        bindings[mode, default: []].append(row)
        return row.id
    }

    func removeBinding(_ id: UUID, from mode: String) {
        bindings[mode]?.removeAll { $0.id == id }
    }

    func addMode(_ name: String) {
        let clean = name.trimmingCharacters(in: .whitespaces)
        guard !clean.isEmpty, bindings[clean] == nil,
              clean.allSatisfy({ $0.isLetter || $0.isNumber || $0 == "-" || $0 == "_" }) else { return }
        bindings[clean] = []
        modeNames = ["main"] + bindings.keys.filter { $0 != "main" }.sorted()
    }

    // MARK: Validation

    static func splitCommands(_ text: String) -> [String] {
        text.split(separator: ";")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
    }

    /// Why a row can't be saved, or nil if it's fine.
    func problem(for row: BindingRow, in mode: String) -> String? {
        let chordText = row.chord.trimmingCharacters(in: .whitespaces)
        if chordText.isEmpty { return "Record a shortcut" }
        guard let chord = KeyChord.parse(chordText) else { return "Unknown key '\(chordText)'" }
        let duplicates = (bindings[mode] ?? []).filter { $0.id != row.id && KeyChord.parse($0.chord) == chord }
        if !duplicates.isEmpty { return "\(chordText) is bound more than once in this mode" }

        let commands = Self.splitCommands(row.commands)
        if commands.isEmpty { return "Add a command" }
        for command in commands {
            do { _ = try WMCommand.parse(command) } catch { return "\(error)" }
        }
        return nil
    }

    var hasProblems: Bool {
        bindings.contains { entry in
            entry.value.contains { problem(for: $0, in: entry.key) != nil }
        }
    }

    // MARK: Save

    enum SaveError: LocalizedError {
        case unreadableSource(String)
        case invalid(String)
        var errorDescription: String? {
            switch self {
            case .unreadableSource(let s): "Can't save: the current config couldn't be read (\(s))."
            case .invalid(let s): "Can't save: \(s)"
            }
        }
    }

    func save() throws {
        if let loadError { throw SaveError.unreadableSource(loadError) }
        guard !hasProblems else { throw SaveError.invalid("fix the highlighted bindings first.") }

        var t = tree
        var modeTable = t["mode"]?.table ?? [:]
        for name in modeNames {
            var table: [String: TOMLValue] = [:]
            for row in bindings[name] ?? [] {
                let chord = row.chord.trimmingCharacters(in: .whitespaces)
                let commands = Self.splitCommands(row.commands)
                guard !chord.isEmpty, !commands.isEmpty else { continue }
                table[chord] = commands.count == 1 ? .string(commands[0]) : .array(commands.map { TOMLValue.string($0) })
            }
            var modeEntry = modeTable[name]?.table ?? [:]
            modeEntry["binding"] = .table(table)
            modeTable[name] = .table(modeEntry)
        }
        t["mode"] = .table(modeTable)

        var borderTable: [String: TOMLValue] = [
            "active-color": .string(BorderStyle.hexString(border.activeARGB)),
            "width": .double(Double(border.width)),
            "corner-radius": .double(Double(border.cornerRadius)),
        ]
        borderTable["inactive-color"] = .string(border.inactiveARGB.map(BorderStyle.hexString) ?? "none")
        t["border"] = .table(borderTable)
        t["bar"] = .table(bar.table)

        let header = """
            # MacOSUtils window manager config (AeroSpace format, plus [border] and [bar] tables).
            # Written by the MacOSUtils settings window from: \(sourceDescription)
            # Delete this file to go back to ~/.aerospace.toml.

            """
        let text = header + TOMLWriter.write(t)

        // Never write something we can't read back.
        do {
            _ = try TOMLParser.parse(text)
            _ = try WMConfig.parse(text)
        } catch {
            throw SaveError.invalid("generated config didn't parse (\(error)).")
        }

        let url = URL(fileURLWithPath: WMConfig.ownConfigPath)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        try text.write(to: url, atomically: true, encoding: .utf8)

        tree = t
        sourcePath = WMConfig.ownConfigPath
        savedBindings = bindings
        savedBorder = border
        savedBar = bar
    }

    /// Moves MacOSUtils' own file to the Trash so ~/.aerospace.toml is used again.
    func useAeroSpaceConfig() throws {
        let url = URL(fileURLWithPath: WMConfig.ownConfigPath)
        if FileManager.default.fileExists(atPath: url.path) {
            try FileManager.default.trashItem(at: url, resultingItemURL: nil)
        }
        load()
    }
}
