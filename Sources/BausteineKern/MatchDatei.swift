import Foundation
import Yams

/// Ein Baustein (ein Eintrag unter `matches:`).
///
/// Unveränderte Einträge behalten ihren Originaltext Zeichen für Zeichen (`quelle`), damit Kommentare,
/// Anführungszeichen und Zeilenumbrüche der Datei erhalten bleiben. Erst wenn ein Eintrag geändert oder
/// verschoben wird, schreibt der Editor ihn neu (`quelle == nil`).
public struct Baustein: Identifiable, Hashable, Sendable {
    public let id: UUID
    /// Dateiname ohne `_`-Präfix, z. B. `ct.yml` — bleibt gleich, wenn der Ordner aus- und eingeschaltet wird.
    public var ordnerID: String
    public var kuerzel: [String]
    public var text: String
    public var wortgrenze: Bool
    /// Weitere Schlüssel, die der Editor nicht als Feld anbietet, aber unverändert mitschreibt (label, propagate_case …).
    public var zusatz: [String: YamlWert]
    /// Einträge mit Variablen, Formularen, Regex usw. werden als YAML-Rohtext bearbeitet.
    public var komplex: Bool
    /// YAML des Eintrags ohne Einrückung und ohne vorangehende Kommentare (nur bei `komplex` massgeblich).
    public var roh: String
    /// Kommentare/Leerzeilen direkt vor dem Eintrag, ohne Einrückung.
    public var vorspann: [String]
    /// Originaltext samt Einrückung, solange der Eintrag unverändert ist.
    public var quelle: String?
    /// Zeilen (0-basiert) in der Datei, für git blame.
    public var zeilen: Range<Int>
    public var geaendert: Date?

    public var hauptkuerzel: String { kuerzel.first ?? "" }

    public init(ordnerID: String, kuerzel: [String], text: String, wortgrenze: Bool) {
        id = UUID(); self.ordnerID = ordnerID; self.kuerzel = kuerzel; self.text = text; self.wortgrenze = wortgrenze
        zusatz = [:]; komplex = false; roh = ""; vorspann = []; quelle = nil; zeilen = 0..<0; geaendert = nil
    }

    init(id: UUID, ordnerID: String, wert: [String: YamlWert], roh: String, vorspann: [String], quelle: String, zeilen: Range<Int>) {
        self.id = id; self.ordnerID = ordnerID; self.roh = roh; self.vorspann = vorspann; self.quelle = quelle; self.zeilen = zeilen
        geaendert = nil
        var k: [String] = []
        if case .text(let t)? = wert["trigger"] { k = [t] }
        if case .liste(let l)? = wert["triggers"] { k = l.compactMap { if case .text(let t) = $0 { return t } else { return nil } } }
        kuerzel = k
        if case .text(let t)? = wert["replace"] { text = t } else { text = "" }
        if case .wahr(let w)? = wert["word"] { wortgrenze = w } else { wortgrenze = false }
        var z = wert
        for s in ["trigger", "triggers", "replace", "word"] { z.removeValue(forKey: s) }
        zusatz = z
        komplex = !Set(z.keys).isSubset(of: Baustein.einfacheZusatzschluessel)
            || k.isEmpty || wert["replace"] == nil
            || { if case .text = wert["replace"]! { return false } else { return true } }()
            || { if let t = wert["triggers"], case .liste(let l) = t { return l.count != k.count } else { return false } }()
    }

    /// Neuer, unabhängiger Eintrag mit denselben Werten (ohne Kommentare der Vorlage).
    public func kopie() -> Baustein {
        var b = Baustein(ordnerID: ordnerID, kuerzel: kuerzel, text: text, wortgrenze: wortgrenze)
        b.zusatz = zusatz; b.komplex = komplex; b.roh = roh; b.geaendert = Date()
        return b
    }

    /// YAML dieses Eintrags (für die Umwandlung in Rohtext).
    public func yaml() throws -> String { try MatchDatei.eintrag(self) }

    /// Schlüssel, die ein Eintrag haben darf und trotzdem im Formular bearbeitet wird.
    public static let einfacheZusatzschluessel: Set<String> = ["label", "propagate_case", "uppercase_style", "left_word", "right_word", "search_terms", "force_clipboard", "paragraph"]

