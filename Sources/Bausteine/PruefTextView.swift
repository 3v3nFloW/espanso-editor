import AppKit
import SwiftUI
import BausteineKern

/// Mehrzeiliges Textfeld mit macOS-Rechtschreibprüfung und LanguageTool-Markierungen.
/// Keine automatischen Ersetzungen (Anführungszeichen, Bindestriche, Autokorrektur) — der Text soll genau so expandieren.
struct PruefTextView: NSViewRepresentable {
    @Binding var text: String
    var treffer: [LTTreffer] = []
    var pruefen = true
    var monospace = false
    var schriftgroesse: Double = 13
    var onAnwenden: ((LTTreffer, String) -> Void)?
    var onIgnorieren: ((LTTreffer) -> Void)?
    var onWoerterbuch: ((String) -> Void)?

    func makeCoordinator() -> Koordinator { Koordinator(self) }

    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSTextView.scrollableTextView()
        let alt = scroll.documentView as! NSTextView
        // TextKit 1, damit die Markierungen als temporäre Attribute gesetzt werden können
        let tv = LTTextView(frame: alt.frame)
        _ = tv.layoutManager
        tv.autoresizingMask = [.width]
        tv.isVerticallyResizable = true
        tv.textContainer?.widthTracksTextView = true
        tv.minSize = NSSize(width: 0, height: 0)
        tv.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        scroll.documentView = tv
        tv.delegate = context.coordinator
        tv.isRichText = false
        tv.allowsUndo = true
        tv.importsGraphics = false
        tv.usesFindBar = true
        tv.isAutomaticQuoteSubstitutionEnabled = false
        tv.isAutomaticDashSubstitutionEnabled = false
        tv.isAutomaticTextReplacementEnabled = false
        tv.isAutomaticSpellingCorrectionEnabled = false
        tv.isAutomaticTextCompletionEnabled = false
        tv.isAutomaticLinkDetectionEnabled = false
        tv.smartInsertDeleteEnabled = false
        tv.textContainerInset = NSSize(width: 4, height: 6)
        tv.font = schrift
        tv.string = text
        tv.koordinator = context.coordinator
        anwendenPruefung(tv)
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        context.coordinator.eltern = self
        guard let tv = scroll.documentView as? LTTextView else { return }
        if tv.string != text {
            let sel = tv.selectedRanges
            tv.string = text
            let laenge = (text as NSString).length
            tv.selectedRanges = sel.map { NSValue(range: NSIntersectionRange($0.rangeValue, NSRange(location: 0, length: laenge))) }
        }
        anwendenPruefung(tv)
        if tv.font != schrift { tv.font = schrift }
        if tv.treffer != treffer {
            tv.treffer = treffer
            tv.markieren()
        }
    }

    private var schrift: NSFont {
        monospace ? .monospacedSystemFont(ofSize: schriftgroesse - 1, weight: .regular) : .systemFont(ofSize: schriftgroesse)
    }

    private func anwendenPruefung(_ tv: NSTextView) {
        if tv.isContinuousSpellCheckingEnabled != pruefen {
            tv.isContinuousSpellCheckingEnabled = pruefen
            tv.isGrammarCheckingEnabled = pruefen
        }
    }

    final class Koordinator: NSObject, NSTextViewDelegate {
        var eltern: PruefTextView
        init(_ e: PruefTextView) { eltern = e }
        func textDidChange(_ n: Notification) {
            guard let tv = n.object as? NSTextView else { return }
            eltern.text = tv.string
        }
    }
}

final class LTTextView: NSTextView {
    var treffer: [LTTreffer] = []
    weak var koordinator: PruefTextView.Koordinator?

    func markieren() {
        guard let lm = layoutManager else { return }
        let alles = NSRange(location: 0, length: (string as NSString).length)
        lm.removeTemporaryAttribute(.underlineStyle, forCharacterRange: alles)
        lm.removeTemporaryAttribute(.underlineColor, forCharacterRange: alles)
        for t in treffer {
            let r = NSIntersectionRange(t.bereich, alles)
            guard r.length > 0 else { continue }
            let farbe: NSColor = t.art == .rechtschreibung ? .systemRed : (t.art == .grammatik ? .systemBlue : .systemOrange)
            lm.addTemporaryAttributes([.underlineStyle: NSUnderlineStyle.thick.rawValue | NSUnderlineStyle.patternDot.rawValue,
                                       .underlineColor: farbe], forCharacterRange: r)
        }
    }

    override func didChangeText() {
        super.didChangeText()
        // Nach dem Tippen stimmen die Positionen nicht mehr → Markierungen weg bis zur nächsten Prüfung
        if !treffer.isEmpty { treffer = []; markieren() }
    }

    /// Rechtsklick auf eine LanguageTool-Markierung: Vorschläge oben im Kontextmenü.
    override func menu(for event: NSEvent) -> NSMenu? {
        let menu = super.menu(for: event) ?? NSMenu()
        let p = convert(event.locationInWindow, from: nil)
        let i = characterIndexForInsertion(at: p)
        guard let t = treffer.first(where: { NSLocationInRange(i, $0.bereich) || i == $0.bereich.location + $0.bereich.length }) else { return menu }
        var pos = 0
        let kopf = NSMenuItem(title: t.meldung, action: nil, keyEquivalent: "")
        kopf.isEnabled = false
        menu.insertItem(kopf, at: pos); pos += 1
        for v in t.vorschlaege {
            let m = NSMenuItem(title: v.isEmpty ? "(entfernen)" : v, action: #selector(vorschlag(_:)), keyEquivalent: "")
            m.target = self; m.representedObject = [t.id.uuidString, v]
            menu.insertItem(m, at: pos); pos += 1
        }
        if t.art == .rechtschreibung {
            let w = NSMenuItem(title: "Ins Wörterbuch aufnehmen", action: #selector(woerterbuch(_:)), keyEquivalent: "")
            w.target = self; w.representedObject = (string as NSString).substring(with: t.bereich)
            menu.insertItem(w, at: pos); pos += 1
        }
        let ig = NSMenuItem(title: "Ignorieren", action: #selector(ignorieren(_:)), keyEquivalent: "")
        ig.target = self; ig.representedObject = t.id.uuidString
        menu.insertItem(ig, at: pos); pos += 1
        menu.insertItem(.separator(), at: pos)
        return menu
    }

    @objc func vorschlag(_ m: NSMenuItem) {
        guard let a = m.representedObject as? [String], let t = treffer.first(where: { $0.id.uuidString == a[0] }) else { return }
        koordinator?.eltern.onAnwenden?(t, a[1])
    }
    @objc func woerterbuch(_ m: NSMenuItem) {
        guard let w = m.representedObject as? String else { return }
        NSSpellChecker.shared.learnWord(w)
        koordinator?.eltern.onWoerterbuch?(w)
    }
    @objc func ignorieren(_ m: NSMenuItem) {
        guard let id = m.representedObject as? String, let t = treffer.first(where: { $0.id.uuidString == id }) else { return }
        koordinator?.eltern.onIgnorieren?(t)
    }
}
