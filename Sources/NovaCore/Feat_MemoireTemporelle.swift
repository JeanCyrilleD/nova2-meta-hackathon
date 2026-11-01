import Foundation

// CHANTIER 2 (27/10) — (b) MEMOIRE TEMPORELLE.
// Faits dates (sujet, predicat, valeur, debut, fin, source) avec supersession : un fait nouveau
// clot l'ancien sans l'effacer. Requete « que vaut X a telle date ». Branchement lecture seule
// dans le bloc memoire du chat derriere le reglage memoire_temporelle (defaut actif).
// Migration douce : les faits actuels de memoire.json restent lisibles tels quels (aucune
// reecriture) ; ce magasin est un fichier separe memoire_temporelle.json.
// Validite : debut <= date < fin (fin vide = toujours en vigueur). Dates au format AAAA-MM-JJ.

public enum TemporalMemory {
    public static let settingKey = "memoire_temporelle"

    public static func isValidDay(_ s: String) -> Bool {
        let p = s.split(separator: "-")
        guard p.count == 3, p[0].count == 4, p[1].count == 2, p[2].count == 2,
              Int(p[0]) != nil, let m = Int(p[1]), (1...12).contains(m),
              let d = Int(p[2]), (1...31).contains(d) else { return false }
        return true
    }

    /// Supersession pure : clot (fin = debut du nouveau) tout fait ouvert de meme sujet+predicat,
    /// sans effacer l'ancien, puis ajoute le nouveau. Entree/sortie : listes de dictionnaires.
    public static func assertFact(facts: [[String: Any]], sujet: String, predicat: String, valeur: String,
                                  debut: String, source: String, id: String, ts: String) -> [[String: Any]] {
        var out = facts
        for i in out.indices {
            let same = ((out[i]["sujet"] as? String) ?? "") == sujet && ((out[i]["predicat"] as? String) ?? "") == predicat
            let open = (((out[i]["fin"] as? String) ?? "").isEmpty)
            if same && open { out[i]["fin"] = debut; out[i]["clot_par"] = id }
        }
        out.append(["id": id, "sujet": sujet, "predicat": predicat, "valeur": valeur,
                    "debut": debut, "fin": "", "source": source, "ts": ts])
        return out
    }

    /// « Que vaut X a telle date » : le fait en vigueur a cette date, ou nil.
    public static func valueAt(facts: [[String: Any]], sujet: String, predicat: String, date: String) -> [String: Any]? {
        facts.filter {
            (($0["sujet"] as? String) ?? "") == sujet && (($0["predicat"] as? String) ?? "") == predicat
                && (($0["debut"] as? String) ?? "9999") <= date
                && (((($0["fin"] as? String) ?? "").isEmpty) || ((($0["fin"] as? String) ?? "") > date))
        }.sorted { (($0["debut"] as? String) ?? "") > (($1["debut"] as? String) ?? "") }.first
    }

    /// Faits en vigueur aujourd'hui dont sujet/predicat/valeur partagent un mot de la requete.
    public static func currentFacts(facts: [[String: Any]], query: String, today: String, limit: Int = 6) -> [[String: Any]] {
        let words = Set(query.lowercased().folding(options: .diacriticInsensitive, locale: Locale(identifier: "fr_FR"))
            .components(separatedBy: CharacterSet.alphanumerics.inverted).filter { $0.count >= 3 })
        let valid = facts.filter {
            (($0["debut"] as? String) ?? "9999") <= today
                && (((($0["fin"] as? String) ?? "").isEmpty) || ((($0["fin"] as? String) ?? "") > today))
        }
        if words.isEmpty { return Array(valid.suffix(limit)) }
        let hit = valid.filter { f in
            let blob = EvalCore.normalize([((f["sujet"] as? String) ?? ""), ((f["predicat"] as? String) ?? ""), ((f["valeur"] as? String) ?? "")].joined(separator: " "))
            return words.contains(where: { blob.contains($0) })
        }
        return Array(hit.prefix(limit))
    }