    /// Der Wert, den espanso nach dem Laden sehen soll.
    public var wert: [String: YamlWert] {
        get throws {
            if komplex {
                guard case .liste(let l)? = try? YamlWert.laden(roh), l.count == 1, case .tabelle(let d) = l[0] else {
                    throw KernFehler.rohtextUngueltig(hauptkuerzel)
                }
                return d
            }
            var d = zusatz
            if kuerzel.count == 1 { d["trigger"] = .text(kuerzel[0]) } else { d["triggers"] = .liste(kuerzel.map { .text($0) }) }
            d["replace"] = .text(text)
            if wortgrenze { d["word"] = .wahr(true) }
            return d
        }
    }
}

public enum KernFehler: LocalizedError, Equatable {
    case rohtextUngueltig(String)
    case pruefungFehlgeschlagen(String, String)
    case nichtLesbar(String, String)

    public var errorDescription: String? {
        switch self {
        case .rohtextUngueltig(let k): return "Der YAML-Text von „\(k)“ ist kein gültiger einzelner Eintrag (muss mit „- “ beginnen)."
        case .pruefungFehlgeschlagen(let d, let g): return "\(d): Die neu geschriebene Datei ergäbe nicht dieselben Bausteine — nicht gespeichert. (\(g))"
        case .nichtLesbar(let d, let g): return "\(d) ist kein gültiges espanso-YAML: \(g)"
        }
    }
}

/// Eine YAML-Datei in `match/` = ein Ordner in der Seitenleiste.
public struct MatchDatei: Identifiable, Hashable, Sendable {
    /// Dateiname ohne `_`-Präfix.
    public var id: String
    public var name: String
    public var aktiv: Bool
    /// Alles bis einschliesslich `matches:`.
    public var kopf: [String]
    /// Was nach der Liste folgt (weitere Schlüssel der Datei), unverändert.
    public var fuss: [String]
    public var einrueckung: Int
    public var bausteine: [Baustein]
    /// Datei, deren Aufbau der Editor nicht versteht (z. B. ohne `matches:`) — wird angezeigt, aber nie geschrieben.
    public var nurLesen: Bool
    public var originalText: String

    public var dateiname: String { aktiv ? id : "_" + id }
    /// espanso legt `base.yml` neu an, wenn sie fehlt — darf nicht ausgeschaltet werden.
    public var ausschaltbar: Bool { id != "base.yml" }

    public static func anzeigename(kopf: [String], id: String) -> String {
        for z in kopf {
            for p in ["# Ordner:", "# Typinator Set:"] where z.hasPrefix(p) {
                let n = z.dropFirst(p.count).trimmingCharacters(in: .whitespaces)
                if !n.isEmpty { return n }
            }
        }
        var n = id.hasSuffix(".yml") ? String(id.dropLast(4)) : id
        n = n.replacingOccurrences(of: "_", with: " ").replacingOccurrences(of: "-", with: " ")
        return n.prefix(1).uppercased() + n.dropFirst()
    }

    // MARK: Lesen

