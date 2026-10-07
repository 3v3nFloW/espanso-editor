import SwiftUI
import AppKit
import BausteineKern

struct EditorBereich: View {
    @Environment(Store.self) private var store

    var body: some View {
        if store.auswahl.count == 1, let id = store.auswahl.first, store.baustein(id) != nil {
            BausteinEditor(id: id).id(id)
        } else {
            ContentUnavailableView(store.auswahl.isEmpty ? "Kein Baustein ausgewählt" : "\(store.auswahl.count) Bausteine ausgewählt",
                                   systemImage: "text.cursor",
                                   description: Text(store.auswahl.isEmpty ? "In der Tabelle wählen oder mit ⌘N neu anlegen."
                                                     : "Mit der Maus auf einen Ordner ziehen oder per Rechtsklick verschieben."))
        }
    }
}

struct BausteinEditor: View {
    @Environment(Store.self) private var store
    let id: UUID
    @State private var kuerzelText = ""
    @State private var treffer: [LTTreffer] = []
    @State private var ignoriert: Set<String> = []
    @State private var ltFehler: String?
    @State private var ltLaeuft = false
    @FocusState private var kuerzelFokus: Bool
    @AppStorage("ltAktiv") private var ltAktiv = false
    @AppStorage("ltBenutzer") private var ltBenutzer = ""
    @AppStorage("ltSprache") private var ltSprache = "auto"
    @AppStorage("schriftgroesse") private var schrift = Schrift.standard

    var b: Baustein? { store.baustein(id) }

    var body: some View {
        if let b {
            VStack(alignment: .leading, spacing: 8) {
                kopfzeile(b)
                hinweise(b)
                if b.komplex {
                    Text("Eintrag mit Variablen/Formular — als YAML bearbeiten (beginnt mit „- trigger:“).").font(.caption).foregroundStyle(.secondary)
                    PruefTextView(text: Binding(get: { b.roh }, set: { neu in store.aendern(id) { $0.roh = neu; $0.kuerzel = Self.kuerzelAusRoh(neu) ?? $0.kuerzel } }),
                                  pruefen: false, monospace: true, schriftgroesse: schrift)
                        .border(Color(nsColor: .separatorColor))
                } else {
                    PruefTextView(text: Binding(get: { b.text }, set: { neu in store.aendern(id) { $0.text = neu } }),
                                  treffer: treffer.filter { !ignoriert.contains(schluessel($0)) },
                                  schriftgroesse: schrift,
                                  onAnwenden: anwenden, onIgnorieren: { ignoriert.insert(schluessel($0)) },
                                  onWoerterbuch: woerterbuch)
                        .border(Color(nsColor: .separatorColor))
                    ltLeiste
                }
            }
            .padding(12)
            .onAppear { kuerzelText = b.kuerzel.joined(separator: ", "); if b.hauptkuerzel.isEmpty { kuerzelFokus = true } }
            .onReceive(NotificationCenter.default.publisher(for: .kuerzelFokus)) { _ in kuerzelFokus = true }
            .task(id: ltAktiv ? b.text : "") { await ltPruefen(b.text) }
        }
    }

    // MARK: Kopf

    @ViewBuilder
    func kopfzeile(_ b: Baustein) -> some View {
        HStack(spacing: 12) {
            TextField("Kürzel", text: $kuerzelText)
                .font(.system(size: schrift + 1, design: .monospaced))
                .controlSize(.large)
                .textFieldStyle(.roundedBorder)
                .frame(maxWidth: 240)
                .focused($kuerzelFokus)
                .disabled(b.komplex)
                .onChange(of: kuerzelText) { _, neu in
                    let k = neu.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
                    store.aendern(id) { $0.kuerzel = k.isEmpty ? [""] : k }
                }
                .help("Mehrere Kürzel mit Komma trennen")
            Picker("Ordner", selection: Binding(get: { b.ordnerID }, set: { store.verschieben([id], nach: $0) })) {
                ForEach(store.dateien.filter { !$0.nurLesen }) { d in Text(d.name + (d.aktiv ? "" : " (aus)")).tag(d.id) }
            }
            .frame(maxWidth: 240)
            if !b.komplex {
                Toggle("Wortgrenze", isOn: Binding(get: { b.wortgrenze }, set: { w in store.aendern(id) { $0.wortgrenze = w } }))
                    .help("An: löst nur als ganzes Wort aus (z. B. „dt“ nicht in „Stadtpark“)")
            }
            Spacer()
            Menu {
                if !b.komplex { Button("Als YAML bearbeiten (Variablen, Formulare …)") { store.alsRohtext(id) } }
                Button("Duplizieren") { store.duplizieren([id]) }
                Divider()
                Button("Löschen", role: .destructive) { store.loeschen([id]) }
            } label: { Image(systemName: "ellipsis.circle") }
            .menuStyle(.borderlessButton).frame(width: 30)
        }
    }

