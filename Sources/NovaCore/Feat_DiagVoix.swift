import Foundation

// 26/10 (Ahadi : « le live et la dictée ce n'est pas fameux ») — miroir de diagnostic voix.
// Toutes les 5 min, Nova recopie la fin de ses journaux voix et ses 3 dernières conversations
// « Voix live » dans ~/spark-local/Nova2/releves/diag/ (dossier de travail d'Ahadi, local, jamais
// envoyé). Secrets masqués par SecretsGuard. Sert à diagnostiquer sans prendre l'écran.
enum DiagVoix {
    nonisolated(unsafe) static var started: Bool = false

    static func start(app: NovaApp) {
        if started { return }
        started = true
        Thread.detachNewThread {
            Thread.sleep(forTimeInterval: 60)
            while true {
                DiagVoix.dump(app: app)
                Thread.sleep(forTimeInterval: 300)
            }
        }
    }

    static func tailLines(_ name: String, _ n: Int) -> String {
        let url: URL = Paths.home.appendingPathComponent(name)
        guard let d = try? Data(contentsOf: url) else { return "" }
        let txt: String = String(decoding: d.suffix(600_000), as: UTF8.self)
        let lines: [String] = txt.components(separatedBy: "\n").filter { (l: String) -> Bool in !l.isEmpty }
        return lines.suffix(n).map { (l: String) -> String in SecretsGuard.redact(l) }.joined(separator: "\n") + "\n"
    }

    nonisolated(unsafe) static var museProbed: Bool = false

    /// 26/10 (Ahadi : abonnement Muse Code) — repérage du CLI « muse » et de son aide (lecture seule, une fois par lancement),
    /// pour brancher Nova sur l'abonnement via « muse exec » sans deviner ses options.
    static func museCLIProbe(dir: String) {
        if museProbed { return }
        museProbed = true
        let h: String = NSHomeDirectory()
        let cands: [String] = [h + "/.local/bin/muse", h + "/.muse/bin/muse", "/opt/homebrew/bin/muse", "/usr/local/bin/muse", h + "/.npm-global/bin/muse", h + "/bin/muse"]
        var out: String = "généré : "
        out += nowISO()
        out += "\n"
        guard let bin = cands.first(where: { FileManager.default.isExecutableFile(atPath: $0) }) else {
            out += "CLI muse introuvable dans : "
            out += cands.joined(separator: ", ")
            try? out.write(toFile: dir + "/muse_cli.txt", atomically: true, encoding: .utf8)
            return
        }
        out += "binaire : "
        out += bin
        out += "\n"
        let argSets: [[String]] = [["--version"], ["--help"], ["exec", "--help"]]
        for args in argSets {
            let p: Process = Process()
            p.executableURL = URL(fileURLWithPath: bin)
            p.arguments = args
            p.currentDirectoryURL = URL(fileURLWithPath: NSTemporaryDirectory())
            let pipe: Pipe = Pipe()
            p.standardOutput = pipe; p.standardError = pipe
            let cmdLine: String = "\n$ muse " + args.joined(separator: " ")
            do { try p.run() } catch { out += cmdLine; out += " → échec : \(error)\n"; continue }
            let deadline: Date = Date().addingTimeInterval(15)
            while p.isRunning && Date() < deadline { Thread.sleep(forTimeInterval: 0.2) }
            if p.isRunning { p.terminate() }
            let d: Data = pipe.fileHandleForReading.readDataToEndOfFile()
            let txt: String = String(decoding: d.prefix(8000), as: UTF8.self)
            out += cmdLine
            out += "\n"
            out += SecretsGuard.redact(txt)
            out += "\n"
        }
        // Essai réel (1 requête de l'abonnement) : la sortie du cerveau « Muse Code », telle que Nova la reçoit.
        let t0: Date = Date()
        do {
            let r: String = try MuseCodeCLI.run(system: "Tu es Nova. Réponds en français, une ligne.", messages: [ChatMsg("user", "Dis exactement : Muse Code branché sur Nova.")], timeout: 120, cancel: { false })
            out += "\n=== essai muse exec : OK en "
            out += String(Int(Date().timeIntervalSince(t0)))
            out += " s ===\n"
            out += String(r.prefix(2000))
            out += "\n"
        } catch let f as BrainFailure {
            out += "\n=== essai muse exec : ÉCHEC ===\n"
            out += f.message
            out += "\n"
        } catch {
            out += "\n=== essai muse exec : ÉCHEC (autre) ===\n"
        }
        try? out.write(toFile: dir + "/muse_cli.txt", atomically: true, encoding: .utf8)
    }

