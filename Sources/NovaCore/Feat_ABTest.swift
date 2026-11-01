import Foundation
import NovaFoundation

// 29/10 (Ahadi : « vas-y pour les comparaisons ») — BANC DES CERVEAUX.
// Le même jeu de cas (fictifs, aucune donnée d'Ahadi) est soumis à plusieurs cerveaux de Nova,
// avec la consigne principale réelle de Nova ; on relève le texte, la durée et les erreurs.
// Déclenchement : un fichier ~/spark-local/Nova2/dormant/AB_REQUEST.json
//   {"brains":["spark-1.3",…], "cases":[{"id":"…","prompt":"…"}]}
// Résultat : ~/spark-local/Nova2/releves/diag/ab_resultats.json (écrit au fil de l'eau) ;
// la demande est renommée AB_REQUEST.done.json. Lecture seule : aucun outil, aucun envoi.
public enum ABBench {
    nonisolated(unsafe) static var started: Bool = false   // PHASE 1 (relu, protégé) : sous lock (start)
    nonisolated(unsafe) static var tools: Tools? = nil
    nonisolated(unsafe) static var lastKeys: Date = Date.distantPast
    static let lock: NSLock = NSLock()

    static func start(router: Router) {
        lock.lock(); if started { lock.unlock(); return }; started = true; lock.unlock()
        Thread.detachNewThread {
            Thread.sleep(forTimeInterval: 60)
            while true {
                ABBench.tick(router: router)
                Thread.sleep(forTimeInterval: 60)
            }
        }
    }

    /// 29/10 : chaque fournisseur dont la clé est au Trousseau est interrogé (liste des modèles, solde quand l'API le donne).
    /// Lecture seule ; aucune valeur de clé écrite ; seuls les identifiants de modèles et les codes HTTP sont gardés.
    static func probeProviders(root: String, ks: KeychainStore) {
        let provs: [(String, String, [KeyRef], String)] = [
            ("meta", "https://api.meta.ai/v1/models", [KnownKeys.spark, KnownKeys.sparkNova, KnownKeys.metaModelAPI], "bearer"),
            ("baseten", "https://inference.baseten.co/v1/models", [KnownKeys.basetenNova], "bearer"),
        ]
        var out: [[String: Any]] = []
        for (id, url, refs, _) in provs {
            var key: String? = nil
            for r in refs { if let v = ks.value(r), !v.isEmpty { key = v; break } }
            guard var k = key, let u = URL(string: url) else { out.append(["id": id, "etat": "sans_cle"]); continue }
            if let d = k.data(using: .utf8), d.first == UInt8(ascii: "{"), let o = parseJSON(d) { k = (o["api_key"] as? String) ?? (o["access_token"] as? String) ?? k }
            var rq: URLRequest = URLRequest(url: u)
            rq.setValue("Bearer " + k, forHTTPHeaderField: "Authorization")
            let (st, d): (Int, Data) = syncGet(rq, timeout: 12)
            var row: [String: Any] = ["id": id, "http": st]
            if let o = parseJSON(d) {
                if let arr = o["data"] as? [[String: Any]] {
                    let ids: [String] = arr.compactMap { (m: [String: Any]) -> String? in m["id"] as? String }
                    row["modeles"] = Array(ids.prefix(120))
                } else if var dd = o["data"] as? [String: Any] {
                    dd.removeValue(forKey: "label")   // libellé possible = fragment de clé — jamais écrit
                    row["donnees"] = dd
                } else {
                    // solde / crédits / erreur : on garde le JSON tel quel (aucune clé n'y figure), tronqué
                    row["reponse"] = String(SecretsGuard.redact(String(decoding: d, as: UTF8.self)).prefix(600))
                }
            } else {
                row["reponse"] = String(SecretsGuard.redact(String(decoding: d, as: UTF8.self)).prefix(300))
            }
            out.append(row)
        }
        let docP: [String: Any] = ["generated": nowISO(), "fournisseurs": out]
        try? jsonData(docP).write(to: URL(fileURLWithPath: root + "/releves/diag/fournisseurs.json"))
    }