    public static func formatBlock(_ facts: [[String: Any]]) -> String {
        if facts.isEmpty { return "" }
        return "FAITS DATES EN VIGUEUR (memoire temporelle) :\n" + facts.map {
            "- \(($0["sujet"] as? String) ?? "") · \(($0["predicat"] as? String) ?? "") : \(($0["valeur"] as? String) ?? "") (depuis le \(($0["debut"] as? String) ?? "?"), source : \(($0["source"] as? String) ?? "?"))"
        }.joined(separator: "\n")
    }

    /// Migration douce (lecture seule) : un fait memoire.json classique devient un fait date
    /// ouvert (debut = son ts), sans modifier memoire.json.
    public static func legacyAsTemporal(_ items: [[String: Any]]) -> [[String: Any]] {
        items.compactMap { m -> [String: Any]? in
            let text = ((m["text"] as? String) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { return nil }
            return ["id": (m["id"] as? String) ?? "", "sujet": "memoire", "predicat": "fait",
                    "valeur": text, "debut": String(((m["ts"] as? String) ?? "").prefix(10)),
                    "fin": "", "source": (m["source"] as? String) ?? "memoire.json"]
        }
    }
}

enum TemporalStore {
    static let file = JSONFile("memoire_temporelle.json")
    static let lock = NSLock()
    static func all() -> [[String: Any]] { file.read(default: [[String: Any]]()) }

    @discardableResult
    static func assertFact(sujet: String, predicat: String, valeur: String, debut: String, source: String) -> [String: Any]? {
        guard TemporalMemory.isValidDay(debut), !sujet.isEmpty, !predicat.isEmpty, !valeur.isEmpty else { return nil }
        lock.lock(); defer { lock.unlock() }
        let id = String(UUID().uuidString.prefix(8)).lowercased()
        let next = TemporalMemory.assertFact(facts: all(), sujet: sujet, predicat: predicat, valeur: valeur,
                                             debut: debut, source: source, id: id, ts: nowISO())
        file.write(next)
        return next.last
    }

    static func chatBlock(query: String, enabled: Bool) -> String {
        guard enabled else { return "" }
        let df = DateFormatter(); df.locale = Locale(identifier: "en_US_POSIX"); df.dateFormat = "yyyy-MM-dd"
        return TemporalMemory.formatBlock(TemporalMemory.currentFacts(facts: all(), query: query, today: df.string(from: Date())))
    }
}

extension NovaApp {
    func memoireTemporelleRoutes() {
        let s = server
        s.on("GET", "/api/memoire-temporelle") { req, res in
            let all = TemporalStore.all()
            if let sj = req.query["sujet"], let pr = req.query["predicat"], let dt = req.query["date"] {
                let v = TemporalMemory.valueAt(facts: all, sujet: sj, predicat: pr, date: dt)
                res.json(["fait": v as Any? ?? NSNull(), "sujet": sj, "predicat": pr, "date": dt]); return
            }
            res.json(["items": all, "actifs": TemporalMemory.currentFacts(facts: all, query: "", today: String(nowISO().prefix(10)))])
        }
        s.on("POST", "/api/memoire-temporelle/fait") { req, res in
            let j = req.json
            let debut = (j["debut"] as? String) ?? String(nowISO().prefix(10))
            guard let f = TemporalStore.assertFact(sujet: (j["sujet"] as? String) ?? "", predicat: (j["predicat"] as? String) ?? "",
                                                   valeur: (j["valeur"] as? String) ?? "", debut: debut,
                                                   source: (j["source"] as? String) ?? "interface") else {
                res.json(["ok": false, "error": "sujet, predicat, valeur requis et debut au format AAAA-MM-JJ"], status: 400); return
            }
            res.json(["ok": true, "fait": f])
        }
    }
}
