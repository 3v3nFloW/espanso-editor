import SwiftUI
import BausteineKern

struct HauptFenster: View {
    @Environment(Store.self) private var store
    @State private var neuerOrdnerZeigen = false
    @State private var neuerOrdnerName = ""
    @State private var umbenennen: String?
    @State private var umbenennenName = ""
    @FocusState private var sucheFokus: Bool

    var body: some View {
        @Bindable var store = store
        NavigationSplitView {
            Seitenleiste(umbenennen: $umbenennen, umbenennenName: $umbenennenName, neuerOrdner: { neuerOrdnerZeigen = true })
                .navigationSplitViewColumnWidth(min: 210, ideal: 250)
        } detail: {
            VSplitView {
                Group {
                    if store.seite == .kollisionen { KollisionsListe() } else { Tabelle() }
                }
                .frame(maxWidth: .infinity, minHeight: 180, maxHeight: .infinity)
                EditorBereich()
                    .frame(maxWidth: .infinity, minHeight: 220, idealHeight: 320, maxHeight: .infinity)
            }
        }
        .searchable(text: $store.suche, placement: .toolbar, prompt: "Kürzel oder Text suchen")
        .toolbar {
            ToolbarItemGroup {
                Toggle(isOn: $store.auchAusgeschaltete) { Label("Ausgeschaltete durchsuchen", systemImage: "eye.slash") }
                    .help("Auch ausgeschaltete Ordner (z. B. Autokorrektur) durchsuchen")
                Button { _ = store.neu() } label: { Label("Neuer Baustein", systemImage: "plus") }
                    .help("Neuer Baustein (⌘N)")
            }
        }
        .safeAreaInset(edge: .bottom, spacing: 0) { Statusleiste() }
        .onReceive(NotificationCenter.default.publisher(for: .neuerOrdner)) { _ in neuerOrdnerZeigen = true }
        .alert("Neuer Ordner", isPresented: $neuerOrdnerZeigen) {
            TextField("Name", text: $neuerOrdnerName)
            Button("Anlegen") { if let id = store.ordnerNeu(neuerOrdnerName) { store.seite = .ordner(id) }; neuerOrdnerName = "" }
            Button("Abbrechen", role: .cancel) { neuerOrdnerName = "" }
        }
        .alert("Ordner umbenennen", isPresented: Binding(get: { umbenennen != nil }, set: { if !$0 { umbenennen = nil } })) {
            TextField("Name", text: $umbenennenName)
            Button("Umbenennen") { if let u = umbenennen { store.ordnerUmbenennen(u, umbenennenName) }; umbenennen = nil }
            Button("Abbrechen", role: .cancel) { umbenennen = nil }
        }
        .alert("Hinweis", isPresented: Binding(get: { store.meldung != nil }, set: { if !$0 { store.meldung = nil } })) {
            Button("OK") { store.meldung = nil }
        } message: { Text(store.meldung ?? "") }
    }
}

// MARK: - Seitenleiste

struct Seitenleiste: View {
    @Environment(Store.self) private var store
    @Binding var umbenennen: String?
    @Binding var umbenennenName: String
    var neuerOrdner: () -> Void
    private var schrift: Double { store.schrift }