    static func tick(router: Router) {
        let root: String = NSHomeDirectory() + "/spark-local/Nova2"
        DesignImageGen.tick(root: root)   // 30/10 : dormant/IMAGE_GEN.json → images de design (Muse Image, clé Meta)
        // 29/10 (contrôle complet à crédits minimaux) : état global de Nova toutes les 10 min, SANS cerveau — intégrations,
        // Éclats (actifs / en pause / derniers runs), dépense, réglages non secrets. Lecture : releves/diag/etat_global.json.
        if Int(Date().timeIntervalSince1970) % 600 < 60 {
            var g: [String: Any] = ["generated": nowISO(), "integrations": IntegrationWatch.state(), "depense": LLMSpend.summary()]
            let dl: [[String: Any]] = JSONFile("dots.json").read(default: [[String: Any]]())
            let runs: [[String: Any]] = JSONFile("dots_runs.json").read(default: [[String: Any]]())
            var dotRows: [[String: Any]] = []
            for d in dl {
                let id: String = (d["id"] as? String) ?? ""
                let last = runs.last(where: { (($0["dot"] as? String) ?? ($0["id"] as? String) ?? "") == id })
                dotRows.append(["id": id, "nom": (d["name"] as? String) ?? "", "pause": (d["paused"] as? Bool) ?? false, "horaire": (d["schedule"] as? String) ?? "",
                                "cerveau": (d["brain"] as? String) ?? "", "dernier_run": (last?["ts"] as? String) ?? "", "dernier_ok": ((last?["ok"] as? Bool).map { (b: Bool) -> Any in b }) ?? NSNull(),
                                "dernier_statut": (last?["status"] as? String) ?? (last?["statut"] as? String) ?? ""])
                // 31/10 (diag Éclats) : QUI a posé la pause (métadonnées seules, aucun contenu) et passages du jour avec durées.
                var extra: [String: Any] = [:]
                for k in ["pause_auto", "paused_by", "paused_at", "paused_until", "merged_into", "retired", "on_demand", "delegation", "until"] { if let v = d[k] { extra[k] = v } }
                if let pm = d["pause_motif"] as? String, !pm.isEmpty { extra["pause_motif"] = String(pm.prefix(200)) }
                let today: String = String(nowISO().prefix(10))
                let mineToday: [[String: Any]] = runs.filter { (($0["dot"] as? String) ?? "") == id && (($0["ts"] as? String) ?? "").hasPrefix(today) }
                if !mineToday.isEmpty {
                    let ms: [Int] = mineToday.compactMap { $0["ms"] as? Int }.sorted()
                    extra["runs_aujourdhui"] = mineToday.count
                    if !ms.isEmpty { extra["duree_s_mediane"] = ms[ms.count / 2] / 1000; extra["duree_s_max"] = (ms.last ?? 0) / 1000 }
                }
                if !extra.isEmpty { dotRows[dotRows.count - 1].merge(extra) { (_: Any, n: Any) -> Any in n } }
            }
            g["eclats"] = dotRows
            g["runs_24h"] = ["total": runs.filter { (($0["ts"] as? String) ?? "") > ISO8601DateFormatter().string(from: Date().addingTimeInterval(-86400)) }.count,
                             "echecs": runs.filter { (($0["ts"] as? String) ?? "") > ISO8601DateFormatter().string(from: Date().addingTimeInterval(-86400)) && ($0["ok"] as? Bool) == false }.count]
            let st: [String: Any] = Settings().all()
            let keep: [String] = ["brain", "dots_brain", "brains_lock", "brains_off", "demo_mode", "economy_mode", "autorisation_totale", "quiet_from", "quiet_to", "briefs", "dots_auto", "dots_plafond", "tri_rapide", "auto_eval", "budget_llm_mois_usd", "budget_fond_jour_usd", "voice_enabled", "brouillons_auto"]
            var sub: [String: Any] = [:]
            for k in keep { if let v = st[k] { sub[k] = v } }
            g["reglages"] = sub
            g["briefs_etat"] = JSONFile("briefs_etat.json").read(default: [String: String]())
            try? jsonData(g).write(to: URL(fileURLWithPath: root + "/releves/diag/etat_global.json"))
        }
        // 29/10 (« réponse inexploitable », lenteurs) : fin du journal des cerveaux recopiée pour diagnostic — métadonnées seules
        // (cerveau, durée, jetons, erreurs masquées), jamais le texte des conversations.
        if let d: Data = try? Data(contentsOf: router.journal.url) {
            let tailD: Data = d.count > 60_000 ? d.suffix(60_000) : d
            let lines: [String] = String(decoding: tailD, as: UTF8.self).components(separatedBy: "\n").filter { $0.hasPrefix("{") }.suffix(80).map { String($0) }
            try? Data((lines.joined(separator: "\n") + "\n").utf8).write(to: URL(fileURLWithPath: root + "/releves/diag/cerveaux_journal_fin.jsonl"))
        }
        // 29/10 (Ahadi : « comment évalues-tu la qualité, la pertinence et la rapidité des recherches de Nova ? ») —
        // banc de recherche : dormant/SEARCH_BENCH.json {"queries":[…]} → le VRAI outil web_search de Nova, chronométré.
        let sb: String = root + "/dormant/SEARCH_BENCH.json"
        if FileManager.default.fileExists(atPath: sb), let t = ABBench.tools,
           let sd: Data = try? Data(contentsOf: URL(fileURLWithPath: sb)), let so: [String: Any] = parseJSON(sd) {
            try? FileManager.default.removeItem(atPath: sb)
            let qs: [String] = (so["queries"] as? [String]) ?? []
            var srows: [[String: Any]] = []
            for q in qs.prefix(12) {
                let t0: Date = Date()
                let out: String = t.toolWebSearch(q)
                let ms: Int = Int(Date().timeIntervalSince(t0) * 1000)
                let first: String = out.components(separatedBy: "\n").first ?? ""
                let n: Int = out.components(separatedBy: "\n- ").count - 1
                let row: [String: Any] = ["q": q, "ms": ms, "moteur": String(first.prefix(80)), "resultats": n, "texte": String(out.prefix(2500))]
                srows.append(row)
            }
            let sdoc: [String: Any] = ["generated": nowISO(), "tavily_disjoncteur_ouvert": Credits.isOpen("tavily"), "rows": srows]
            try? jsonData(sdoc).write(to: URL(fileURLWithPath: root + "/releves/diag/recherche_banc.json"))
        }
        // 29/10 — dormant/RELAIS_TEST {"q":"…"} : la chaîne mémoire → Algolia puis copie locale ; on note qui répond, en combien de temps, combien de résultats.
        let rt: String = root + "/dormant/RELAIS_TEST"
        if FileManager.default.fileExists(atPath: rt) {
            let q0: String = ((try? String(contentsOfFile: rt, encoding: .utf8)) ?? "BRVM").trimmingCharacters(in: .whitespacesAndNewlines)
            try? FileManager.default.removeItem(atPath: rt)
            let q: String = q0.isEmpty ? "BRVM" : String(q0.prefix(200))
            let t0: Date = Date()
            let al: [[String: Any]]? = AlgoliaRelay.search(q, k: 5)
            let msA: Int = Int(Date().timeIntervalSince(t0) * 1000)
            let t1: Date = Date()
            let loc: [[String: Any]]? = Credits.localSemanticSearch(q, k: 5)
            let msL: Int = Int(Date().timeIntervalSince(t1) * 1000)
            let titresA: [String] = (al ?? []).map { (h: [String: Any]) -> String in String(((h["title"] as? String) ?? "").prefix(80)) }
            let titresL: [String] = (loc ?? []).map { (h: [String: Any]) -> String in String(((h["title"] as? String) ?? "").prefix(80)) }
            let r: [String: Any] = ["generated": nowISO(), "requete": q, "algolia_ms": msA, "algolia_resultats": titresA.count, "algolia_titres": titresA,
                                    "local_ms": msL, "local_resultats": titresL.count, "local_titres": titresL]
            try? jsonData(r).write(to: URL(fileURLWithPath: root + "/releves/diag/relais_test.json"))
        }
        // 29/10 : état de chaque cerveau du catalogue, pour le diagnostic (aucune clé, seulement le motif).
        var etat: [[String: Any]] = []
        for id in router.catalogIds() {
            let w: String = router.whyUnusable(id)
            let e: [String: Any] = ["id": id, "utilisable": w.isEmpty, "motif": w]
            etat.append(e)
        }
        let doc: [String: Any] = ["generated": nowISO(), "cerveaux": etat]
        try? jsonData(doc).write(to: URL(fileURLWithPath: root + "/releves/diag/cerveaux_etat.json"))
        // 29/10 (Ahadi : « j'ai des crédits et clés Tavily… vérifie les branchements ») — présence des clés au Trousseau,
        // NOMS SEULEMENT (jamais la valeur, jamais un fragment), relevée une fois par minute.
        let refs: [(String, KeyRef)] = [
            ("spark", KnownKeys.spark),
            ("sparkNova", KnownKeys.sparkNova),
            ("metaModelAPI", KnownKeys.metaModelAPI),
            ("hf", KnownKeys.hf),
            ("hfNova", KnownKeys.hfNova),
            ("basetenNova", KnownKeys.basetenNova),
            ("braveNova", KnownKeys.braveNova),
            ("tavilyNova", KnownKeys.tavilyNova),
            ("sentryDSN", KnownKeys.sentryDSN),
            ("algoliaApp", KnownKeys.algoliaApp),
            ("algoliaSearch", KnownKeys.algoliaSearch),
            ("amplitudeAPI", KnownKeys.amplitudeAPI),
            ("zoho", KnownKeys.zoho)
        ]
        var cles: [[String: Any]] = []
        let ks: KeychainStore = KeychainStore()
        let doKeys: Bool = Date().timeIntervalSince(ABBench.lastKeys) > 600
        if doKeys { ABBench.lastKeys = Date() }
        for (nom, ref) in refs where doKeys {
            let present: Bool = !((ks.value(ref) ?? "").isEmpty)
            let e: [String: Any] = ["cle": nom, "service": ref.service, "presente": present]
            cles.append(e)
        }
        let docK: [String: Any] = ["generated": nowISO(), "cles": cles]
        if doKeys { try? jsonData(docK).write(to: URL(fileURLWithPath: root + "/releves/diag/cles_etat.json")) }
        if doKeys { ABBench.probeProviders(root: root, ks: ks) }
        if doKeys { AlgoliaRelay.syncIfNeeded() }   // 29/10 : relais Algolia de la mémoire — versement dès que les clés sont là
        let reqPath: String = root + "/dormant/AB_REQUEST.json"
        guard FileManager.default.fileExists(atPath: reqPath),
              let d: Data = try? Data(contentsOf: URL(fileURLWithPath: reqPath)),
              let o: [String: Any] = parseJSON(d) else { return }
        let donePath: String = root + "/dormant/AB_REQUEST.done.json"
        try? FileManager.default.removeItem(atPath: donePath)
        try? FileManager.default.moveItem(atPath: reqPath, toPath: donePath)
        let brains: [String] = (o["brains"] as? [String]) ?? []
        let cases: [[String: Any]] = (o["cases"] as? [[String: Any]]) ?? []
        let outPath: String = root + "/releves/diag/ab_resultats.json"
        let sys: String = Persona.system(title: "Ahadi", memory: "", voice: false, tools: false)
        var rows: [[String: Any]] = []
        let started0: String = nowISO()
        for b in brains {
            let usable: Bool = router.usable(b)
            for c in cases {
                let cid: String = (c["id"] as? String) ?? "?"
                let prompt: String = (c["prompt"] as? String) ?? ""
                var row: [String: Any] = ["brain": b, "case": cid, "usable": usable]
                if !usable {
                    row["error"] = "cerveau inutilisable : " + router.whyUnusable(b)
                    rows.append(row)
                    continue
                }
                let t0: Date = Date()
                let det: (result: (text: String, brain: String)?, error: String?) = router.completeDetailed(
                    messages: [ChatMsg("user", prompt)], system: sys, mode: "fast",
                    preferred: b, maxTokens: 3000, deadline: 150, solo: true)
                let ms: Int = Int(Date().timeIntervalSince(t0) * 1000)
                row["ms"] = ms
                if let r = det.result {
                    row["text"] = SecretsGuard.redact(r.text)
                    row["served_by"] = r.brain
                    row["chars"] = r.text.count
                } else {
                    row["error"] = String((det.error ?? "aucune réponse").prefix(300))
                }
                rows.append(row)
                let snap: [String: Any] = ["started": started0, "updated": nowISO(), "done": false, "rows": rows]
                try? jsonData(snap).write(to: URL(fileURLWithPath: outPath))
            }
        }
        let fin: [String: Any] = ["started": started0, "updated": nowISO(), "done": true, "rows": rows]
        try? jsonData(fin).write(to: URL(fileURLWithPath: outPath))
        var rec: [String: Any] = [:]
        rec["tool"] = "banc_cerveaux"; rec["actor"] = "Nova"; rec["ok"] = true; rec["effect"] = "lecture"
        rec["why"] = "banc des cerveaux (cas fictifs) demandé par Ahadi"
        rec["result"] = String(rows.count) + " essais"
        _ = BlackBox.record(rec)
    }
}
