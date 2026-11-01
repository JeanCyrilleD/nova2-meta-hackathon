import Foundation
import NovaFoundation

/// 31/10 01:41 (Ahadi : « vas-y et teste aussi [tiers] en cerveau principal ainsi qu'Argon ») — BANC AGENT.
/// Chaque cerveau joue le rôle de cerveau PRINCIPAL de Nova sur de vraies demandes, par le chemin normal du chat
/// (/api/chat : même consigne, mêmes OUTILS réels, mêmes garde-fous), en conversation « hors mémoire ».
/// Demandes en LECTURE SEULE (mails, agenda, BRVM, état de Nova, web). Pendant le banc, les confirmations du moteur
/// restent actives même si « autorisation_totale » est allumé (en-tête x-nova-banc → Tools.fullAuto = faux sur ce fil).
/// Déclenchement : dormant/AGENT_BENCH.json {"cerveaux":[…], "correcteurs":[…], "cas":[{"id","demande","critere"}]}
/// Résultats : releves/diag/banc_agent.json (au fil de l'eau). Notation croisée : jamais par la famille du cerveau.
extension NovaApp {
    func agentBenchStart() {
        let root: String = NSHomeDirectory() + "/spark-local/Nova2"
        Thread.detachNewThread { [weak self] in
            Thread.sleep(forTimeInterval: 5)
            Eveil.tick(root: root)   // 31/10 : rester éveillé dès le démarrage si demandé
            CafuMode.bootstrap()   // 31/10 (CAFU) : skill cafu-note-quality-v2 au magasin + notes CAFU versées dans l'index Algolia nova-cafu
            while true {
                Eveil.tick(root: root)
                self?.applySettingsRequest(root: root)
                self?.cafuTestPoll(root: root)   // 31/10 (CAFU) : dormant/CAFU_TEST_REQUEST → releves/diag/cafu_test.json
                self?.voixTestPoll(root: root)   // 01/11 (voix-test) : dormant/VOIX_TEST_REQUEST → releves/diag/voix_test.json
                AlgoliaBiblio.tick(root: root)   // 31/10 (Algolia biblio) : dormant/ALGOLIA_REARM, diag du disjoncteur, ingestion de fond nova-bibliotheque
                let req: String = root + "/dormant/AGENT_BENCH.json"
                if let d = try? Data(contentsOf: URL(fileURLWithPath: req)), let o = parseJSON(d) {
                    try? FileManager.default.removeItem(atPath: root + "/dormant/AGENT_BENCH.done.json")
                    try? FileManager.default.moveItem(atPath: req, toPath: root + "/dormant/AGENT_BENCH.done.json")
                    self?.agentBenchRun(o, root: root)
                }
                Thread.sleep(forTimeInterval: 30)
            }
        }
    }

    /// 31/10 (audit, GO d'Ahadi « applique des corrections ») — DEMANDE DE RÉGLAGES SANS ÉCRAN.
    /// dormant/REGLAGES_REQUEST.json {"brain": "...", ...} : seules les clés de la liste blanche sont appliquées
    /// (cerveaux et budgets — jamais de clé, jeton ni mot de passe). Résultat : dormant/REGLAGES_REQUEST.done.json.
    static let settingsWhitelist: Set<String> = ["brain", "dots_brain", "budget_llm_mois_usd", "budget_fond_jour_usd", "budget_banc_jour_usd", "brains_off", "cafu_mode", "cafu_algolia_obligatoire", "algolia_mac_index", "algolia_plafond_par_passe", "meta_only"]   // 31/10 (CAFU) : interrupteurs du mode CAFU ; 31/10 (Algolia biblio) : indexation du Mac + plafond par passe
    func applySettingsRequest(root: String) {
        let req: String = root + "/dormant/REGLAGES_REQUEST.json"
        guard let d = try? Data(contentsOf: URL(fileURLWithPath: req)), let o = parseJSON(d) else { return }
        try? FileManager.default.removeItem(atPath: req)
        var patch: [String: Any] = [:]
        var refused: [String] = []
        for (k, v) in o { if NovaApp.settingsWhitelist.contains(k) { patch[k] = v } else { refused.append(k) } }
        let before: [String: Any] = settings.all()
        if !patch.isEmpty { settings.set(patch) }
        var avant: [String: Any] = [:]
        for k in patch.keys { avant[k] = before[k] ?? NSNull() }
        _ = BlackBox.record(["tool": "reglages_request", "actor": "Claude", "ok": true, "effect": "config",
                             "why": "demande de réglages sans écran (audit 31/10)", "result": patch.keys.sorted().joined(separator: ", ")])
        try? jsonData(["applique": patch, "avant": avant, "refuse": refused, "ts": nowISO()])
            .write(to: URL(fileURLWithPath: root + "/dormant/REGLAGES_REQUEST.done.json"))
    }

