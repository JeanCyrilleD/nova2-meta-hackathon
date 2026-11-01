import Foundation

// CHANTIER 2 (27/10) — (a) BOUCLE D'EVALUATION.
// Registre de taches de reference versionnees (question, contexte, critere), execution contre le
// moteur LOCAL ou les magasins (jamais de contenu SCI/CAFU vers un cloud — Politique A), score
// deterministe quand c'est possible (correspondance de faits, presence de sources datees),
// historique des scores par version de prompt/modele. But : detecter une regression.
// Routes : GET /api/eval (dernier passage + tendance) · POST /api/eval/run borne (<= 5 taches).

public enum EvalCore {
    public static let registryVersion = "eval-v1"
    public static let maxRunTasks = 5

    public static func normalize(_ s: String) -> String {
        let low = s.lowercased().folding(options: .diacriticInsensitive, locale: Locale(identifier: "fr_FR"))
        let parts = low.components(separatedBy: CharacterSet.whitespacesAndNewlines).filter { !$0.isEmpty }
        return parts.joined(separator: " ")
    }

    public static func hasDatedSource(_ s: String) -> Bool {
        // Source datee : annee explicite (AAAA-MM-JJ ou AAAA) pres d'une mention de source.
        let iso = s.range(of: #"(19|20)\d{2}-\d{2}-\d{2}"#, options: .regularExpression) != nil
        if iso { return true }
        return s.range(of: #"(source|ref|réf|selon|daté|date).{0,40}(19|20)\d{2}"#, options: [.regularExpression, .caseInsensitive]) != nil
    }

    /// Score deterministe : fraction des faits attendus presents (correspondance normalisee),
    /// + volet source datee (20 %) quand le critere l'exige. Aucun juge LLM.
    public static func score(response: String, expectedFacts: [String], requireDatedSource: Bool)
        -> (score: Double, matched: [String], missing: [String], dated: Bool) {
        let norm = normalize(response)
        var matched: [String] = []; var missing: [String] = []
        for f in expectedFacts {
            if norm.contains(normalize(f)) { matched.append(f) } else { missing.append(f) }
        }
        let factScore = expectedFacts.isEmpty ? 1.0 : Double(matched.count) / Double(expectedFacts.count)
        let dated = hasDatedSource(response)
        let total = requireDatedSource ? factScore * 0.8 + (dated ? 0.2 : 0.0) : factScore
        return ((total * 100).rounded() / 100, matched, missing, dated)
    }

    /// Taches fictives par defaut (aucune donnee reelle) — remplacees des qu'eval_tasks.json existe.
    public static func defaultTasks() -> [[String: Any]] {
        [
            ["id": "capitale-fictive", "question": "Quelle est la capitale du pays fictif de Valdoria ?",
             "contexte": "Fiche fictive : la capitale de la Valdoria est Brume-sur-Lac (fiche revisee le 2026-01-15).",
             "critere": "La reponse cite le fait attendu.", "faits_attendus": ["Brume-sur-Lac"], "exige_source_datee": true],
            ["id": "pluie-fictive", "question": "Combien de jours de pluie la station fictive de Kerga a-t-elle releves en mars ?",
             "contexte": "Releve fictif : 12 jours de pluie en mars a Kerga (releve du 2026-04-02).",
             "critere": "La reponse cite le chiffre attendu.", "faits_attendus": ["12 jours"], "exige_source_datee": true],
            ["id": "train-fictif", "question": "A quelle heure part le train fictif T42 ?",
             "contexte": "Horaire fictif : le train T42 part a 07:45 de la gare de Nordan.",
             "critere": "La reponse cite l'heure attendue.", "faits_attendus": ["07:45"], "exige_source_datee": false],
        ]
    }

    /// Tendance : moyenne par version de prompt, du plus recent au plus ancien.
    public static func trend(history: [[String: Any]]) -> [[String: Any]] {
        var byVersion: [String: [Double]] = [:]; var order: [String] = []
        for h in history {
            let v = (h["prompt_version"] as? String) ?? "?"
            guard let s = (h["score"] as? Double) ?? (h["score"] as? NSNumber)?.doubleValue else { continue }
            if byVersion[v] == nil { order.append(v) }
            byVersion[v, default: []].append(s)
        }
        return order.map { v -> [String: Any] in
            let vals = byVersion[v] ?? []
            let avg = vals.isEmpty ? 0 : vals.reduce(0, +) / Double(vals.count)
            return ["prompt_version": v, "passages": vals.count, "moyenne": (avg * 100).rounded() / 100]
        }
    }

    /// Regression : la derniere moyenne est inferieure a la precedente d'au moins 0.15.
    public static func regressionDetected(history: [[String: Any]]) -> Bool {
        let t = trend(history: history)
        guard t.count >= 2 else { return false }
        let last = (t[0]["moyenne"] as? Double) ?? 0
        let prev = (t[1]["moyenne"] as? Double) ?? 0
        return prev - last >= 0.15
    }
}

enum EvalStore {
    static let tasksFile = JSONFile("eval_tasks.json")
    static let historyFile = JSONFile("eval_history.json")
    static let lock = NSLock()

    static func tasks() -> (version: String, tasks: [[String: Any]]) {
        let raw = tasksFile.read(default: [String: Any]())
        if let t = raw["taches"] as? [[String: Any]], !t.isEmpty {
            return ((raw["version"] as? String) ?? EvalCore.registryVersion, t)
        }
        return (EvalCore.registryVersion, EvalCore.defaultTasks())
    }

    static func history() -> [[String: Any]] { historyFile.read(default: [[String: Any]]()) }

    static func appendHistory(_ rows: [[String: Any]]) {
        lock.lock(); defer { lock.unlock() }
        var h = history(); h.insert(contentsOf: rows, at: 0)
        historyFile.write(Array(h.prefix(200)))
    }

    /// Execution bornee : moteur LOCAL uniquement (solo). Sans moteur local, score 0 explicite
    /// « moteur_local_absent » — jamais un chiffre flatteur, jamais d'appel cloud.
    static func run(router: Router, promptVersion: String, onlyIds: [String]) -> [String: Any] {
        let (version, all) = tasks()
        let picked = (onlyIds.isEmpty ? all : all.filter { onlyIds.contains(($0["id"] as? String) ?? "") })
        let bounded = Array(picked.prefix(EvalCore.maxRunTasks))
        let pv = promptVersion.isEmpty ? version : promptVersion
        var rows: [[String: Any]] = []; var results: [[String: Any]] = []
        for t in bounded {
            let q = (t["question"] as? String) ?? ""
            let ctx = (t["contexte"] as? String) ?? ""
            let facts = (t["faits_attendus"] as? [String]) ?? []
            let dated = (t["exige_source_datee"] as? Bool) ?? false
            let r = router.completeDetailed(messages: [ChatMsg("user", q)], system: "Contexte de reference :\n" + ctx,
                                            mode: "fast", preferred: "local", maxTokens: 400, deadline: 60, solo: true)
            var row: [String: Any] = ["id": (t["id"] as? String) ?? "", "question": q, "prompt_version": pv,
                                      "registre": version, "ts": nowISO()]
            if let res = r.result {
                let s = EvalCore.score(response: res.text, expectedFacts: facts, requireDatedSource: dated)
                row["score"] = s.score; row["modele"] = res.brain; row["faits_trouves"] = s.matched
                row["faits_manquants"] = s.missing; row["source_datee"] = s.dated; row["statut"] = "mesure"
            } else {
                row["score"] = 0.0; row["modele"] = "local"; row["statut"] = "moteur_local_absent"
                row["detail"] = r.error ?? "aucun moteur local"
            }
            rows.append(row); results.append(row)
        }
        if !rows.isEmpty { appendHistory(rows) }
        let scores = rows.compactMap { ($0["score"] as? Double) ?? ($0["score"] as? NSNumber)?.doubleValue }
        let avg = scores.isEmpty ? 0 : scores.reduce(0, +) / Double(scores.count)
        return ["ok": true, "prompt_version": pv, "registre": version, "resultats": results,
                "moyenne": (avg * 100).rounded() / 100, "ts": nowISO()]
    }
}

extension NovaApp {
    func evalRoutes() {
        let s = server; let rt = router
        s.on("GET", "/api/eval") { _, res in
            let h = EvalStore.history()
            let body: [String: Any] = ["dernier": h.first as Any? ?? NSNull(), "historique": Array(h.prefix(50)),
                                       "tendance": EvalCore.trend(history: h), "regression": EvalCore.regressionDetected(history: h),
                                       "registre": EvalStore.tasks().version, "taches": EvalStore.tasks().tasks.count]
            res.json(body)
        }
        s.on("POST", "/api/eval/run") { req, res in
            let ids = (req.json["ids"] as? [String]) ?? []
            let pv = (req.json["prompt_version"] as? String) ?? ""
            DispatchQueue.global(qos: .utility).async {
                let out = EvalStore.run(router: rt, promptVersion: pv, onlyIds: ids)
                res.json(out)
            }
        }
    }
}
