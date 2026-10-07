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
        let woerter = wortschatz.filter { $0.key.count > 2 }
        for b in bausteine where !b.wortgrenze {
            for k in b.kuerzel where k.count >= 2 && k.contains(where: \.isLetter) && !akzeptiert.contains(k) {
                let gross = isTrue(b.zusatz["propagate_case"])
                func steckt(_ w: String) -> Bool {
                    w != k && (gross ? w.range(of: k, options: .caseInsensitive) != nil : w.contains(k))
                }
                let s = schutz.filter(steckt)
                let treffer = woerter.filter { steckt($0.key) }.sorted { $0.value > $1.value }
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
