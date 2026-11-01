import Foundation

// V5-P (25/10) — DEUIL D'UN PROJET (#32, FALSE dans l'audit : la « clôture/leçon » avait été retirée de vie.js).
// Trois temps, aucun automatique :
//  1. POST /api/projects/deuil/proposer {id} → le cerveau rédige un bilan et 3 à 7 leçons à partir du dossier du projet
//     (projects.json), des décisions (decisions.json), de la mémoire et des messages d'Ahadi qui le citent. Proposition
//     gardée dans projets_deuil.json (rien d'autre ne change).
//  2. POST /api/projects/deuil/valider {id, lecons:[String], bilan} → APRÈS relecture d'Ahadi : chaque leçon devient un
//     fait de mémoire (Memory.add, versionné) ; le projet passe aux ARCHIVES (archive = true, auto_off = true : le scan
//     automatique ne l'enrichit plus). Rien n'est effacé.
//  3. POST /api/projects/deuil/restaurer {id} → retour du projet parmi les actifs (réversible) ; les leçons restent en
//     mémoire (elles s'oublient une à une dans Savoir › Mémoire si Ahadi le veut).
// POST /api/projects/deuil/abandonner {id} retire une proposition non validée.

enum DeuilStore {
    static let file: JSONFile = JSONFile("projets_deuil.json")   // {"<id projet>": {bilan, lecons, ts, brain}}
    static let lock: NSLock = NSLock()
}

extension NovaApp {
    func deuilMaterial(_ p: [String: Any]) -> String {
        var parts: [String] = ["DOSSIER DU PROJET :\n" + ProjectMemory.block(p)]
        let names: [String] = ProjectMemory.names(p).filter { $0.count >= 3 }
        func cites(_ t: String) -> Bool {
            for n in names where t.range(of: n, options: [.caseInsensitive, .diacriticInsensitive]) != nil { return true }
            return false
        }
        let dec: [[String: Any]] = JSONFile("decisions.json").read(default: [[String: Any]]())
        var dl: [String] = []
        for d in dec.suffix(200) {
            let q: String = (d["question"] as? String) ?? ""
            let c: String = (d["choix"] as? String) ?? ""
            if cites(q + " " + c) { dl.append("- " + String(q.prefix(160)) + " → " + String(c.prefix(120))) }
        }
        if !dl.isEmpty { parts.append("DÉCISIONS LIÉES :\n" + dl.suffix(15).joined(separator: "\n")) }
        var ml: [String] = []
        for m in memory.list() {
            let t: String = (m["text"] as? String) ?? ""
            if cites(t) { ml.append("- [" + String(((m["ts"] as? String) ?? "").prefix(10)) + "] " + String(t.prefix(240))) }
        }
        if !ml.isEmpty { parts.append("MÉMOIRE LIÉE :\n" + ml.suffix(20).joined(separator: "\n")) }
        var cl: [String] = []
        for (d, t) in ameMessages(days: 365, role: "user", limit: 2000) where cites(t) {
            cl.append("- [" + String(ISO8601DateFormatter().string(from: d).prefix(10)) + "] " + String(t.replacingOccurrences(of: "\n", with: " ").prefix(220)))
            if cl.count >= 25 { break }
        }
        if !cl.isEmpty { parts.append("CE QU'AHADI EN A DIT (récent → ancien) :\n" + cl.joined(separator: "\n")) }
        return String(parts.joined(separator: "\n\n").prefix(12000))
    }

