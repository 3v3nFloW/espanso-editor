// swift-tools-version: 5.10
import PackageDescription

let package = Package(
    name: "Bausteine",
    platforms: [.macOS(.v14)],
    dependencies: [
        .package(url: "https://github.com/jpsim/Yams.git", from: "5.1.0"),
    ],
    targets: [
        // Alles ohne Oberfläche: espanso-YAML lesen/schreiben (kommentarerhaltend), Import/Export, Kollisionen
        .target(name: "BausteineKern", dependencies: ["Yams"]),
        // Die App
        .executableTarget(name: "Bausteine", dependencies: ["BausteineKern"]),
        // Selbstprüfung des Kerns gegen echte Dateien: swift run kern-pruefung <match-ordner>
        .executableTarget(name: "kern-pruefung", dependencies: ["BausteineKern"]),
        // Ablauf des Stores ohne Oberfläche gegen eine Testkopie (ESPANSO_CONFIG_DIR, BAUSTEINE_KEIN_NEUSTART=1)
        .executableTarget(name: "store-pruefung", dependencies: ["BausteineKern"]),
    ]
)
