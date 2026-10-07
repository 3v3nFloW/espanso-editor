import Foundation

public struct ImportEintrag: Sendable, Hashable {
    public var kuerzel: String
    public var text: String
    public var wortgrenze: Bool
    public var ordner: String?
    public init(kuerzel: String, text: String, wortgrenze: Bool, ordner: String?) {
        self.kuerzel = kuerzel; self.text = text; self.wortgrenze = wortgrenze; self.ordner = ordner
    }
}

public enum ImportFehler: LocalizedError {
    case typinatorNichtErreichbar(String)
    public var errorDescription: String? {
        switch self {
        case .typinatorNichtErreichbar(let m): return L("Typinator liess sich nicht auslesen: {0}", m)
        }
    }
}

public enum Importe {

    // MARK: CSV

    /// RFC 4180; Felder in Anführungszeichen dürfen Trennzeichen, Zeilenumbrüche und "" enthalten.
    public static func csvLesen(_ inhalt: String) -> [ImportEintrag] {
        var s = inhalt
        if s.hasPrefix("\u{FEFF}") { s.removeFirst() }
        let trenner = trennzeichen(s)
        let zeilen = csvZeilen(s, trenner: trenner)
        guard let erste = zeilen.first else { return [] }

        let kKuerzel: Set = ["kürzel", "kuerzel", "trigger", "abbreviation", "abkürzung"]
        let kText: Set = ["text", "replace", "expansion", "ersetzung"]
        let kOrdner: Set = ["ordner", "folder", "set", "gruppe"]
        let kWort: Set = ["wortgrenze", "word", "whole word", "word boundary"]
        let kopf = erste.map { $0.trimmingCharacters(in: .whitespaces).lowercased() }
        let hatKopf = kopf.first.map(kKuerzel.contains) ?? false
        var spalte = (k: 0, t: 1, o: Optional(2), w: Optional(3))
        if hatKopf {
            spalte.k = kopf.firstIndex(where: kKuerzel.contains) ?? 0
            spalte.t = kopf.firstIndex(where: kText.contains) ?? 1
            spalte.o = kopf.firstIndex(where: kOrdner.contains)
            spalte.w = kopf.firstIndex(where: kWort.contains)
        }
        func feld(_ z: [String], _ i: Int?) -> String? { i.flatMap { $0 < z.count ? z[$0] : nil } }

        return zeilen.dropFirst(hatKopf ? 1 : 0).compactMap { z in
            guard let k = feld(z, spalte.k)?.trimmingCharacters(in: .whitespaces), !k.isEmpty,
                  let t = feld(z, spalte.t), !t.isEmpty else { return nil }
            let o = feld(z, spalte.o)?.trimmingCharacters(in: .whitespaces)
            let w = feld(z, spalte.w)?.trimmingCharacters(in: .whitespaces).lowercased() ?? ""
            return ImportEintrag(kuerzel: k, text: t.replacingOccurrences(of: "\r\n", with: "\n"),
                                 wortgrenze: ["ja", "true", "1", "yes", "x"].contains(w), ordner: (o?.isEmpty ?? true) ? nil : o)
        }
    }

    public static func csvSchreiben(_ eintraege: [ImportEintrag]) -> String {
        func feld(_ s: String) -> String {
            s.contains(where: { $0 == ";" || $0 == "\"" || $0 == "\n" || $0 == "\r" || $0 == "\r\n" })
                ? "\"" + s.replacingOccurrences(of: "\"", with: "\"\"") + "\"" : s
        }
        var r = "\u{FEFF}" + L("Kürzel;Text;Ordner;Wortgrenze") + "\r\n"
        for e in eintraege {
            r += [feld(e.kuerzel), feld(e.text), feld(e.ordner ?? ""), e.wortgrenze ? L("ja") : L("nein")].joined(separator: ";") + "\r\n"
        }
        return r
    }

    /// Häufigstes Trennzeichen der ersten Zeile ausserhalb von Anführungszeichen.
    static func trennzeichen(_ s: String) -> Character {
        var zaehler: [Character: Int] = [";": 0, "\t": 0, ",": 0]
        var inZitat = false
        for c in s {
            if c == "\"" { inZitat.toggle() }
            else if !inZitat && (c == "\n" || c == "\r\n") { break }
            else if !inZitat, zaehler[c] != nil { zaehler[c]! += 1 }
        }
        let best = [";", "\t", ","].max { zaehler[$0]! < zaehler[$1]! }!
        return zaehler[best]! > 0 ? best : ";"
    }

