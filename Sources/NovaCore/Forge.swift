import Foundation

/// Phase 9 — Forge auto-correctrice : un outil généré n'est enregistré « opérationnel » qu'après un test de santé
/// en bac à sable (3 s, sortie capturée, sans réseau, écriture limitée à un dossier temporaire), avec jusqu'à 3 essais
/// de correction par le routeur de cerveaux. Aucun garde-fou existant (Tools.gate/regex) n'est assoupli : le code qui les
/// déclenche est REFUSÉ sans être exécuté, et sans le bac à sable macOS (sandbox-exec) rien n'est jamais exécuté.
public struct ForgeResult {
    public var ok: Bool
    public var name: String
    public var source: String
    public var attempts: Int
    public var error: String?
    public var path: String?
    public var dict: [String: Any] {
        var d: [String: Any] = ["ok": ok, "name": name, "attempts": attempts]
        if let e = error { d["error"] = e }
        if let p = path { d["path"] = p }
        return d
    }
}

public final class Forge {
    public let router: Router
    public let journal: Journal
    public let registry = JSONFile("outils_forges.json")
    public static let maxAttempts = 3
    public static let healthTimeout: TimeInterval = 3

    public init(router: Router, journal: Journal = Tools.actions) { self.router = router; self.journal = journal }

    /// Interpréteurs autorisés pour un test de santé (chemins fixes, jamais résolus via le PATH de l'utilisateur).
    static let interpreters: [String: [String]] = [
        "sh": ["/bin/zsh"], "zsh": ["/bin/zsh"],
        "py": ["/usr/bin/python3"], "python": ["/usr/bin/python3"],
        "js": ["/opt/homebrew/bin/node", "/usr/local/bin/node"], "node": ["/opt/homebrew/bin/node", "/usr/local/bin/node"],
    ]
    static func ext(_ kind: String) -> String { ["sh": "sh", "zsh": "sh", "py": "py", "python": "py", "js": "js", "node": "js"][kind] ?? "txt" }

    static func safeName(_ n: String) -> String {
        let s = n.lowercased().map { $0.isLetter || $0.isNumber || $0 == "_" || $0 == "-" ? $0 : "_" }
        return String(String(s).prefix(48))
    }

    /// Refus statique : réutilise telles quelles les règles de Tools (secrets, envoi/paiement, exécution indirecte, destructif, réseau sortant).
    static func staticVerdict(_ src: String) -> String? {
        if Tools.match(Tools.mailPayRx, src) || Tools.match(Tools.sendEvasionRx, src) { return "Refusé : envoi de messages / paiements réservés à l'utilisateur." }
        if Tools.match(Tools.forbiddenRx, src) { return "Refusé : secret, système profond ou dangereux par nature." }
        if Tools.match(Tools.riskyRx, src) { return "Refusé pour le test automatique : action destructrice ou système (confirmation utilisateur requise, hors bac à sable)." }
        if Tools.match(Tools.indirectRx, src) { return "Refusé : exécution indirecte (code encodé / eval)." }
        return nil
    }

