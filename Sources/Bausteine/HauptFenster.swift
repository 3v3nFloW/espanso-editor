import SwiftUI
import BausteineKern

struct HauptFenster: View {
    @Environment(Store.self) private var store
    @State private var neuerOrdnerZeigen = false
    @State private var neuerOrdnerName = ""
    @State private var umbenennen: String?
    @State private var umbenennenName = ""
    @FocusState private var sucheFokus: Bool

    private var suchHinweis: String {
        switch store.suchbereich {
        case .alles: L("Kürzel oder Text suchen")
        case .kuerzel: L("Kürzel suchen")
        case .text: L("Text suchen")
        }
    }

    var body: some View {
        @Bindable var store = store
        NavigationSplitView {
            Seitenleiste(umbenennen: $umbenennen, umbenennenName: $umbenennenName, neuerOrdner: { neuerOrdnerZeigen = true })
                .navigationSplitViewColumnWidth(min: 210, ideal: 250)
        } detail: {
            VStack(spacing: 0) {
            VSplitView {
                Group {
                    Tabelle()   // eine einzige Tabelle; „Kollisionen“ ist nur ein Filter (eine neu eingeblendete Tabelle rutschte unter die Symbolleiste)
                }
                .frame(maxWidth: .infinity, minHeight: 180, maxHeight: .infinity)
                EditorBereich()
                    .frame(maxWidth: .infinity, minHeight: 220, idealHeight: 320, maxHeight: .infinity)
            }
            // Platz für die Statusleiste: VSplitView beachtet den unteren Sicherheitsrand nicht und lag sonst darunter
            Color.clear.frame(height: Statusleiste.hoehe)
            }
        }
        .searchable(text: $store.suche, placement: .toolbar, prompt: suchHinweis)
        .toolbar {
            ToolbarItemGroup {
                Picker(L("Suchen in"), selection: $store.suchbereich) {
                    ForEach(Suchbereich.allCases, id: \.self) { Text($0.titel).tag($0) }
                }
                .pickerStyle(.segmented)
                .help(L("Suchen in Kürzel und Text, nur in Kürzeln oder nur im Text (Expansion)"))
                Toggle(isOn: $store.ganzesWort) { Label(L("Ganzes Wort"), systemImage: "textformat.abc") }
                    .help(L("Nur als ganzes Wort finden — „hgr“ findet dann nicht „hochgradig“"))
                Toggle(isOn: $store.auchAusgeschaltete) { Label(L("Ausgeschaltete durchsuchen"), systemImage: "eye.slash") }
                    .help(L("Auch ausgeschaltete Ordner (z. B. Autokorrektur) durchsuchen"))
                Button { _ = store.neu() } label: { Label(L("Neuer Baustein"), systemImage: "plus") }
                    .help(L("Neuer Baustein (⌘N)"))
            }
        }
        .safeAreaInset(edge: .bottom, spacing: 0) { Statusleiste() }
        .onReceive(NotificationCenter.default.publisher(for: .neuerOrdner)) { _ in neuerOrdnerZeigen = true }
        .alert(L("Neuer Ordner"), isPresented: $neuerOrdnerZeigen) {
            TextField("Name", text: $neuerOrdnerName)
            Button(L("Anlegen")) { if let id = store.ordnerNeu(neuerOrdnerName) { store.seite = .ordner(id) }; neuerOrdnerName = "" }
            Button(L("Abbrechen"), role: .cancel) { neuerOrdnerName = "" }
        }
        .alert(L("Ordner umbenennen"), isPresented: Binding(get: { umbenennen != nil }, set: { if !$0 { umbenennen = nil } })) {
            TextField("Name", text: $umbenennenName)
            Button(L("Umbenennen")) { if let u = umbenennen { store.ordnerUmbenennen(u, umbenennenName) }; umbenennen = nil }
            Button(L("Abbrechen"), role: .cancel) { umbenennen = nil }
        }
        .alert(L("Hinweis"), isPresented: Binding(get: { store.meldung != nil }, set: { if !$0 { store.meldung = nil } })) {
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
                Label { HStack { Text(L("Alle")).font(.system(size: schrift)); Spacer(); Zahl(store.aktiveBausteine.count) } } icon: { Image(systemName: "tray.full") }
                    .tag(Seitenwahl.alle)
            }
            Section(Sprache.englisch ? "Folders" : "Ordner") {
                ForEach(store.dateien) { d in
                    Label {
                        HStack {
                            Text(d.name).font(.system(size: schrift)).foregroundStyle(d.aktiv ? .primary : .secondary)
                            if d.nurLesen { Image(systemName: "lock").foregroundStyle(.secondary).help(L("Aufbau nicht erkannt — nur lesen")) }
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
                        Button(L("Umbenennen …")) { umbenennenName = d.name; umbenennen = d.id }.disabled(d.nurLesen)
                        if d.ausschaltbar {
                            Button(d.aktiv ? L("Ausschalten") : L("Einschalten")) { store.ordnerSchalten(d.id, an: !d.aktiv) }
                        }
                        Button(L("Neuer Baustein hier")) { _ = store.neu(in: d.id) }.disabled(d.nurLesen)
                        Divider()
                        Button(L("Nach oben")) { store.ordnerVerschieben(d.id, um: -1) }.disabled(!store.ordnerVerschiebbar(d.id, um: -1))
                        Button(L("Nach unten")) { store.ordnerVerschieben(d.id, um: 1) }.disabled(!store.ordnerVerschiebbar(d.id, um: 1))
                        Divider()
                        Button(L("Ordner löschen"), role: .destructive) { store.ordnerLoeschen(d.id) }
                            .disabled(!d.bausteine.isEmpty || !d.ausschaltbar)
                    }
                }
                .onMove { store.ordnerVerschieben(von: $0, nach: $1) }
            }
            Section(L("Prüfen")) {
                Label { HStack { Text(L("Kollisionen")).font(.system(size: schrift)); Spacer(); Zahl(store.kollisionen.count, warnung: !store.kollisionen.isEmpty) } }
                    icon: { Image(systemName: "exclamationmark.triangle") }
                    .tag(Seitenwahl.kollisionen)
                    .help(L("Kürzel ohne Wortgrenze, die mitten in echten Wörtern auslösen"))
                Label { HStack { Text(L("Doppelte Kürzel")).font(.system(size: schrift)); Spacer(); Zahl(store.doppelteKuerzel.count, warnung: !store.doppelteKuerzel.isEmpty) } }
                    icon: { Image(systemName: "square.on.square") }
                    .tag(Seitenwahl.doppelte)
            }
        }
        .font(.system(size: schrift))
        .environment(\.defaultMinListRowHeight, schrift + 12)
        .listStyle(.sidebar)
        .safeAreaInset(edge: .bottom, spacing: 0) {
            VStack(spacing: 0) {
                Button { neuerOrdner() } label: { Label(L("Neuer Ordner"), systemImage: "folder.badge.plus") }
                    .buttonStyle(.borderless).padding(8).frame(maxWidth: .infinity, alignment: .leading)
                    .help(L("Neuer Ordner (⇧⌘N)"))
                // Die Statusleiste läuft über die ganze Fensterbreite und lag sonst über diesem Knopf
                Color.clear.frame(height: Statusleiste.hoehe)
            }
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
        // Zellen lesen nur diese Konstanten, nicht den Store — sonst aktualisiert sich jede Zelle einzeln mitten im
        // Tabellen-Update („reentrant operation in its NSTableView delegate“, Absturz 07.10. 10:45)
        let schrift = store.schrift
        let ordnernamen = Dictionary(uniqueKeysWithValues: store.dateien.map { ($0.id, $0.name) })
        let kollisionsModus = store.seite == .kollisionen
        let kollisionstexte = Dictionary(store.kollisionen.map { ($0.baustein, Kollisionstext.beschreibung($0)) }, uniquingKeysWith: { a, _ in a })
        Table(of: Baustein.self, selection: $store.auswahl, sortOrder: $store.sortierung) {
            TableColumn(L("Kürzel"), value: \.hauptkuerzel, comparator: .localizedStandard) { b in
                HStack(spacing: 4) {
                    Text(b.kuerzel.joined(separator: ", ").isEmpty ? L("(neu)") : b.kuerzel.joined(separator: ", "))
                        .font(.system(size: schrift, design: .monospaced))
                        .foregroundStyle(b.hauptkuerzel.isEmpty ? .secondary : .primary)
                    if b.kuerzel.contains(where: doppelt.contains) { Image(systemName: "square.on.square").foregroundStyle(.orange).help(L("Kürzel kommt mehrfach vor")) }
                    if kollidiert.contains(b.id) { Image(systemName: "exclamationmark.triangle").foregroundStyle(.orange).help(L("Löst mitten in Wörtern aus")) }
                }
            }
            .width(min: 80, ideal: 120)
            TableColumn("Text", value: \.text, comparator: .localizedStandard) { b in
                if kollisionsModus, let k = kollisionstexte[b.id] {
                    Text(k).font(.system(size: schrift)).foregroundStyle(.orange).lineLimit(1).truncationMode(.tail)
                } else {
                Text(b.komplex ? "⚙︎ " + (b.text.isEmpty ? b.roh : b.text) : b.text)
                    .font(.system(size: schrift))
                    .lineLimit(1).truncationMode(.tail)
                    .foregroundStyle(b.komplex ? .secondary : .primary)
                }
            }
            .width(min: 160, ideal: 380)
            TableColumn(L("Ordner"), value: \.ordnerID) { b in
                Text(ordnernamen[b.ordnerID] ?? b.ordnerID).font(.system(size: schrift)).foregroundStyle(.secondary)
            }
            .width(min: 80, ideal: 140)
            TableColumn(L("Wortgrenze"), value: \.wortgrenzeSortierung) { b in
                Image(systemName: b.wortgrenze ? "checkmark" : "minus").foregroundStyle(b.wortgrenze ? .primary : .tertiary)
                    .help(b.wortgrenze ? L("Löst nur als ganzes Wort aus") : L("Löst auch mitten im Wort aus"))
            }
            .width(min: 70, ideal: 80)
            TableColumn(L("Geändert"), value: \.geaendertSortierung) { b in
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
                Menu(L("Verschieben nach")) {
                    ForEach(store.dateien.filter { !$0.nurLesen }) { d in
                        Button(d.name) { store.verschieben(ids, nach: d.id) }
                    }
                }
                Button(L("Wortgrenze an")) { ids.forEach { id in store.aendern(id) { $0.wortgrenze = true } } }
                Button(L("Wortgrenze aus")) { ids.forEach { id in store.aendern(id) { $0.wortgrenze = false } } }
                if ids.contains(where: { id in store.kollision(fuer: id) != nil }) {
                    Button(L("So lassen")) { ids.compactMap { store.kollision(fuer: $0)?.kuerzel }.forEach { store.akzeptieren($0) } }
                }
                Button(L("Duplizieren")) { store.duplizieren(ids) }
                Divider()
                Button(L("Löschen"), role: .destructive) { loeschenFragen(ids) }
            }
        }
        .onDeleteCommand { loeschenFragen(store.auswahl) }
        .overlay {
            if zeilen.isEmpty && kollisionsModus {
                ContentUnavailableView(L("Keine Kollisionen"), systemImage: "checkmark.circle",
                                       description: Text(store.wortschatz.isEmpty && store.schutzwoerter.isEmpty
                                                         ? L("Noch kein Wortschatz und keine Schutzliste — unter Einstellungen › Kollisionen einrichten.") : ""))
            } else if zeilen.isEmpty {
                ContentUnavailableView(store.suche.isEmpty ? L("Keine Bausteine") : L("Nichts gefunden"),
                                       systemImage: store.suche.isEmpty ? "tray" : "magnifyingglass",
                                       description: Text(store.suche.isEmpty ? L("⌘N legt einen neuen an.") : L("Auch ausgeschaltete Ordner durchsuchen? Schalter oben rechts.")))
            }
        }
    }

    private func loeschenFragen(_ ids: Set<UUID>) {
        guard !ids.isEmpty else { return }
        let a = NSAlert()
        a.messageText = ids.count == 1 ? L("„{0}“ löschen?", store.baustein(ids.first!)?.hauptkuerzel ?? "") : L("{0} Bausteine löschen?", ids.count)
        a.informativeText = L("Lässt sich über git zurückholen.")
        a.addButton(withTitle: L("Löschen")); a.addButton(withTitle: L("Abbrechen"))
        a.buttons.first?.hasDestructiveAction = true
        if a.runModal() == .alertFirstButtonReturn { store.loeschen(ids) }
    }
}

extension Baustein {
    var wortgrenzeSortierung: Int { wortgrenze ? 1 : 0 }
    var geaendertSortierung: Date { geaendert ?? .distantPast }
}

// MARK: - Kollisionen

enum Kollisionstext {
    static func beschreibung(_ k: Kollision) -> String {
        var t: [String] = []
        if !k.ausSchutzliste.isEmpty { t.append(L("Schutzliste: {0}", k.ausSchutzliste.joined(separator: ", "))) }
        if !k.woerter.isEmpty { t.append(L("steckt in {0} ({1}× im Wortschatz)", k.woerter.joined(separator: ", "), k.haeufigkeit.formatted())) }
        return t.joined(separator: " · ")
    }
}

extension Notification.Name { static let kuerzelFokus = Notification.Name("kuerzelFokus") }

// MARK: - Statusleiste

struct Statusleiste: View {
    static let hoehe: CGFloat = 28
    @Environment(Store.self) private var store
    private var schrift: Double { store.schrift }