    func deuilRoutes() {
        let s = server
        s.on("GET", "/api/projects/deuil") { _, res in
            let body: [String: Any] = ["propositions": DeuilStore.file.read(default: [String: Any]())]
            res.json(body)
        }
        s.on("POST", "/api/projects/deuil/proposer") { [self] req, res in
            let id: String = (req.json["id"] as? String) ?? ""
            guard let p = ProjectMemory.items().first(where: { ($0["id"] as? String) == id }) else { let e: [String: Any] = ["error": "projet introuvable"]; res.json(e, status: 404); return }
            let nom: String = (p["nom"] as? String) ?? "?"
            let sys: String = "TU ACCOMPAGNES LA CLÔTURE (LE DEUIL) D'UN PROJET D'AHADI. À partir des seules données fournies, rédige : un bilan honnête en 2 à 4 phrases (ce qui a été fait, ce qui reste ouvert), puis 3 à 7 LEÇONS durables, chacune une phrase autonome et réutilisable sur un autre projet (« La prochaine fois… », « Toujours… »). Rien d'inventé ; si la matière est maigre, moins de leçons. Réponds UNIQUEMENT en JSON strict : {\"bilan\":\"…\",\"lecons\":[\"…\"]}."
            guard let r = ameAsk(sys, "Projet : " + nom + "\n\n" + deuilMaterial(p), deep: true, maxTokens: 1500) else {
                let e: [String: Any] = ["error": "aucun cerveau n'a répondu (crédit épuisé ou hors ligne ?)"]; res.json(e, status: 502); return
            }
            guard let o = ProjectMemory.extractJSON(r.text) else {
                let e: [String: Any] = ["error": "proposition illisible (réponse non JSON du cerveau " + r.brain + ")", "brut": String(r.text.prefix(600))]; res.json(e, status: 502); return
            }
            let lecons: [String] = ProjectMemory.strs(o["lecons"]).map { String($0.prefix(400)) }.prefix(7).map { $0 }
            let prop: [String: Any] = ["bilan": String(((o["bilan"] as? String) ?? "").prefix(1200)), "lecons": lecons, "ts": nowISO(), "brain": r.brain, "nom": nom]
            DeuilStore.lock.lock()
            var all: [String: Any] = DeuilStore.file.read(default: [String: Any]())
            all[id] = prop
            DeuilStore.file.write(all)
            DeuilStore.lock.unlock()
            res.json(prop)
        }
        s.on("POST", "/api/projects/deuil/abandonner") { req, res in
            let id: String = (req.json["id"] as? String) ?? ""
            DeuilStore.lock.lock()
            var all: [String: Any] = DeuilStore.file.read(default: [String: Any]())
            all.removeValue(forKey: id)
            DeuilStore.file.write(all)
            DeuilStore.lock.unlock()
            let ok: [String: Any] = ["ok": true]
            res.json(ok)
        }
        s.on("POST", "/api/projects/deuil/valider") { [self] req, res in
            let j: [String: Any] = req.json
            let id: String = (j["id"] as? String) ?? ""
            var items: [[String: Any]] = ProjectMemory.items()
            guard let i = items.firstIndex(where: { ($0["id"] as? String) == id }) else { let e: [String: Any] = ["error": "projet introuvable"]; res.json(e, status: 404); return }
            let lecons: [String] = ProjectMemory.strs(j["lecons"]).map { String($0.prefix(400)) }
            let bilan: String = String(((j["bilan"] as? String) ?? "").trimmingCharacters(in: .whitespacesAndNewlines).prefix(1200))
            var p: [String: Any] = items[i]
            let nom: String = (p["nom"] as? String) ?? "?"
            var memIds: [String] = []
            var deja: Int = 0
            for l in lecons {
                if let a = memory.add("Leçon du projet « " + nom + " » : " + l, source: "utilisateur", why: "Deuil du projet « " + nom + " » validé par Ahadi (écran Vie)"), let mid = a["id"] as? String { memIds.append(mid) } else { deja += 1 }
            }
            p["archive_prev_auto_off"] = (p["auto_off"] as? Bool) ?? false
            p["archive"] = true
            p["archive_ts"] = nowISO()
            p["archive_bilan"] = bilan
            p["archive_lecons"] = lecons
            p["archive_memory_ids"] = memIds
            p["auto_off"] = true
            p["maj"] = nowISO()
            items[i] = p
            ProjectMemory.save(items)
            DeuilStore.lock.lock()
            var all: [String: Any] = DeuilStore.file.read(default: [String: Any]())
            all.removeValue(forKey: id)
            DeuilStore.file.write(all)
            DeuilStore.lock.unlock()
            _ = BlackBox.record(["tool": "projets", "actor": "Ahadi", "why": "Deuil du projet « " + nom + " » : archivé, " + String(memIds.count) + " leçon(s) en mémoire", "ok": true, "effect": "écrit"])
            let ok: [String: Any] = ["ok": true, "lecons_en_memoire": memIds.count, "deja_en_memoire": deja, "memoire_coupee": memory.isOff, "item": p]
            res.json(ok)
        }
        s.on("POST", "/api/projects/deuil/restaurer") { req, res in
            let id: String = (req.json["id"] as? String) ?? ""
            var items: [[String: Any]] = ProjectMemory.items()
            guard let i = items.firstIndex(where: { ($0["id"] as? String) == id }) else { let e: [String: Any] = ["error": "projet introuvable"]; res.json(e, status: 404); return }
            var p: [String: Any] = items[i]
            p["archive"] = false
            p["auto_off"] = (p["archive_prev_auto_off"] as? Bool) ?? false
            p["restaure_ts"] = nowISO()
            p["maj"] = nowISO()
            items[i] = p
            ProjectMemory.save(items)
            _ = BlackBox.record(["tool": "projets", "actor": "Ahadi", "why": "Projet « " + ((p["nom"] as? String) ?? "?") + " » sorti des archives (les leçons restent en mémoire)", "ok": true, "effect": "écrit"])
            let ok: [String: Any] = ["ok": true, "item": p]
            res.json(ok)
        }
    }
}