    public static func lesen(text: String, dateiname: String) -> MatchDatei {
        let id = dateiname.hasPrefix("_") ? String(dateiname.dropFirst()) : dateiname
        let aktiv = !dateiname.hasPrefix("_")
        let zeilen = text.zeilenMitUmbruch()
        var leer = MatchDatei(id: id, name: anzeigename(kopf: zeilen.map { $0.ohneUmbruch }, id: id), aktiv: aktiv,
                              kopf: zeilen, fuss: [], einrueckung: 0, bausteine: [], nurLesen: true, originalText: text)

        // Massgeblich für die Werte ist das Laden der ganzen Datei; die Aufteilung in Abschnitte liefert nur den Originaltext.
        let gesamt: [YamlWert]
        do {
            guard let w = try YamlWert.laden(text) else { leer.nurLesen = false; return leer }   // leere Datei
            guard case .tabelle(let d) = w else { return leer }
            guard let m = d["matches"] else { return leer }
            guard case .liste(let l) = m else {
                if case .nichts = m { gesamt = [] } else { return leer }
                return lesenOhneEintraege(leer, zeilen: zeilen)
            }
            gesamt = l
        } catch {
            return leer
        }

        guard let mi = zeilen.firstIndex(where: { $0.ohneUmbruch.trimmingCharacters(in: .whitespaces) == "matches:" && !$0.hasPrefix(" ") }) else { return leer }
        let kopf = Array(zeilen[...mi])
        let bereich = Array(zeilen[(mi + 1)...])
        guard let erste = bereich.first(where: { $0.ohneUmbruch.trimmingCharacters(in: .whitespaces).hasPrefix("- ") || $0.ohneUmbruch.trimmingCharacters(in: .whitespaces) == "-" }) else {
            return gesamt.isEmpty ? lesenOhneEintraege(leer, zeilen: zeilen) : leer
        }
        let einr = erste.prefix(while: { $0 == " " }).count
        let einzug = String(repeating: " ", count: einr)

        var abschnitte: [(start: Int, zeilen: [String], vorspann: Int)] = []
        var aktuell: (start: Int, zeilen: [String], vorspann: Int)?
        var wartend: [String] = []
        var wartendStart = mi + 1
        var fuss: [String] = []
        var vorErstem: [String] = []
        for (i, z) in bereich.enumerated() {
            let n = mi + 1 + i
            let ohne = z.ohneUmbruch
            let getrimmt = ohne.trimmingCharacters(in: .whitespaces)
            let ein = ohne.prefix(while: { $0 == " " }).count
            if !fuss.isEmpty { fuss.append(z); continue }
            if ohne.hasPrefix(einzug + "- ") || ohne == einzug + "-" {
                if let a = aktuell { abschnitte.append(a) }
                aktuell = (start: wartend.isEmpty ? n : wartendStart, zeilen: wartend + [z], vorspann: wartend.count)
                wartend = []
            } else if getrimmt.isEmpty || (getrimmt.hasPrefix("#") && ein <= einr) {
                if wartend.isEmpty { wartendStart = n }
                wartend.append(z)
            } else if ein < einr || (ein == einr && !getrimmt.hasPrefix("-")) {
                // nächster Schlüssel auf oberster Ebene: Rest der Datei bleibt unangetastet
                fuss = wartend + [z]; wartend = []
            } else if aktuell != nil {
                aktuell!.zeilen += wartend + [z]; wartend = []
            } else {
                vorErstem += wartend + [z]; wartend = []
            }
        }
        if let a = aktuell { abschnitte.append(a) }
        if !vorErstem.isEmpty || abschnitte.count != gesamt.count { return leer }
        fuss = wartend + fuss

        var bausteine: [Baustein] = []
        for (i, a) in abschnitte.enumerated() {
            guard case .tabelle(let wert) = gesamt[i] else { return leer }
            let koerper = a.zeilen[a.vorspann...].map { $0.ohneEinzug(einr) }.joined()
            let vorspann = a.zeilen[..<a.vorspann].map { $0.ohneUmbruch.ohneEinzug(einr) }
            bausteine.append(Baustein(id: UUID(), ordnerID: id, wert: wert, roh: koerper.ohneLetztenUmbruch,
                                      vorspann: vorspann, quelle: a.zeilen.joined(), zeilen: a.start..<(a.start + a.zeilen.count)))
        }
        return MatchDatei(id: id, name: anzeigename(kopf: kopf.map { $0.ohneUmbruch }, id: id), aktiv: aktiv, kopf: kopf, fuss: fuss,
                          einrueckung: einr, bausteine: bausteine, nurLesen: false, originalText: text)
    }

    private static func lesenOhneEintraege(_ leer: MatchDatei, zeilen: [String]) -> MatchDatei {
        guard let mi = zeilen.firstIndex(where: { $0.ohneUmbruch.trimmingCharacters(in: .whitespaces).hasPrefix("matches:") && !$0.hasPrefix(" ") }),
              zeilen[mi].ohneUmbruch.trimmingCharacters(in: .whitespaces) == "matches:" else { return leer }
        var d = leer
        d.kopf = Array(zeilen[...mi]); d.fuss = Array(zeilen[(mi + 1)...]); d.nurLesen = false
        return d
    }

    // MARK: Entfernen