    /// Profil SBPL : tout est interdit par défaut ; lecture du système permise sauf zones secrètes ; écriture seulement dans `tmp` ; aucun réseau.
    static func profile(tmp: String) -> String {
        let q = { (s: String) in s.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"") }
        let home = q(FileManager.default.homeDirectoryForCurrentUser.path)
        return """
        (version 1)
        (deny default)
        (allow process-exec*) (allow process-fork) (allow signal (target self))
        (allow sysctl-read) (allow mach-lookup) (allow ipc-posix-shm-read*)
        (allow file-read*)
        (deny file-read* (subpath "\(home)/.ssh") (subpath "\(home)/.aws") (subpath "\(home)/.gnupg") (subpath "\(home)/Library/Keychains") (subpath "\(home)/Library/Application Support/Nova"))
        (deny file-write*)
        (allow file-write* (subpath "\(q(tmp))") (literal "/dev/null") (literal "/dev/dtracehelper"))
        (deny network*)
        """
    }

    /// Un test de santé : (code, stdout, stderr) ou une erreur d'infrastructure. Jamais d'exécution hors bac à sable.
    struct Run { var code: Int32; var out: String; var err: String }
    func sandboxRun(kind: String, source: String) -> (Run?, String?) {
        #if os(macOS)
        guard let cands = Forge.interpreters[kind], let interp = cands.first(where: { FileManager.default.isExecutableFile(atPath: $0) }) else { return (nil, "Interpréteur « \(kind) » introuvable : test impossible.") }
        let sb = "/usr/bin/sandbox-exec"
        guard FileManager.default.isExecutableFile(atPath: sb) else { return (nil, "Bac à sable macOS indisponible : aucune exécution.") }
        let fm = FileManager.default
        let dir = fm.temporaryDirectory.appendingPathComponent("nova-forge-" + UUID().uuidString)
        do { try fm.createDirectory(at: dir, withIntermediateDirectories: true) } catch { return (nil, "Dossier temporaire impossible.") }
        defer { try? fm.removeItem(at: dir) }
        let real = dir.resolvingSymlinksInPath().path
        let script = real + "/tool." + Forge.ext(kind)
        let prof = real + "/p.sb"
        do { try source.write(toFile: script, atomically: true, encoding: .utf8); try Forge.profile(tmp: real).write(toFile: prof, atomically: true, encoding: .utf8) }
        catch { return (nil, "Écriture temporaire impossible.") }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: sb)
        p.arguments = ["-f", prof, interp, script]
        p.currentDirectoryURL = URL(fileURLWithPath: real)
        p.environment = ["PATH": "/usr/bin:/bin", "HOME": real, "TMPDIR": real, "LANG": "en_US.UTF-8"]
        let o = Pipe(), e = Pipe(); p.standardOutput = o; p.standardError = e; p.standardInput = FileHandle.nullDevice
        do { try p.run() } catch { return (nil, "Lancement impossible : \(error.localizedDescription)") }
        var od = Data(), ed = Data(); let g = DispatchGroup()
        g.enter(); DispatchQueue.global().async { od = o.fileHandleForReading.readData(ofLength: 65536); g.leave() }
        g.enter(); DispatchQueue.global().async { ed = e.fileHandleForReading.readData(ofLength: 65536); g.leave() }
        let deadline = Date().addingTimeInterval(Forge.healthTimeout)
        while p.isRunning && Date() < deadline { Thread.sleep(forTimeInterval: 0.02) }
        var timedOut = false
        if p.isRunning {
            timedOut = true; let pid = p.processIdentifier
            _ = runProcess("/usr/bin/pkill", ["-KILL", "-P", "\(pid)"], timeout: 2); p.terminate(); Thread.sleep(forTimeInterval: 0.2)
            if p.isRunning { kill(pid, SIGKILL) }
        }
        _ = g.wait(timeout: .now() + 1)
        let so = String(data: od, encoding: .utf8) ?? "", se = String(data: ed, encoding: .utf8) ?? ""
        if timedOut { return (Run(code: 124, out: so, err: "Délai dépassé (\(Int(Forge.healthTimeout)) s). " + se), nil) }
        return (Run(code: p.terminationStatus, out: so, err: se), nil)
        #else
        return (nil, "Bac à sable indisponible hors macOS : aucune exécution.")
        #endif
    }

    /// Extrait le code corrigé d'une réponse de cerveau (premier bloc ```), sinon le texte entier.
    static func extractCode(_ t: String) -> String {
        if let r = t.range(of: "```") {
            var rest = t[r.upperBound...]
            if let nl = rest.firstIndex(of: "\n") { rest = rest[rest.index(after: nl)...] }
            if let end = rest.range(of: "```") { return String(rest[..<end.lowerBound]).trimmingCharacters(in: .whitespacesAndNewlines) }
        }
        return t.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Valide, répare (≤ 3 essais) puis enregistre un outil généré. Bloquant : à appeler hors du thread principal.
    @discardableResult
    public func verifyAndHealTool(name: String, kind: String, source: String, why: String = "", actor: String = "Nova",
                                  heal: ((_ error: String, _ source: String) -> String?)? = nil) -> ForgeResult {
        let nm = Forge.safeName(name); var src = source; var lastErr = ""
        func log(_ ev: [String: Any]) { var e = ev; e["id"] = String(UUID().uuidString.prefix(8)).lowercased(); e["tool"] = "forge:" + nm; e["actor"] = actor; e["why"] = String(why.prefix(240)); e["effect"] = "écrit"; journal.add(e) }
        for attempt in 1...Forge.maxAttempts {
            if let v = Forge.staticVerdict(src) {
                lastErr = v; log(["input": "essai \(attempt)", "result": v, "ok": false]); return ForgeResult(ok: false, name: nm, source: src, attempts: attempt, error: v, path: nil)   // jamais de « correction » pour contourner un garde-fou
            }
            let (run, infra) = sandboxRun(kind: kind, source: src)
            if let i = infra { log(["input": "essai \(attempt)", "result": i, "ok": false]); return ForgeResult(ok: false, name: nm, source: src, attempts: attempt, error: i, path: nil) }
            let r = run!
            let bad = r.code != 0 || !r.err.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            if !bad {
                let dir = Paths.home.appendingPathComponent("forge", isDirectory: true)
                try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
                let file = dir.appendingPathComponent(nm + "." + Forge.ext(kind))
                try? src.write(to: file, atomically: true, encoding: .utf8)
                var l = registry.read(default: [[String: Any]]()); l.removeAll { ($0["name"] as? String) == nm }
                l.append(["name": nm, "kind": kind, "path": file.path, "attempts": attempt, "ts": nowISO(), "state": "operationnel"]); registry.write(l)
                log(["input": "essai \(attempt)", "result": "outil opérationnel", "ok": true])
                return ForgeResult(ok: true, name: nm, source: src, attempts: attempt, error: nil, path: file.path)
            }
            lastErr = "code \(r.code) · " + shortError(r.err.isEmpty ? r.out : r.err, 600)
            log(["input": "essai \(attempt)", "result": shortError(lastErr, 300), "ok": false])
            if attempt == Forge.maxAttempts { break }
            let prompt = "Cet outil (\(kind)) a échoué à son test de santé (3 s, sans réseau, écriture interdite hors dossier temporaire).\nERREUR :\n\(lastErr)\n\nSOURCE :\n\(src)\n\nRenvoie UNIQUEMENT le source corrigé complet dans un bloc ```. N'ajoute ni réseau, ni écriture hors dossier temporaire, ni envoi de messages."
            let fixed: String?
            if let h = heal { fixed = h(lastErr, src) }
            else { fixed = router.complete(messages: [ChatMsg("user", prompt)], system: "Tu corriges du code généré. Réponse = code seul.", mode: MetaSpecialites.actif ? "code" : "deep", maxTokens: 2500)?.text }   // 01/11 : spécialité code (Wonder)
            guard let f = fixed, !f.isEmpty else { lastErr += " · aucun cerveau n'a pu corriger"; break }
            src = Forge.extractCode(f)
        }
        let msg = "Outil « \(nm) » NON enregistré après \(Forge.maxAttempts) essais : \(lastErr)"
        log(["input": "échec final", "result": shortError(msg, 300), "ok": false])
        return ForgeResult(ok: false, name: nm, source: src, attempts: Forge.maxAttempts, error: msg, path: nil)
    }
}

