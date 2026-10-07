// Baut Resources/AppIcon.icns aus dem mittleren Entwurf in Resources/icon-entwuerfe.jpg:
// dunkle Icon-Fläche suchen, Ecken auf macOS-Form maskieren, im Apple-Raster (824/1024) mit Schatten ablegen.
import AppKit
let wurzel = CommandLine.arguments[1]
let quelle = NSImage(contentsOfFile: wurzel + "/Resources/icon-entwuerfe.jpg")!
let rep = NSBitmapImageRep(data: quelle.tiffRepresentation!)!
let W = rep.pixelsWide, H = rep.pixelsHigh
// mittlerer Entwurf liegt im mittleren Drittel; dunkle Fläche (Helligkeit < 0.35) eingrenzen
func dunkel(_ x: Int, _ y: Int) -> Bool { let c = rep.colorAt(x: x, y: y)!.usingColorSpace(.deviceRGB)!; return (c.redComponent + c.greenComponent + c.blueComponent) / 3 < 0.35 }
let x0 = W / 3, x1 = 2 * W / 3, my = H / 2, mx = W / 2
var links = x0, rechts = x1, oben = 0, unten = H - 1
while !dunkel(links, my) { links += 1 }
while !dunkel(rechts, my) { rechts -= 1 }
let breite = rechts - links
while !dunkel(mx, oben) { oben += 1 }                       // Oberkante: gerade, von oben in der Mitte
let spalte = links + breite / 4                             // Unterkante: von unten, neben dem Logo
while !dunkel(spalte, unten) { unten -= 1 }
let flaeche = unten - oben - Int(Double(breite) * 0.045)    // 3D-Kante der Vorlage abziehen
// quadratisch aus der kleineren Seite, waagrecht mittig
let seite = min(breite, flaeche)
let rand = Int(Double(seite) * 0.02)
let xa = links + (breite - seite) / 2
print("Fläche: x \(links)…\(rechts), y \(oben)…\(unten), Seite \(seite)")
let ausschnitt = NSRect(x: xa + rand, y: H - (oben + seite) + rand, width: seite - 2 * rand, height: seite - 2 * rand)

func render(_ px: Int) -> Data {
    let ziel = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: px, pixelsHigh: px, bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: ziel)
    NSGraphicsContext.current!.imageInterpolation = .high
    let s = Double(px) / 1024
    let koerper = NSRect(x: 100 * s, y: 100 * s, width: 824 * s, height: 824 * s)
    let pfad = NSBezierPath(roundedRect: koerper, xRadius: 185 * s, yRadius: 185 * s)
    let schatten = NSShadow(); schatten.shadowColor = NSColor.black.withAlphaComponent(0.35); schatten.shadowBlurRadius = 18 * s; schatten.shadowOffset = NSSize(width: 0, height: -8 * s)
    NSGraphicsContext.saveGraphicsState(); schatten.set(); NSColor(white: 0.17, alpha: 1).setFill(); pfad.fill(); NSGraphicsContext.restoreGraphicsState()
    NSGraphicsContext.saveGraphicsState(); pfad.addClip()
    quelle.draw(in: koerper, from: NSRect(x: ausschnitt.minX * quelle.size.width / Double(W), y: ausschnitt.minY * quelle.size.height / Double(H),
                                           width: ausschnitt.width * quelle.size.width / Double(W), height: ausschnitt.height * quelle.size.height / Double(H)),
                operation: .sourceOver, fraction: 1)
    NSGraphicsContext.restoreGraphicsState()
    NSGraphicsContext.restoreGraphicsState()
    return ziel.representation(using: .png, properties: [:])!
}
let set = URL(fileURLWithPath: NSTemporaryDirectory() + "AppIcon.iconset")
try? FileManager.default.removeItem(at: set)
try! FileManager.default.createDirectory(at: set, withIntermediateDirectories: true)
for b in [16, 32, 128, 256, 512] {
    try! render(b).write(to: set.appendingPathComponent("icon_\(b)x\(b).png"))
    try! render(b * 2).write(to: set.appendingPathComponent("icon_\(b)x\(b)@2x.png"))
}
try! render(1024).write(to: URL(fileURLWithPath: wurzel + "/Resources/AppIcon-1024.png"))
let p = Process(); p.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
p.arguments = ["-c", "icns", set.path, "-o", wurzel + "/Resources/AppIcon.icns"]
try! p.run(); p.waitUntilExit()
print(p.terminationStatus == 0 ? "AppIcon.icns gebaut" : "iconutil fehlgeschlagen")
