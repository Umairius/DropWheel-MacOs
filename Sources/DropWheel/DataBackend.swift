import Foundation

/// CSV ↔ JSON, no dependencies.
enum DataBackend {
    // MARK: CSV parsing (quotes, escaped quotes, embedded newlines, auto-detects , ; or tab)

    static func parseCSV(_ text: String) -> [[String]] {
        var cleaned = text
        if cleaned.hasPrefix("\u{FEFF}") { cleaned.removeFirst() }
        let chars = Array(cleaned)

        let firstLine = chars.prefix { $0 != "\n" && $0 != "\r\n" && $0 != "\r" }
        let candidates: [Character] = [",", ";", "\t"]
        let counts: [(Character, Int)] = candidates.map { d in (d, firstLine.filter { $0 == d }.count) }
        let best = counts.map { $0.1 }.max() ?? 0
        let delimiter: Character = best == 0 ? "," : (counts.first { $0.1 == best }?.0 ?? ",")

        var rows: [[String]] = []
        var row: [String] = []
        var field = ""
        var inQuotes = false
        var i = 0
        while i < chars.count {
            let c = chars[i]
            if inQuotes {
                if c == "\"" {
                    if i + 1 < chars.count, chars[i + 1] == "\"" { field.append("\""); i += 1 }
                    else { inQuotes = false }
                } else {
                    field.append(c)
                }
            } else if c == "\"" {
                inQuotes = true
            } else if c == delimiter {
                row.append(field); field = ""
            } else if c == "\n" || c == "\r\n" || c == "\r" {
                row.append(field); field = ""
                rows.append(row); row = []
            } else {
                field.append(c)
            }
            i += 1
        }
        if !field.isEmpty || !row.isEmpty { row.append(field); rows.append(row) }
        return rows.filter { !($0.count == 1 && $0[0].isEmpty) }
    }

    // MARK: CSV → JSON (array of objects, column order preserved)

    static func csvToJSON(_ input: URL, to out: URL) throws {
        let rows = parseCSV(try Backends.readText(input))
        guard let header = rows.first, rows.count >= 1 else { throw ConvError("This CSV is empty") }
        let keys = header.enumerated().map { $1.isEmpty ? "col\($0 + 1)" : $1 }

        var objects: [String] = []
        for row in rows.dropFirst() {
            var pairs: [String] = []
            for (i, key) in keys.enumerated() {
                let cell = i < row.count ? row[i] : ""
                pairs.append("    \(jsonString(key)): \(jsonValue(cell))")
            }
            objects.append("  {\n" + pairs.joined(separator: ",\n") + "\n  }")
        }
        let json = "[\n" + objects.joined(separator: ",\n") + "\n]\n"
        try json.write(to: out, atomically: true, encoding: .utf8)
    }

    private static func jsonString(_ s: String) -> String {
        let enc = JSONEncoder()
        enc.outputFormatting = [.withoutEscapingSlashes]
        guard let d = try? enc.encode(s), let r = String(data: d, encoding: .utf8) else { return "\"\"" }
        return r
    }

    /// Numbers and booleans become JSON numbers/booleans. Leading zeros ("007") stay strings.
    private static func jsonValue(_ cell: String) -> String {
        if cell == "true" || cell == "false" { return cell }
        if cell.range(of: "^-?(0|[1-9][0-9]{0,14})$", options: .regularExpression) != nil { return cell }
        if cell.range(of: "^-?(0|[1-9][0-9]*)\\.[0-9]+$", options: .regularExpression) != nil { return cell }
        return jsonString(cell)
    }

    // MARK: JSON → CSV (array of objects, or one object; columns sorted A–Z)

    static func jsonToCSV(_ input: URL, to out: URL) throws {
        let data = try Data(contentsOf: input)
        let obj = try JSONSerialization.jsonObject(with: data)
        let rows: [[String: Any]]
        if let arr = obj as? [[String: Any]] { rows = arr }
        else if let one = obj as? [String: Any] { rows = [one] }
        else { throw ConvError("JSON must be an array of objects (or a single object)") }
        guard !rows.isEmpty else { throw ConvError("This JSON has no rows") }

        var keys: [String] = []
        for r in rows { for k in r.keys.sorted() where !keys.contains(k) { keys.append(k) } }

        var lines = [keys.map(csvEscape).joined(separator: ",")]
        for r in rows {
            lines.append(keys.map { csvEscape(cell(r[$0])) }.joined(separator: ","))
        }
        try (lines.joined(separator: "\n") + "\n").write(to: out, atomically: true, encoding: .utf8)
    }

    private static func cell(_ v: Any?) -> String {
        guard let v = v, !(v is NSNull) else { return "" }
        if let s = v as? String { return s }
        if let n = v as? NSNumber {
            if CFGetTypeID(n) == CFBooleanGetTypeID() { return n.boolValue ? "true" : "false" }
            return n.stringValue
        }
        if JSONSerialization.isValidJSONObject(v),
           let d = try? JSONSerialization.data(withJSONObject: v, options: [.withoutEscapingSlashes]),
           let s = String(data: d, encoding: .utf8) { return s }
        return "\(v)"
    }

    private static func csvEscape(_ s: String) -> String {
        guard s.contains(",") || s.contains("\"") || s.contains("\n") || s.contains("\r") else { return s }
        return "\"" + s.replacingOccurrences(of: "\"", with: "\"\"") + "\""
    }
}
