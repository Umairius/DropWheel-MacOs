import AppKit
import PDFKit
import Vision

// MARK: - Types

enum SpotKind: String {
    case signature, initials, date
}

/// A place where something probably belongs. All numbers are upright page points, y down.
struct Spot {
    var page: Int
    var kind: SpotKind
    var x: CGFloat              // left edge of the writing area
    var baseline: CGFloat       // y of the line the ink sits on
    var width: CGFloat          // room to the right of x
    var hasLine: Bool
    var score: Double
    var crowd: Double           // fraction of dark pixels where the ink would go (0 = clear paper)
    var reason: String
}

struct DetectedLine {
    var x0: CGFloat
    var x1: CGFloat
    var y: CGFloat
}

private enum HitKind { case signature, initials, date, name }

private struct LabelHit {
    var kind: HitKind
    var weight: Double
    var rect: CGRect            // upright points
    var words: Int              // words on the text line the label sits in: long lines are body text
}

// MARK: - Line detection
//
// Direct port of the Python prototype that was tuned on clean and noisy scanned pages:
// 5/5 lines found on both, zero false positives on dense text.

enum LineFinder {
    static let darkSum = 140        // darkness summed over two pixel rows: catches hairlines that straddle rows
    static let gap = 2              // pixel gap tolerated inside one line
    static let minLenPt = 60.0
    static let maxThickPt = 3.0

    private struct Active {
        var x0: Int
        var x1: Int
        var y0: Int
        var y1: Int
    }

    static func find(in g: PageRaster.Gray) -> [DetectedLine] {
        let w = g.w, h = g.h
        guard w > 0, h > 1 else { return [] }
        let minLen = Int(minLenPt * g.sx)
        let maxThick = Int(maxThickPt * g.sy)
        var active: [Active] = []
        var done: [Active] = []
        var row = [Bool](repeating: false, count: w)

        g.px.withUnsafeBufferPointer { px in
            for y in 0..<h {
                let base = y * w
                let nextBase = (y + 1) * w
                var any = false
                for x in 0..<w {
                    var d = 255 - Int(px[base + x])
                    if y + 1 < h { d += 255 - Int(px[nextBase + x]) }
                    let dark = d > darkSum
                    row[x] = dark
                    if dark { any = true }
                }

                var runs: [(Int, Int)] = []
                if any {
                    var start = -1
                    var prev = -1
                    for x in 0..<w where row[x] {
                        if start < 0 {
                            start = x
                        } else if x - prev - 1 > gap {
                            runs.append((start, prev))
                            start = x
                        }
                        prev = x
                    }
                    if start >= 0 { runs.append((start, prev)) }
                }

                var next: [Active] = []
                var used = Set<Int>()
                for r in runs where r.1 - r.0 + 1 >= minLen {
                    var hit = -1
                    for (k, a) in active.enumerated() where !used.contains(k) {
                        let overlap = min(a.x1, r.1) - max(a.x0, r.0)
                        let need = 0.8 * Double(min(a.x1 - a.x0, r.1 - r.0))
                        if Double(overlap) >= need && a.y1 == y - 1 { hit = k; break }
                    }
                    if hit < 0 {
                        next.append(Active(x0: r.0, x1: r.1, y0: y, y1: y))
                    } else {
                        used.insert(hit)
                        var a = active[hit]
                        a.x0 = min(a.x0, r.0)
                        a.x1 = max(a.x1, r.1)
                        a.y1 = y
                        next.append(a)
                    }
                }
                for (k, a) in active.enumerated() where !used.contains(k) { done.append(a) }
                active = next
            }
        }
        done += active

        var lines: [DetectedLine] = []
        for a in done where a.y1 - a.y0 + 1 <= maxThick {
            lines.append(DetectedLine(x0: CGFloat(Double(a.x0) / g.sx),
                                      x1: CGFloat(Double(a.x1 + 1) / g.sx),
                                      y: CGFloat(Double(a.y0 + a.y1 + 1) / 2.0 / g.sy)))
        }
        return lines.sorted { ($0.y, $0.x0) < ($1.y, $1.x0) }
    }
}

// MARK: - Spot finder

enum SpotFinder {
    // Multilingual labels. "Signatures" (plural heading) deliberately doesn't match.
    private struct LabelPattern {
        let kind: HitKind
        let regex: NSRegularExpression
    }

