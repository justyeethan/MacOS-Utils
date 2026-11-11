import Foundation

/// A parsed TOML value.
nonisolated enum TOMLValue: Equatable, Sendable {
    case string(String)
    case integer(Int)
    case double(Double)
    case bool(Bool)
    case array([TOMLValue])
    case table([String: TOMLValue])

    var string: String? { if case .string(let v) = self { v } else { nil } }
    var integer: Int? { if case .integer(let v) = self { v } else { nil } }
    var bool: Bool? { if case .bool(let v) = self { v } else { nil } }
    var array: [TOMLValue]? { if case .array(let v) = self { v } else { nil } }
    var table: [String: TOMLValue]? { if case .table(let v) = self { v } else { nil } }

    /// Integer or float as a Double.
    var number: Double? {
        switch self {
        case .integer(let v): Double(v)
        case .double(let v): v
        default: nil
        }
    }

    /// A string, or an array of strings (AeroSpace accepts both for command lists).
    var stringList: [String]? {
        switch self {
        case .string(let s): [s]
        case .array(let a): a.compactMap(\.string)
        default: nil
        }
    }
}

nonisolated struct TOMLError: Error, CustomStringConvertible, Sendable {
    let message: String
    let line: Int
    var description: String { "TOML line \(line): \(message)" }
}

