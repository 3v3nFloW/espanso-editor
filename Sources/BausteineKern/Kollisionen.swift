import Foundation

/// Ein Kürzel ohne Wortgrenze, das in einem Wort steckt, das man wirklich schreibt (z. B. „dt“ in „Stadtpark“).
public struct Kollision: Identifiable, Hashable, Sendable {
    public var id: UUID { baustein }
    public let baustein: UUID
    public let kuerzel: String
    /// Häufigste betroffene Wörter mit Anzahl
    public let woerter: [String]
    public let haeufigkeit: Int
    public let ausSchutzliste: [String]
}

public enum Kollisionspruefung {
    /// Wörter einer Schutzliste: ein Wort pro Zeile, `#` = Kommentar.
    public static func liste(_ text: String) -> [String] {
        text.split(whereSeparator: \.isNewline).map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty && !$0.hasPrefix("#") }
    }

    public static func pruefen(_ bausteine: [Baustein], wortschatz: [String: Int], schutz: [String], akzeptiert: Set<String>) -> [Kollision] {
        var r: [Kollision] = []
        let woerter = wortschatz.filter { $0.key.count > 2 }.map { (key: $0.key, value: $0.value) }
        // Je ein Block für genaue und kleine Schreibweise: ein Suchlauf pro Kürzel statt einer pro Wort und Kürzel
        let wortGenau = Wortblock(woerter.map(\.key)), wortKlein = Wortblock(woerter.map { $0.key.lowercased() })
        let schutzGenau = Wortblock(schutz), schutzKlein = Wortblock(schutz.map { $0.lowercased() })
        for b in bausteine where !b.wortgrenze {
            for k in b.kuerzel where k.count >= 2 && k.contains(where: \.isLetter) && !akzeptiert.contains(k) {
                // „Schreibweise anpassen“ löst auch bei Ggr/GGR aus; „Bds“ als ganzes Wort ist dann gewollt, keine Kollision
                let gross = isTrue(b.zusatz["propagate_case"])
                let suche = gross ? k.lowercased() : k
                let s = (gross ? schutzKlein : schutzGenau).treffer(suche).map { schutz[$0] }
                let treffer = (gross ? wortKlein : wortGenau).treffer(suche).map { woerter[$0] }.sorted { $0.value > $1.value }
                if !s.isEmpty || !treffer.isEmpty {
                    r.append(Kollision(baustein: b.id, kuerzel: k, woerter: treffer.prefix(4).map(\.key),
                                       haeufigkeit: treffer.reduce(0) { $0 + $1.value }, ausSchutzliste: s))
                }
            }
        }
        return r.sorted { ($0.ausSchutzliste.isEmpty ? 0 : 1, $0.haeufigkeit) > ($1.ausSchutzliste.isEmpty ? 0 : 1, $1.haeufigkeit) }
    }

    static func isTrue(_ w: YamlWert?) -> Bool { if case .wahr(true)? = w { return true } else { return false } }
}

/// Wortschatz = Wörter, die man tatsächlich schreibt, mit Häufigkeit. Datei: `wort<TAB>anzahl` je Zeile.
public enum Wortschatz {
    public static func laden(_ url: URL) -> [String: Int] {
        guard let t = try? String(contentsOf: url, encoding: .utf8) else { return [:] }
        var d: [String: Int] = [:]
        for z in t.split(separator: "\n") {
            let p = z.split(separator: "\t")
            if let w = p.first { d[String(w)] = p.count > 1 ? Int(p[1]) ?? 1 : 1 }
        }
        return d
    }

    /// Zählt Wörter in Textdateien (txt, md, csv, jsonl, …).
    public static func aufbauen(aus dateien: [URL]) -> [String: Int] {
        var d: [String: Int] = [:]
        let regex = try! NSRegularExpression(pattern: "[\\p{L}]{3,}")
        for url in dateien {
            guard let t = try? String(contentsOf: url, encoding: .utf8) else { continue }
            let ns = t as NSString
            for m in regex.matches(in: t, range: NSRange(location: 0, length: ns.length)) {
                d[ns.substring(with: m.range), default: 0] += 1
            }
        }
        return d
    }

    public static func speichern(_ d: [String: Int], nach url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try d.sorted { $0.value > $1.value }.map { "\($0.key)\t\($0.value)" }.joined(separator: "\n").write(to: url, atomically: true, encoding: .utf8)
    }
}

/// Wörter als ein UTF-8-Block („\nwort\nwort…\n“): `treffer` findet mit memmem alle Wörter, in denen ein Teil echt steckt.
struct Wortblock {
    private var bytes: [UInt8] = [10]
    private var anfaenge: [Int] = []   // Byte-Position des ersten Zeichens jedes Worts

    init(_ woerter: [String]) {
        for w in woerter { anfaenge.append(bytes.count); bytes += w.utf8; bytes.append(10) }
    }

    /// Indizes der Wörter, die `teil` enthalten, ohne die, die genau `teil` sind.
    func treffer(_ teil: String) -> [Int] {
        let nadel = Array(teil.utf8)
        guard !nadel.isEmpty, !nadel.contains(10) else { return [] }
        var r: [Int] = []
        bytes.withUnsafeBytes { heu in
            nadel.withUnsafeBytes { n in
                var ab = 0
                while ab < heu.count, let p = memmem(heu.baseAddress! + ab, heu.count - ab, n.baseAddress!, n.count) {
                    let pos = heu.baseAddress!.distance(to: UnsafeRawPointer(p))
                    // letztes Wort, das vor dieser Stelle beginnt
                    var lo = 0, hi = anfaenge.count - 1
                    while lo < hi { let m = (lo + hi + 1) / 2; if anfaenge[m] <= pos { lo = m } else { hi = m - 1 } }
                    let ende = lo + 1 < anfaenge.count ? anfaenge[lo + 1] - 1 : heu.count - 1
                    if ende - anfaenge[lo] != nadel.count { r.append(lo) }
                    ab = ende + 1
                }
            }
        }
        return r
    }
}