    var body: some View {
        @Bindable var store = store
        List(selection: Binding(get: { store.seite }, set: { if let s = $0 { store.seite = s } })) {
            Section {
                Label { HStack { Text("Alle").font(.system(size: schrift)); Spacer(); Zahl(store.aktiveBausteine.count) } } icon: { Image(systemName: "tray.full") }
                    .tag(Seitenwahl.alle)
            }
            Section("Ordner") {
                ForEach(store.dateien) { d in
                    Label {
                        HStack {
                            Text(d.name).font(.system(size: schrift)).foregroundStyle(d.aktiv ? .primary : .secondary)
                            if d.nurLesen { Image(systemName: "lock").foregroundStyle(.secondary).help("Aufbau nicht erkannt — nur lesen") }
                            Spacer()
                            Zahl(d.bausteine.count).opacity(d.aktiv ? 1 : 0.5)
                        }
                    } icon: { Image(systemName: d.aktiv ? "folder" : "folder.badge.minus").foregroundStyle(d.aktiv ? Color.accentColor : .secondary) }
                    .tag(Seitenwahl.ordner(d.id))
                    .dropDestination(for: String.self) { ids, _ in
                        let u = Set(ids.compactMap(UUID.init(uuidString:)))
                        guard !u.isEmpty, !d.nurLesen else { return false }
                        store.verschieben(u, nach: d.id)
                        return true
                    }
                    .contextMenu {
                        Button("Umbenennen …") { umbenennenName = d.name; umbenennen = d.id }.disabled(d.nurLesen)
                        if d.ausschaltbar {
                            Button(d.aktiv ? "Ausschalten" : "Einschalten") { store.ordnerSchalten(d.id, an: !d.aktiv) }
                        }
                        Button("Neuer Baustein hier") { _ = store.neu(in: d.id) }.disabled(d.nurLesen)
                        Divider()
                        Button("Ordner löschen", role: .destructive) { store.ordnerLoeschen(d.id) }
                            .disabled(!d.bausteine.isEmpty || !d.ausschaltbar)
                    }
                }
            }
            Section("Prüfen") {
                Label { HStack { Text("Kollisionen").font(.system(size: schrift)); Spacer(); Zahl(store.kollisionen.count, warnung: !store.kollisionen.isEmpty) } }
                    icon: { Image(systemName: "exclamationmark.triangle") }
                    .tag(Seitenwahl.kollisionen)
                    .help("Kürzel ohne Wortgrenze, die mitten in echten Wörtern auslösen")
                Label { HStack { Text("Doppelte Kürzel").font(.system(size: schrift)); Spacer(); Zahl(store.doppelteKuerzel.count, warnung: !store.doppelteKuerzel.isEmpty) } }
                    icon: { Image(systemName: "square.on.square") }
                    .tag(Seitenwahl.doppelte)
            }
        }
        .font(.system(size: schrift))
        .environment(\.defaultMinListRowHeight, schrift + 12)
        .id(Int(schrift))
        .listStyle(.sidebar)
        .safeAreaInset(edge: .bottom) {
            Button { neuerOrdner() } label: { Label("Neuer Ordner", systemImage: "folder.badge.plus") }
                .buttonStyle(.borderless).padding(8).frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

struct Zahl: View {
    @Environment(Store.self) private var store
    let n: Int
    var warnung = false
    init(_ n: Int, warnung: Bool = false) { self.n = n; self.warnung = warnung }
    var body: some View {
        Text("\(n)").font(.system(size: max(10, store.schrift - 2)).monospacedDigit()).foregroundStyle(warnung ? .orange : .secondary)
    }
}

// MARK: - Tabelle

struct Tabelle: View {
    @Environment(Store.self) private var store
    private var schrift: Double { store.schrift }

    var body: some View {
        @Bindable var store = store
        let zeilen = store.sichtbar
        let doppelt = store.doppelteKuerzel
        let kollidiert = Set(store.kollisionen.map(\.baustein))
        Table(of: Baustein.self, selection: $store.auswahl, sortOrder: $store.sortierung) {
            TableColumn("Kürzel", value: \.hauptkuerzel, comparator: .localizedStandard) { b in
                HStack(spacing: 4) {
                    Text(b.kuerzel.joined(separator: ", ").isEmpty ? "(neu)" : b.kuerzel.joined(separator: ", "))
                        .font(.system(size: schrift, design: .monospaced))
                        .foregroundStyle(b.hauptkuerzel.isEmpty ? .secondary : .primary)
                    if b.kuerzel.contains(where: doppelt.contains) { Image(systemName: "square.on.square").foregroundStyle(.orange).help("Kürzel kommt mehrfach vor") }
                    if kollidiert.contains(b.id) { Image(systemName: "exclamationmark.triangle").foregroundStyle(.orange).help("Löst mitten in Wörtern aus") }
                }
            }
            .width(min: 80, ideal: 120)
            TableColumn("Text", value: \.text, comparator: .localizedStandard) { b in
                Text(b.komplex ? "⚙︎ " + (b.text.isEmpty ? b.roh : b.text) : b.text)
                    .font(.system(size: schrift))
                    .lineLimit(1).truncationMode(.tail)
                    .foregroundStyle(b.komplex ? .secondary : .primary)
            }
            .width(min: 160, ideal: 380)
            TableColumn("Ordner", value: \.ordnerID) { b in
                Text(store.ordnername(b.ordnerID)).font(.system(size: schrift)).foregroundStyle(.secondary)
            }
            .width(min: 80, ideal: 140)
            TableColumn("Wortgrenze", value: \.wortgrenzeSortierung) { b in
                Image(systemName: b.wortgrenze ? "checkmark" : "minus").foregroundStyle(b.wortgrenze ? .primary : .tertiary)
                    .help(b.wortgrenze ? "Löst nur als ganzes Wort aus" : "Löst auch mitten im Wort aus")
            }
            .width(min: 70, ideal: 80)
            TableColumn("Geändert", value: \.geaendertSortierung) { b in
                Text(b.geaendert.map { $0.formatted(date: .numeric, time: .omitted) } ?? "").font(.system(size: schrift)).foregroundStyle(.secondary).monospacedDigit()
            }
            .width(min: 70, ideal: 90)
        } rows: {
            ForEach(zeilen) { b in
                TableRow(b).draggable(b.id.uuidString)
            }
        }
        .contextMenu(forSelectionType: UUID.self) { ids in
            if !ids.isEmpty {
                Menu("Verschieben nach") {
                    ForEach(store.dateien.filter { !$0.nurLesen }) { d in
                        Button(d.name) { store.verschieben(ids, nach: d.id) }
                    }
                }
                Button("Wortgrenze an") { ids.forEach { id in store.aendern(id) { $0.wortgrenze = true } } }
                Button("Wortgrenze aus") { ids.forEach { id in store.aendern(id) { $0.wortgrenze = false } } }
                Button("Duplizieren") { store.duplizieren(ids) }
                Divider()
                Button("Löschen", role: .destructive) { loeschenFragen(ids) }
            }
        }
        .onDeleteCommand { loeschenFragen(store.auswahl) }
        .id(Int(schrift))   // NSTableView behält sonst die alten Zeilenhöhen
        .overlay {
            if zeilen.isEmpty {
                ContentUnavailableView(store.suche.isEmpty ? "Keine Bausteine" : "Nichts gefunden",
                                       systemImage: store.suche.isEmpty ? "tray" : "magnifyingglass",
                                       description: Text(store.suche.isEmpty ? "⌘N legt einen neuen an." : "Auch ausgeschaltete Ordner durchsuchen? Schalter oben rechts."))
            }
        }
    }

    private func loeschenFragen(_ ids: Set<UUID>) {
        guard !ids.isEmpty else { return }
        let a = NSAlert()
        a.messageText = ids.count == 1 ? "„\(store.baustein(ids.first!)?.hauptkuerzel ?? "")“ löschen?" : "\(ids.count) Bausteine löschen?"
        a.informativeText = "Lässt sich über git zurückholen."
        a.addButton(withTitle: "Löschen"); a.addButton(withTitle: "Abbrechen")
        a.buttons.first?.hasDestructiveAction = true
        if a.runModal() == .alertFirstButtonReturn { store.loeschen(ids) }
    }
}

extension Baustein {
    var wortgrenzeSortierung: Int { wortgrenze ? 1 : 0 }
    var geaendertSortierung: Date { geaendert ?? .distantPast }
}

// MARK: - Kollisionen

struct KollisionsListe: View {
    @Environment(Store.self) private var store
    private var schrift: Double { store.schrift }

    var body: some View {
        @Bindable var store = store
        List(selection: $store.auswahl) {
            if store.wortschatz.isEmpty && store.schutzwoerter.isEmpty {
                Text("Noch kein Wortschatz und keine Schutzliste — unter Einstellungen › Kollisionen einrichten.").foregroundStyle(.secondary)
            }
            ForEach(store.kollisionen) { k in
                HStack(alignment: .firstTextBaseline) {
                    VStack(alignment: .leading, spacing: 2) {
                        HStack {
                            Text(k.kuerzel).font(.system(size: schrift, design: .monospaced)).bold()
                            Text("→ " + (store.baustein(k.baustein)?.text.split(separator: "\n").first.map(String.init) ?? "")).lineLimit(1).foregroundStyle(.secondary)
                        }
                        Text(beschreibung(k)).font(.system(size: schrift - 1)).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button("Wortgrenze setzen") { store.aendern(k.baustein) { $0.wortgrenze = true } }
                    Button("Umbenennen") { store.auswahl = [k.baustein]; NotificationCenter.default.post(name: .kuerzelFokus, object: nil) }
                    Button("So lassen") { store.akzeptieren(k.kuerzel) }
                }
                .tag(k.baustein)
                .padding(.vertical, 2)
            }
        }
        .id(Int(schrift))
    }

    func beschreibung(_ k: Kollision) -> String {
        var t: [String] = []
        if !k.ausSchutzliste.isEmpty { t.append("Schutzliste: " + k.ausSchutzliste.joined(separator: ", ")) }
        if !k.woerter.isEmpty { t.append("steckt in " + k.woerter.joined(separator: ", ") + " (\(k.haeufigkeit.formatted())× im Wortschatz)") }
        return t.joined(separator: " · ")
    }
}

extension Notification.Name { static let kuerzelFokus = Notification.Name("kuerzelFokus") }

// MARK: - Statusleiste

struct Statusleiste: View {
    @Environment(Store.self) private var store
    private var schrift: Double { store.schrift }

    var body: some View {
        HStack(spacing: 14) {
            Text("\(store.aktiveBausteine.count.formatted()) aktiv · \(store.alleBausteine.count.formatted()) gesamt")
            if let n = store.espansoAnzahl {
                Label("espanso lädt \(n.formatted())", systemImage: "bolt.fill").foregroundStyle(.secondary)
            } else if !store.espansoGefunden {
                Label("espanso nicht gefunden", systemImage: "bolt.slash").foregroundStyle(.orange)
            }
            Spacer()
            switch store.verteilstatus {
            case .gesichert: Label("gesichert", systemImage: "checkmark.circle").foregroundStyle(.green)
            case .ausstehend:
                Button { store.jetztVerteilen() } label: { Label("noch nicht verteilt", systemImage: "clock") }
                    .buttonStyle(.borderless).help("Wird nach 30 s Ruhe verteilt — jetzt: ⌘S")
            case .laeuft: Label("wird verteilt …", systemImage: "arrow.triangle.2.circlepath")
            case .fehler(let m):
                Button { store.jetztVerteilen() } label: { Label("nicht verteilt", systemImage: "exclamationmark.triangle") }
                    .buttonStyle(.borderless).foregroundStyle(.orange).help(m)
            case .ohneGit: Label("ohne git", systemImage: "externaldrive").foregroundStyle(.secondary)
            }
            HStack(spacing: 4) {
                Button { store.schriftAendern(-1) } label: { Image(systemName: "textformat.size.smaller") }
                    .buttonStyle(.borderless)
                Slider(value: Binding(get: { store.schrift }, set: { store.schrift = $0 }), in: Schrift.bereich, step: 1)
                    .controlSize(.mini)
                    .frame(width: 90)
                Button { store.schriftAendern(+1) } label: { Image(systemName: "textformat.size.larger") }
                    .buttonStyle(.borderless)
            }
            .help("Schriftgrösse \(Int(schrift)) pt — ⌘+ / ⌘− / ⌘0")
            .onTapGesture(count: 2) { store.schrift = Schrift.standard }
            Marke()
        }
        .font(.callout)
        .padding(.horizontal, 12).padding(.vertical, 5)
        .background(.bar)
    }
}

/// Signatur wie in ImagoPilot/ReportPilot: „⚙ Built in Switzerland with ♥ by Kappa1“, Klick öffnet die Einstellungen.
struct Marke: View {
    @State private var hover = false
    var body: some View {
        SettingsLink {
            (Text("⚙\u{00A0}\u{00A0}Built in Switzerland with ") + Text("♥").foregroundColor(Color(red: 0xE0 / 255, green: 0x52 / 255, blue: 0x52 / 255)) + Text(" by ") + Text("K").foregroundColor(Color(red: 0x7E / 255, green: 0xA6 / 255, blue: 0xDC / 255)) + Text("appa1"))
                .font(.caption)
                .foregroundStyle(.secondary)
                .opacity(hover ? 1 : 0.7)
        }
        .buttonStyle(.plain)
        .onHover { hover = $0 }
        .help("Einstellungen")
    }
}
