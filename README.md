# Bausteine — ein Editor für espanso (macOS)

Übersichtliche Oberfläche für die Textbausteine von [espanso](https://espanso.org): Ordner wie in Typinator,
Tabelle mit Suche über alle Ordner, Rechtschreibprüfung (macOS + optional LanguageTool), Kollisionsprüfung
für Kürzel, die mitten in Wörtern auslösen, Import (CSV, espanso-YAML, Typinator) und Export (ZIP, CSV).

- **Ordner = eine YAML-Datei in `match/`.** Anzeigename aus der Kopfzeile `# Ordner: …`. Ausgeschaltet = Datei mit `_` vorne
  (espanso lädt sie nicht). `base.yml` lässt sich nicht ausschalten — espanso legt sie sonst neu an.
- **Kommentare bleiben erhalten.** Nur geänderte Einträge werden neu geschrieben, alles andere bleibt Zeichen für Zeichen.
  Vor jedem Schreiben wird die neue Datei gelesen und mit den erwarteten Bausteinen verglichen; danach muss
  `espanso match list` dieselbe Anzahl liefern, sonst wird die Änderung zurückgenommen.
- **Sofort aktiv:** Speichern ohne Knopf, espanso-Neustart ≈1 s nach der letzten Änderung.
- **git:** Liegen die Bausteine in einem git-Repo, wird nach 30 s Ruhe (oder ⌘S, oder beim Beenden) committet und gepusht.
- **Schutzliste / Kollisionen:** `match/_bausteine/schutzwoerter.txt` (wird mitverteilt) plus ein lokaler Wortschatz
  (`~/Library/Application Support/Bausteine/wortschatz.txt`, `wort<TAB>anzahl`, aus eigenen Texten aufbaubar).

## Bauen

Nur Command Line Tools nötig (kein Xcode):

```sh
./scripts/app-bauen.sh                # → build/Bausteine.app
./scripts/app-bauen.sh --installieren # → /Applications
```

Das macOS-27-SDK der Command Line Tools führt `@State` als Makro ein, dessen Plugin nur Xcode mitbringt —
das Skript baut deshalb gegen das neueste installierte macOS-26-SDK.

## Prüfen

```sh
SDKROOT=…/MacOSX26.5.sdk swift run kern-pruefung [match-ordner]   # liest nur: Round-Trip aller Einträge, CSV
# Store-Abläufe gegen eine Kopie (nie gegen den echten Ordner):
git clone --bare <repo> /tmp/t/gegenstelle.git && git clone /tmp/t/gegenstelle.git /tmp/t/espanso
ESPANSO_CONFIG_DIR=/tmp/t/espanso BAUSTEINE_KEIN_NEUSTART=1 swift run store-pruefung
```

Lizenz: GPL-3.0-or-later.

Built in Switzerland with ♥ by Kappa1
