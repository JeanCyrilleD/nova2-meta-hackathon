import Foundation

/// 01/11 (Meta AI Developer Hackathon) — MODE DÉMO SANS CLÉ.
/// `NOVA_DEMO_REPLAY=1` (variable d'environnement) ou réglage « demo_replay » = vrai : Nova REJOUE des exécutions réelles
/// enregistrées (demo/traces/*.json, construites par tools/demo/build_traces.py à partir des journaux réels, nettoyées)
/// — note CAFU (Muse Spark 1.3), relecture Spark Open (Baseten), image (Muse Image), dictée (Muse Voice Transcribe),
/// journal de routage meta_only. Les identifiants de modèle et les étapes sont visibles. Aucun appel réseau, aucune clé.
/// Une trace sans exécution réelle réussie est servie avec « recorded »: false — jamais inventée.
/// Routes : GET /api/demo/traces · GET /api/demo/trace?id=… · GET /api/demo/replay?id=… (SSE, étape par étape).
public enum DemoReplay {
    public static let envKey: String = "NOVA_DEMO_REPLAY"
    public static let ids: [String] = ["cafu_note", "spark_open_review", "image", "dictation", "meta_routing"]

    public static var enabled: Bool {
        if ProcessInfo.processInfo.environment[envKey] == "1" { return true }
        return Settings().get("demo_replay", false)
    }

    /// Dossiers candidats : NOVA_DEMO_DIR, ressources de l'app, dépôt (à côté des sources), dossier de travail.
    public static func dirCandidates() -> [String] {
        var out: [String] = []
        if let e = ProcessInfo.processInfo.environment["NOVA_DEMO_DIR"], !e.isEmpty { out.append(e) }
        if let r = Bundle.main.resourcePath { out.append(r + "/demo/traces") }
        let repo: URL = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        out.append(repo.appendingPathComponent("demo/traces").path)
        out.append(FileManager.default.currentDirectoryPath + "/demo/traces")
        return out
    }
    public static func dir() -> String? {
        dirCandidates().first { FileManager.default.fileExists(atPath: $0 + "/cafu_note.json") }
    }

    /// Trace lue sur disque (nil = inconnue ou illisible). L'id est contrôlé contre la liste blanche (aucun chemin arbitraire).
    public static func trace(_ id: String, dir d: String? = nil) -> [String: Any]? {
        guard ids.contains(id), let base = d ?? dir(),
              let data = FileManager.default.contents(atPath: base + "/" + id + ".json"), let o = parseJSON(data) else { return nil }
        return o
    }

    /// Résumé servi à l'interface et aux juges : id, titre, modèle, enregistrée ou non.
    public static func list(dir d: String? = nil) -> [[String: Any]] {
        ids.compactMap { (id: String) -> [String: Any]? in
            guard let t = trace(id, dir: d) else { return nil }
            var r: [String: Any] = ["id": id, "title": (t["title"] as? String) ?? id, "recorded": (t["recorded"] as? Bool) ?? false]
            if let m = t["model"] as? String { r["model"] = m }
            return r
        }
    }

    /// Événements de rejeu (ordre réel) : étapes texte (CAFU) ou lignes de journal (appels de modèle).
    public static func events(_ t: [String: Any]) -> [[String: Any]] {
        var out: [[String: Any]] = []
        let model: String = (t["model"] as? String) ?? ""
        out.append(["type": "start", "id": (t["id"] as? String) ?? "", "title": (t["title"] as? String) ?? "", "model": model,
                    "recorded": (t["recorded"] as? Bool) ?? false, "replay": true])
        for s in (t["steps"] as? [String]) ?? [] { out.append(["type": "step", "text": s, "model": model]) }
        for e in (t["events"] as? [[String: Any]]) ?? [] {
            var x: [String: Any] = e; x["type"] = "model_call"
            out.append(x)
        }
        if let n = t["note"] as? String, !n.isEmpty { out.append(["type": "result", "text": n, "model": model]) }
        out.append(["type": "done", "id": (t["id"] as? String) ?? "", "replay": true])
        return out
    }
}

extension NovaApp {
    func demoReplayRoutes() {
        let s = server
        s.on("GET", "/api/demo/traces") { _, res in
            res.json(["ok": true, "enabled": DemoReplay.enabled, "dir": DemoReplay.dir().map { $0 as Any } ?? NSNull(), "traces": DemoReplay.list()])
        }
        s.on("GET", "/api/demo/trace") { req, res in
            guard let t = DemoReplay.trace(req.query["id"] ?? "") else { res.json(["ok": false, "error": "trace inconnue"], status: 404); return }
            res.json(t)
        }
        s.on("GET", "/api/demo/replay") { req, res in
            guard let t = DemoReplay.trace(req.query["id"] ?? "") else { res.json(["ok": false, "error": "trace inconnue"], status: 404); return }
            let pace: Double = min(2.0, max(0.0, Double(req.query["pace"] ?? "") ?? 0.4))
            res.sseStart()
            for e in DemoReplay.events(t) {
                if !res.sse("replay", e) { return }
                if pace > 0 { Thread.sleep(forTimeInterval: pace) }
            }
        }
    }
}