    @ViewBuilder
    func hinweise(_ b: Baustein) -> some View {
        let andere = b.kuerzel.filter { !$0.isEmpty }.flatMap { k in store.anderswo(k, ausser: id).map { (k, $0.ordnerID) } }
        let doppelt = andere.filter { store.datei($0.1)?.aktiv == true }.map { ($0.0, store.ordnername($0.1)) }
        let ruhend = andere.filter { store.datei($0.1)?.aktiv != true }.map { ($0.0, store.ordnername($0.1)) }
        if store.entwuerfe.contains(id) {
            Label("Neu — wird gespeichert, sobald Kürzel und Text ausgefüllt sind.", systemImage: "square.and.pencil").font(.callout).foregroundStyle(.secondary)
        }
        if let (k, o) = doppelt.first {
            Label("„\(k)“ gibt es auch in „\(o)“\(doppelt.count > 1 ? " (+\(doppelt.count - 1))" : "") — espanso nimmt dann einen davon.", systemImage: "square.on.square")
                .font(.callout).foregroundStyle(.orange)
        }
        if doppelt.isEmpty, let (k, o) = ruhend.first {
            Label("„\(k)“ steht auch im ausgeschalteten Ordner „\(o)“ — stört erst, wenn er eingeschaltet wird.", systemImage: "square.on.square")
                .font(.callout).foregroundStyle(.secondary)
        }
        if let k = store.kollision(fuer: id) {
            HStack {
                Label("Löst mitten in Wörtern aus: " + (k.ausSchutzliste + k.woerter).prefix(4).joined(separator: ", "), systemImage: "exclamationmark.triangle")
                    .font(.callout).foregroundStyle(.orange)
                Button("Wortgrenze setzen") { store.aendern(id) { $0.wortgrenze = true } }.controlSize(.small)
                Button("So lassen") { store.akzeptieren(k.kuerzel) }.controlSize(.small)
            }
        }
    }

    // MARK: LanguageTool

    @ViewBuilder
    var ltLeiste: some View {
        let sichtbar = treffer.filter { !ignoriert.contains(schluessel($0)) }
        if ltAktiv {
            HStack(spacing: 8) {
                if ltLaeuft { ProgressView().controlSize(.small) }
                if let ltFehler {
                    Label(ltFehler, systemImage: "wifi.exclamationmark").foregroundStyle(.secondary).lineLimit(1)
                } else if sichtbar.isEmpty && !ltLaeuft {
                    Label("LanguageTool: keine Fehler", systemImage: "checkmark.seal").foregroundStyle(.secondary)
                } else {
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 6) {
                            ForEach(sichtbar) { t in
                                Menu {
                                    Text(t.meldung)
                                    ForEach(t.vorschlaege, id: \.self) { v in Button(v.isEmpty ? "(entfernen)" : v) { anwenden(t, v) } }
                                    if t.art == .rechtschreibung { Button("Ins Wörterbuch") { woerterbuch(wort(t)) } }
                                    Button("Ignorieren") { ignoriert.insert(schluessel(t)) }
                                } label: {
                                    Text(wort(t) + (t.vorschlaege.first.map { " → " + $0 } ?? ""))
                                }
                                .menuStyle(.button).controlSize(.small)
                                .tint(t.art == .rechtschreibung ? .red : (t.art == .grammatik ? .blue : .orange))
                                .help(t.meldung)
                            }
                        }
                    }
                }
            }
            .font(.callout)
            .frame(height: 22)
        } else {
            Text("Rechtschreibung: macOS (Tippfehler). Kommas und Grammatik prüft LanguageTool — in den Einstellungen einschalten.")
                .font(.caption).foregroundStyle(.tertiary)
        }
    }

    func schluessel(_ t: LTTreffer) -> String { t.regel + ":" + wort(t) }
    func wort(_ t: LTTreffer) -> String {
        let ns = (b?.text ?? "") as NSString
        guard t.bereich.location + t.bereich.length <= ns.length else { return "" }
        return ns.substring(with: t.bereich)
    }

    func anwenden(_ t: LTTreffer, _ ersatz: String) {
        guard let text = b?.text else { return }
        let ns = text as NSString
        guard t.bereich.location + t.bereich.length <= ns.length else { return }
        let neu = ns.replacingCharacters(in: t.bereich, with: ersatz)
        treffer = []
        store.aendern(id) { $0.text = neu }
    }

    func woerterbuch(_ w: String) {
        NSSpellChecker.shared.learnWord(w)
        ignoriert.insert("*:" + w)
        treffer.removeAll { wort($0) == w && $0.art == .rechtschreibung }
        let lt = LanguageTool(benutzer: ltBenutzer, schluessel: Schluesselbund.lesen(dienst: Einstellungen.ltDienst)?.geheim ?? "", sprache: ltSprache)
        Task { try? await lt.wortAufnehmen(w) }
    }

    func ltPruefen(_ text: String) async {
        guard ltAktiv else { treffer = []; return }
        try? await Task.sleep(for: .milliseconds(1200))
        guard !Task.isCancelled else { return }
        ltLaeuft = true
        defer { ltLaeuft = false }
        let lt = LanguageTool(benutzer: ltBenutzer, schluessel: Schluesselbund.lesen(dienst: Einstellungen.ltDienst)?.geheim ?? "", sprache: ltSprache)
        do {
            let r = try await lt.pruefen(text)
            guard !Task.isCancelled, b?.text == text else { return }
            treffer = r
            ltFehler = nil
        } catch is CancellationError {
        } catch {
            if (error as? URLError)?.code == .cancelled { return }
            ltFehler = "LanguageTool nicht erreichbar — nur macOS-Prüfung"
        }
    }

    static func kuerzelAusRoh(_ roh: String) -> [String]? {
        for z in roh.split(separator: "\n") {
            let s = z.trimmingCharacters(in: .whitespaces).replacingOccurrences(of: "- ", with: "", options: .anchored)
            if s.hasPrefix("trigger:") {
                return [s.dropFirst(8).trimmingCharacters(in: .whitespaces).trimmingCharacters(in: CharacterSet(charactersIn: "\"'"))]
            }
        }
        return nil
    }
}