    /// Nimmt Einträge heraus. Kommentare über einem entfernten Eintrag (z. B. Abschnittsköpfe wie
    /// „# ── aus typinator_us_dt_set.yml ──“) bleiben in der Datei: sie gehen an den nächsten Eintrag über,
    /// beim letzten Eintrag ans Dateiende.
    public mutating func entfernen(_ ids: Set<UUID>) -> [Baustein] {
        var weg: [Baustein] = []
        var uebrig: [Baustein] = []
        var mitnehmen: [String] = []
        let einzug = String(repeating: " ", count: einrueckung)
        for var b in bausteine {
            if ids.contains(b.id) {
                if b.vorspann.contains(where: { $0.trimmingCharacters(in: .whitespaces).hasPrefix("#") }) {
                    mitnehmen += b.vorspann
                }
                b.vorspann = []
                weg.append(b)
            } else {
                if !mitnehmen.isEmpty {
                    if let q = b.quelle {
                        b.quelle = mitnehmen.map { ($0.isEmpty ? "" : einzug + $0) + "\n" }.joined() + q
                    }
                    b.vorspann = mitnehmen + b.vorspann
                    mitnehmen = []
                }
                uebrig.append(b)
            }
        }
        if !mitnehmen.isEmpty {
            fuss = mitnehmen.map { ($0.isEmpty ? "" : einzug + $0) + "\n" } + fuss
        }
        bausteine = uebrig
        return weg
    }

    // MARK: Schreiben

    /// Erzeugt den Dateitext und prüft ihn, bevor irgendetwas auf die Platte geht:
    /// die neu gelesene Datei muss genau die erwarteten Bausteine in derselben Reihenfolge ergeben.
    public func dateitext() throws -> String {
        var kopf = self.kopf
        if let letzte = kopf.last, !letzte.hasSuffix("\n") { kopf[kopf.count - 1] = letzte + "\n" }
        var teile = kopf.joined()
        if !kopf.contains(where: { $0.ohneUmbruch.trimmingCharacters(in: .whitespaces) == "matches:" }) {
            teile += "matches:\n"
        }
        let einzug = String(repeating: " ", count: einrueckung)
        var erwartet: [String] = []
        for b in bausteine {
            erwartet.append(try YamlWert.tabelle(b.wert).kanonisch)
            if let q = b.quelle {
                teile += q.hasSuffix("\n") ? q : q + "\n"
            } else {
                for v in b.vorspann { teile += (v.isEmpty ? "" : einzug + v) + "\n" }
                teile += try MatchDatei.eintrag(b).zeilenMitUmbruch().map { $0 == "\n" ? $0 : einzug + $0 }.joined()
            }
        }
        if !fuss.isEmpty {
            if !teile.hasSuffix("\n") { teile += "\n" }
            teile += fuss.joined()
        }
        // Gegenprobe
        let neu = MatchDatei.lesen(text: teile, dateiname: dateiname)
        guard !neu.nurLesen else { throw KernFehler.pruefungFehlgeschlagen(name, "Aufbau nicht mehr lesbar") }
        let ist = try neu.bausteine.map { try YamlWert.tabelle($0.wert).kanonisch }
        guard ist == erwartet else {
            let i = Array(zip(ist, erwartet)).firstIndex(where: { $0 != $1 }) ?? min(ist.count, erwartet.count)
            let k = i < bausteine.count ? bausteine[i].hauptkuerzel : "?"
            throw KernFehler.pruefungFehlgeschlagen(name, "Abweichung bei „\(k)“")
        }
        return teile
    }

    /// YAML eines Eintrags ohne Einrückung, endet mit Zeilenumbruch.
    static func eintrag(_ b: Baustein) throws -> String {
        if b.komplex {
            var r = b.roh.trimmingCharacters(in: .newlines)
            if !r.hasPrefix("-") { throw KernFehler.rohtextUngueltig(b.hauptkuerzel) }
            r += "\n"
            return r
        }
        var s = ""
        if b.kuerzel.count == 1 {
            s += "- trigger: \(YamlWert.skalar(b.kuerzel[0]))\n"
        } else {
            s += "- triggers: [\(b.kuerzel.map(YamlWert.skalar).joined(separator: ", "))]\n"
        }
        s += "  replace:" + YamlWert.textblock(b.text, einzug: 4)
        if b.wortgrenze { s += "  word: true\n" }
        for k in b.zusatz.keys.sorted() {
            s += "  \(k): \(b.zusatz[k]!.flussYaml)\n"
        }
        return s
    }
}

