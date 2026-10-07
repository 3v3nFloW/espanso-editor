import SwiftUI
import AppKit
import BausteineKern

struct Einstellungen: View {
    // interner Name aus der Zeit als „Bausteine“ (07.10.26) — so bleibt der dort eingetragene Schlüssel gültig
    static let ltDienst = "Bausteine-Editor LanguageTool"

    var body: some View {
        TabView {
            Allgemein().tabItem { Label(L("Allgemein"), systemImage: "gearshape") }
            Rechtschreibung().tabItem { Label(L("Rechtschreibung"), systemImage: "textformat.abc") }
            KollisionenEinstellungen().tabItem { Label(L("Kollisionen"), systemImage: "exclamationmark.triangle") }
        }
        .frame(width: 560, height: 420)
    }
}

private struct Allgemein: View {
    @Environment(Store.self) private var store
    var body: some View {
        Form {
            LabeledContent(L("espanso-Ordner")) { Text(store.konfigOrdner.path).textSelection(.enabled) }
            LabeledContent(L("Bausteine liegen in")) { Text(store.matchOrdner.resolvingSymlinksInPath().path).textSelection(.enabled) }
            LabeledContent(L("espanso-Programm")) { Text(Espanso.programm ?? L("nicht gefunden")).textSelection(.enabled) }
            LabeledContent("git") { Text(store.repo.map { L("{0} — Änderungen werden nach 30 s Ruhe committet und gepusht", $0.wurzel.path) } ?? L("kein git-Repo — Änderungen werden nur gespeichert")) }
            Text(L("Jede Änderung ist nach ca. 1 s in espanso aktiv. Ausgeschaltete Ordner sind Dateien mit „_“ vorne — espanso lädt sie nicht."))
                .font(.caption).foregroundStyle(.secondary)
        }
        .formStyle(.grouped)
    }
}

private struct Rechtschreibung: View {
    @AppStorage("ltAktiv") private var ltAktiv = false
    @AppStorage("ltBenutzer") private var ltBenutzer = ""
    @AppStorage("ltSprache") private var ltSprache = "auto"
    @State private var schluessel = ""
    @State private var test: String?

    var body: some View {
        Form {
            Section {
                Text(L("macOS prüft immer die Rechtschreibung (rot unterstrichen). Kommas und Grammatik prüft es auf Deutsch nicht — dafür LanguageTool."))
                    .font(.callout).foregroundStyle(.secondary)
            }
            Section("LanguageTool") {
                Toggle(L("LanguageTool verwenden (Text wird an languagetool.org gesendet)"), isOn: $ltAktiv)
                TextField(L("E-Mail (Premium-Konto)"), text: $ltBenutzer)
                SecureField(L("API-Schlüssel"), text: $schluessel)
                    .onSubmit { Schluesselbund.speichern(dienst: Einstellungen.ltDienst, konto: ltBenutzer, geheim: schluessel) }
                Picker(L("Sprache"), selection: $ltSprache) {
                    Text(L("Automatisch (de-CH / en-GB)")).tag("auto")
                    Text(L("Deutsch (Schweiz)")).tag("de-CH")
                    Text(L("Deutsch (Deutschland)")).tag("de-DE")
                    Text(L("Englisch (GB)")).tag("en-GB")
                    Text(L("Englisch (US)")).tag("en-US")
                }
                HStack {
                    Button(L("Speichern & testen")) {
                        Schluesselbund.speichern(dienst: Einstellungen.ltDienst, konto: ltBenutzer, geheim: schluessel)
                        Task {
                            let lt = LanguageTool(benutzer: ltBenutzer, schluessel: schluessel, sprache: Sprache.englisch ? "en-GB" : "de-CH")
                            do {
                                let r = try await lt.pruefen(Sprache.englisch ? "He go to school every days." : "Ich glaube dass er morgen kommt.")
                                test = r.isEmpty ? L("Verbunden, aber nichts gemeldet") : L("OK — {0} Hinweis(e): {1}", r.count, r[0].meldung)
                            } catch { test = error.localizedDescription }
                        }
                    }
                    if let test { Text(test).font(.caption).foregroundStyle(.secondary).lineLimit(2) }
                }
                Text(L("Ohne E-Mail/Schlüssel wird die freie API genutzt (Zeichen- und Abfragegrenzen). Den Premium-Schlüssel gibt es im LanguageTool-Konto unter „Zugangsdaten“."))
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .onAppear {
            if let s = Schluesselbund.lesen(dienst: Einstellungen.ltDienst) {
                schluessel = s.geheim
                if ltBenutzer.isEmpty { ltBenutzer = s.konto }
            }
        }
    }
}

private struct KollisionenEinstellungen: View {
    @Environment(Store.self) private var store
    @State private var schutz = ""
    @AppStorage("wortschatzPfad") private var wortschatzPfad = Store.standardWortschatz.path

    var body: some View {
        Form {
            Section(L("Schutzliste — ein Wort pro Zeile")) {
                TextEditor(text: $schutz)
                    .font(.system(.body, design: .monospaced))
                    .frame(minHeight: 120)
                    .onChange(of: schutz) { _, t in store.schutzlisteSpeichern(t) }
                Text(L("Wörter, in denen kein Kürzel auslösen darf (z. B. VVR, Stadtpark). Liegt in match/_bausteine/ und wird mit den Bausteinen verteilt."))
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section(L("Wortschatz")) {
                LabeledContent(L("Datei")) { Text(wortschatzPfad).lineLimit(1).truncationMode(.middle) }
                LabeledContent(L("Wörter")) { Text(store.wortschatz.count.formatted()) }
                HStack {
                    Button(L("Aus Textdateien aufbauen …")) { aufbauen() }
                    Button(L("Andere Datei wählen …")) {
                        let p = NSOpenPanel(); p.allowedContentTypes = [.plainText]
                        if p.runModal() == .OK, let u = p.url { wortschatzPfad = u.path; store.wortschatzLaden() }
                    }
                }
                Text(L("Wörter, die du wirklich schreibst (z. B. aus alten Berichten). Bleibt lokal, wird nicht verteilt."))
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .onAppear { schutz = (try? String(contentsOf: store.schutzlisteURL, encoding: .utf8)) ?? "" }
    }

    func aufbauen() {
        let p = NSOpenPanel()
        p.canChooseDirectories = true; p.allowsMultipleSelection = true
        p.message = L("Textdateien oder Ordner mit Berichten wählen (txt, md, csv, jsonl)")
        guard p.runModal() == .OK else { return }
        var dateien: [URL] = []
        for u in p.urls {
            var verz: ObjCBool = false
            if FileManager.default.fileExists(atPath: u.path, isDirectory: &verz), verz.boolValue {
                let e = FileManager.default.enumerator(at: u, includingPropertiesForKeys: nil)
                while let f = e?.nextObject() as? URL {
                    if ["txt", "md", "csv", "jsonl", "json"].contains(f.pathExtension.lowercased()) { dateien.append(f) }
                }
            } else { dateien.append(u) }
        }
        let ziel = Store.standardWortschatz
        Task {
            let d = await Task.detached { Wortschatz.aufbauen(aus: dateien) }.value
            try? Wortschatz.speichern(d, nach: ziel)
            wortschatzPfad = ziel.path
            store.wortschatzLaden()
        }
    }
}
