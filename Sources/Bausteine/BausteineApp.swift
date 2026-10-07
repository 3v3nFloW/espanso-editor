import SwiftUI
import AppKit
import UniformTypeIdentifiers
import BausteineKern

@main
struct BausteineApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var delegate
    @State private var store = Store()

    init() {
        // Einstellungen der App aus der Zeit als „Bausteine“ (vet.kappa1.bausteine-editor) einmalig übernehmen
        let d = UserDefaults.standard
        if d.object(forKey: "einstellungenUebernommen") == nil, let alt = UserDefaults(suiteName: "vet.kappa1.bausteine-editor") {
            for k in ["ltAktiv", "ltBenutzer", "ltSprache", "schriftgroesse"] where d.object(forKey: k) == nil {
                if let v = alt.object(forKey: k) { d.set(v, forKey: k) }
            }
            d.set(true, forKey: "einstellungenUebernommen")
        }
    }

    var body: some Scene {
        Window("Espanso Editor", id: "haupt") {
            HauptFenster()
                .environment(store)
                .frame(minWidth: 900, minHeight: 560)
                .onAppear {
                    delegate.store = store
                    store.starten()
                    Schnappschuss.vielleicht(store)
                }
        }
        .defaultSize(width: 1400, height: 860)
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("Neuer Baustein") { _ = store.neu() }.keyboardShortcut("n")
                Button("Neuer Ordner …") { NotificationCenter.default.post(name: .neuerOrdner, object: nil) }
                    .keyboardShortcut("n", modifiers: [.command, .shift])
            }
            CommandGroup(after: .importExport) {
                Menu("Importieren") {
                    Button("CSV …") { ImportExport.csvImport(store) }
                    Button("espanso-YAML …") { ImportExport.yamlImport(store) }
                    Button("Aus Typinator (laufende App)") { ImportExport.typinatorImport(store) }
                }
                Menu("Exportieren") {
                    Button("Sicherung als ZIP (espanso-Format) …") { ImportExport.zipExport(store) }
                    Button("Tabelle als CSV …") { ImportExport.csvExport(store) }
                }
            }
            CommandMenu("Bausteine") {
                Button("Jetzt verteilen") { store.jetztVerteilen() }.keyboardShortcut("s")
                Button("espanso neu starten") { Task.detached { Espanso.neustarten() } }
                Divider()
                Button("Suchen") { NotificationCenter.default.post(name: .sucheFokus, object: nil) }.keyboardShortcut("f")
            }
            CommandGroup(after: .toolbar) {
                Button("Schrift grösser") { store.schriftAendern(+1) }.keyboardShortcut("+")
                Button("Schrift kleiner") { store.schriftAendern(-1) }.keyboardShortcut("-")
                Button("Normale Schriftgrösse") { store.schrift = Schrift.standard }.keyboardShortcut("0")
            }
        }

        Settings {
            Einstellungen().environment(store)
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    var store: Store?
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }

    /// Beenden: erstes Mal absagen, Fenster weg, im Hintergrund speichern + verteilen (höchstens 15 s), dann selbst beenden.
    /// Kein Warten im Hauptthread — ein Semaphore- bzw. terminateLater-Warten hat die App hängen lassen,
    /// weil das Speichern selbst den Hauptthread braucht.
    private var darfBeenden = false

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        MainActor.assumeIsolated {
            guard !darfBeenden, let store, store.hatOffenes else { return .terminateNow }
            for w in sender.windows { w.orderOut(nil) }
            Task { @MainActor in
                await store.beenden()
                self.endgueltig()
            }
            Task { @MainActor in
                try? await Task.sleep(for: .seconds(15))
                self.endgueltig()
            }
            return .terminateCancel
        }
    }

    @MainActor private func endgueltig() {
        guard !darfBeenden else { return }
        darfBeenden = true
        NSApp.terminate(nil)
    }
}

extension Notification.Name {
    static let neuerOrdner = Notification.Name("neuerOrdner")
    static let sucheFokus = Notification.Name("sucheFokus")
}

