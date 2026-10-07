import Foundation
import SwiftUI
import BausteineKern

enum Seitenwahl: Hashable {
    case alle, ordner(String), kollisionen, doppelte
}

enum Verteilstatus: Equatable {
    case gesichert, ausstehend, laeuft, fehler(String), ohneGit
}

@MainActor
@Observable
final class Store {
    // Orte
    private(set) var konfigOrdner: URL = Espanso.konfigOrdner()
    private(set) var matchOrdner: URL = Espanso.konfigOrdner().appendingPathComponent("match")
    private(set) var repo: GitRepo?
    var espansoGefunden: Bool { Espanso.programm != nil }

    // Daten
    private(set) var dateien: [MatchDatei] = []
    var seite: Seitenwahl = .alle
    var suche = ""
    var auchAusgeschaltete = false
    var auswahl: Set<UUID> = []
    var sortierung: [KeyPathComparator<Baustein>] = [KeyPathComparator(\.hauptkuerzel, comparator: .localizedStandard)]

    // Zustand
    private(set) var verteilstatus: Verteilstatus = .gesichert
    private(set) var espansoAnzahl: Int?
    var meldung: String?
    private(set) var schutzwoerter: [String] = []
    private(set) var akzeptiert: Set<String> = []
    private(set) var wortschatz: [String: Int] = [:]
    private(set) var kollisionen: [Kollision] = []

    /// Neue Bausteine ohne Kürzel oder Text: nur im Editor, noch nicht in der Datei.
    private(set) var entwuerfe: Set<UUID> = []
    private var schreibenGeplant: Set<String> = []
    private var schreibAufgabe: Task<Void, Never>?
    private var neustartAufgabe: Task<Void, Never>?
    private var gitAufgabe: Task<Void, Never>?
    private var kollisionsAufgabe: Task<Void, Never>?
    private var aenderungsprotokoll: [String] = []
    /// Unterschied zwischen espansos Zählung und unserer (Pakete, Unterordner …) — muss nach jedem Schreiben gleich bleiben.
    private var espansoVersatz: Int?
    private var bekannteStaende: [String: Date] = [:]
    private var waechter: Timer?

    var editorOrdner: URL { matchOrdner.appendingPathComponent("_bausteine") }
    var schutzlisteURL: URL { editorOrdner.appendingPathComponent("schutzwoerter.txt") }
    var akzeptiertURL: URL { editorOrdner.appendingPathComponent("kollisionen-ok.txt") }

    // MARK: Laden

