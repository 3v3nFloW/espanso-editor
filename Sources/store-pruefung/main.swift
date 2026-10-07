import Foundation
import BausteineKern

// Spielt die Store-Abläufe gegen eine Testkopie durch: ESPANSO_CONFIG_DIR=<kopie> BAUSTEINE_KEIN_NEUSTART=1
guard let dir = ProcessInfo.processInfo.environment["ESPANSO_CONFIG_DIR"], ProcessInfo.processInfo.environment["BAUSTEINE_KEIN_NEUSTART"] != nil else {
    print("Nur gegen eine Testkopie: ESPANSO_CONFIG_DIR und BAUSTEINE_KEIN_NEUSTART setzen"); exit(2)
}
let match = URL(fileURLWithPath: dir).appendingPathComponent("match")
var fehler = 0
func pruefe(_ ok: Bool, _ s: String) { print((ok ? "  ✓ " : "  ✗ ") + s); if !ok { fehler += 1 } }
func warte(_ s: Double) async { try? await Task.sleep(for: .milliseconds(Int(s * 1000))) }
func datei(_ n: String) -> String { (try? String(contentsOf: match.appendingPathComponent(n), encoding: .utf8)) ?? "" }
func git(_ a: [String]) -> String { Shell.run("/usr/bin/git", ["-C", dir] + a).aus }