// MARK: - V5-G (24/10) : écran « Outils » — revérification et retrait d'un outil forgé
// POST /api/forge/verify exige le source : l'interface ne l'a pas. Ces deux routes travaillent par NOM, sur le fichier
// enregistré dans ~/…/Nova/forge. Revérifier = un test de santé pur (mêmes refus statiques, même bac à sable, AUCUNE
// correction par un cerveau, aucun coût). Retirer = fichier mis à la Corbeille (récupérable) et entrée marquée « retire »,
// jamais effacée. Enregistrées depuis checkpointRoutes() (Feat_Checkpoints.swift), déjà appelée par App.swift.
extension Forge {
    static let uiLock: NSLock = NSLock()

    /// Chemin réel d'un outil forgé, seulement s'il vit dans le dossier forge de Nova.
    static func forgedPath(_ entry: [String: Any]) -> String? {
        let p: String = (entry["path"] as? String) ?? ""
        let dir: String = Paths.home.appendingPathComponent("forge", isDirectory: true).resolvingSymlinksInPath().path
        let real: String = URL(fileURLWithPath: p).resolvingSymlinksInPath().path
        guard !p.isEmpty, real.hasPrefix(dir + "/") else { return nil }
        return real
    }

    /// Met à jour une entrée du registre (sous verrou) ; renvoie l'entrée modifiée.
    func updateEntry(_ name: String, _ patch: [String: Any]) -> [String: Any]? {
        Forge.uiLock.lock(); defer { Forge.uiLock.unlock() }
        var l: [[String: Any]] = registry.read(default: [[String: Any]]())
        guard let i: Int = l.firstIndex(where: { ($0["name"] as? String) == name }) else { return nil }
        for (k, v) in patch { l[i][k] = v }
        registry.write(l)
        return l[i]
    }

