import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
#if os(macOS)
import ApplicationServices
#endif
import NovaFoundation

/* DÉCOUPAGE App.swift (29/10, engagement de découpage honoré) : routes mémoire, skills et savoir.
   Méthode extraite telle quelle de App.swift — extension du même type NovaApp, même module :
   ZÉRO changement de comportement. Recette : swift build + swift test + verify.sh verts. */

extension NovaApp {
    func routesMemorySkills(_ s: HTTPServer) {
        s.on("GET", "/api/memory") { [self] _, res in res.json(["items": memory.list()]) }
        s.on("POST", "/api/memory/add") { [self] req, res in res.json(["item": memory.add(req.json["text"] as? String ?? "") as Any? ?? NSNull()]) }
        s.on("POST", "/api/memory/remove") { [self] req, res in memory.remove(req.json["id"] as? String ?? ""); res.json(["ok": true]) }
        // Décision oui/non → règle mémorisée. Une règle ne peut jamais autoriser envoi, paiement, mot de passe ni finance.
        s.on("POST", "/api/decision") { [self] req, res in
            let regle = (req.json["regle"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            guard !regle.isEmpty, regle.count <= 300 else { res.json(["ok": false, "error": "règle vide ou trop longue"], status: 400); return }
            if regle.lowercased().range(of: #"\b(envoy|envoi|paie|virement|mot de passe|password|financ|banque|iban|achat|vente|ordre (de|d.)achat|ordre de bourse)"#, options: .regularExpression) != nil {
                res.json(["ok": false, "error": "Une règle ne peut pas autoriser envois, paiements, mots de passe ni finances."], status: 403); return }
            let item = memory.add("Décision : " + regle, source: "décision")
            res.json(["ok": item != nil, "item": (item as Any?) ?? NSNull()]) }
        // Historique des règles : ce que Nova peut faire, et les règles mémorisées (lecture seule)
        s.on("GET", "/api/rules") { [self] _, res in
            let regles = memory.list().filter { ($0["source"] as? String) == "décision" }
            res.json(["autorisation_totale": settings.get("autorisation_totale", false),
                      "file_envoi": "Chaque envoi attend ton aperçu et ta confirmation « ENVOYER ».",
                      "interdits_en_dur": ["mots de passe", "envois de mails et messages", "paiements", "finances"],
                      "regles": regles]) }
        s.on("POST", "/api/memory/update") { [self] req, res in
            let ok = memory.update(req.json["id"] as? String ?? "", text: req.json["text"] as? String ?? ""); res.json(["ok": ok], status: ok ? 200 : 404) }
        s.on("POST", "/api/conversations/rename") { [self] req, res in
            let ok = convs.rename(req.json["id"] as? String ?? "", title: req.json["title"] as? String ?? ""); res.json(["ok": ok], status: ok ? 200 : 404) }
        s.on("POST", "/api/conversations/pin") { [self] req, res in   // 27/10 : épingler/désépingler un fil (Store.setPinned)
            let ok = convs.setPinned(req.json["id"] as? String ?? "", (req.json["pinned"] as? Bool) ?? false); res.json(["ok": ok], status: ok ? 200 : 404) }
        s.on("POST", "/api/drafts/remove") { [self] req, res in   // supprime un brouillon (jamais un envoi) ; modifiable via /api/drafts/update
            let id = req.json["id"] as? String ?? ""; var l = tools.drafts.read(default: [[String: Any]]()); let n = l.count
            l.removeAll { ($0["id"] as? String) == id }; tools.drafts.write(l); res.json(["ok": l.count < n]) }
        s.on("POST", "/api/drafts/update") { [self] req, res in   // P-DRAFT-2 (re-préparé v6) : édite un brouillon EN ATTENTE — un « envoyé » est non modifiable (409) ; toute édition recalcule coche + empreinte
            let id = req.json["id"] as? String ?? ""; var l = tools.drafts.read(default: [[String: Any]]())
            guard let i = l.firstIndex(where: { ($0["id"] as? String) == id }) else { res.json(["ok": false, "error": "brouillon introuvable"], status: 404); return }
            if let st = l[i]["status"] as? String, st.lowercased().hasPrefix("envoy") { res.json(["ok": false, "error": "brouillon déjà envoyé — non modifiable"], status: 409); return }
            for k in ["subject", "body", "to", "target"] { if let v = req.json[k] as? String { l[i][k] = v } }
            DraftLint.refresh(&l[i])   // l'aperçu validé ne couvre plus l'ancien contenu : nouvelle empreinte (P-DRAFT-3)
            tools.drafts.write(l); res.json(["ok": true, "hash": l[i]["hash"] as? String ?? ""]) }
        s.on("POST", "/api/import/spark") { [self] req, res in
            let base = ((req.json["path"] as? String) ?? "~/spark-local/data") as NSString
            let dir = base.expandingTildeInPath; var n = 0
            for f in ["faits.json", "lecons.json", "memory.json", "objectifs.json"] {
                guard let d = FileManager.default.contents(atPath: dir + "/" + f), let o = try? JSONSerialization.jsonObject(with: d) else { continue }
                let arr: [Any] = (o as? [Any]) ?? ((o as? [String: Any]).map { Array($0.values) } ?? [])
                for it in arr {
                    var t: String? = nil
                    if let s = it as? String { t = s } else if let m = it as? [String: Any] { t = (m["texte"] ?? m["text"] ?? m["fait"] ?? m["titre"] ?? m["nom"] ?? m["lecon"] ?? m["objectif"]) as? String }
                    if let t = t, t.count > 3, memory.add(t, source: "import SparkLocal/" + f) != nil { n += 1 }
                }
            }
            res.json(["imported": n, "from": dir])
        }

        // Briefs
        s.on("GET", "/api/briefs") { [self] _, res in res.json(["items": briefs.list()]) }
        s.on("POST", "/api/briefs/run") { [self] req, res in
            let kind = (req.json["kind"] as? String) ?? "matin"
            let label = (settings.get("briefs", [[String: Any]]()).first { ($0["kind"] as? String) == kind }?["label"] as? String) ?? "Brief"
            res.json(briefs.generate(kind: kind, label: label, manual: true))
        }
        s.on("POST", "/api/briefs/read") { [self] req, res in briefs.markRead(req.json["id"] as? String ?? ""); res.json(["ok": true]) }
        s.on("POST", "/api/assistant/state") { [bus] req, res in bus.publish("assistant", req.json); res.json(["ok": true]) }
        // Spéculatif : réponse immédiate, puis pré-calcul du contexte (mémoire + connaissances) réutilisé par /api/chat pendant 15 s.
        s.on("POST", "/api/assistant/speculate") { [self] req, res in
            let text = ((req.json["text"] as? String) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            let k = SpeculativeCache.key(text)
            res.json(["ok": true])
            guard k.count >= 3, text.count <= 4000, SpeculativeCache.shared.begin(k) else { return }
            let m = memory.promptBlock(query: text)
            let kb = Knowledge.shared.hitsBlock(query: text)   // BRAIN-B : la doctrine (stable) est servie avant cacheMark ; ici les seuls extraits liés au message
            SpeculativeCache.shared.put(k, memory: m, knowledge: kb)
        }
        // Lentille contextuelle : app au premier plan (nom + identifiant de paquet), rien d'autre.
        s.on("GET", "/api/system/frontmost") { _, res in
            let f = SystemHooks.frontmostProvider?() ?? ("", "")
            Predict.shared.noteApp(name: f.0, bundle: f.1)   // Phase 8 : historique d'app pour la prédiction (nom seulement)
            res.json(["app": f.0, "bundle": f.1])
        }
        // Auto-test des interrupteurs (dispatchDirect, SQLite WAL, index vectoriel) : chiffres mesurés sur la machine, rien n'est modifié.
        s.on("GET", "/api/system/selftest") { [self] _, res in res.json(NovaSelfTest.run(server: server)) }
        UIPilot.publish = { [bus] ev, o in bus.publish(ev, o) }
        s.on("POST", "/api/ui/result") { req, res in
            // LOT2 P-E1b : contrat explicite — un constat non emballé ou malformé est une ERREUR (400), jamais un ok:true silencieux.
            let j = req.json
            guard let id = j["id"] as? String, !id.isEmpty, let r = j["result"] as? [String: Any] else {
                res.json(["ok": false, "error": "constat UI malformé : {\"id\": \"…\", \"result\": {…}} attendu — rien n'a été livré à l'outil demandeur"], status: 400); return
            }
            guard UIPilot.shared.deliver(id, r) else {
                res.json(["ok": false, "error": "constat UI pour un ordre inconnu ou expiré (id \(id)) — non livré"], status: 409); return
            }
            res.json(["ok": true])
        }
        // PRO-1 (E3-S3) : le fil proactif, relisible après relance. since = curseur ISO optionnel.
        s.on("GET", "/api/proactive/feed") { [self] req, res in
            // SPEC ÉVÉNEMENTS DANS LE CHAT (21/10, §4.6) : le web apprend ici quel fil est
            // le Fil direct — prochat.js s'en sert pour ne pas doubler en carte un événement
            // déjà matérialisé dans ce fil par le matérialiseur.
            res.json(["items": ProactiveFeed.list(limit: Int(req.query["limit"] ?? "") ?? 50, since: req.query["since"] ?? ""),
                      "direct_thread_id": settings.get("direct_thread_id", "")])
        }
        s.on("GET", "/api/events") { [self] _, res in res.sseStart(); res.sse("hello", ["ts": nowISO()]); bus.add(res); while !res.clientGone { Thread.sleep(forTimeInterval: 1) } }

        // Dots
        s.on("GET", "/api/dots") { [self] _, res in
            // 26/10 : les 30 derniers passages + le dernier passage de chaque Éclat qui n'y figure pas (sinon « jamais passé » à tort).
            let hist: [[String: Any]] = dots.history()
            var runs: [[String: Any]] = Array(hist.prefix(30))
            var seen: Set<String> = Set(runs.compactMap { (r: [String: Any]) -> String? in r["dot"] as? String })
            for r in hist.dropFirst(30) {
                guard let d: String = r["dot"] as? String, !seen.contains(d) else { continue }
                seen.insert(d); runs.append(r)
            }
            res.json(["items": dots.list(), "runs": runs])
        }
        s.on("GET", "/api/dots/waiting") { [self] _, res in res.json(["items": scheduler.waiting()]) }
        s.on("POST", "/api/dots/snooze") { [self] req, res in scheduler.snooze(runId: req.json["run_id"] as? String ?? "", minutes: (req.json["minutes"] as? Int) ?? 15); res.json(["ok": true]) }
        s.on("GET", "/api/memory/settings") { [self] _, res in res.json(memory.settings()) }
        s.on("POST", "/api/memory/settings") { [self] req, res in
            memory.configure(off: req.json["off"] as? Bool, sensitiveDays: req.json["sensitive_days"] as? Int)
            let n = memory.purgeExpired(); var o = memory.settings(); o["purged"] = n; res.json(o) }
        // VAGUE 2 FIABILITÉ : doublon retiré — GET /api/memory/export est servi par Feat_MemoireSouveraine (enregistré avant, via extraRoutes : celui-ci n'était jamais atteint).
        // NOVA2-FIX (directive SKILLS) : magasin de skills de la maison (NovaSkills) — écran Savoir › « Ses skills ».
        s.on("GET", "/api/skills") { _, res in res.json(["items": NovaSkills.entries().map { ["name": $0.name, "title": $0.title, "trigger": $0.trigger, "description": $0.summary] }]) }
        s.on("GET", "/api/skills/content") { req, res in
            if let c = NovaSkills.content(req.query["name"] ?? "") { res.json(["name": req.query["name"] ?? "", "content": c]) }
            else { res.json(["error": "skill inconnu"]) } }
        s.on("POST", "/api/skills/save") { req, res in res.json(["ok": NovaSkills.save(name: req.json["name"] as? String ?? "", content: req.json["content"] as? String ?? "")]) }
    }
}