    static func csvZeilen(_ s: String, trenner: Character) -> [[String]] {
        var zeilen: [[String]] = []
        var zeile: [String] = []
        var feld = ""
        var inZitat = false
        var i = s.startIndex
        while i < s.endIndex {
            let c = s[i]
            if inZitat {
                if c == "\"" {
                    let n = s.index(after: i)
                    if n < s.endIndex && s[n] == "\"" { feld.append("\""); i = n } else { inZitat = false }
                } else { feld.append(c) }
            } else if c == "\"" && feld.isEmpty {
                inZitat = true
            } else if c == trenner {
                zeile.append(feld); feld = ""
            } else if c == "\n" || c == "\r\n" || c == "\r" {
                zeile.append(feld); feld = ""
                if !(zeile.count == 1 && zeile[0].isEmpty) { zeilen.append(zeile) }
                zeile = []
            } else {
                feld.append(c)
            }
            i = s.index(after: i)
        }
        if !feld.isEmpty || !zeile.isEmpty { zeile.append(feld); zeilen.append(zeile) }
        return zeilen
    }

    // MARK: Typinator

    /// Liest alle Regeln aller Sets aus der laufenden App Typinator (AppleScript).
    /// Regeln mit Typinator-Funktionen, die espanso nicht kennt, werden übersprungen und gezählt.
    public static func typinatorLesen() throws -> (eintraege: [ImportEintrag], uebersprungen: Int) {
        let skript = """
        tell application "Typinator"
            set f to ASCII character 1
            set ausgabe to {}
            repeat with aSet in every rule set
                set nm to name of aSet
                repeat with aRule in every rule of aSet
                    set end of ausgabe to nm & f & (abbreviation of aRule) & f & (plain expansion of aRule) & f & ((whole word of aRule) as text)
                end repeat
            end repeat
            set AppleScript's text item delimiters to (ASCII character 2)
            set r to ausgabe as text
            set AppleScript's text item delimiters to ""
            return r
        end tell
        """
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        p.arguments = ["-e", skript]
        let aus = Pipe(), err = Pipe()
        p.standardOutput = aus; p.standardError = err
        do { try p.run() } catch { throw ImportFehler.typinatorNichtErreichbar(error.localizedDescription) }
        let daten = aus.fileHandleForReading.readDataToEndOfFile()
        let fehler = err.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        guard p.terminationStatus == 0 else {
            throw ImportFehler.typinatorNichtErreichbar(String(decoding: fehler, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines))
        }
        var r: [ImportEintrag] = []
        var weg = 0
        for satz in String(decoding: daten, as: UTF8.self).components(separatedBy: "\u{02}") {
            let f = satz.components(separatedBy: "\u{01}")
            guard f.count >= 4 else { continue }
            let k = f[1].trimmingCharacters(in: .whitespacesAndNewlines)
            let t = f[2...(f.count - 2)].joined(separator: "\u{01}").replacingOccurrences(of: "\r", with: "\n")
            guard !k.isEmpty, !t.isEmpty else { continue }
            guard let e = typinatorText(t) else { weg += 1; continue }
            r.append(ImportEintrag(kuerzel: k, text: e, wortgrenze: f.last!.trimmingCharacters(in: .whitespacesAndNewlines) == "true", ordner: f[0]))
        }
        return (r, weg)
    }

    /// Typinator-Variablen → espanso; nil, wenn etwas Unübersetzbares übrig bleibt.
    static func typinatorText(_ t: String) -> String? {
        var s = t.replacingOccurrences(of: "{clip}", with: "{{clipboard}}")
            .replacingOccurrences(of: "{^}", with: "$|$")
            .replacingOccurrences(of: "{tab}", with: "\t")
        s = s.replacingOccurrences(of: "{{clipboard}}", with: "\u{0}")
        if s.contains("{/") || s.contains("{{") || s.contains("{?") || s.range(of: #"\{[A-Za-z#]+\}"#, options: .regularExpression) != nil { return nil }
        return s.replacingOccurrences(of: "\u{0}", with: "{{clipboard}}")
    }
}