    var body: some View {
        HStack(spacing: 14) {
            Text(L("{0} aktiv · {1} gesamt", store.aktiveBausteine.count.formatted(), store.alleBausteine.count.formatted()))
            if let n = store.espansoAnzahl {
                Label(L("espanso lädt {0}", n.formatted()), systemImage: "bolt.fill").foregroundStyle(.secondary)
            } else if !store.espansoGefunden {
                Label(L("espanso nicht gefunden"), systemImage: "bolt.slash").foregroundStyle(.orange)
            }
            Spacer()
            switch store.verteilstatus {
            case .gesichert: Label(L("gesichert"), systemImage: "checkmark.circle").foregroundStyle(.green)
            case .ausstehend:
                Button { store.jetztVerteilen() } label: { Label(L("noch nicht verteilt"), systemImage: "clock") }
                    .buttonStyle(.borderless).help(L("Wird nach 30 s Ruhe verteilt — jetzt: ⌘S"))
            case .laeuft: Label(L("wird verteilt …"), systemImage: "arrow.triangle.2.circlepath")
            case .fehler(let m):
                Button { store.jetztVerteilen() } label: { Label(L("nicht verteilt"), systemImage: "exclamationmark.triangle") }
                    .buttonStyle(.borderless).foregroundStyle(.orange).help(m)
            case .ohneGit: Label(L("ohne git"), systemImage: "externaldrive").foregroundStyle(.secondary)
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
            .help(L("Schriftgrösse {0} pt — ⌘+ / ⌘− / ⌘0", Int(schrift)))
            .onTapGesture(count: 2) { store.schrift = Schrift.standard }
            Marke()
        }
        .font(.callout)
        .padding(.horizontal, 12)
        .frame(height: Statusleiste.hoehe)
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
        .help(L("Einstellungen"))
    }
}