    private static let patterns: [LabelPattern] = {
        func make(_ k: HitKind, _ p: String) -> LabelPattern? {
            guard let r = try? NSRegularExpression(pattern: p, options: [.caseInsensitive]) else { return nil }
            return LabelPattern(kind: k, regex: r)
        }
        return [
            make(.signature, "\\b(signature|signed|signer|signatory|sign here|sign|handtekening|ondertekening|ondertekend|unterschrift|unterzeichner|signatur|firma|firmado|firmar|signataire|podpis|imza)\\b|lu et approuv"),
            make(.initials, "\\b(initials|initial here|paraaf|paraphe|parafe|initialen|iniciales)\\b"),
            make(.date, "\\b(date|datum|fecha)\\b"),
        ].compactMap { $0 }
    }()

    private static func weight(_ kind: HitKind, matched: String) -> Double {
        let m = matched.lowercased()
        switch kind {
        case .signature:
            if m == "sign here" { return 6 }
            let strong: Set<String> = ["signature", "handtekening", "ondertekening", "unterschrift", "signatur", "signataire"]
            if strong.contains(m) || m.hasPrefix("lu et approuv") { return 5 }
            return 3
        case .initials: return 4
        case .date: return 2
        case .name: return 0
        }
    }

    // MARK: Entry point

    /// Pages are visited last to first (that's where signatures live). Pages with a text layer are free;
    /// scans and rotated pages go through Vision OCR, at most `ocrBudget` of them.
    static func find(in doc: PDFDocument, printedName: String?, ocrBudget: Int = 3) -> [Spot] {
        let count = doc.pageCount
        guard count > 0 else { return [] }
        var spots: [Spot] = []
        var budget = ocrBudget
        var lastPageLines: [DetectedLine] = []
        var lastPageRaster: PageRaster.Gray?
        var lastPageSize = CGSize(width: 595, height: 842)

        for index in stride(from: count - 1, through: 0, by: -1) {
            guard let page = doc.page(at: index) else { continue }
            let geo = PageGeometry(page: page)
            let pageSize = geo.size
            let isLast = index == count - 1

            spots += widgetSpots(page, index: index, geo: geo)

            let text = page.string ?? ""
            let hasText = geo.rotation == 0 && text.filter({ !$0.isWhitespace }).count >= 25
            var hits: [LabelHit] = []
            var raster: PageRaster.Gray?

            if hasText {
                hits = textHits(page, text: text, geo: geo, name: printedName)
            } else if budget > 0 {
                budget -= 1
                raster = PageRaster.gray(page, geo: geo, scale: 2)
                if let r = raster { hits = ocrHits(r.cg, pageSize: pageSize, name: printedName) }
            }

            let wanted = hits.filter { $0.kind != .name }
            let names = hits.filter { $0.kind == .name }.map { $0.rect }

            if !wanted.isEmpty || isLast {
                if raster == nil { raster = PageRaster.gray(page, geo: geo, scale: 2) }
            }
            let lines = raster.map { LineFinder.find(in: $0) } ?? []

            for h in wanted {
                if let s = makeSpot(h, lines: lines, raster: raster, pageSize: pageSize,
                                    page: index, isLast: isLast, names: names) {
                    spots.append(s)
                }
            }
            if isLast {
                lastPageLines = lines
                lastPageRaster = raster
                lastPageSize = pageSize
            }
        }

        if !spots.contains(where: { $0.kind == .signature }) {
            spots.append(fallback(page: count - 1, size: lastPageSize, lines: lastPageLines, raster: lastPageRaster))
        }
        return dedupe(spots).sorted { $0.score > $1.score }
    }

    // MARK: Real signature fields (exact answers)

    private static func widgetSpots(_ page: PDFPage, index: Int, geo: PageGeometry) -> [Spot] {
        var out: [Spot] = []
        for a in page.annotations where a.widgetFieldType == .signature {
            // A value means somebody already signed this field: not ours to use.
            if a.value(forAnnotationKey: PDFAnnotationKey(rawValue: "/V")) != nil { continue }
            let r = geo.toUpright(rect: a.bounds)
            guard r.width > 20, r.height > 8 else { continue }
            out.append(Spot(page: index, kind: .signature, x: r.minX, baseline: r.maxY - 3, width: r.width,
                            hasLine: true, score: 20, crowd: 0, reason: "Signature field in the document"))
        }
        return out
    }

