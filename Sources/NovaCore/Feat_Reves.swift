import Foundation

// V5-P (25/10) — Rêves validables (#5, bug n°4 de VERIF_AUDIT.md).
// La distillation de 23:30 (Ame.swift → ameThink kind « reve ») écrivait des propositions dans ame_reves.json
// sans aucun moyen de les valider : elles ne devenaient jamais de la mémoire. Ici :
//  · GET  /api/reves             → propositions en attente + état de la dernière distillation ;
//  · POST /api/reves/decider     {id, decision: "garder"|"rejeter", text?} — garder = Memory.add (mécanisme existant,
//                                  versionné par MemoryLedger) ; rejeter = la proposition est retirée du fichier ;
//  · POST /api/reves/lancer      → distiller maintenant (même code que 23:30) ;
//  · rattrapage : si la dernière distillation réussie date de plus de 24 h (Mac endormi à 23:30), la veille de fond
//    (Feat_AmeDocs.ameViveStart, toutes les 5 min) la relance au réveil ou au démarrage.
// Forme de ame_reves.json inchangée ([{id, text, ts, status, …}]) : Feat_Daily (Rituels) la lit telle quelle.

enum ReveState {
    static let file: JSONFile = JSONFile("ame_reves_etat.json")   // {last_ok, last_try, last_origine, last_n, last_error}
    static let lock: NSLock = NSLock()
    nonisolated(unsafe) static var running: Bool = false   // PHASE 1 (relu, protégé) : sous ReveState.lock (pose et retour à faux)
}

extension NovaApp {
    /// Une distillation (23:30, rattrapage ou à la demande). `minGapHours` : ne relance pas si la dernière réussie est plus récente.
    @discardableResult func reveRun(origine: String, minGapHours: Double = 12) -> [String: Any] {
        ReveState.lock.lock()
        if ReveState.running { ReveState.lock.unlock(); let busy: [String: Any] = ["ok": false, "skipped": true, "reason": "distillation déjà en cours"]; return busy }
        var st: [String: Any] = ReveState.file.read(default: [String: Any]())
        if minGapHours > 0, let lastOk = AmeDocParse.date(st["last_ok"]), Date().timeIntervalSince(lastOk) < minGapHours * 3600 {
            ReveState.lock.unlock()
            let skip: [String: Any] = ["ok": false, "skipped": true, "reason": "distillation récente (" + ((st["last_ok"] as? String) ?? "") + ")"]
            return skip
        }
        ReveState.running = true
        st["last_try"] = nowISO()
        ReveState.file.write(st)
        ReveState.lock.unlock()

        let r: [String: Any] = ameThink(kind: "reve", input: "")
        let items: [String] = (r["items"] as? [String]) ?? []
        if !items.isEmpty {
            var l: [[String: Any]] = AmeDocParse.objects(ameDoc("reves"))
            for t in items {
                let o: [String: Any] = ["id": UUID().uuidString.prefix(8).lowercased().description, "text": t, "ts": nowISO(), "status": "proposé", "origine": origine]
                l.append(o)
            }
            JSONFile("ame_reves.json").write(Array(l.suffix(60)))
        }
        ReveState.lock.lock()
        var st2: [String: Any] = ReveState.file.read(default: [String: Any]())
        st2["last_origine"] = origine
        if let e = r["error"] as? String {
            st2["last_error"] = e
        } else {
            st2["last_ok"] = nowISO()
            st2["last_n"] = items.count
            st2.removeValue(forKey: "last_error")
        }
        ReveState.file.write(st2)
        ReveState.running = false
        ReveState.lock.unlock()
        let out: [String: Any] = ["ok": r["error"] == nil, "n": items.count, "origine": origine, "error": (r["error"] as? String) ?? "", "text": (r["text"] as? String) ?? ""]
        return out
    }