    /// Un tour de chat réel, lu en flux : cerveau servi, relais, outils appelés, cartes de confirmation, texte final.
    func agentBenchTurn(brain: String, text: String) -> [String: Any] {
        var row: [String: Any] = ["cerveau_demande": brain]
        guard server.port > 0, let url = URL(string: "http://127.0.0.1:" + String(server.port) + "/api/chat") else { row["erreur"] = "serveur local pas prêt"; return row }
        var r: URLRequest = URLRequest(url: url)
        r.httpMethod = "POST"
        r.setValue("application/json", forHTTPHeaderField: "Content-Type")
        r.setValue(server.token, forHTTPHeaderField: "x-nova-token")
        r.setValue("1", forHTTPHeaderField: "x-nova-banc")
        r.httpBody = jsonData(["text": text, "brain": brain, "incognito": true, "tools": true, "mode": "fast", "autonomie": "cowork"])
        let lock: NSLock = NSLock()
        var buf: Data = Data()
        let t0: Date = Date()
        let res: HTTPResult = HTTPStream.run(r, firstByteTimeout: 60, idleTimeout: 240, totalTimeout: 600) { (d: Data) -> Bool in
            lock.lock(); buf.append(d); lock.unlock(); return true
        }
        row["ms"] = Int(Date().timeIntervalSince(t0) * 1000)
        if res.status != 200 { row["erreur"] = res.error ?? ("HTTP " + String(res.status)) }
        lock.lock(); let raw: String = String(decoding: buf, as: UTF8.self); lock.unlock()
        var answer: String = "", served: [String] = [], tools: [[String: Any]] = [], failovers: [String] = [], confirms: Int = 0, errs: [String] = []
        for block in raw.components(separatedBy: "\n\n") {
            var ev: String = "", data: String = ""
            for l in block.components(separatedBy: "\n") {
                if l.hasPrefix("event: ") { ev = String(l.dropFirst(7)) } else if l.hasPrefix("data: ") { data += String(l.dropFirst(6)) }
            }
            guard !ev.isEmpty, let o = parseJSON(Data(data.utf8)) else { continue }
            switch ev {
            case "brain": if let id = o["id"] as? String, !served.contains(id) { served.append(id) }
            case "delta": answer += (o["t"] as? String) ?? ""
            case "reset": answer = ""
            case "tool": tools.append(["nom": o["name"] ?? "", "entree": String(((o["input"] as? String) ?? "").prefix(200)), "sortie": String(((o["output"] as? String) ?? "").prefix(12000))])
            case "failover": failovers.append(((o["from"] as? String) ?? "?") + " → " + ((o["to"] as? String) ?? "?") + " : " + String(((o["reason"] as? String) ?? "").prefix(120)))
            case "confirm": confirms += 1
            case "error": errs.append(String(((o["message"] as? String) ?? "").prefix(200)))
            case "done": if let id = o["brain"] as? String, !served.contains(id) { served.append(id) }
            default: break
            }
        }
        row["cerveaux_servis"] = served
        row["outils"] = tools
        row["nb_outils"] = tools.count
        row["relais"] = failovers
        row["cartes_go"] = confirms
        if !errs.isEmpty { row["erreurs"] = errs }
        row["reponse"] = String(SecretsGuard.redact(answer).prefix(12000))
        row["chars"] = answer.count
        row["servi_par_le_bon"] = served.last == brain && failovers.isEmpty
        return row
    }

    static let agentGraderSys: String = """
    Tu es le correcteur du banc AGENT de Nova, l'assistant d'Ahadi (analyste humanitaire au Burkina Faso, standards CAFU).
    On te donne la DEMANDE d'Ahadi, le CRITÈRE de réussite, la TRACE des outils réellement appelés (avec leurs sorties brutes)
    et la RÉPONSE finale de Nova. La trace fait foi : tout fait de la réponse absent des sorties d'outils est une invention.
    Note de 1 à 5, avec sévérité :
    - outils : les bons outils, bien enchaînés, sans appel inutile ; a cherché l'information au lieu de dire « je ne peux pas » ;
    - fidelite : les faits qui DOIVENT venir des outils (expéditeurs, sujets, heures, dates, montants, cours, sources web) sont exacts
      et présents dans les sorties ; un élément de contexte général (projets, collègues, organisation d'Ahadi) peut venir de la
      mémoire de Nova, non montrée ici : ne le compte pas comme invention s'il est plausible ;
    - completude : la demande est entièrement traitée selon le CRITÈRE ;
    - forme : réponse claire, utile, longueur adaptée (CAFU pour une note).
    Réponds UNIQUEMENT par un objet JSON, sans texte autour :
    {"outils":n,"fidelite":n,"completude":n,"forme":n,"commentaire":"25 mots maximum"}
    """