/// A small TOML parser covering what AeroSpace configs use: comments, bare/quoted/dotted
/// keys, `[table]` and `[[array.of.tables]]` headers, basic/literal/multi-line strings,
/// integers, floats, booleans, (multi-line) arrays and inline tables.
///
/// Not supported (not needed for AeroSpace configs): dates/times.
nonisolated struct TOMLParser {
    private let chars: [Character]
    private var i = 0
    private var line = 1

    static func parse(_ text: String) throws -> [String: TOMLValue] {
        // Swift treats "\r\n" as a single Character; normalise so newline checks see "\n".
        let normalized = text.replacingOccurrences(of: "\r\n", with: "\n")
        var parser = TOMLParser(chars: Array(normalized))
        return try parser.parseDocument()
    }

    private init(chars: [Character]) { self.chars = chars }

    // MARK: Document

    private mutating func parseDocument() throws -> [String: TOMLValue] {
        var root: [String: TOMLValue] = [:]
        var currentPath: [String] = []

        while true {
            skipWhitespaceNewlinesAndComments()
            guard let c = peek() else { break }

            if c == "[" {
                if peek(1) == "[" {
                    i += 2
                    skipInlineWhitespace()
                    let path = try parseKeyPath()
                    skipInlineWhitespace()
                    try expect("]"); try expect("]")
                    try Self.modify(&root, path.dropLast(), line: line) { table in
                        var arr = table[path.last!]?.array ?? []
                        arr.append(.table([:]))
                        table[path.last!] = .array(arr)
                    }
                    currentPath = path
                } else {
                    i += 1
                    skipInlineWhitespace()
                    let path = try parseKeyPath()
                    skipInlineWhitespace()
                    try expect("]")
                    try Self.modify(&root, path[...], line: line) { _ in }
                    currentPath = path
                }
                try expectEndOfLine()
            } else {
                let key = try parseKeyPath()
                skipInlineWhitespace()
                try expect("=")
                skipInlineWhitespace()
                let value = try parseValue()
                let line = self.line
                try Self.modify(&root, currentPath[...], line: line) { table in
                    try Self.setDotted(&table, key[...], value, line: line)
                }
                try expectEndOfLine()
            }
        }
        return root
    }

    /// Walks `path` from `dict`, creating tables as needed and descending into the last element
    /// of arrays of tables, then runs `body` on the table found.
    private static func modify(_ dict: inout [String: TOMLValue],
                               _ path: ArraySlice<String>,
                               line: Int,
                               _ body: (inout [String: TOMLValue]) throws -> Void) throws {
        guard let first = path.first else {
            try body(&dict)
            return
        }
        let rest = path.dropFirst()
        switch dict[first] {
        case .table(var t)?:
            try modify(&t, rest, line: line, body)
            dict[first] = .table(t)
        case .array(var arr)?:
            guard let last = arr.indices.last, case .table(var t) = arr[last] else {
                throw TOMLError(message: "'\(first)' is an array, not a table", line: line)
            }
            try modify(&t, rest, line: line, body)
            arr[last] = .table(t)
            dict[first] = .array(arr)
        case nil:
            var t: [String: TOMLValue] = [:]
            try modify(&t, rest, line: line, body)
            dict[first] = .table(t)
        default:
            throw TOMLError(message: "'\(first)' is a value, not a table", line: line)
        }
    }

    private static func setDotted(_ table: inout [String: TOMLValue],
                                  _ key: ArraySlice<String>,
                                  _ value: TOMLValue,
                                  line: Int) throws {
        guard let last = key.last else { return }
        try modify(&table, key.dropLast(), line: line) { t in
            t[last] = value
        }
    }

    // MARK: Keys

    private mutating func parseKeyPath() throws -> [String] {
        var parts: [String] = []
        while true {
            skipInlineWhitespace()
            parts.append(try parseSimpleKey())
            skipInlineWhitespace()
            if peek() == "." { i += 1 } else { break }
        }
        return parts
    }

    private mutating func parseSimpleKey() throws -> String {
        guard let c = peek() else { throw error("expected a key") }
        if c == "\"" { return try parseBasicString() }
        if c == "'" { return try parseLiteralString() }
        var key = ""
        while let c = peek(), c.isLetter || c.isNumber || c == "_" || c == "-" {
            key.append(c); i += 1
        }
        if key.isEmpty { throw error("expected a key, found '\(c)'") }
        return key
    }

    // MARK: Values

    private mutating func parseValue() throws -> TOMLValue {
        guard let c = peek() else { throw error("expected a value") }
        switch c {
        case "\"":
            if peek(1) == "\"" && peek(2) == "\"" { return .string(try parseMultilineBasicString()) }
            return .string(try parseBasicString())
        case "'":
            if peek(1) == "'" && peek(2) == "'" { return .string(try parseMultilineLiteralString()) }
            return .string(try parseLiteralString())
        case "[":
            return try parseArray()
        case "{":
            return try parseInlineTable()
        case "t", "f":
            if match("true") { return .bool(true) }
            if match("false") { return .bool(false) }
            throw error("unexpected '\(c)'")
        default:
            return try parseNumber()
        }
    }

    private mutating func parseArray() throws -> TOMLValue {
        try expect("[")
        var items: [TOMLValue] = []
        while true {
            skipWhitespaceNewlinesAndComments()
            if peek() == "]" { i += 1; break }
            items.append(try parseValue())
            skipWhitespaceNewlinesAndComments()
            if peek() == "," { i += 1; continue }
            if peek() == "]" { i += 1; break }
            throw error("expected ',' or ']' in array")
        }
        return .array(items)
    }

    private mutating func parseInlineTable() throws -> TOMLValue {
        try expect("{")
        var table: [String: TOMLValue] = [:]
        skipInlineWhitespace()
        if peek() == "}" { i += 1; return .table(table) }
        while true {
            let key = try parseKeyPath()
            skipInlineWhitespace()
            try expect("=")
            skipInlineWhitespace()
            let value = try parseValue()
            try Self.setDotted(&table, key[...], value, line: line)
            skipInlineWhitespace()
            if peek() == "," { i += 1; skipInlineWhitespace(); continue }
            if peek() == "}" { i += 1; break }
            throw error("expected ',' or '}' in inline table")
        }
        return .table(table)
    }

    private mutating func parseNumber() throws -> TOMLValue {
        var s = ""
        while let c = peek(), c.isNumber || c.isLetter || "+-._".contains(c) {
            if c != "_" { s.append(c) }
            i += 1
        }
        if s.hasPrefix("0x"), let v = Int(s.dropFirst(2), radix: 16) { return .integer(v) }
        if let v = Int(s) { return .integer(v) }
        if let v = Double(s) { return .double(v) }
        throw error("invalid value '\(s)'")
    }

    private mutating func parseBasicString() throws -> String {
        try expect("\"")
        var out = ""
        while true {
            guard let c = peek() else { throw error("unterminated string") }
            if c == "\n" { throw error("newline in string") }
            i += 1
            if c == "\"" { return out }
            if c == "\\" { out.append(contentsOf: try parseEscape()) } else { out.append(c) }
        }
    }

    private mutating func parseMultilineBasicString() throws -> String {
        i += 3
        if peek() == "\n" { i += 1; line += 1 }
        var out = ""
        while true {
            guard let c = peek() else { throw error("unterminated string") }
            if c == "\"" && peek(1) == "\"" && peek(2) == "\"" { i += 3; return out }
            i += 1
            if c == "\n" { line += 1 }
            if c == "\\" {
                // Line-ending backslash trims the newline and following whitespace.
                if let n = peek(), n == "\n" || n == " " || n == "\t" {
                    while let w = peek(), w.isWhitespace { if w == "\n" { line += 1 }; i += 1 }
                } else {
                    out.append(contentsOf: try parseEscape())
                }
            } else {
                out.append(c)
            }
        }
    }

    private mutating func parseLiteralString() throws -> String {
        try expect("'")
        var out = ""
        while true {
            guard let c = peek() else { throw error("unterminated string") }
            if c == "\n" { throw error("newline in string") }
            i += 1
            if c == "'" { return out }
            out.append(c)
        }
    }

    private mutating func parseMultilineLiteralString() throws -> String {
        i += 3
        if peek() == "\n" { i += 1; line += 1 }
        var out = ""
        while true {
            guard let c = peek() else { throw error("unterminated string") }
            if c == "'" && peek(1) == "'" && peek(2) == "'" { i += 3; return out }
            if c == "\n" { line += 1 }
            out.append(c); i += 1
        }
    }

    private mutating func parseEscape() throws -> String {
        guard let c = peek() else { throw error("bad escape") }
        i += 1
        switch c {
        case "n": return "\n"
        case "t": return "\t"
        case "r": return "\r"
        case "\"": return "\""
        case "\\": return "\\"
        case "b": return "\u{08}"
        case "f": return "\u{0C}"
        case "u", "U":
            let count = c == "u" ? 4 : 8
            var hex = ""
            for _ in 0..<count { if let h = peek() { hex.append(h); i += 1 } }
            guard let v = UInt32(hex, radix: 16), let scalar = Unicode.Scalar(v) else {
                throw error("bad unicode escape")
            }
            return String(Character(scalar))
        default:
            throw error("unknown escape '\\\(c)'")
        }
    }

    // MARK: Scanning helpers

    private func peek(_ offset: Int = 0) -> Character? {
        let j = i + offset
        return j < chars.count ? chars[j] : nil
    }

    private mutating func match(_ word: String) -> Bool {
        let w = Array(word)
        guard i + w.count <= chars.count, Array(chars[i..<(i + w.count)]) == w else { return false }
        i += w.count
        return true
    }

    private mutating func expect(_ c: Character) throws {
        guard peek() == c else { throw error("expected '\(c)'") }
        i += 1
    }

    private mutating func skipInlineWhitespace() {
        while let c = peek(), c == " " || c == "\t" { i += 1 }
    }

    private mutating func skipComment() {
        if peek() == "#" { while let c = peek(), c != "\n" { i += 1 } }
    }

    private mutating func skipWhitespaceNewlinesAndComments() {
        while let c = peek() {
            if c == " " || c == "\t" || c == "\r" { i += 1 }
            else if c == "\n" { i += 1; line += 1 }
            else if c == "#" { skipComment() }
            else { break }
        }
    }

    private mutating func expectEndOfLine() throws {
        skipInlineWhitespace()
        skipComment()
        if peek() == "\r" { i += 1 }
        guard let c = peek() else { return }
        guard c == "\n" else { throw error("unexpected '\(c)' after value") }
        i += 1; line += 1
    }

    private func error(_ message: String) -> TOMLError {
        TOMLError(message: message, line: line)
    }
}
