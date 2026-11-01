import Foundation

// 26/10 (Ahadi : « j'ai un abonnement Muse Code, comment l'utiliser ? ») — cerveau « Muse Code (abonnement) ».
// L'abonnement couvre le CLI officiel « muse » (pas les clés API, facturées à l'usage) : Nova lance donc
// « muse exec » en mode sans écran, dans un dossier temporaire VIDE, outils coupés (pas de shell, pas
// d'écriture, pas de web, pas de question à l'utilisateur, pas de journal de session) — il ne fait que
// répondre au texte qu'on lui donne. Aucune clé ne transite par Nova : le CLI utilise sa propre connexion.
final class MuseBuf: @unchecked Sendable {
    private let lock: NSLock = NSLock()
    private var d: Data = Data()
    func add(_ x: Data) { lock.lock(); d.append(x); lock.unlock() }
    func get() -> Data { lock.lock(); defer { lock.unlock() }; return d }
}

public enum MuseCodeCLI {
    static func binary() -> String? {
        let h: String = NSHomeDirectory()
        let cands: [String] = [h + "/.local/bin/muse", h + "/.muse/bin/muse", "/opt/homebrew/bin/muse", "/usr/local/bin/muse"]
        return cands.first(where: { (p: String) -> Bool in FileManager.default.isExecutableFile(atPath: p) })
    }

    /// Conversation → un seul texte de consigne (le CLI prend un prompt, pas une liste de messages).
    static func promptText(system: String?, messages: [ChatMsg]) -> String {
        var out: String = ""
        let sys: String = (system ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        if !sys.isEmpty {
            out += "<consignes>\n"
            out += sys
            out += "\n</consignes>\n\n"
        }
        out += "<conversation>\n"
        for m in messages.suffix(40) {
            let who: String = m.role == "assistant" ? "Nova" : (m.role == "user" ? "Ahadi" : m.role)
            out += who
            out += " : "
            out += m.content
            out += "\n\n"
        }
        out += "</conversation>\n\n"
        out += "Réponds maintenant, en tant que Nova, au dernier message d'Ahadi. Donne uniquement la réponse finale, sans préambule ni commentaire sur ces consignes."
        return out
    }

    /// Exécution bloquante ; lève BrainFailure. Le texte rendu = la sortie standard du CLI (réponse finale).
    static func run(system: String?, messages: [ChatMsg], timeout: TimeInterval, cancel: () -> Bool) throws -> String {
        guard let bin = binary() else { throw BrainFailure(kind: .model, message: "CLI Muse Code introuvable (~/.local/bin/muse)") }
        let fm: FileManager = FileManager.default
        let dir: URL = fm.temporaryDirectory.appendingPathComponent("nova-muse-" + String(UUID().uuidString.prefix(8)).lowercased())
        try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: dir) }
        let pf: URL = dir.appendingPathComponent("prompt.txt")
        do { try promptText(system: system, messages: messages).write(to: pf, atomically: true, encoding: .utf8) }
        catch { throw BrainFailure(kind: .other, message: "Muse Code : prompt non écrit") }
        let p: Process = Process()
        p.executableURL = URL(fileURLWithPath: bin)
        p.arguments = ["exec", "--prompt-file", pf.path, "--preset", "empty",
                       "--disable-shell", "--disable-write", "--disable-web-tools", "--disable-reminders",
                       "--disable-request-user-input", "--no-session-log", "--no-foreign-personal-context",
                       "--reasoning-effort", "medium"]
        p.currentDirectoryURL = dir
        let outPipe: Pipe = Pipe()
        let errPipe: Pipe = Pipe()
        p.standardOutput = outPipe
        p.standardError = errPipe
        p.standardInput = FileHandle.nullDevice
        let ob: MuseBuf = MuseBuf()
        let eb: MuseBuf = MuseBuf()
        outPipe.fileHandleForReading.readabilityHandler = { (h: FileHandle) in ob.add(h.availableData) }
        errPipe.fileHandleForReading.readabilityHandler = { (h: FileHandle) in eb.add(h.availableData) }
        do { try p.run() } catch { throw BrainFailure(kind: .other, message: "Muse Code : lancement impossible") }
        let deadline: Date = Date().addingTimeInterval(timeout)
        var killed: String = ""
        while p.isRunning {
            if cancel() { killed = "annulé"; break }
            if Date() > deadline { killed = "délai"; break }
            Thread.sleep(forTimeInterval: 0.2)
        }
        if p.isRunning { p.terminate() }
        p.waitUntilExit()
        outPipe.fileHandleForReading.readabilityHandler = nil
        errPipe.fileHandleForReading.readabilityHandler = nil
        ob.add(outPipe.fileHandleForReading.readDataToEndOfFile())
        eb.add(errPipe.fileHandleForReading.readDataToEndOfFile())
        let out: String = String(decoding: ob.get(), as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        let err: String = String(decoding: eb.get(), as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        if killed == "annulé" { throw BrainFailure(kind: .canceled, message: "annulé") }
        if killed == "délai" { throw BrainFailure(kind: .timeout, message: "Muse Code : délai de \(Int(timeout)) s dépassé") }
        if p.terminationStatus != 0 || out.isEmpty {
            let low: String = err.lowercased()
            let kind: ErrKind
            if low.contains("allowance") || low.contains("quota") || low.contains("limit") { kind = .rate }
            else if low.contains("login") || low.contains("auth") || low.contains("credential") { kind = .auth }
            else { kind = .other }
            let why: String = String(SecretsGuard.redact(err).suffix(240))
            throw BrainFailure(kind: kind, message: "Muse Code (code \(p.terminationStatus)) : " + (why.isEmpty ? "réponse vide" : why))
        }
        return out
    }
}
