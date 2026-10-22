import Foundation

/// Tiny Markdown → HTML, used when pandoc isn't installed.
/// Covers: headings, paragraphs, bold/italic/code/links, fenced code, quotes,
/// flat lists, rules, pipe tables, YAML front matter (stripped).
/// Not covered: nested lists, footnotes, raw HTML, images. Install pandoc for full fidelity.
enum MiniMarkdown {
    static func toHTML(_ markdown: String) -> String {
        var lines = markdown.replacingOccurrences(of: "\r\n", with: "\n").components(separatedBy: "\n")

        // Strip YAML front matter.
        if lines.first?.trimmingCharacters(in: .whitespaces) == "---",
           let end = lines.dropFirst().prefix(40).firstIndex(where: { $0.trimmingCharacters(in: .whitespaces) == "---" }) {
            lines.removeSubrange(0...end)
        }

        var out: [String] = []
        var para: [String] = []
        var i = 0

        func flush() {
            guard !para.isEmpty else { return }
            out.append("<p>" + inline(para.joined(separator: " ")) + "</p>")
            para.removeAll()
        }

        while i < lines.count {
            let t = lines[i].trimmingCharacters(in: .whitespaces)

            if t.isEmpty { flush(); i += 1; continue }

            if t.hasPrefix("```") {
                flush()
                var code: [String] = []
                i += 1
                while i < lines.count, !lines[i].trimmingCharacters(in: .whitespaces).hasPrefix("```") {
                    code.append(lines[i])
                    i += 1
                }
                i += 1
                out.append("<pre>" + esc(code.joined(separator: "\n")) + "</pre>")
                continue
            }

            if let h = heading(t) {
                flush()
                out.append("<h\(h.level)>" + inline(h.text) + "</h\(h.level)>")
                i += 1
                continue
            }

            if isRule(t) { flush(); out.append("<hr>"); i += 1; continue }

            if t.hasPrefix(">") {
                flush()
                var quote: [String] = []
                while i < lines.count {
                    let q = lines[i].trimmingCharacters(in: .whitespaces)
                    guard q.hasPrefix(">") else { break }
                    quote.append(String(q.dropFirst()).trimmingCharacters(in: .whitespaces))
                    i += 1
                }
                out.append("<blockquote>" + inline(quote.joined(separator: " ")) + "</blockquote>")
                continue
            }

            if let first = listItem(t) {
                flush()
                var items: [String] = []
                while i < lines.count,
                      let li = listItem(lines[i].trimmingCharacters(in: .whitespaces)),
                      li.ordered == first.ordered {
                    items.append("<li>" + inline(li.text) + "</li>")
                    i += 1
                }
                let tag = first.ordered ? "ol" : "ul"
                out.append("<\(tag)>" + items.joined() + "</\(tag)>")
                continue
            }

            if t.contains("|"), i + 1 < lines.count, isTableSeparator(lines[i + 1]) {
                flush()
                let head = cells(t)
                i += 2
                var rows: [[String]] = []
                while i < lines.count,
                      lines[i].contains("|"),
                      !lines[i].trimmingCharacters(in: .whitespaces).isEmpty {
                    rows.append(cells(lines[i]))
                    i += 1
                }
                var html = "<table border=\"1\" cellpadding=\"4\" cellspacing=\"0\"><tr>"
                html += head.map { "<th>" + inline($0) + "</th>" }.joined() + "</tr>"
                for r in rows {
                    html += "<tr>" + r.map { "<td>" + inline($0) + "</td>" }.joined() + "</tr>"
                }
                html += "</table>"
                out.append(html)
                continue
            }

            para.append(t)
            i += 1
        }
        flush()
        return out.joined(separator: "\n")
    }

    // MARK: Block helpers

    private static func heading(_ t: String) -> (level: Int, text: String)? {
        var n = 0
        for ch in t { if ch == "#" { n += 1 } else { break } }
        guard (1...6).contains(n), t.count > n,
              t[t.index(t.startIndex, offsetBy: n)] == " " else { return nil }
        let text = String(t.dropFirst(n))
            .trimmingCharacters(in: .whitespaces)
            .trimmingCharacters(in: CharacterSet(charactersIn: "#"))
            .trimmingCharacters(in: .whitespaces)
        return (n, text)
    }

    private static func isRule(_ t: String) -> Bool {
        let s = t.replacingOccurrences(of: " ", with: "")
        guard s.count >= 3, let c = s.first, "-*_".contains(c) else { return false }
        return s.allSatisfy { $0 == c }
    }

    private static func listItem(_ t: String) -> (ordered: Bool, text: String)? {
        if t.hasPrefix("- ") || t.hasPrefix("* ") || t.hasPrefix("+ ") {
            return (false, String(t.dropFirst(2)))
        }
        var digits = 0
        for ch in t { if ch.isNumber { digits += 1 } else { break } }
        if digits > 0, digits < 9 {
            let rest = t.dropFirst(digits)
            if rest.hasPrefix(". ") || rest.hasPrefix(") ") {
                return (true, String(rest.dropFirst(2)))
            }
        }
        return nil
    }

    private static func isTableSeparator(_ line: String) -> Bool {
        let t = line.trimmingCharacters(in: .whitespaces)
        return t.contains("-") && t.contains("|") && t.allSatisfy { "|-: ".contains($0) }
    }

    private static func cells(_ line: String) -> [String] {
        var t = line.trimmingCharacters(in: .whitespaces)
        if t.hasPrefix("|") { t.removeFirst() }
        if t.hasSuffix("|") { t.removeLast() }
        return t.components(separatedBy: "|").map { $0.trimmingCharacters(in: .whitespaces) }
    }

    // MARK: Inline helpers

    static func inline(_ s: String) -> String {
        var t = esc(s)
        t = sub(t, "`([^`]+)`", "<code>$1</code>")
        t = sub(t, "!\\[([^\\]]*)\\]\\([^)]*\\)", "$1")
        t = sub(t, "\\[([^\\]]+)\\]\\(([^)\\s]+)\\)", "<a href=\"$2\">$1</a>")
        t = sub(t, "\\*\\*(.+?)\\*\\*", "<b>$1</b>")
        t = sub(t, "__(.+?)__", "<b>$1</b>")
        t = sub(t, "\\*(.+?)\\*", "<i>$1</i>")
        t = sub(t, "(?<![\\w])_(.+?)_(?![\\w])", "<i>$1</i>")
        t = sub(t, "~~(.+?)~~", "<s>$1</s>")
        return t
    }

    private static func esc(_ s: String) -> String {
        s.replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
    }

    private static func sub(_ s: String, _ pattern: String, _ template: String) -> String {
        guard let re = try? NSRegularExpression(pattern: pattern) else { return s }
        return re.stringByReplacingMatches(
            in: s, range: NSRange(s.startIndex..., in: s), withTemplate: template)
    }
}