    // MARK: Text-layer labels

    private static func textHits(_ page: PDFPage, text: String, geo: PageGeometry, name: String?) -> [LabelHit] {
        let ns = text as NSString
        let all = NSRange(location: 0, length: ns.length)
        var hits: [LabelHit] = []

        func add(_ kind: HitKind, _ range: NSRange, weight: Double) {
            guard let sel = page.selection(for: range) else { return }
            let b = sel.bounds(for: page)
            guard b.width > 0, b.height > 0 else { return }
            let line = ns.substring(with: ns.lineRange(for: range))
            let words = line.split(whereSeparator: { $0.isWhitespace }).count
            hits.append(LabelHit(kind: kind, weight: weight, rect: geo.toUpright(rect: b), words: words))
        }

        for p in patterns {
            p.regex.enumerateMatches(in: text, options: [], range: all) { m, _, _ in
                guard let m else { return }
                add(p.kind, m.range, weight: weight(p.kind, matched: ns.substring(with: m.range)))
            }
        }
        if let n = name, n.count >= 3,
           let rx = try? NSRegularExpression(pattern: NSRegularExpression.escapedPattern(for: n), options: [.caseInsensitive]) {
            rx.enumerateMatches(in: text, options: [], range: all) { m, _, _ in
                if let m { add(.name, m.range, weight: 0) }
            }
        }
        return hits
    }

    // MARK: OCR labels (scans, photos, rotated pages)

    private static func ocrHits(_ cg: CGImage, pageSize: CGSize, name: String?) -> [LabelHit] {
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = false
        let handler = VNImageRequestHandler(cgImage: cg, options: [:])
        do { try handler.perform([request]) } catch { return [] }
        let observations = request.results ?? []

        var hits: [LabelHit] = []
        for obs in observations {
            guard let cand = obs.topCandidates(1).first else { continue }
            let s = cand.string
            let ns = s as NSString
            let all = NSRange(location: 0, length: ns.length)
            let words = s.split(whereSeparator: { $0.isWhitespace }).count

            func rect(_ r: NSRange) -> CGRect? {
                guard let sr = Range(r, in: s), let box = try? cand.boundingBox(for: sr) else { return nil }
                let b = box.boundingBox      // normalized, origin bottom-left
                return CGRect(x: b.minX * pageSize.width, y: (1 - b.maxY) * pageSize.height,
                              width: b.width * pageSize.width, height: b.height * pageSize.height)
            }

            for p in patterns {
                p.regex.enumerateMatches(in: s, options: [], range: all) { m, _, _ in
                    guard let m, let r = rect(m.range) else { return }
                    hits.append(LabelHit(kind: p.kind, weight: weight(p.kind, matched: ns.substring(with: m.range)),
                                         rect: r, words: words))
                }
            }
            if let n = name, n.count >= 3, let r = s.range(of: n, options: .caseInsensitive),
               let box = rect(NSRange(r, in: s)) {
                hits.append(LabelHit(kind: .name, weight: 0, rect: box, words: words))
            }
        }
        return hits
    }

    // MARK: From a label to a place

    private enum Assoc { case right, above }

    private static func associate(_ h: CGRect, _ lines: [DetectedLine], pageW: CGFloat) -> (line: DetectedLine, kind: Assoc, score: Double)? {
        var best: (line: DetectedLine, kind: Assoc, score: Double)?
        for l in lines {
            let wid = l.x1 - l.x0
            var sc: Double
            var kind: Assoc
            if l.x0 >= h.minX - 2 && l.x0 - h.maxX <= 90 && h.minY - 4 <= l.y && l.y <= h.maxY + 6 && l.x1 > h.maxX {
                sc = 6 - Double(l.x0 - h.maxX) / 30        // a line right after the label: "Signature: ______"
                kind = .right
            } else if h.minY - 60 <= l.y && l.y <= h.minY + 1 && l.x0 - 4 <= h.midX && h.midX <= l.x1 + 4 {
                sc = 6 - Double(h.minY - l.y) / 15         // a line above the label: "______ / Signature"
                kind = .above
            } else {
                continue
            }
            if wid > 0.75 * pageW { sc -= 4 }              // page-wide rules are table borders, not signature lines
            if best == nil || sc > best!.score { best = (l, kind, sc) }
        }
        return best
    }

