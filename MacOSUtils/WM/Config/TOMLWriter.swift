import Foundation

/// Serialises a parsed TOML tree back to text in AeroSpace's layout: top-level settings first,
/// then `[tables]` (with `[mode.<name>.binding]` sections), then `[[arrays.of.tables]]` with
/// dotted keys (`if.app-id = …`). Comments from the original file aren't preserved — which is
/// why the settings window writes its own file instead of touching ~/.aerospace.toml.
nonisolated enum TOMLWriter {

    static let topLevelOrder = [
        "after-login-command", "after-startup-command", "exec-on-workspace-change", "start-at-login",
        "enable-normalization-flatten-containers",
        "enable-normalization-opposite-orientation-for-nested-containers",
        "accordion-padding", "default-root-container-layout", "default-root-container-orientation",
        "on-focused-monitor-changed", "automatically-unhide-macos-hidden-apps",
    ]
    static let tableOrder = ["key-mapping", "gaps", "border", "bar", "mode"]

    static func write(_ root: [String: TOMLValue]) -> String {
        var out = ""
        let scalars = root.filter { !isTable($0.value) && !isArrayOfTables($0.value) }
        for key in ordered(Array(scalars.keys), preferred: topLevelOrder) {
            out += "\(bareOrQuoted(key)) = \(value(scalars[key]!))\n"
        }
        for key in ordered(root.keys.filter { isTable(root[$0]!) }, preferred: tableOrder) {
            if case .table(let t)? = root[key] { emitTable(path: [key], t, into: &out) }
        }
        for key in root.keys.filter({ isArrayOfTables(root[$0]!) }).sorted() {
            emitArrayOfTables(path: [key], root[key]!.array ?? [], into: &out)
        }
        return out
    }

    // MARK: Sections

    private static func emitTable(path: [String], _ table: [String: TOMLValue], into out: inout String) {
        let scalars = table.filter { !isTable($0.value) && !isArrayOfTables($0.value) }
        let subtables = table.keys.filter { isTable(table[$0]!) }
        let arrays = table.keys.filter { isArrayOfTables(table[$0]!) }

        if !scalars.isEmpty || (subtables.isEmpty && arrays.isEmpty) {
            out += "\n[\(path.map(bareOrQuoted).joined(separator: "."))]\n"
            let keys = path.last == "binding"
                ? scalars.keys.sorted(by: KeyChord.displayOrder)
                : scalars.keys.sorted()
            for key in keys {
                out += "\(bareOrQuoted(key)) = \(value(scalars[key]!))\n"
            }
        }
        let preferred = path == ["mode"] ? ["main"] : []
        for key in ordered(subtables, preferred: preferred) {
            if case .table(let t)? = table[key] { emitTable(path: path + [key], t, into: &out) }
        }
        for key in arrays.sorted() {
            emitArrayOfTables(path: path + [key], table[key]!.array ?? [], into: &out)
        }
    }

    private static func emitArrayOfTables(path: [String], _ items: [TOMLValue], into out: inout String) {
        let header = path.map(bareOrQuoted).joined(separator: ".")
        for item in items {
            guard case .table(let t) = item else { continue }
            out += "\n[[\(header)]]\n"
            for (key, v) in flatten(t, prefix: []) {
                out += "\(key) = \(value(v))\n"
            }
        }
    }

    /// Nested tables inside an array-of-tables element become dotted keys: `if.app-id = '…'`.
    private static func flatten(_ table: [String: TOMLValue], prefix: [String]) -> [(String, TOMLValue)] {
        var result: [(String, TOMLValue)] = []
        // Conditions (`if.*`) read best first, then `run`, then anything else.
        let order = ["if", "check-further-callbacks", "run"]
        for key in ordered(Array(table.keys), preferred: order) {
            let v = table[key]!
            if case .table(let sub) = v {
                result += flatten(sub, prefix: prefix + [key])
            } else {
                result.append(((prefix + [key]).map(bareOrQuoted).joined(separator: "."), v))
            }
        }
        return result
    }

    // MARK: Values

    static func value(_ v: TOMLValue) -> String {
        switch v {
        case .string(let s):
            return string(s)
        case .integer(let i):
            return String(i)
        case .double(let d):
            if d == d.rounded(), abs(d) < 1e15 { return String(Int(d)) }
            return String(d)
        case .bool(let b):
            return b ? "true" : "false"
        case .array(let items):
            let parts = items.map(value)
            let oneLine = "[" + parts.joined(separator: ", ") + "]"
            if oneLine.count <= 100 { return oneLine }
            return "[\n" + parts.map { "    " + $0 }.joined(separator: ",\n") + ",\n]"
        case .table(let t):
            let entries = t.keys.sorted().map { "\(bareOrQuoted($0)) = \(value(t[$0]!))" }
            return "{ " + entries.joined(separator: ", ") + " }"
        }
    }

    /// Single-quoted literal when possible (AeroSpace style), otherwise an escaped basic string.
    private static func string(_ s: String) -> String {
        if !s.contains("'") && !s.contains(where: \.isNewline) { return "'\(s)'" }
        return basicString(s)
    }

    private static func basicString(_ s: String) -> String {
        var out = "\""
        for scalar in s.unicodeScalars {
            switch scalar {
            case "\"": out += "\\\""
            case "\\": out += "\\\\"
            case "\n": out += "\\n"
            case "\t": out += "\\t"
            case "\r": out += "\\r"
            default:
                if scalar.value < 0x20 {
                    out += String(format: "\\u%04X", scalar.value)
                } else {
                    out.unicodeScalars.append(scalar)
                }
            }
        }
        return out + "\""
    }

    static func bareOrQuoted(_ key: String) -> String {
        let bare = !key.isEmpty && key.allSatisfy { c in
            c.isASCII && (c.isLetter || c.isNumber || c == "_" || c == "-")
        }
        return bare ? key : basicString(key)
    }

    // MARK: Helpers

    private static func isTable(_ v: TOMLValue) -> Bool {
        if case .table = v { return true }
        return false
    }

    private static func isArrayOfTables(_ v: TOMLValue) -> Bool {
        guard case .array(let items) = v, !items.isEmpty else { return false }
        return items.allSatisfy(isTable)
    }

    private static func ordered(_ keys: [String], preferred: [String]) -> [String] {
        let set = Set(keys)
        return preferred.filter(set.contains) + keys.filter { !preferred.contains($0) }.sorted()
    }
}