    /// Test de santé seul (sans auto-guérison). Renvoie (ok, message).
    public func recheckTool(name: String) -> (ok: Bool, message: String, entry: [String: Any]?) {
        let l: [[String: Any]] = registry.read(default: [[String: Any]]())
        guard let e: [String: Any] = l.first(where: { ($0["name"] as? String) == name }) else { return (false, "Outil introuvable dans le registre.", nil) }
        if (e["state"] as? String) == "retire" { return (false, "Outil retiré : remets-le en place depuis la Corbeille avant de le revérifier.", e) }
        guard let path: String = Forge.forgedPath(e) else { return (false, "Fichier de l'outil hors du dossier forge : vérification refusée.", e) }
        guard let src: String = try? String(contentsOfFile: path, encoding: .utf8) else {
            let u: [String: Any]? = updateEntry(name, ["state": "en_echec", "checked": nowISO(), "last_error": "Fichier de l'outil introuvable."])
            return (false, "Fichier de l'outil introuvable : " + path, u)
        }
        let kind: String = (e["kind"] as? String) ?? "sh"
        var ok: Bool = false
        var msg: String = ""
        if let v: String = Forge.staticVerdict(src) { msg = v }
        else {
            let r: (Run?, String?) = sandboxRun(kind: kind, source: src)
            if let infra: String = r.1 { msg = infra }
            else if let run: Run = r.0 {
                let bad: Bool = run.code != 0 || !run.err.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                if bad { msg = "code \(run.code) · " + shortError(run.err.isEmpty ? run.out : run.err, 300) }
                else { ok = true; msg = "Test de santé réussi (bac à sable, \(Int(Forge.healthTimeout)) s, sans réseau)." }
            } else { msg = "Test impossible." }
        }
        var patch: [String: Any] = ["state": ok ? "operationnel" : "en_echec", "checked": nowISO()]
        patch["last_error"] = ok ? "" : msg
        let u: [String: Any]? = updateEntry(name, patch)
        let ev: [String: Any] = ["id": String(UUID().uuidString.prefix(8)).lowercased(), "tool": "forge:" + name, "actor": "Ahadi", "why": "revérification depuis l'écran Outils", "input": "revérification", "result": shortError(msg, 300), "ok": ok, "effect": "lu"]
        journal.add(ev)
        return (ok, msg, u)
    }

    /// Retire un outil : fichier à la Corbeille (récupérable), entrée conservée avec state « retire ».
    public func retireTool(name: String) -> (ok: Bool, message: String) {
        let l: [[String: Any]] = registry.read(default: [[String: Any]]())
        guard let e: [String: Any] = l.first(where: { ($0["name"] as? String) == name }) else { return (false, "Outil introuvable dans le registre.") }
        if (e["state"] as? String) == "retire" { return (true, "Outil déjà retiré.") }
        var trashed: String = ""
        if let path: String = Forge.forgedPath(e), FileManager.default.fileExists(atPath: path) {
            #if os(macOS)
            var out: NSURL? = nil
            do { try FileManager.default.trashItem(at: URL(fileURLWithPath: path), resultingItemURL: &out); trashed = out?.path ?? "" }
            catch { return (false, "Mise à la Corbeille impossible : " + error.localizedDescription) }
            #else
            return (false, "Corbeille indisponible sur ce système.")
            #endif
        }
        _ = updateEntry(name, ["state": "retire", "retired": nowISO(), "trashed": trashed])
        let ev: [String: Any] = ["id": String(UUID().uuidString.prefix(8)).lowercased(), "tool": "forge:" + name, "actor": "Ahadi", "why": "retrait depuis l'écran Outils", "input": "retrait", "result": trashed.isEmpty ? "entrée retirée (fichier déjà absent)" : "fichier mis à la Corbeille", "ok": true, "effect": "écrit"]
        journal.add(ev)
        return (true, trashed.isEmpty ? "Outil retiré (son fichier était déjà absent)." : "Outil retiré : son fichier est dans la Corbeille, récupérable.")
    }
}

extension NovaApp {
    /// V5-G : routes de l'écran « Outils ». Appelée depuis checkpointRoutes() (Feat_Checkpoints.swift).
    func forgeUIRoutes() {
        let s: HTTPServer = server
        let fg: Forge = forge
        s.on("POST", "/api/forge/recheck") { req, res in
            let name: String = (req.json["name"] as? String) ?? ""
            guard !name.isEmpty else { let bad: [String: Any] = ["ok": false, "message": "nom requis"]; res.json(bad, status: 400); return }
            let r: (ok: Bool, message: String, entry: [String: Any]?) = fg.recheckTool(name: name)
            var body: [String: Any] = ["ok": r.ok, "message": r.message]
            if let e: [String: Any] = r.entry { body["item"] = e }
            res.json(body)
        }
        s.on("POST", "/api/forge/retire") { req, res in
            let name: String = (req.json["name"] as? String) ?? ""
            guard !name.isEmpty else { let bad: [String: Any] = ["ok": false, "message": "nom requis"]; res.json(bad, status: 400); return }
            let r: (ok: Bool, message: String) = fg.retireTool(name: name)
            let body: [String: Any] = ["ok": r.ok, "message": r.message]
            res.json(body)
        }
    }
}