/// Import/Export über Dateidialoge.
@MainActor
enum ImportExport {
    static func melden(_ titel: String, _ text: String) {
        let a = NSAlert(); a.messageText = titel; a.informativeText = text; a.runModal()
    }

    static func oeffnen(_ typen: [UTType]) -> URL? {
        let p = NSOpenPanel(); p.allowedContentTypes = typen; p.allowsMultipleSelection = false
        return p.runModal() == .OK ? p.url : nil
    }

    /// Zielordner: aus der Datei (Ordner-Spalte / Set-Name) oder der gewählte Ordner.
    static func zielFragen(_ store: Store, _ anzahl: Int, mitDateiordnern: Bool) -> String?? {
        let a = NSAlert()
        a.messageText = "\(anzahl) Bausteine importieren"
        a.informativeText = "Bereits vorhandene Kürzel werden übersprungen."
        let pop = NSPopUpButton(frame: NSRect(x: 0, y: 0, width: 280, height: 26))
        if mitDateiordnern { pop.addItem(withTitle: "Ordner aus der Datei übernehmen") }
        for d in store.dateien where !d.nurLesen { pop.addItem(withTitle: "In „\(d.name)“"); pop.lastItem?.representedObject = d.id }
        if case .ordner(let o) = store.seite, let i = pop.itemArray.firstIndex(where: { $0.representedObject as? String == o }), !mitDateiordnern { pop.selectItem(at: i) }
        a.accessoryView = pop
        a.addButton(withTitle: "Importieren"); a.addButton(withTitle: "Abbrechen")
        guard a.runModal() == .alertFirstButtonReturn else { return .none }
        return .some(pop.selectedItem?.representedObject as? String)
    }

    static func csvImport(_ store: Store) {
        guard let url = oeffnen([.commaSeparatedText, .tabSeparatedText, .plainText]),
              let t = (try? String(contentsOf: url, encoding: .utf8)) ?? (try? String(contentsOf: url, encoding: .isoLatin1)) else { return }
        let e = Importe.csvLesen(t)
        guard !e.isEmpty else { return melden("Nichts gefunden", "Die Datei enthält keine Zeilen mit Kürzel und Text.") }
        guard let ziel = zielFragen(store, e.count, mitDateiordnern: e.contains { $0.ordner != nil }) else { return }
        let r = store.importieren(e, zielordner: ziel)
        melden("Import abgeschlossen", "\(r.neu) neu, \(r.doppelt) übersprungen (Kürzel gab es schon).")
    }

    static func yamlImport(_ store: Store) {
        guard let url = oeffnen([UTType(filenameExtension: "yml")!, UTType(filenameExtension: "yaml")!]) else { return }
        guard let ziel = zielFragen(store, 0, mitDateiordnern: true) else { return }
        do {
            let r = try store.yamlImportieren(url, zielordner: ziel)
            melden("Import abgeschlossen", "\(r.neu) neu, \(r.doppelt) übersprungen (Kürzel gab es schon).")
        } catch { melden("Import fehlgeschlagen", error.localizedDescription) }
    }

    static func typinatorImport(_ store: Store) {
        Task {
            do {
                let r = try await Task.detached { try Importe.typinatorLesen() }.value
                guard let ziel = zielFragen(store, r.eintraege.count, mitDateiordnern: true) else { return }
                let i = store.importieren(r.eintraege, zielordner: ziel)
                melden("Import abgeschlossen", "\(i.neu) neu, \(i.doppelt) übersprungen (Kürzel gab es schon), \(r.uebersprungen) mit Typinator-Funktionen, die espanso nicht kennt.")
            } catch { melden("Typinator", error.localizedDescription) }
        }
    }

    static func speichern(_ name: String, _ typ: UTType) -> URL? {
        let p = NSSavePanel(); p.nameFieldStringValue = name; p.allowedContentTypes = [typ]
        return p.runModal() == .OK ? p.url : nil
    }