// MARK: - YAML-Werte

/// Schlanker, vergleichbarer YAML-Wert (die Typen, die in espanso-Dateien vorkommen).
public indirect enum YamlWert: Hashable, Sendable {
    case text(String), zahl(String), wahr(Bool), nichts
    case liste([YamlWert])
    case tabelle([String: YamlWert])

    static func laden(_ yaml: String) throws -> YamlWert? {
        guard let n = try Yams.compose(yaml: yaml) else { return nil }
        return YamlWert(n)
    }

    init(_ n: Node) {
        switch n {
        case .scalar(let s):
            if s.style == .plain || s.style == .any {
                if let b = Bool.construct(from: s) { self = .wahr(b); return }
                if NSNull.construct(from: s) != nil { self = .nichts; return }
                if Int.construct(from: s) != nil || Double.construct(from: s) != nil { self = .zahl(s.string); return }
            }
            self = .text(s.string)
        case .sequence(let q): self = .liste(q.map { YamlWert($0) })
        case .mapping(let m):
            var d: [String: YamlWert] = [:]
            for (k, v) in m { d[k.string ?? "\(k)"] = YamlWert(v) }
            self = .tabelle(d)
        case .alias: self = .nichts
        }
    }

    /// Vergleichsform unabhängig von Schlüsselreihenfolge und Schreibweise.
    var kanonisch: String {
        switch self {
        case .text(let s): return "s" + YamlWert.json(s)
        case .zahl(let z): return "n" + z
        case .wahr(let b): return b ? "T" : "F"
        case .nichts: return "~"
        case .liste(let l): return "[" + l.map(\.kanonisch).joined(separator: ",") + "]"
        case .tabelle(let d): return "{" + d.keys.sorted().map { YamlWert.json($0) + ":" + d[$0]!.kanonisch }.joined(separator: ",") + "}"
        }
    }

    static func json(_ s: String) -> String {
        let d = try! JSONSerialization.data(withJSONObject: [s], options: [.fragmentsAllowed])
        return String(decoding: d, as: UTF8.self)
    }

    /// Doppelt gequoteter YAML-String — für jede Zeichenkette eindeutig.
    public static func zitiert(_ s: String) -> String {
        var r = "\""
        for c in s.unicodeScalars {
            switch c {
            case "\"": r += "\\\""
            case "\\": r += "\\\\"
            case "\n": r += "\\n"
            case "\t": r += "\\t"
            case "\r": r += "\\r"
            default:
                if c.value < 0x20 || c.value == 0x7F || c.value == 0x85 || c.value == 0x2028 || c.value == 0x2029 || c.value == 0xFEFF {
                    r += String(format: "\\u%04X", c.value)
                } else { r.unicodeScalars.append(c) }
            }
        }
        return r + "\""
    }

    /// Ohne Anführungszeichen, wo YAML den Text unverändert liest (wie PyYAML schreibt → kleine git-Diffs), sonst gequotet.
    public static func skalar(_ s: String) -> String {
        guard !s.isEmpty, !s.contains("\n"), s.trimmingCharacters(in: .whitespaces) == s,
              !s.contains(","), !s.contains("["), !s.contains("]"), !s.contains("{"), !s.contains("}") else { return zitiert(s) }
        if case .tabelle(let d)? = try? laden("x: " + s), d["x"] == .text(s), d.count == 1 { return s }
        return zitiert(s)
    }

    /// `replace:`-Wert: einzeilig gequotet, mehrzeilig als Block (lesbar in git), sonst gequotet mit \n.
    static func textblock(_ s: String, einzug: Int) -> String {
        guard s.contains("\n") else { return " " + skalar(s) + "\n" }
        let sicher = !s.unicodeScalars.contains { ($0.value < 0x20 && $0 != "\n" && $0 != "\t") || $0 == "\r" || $0.value == 0x85 || $0.value == 0x2028 || $0.value == 0x2029 || $0.value == 0xFEFF || $0.value == 0x7F }
        let zeilen = s.components(separatedBy: "\n")
        // Zeilen nur aus Leerzeichen/Tab würden im Block nicht sicher erhalten
        let nurWeiss = zeilen.contains { !$0.isEmpty && $0.allSatisfy { $0 == " " || $0 == "\t" } }
        var hinten = 0
        for z in zeilen.reversed() { if z.isEmpty { hinten += 1 } else { break } }
        // Mehr als ein Zeilenumbruch am Ende bräuchte „|+“ — der schluckt aber die Leerzeilen vor dem nächsten Eintrag.
        if sicher && !nurWeiss && hinten <= 1 {
            let inhalt = Array(zeilen.dropLast(hinten))
            let chomp = hinten == 0 ? "-" : ""
            let ersteFuehrend = inhalt.first.map { $0.hasPrefix(" ") || $0.hasPrefix("\t") || $0.isEmpty } ?? true
            let indikator = ersteFuehrend ? "2" : ""
            let pad = String(repeating: " ", count: ersteFuehrend ? einzug : einzug)
            var r = " |\(indikator)\(chomp)\n"
            for z in inhalt { r += (z.isEmpty ? "" : pad + z) + "\n" }
            // Gegenprobe des einzelnen Werts, sonst gequotet
            let probe = "x:" + r.split(separator: "\n", omittingEmptySubsequences: false).enumerated()
                .map { $0.offset == 0 ? String($0.element) : (String($0.element).isEmpty ? "" : String(String($0.element).dropFirst(einzug - 2))) }
                .joined(separator: "\n")
            if case .tabelle(let d)? = try? laden(probe), d["x"] == .text(s) { return r }
        }
        return " " + zitiert(s) + "\n"
    }

    /// Kompakte Einzeilen-Darstellung für zusätzliche Schlüssel.
    var flussYaml: String {
        switch self {
        case .text(let s): return YamlWert.zitiert(s)
        case .zahl(let z): return z
        case .wahr(let b): return b ? "true" : "false"
        case .nichts: return "null"
        case .liste(let l): return "[" + l.map(\.flussYaml).joined(separator: ", ") + "]"
        case .tabelle(let d): return "{" + d.keys.sorted().map { YamlWert.zitiert($0) + ": " + d[$0]!.flussYaml }.joined(separator: ", ") + "}"
        }
    }
}

