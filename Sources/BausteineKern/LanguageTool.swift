import Foundation
import Security

public struct LTTreffer: Identifiable, Hashable, Sendable {
    public enum Art: Sendable { case rechtschreibung, grammatik, stil }
    public let id = UUID()
    /// UTF-16-Offset und -Länge (wie NSString)
    public let bereich: NSRange
    public let meldung: String
    public let regel: String
    public let art: Art
    public let vorschlaege: [String]
}

public enum LTFehler: LocalizedError {
    case http(Int, String)
    public var errorDescription: String? {
        switch self { case .http(let c, let m): return L("LanguageTool antwortet mit {0}: {1}", c, m.prefix(200)) }
    }
}

/// LanguageTool-API. Mit Benutzer + API-Schlüssel → Premium (api.languagetoolplus.com), sonst die freie API.
public struct LanguageTool: Sendable {
    public var benutzer: String
    public var schluessel: String
    /// "auto", "de-CH", "de-DE", "en-GB", …
    public var sprache: String

    public init(benutzer: String, schluessel: String, sprache: String) {
        self.benutzer = benutzer; self.schluessel = schluessel; self.sprache = sprache
    }

    var premium: Bool { !benutzer.isEmpty && !schluessel.isEmpty }
    var basis: String { premium ? "https://api.languagetoolplus.com/v2" : "https://api.languagetool.org/v2" }

    public func pruefen(_ text: String) async throws -> [LTTreffer] {
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return [] }
        var felder: [(String, String)] = [("data", Self.annotiert(text)), ("language", sprache), ("level", "picky")]
        if sprache == "auto" { felder.append(("preferredVariants", "de-CH,en-GB")) }
        if premium { felder += [("username", benutzer), ("apiKey", schluessel)] }
        let json = try await post("/check", felder)
        guard let matches = json["matches"] as? [[String: Any]] else { return [] }
        return matches.compactMap { m in
            guard let o = m["offset"] as? Int, let l = m["length"] as? Int else { return nil }
            let regel = m["rule"] as? [String: Any] ?? [:]
            let rid = regel["id"] as? String ?? ""
            let typ = (regel["issueType"] as? String ?? "").lowercased()
            let art: LTTreffer.Art = (typ == "misspelling" || rid.contains("SPELL") || rid.contains("ORTHOGRAPHY")) ? .rechtschreibung
                : (typ == "style" || typ == "locale-violation" || typ == "register") ? .stil : .grammatik
            let v = (m["replacements"] as? [[String: Any]] ?? []).compactMap { $0["value"] as? String }
            return LTTreffer(bereich: NSRange(location: o, length: l), meldung: m["message"] as? String ?? "", regel: rid, art: art, vorschlaege: Array(v.prefix(6)))
        }
    }

    /// Wort ins persönliche LanguageTool-Wörterbuch (nur Premium).
    public func wortAufnehmen(_ wort: String) async throws {
        guard premium else { return }
        _ = try await post("/words/add", [("word", wort), ("username", benutzer), ("apiKey", schluessel)])
    }

    /// espanso-Platzhalter ({{datum}}, $|$) als Markup, damit LT sie überspringt.
    static func annotiert(_ text: String) -> String {
        var teile: [[String: String]] = []
        let ns = text as NSString
        let re = try! NSRegularExpression(pattern: "\\{\\{[^}]*\\}\\}|\\$\\|\\$")
        var pos = 0
        for m in re.matches(in: text, range: NSRange(location: 0, length: ns.length)) {
            if m.range.location > pos { teile.append(["text": ns.substring(with: NSRange(location: pos, length: m.range.location - pos))]) }
            teile.append(["markup": ns.substring(with: m.range)])
            pos = m.range.location + m.range.length
        }
        if pos < ns.length { teile.append(["text": ns.substring(from: pos)]) }
        let d = try! JSONSerialization.data(withJSONObject: ["annotation": teile])
        return String(decoding: d, as: UTF8.self)
    }

    func post(_ pfad: String, _ felder: [(String, String)]) async throws -> [String: Any] {
        var req = URLRequest(url: URL(string: basis + pfad)!)
        req.httpMethod = "POST"
        req.timeoutInterval = 20
        req.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        var erlaubt = CharacterSet.alphanumerics; erlaubt.insert(charactersIn: "-._~")
        req.httpBody = felder.map { "\($0.0)=\($0.1.addingPercentEncoding(withAllowedCharacters: erlaubt) ?? "")" }.joined(separator: "&").data(using: .utf8)
        let (d, antwort) = try await URLSession.shared.data(for: req)
        let code = (antwort as? HTTPURLResponse)?.statusCode ?? 0
        guard code == 200 else { throw LTFehler.http(code, String(decoding: d, as: UTF8.self)) }
        return (try JSONSerialization.jsonObject(with: d) as? [String: Any]) ?? [:]
    }
}

/// Schlüsselbund (generisches Passwort).
public enum Schluesselbund {
    public static func lesen(dienst: String) -> (konto: String, geheim: String)? {
        let q: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: dienst,
                                kSecReturnAttributes as String: true, kSecReturnData as String: true, kSecMatchLimit as String: kSecMatchLimitOne]
        var r: AnyObject?
        guard SecItemCopyMatching(q as CFDictionary, &r) == errSecSuccess, let d = r as? [String: Any],
              let daten = d[kSecValueData as String] as? Data else { return nil }
        return (d[kSecAttrAccount as String] as? String ?? "", String(decoding: daten, as: UTF8.self))
    }

    public static func speichern(dienst: String, konto: String, geheim: String) {
        let q: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: dienst]
        SecItemDelete(q as CFDictionary)
        guard !geheim.isEmpty else { return }
        var neu = q
        neu[kSecAttrAccount as String] = konto
        neu[kSecValueData as String] = Data(geheim.utf8)
        SecItemAdd(neu as CFDictionary, nil)
    }
}