    func agentBenchGrade(judge: String, demande: String, critere: String, row: [String: Any]) -> [String: Any]? {
        var trace: String = ""
        for t in (row["outils"] as? [[String: Any]]) ?? [] {
            trace += "• " + ((t["nom"] as? String) ?? "") + "(" + ((t["entree"] as? String) ?? "") + ")\n  → " + ((t["sortie"] as? String) ?? "") + "\n"
            if trace.count > 40000 { trace += "…(trace tronquée : la suite des sorties n'est pas montrée — ne compte PAS comme invention un fait qui pourrait s'y trouver)\n"; break }
        }
        if trace.isEmpty { trace = "(aucun outil appelé)" }
        let user: String = "DEMANDE :\n" + demande + "\n\nCRITÈRE :\n" + critere + "\n\nTRACE DES OUTILS :\n" + trace + "\nRÉPONSE :\n" + String(((row["reponse"] as? String) ?? "").prefix(8000))
        LLMSpend.setInteractive(true); LLMSpend.setBench(true)
        let det = router.completeDetailed(messages: [ChatMsg("user", user)], system: NovaApp.agentGraderSys, mode: "bulk",
                                          preferred: judge, maxTokens: 3000, deadline: 120, solo: true)
        LLMSpend.setInteractive(false); LLMSpend.setBench(false)
        guard let r = det.result, r.brain == judge, let a = r.text.firstIndex(of: "{"), let b = r.text.lastIndex(of: "}"), a < b,
              let o = parseJSON(Data(String(r.text[a...b]).utf8)) else { return nil }
        func n(_ k: String) -> Int {
            if let i = o[k] as? Int { return max(1, min(5, i)) }
            if let d = o[k] as? Double { return max(1, min(5, Int(d.rounded()))) }
            return 1
        }
        return ["correcteur": judge, "outils": n("outils"), "fidelite": n("fidelite"), "completude": n("completude"), "forme": n("forme"),
                "commentaire": String(((o["commentaire"] as? String) ?? "").prefix(220))]
    }

    func agentBenchRun(_ cfg: [String: Any], root: String) {
        let brains: [String] = (cfg["cerveaux"] as? [String]) ?? []
        let judges: [String] = (cfg["correcteurs"] as? [String]) ?? ["wonder-1.0"]
        let cases: [[String: Any]] = (cfg["cas"] as? [[String: Any]]) ?? []
        let out: String = root + "/releves/diag/banc_agent.json"
        let started: String = nowISO()
        let b0 = LLMSpend.benchToday()
        let lock: NSLock = NSLock()
        var results: [String: [[String: Any]]] = [:]
        func save(_ done: Bool) {
            lock.lock(); let snap = results; lock.unlock()
            let b1 = LLMSpend.benchToday()
            try? jsonData(["started": started, "updated": nowISO(), "done": done, "cerveaux": brains, "correcteurs": judges,
                           "resultats": snap, "cout_banc_usd": QualiteNuit.r2(b1.usd - b0.usd)]).write(to: URL(fileURLWithPath: out))
        }
        _ = BlackBox.record(["tool": "banc_agent", "actor": "Nova", "ok": true, "effect": "lecture",
                             "why": "banc agent : " + String(cases.count) + " demandes en lecture seule, cerveaux " + brains.joined(separator: ", ")])
        let group: DispatchGroup = DispatchGroup()
        for b in brains {
            group.enter()
            Thread.detachNewThread { [weak self] in
                defer { group.leave() }
                guard let self = self else { return }
                let own: [String] = judges.filter { QualiteNuit.famille($0) != QualiteNuit.famille(b) }
                for c in cases {
                    let demande: String = (c["demande"] as? String) ?? ""
                    var row: [String: Any] = self.agentBenchTurn(brain: b, text: demande)
                    row["id"] = c["id"] ?? ""
                    if (row["servi_par_le_bon"] as? Bool) == true, !((row["reponse"] as? String) ?? "").isEmpty {
                        var gs: [[String: Any]] = []
                        for j in own { if let g = self.agentBenchGrade(judge: j, demande: demande, critere: (c["critere"] as? String) ?? "", row: row) { gs.append(g) } }
                        row["notes"] = gs
                    } else {
                        row["non_note"] = "réponse servie par un autre cerveau, vide ou en erreur"
                    }
                    lock.lock(); results[b, default: []].append(row); lock.unlock()
                    save(false)
                }
            }
        }
        group.wait()
        save(true)
    }
}