Task { @MainActor in
    let s = Store()
    s.starten()
    await warte(4)
    print("Geladen: \(s.dateien.count) Ordner, \(s.aktiveBausteine.count) aktiv, espanso \(s.espansoAnzahl ?? -1)")
    let n0 = s.aktiveBausteine.count
    pruefe(n0 > 0 && s.espansoAnzahl == n0, "\(n0) aktiv, espanso zählt gleich")
    pruefe(s.dateien.allSatisfy { !$0.nurLesen }, "alle Dateien bearbeitbar")

    // 1 Text ändern → nur dieser Eintrag ändert sich in der Datei
    let ggr = s.aktiveBausteine.first { $0.hauptkuerzel == "ggr" }!
    s.aendern(ggr.id) { $0.text = "geringgradig (Test)" }
    await warte(2.5)
    let diff = git(["diff", "--numstat"])
    pruefe(diff.trimmingCharacters(in: .whitespacesAndNewlines) == "1\t1\tmatch/meine-abkuerzungen.yml", "ggr geändert: genau 1 Zeile in 1 Datei (\(diff.trimmingCharacters(in: .whitespacesAndNewlines)))")
    pruefe(s.espansoAnzahl == n0, "espanso weiter \(n0)")

    // 2 Verschieben
    let ctx = s.aktiveBausteine.first { $0.hauptkuerzel == "cbctx" }!
    s.verschieben([ctx.id], nach: "rx.yml")
    await warte(2.5)
    pruefe(datei("rx.yml").contains("cbctx") && !datei("ct.yml").contains("trigger: cbctx"), "cbctx von CT nach Rx verschoben")
    pruefe(s.espansoAnzahl == n0, "espanso weiter \(n0)")

    // 3 Entwurf: erst mit Kürzel + Text in der Datei
    let n = s.neu(in: "meine-abkuerzungen.yml")!
    await warte(1.5)
    pruefe(!datei("meine-abkuerzungen.yml").contains("zzentwurf"), "leerer Entwurf nicht geschrieben")
    s.aendern(n) { $0.kuerzel = ["zzentwurf"] }
    await warte(1.5)
    pruefe(!datei("meine-abkuerzungen.yml").contains("zzentwurf"), "Entwurf nur mit Kürzel noch nicht geschrieben")
    s.aendern(n) { $0.text = "Zeile 1\n  Zeile \"2\"\n" }
    await warte(2.5)
    pruefe(datei("meine-abkuerzungen.yml").contains("zzentwurf"), "Entwurf mit Kürzel + Text geschrieben")
    pruefe(s.espansoAnzahl == n0 + 1, "espanso zählt \(n0 + 1) (\(s.espansoAnzahl ?? -1))")

    // 4 Ungültiger Rohtext → nichts geschrieben, Meldung
    let vorher = datei("meine-abkuerzungen.yml")
    s.alsRohtext(n)
    await warte(1.5)
    s.aendern(n) { $0.roh = "- trigger: \"zzentwurf\"\n  replace: [kaputt" }
    await warte(2.5)
    pruefe(datei("meine-abkuerzungen.yml") == vorher && s.meldung != nil, "kaputtes YAML nicht gespeichert, Meldung: \(s.meldung ?? "-")")
    s.meldung = nil
    s.aendern(n) { $0.roh = "- trigger: \"zzentwurf\"\n  replace: \"{{d}}\"\n  vars:\n    - name: d\n      type: date\n      params:\n        format: \"%Y\"" }
    await warte(2.5)
    pruefe(datei("meine-abkuerzungen.yml").contains("format: \"%Y\"") && s.meldung == nil, "Rohtext mit Variable gespeichert")

    // 5 Ordner neu / aus / ein / löschen
    let o = s.ordnerNeu("Test Ordner")!
    await warte(1.5)
    pruefe(datei(o).hasPrefix("# Ordner: Test Ordner\nmatches:"), "neuer Ordner \(o)")
    let nUS = s.datei("us.yml")?.bausteine.count ?? 0
    s.ordnerSchalten("us.yml", an: false)
    await warte(2.5)
    pruefe(FileManager.default.fileExists(atPath: match.appendingPathComponent("_us.yml").path) && s.espansoAnzahl == n0 + 1 - nUS, "US ausgeschaltet → _us.yml, espanso \(s.espansoAnzahl ?? -1)")
    s.ordnerSchalten("us.yml", an: true)
    s.ordnerLoeschen(o)
    await warte(2.5)
    pruefe(FileManager.default.fileExists(atPath: match.appendingPathComponent("us.yml").path) && !FileManager.default.fileExists(atPath: match.appendingPathComponent(o).path), "US wieder an, Testordner gelöscht")
    s.ordnerSchalten("base.yml", an: false)
    pruefe(s.datei("base.yml")?.aktiv == true, "base.yml lässt sich nicht ausschalten")

    // 6 Schutzliste + Kollisionen
    let k = s.neu(in: "rx.yml")!
    s.aendern(k) { $0.kuerzel = ["tadtp"]; $0.text = "Kollisionstest"; $0.wortgrenze = false }
    await warte(2.5)
    s.schutzlisteSpeichern("# Test\nVVR\nStadtpark\n")
    await warte(1.5)
    pruefe(s.kollisionen.contains { $0.kuerzel == "tadtp" && $0.ausSchutzliste.contains("Stadtpark") }, "Kollision tadtp in Stadtpark (Schutzliste) erkannt")
    s.loeschen([k])
    await warte(2.5)
    pruefe(!s.kollisionen.contains { $0.kuerzel == "dt" }, "dt (mit Wortgrenze) keine Kollision mehr")
    s.akzeptieren("ggr")
    await warte(3)
    print("    akzeptiert:", s.akzeptiert.sorted(), "ggr-Kollisionen:", s.kollisionen.filter { $0.kuerzel == "ggr" }.map { ($0.baustein, $0.woerter) })
    pruefe(!s.kollisionen.contains { $0.kuerzel == "ggr" }, "ggr akzeptiert")

    // 7 Löschen
    s.loeschen([n])
    await warte(2.5)
    pruefe(!datei("meine-abkuerzungen.yml").contains("zzentwurf") && s.espansoAnzahl == n0, "gelöscht, espanso \(n0)")

    // 8 Fremde Änderung (wie :neu) wird übernommen
    try? (datei("rx.yml") + "- trigger: \"zzfremd\"\n  replace: \"von aussen\"\n").write(to: match.appendingPathComponent("rx.yml"), atomically: true, encoding: .utf8)
    await warte(8)
    pruefe(s.aktiveBausteine.contains { $0.hauptkuerzel == "zzfremd" }, "fremde Änderung eingelesen")

    // 9 Verteilen
    s.jetztVerteilen()
    await warte(5)
    let remote = Shell.run("/usr/bin/git", ["-C", dir + "/../gegenstelle.git", "log", "--oneline", "-1"]).aus
    pruefe(s.verteilstatus == .gesichert && remote.contains("Espanso Editor"), "committet + gepusht: \(remote.trimmingCharacters(in: .whitespacesAndNewlines))")
    pruefe(git(["status", "--porcelain"]).isEmpty, "Arbeitskopie sauber")

    // 10 Unveränderte Dateien Byte für Byte gleich
    let unberuehrt = ["diagnosen.yml", "mrt.yml", "_autokorrektur-britisch.yml", "base.yml"]
    let d = git(["diff", "--stat", "HEAD~1", "--"] + unberuehrt.map { "match/" + $0 })
    pruefe(d.isEmpty, "nicht berührte Dateien unverändert")

    print(fehler == 0 ? "OK" : "\(fehler) FEHLER")
    exit(fehler == 0 ? 0 : 1)
}
RunLoop.main.run()
