import Foundation

// CHANTIER 2 (27/10) — (c) SOUS-AGENTS ISOLES.
// Primitive d'execution en contexte isole : allowlist d'outils par role, budget de pas,
// modele route local ou Standard (spark-1.3) — jamais Contributor. Seul un resume structure
// retourne au parent. Journal des executions. Reutilise Agent/Router existants, sans les dupliquer.
// Routes : POST /api/sous-agents/run borne · GET /api/sous-agents (historique).

public enum SousAgents {
    public static let maxStepsCap = 5
    public static let maxTaskChars = 2000

    /// Roles fermes : outils autorises + cerveau. Contributor interdit par construction.
    public static let roles: [String: [String: Any]] = [
        "lecture": ["outils": ["recall", "know", "calendar", "reminders", "system", "web_search"], "cerveau": "local"],
        "recherche": ["outils": ["web_search", "web_fetch", "recall", "know"], "cerveau": "spark-1.3"],
        "redaction": ["outils": ["recall", "know"], "cerveau": "spark-1.3"],
    ]

    public static func allowedTools(role: String) -> Set<String>? {
        guard let r = roles[role], let t = r["outils"] as? [String] else { return nil }
        return Set(t)
    }

    /// Routage ferme : local ou Standard, jamais Contributor (meme si demande explicitement).
    public static func brainFor(role: String, requested: String?) -> String? {
        let req = (requested ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        if req.lowercased().contains("contributor") { return nil }
        if req == "local" || req == "spark-1.3" { return req }
        if !req.isEmpty { return nil }
        return (roles[role]?["cerveau"] as? String) ?? "spark-1.3"
    }

    public static func clampSteps(_ n: Int) -> Int { max(1, min(maxStepsCap, n)) }

    /// Resume structure : seul ce qui retourne au parent (jamais l'historique brut du sous-agent).
    public static func summary(role: String, brain: String?, text: String, ledger: [[String: Any]], stepsCap: Int) -> [String: Any] {
        let toolsUsed = Array(Set(ledger.compactMap { $0["tool"] as? String })).sorted()
        return ["role": role, "cerveau": brain as Any? ?? NSNull(), "pas_max": stepsCap, "pas_outils": ledger.count,
                "outils_utilises": toolsUsed, "resume": String(text.prefix(1500)), "ts": nowISO()]
    }
}

enum SousAgentsStore {
    static let file = JSONFile("sous_agents.json")
    static let lock = NSLock()
    static func history() -> [[String: Any]] { file.read(default: [[String: Any]]()) }
    static func append(_ row: [String: Any]) {
        lock.lock(); defer { lock.unlock() }
        var h = history(); h.insert(row, at: 0); file.write(Array(h.prefix(100)))
    }
}

extension NovaApp {
    func sousAgentsRoutes() {
        let s = server; let rt = router; let tl = tools
        s.on("GET", "/api/sous-agents") { _, res in
            res.json(["items": SousAgentsStore.history(), "roles": SousAgents.roles.keys.sorted()])
        }
        s.on("POST", "/api/sous-agents/run") { req, res in
            let role = ((req.json["role"] as? String) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            let task = String(((req.json["tache"] as? String) ?? "").prefix(SousAgents.maxTaskChars))
            guard SousAgents.allowedTools(role: role) != nil else {
                res.json(["ok": false, "error": "role inconnu (lecture, recherche, redaction)"], status: 400); return
            }
            guard !task.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                res.json(["ok": false, "error": "tache vide"], status: 400); return
            }
            guard let brain = SousAgents.brainFor(role: role, requested: req.json["cerveau"] as? String) else {
                res.json(["ok": false, "error": "cerveau refuse : local ou Standard (spark-1.3) uniquement, jamais Contributor"], status: 400); return
            }
            let steps = SousAgents.clampSteps((req.json["pas_max"] as? Int) ?? 3)
            let allowed = SousAgents.allowedTools(role: role)
            DispatchQueue.global(qos: .utility).async {
                let agent = Agent(router: rt, tools: tl)
                var text = ""; var ledger: [[String: Any]] = []
                let system = "Tu es un sous-agent isole de Nova, role « \(role) ». Accomplis uniquement la tache bornee, avec les seuls outils autorises. Conclis par un resume factuel court : Nova ne verra que ce resume."
                let brainUsed = agent.run(messages: [ChatMsg("user", task)], system: system, mode: "fast", preferred: brain,
                                          maxTokens: 1200, useTools: true, maxSteps: steps, allowed: allowed,
                                          actor: "Sous-agent \(role)", cancel: { false },
                                          onLedger: { ledger = $0 },
                                          onEvent: { ev in if case .delta(let d) = ev { text += d }; if case .draftReset = ev { text = "" } })
                var sum = SousAgents.summary(role: role, brain: brainUsed ?? brain, text: text, ledger: ledger, stepsCap: steps)
                sum["ok"] = brainUsed != nil && !text.isEmpty
                if brainUsed == nil { sum["erreur"] = "aucun cerveau local/Standard disponible" }
                SousAgentsStore.append(sum)
                res.json(sum)
            }
        }
    }
}