    /// Rattrapage : dernière distillation réussie > 24 h (ou jamais, après la première minute de vie), dernier essai > 2 h.
    /// Repère quand l'état n'existe pas encore : l'horodatage de la dernière proposition déjà écrite par l'ancien code.
    func reveCatchUp(now: Date) {
        let st: [String: Any] = ReveState.file.read(default: [String: Any]())
        var ref: Date? = AmeDocParse.date(st["last_ok"])
        if ref == nil, let lastItem = AmeDocParse.objects(ameDoc("reves")).last { ref = AmeDocParse.date(lastItem["ts"]) }
        if let r = ref, now.timeIntervalSince(r) < 24 * 3600 { return }
        if let t = AmeDocParse.date(st["last_try"]), now.timeIntervalSince(t) < 2 * 3600 { return }
        let hh: Int = Calendar.current.component(.hour, from: now)
        if hh == 23 { return }   // la passe régulière de 23:30 s'en charge
        if !Rituels.allows("reve", settings: settings) { return }   // rituel « Rêve » éteint (Feat_Daily, V5-O) : pas de rattrapage non plus
        let rr: [String: Any] = reveRun(origine: "rattrapage", minGapHours: 24)
        if (rr["ok"] as? Bool) == true { Rituels.mark("reve") }
    }

    func revesRoutes() {
        let s = server
        s.on("GET", "/api/reves") { [self] _, res in
            let all: [[String: Any]] = AmeDocParse.objects(ameDoc("reves"))
            let pending: [[String: Any]] = all.filter { (($0["status"] as? String) ?? "proposé") == "proposé" }
            let kept: Int = all.filter { ($0["status"] as? String) == "gardé" }.count
            let body: [String: Any] = ["items": Array(pending.reversed()), "gardes": kept, "etat": ReveState.file.read(default: [String: Any]()),
                                       "memoire_coupee": memory.isOff]
            res.json(body)
        }
        s.on("POST", "/api/reves/decider") { [self] req, res in
            let j: [String: Any] = req.json
            let id: String = (j["id"] as? String) ?? ""
            let decision: String = (j["decision"] as? String) ?? ""
            guard decision == "garder" || decision == "rejeter" else { let e: [String: Any] = ["error": "décision attendue : garder ou rejeter"]; res.json(e, status: 400); return }
            var l: [Any] = JSONFile("ame_reves.json").read(default: [Any]())
            guard let i = l.firstIndex(where: { (($0 as? [String: Any])?["id"] as? String) == id }), var item = l[i] as? [String: Any] else {
                let e: [String: Any] = ["error": "proposition introuvable"]; res.json(e, status: 404); return
            }
            let day: String = String(((item["ts"] as? String) ?? "").prefix(10))
            if decision == "rejeter" {
                l.remove(at: i)
                JSONFile("ame_reves.json").write(l)
                _ = BlackBox.record(["tool": "memoire", "actor": "Ahadi", "why": "Rêve du " + day + " rejeté (proposition retirée, rien retenu)", "ok": true, "effect": "écrit"])
                let ok: [String: Any] = ["ok": true, "decision": "rejeté"]
                res.json(ok); return
            }
            let edited: String = ((j["text"] as? String) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            let text: String = edited.isEmpty ? ((item["text"] as? String) ?? "") : edited
            if text.isEmpty { let e: [String: Any] = ["error": "texte vide"]; res.json(e, status: 400); return }
            if memory.isOff { let e: [String: Any] = ["error": "mémoire coupée (Savoir › Mémoire) : rien ne peut être retenu"]; res.json(e, status: 409); return }
            let added: [String: Any]? = memory.add(text, source: "utilisateur", why: "Rêve du " + day + " gardé par Ahadi (écran Âme)")
            item["status"] = "gardé"
            item["decided"] = nowISO()
            item["text"] = text
            if let a = added, let mid = a["id"] as? String { item["memory_id"] = mid } else { item["note"] = "déjà en mémoire" }
            l[i] = item
            JSONFile("ame_reves.json").write(l)
            _ = BlackBox.record(["tool": "memoire", "actor": "Ahadi", "why": "Rêve du " + day + " gardé → mémoire", "ok": true, "effect": "écrit"])
            let ok: [String: Any] = ["ok": true, "decision": "gardé", "deja": added == nil, "memory_id": (added?["id"] as? String) ?? ""]
            res.json(ok)
        }
        s.on("POST", "/api/reves/lancer") { [self] _, res in
            let r: [String: Any] = reveRun(origine: "à la demande", minGapHours: 0)
            res.json(r)
        }
    }
}