// MARK: - Zeilenhilfen

extension String {
    /// Zeilen samt `\n` (letzte Zeile ggf. ohne).
    func zeilenMitUmbruch() -> [String] {
        var r: [String] = []
        var aktuell = ""
        for c in self {
            aktuell.append(c)
            if c == "\n" || c == "\r\n" { r.append(aktuell); aktuell = "" }
        }
        if !aktuell.isEmpty { r.append(aktuell) }
        return r
    }
    var ohneUmbruch: String {
        var s = self
        while s.hasSuffix("\n") || s.hasSuffix("\r") || s.hasSuffix("\r\n") { s.removeLast() }
        return s
    }
    var ohneLetztenUmbruch: String { hasSuffix("\n") ? String(dropLast()) : self }
    func ohneEinzug(_ n: Int) -> String {
        let fuehrend = prefix(while: { $0 == " " }).count
        return String(dropFirst(Swift.min(n, fuehrend)))
    }
}

public enum Diagnose {
    public static func zeige(_ d: MatchDatei) -> String {
        var t = d.kopf.joined()
        for b in d.bausteine { t += (try? MatchDatei.eintrag(b)) ?? "FEHLER" }
        let erwartet = (try? YamlWert.tabelle(d.bausteine[0].wert).kanonisch) ?? "?"
        let neu = MatchDatei.lesen(text: t, dateiname: "x.yml")
        let ist = neu.bausteine.first.flatMap { try? YamlWert.tabelle($0.wert).kanonisch } ?? "nurLesen=\(neu.nurLesen) n=\(neu.bausteine.count)"
        return "---TEXT---\n\(t)---ERWARTET---\n\(erwartet)\n---IST---\n\(ist)"
    }
}