    private static func makeSpot(_ h: LabelHit, lines: [DetectedLine], raster: PageRaster.Gray?, pageSize: CGSize,
                                 page: Int, isLast: Bool, names: [CGRect]) -> Spot? {
        let kind: SpotKind
        switch h.kind {
        case .signature: kind = .signature
        case .initials: kind = .initials
        case .date: kind = .date
        case .name: return nil
        }

        let assoc = associate(h.rect, lines, pageW: pageSize.width)
        if h.words > 8 && assoc == nil { return nil }       // a long sentence with no line nearby is just body text

        var score = h.weight
        var x: CGFloat
        var baseline: CGFloat
        var width: CGFloat
        var hasLine = false
        var reason: String

        if let a = assoc {
            score += a.score
            x = a.line.x0
            baseline = a.line.y
            width = a.line.x1 - a.line.x0
            hasLine = true
            reason = a.kind == .right ? "Line after the label" : "Line above the label"
        } else {
            score -= 2
            let margin: CGFloat = 40
            if h.rect.maxX + 120 < pageSize.width - margin {
                x = h.rect.maxX + 8
                baseline = h.rect.maxY
            } else {
                x = h.rect.minX
                baseline = h.rect.maxY + 46
            }
            width = min(220, pageSize.width - margin - x)
            reason = "Next to the label (no line found)"
        }

        if isLast { score += 1.5 }
        score += Double(baseline / max(pageSize.height, 1))
        if kind == .signature,
           names.contains(where: { abs($0.midY - h.rect.midY) < 90 && abs($0.midX - h.rect.midX) < 220 }) {
            score += 2
            reason += ", next to your name"
        }

        var crowd = 0.0
        if let r = raster {
            crowd = r.inkDensity(CGRect(x: x + 4, y: baseline - 44, width: min(width, 210), height: 42))
        }
        return Spot(page: page, kind: kind, x: x, baseline: baseline, width: max(width, 60),
                    hasLine: hasLine, score: score, crowd: crowd, reason: reason)
    }

    private static func fallback(page: Int, size: CGSize, lines: [DetectedLine], raster: PageRaster.Gray?) -> Spot {
        let candidates = lines.filter {
            $0.y > size.height * 0.55 && ($0.x1 - $0.x0) >= 80 && ($0.x1 - $0.x0) <= 340
        }
        if let l = candidates.max(by: { ($0.y, $0.x0) < ($1.y, $1.x0) }) {
            let crowd = raster?.inkDensity(CGRect(x: l.x0 + 4, y: l.y - 44, width: min(l.x1 - l.x0, 210), height: 42)) ?? 0
            return Spot(page: page, kind: .signature, x: l.x0, baseline: l.y, width: l.x1 - l.x0, hasLine: true,
                        score: 2, crowd: crowd, reason: "Best guess: a line near the bottom of the last page")
        }
        return Spot(page: page, kind: .signature, x: size.width - 56 - 200, baseline: size.height - 110, width: 200,
                    hasLine: false, score: 0.5, crowd: 0,
                    reason: "No signature line found. Drag it where it belongs")
    }

    private static func dedupe(_ spots: [Spot]) -> [Spot] {
        var kept: [Spot] = []
        for s in spots.sorted(by: { $0.score > $1.score }) {
            let dup = kept.contains {
                $0.page == s.page && $0.kind == s.kind && abs($0.x - s.x) < 40 && abs($0.baseline - s.baseline) < 25
            }
            if !dup { kept.append(s) }
        }
        return kept
    }

    // MARK: For the CLI

    static func describe(_ spots: [Spot]) -> String {
        spots.map {
            String(format: "p%ld %@ score %.1f at x=%.0f baseline=%.0f width=%.0f%@ — %@", $0.page + 1, $0.kind.rawValue,
                   $0.score, Double($0.x), Double($0.baseline), Double($0.width),
                   $0.crowd > 0.04 ? " (crowded)" : "", $0.reason)
        }.joined(separator: "\n")
    }
}