    static func dump(app: NovaApp) {
        let dir: String = NSHomeDirectory() + "/spark-local/Nova2/releves/diag"
        let fm: FileManager = FileManager.default
        guard fm.fileExists(atPath: NSHomeDirectory() + "/spark-local/Nova2") else { return }
        try? fm.createDirectory(atPath: dir, withIntermediateDirectories: true)
        for name in ["voix_live_journal.jsonl", "voix_journal.jsonl"] {
            let t: String = tailLines(name, 400)
            if !t.isEmpty { try? t.write(toFile: dir + "/" + name, atomically: true, encoding: .utf8) }
        }
        var out: [[String: Any]] = []
        for c in app.convs.list() {
            if out.count >= 4 { break }
            let title: String = (c["title"] as? String) ?? ""
            if !title.lowercased().hasPrefix("voix live") && !title.lowercased().contains("dictée") { continue }
            guard let id = c["id"] as? String, let full = app.convs.get(id) else { continue }
            if (full["incognito"] as? Bool) == true { continue }
            let msgs: [[String: Any]] = (full["messages"] as? [[String: Any]]) ?? []
            let slim: [[String: Any]] = msgs.suffix(60).map { (m: [String: Any]) -> [String: Any] in
                ["role": (m["role"] as? String) ?? "", "ts": (m["ts"] as? String) ?? "",
                 "content": SecretsGuard.redact(String(((m["content"] as? String) ?? "").prefix(1500)))]
            }
            out.append(["title": title, "updated": (c["updated"] as? String) ?? "", "messages": slim])
        }
        try? jsonData(["generated": nowISO(), "conversations": out]).write(to: URL(fileURLWithPath: dir + "/voix_live_conversations.json"))
        // Réglages voix (aucun secret : uniquement les clés voix_* / voice_* non sensibles)
        var reg: [String: Any] = [:]
        for k in ["voice_id", "voice_model", "voix_moteur", "phrases_attente", "stt_engine", "live_aec", "live_vad", "wake_word", "langue"] {
            let v: String = app.settings.get(k, "")
            if !v.isEmpty { reg[k] = v }
        }
        try? jsonData(reg).write(to: URL(fileURLWithPath: dir + "/voix_reglages.json"))
        // 26/10 (Ahadi : « pourquoi je ne reçois pas les directs Teams ? ») — état des volets et des arrivées, sans corps.
        var ages: [String: Any] = [:]
        for b in ["ol", "gm", "tm", "wa"] {
            if let a = WebMail.snapshotAge(b) { ages[b] = Int(a) } else { ages[b] = "jamais" }
        }
        let evs: [[String: Any]] = ProactiveFeed.list(limit: 80).map { (e: [String: Any]) -> [String: Any] in
            ["ts": (e["ts"] as? String) ?? "", "kind": (e["kind"] as? String) ?? "", "box": (e["box"] as? String) ?? "",
             "title": SecretsGuard.redact(String(((e["title"] as? String) ?? "").prefix(70))), "body": (e["body"] as? String) ?? "",
             "urgent": (e["urgent"] as? Bool) ?? false]
        }
        try? jsonData(["generated": nowISO(), "volets_age_s": ages, "conv_active": DirectActif.current() ?? "", "arrivees": evs]).write(to: URL(fileURLWithPath: dir + "/directs_etat.json"))
        DiagVoix.museCLIProbe(dir: dir)
        for name in ["direct_journal.jsonl", "briefs_journal.jsonl"] {
            let t: String = tailLines(name, 150)
            if !t.isEmpty { try? t.write(toFile: dir + "/" + name, atomically: true, encoding: .utf8) }
        }
    }
}