    func starten() {
        konfigOrdner = Espanso.konfigOrdner()
        matchOrdner = konfigOrdner.appendingPathComponent("match")
        let ordner = matchOrdner
        Task {
            let repo = await Task.detached { GitRepo.finden(ordner) }.value
            self.repo = repo
            self.verteilstatus = repo == nil ? .ohneGit : .gesichert
            if let repo, let f = await Task.detached(operation: { repo.holen() }).value { meldung = "Abgleich beim Start: \(f)" }
            laden()
            await espansoZaehlen(versatzSetzen: true)
            wortschatzLaden()
        }
        waechter = Timer.scheduledTimer(withTimeInterval: 3, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.aufFremdeAenderungenPruefen() }
        }
    }

    func laden() {
        let fm = FileManager.default
        let namen = ((try? fm.contentsOfDirectory(atPath: matchOrdner.path)) ?? []).filter { $0.hasSuffix(".yml") }.sorted()
        let alteAuswahl = auswahl.compactMap { id in baustein(id).map { ($0.ordnerID, $0.hauptkuerzel) } }
        dateien = namen.compactMap { n in
            guard let t = try? String(contentsOf: matchOrdner.appendingPathComponent(n), encoding: .utf8) else { return nil }
            return MatchDatei.lesen(text: t, dateiname: n)
        }
        dateien.sort { a, b in
            if a.aktiv != b.aktiv { return a.aktiv }
            if (a.id == "base.yml") != (b.id == "base.yml") { return b.id == "base.yml" }   // System ans Ende der aktiven
            return a.name.localizedStandardCompare(b.name) == .orderedAscending
        }
        bekannteStaende = staende()
        auswahl = Set(alteAuswahl.compactMap { o, k in dateien.first { $0.id == o }?.bausteine.first { $0.hauptkuerzel == k }?.id })
        schutzwoerter = Kollisionspruefung.liste((try? String(contentsOf: schutzlisteURL, encoding: .utf8)) ?? "")
        akzeptiert = Set(Kollisionspruefung.liste((try? String(contentsOf: akzeptiertURL, encoding: .utf8)) ?? ""))
        kollisionenBerechnen()
        datenNachladen()
    }

    /// Änderungsdaten aus git blame im Hintergrund.
    private func datenNachladen() {
        guard let repo else { return }
        let jobs = dateien.map { ($0.id, matchOrdner.appendingPathComponent($0.dateiname)) }
        Task {
            for (id, url) in jobs {
                let z = await Task.detached { repo.zeilendaten(url) }.value
                guard let di = dateien.firstIndex(where: { $0.id == id }) else { continue }
                for bi in dateien[di].bausteine.indices where dateien[di].bausteine[bi].quelle != nil {
                    dateien[di].bausteine[bi].geaendert = dateien[di].bausteine[bi].zeilen.compactMap { z[$0] }.max()
                }
            }
        }
    }

    private func staende() -> [String: Date] {
        let fm = FileManager.default
        var r: [String: Date] = [:]
        for n in (try? fm.contentsOfDirectory(atPath: matchOrdner.path)) ?? [] where n.hasSuffix(".yml") {
            r[n] = (try? fm.attributesOfItem(atPath: matchOrdner.appendingPathComponent(n).path))?[.modificationDate] as? Date
        }
        return r
    }

    /// :neu, der Abgleich vom Studio oder ein Texteditor haben etwas geändert → neu einlesen (wenn wir nichts offen haben).
    private func aufFremdeAenderungenPruefen() {
        guard schreibenGeplant.isEmpty, schreibAufgabe == nil, entwuerfe.isEmpty else { return }
        if staende() != bekannteStaende { laden() }
    }

    // MARK: Abfragen

    var alleBausteine: [Baustein] { dateien.flatMap(\.bausteine) }
    var aktiveBausteine: [Baustein] { dateien.filter(\.aktiv).flatMap(\.bausteine) }

    func datei(_ id: String) -> MatchDatei? { dateien.first { $0.id == id } }
    func baustein(_ id: UUID) -> Baustein? {
        for d in dateien { if let b = d.bausteine.first(where: { $0.id == id }) { return b } }
        return nil
    }
    func ordnername(_ id: String) -> String { datei(id)?.name ?? id }

    var sichtbar: [Baustein] {
        var l: [Baustein]
        let q = suche.trimmingCharacters(in: .whitespaces)
        switch seite {
        case .alle: l = q.isEmpty || !auchAusgeschaltete ? aktiveBausteine : alleBausteine
        case .ordner(let id):
            // Suche umspannt immer alle Ordner und zeigt den Fundort
            l = q.isEmpty ? (datei(id)?.bausteine ?? []) : (auchAusgeschaltete ? alleBausteine : aktiveBausteine)
        case .kollisionen:
            let ids = Set(kollisionen.map(\.baustein)); l = alleBausteine.filter { ids.contains($0.id) }
        case .doppelte:
            let d = doppelteKuerzel; l = aktiveBausteine.filter { $0.kuerzel.contains(where: d.contains) }
        }
        if !q.isEmpty {
            l = l.filter { b in
                b.kuerzel.contains { $0.range(of: q, options: [.caseInsensitive, .diacriticInsensitive]) != nil }
                    || b.text.range(of: q, options: [.caseInsensitive, .diacriticInsensitive]) != nil
                    || (b.komplex && b.roh.range(of: q, options: [.caseInsensitive, .diacriticInsensitive]) != nil)
            }
        }
        return l.sorted(using: sortierung)
    }

    var doppelteKuerzel: Set<String> {
        var z: [String: Int] = [:]
        for b in aktiveBausteine { for k in Set(b.kuerzel) { z[k, default: 0] += 1 } }
        return Set(z.filter { $0.value > 1 }.keys)
    }

    func anderswo(_ kuerzel: String, ausser id: UUID) -> [Baustein] {
        alleBausteine.filter { $0.id != id && $0.kuerzel.contains(kuerzel) }
    }

    // MARK: Ändern

    private func index(_ id: UUID) -> (Int, Int)? {
        for (di, d) in dateien.enumerated() { if let bi = d.bausteine.firstIndex(where: { $0.id == id }) { return (di, bi) } }
        return nil
    }

    func aendern(_ id: UUID, _ aenderung: (inout Baustein) -> Void) {
        guard let (di, bi) = index(id), !dateien[di].nurLesen else { return }
        var b = dateien[di].bausteine[bi]
        let vorher = b
        aenderung(&b)
        guard b != vorher else { return }
        if entwuerfe.contains(id) && !b.hauptkuerzel.trimmingCharacters(in: .whitespaces).isEmpty && (b.komplex || !b.text.isEmpty) {
            entwuerfe.remove(id)
        }
        b.quelle = nil
        b.geaendert = Date()
        dateien[di].bausteine[bi] = b
        protokoll("geändert: \(b.hauptkuerzel)")
        planeSchreiben([dateien[di].id])
    }

    /// Wandelt einen einfachen Eintrag in Rohtext um (für Variablen etc.).
    func alsRohtext(_ id: UUID) {
        guard let b = baustein(id), !b.komplex, let y = try? b.yaml() else { return }
        aendern(id) { $0.roh = y; $0.komplex = true }
    }

    func neu(in ordnerID: String? = nil) -> UUID? {
        let ziel: String
        if let ordnerID { ziel = ordnerID }
        else if case .ordner(let o) = seite { ziel = o }
        else { ziel = dateien.first { $0.id == "meine-abkuerzungen.yml" }?.id ?? dateien.first(where: { $0.aktiv && !$0.nurLesen })?.id ?? "" }
        guard let di = dateien.firstIndex(where: { $0.id == ziel }), !dateien[di].nurLesen else { return nil }
        var b = Baustein(ordnerID: ziel, kuerzel: [""], text: "", wortgrenze: true)
        b.geaendert = Date()
        dateien[di].bausteine.append(b)
        entwuerfe.insert(b.id)
        suche = ""
        if case .ordner = seite { seite = .ordner(ziel) } else { seite = .alle }
        auswahl = [b.id]
        return b.id
    }

    func duplizieren(_ ids: Set<UUID>) {
        var neue: Set<UUID> = []
        for id in ids {
            guard let (di, bi) = index(id) else { continue }
            var b = dateien[di].bausteine[bi].kopie()
            if !b.komplex { b.kuerzel = b.kuerzel.map { $0 + "2" } }
            dateien[di].bausteine.insert(b, at: bi + 1)
            protokoll("dupliziert: \(b.hauptkuerzel)")
            neue.insert(b.id)
            planeSchreiben([dateien[di].id])
        }
        auswahl = neue
    }

    func loeschen(_ ids: Set<UUID>) {
        var betroffen: Set<String> = []
        for (di, d) in dateien.enumerated() where !d.nurLesen {
            let weg = d.bausteine.filter { ids.contains($0.id) }
            guard !weg.isEmpty else { continue }
            dateien[di].bausteine.removeAll { ids.contains($0.id) }
            weg.forEach { protokoll("gelöscht: \($0.hauptkuerzel)") }
            betroffen.insert(d.id)
        }
        auswahl.subtract(ids)
        entwuerfe.subtract(ids)
        planeSchreiben(betroffen)
    }

    func verschieben(_ ids: Set<UUID>, nach ziel: String) {
        guard let zi = dateien.firstIndex(where: { $0.id == ziel }), !dateien[zi].nurLesen else { return }
        var betroffen: Set<String> = [ziel]
        for di in dateien.indices where di != zi && !dateien[di].nurLesen {
            let weg = dateien[di].bausteine.filter { ids.contains($0.id) }
            guard !weg.isEmpty else { continue }
            dateien[di].bausteine.removeAll { ids.contains($0.id) }
            for var b in weg {
                b.ordnerID = ziel; b.quelle = nil
                dateien[zi].bausteine.append(b)
                protokoll("verschoben: \(b.hauptkuerzel) → \(dateien[zi].name)")
            }
            betroffen.insert(dateien[di].id)
        }
        planeSchreiben(betroffen)
    }

    // MARK: Ordner

    func ordnerNeu(_ name: String) -> String? {
        let n = name.trimmingCharacters(in: .whitespaces)
        guard !n.isEmpty else { return nil }
        var slug = n.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: .init(identifier: "de")).lowercased()
            .replacingOccurrences(of: "ß", with: "ss")
            .replacingOccurrences(of: "[^a-z0-9]+", with: "-", options: .regularExpression)
            .trimmingCharacters(in: CharacterSet(charactersIn: "-"))
        if slug.isEmpty { slug = "ordner" }
        var id = slug + ".yml", i = 2
        while dateien.contains(where: { $0.id == id }) || id == "base.yml" { id = "\(slug)-\(i).yml"; i += 1 }
        let d = MatchDatei.lesen(text: "# Ordner: \(n)\nmatches:\n", dateiname: id)
        dateien.append(d)
        protokoll("neuer Ordner: \(n)")
        planeSchreiben([id])
        return id
    }

    func ordnerUmbenennen(_ id: String, _ name: String) {
        guard let di = dateien.firstIndex(where: { $0.id == id }), !dateien[di].nurLesen, !name.isEmpty else { return }
        var kopf = dateien[di].kopf
        if let i = kopf.firstIndex(where: { $0.hasPrefix("# Ordner:") }) { kopf[i] = "# Ordner: \(name)\n" }
        else { kopf.insert("# Ordner: \(name)\n", at: 0) }
        dateien[di].kopf = kopf
        dateien[di].name = name
        protokoll("Ordner umbenannt: \(name)")
        planeSchreiben([id])
    }

    func ordnerSchalten(_ id: String, an: Bool) {
        guard let di = dateien.firstIndex(where: { $0.id == id }), dateien[di].ausschaltbar, dateien[di].aktiv != an else { return }
        let alt = matchOrdner.appendingPathComponent(dateien[di].dateiname)
        dateien[di].aktiv = an
        let neu = matchOrdner.appendingPathComponent(dateien[di].dateiname)
        do { try FileManager.default.moveItem(at: alt, to: neu) } catch { dateien[di].aktiv = !an; meldung = error.localizedDescription; return }
        protokoll("Ordner \(an ? "eingeschaltet" : "ausgeschaltet"): \(dateien[di].name)")
        bekannteStaende = staende()
        nachDemSchreiben()
    }

    func ordnerLoeschen(_ id: String) {
        guard let di = dateien.firstIndex(where: { $0.id == id }), dateien[di].bausteine.isEmpty, dateien[di].ausschaltbar else { return }
        try? FileManager.default.removeItem(at: matchOrdner.appendingPathComponent(dateien[di].dateiname))
        protokoll("Ordner gelöscht: \(dateien[di].name)")
        dateien.remove(at: di)
        if seite == .ordner(id) { seite = .alle }
        bekannteStaende = staende()
        nachDemSchreiben()
    }

    // MARK: Schutzliste / Kollisionen

    func schutzlisteSpeichern(_ text: String) {
        try? FileManager.default.createDirectory(at: editorOrdner, withIntermediateDirectories: true)
        try? text.write(to: schutzlisteURL, atomically: true, encoding: .utf8)
        schutzwoerter = Kollisionspruefung.liste(text)
        protokoll("Schutzliste")
        kollisionenBerechnen()
        gitPlanen()
    }

    func akzeptieren(_ kuerzel: String) {
        akzeptiert.insert(kuerzel)
        try? FileManager.default.createDirectory(at: editorOrdner, withIntermediateDirectories: true)
        let t = "# Kürzel ohne Wortgrenze, die bewusst so bleiben (Espanso Editor)\n" + akzeptiert.sorted().joined(separator: "\n") + "\n"
        try? t.write(to: akzeptiertURL, atomically: true, encoding: .utf8)
        protokoll("Kollision akzeptiert: \(kuerzel)")
        kollisionenBerechnen()
        gitPlanen()
    }

    func wortschatzLaden() {
        let pfad = UserDefaults.standard.string(forKey: "wortschatzPfad") ?? Store.standardWortschatz.path
        let url = URL(fileURLWithPath: pfad)
        Task {
            wortschatz = await Task.detached { Wortschatz.laden(url) }.value
            kollisionenBerechnen()
        }
    }

    static var standardWortschatz: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("Espanso Editor/wortschatz.txt")
    }

    func kollisionenBerechnen() {
        kollisionsAufgabe?.cancel()
        let b = aktiveBausteine, w = wortschatz, s = schutzwoerter, a = akzeptiert
        kollisionsAufgabe = Task {
            let r = await Task.detached { Kollisionspruefung.pruefen(b, wortschatz: w, schutz: s, akzeptiert: a) }.value
            if !Task.isCancelled { kollisionen = r }
        }
    }

    func kollision(fuer id: UUID) -> Kollision? { kollisionen.first { $0.baustein == id } }

    // MARK: Speichern → prüfen → espanso → git

    private func protokoll(_ s: String) {
        aenderungsprotokoll.append(s)
        if repo != nil { verteilstatus = .ausstehend }
    }

    private func planeSchreiben(_ ids: Set<String>) {
        schreibenGeplant.formUnion(ids)
        schreibAufgabe?.cancel()
        schreibAufgabe = Task {
            try? await Task.sleep(for: .milliseconds(600))
            guard !Task.isCancelled else { return }
            schreibAufgabe = nil
            await schreiben()
        }
    }

    /// Schreibt alle vorgemerkten Dateien, prüft gegen espanso und nimmt bei Abweichung alles zurück.
    func schreiben() async {
        let ids = schreibenGeplant
        schreibenGeplant = []
        var zurueck: [(URL, String?)] = []
        for id in ids {
            guard var d = datei(id), !d.nurLesen else { continue }
            // Entwürfe (noch ohne Kürzel oder Text) bleiben nur im Editor
            d.bausteine.removeAll { entwuerfe.contains($0.id) }
            let url = matchOrdner.appendingPathComponent(d.dateiname)
            do {
                let text = try d.dateitext()
                let alt = try? String(contentsOf: url, encoding: .utf8)
                if alt == text { continue }
                zurueck.append((url, alt))
                try text.write(to: url, atomically: true, encoding: .utf8)
            } catch {
                meldung = error.localizedDescription
                schreibenGeplant.insert(id)   // bleibt offen, bis der Fehler behoben ist
            }
        }
        bekannteStaende = staende()
        guard !zurueck.isEmpty else { return }
        // Gegenprobe: lädt espanso genauso viele Bausteine wie erwartet?
        if let versatz = espansoVersatz, let n = await Task.detached(operation: { Espanso.anzahlGeladen() }).value {
            let erwartet = gespeicherteAktive + versatz
            if n != erwartet {
                for (url, alt) in zurueck {
                    if let alt { try? alt.write(to: url, atomically: true, encoding: .utf8) } else { try? FileManager.default.removeItem(at: url) }
                }
                meldung = "espanso lädt nach dem Speichern \(n) statt \(erwartet) Bausteine — Änderung zurückgenommen. Bitte den letzten Eintrag prüfen."
                laden()
                return
            }
            espansoAnzahl = n
        }
        nachDemSchreiben()
    }

    /// Aktive Bausteine, wie sie auf der Platte stehen (ohne Entwürfe).
    private var gespeicherteAktive: Int {
        aktiveBausteine.filter { !entwuerfe.contains($0.id) }.count
    }

    private func nachDemSchreiben() {
        kollisionenBerechnen()
        // espanso sieht Änderungen hinter Symlinks nicht selbst → kurz nach der letzten Änderung neu starten (≈0,8 s)
        neustartAufgabe?.cancel()
        neustartAufgabe = Task {
            try? await Task.sleep(for: .seconds(1))
            guard !Task.isCancelled else { return }
            await Task.detached { Espanso.neustarten() }.value
            await espansoZaehlen(versatzSetzen: false)
        }
        gitPlanen()
    }

    func espansoZaehlen(versatzSetzen: Bool) async {
        let n = await Task.detached { Espanso.anzahlGeladen() }.value
        espansoAnzahl = n
        if versatzSetzen, let n { espansoVersatz = n - gespeicherteAktive }
    }

    private func gitPlanen(sofort: Bool = false) {
        guard repo != nil else { return }
        verteilstatus = .ausstehend
        gitAufgabe?.cancel()
        gitAufgabe = Task {
            if !sofort { try? await Task.sleep(for: .seconds(30)) }
            guard !Task.isCancelled else { return }
            await sichern()
        }
    }

    func jetztVerteilen() { gitPlanen(sofort: true) }

    func sichern() async {
        guard let repo else { return }
        if schreibAufgabe != nil || !schreibenGeplant.isEmpty { await schreiben() }
        verteilstatus = .laeuft
        let eintraege = aenderungsprotokoll
        aenderungsprotokoll = []
        var titel = eintraege.prefix(3).joined(separator: ", ")
        if eintraege.count > 3 { titel += " (+\(eintraege.count - 3))" }
        let nachricht = "Espanso Editor: " + (titel.isEmpty ? "Änderungen" : titel)
            + (eintraege.count > 3 ? "\n\n" + eintraege.map { "- " + $0 }.joined(separator: "\n") : "")
        let r = await Task.detached { repo.sichern(nachricht: nachricht) }.value
        verteilstatus = r.ok ? .gesichert : .fehler(r.meldung)
        if !r.ok { aenderungsprotokoll = eintraege + aenderungsprotokoll }
        bekannteStaende = staende()
    }

    /// Beim Beenden: offenes schreiben und verteilen (synchron, damit nichts liegen bleibt).
    func beenden() {
        let semaphore = DispatchSemaphore(value: 0)
        Task.detached { @MainActor in
            await self.schreiben()
            if self.verteilstatus == .ausstehend || self.repo?.hatAenderungen == true { await self.sichern() }
            semaphore.signal()
        }
        _ = semaphore.wait(timeout: .now() + 20)
    }

    // MARK: Import

    func importieren(_ eintraege: [ImportEintrag], zielordner: String?) -> (neu: Int, doppelt: Int) {
        var vorhanden = Set(alleBausteine.flatMap(\.kuerzel))
        var neu = 0, doppelt = 0
        var betroffen: Set<String> = []
        for e in eintraege {
            guard !vorhanden.contains(e.kuerzel) else { doppelt += 1; continue }
            let ordnerName = zielordner == nil ? (e.ordner ?? "Importiert") : nil
            var ziel = zielordner ?? ""
            if let ordnerName {
                ziel = dateien.first { $0.name.caseInsensitiveCompare(ordnerName) == .orderedSame }?.id ?? ordnerNeu(ordnerName) ?? ""
            }
            guard let di = dateien.firstIndex(where: { $0.id == ziel }), !dateien[di].nurLesen else { continue }
            var b = Baustein(ordnerID: ziel, kuerzel: [e.kuerzel], text: e.text, wortgrenze: e.wortgrenze)
            b.geaendert = Date()
            dateien[di].bausteine.append(b)
            vorhanden.insert(e.kuerzel)
            betroffen.insert(ziel)
            neu += 1
        }
        if neu > 0 { protokoll("importiert: \(neu) Bausteine") }
        planeSchreiben(betroffen)
        return (neu, doppelt)
    }

    func yamlImportieren(_ url: URL, zielordner: String?) throws -> (neu: Int, doppelt: Int) {
        let t = try String(contentsOf: url, encoding: .utf8)
        let d = MatchDatei.lesen(text: t, dateiname: url.lastPathComponent)
        guard !d.nurLesen else { throw KernFehler.nichtLesbar(url.lastPathComponent, "Aufbau nicht erkannt") }
        let ziel = zielordner ?? ordnerNeu(d.name) ?? ""
        guard let di = dateien.firstIndex(where: { $0.id == ziel }) else { return (0, 0) }
        var vorhanden = Set(alleBausteine.flatMap(\.kuerzel))
        var neu = 0, doppelt = 0
        for var b in d.bausteine {
            if b.kuerzel.contains(where: vorhanden.contains) { doppelt += 1; continue }
            b = b.kopie(); b.ordnerID = ziel
            dateien[di].bausteine.append(b)
            b.kuerzel.forEach { vorhanden.insert($0) }
            neu += 1
        }
        if neu > 0 { protokoll("importiert: \(neu) aus \(url.lastPathComponent)") }
        planeSchreiben([ziel])
        return (neu, doppelt)
    }
}

