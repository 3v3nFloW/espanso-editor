import Foundation

/// Externe Programme aufrufen (espanso, git, ditto).
public enum Shell {
    public struct Ergebnis: Sendable { public let code: Int32; public let aus: String; public let fehler: String; public var ok: Bool { code == 0 } }

    @discardableResult
    public static func run(_ programm: String, _ argumente: [String], in ordner: URL? = nil, timeout: TimeInterval = 60) -> Ergebnis {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: programm)
        p.arguments = argumente
        if let ordner { p.currentDirectoryURL = ordner }
        var env = ProcessInfo.processInfo.environment
        env["GIT_TERMINAL_PROMPT"] = "0"
        env["LANG"] = env["LANG"] ?? "de_CH.UTF-8"
        p.environment = env
        let aus = Pipe(), err = Pipe()
        p.standardOutput = aus; p.standardError = err
        p.standardInput = FileHandle.nullDevice
        do { try p.run() } catch { return Ergebnis(code: -1, aus: "", fehler: error.localizedDescription) }
        // Ausgaben parallel lesen, sonst blockiert eine volle Pipe den Prozess
        var a = Data(), e = Data()
        let gruppe = DispatchGroup()
        gruppe.enter(); DispatchQueue.global().async { a = aus.fileHandleForReading.readDataToEndOfFile(); gruppe.leave() }
        gruppe.enter(); DispatchQueue.global().async { e = err.fileHandleForReading.readDataToEndOfFile(); gruppe.leave() }
        if gruppe.wait(timeout: .now() + timeout) == .timedOut { p.terminate() }
        p.waitUntilExit()
        return Ergebnis(code: p.terminationStatus, aus: String(decoding: a, as: UTF8.self), fehler: String(decoding: e, as: UTF8.self))
    }
}

public enum Espanso {
    public static var programm: String? {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        return ["/usr/local/bin/espanso", "/opt/homebrew/bin/espanso", "/Applications/Espanso.app/Contents/MacOS/espanso",
                home + "/Applications/Espanso.app/Contents/MacOS/espanso", "/usr/bin/espanso", home + "/.local/bin/espanso"]
            .first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    /// Konfigurationsordner laut `espanso path`, sonst der übliche Ort.
    public static func konfigOrdner() -> URL {
        if let p = programm {
            let r = Shell.run(p, ["path"], timeout: 10)
            for z in r.aus.split(separator: "\n") where z.hasPrefix("Config:") {
                return URL(fileURLWithPath: z.dropFirst("Config:".count).trimmingCharacters(in: .whitespaces))
            }
        }
        let home = FileManager.default.homeDirectoryForCurrentUser
        #if os(macOS)
        return home.appendingPathComponent("Library/Application Support/espanso")
        #else
        return home.appendingPathComponent(".config/espanso")
        #endif
    }

    /// Anzahl der Bausteine, die espanso tatsächlich lädt (liest die Dateien selbst, auch bei gestopptem Dienst).
    public static func anzahlGeladen() -> Int? {
        guard let p = programm else { return nil }
        let r = Shell.run(p, ["match", "list", "-j"], timeout: 30)
        guard r.ok, let d = r.aus.data(using: .utf8), let l = try? JSONSerialization.jsonObject(with: d) as? [Any] else { return nil }
        return l.count
    }

    public static func laeuft() -> Bool {
        guard let p = programm else { return false }
        return Shell.run(p, ["status"], timeout: 10).aus.contains("running")
    }

    public static func neustarten() {
        // Testbetrieb gegen eine Kopie (ESPANSO_CONFIG_DIR): den echten Dienst nicht anfassen
        guard ProcessInfo.processInfo.environment["BAUSTEINE_KEIN_NEUSTART"] == nil, let p = programm else { return }
        Shell.run(p, ["restart"], timeout: 20)
    }
}

/// git-Arbeitskopie, in der die Bausteine liegen (wenn es eine gibt).
public struct GitRepo: Sendable {
    public let wurzel: URL
    static let git = "/usr/bin/git"

    public static func finden(_ ordner: URL) -> GitRepo? {
        let r = Shell.run(git, ["-C", ordner.resolvingSymlinksInPath().path, "rev-parse", "--show-toplevel"], timeout: 10)
        guard r.ok else { return nil }
        return GitRepo(wurzel: URL(fileURLWithPath: r.aus.trimmingCharacters(in: .whitespacesAndNewlines)))
    }

    func g(_ a: [String], timeout: TimeInterval = 60) -> Shell.Ergebnis { Shell.run(GitRepo.git, ["-C", wurzel.path] + a, timeout: timeout) }

    public var hatGegenstelle: Bool { !g(["remote"]).aus.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }

    /// Stand der anderen Rechner holen; nil = ok, sonst Meldung.
    public func holen() -> String? {
        guard hatGegenstelle else { return nil }
        let r = g(["pull", "-q", "--ff-only"], timeout: 30)
        return r.ok ? nil : r.fehler.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    public var hatAenderungen: Bool { !g(["status", "--porcelain", "--", "match", "config"]).aus.isEmpty }

    /// Commit + Push; bei abgewiesenem Push erst die Änderungen der anderen holen (rebase).
    public func sichern(nachricht: String) -> (ok: Bool, meldung: String) {
        if hatAenderungen {
            g(["add", "-A", "--", "match"])
            let c = g(["commit", "-q", "-m", nachricht])
            if !c.ok && !c.aus.contains("nothing to commit") { return (false, "commit: " + c.fehler + c.aus) }
        }
        guard hatGegenstelle else { return (true, "gesichert (ohne Gegenstelle)") }
        var p = g(["push", "-q"], timeout: 45)
        if !p.ok {
            let r = g(["pull", "-q", "--rebase", "--autostash"], timeout: 45)
            if !r.ok { g(["rebase", "--abort"]); return (false, "Abgleich: " + r.fehler) }
            p = g(["push", "-q"], timeout: 45)
        }
        return p.ok ? (true, "gesichert und verteilt") : (false, "push: " + p.fehler)
    }

    /// Letzte Änderung je Zeile (0-basiert) aus git blame; nicht committete Zeilen = jetzt.
    public func zeilendaten(_ datei: URL) -> [Int: Date] {
        let rel = datei.resolvingSymlinksInPath().path.replacingOccurrences(of: wurzel.resolvingSymlinksInPath().path + "/", with: "")
        let r = g(["blame", "--line-porcelain", "--", rel], timeout: 30)
        guard r.ok else { return [:] }
        var d: [Int: Date] = [:]
        var zeit: Date?
        for z in r.aus.split(separator: "\n", omittingEmptySubsequences: false) {
            if z.hasPrefix("author-time ") { zeit = Double(z.dropFirst(12)).map { Date(timeIntervalSince1970: $0) } }
            else if z.hasPrefix("\t") {
                // Kopfzeile des Blocks davor enthält die Zielzeilennummer; einfacher: fortlaufend zählen
                d[d.count] = zeit
            }
        }
        return d
    }
}
