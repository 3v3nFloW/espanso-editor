import SwiftUI
import AppKit
import BausteineKern

struct Einstellungen: View {
    static let ltDienst = "Bausteine-Editor LanguageTool"

    var body: some View {
        TabView {
            Allgemein().tabItem { Label("Allgemein", systemImage: "gearshape") }
            Rechtschreibung().tabItem { Label("Rechtschreibung", systemImage: "textformat.abc") }
            KollisionenEinstellungen().tabItem { Label("Kollisionen", systemImage: "exclamationmark.triangle") }
        }
        .frame(width: 560, height: 420)
    }
}

private struct Allgemein: View {
    @Environment(Store.self) private var store
    var body: some View {
        Form {
            LabeledContent("espanso-Ordner") { Text(store.konfigOrdner.path).textSelection(.enabled) }
            LabeledContent("Bausteine liegen in") { Text(store.matchOrdner.resolvingSymlinksInPath().path).textSelection(.enabled) }
            LabeledContent("espanso-Programm") { Text(Espanso.programm ?? "nicht gefunden").textSelection(.enabled) }
            LabeledContent("git") { Text(store.repo.map { "\($0.wurzel.path) — Änderungen werden nach 30 s Ruhe committet und gepusht" } ?? "kein git-Repo — Änderungen werden nur gespeichert") }
            Text("Jede Änderung ist nach ca. 1 s in espanso aktiv. Ausgeschaltete Ordner sind Dateien mit „_“ vorne — espanso lädt sie nicht.")
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
                Text("macOS prüft immer die Rechtschreibung (rot unterstrichen). Kommas und Grammatik prüft es auf Deutsch nicht — dafür LanguageTool.")
                    .font(.callout).foregroundStyle(.secondary)
            }
            Section("LanguageTool") {
                Toggle("LanguageTool verwenden (Text wird an languagetool.org gesendet)", isOn: $ltAktiv)
                TextField("E-Mail (Premium-Konto)", text: $ltBenutzer)
                SecureField("API-Schlüssel", text: $schluessel)
                    .onSubmit { Schluesselbund.speichern(dienst: Einstellungen.ltDienst, konto: ltBenutzer, geheim: schluessel) }
                Picker("Sprache", selection: $ltSprache) {
                    Text("Automatisch (de-CH / en-GB)").tag("auto")
                    Text("Deutsch (Schweiz)").tag("de-CH")
                    Text("Deutsch (Deutschland)").tag("de-DE")
                    Text("Englisch (GB)").tag("en-GB")
                    Text("Englisch (US)").tag("en-US")
                }
                HStack {
                    Button("Speichern & testen") {
                        Schluesselbund.speichern(dienst: Einstellungen.ltDienst, konto: ltBenutzer, geheim: schluessel)
                        Task {
                            let lt = LanguageTool(benutzer: ltBenutzer, schluessel: schluessel, sprache: "de-CH")
                            do {
                                let r = try await lt.pruefen("Ich glaube dass er morgen kommt.")
                                test = r.isEmpty ? "Verbunden, aber nichts gemeldet" : "OK — \(r.count) Hinweis(e): \(r[0].meldung)"
                            } catch { test = error.localizedDescription }
                        }
                    }
                    if let test { Text(test).font(.caption).foregroundStyle(.secondary).lineLimit(2) }
                }
                Text("Ohne E-Mail/Schlüssel wird die freie API genutzt (Zeichen- und Abfragegrenzen). Den Premium-Schlüssel gibt es im LanguageTool-Konto unter „Zugangsdaten“.")
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
            Section("Schutzliste — ein Wort pro Zeile") {
                TextEditor(text: $schutz)
                    .font(.system(.body, design: .monospaced))
                    .frame(minHeight: 120)
                    .onChange(of: schutz) { _, t in store.schutzlisteSpeichern(t) }
                Text("Wörter, in denen kein Kürzel auslösen darf (z. B. VVR, Stadtpark). Liegt in match/_bausteine/ und wird mit den Bausteinen verteilt.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("Wortschatz") {
                LabeledContent("Datei") { Text(wortschatzPfad).lineLimit(1).truncationMode(.middle) }
                LabeledContent("Wörter") { Text(store.wortschatz.count.formatted()) }
                HStack {
                    Button("Aus Textdateien aufbauen …") { aufbauen() }
                    Button("Andere Datei wählen …") {
                        let p = NSOpenPanel(); p.allowedContentTypes = [.plainText]
                        if p.runModal() == .OK, let u = p.url { wortschatzPfad = u.path; store.wortschatzLaden() }
                    }
                }
                Text("Wörter, die du wirklich schreibst (z. B. aus alten Berichten). Bleibt lokal, wird nicht verteilt.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .onAppear { schutz = (try? String(contentsOf: store.schutzlisteURL, encoding: .utf8)) ?? "" }
    }

    func aufbauen() {
        let p = NSOpenPanel()
        p.canChooseDirectories = true; p.allowsMultipleSelection = true
        p.message = "Textdateien oder Ordner mit Berichten wählen (txt, md, csv, jsonl)"
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
