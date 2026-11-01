import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
#if os(macOS)
import ApplicationServices
#endif
import NovaFoundation

/* DÉCOUPAGE App.swift (29/10, engagement de découpage honoré) : routes des Éclats/Dots (exécution, file, éclats du jour).
   Méthode extraite telle quelle de App.swift — extension du même type NovaApp, même module :
   ZÉRO changement de comportement. Recette : swift build + swift test + verify.sh verts. */

extension NovaApp {
    func routesDots(_ s: HTTPServer) {
        s.on("POST", "/api/dots/import") { [self] req, res in   // import idempotent : ne remplace jamais un Dot existant
            let have = Set(dots.list().compactMap { $0["id"] as? String }); var n = 0
            for d in (req.json["items"] as? [[String: Any]]) ?? [] { if let id = d["id"] as? String, id.hasPrefix("imp-"), !have.contains(id) { dots.save(d); n += 1 } }
            res.json(["imported": n]) }
        s.on("GET", "/api/actions") { _, res in res.json(["items": Array(Tools.actions.tail(300).reversed())]) }
        s.on("POST", "/api/actions/undo") { [self] req, res in res.json(["message": tools.undo(actionId: req.json["id"] as? String ?? "")]) }
        s.on("POST", "/api/dots/ack") { [self] req, res in scheduler.ack(runId: req.json["run_id"] as? String ?? ""); res.json(["ok": true]) }
        s.on("POST", "/api/dots/launch") { [self] req, res in
            guard let d = dots.list().first(where: { ($0["id"] as? String) == (req.json["id"] as? String) }) else { res.json(["error": "Dot introuvable"], status: 404); return }
            let lr: LaunchResult = scheduler.launch(d, task: (d["id"] as? String) == "bilan" ? scheduler.bilanTask() : (req.json["task"] as? String) ?? "", manual: true)
            res.json(["ok": lr.isStarted || lr == .alreadyRunning, "lancement": lr.label, "run_id": lr.runID ?? ""])   // WP1 : issue réelle (déjà en cours = pas de second run)
        }
        // VAGUE 2 FIABILITÉ : Stop RÉEL d'un Éclat en cours — {id} (tous ses runs en vol) ou {run} (un run précis).
        // Le jeton d'arrêt est lu par l'agent entre chaque étape (et par le flux du cerveau) : l'outil en cours se
        // termine, rien d'autre ne part. Pas de pause posée (contrairement à /api/dots/control « stop »). Journalisé.
        s.on("POST", "/api/dots/stop") { [self] req, res in
            let id: String = (req.json["id"] as? String) ?? ""
            let run: String = (req.json["run"] as? String) ?? ((req.json["run_id"] as? String) ?? "")
            if id.isEmpty && run.isEmpty { res.json(["ok": false, "error": "id (Éclat) ou run (exécution) requis"], status: 400); return }
            let targets: [String] = Dots.requestStop(run: run, dot: id)
            let nom: String = (dots.list().first(where: { ($0["id"] as? String) == id })?["name"] as? String) ?? id
            let cible: String = id.isEmpty ? "run " + run : "Éclat " + nom
            _ = BlackBox.record(["tool": "dots_stop", "actor": "Ahadi", "why": "Stop demandé — " + cible + " : " + (targets.isEmpty ? "aucune exécution en cours" : "\(targets.count) exécution(s) visée(s) (" + targets.joined(separator: ", ") + ")"),
                                 "ok": !targets.isEmpty, "effect": targets.isEmpty ? "aucun" : "arrêt"])
            if targets.isEmpty { res.json(["ok": false, "stopped": [String](), "error": "aucune exécution en cours pour cet Éclat"]); return }
            res.json(["ok": true, "stopped": targets, "note": "Arrêt demandé : l'Éclat s'interrompt à la prochaine étape (l'outil en cours se termine)."])
        }
        // PRO-4 : contrôle des Dots par l'agent AVEC état relu après action — la réponse décrit l'état CONSTATÉ,
        // jamais l'état demandé. start → relire en_cours ; stop → pause posée + arrêt du run en cours ; etat → lecture seule.
        s.on("POST", "/api/dots/control") { [self] req, res in
            let id = (req.json["id"] as? String) ?? "", action = (req.json["action"] as? String) ?? "etat"
            guard let d = dots.list().first(where: { ($0["id"] as? String) == id }) else { res.json(["error": "Dot introuvable"], status: 404); return }
            if action == "start" { scheduler.launch(d, task: (req.json["task"] as? String) ?? "", manual: true) }
            if action == "stop" { scheduler.stop(id); var dd = d; dd["paused"] = true; dots.save(dd) }
            if action == "resume" { var dd = d; dd["paused"] = false; dots.save(dd) }
            let relu = dots.list().first(where: { ($0["id"] as? String) == id }) ?? [:]
            let dernier = dots.history(id).first
            res.json(["ok": true, "id": id, "action": action, "verifie": true,
                      "etat_relu": ["paused": (relu["paused"] as? Bool) ?? false, "schedule": (relu["schedule"] as? String) ?? "",
                                    "en_cours": scheduler.isRunning(id), "dernier_run": dernier?["ts"] ?? dernier?["id"] ?? ""]])
        }
        s.on("POST", "/api/dots/save") { [self] req, res in
            var j = req.json; let id = j["id"] as? String ?? ""
            if let old = dots.list().first(where: { ($0["id"] as? String) == id }), DotCharter.isLocked(id: id, settings: settings) {
                for f in DotCharter.lockedFields { if let v = old[f] { j[f] = v } }   // la charte reste intacte ; horaire, pause, cerveau restent modifiables
            }
            j.removeValue(forKey: "persona"); dots.save(j); res.json(["ok": true]) }
        s.on("POST", "/api/dots/remove") { [self] req, res in dots.remove(req.json["id"] as? String ?? ""); res.json(["ok": true]) }
        s.on("POST", "/api/dots/run") { [self] req, res in
            res.sseStart()
            let dotId = req.json["id"] as? String ?? ""
            let dotDef = dots.list().first(where: { ($0["id"] as? String) == dotId })
            // E8-3 / E8-4 (recette n°8, 23/10) : ce lancement direct court-circuitait le
            // cycle de vie du DotScheduler — aucun événement « dot » sur le bus, donc le
            // miroir d'activité du compagnon restait « au repos » (surtout pour un run
            // sans étape d'outil) et la fin du run n'entrait jamais au fil Direct. Le
            // run émet désormais le même cycle que DotScheduler.launch, par la même
            // porte : scheduler.publish (bus + ProactiveFeed « dot.done » + notification),
            // avec la même discrétion RAS et la même file d'attente des décisions.
            var ownRun: String? = nil
            if dotDef != nil {
                // VAGUE 2 FIABILITÉ : run visible « en cours » (halo, écran Éclats) et file automatique en attente.
                // WP1 : même réservation que le planificateur — un Éclat déjà en cours n'est pas relancé par-dessus lui-même.
                let lr: LaunchResult = scheduler.claimExternal(dotId)
                guard let rid = lr.runID else { res.sse("error", ["message": "Éclat " + lr.label + " — rien n'est relancé par-dessus le run en vol"]); res.sse("done", ["run": [String: Any]()]); return }
                ownRun = rid
                scheduler.publish("dot", ["phase": "working", "dot": dotId, "name": dotDef?["name"] ?? "", "emoji": dotDef?["emoji"] ?? "●", "color": dotDef?["color"] ?? "#D93226"])
            }
            let r = dots.run(id: dotId, task: req.json["task"] as? String ?? "", ordered: true, cancel: { res.clientGone }) { ev in   // A1 : lancement direct depuis l'écran = run ordonné
                switch ev {
                case .start(_, let l): res.sse("brain", ["label": l])
                case .delta(let t): res.sse("delta", ["t": t])
                case .tool(let n, let i, let o): res.sse("tool", ["name": n, "input": String(i.prefix(300)), "output": String(o.prefix(600))])
                case .step(let k, let info): res.sse(k, info)   // LOT M
                case .failover(let f, let t, let rr, _): res.sse("failover", ["from": f, "to": t, "reason": rr])
                case .usage(let i, let o): res.sse("usage", ["in": i, "out": o])   // MN2-6 : le coût du run se voit pendant qu'il tourne
                case .error(let m): res.sse("error", ["message": m])
                default: break
                }
            }
            if let rid = ownRun { scheduler.finishExternal(rid, result: r) }
            if (r?["arrete"] as? Bool) == true {   // VAGUE 2 FIABILITÉ : arrêté à la demande — ni notification, ni file de décision
                scheduler.publish("dot", ["phase": "idle", "dot": dotId, "stopped": true])
                res.sse("stopped", ["run": (r?["id"] as? String) ?? ""])
            } else if let d = dotDef {
                let text = (r?["result"] as? String) ?? ""
                let ok = !text.isEmpty && DotCharter.status(of: text) != "ECHEC"
                if DotScheduler.isRAS(text) {
                    scheduler.publish("dot", ["phase": "idle", "dot": dotId])   // FLOTTE V1 : rien à signaler — discret pour tout Éclat (comme DotScheduler.launch)
                } else {
                    let rid = (r?["id"] as? String) ?? UUID().uuidString.prefix(8).lowercased().description
                    let decision: Bool = (r?["decision"] as? Bool) == true
                    if decision {   // FLOTTE V1 : seule une vraie décision entre en file (une par Éclat, la plus récente)
                        var entry: [String: Any] = ["run_id": rid, "dot": dotId, "ts": nowISO()]
                        entry["decision"] = true
                        entry["question"] = (r?["question"] as? String) ?? ""
                        if let sup = r?["supervision"] as? String, !sup.isEmpty { entry["supervision"] = String(sup.prefix(400)) }
                        scheduler.appendPending(entry)
                    }
                    let flat: String = text.replacingOccurrences(of: "\n", with: " ")
                    let summary: String = ok ? String(flat.prefix(600)) : "Je n'ai pas pu produire de résultat (aucun cerveau n'a répondu)."
                    var ev: [String: Any] = ["phase": "ready", "dot": dotId, "run_id": rid, "ok": ok, "summary": summary, "notify": decision]
                    ev["name"] = d["name"] ?? ""
                    ev["emoji"] = d["emoji"] ?? "●"
                    ev["color"] = d["color"] ?? "#D93226"
                    scheduler.publish("dot", ev)
                }
            }
            res.sse("done", ["run": r ?? [:]])
        }
        s.on("GET", "/api/drafts") { [self] _, res in   // P-DRAFT-2 (re-préparé v6) : les brouillons v1 (sans lint/hash) sont enrichis À LA LECTURE, sans réécrire le magasin — la carte peut alors lier son aperçu par l'empreinte (P-DRAFT-3/6) · REVUE-GATE 22/10 : refresh SYSTÉMATIQUE à la lecture (avant : seulement si lint/hash absents) — un verdict calculé par un moteur de lint plus ancien ne doit pas survivre à la mise à jour du moteur (FIX-LINT2 : les 7 brouillons d'origine affichaient des verdicts fossiles de la règle v0, 4 bloqués à tort) ; le coût est trivial à cette échelle (une passe de lexiques par brouillon) et le magasin n'est toujours pas réécrit. La porte d'envoi (hardFailures) recalcule déjà à frais — inchangée
            let l = tools.drafts.read(default: [[String: Any]]())
            let items = l.map { var d = $0; DraftLint.refresh(&d); return d }
            res.json(["items": items, "count": l.count]) }
        Tools.fluxHook = { [settings] q in FluxCatalog.read(q, userFeeds: settings.get("feeds", [String]())) }
        do {   // migration : les anciens flux par défaut (RFI, Le Monde) sont injoignables sur ce réseau → remplacés par leurs équivalents via [tiers] Actualités
            let old = ["https://www.rfi.fr/fr/afrique/rss", "https://www.lemonde.fr/afrique/rss_full.xml"]
            if settings.get("feeds", [String]()) == old { settings.set(["feeds": [FluxCatalog.general[0].url, FluxCatalog.general[1].url, FluxCatalog.general[2].url, "https://reliefweb.int/updates/rss.xml"]]) }
        }
        Tools.pageHook = { [weak self] (raw: String) -> String? in self?.pilotage("page-aller", "page-aller " + raw) }
        // 26/10 (format Muse) : bilans 07:30 · 12:30 · 18:30 — midi activé, soir déplacé à 18:30 (une fois ; Ahadi peut les rechanger).
        if !settings.get("briefs_muse_v1", false) {
            var bl: [[String: Any]] = settings.get("briefs", [[String: Any]]())
            for i in bl.indices {
                let id: String = (bl[i]["id"] as? String) ?? ""
                if id == "midi" { bl[i]["enabled"] = true; bl[i]["time"] = "12:30" }
                if id == "soir" && ((bl[i]["time"] as? String) ?? "") == "18:00" { bl[i]["time"] = "18:30" }
            }
            if !bl.isEmpty { settings.set(["briefs": bl]) }
            settings.set(["briefs_muse_v1": true])
        }
        Tools.brvmHook = {
            let o = VeillePole.brvm(); let d = (try? JSONSerialization.data(withJSONObject: o)) ?? Data()
            // MES VALEURS SUIVIES = toutes les lignes des portefeuilles SBIF (relevés importés), avec le dernier cours BRVM connu
            let v: [String: Any] = VaultFile.isOpen ? VaultFile("vault_portefeuilles.json").read(default: [String: Any]()) : JSONFile("vault_portefeuilles.json").read(default: [String: Any]())   // V3 : lecture chiffrée quand le coffre est ouvert ; sinon l'ancien chemin (fichier clair) — le coffre n'est chiffré que sur ordre
            let quotes = (v["quotes"] as? [String: Any]) ?? [:]
            var rows: [String] = []; var seenSym = Set<String>()
            for (acc, a) in ((v["accounts"] as? [String: Any]) ?? [:]).sorted(by: { $0.key < $1.key }) {
                guard let ad = a as? [String: Any] else { continue }
                for p in (ad["positions"] as? [[String: Any]]) ?? [] {
                    let nm = p["name"] as? String ?? "", sym = p["sym"] as? String ?? ""
                    let q = (p["qty"] as? Double) ?? Double(p["qty"] as? Int ?? 0)
                    let cr = (p["cours_releve"] as? Double) ?? 0
                    let live = (quotes[sym] as? [String: Any]).flatMap { $0["price"] as? Double }
                    let vr = (quotes[sym] as? [String: Any]).flatMap { $0["var"] as? Double }
                    rows.append("• \(nm) [\(sym)] compte …\(String(acc.suffix(4))) : \(Int(q)) titres · cours relevé \(Int(cr))" + (live.map { " · cours BRVM \(Int($0)) FCFA" + (vr.map { " (\($0 >= 0 ? "+" : "")\($0) %)" } ?? "") } ?? " · cours BRVM non rafraîchi"))
                    seenSym.insert(sym)
                }
            }
            let mine = rows.isEmpty ? "MES VALEURS SUIVIES : aucun relevé SBIF importé (dépose les PDF dans ~/Nova-Finances)." : "MES VALEURS SUIVIES (portefeuilles SBIF, \(seenSym.count) valeurs) — au \((v["quotes_at"] as? String) ?? "cours relevé") :\n" + rows.joined(separator: "\n")
            return mine + "\n\nMARCHÉ :\n" + String(String(data: d, encoding: .utf8)?.prefix(4500) ?? "")
        }
    }
}
