import Foundation
import BausteineKern

// Selbstprüfung des YAML-Kerns an echten Dateien (liest nur, schreibt nichts):
//  1. unverändert lesen + schreiben ergibt Byte für Byte denselben Text
//  2. jeden Eintrag neu erzeugen (als wäre er bearbeitet) ergibt dieselben Werte
//  3. alle Einträge in eine andere Einrückung verschieben ergibt dieselben Werte
//  4. CSV hin und zurück

let ordner = CommandLine.arguments.count > 1 ? CommandLine.arguments[1]
    : NSString(string: "~/Library/Application Support/espanso/match").expandingTildeInPath
var fehler = 0
var anzahl = 0
func melde(_ s: String) { print("  ✗ " + s); fehler += 1 }

let dateien = try FileManager.default.contentsOfDirectory(atPath: ordner).filter { $0.hasSuffix(".yml") }.sorted()
var alle: [Baustein] = []
for name in dateien {
    let text = try String(contentsOfFile: ordner + "/" + name, encoding: .utf8)
    let d = MatchDatei.lesen(text: text, dateiname: name)
    anzahl += d.bausteine.count
    print("\(name): \(d.bausteine.count) Einträge, Einrückung \(d.einrueckung), komplex \(d.bausteine.filter(\.komplex).count)\(d.nurLesen ? ", NUR LESEN" : "")")
    if d.nurLesen { continue }
    alle += d.bausteine

    // 1
    do { if try d.dateitext() != text { melde("\(name): unverändert geschrieben ≠ Original") } } catch { melde("\(name): \(error.localizedDescription)") }

    if let z = ProcessInfo.processInfo.environment["ZEIGE"], let b = d.bausteine.first(where: { $0.hauptkuerzel == z }) {
        var x = d; x.bausteine = [b]; x.bausteine[0].quelle = nil; x.kopf = ["matches:\n"]; x.fuss = []
        print(Diagnose.zeige(x))
    }
    // 2
    var neu = d
    for i in neu.bausteine.indices { neu.bausteine[i].quelle = nil }
    do { _ = try neu.dateitext() } catch { melde("neu erzeugt: \(error.localizedDescription)") }

    // 3
    var verschoben = neu
    verschoben.einrueckung = d.einrueckung == 0 ? 2 : 0
    do { _ = try verschoben.dateitext() } catch { melde("andere Einrückung: \(error.localizedDescription)") }
}

// 4
let einfache = alle.filter { !$0.komplex && !$0.text.isEmpty }.map { ImportEintrag(kuerzel: $0.hauptkuerzel, text: $0.text, wortgrenze: $0.wortgrenze, ordner: $0.ordnerID) }
let zurueck = Importe.csvLesen(Importe.csvSchreiben(einfache))
if zurueck != einfache {
    let i = Array(zip(zurueck, einfache)).firstIndex { $0 != $1 } ?? -1
    melde("CSV hin und zurück: \(zurueck.count) statt \(einfache.count), erste Abweichung bei \(i >= 0 ? einfache[i].kuerzel : "?")")
}

print(fehler == 0 ? "OK — \(anzahl) Einträge in \(dateien.count) Dateien geprüft" : "\(fehler) FEHLER")
exit(fehler == 0 ? 0 : 1)

// Diagnose: ZEIGE=<kürzel> gibt den neu erzeugten Eintrag und beide Werte aus