    static var datum: String { let f = DateFormatter(); f.dateFormat = "yyyy-MM-dd"; return f.string(from: Date()) }

    static func zipExport(_ store: Store) {
        guard let url = speichern("Bausteine-\(datum).zip", .zip) else { return }
        try? FileManager.default.removeItem(at: url)
        let quelle = store.matchOrdner.resolvingSymlinksInPath()
        let r = Shell.run("/usr/bin/ditto", ["-c", "-k", "--keepParent", quelle.path, url.path])
        if !r.ok { melden("Export fehlgeschlagen", r.fehler) }
    }

    static func csvExport(_ store: Store) {
        guard let url = speichern("Bausteine-\(datum).csv", .commaSeparatedText) else { return }
        let e = store.alleBausteine.map {
            ImportEintrag(kuerzel: $0.kuerzel.joined(separator: ", "), text: $0.komplex ? $0.roh : $0.text, wortgrenze: $0.wortgrenze,
                          ordner: store.ordnername($0.ordnerID) + (store.datei($0.ordnerID)?.aktiv == false ? " (aus)" : ""))
        }
        do { try Importe.csvSchreiben(e).write(to: url, atomically: true, encoding: .utf8) }
        catch { melden("Export fehlgeschlagen", error.localizedDescription) }
    }
}

/// Testhilfe: BAUSTEINE_SCHNAPPSCHUSS=<png> rendert das Fenster unsichtbar in eine Datei und beendet die App.
/// BAUSTEINE_SCHNAPPSCHUSS_KUERZEL=<kürzel> wählt vorher einen Baustein, BAUSTEINE_SCHNAPPSCHUSS_SEITE=kollisionen die Kollisionsliste.
@MainActor
enum Schnappschuss {
    static func vielleicht(_ store: Store) {
        let env = ProcessInfo.processInfo.environment
        if env["BAUSTEINE_BEENDEN_TEST"] != nil {
            // Test: Änderung machen und sofort beenden — muss gespeichert + verteilt sein und darf nicht hängen
            NSApp.setActivationPolicy(.accessory)
            for w in NSApp.windows { w.alphaValue = 0 }
            Task {
                try? await Task.sleep(for: .seconds(4))
                if let b = store.aktiveBausteine.first(where: { $0.hauptkuerzel == "ggr" }) { store.aendern(b.id) { $0.text = "geringgradig (Beenden-Test)" } }
                NSApp.terminate(nil)
            }
            return
        }
        guard let ziel = env["BAUSTEINE_SCHNAPPSCHUSS"] else { return }
        NSApp.setActivationPolicy(.accessory)
        for w in NSApp.windows { w.alphaValue = 0; w.setContentSize(NSSize(width: 1400, height: 860)) }
        Task {
            try? await Task.sleep(for: .seconds(4))
            if env["BAUSTEINE_SCHNAPPSCHUSS_SEITE"] == "kollisionen" { store.seite = .kollisionen }
            if let g = env["BAUSTEINE_SCHNAPPSCHUSS_SCHRIFT"].flatMap(Double.init) { store.schrift = g }
            if let k = env["BAUSTEINE_SCHNAPPSCHUSS_KUERZEL"], let b = store.aktiveBausteine.first(where: { $0.hauptkuerzel == k }) { store.auswahl = [b.id] }
            for w in NSApp.windows where w.frame.width > 500 { w.setFrame(NSRect(x: 0, y: 0, width: 1400, height: 860), display: true) }
            try? await Task.sleep(for: .seconds(2))
            guard let w = NSApp.windows.first(where: { $0.contentView != nil && $0.frame.width > 500 }), let v = w.contentView?.superview ?? w.contentView,
                  let rep = v.bitmapImageRepForCachingDisplay(in: v.bounds) else { exit(3) }
            v.cacheDisplay(in: v.bounds, to: rep)
            try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: ziel))
            exit(0)
        }
    }
}

