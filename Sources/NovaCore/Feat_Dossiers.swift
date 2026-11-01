import Foundation

// LOT F (28/10/2026) — SUIVI DE DOSSIERS (pièces + échéance).
//
// Un dossier = un intitulé (visa, candidature, dossier administratif…), une
// échéance optionnelle et une liste de pièces cochables. C'est Ahadi qui crée
// ses dossiers (aucune donnée fabriquée : le magasin naît vide). Nova compte
// les pièces restantes et les jours avant échéance ; rien n'est deviné.
// Magasin : dossiers.json {items: [{id, titre, echeance?, statut, pieces:
// [{id, label, fait}], note, cree, maj}], updated}

public enum Dossiers {
    static let file: JSONFile = JSONFile("dossiers.json")
    static let lock: NSLock = NSLock()

    static func items() -> [[String: Any]] {
        let o: [String: Any] = file.read(default: [String: Any]())
        return (o["items"] as? [[String: Any]]) ?? []
    }

    static func saveAll(_ items: [[String: Any]]) {
        file.write(["items": items, "updated": nowISO()] as [String: Any])
    }

    static func clean(_ s: Any?, max: Int) -> String {
        let t: String = ((s as? String) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        return String(t.prefix(max))
    }

    /// Échéance acceptée : AAAA-MM-JJ (ou vide). Sinon refus explicite.
    static func validDate(_ s: String) -> Bool {
        if s.isEmpty { return true }
        let f: DateFormatter = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX"); f.timeZone = TimeZone(identifier: "GMT"); f.dateFormat = "yyyy-MM-dd"
        return f.date(from: s) != nil && f.string(from: f.date(from: s)!) == s
    }

    static func newId() -> String { UUID().uuidString.prefix(8).lowercased() }

    /// Crée ou met à jour un dossier. Actions : save (titre/échéance/note/statut),
    /// piece_add {id,label}, piece_toggle {id,piece}, piece_remove {id,piece},
    /// remove {id}. Renvoie (ok, erreur).
    public static func apply(_ j: [String: Any]) -> (Bool, String) {
        let action: String = clean(j["action"], max: 24)
        lock.lock(); defer { lock.unlock() }
        var all: [[String: Any]] = items()
        func index(of id: String) -> Int? { all.firstIndex { ($0["id"] as? String) == id } }
        switch action {
        case "save":
            let titre: String = clean(j["titre"], max: 160)
            if titre.isEmpty { return (false, "intitulé manquant") }
            let ech: String = clean(j["echeance"], max: 10)
            if !validDate(ech) { return (false, "échéance au format AAAA-MM-JJ") }
            let statut: String = clean(j["statut"], max: 10) == "clos" ? "clos" : "ouvert"
            let idIn: String = clean(j["id"], max: 16)
            if let i = index(of: idIn), !idIn.isEmpty {
                all[i]["titre"] = titre; all[i]["echeance"] = ech; all[i]["statut"] = statut
                all[i]["note"] = clean(j["note"], max: 2000); all[i]["maj"] = nowISO()
            } else {
                if all.count >= 60 { return (false, "60 dossiers au plus") }
                let piecesBrutes: [String] = clean(j["pieces"], max: 4000).split(separator: "\n").map { String($0).trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
                let pieces: [[String: Any]] = piecesBrutes.prefix(80).map { ["id": newId(), "label": String($0.prefix(200)), "fait": false] as [String: Any] }
                all.append(["id": newId(), "titre": titre, "echeance": ech, "statut": statut,
                            "pieces": pieces, "note": clean(j["note"], max: 2000),
                            "cree": nowISO(), "maj": nowISO()] as [String: Any])
            }
        case "piece_add":
            guard let i = index(of: clean(j["id"], max: 16)) else { return (false, "dossier introuvable") }
            let label: String = clean(j["label"], max: 200)
            if label.isEmpty { return (false, "pièce sans intitulé") }
            var pieces: [[String: Any]] = (all[i]["pieces"] as? [[String: Any]]) ?? []
            if pieces.count >= 80 { return (false, "80 pièces au plus par dossier") }
            pieces.append(["id": newId(), "label": label, "fait": false] as [String: Any])
            all[i]["pieces"] = pieces; all[i]["maj"] = nowISO()
        case "piece_toggle", "piece_remove":
            guard let i = index(of: clean(j["id"], max: 16)) else { return (false, "dossier introuvable") }
            let pid: String = clean(j["piece"], max: 16)
            var pieces: [[String: Any]] = (all[i]["pieces"] as? [[String: Any]]) ?? []
            if action == "piece_remove" {
                pieces.removeAll { ($0["id"] as? String) == pid }
            } else if let k = pieces.firstIndex(where: { ($0["id"] as? String) == pid }) {
                pieces[k]["fait"] = !((pieces[k]["fait"] as? Bool) ?? false)
            } else { return (false, "pièce introuvable") }
            all[i]["pieces"] = pieces; all[i]["maj"] = nowISO()
        case "remove":
            let id: String = clean(j["id"], max: 16)
            let before: Int = all.count
            all.removeAll { ($0["id"] as? String) == id }
            if all.count == before { return (false, "dossier introuvable") }
        default:
            return (false, "action inconnue")
        }
        saveAll(all)
        return (true, "")
    }

    /// Vue servie : dossiers ouverts d'abord (échéance la plus proche en tête),
    /// avec avancement (pièces faites/total) et jours restants calculés au GMT.
    public static func snapshot() -> [String: Any] {
        let f: DateFormatter = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX"); f.timeZone = TimeZone(identifier: "GMT"); f.dateFormat = "yyyy-MM-dd"
        let todayStart: Date = f.date(from: f.string(from: Date())) ?? Date()
        var rows: [[String: Any]] = items().map { d in
            var r: [String: Any] = d
            let pieces: [[String: Any]] = (d["pieces"] as? [[String: Any]]) ?? []
            let faits: Int = pieces.filter { ($0["fait"] as? Bool) == true }.count
            r["pieces_total"] = pieces.count; r["pieces_faites"] = faits
            let ech: String = (d["echeance"] as? String) ?? ""
            if let e = f.date(from: ech) { r["jours_restants"] = Int((e.timeIntervalSince(todayStart) / 86400).rounded()) }
            return r
        }
        rows.sort { a, b in
            let ca: Bool = (a["statut"] as? String) == "clos"; let cb: Bool = (b["statut"] as? String) == "clos"
            if ca != cb { return !ca }
            let ja: Int = (a["jours_restants"] as? Int) ?? 99999; let jb: Int = (b["jours_restants"] as? Int) ?? 99999
            if ja != jb { return ja < jb }
            return ((a["maj"] as? String) ?? "") > ((b["maj"] as? String) ?? "")
        }
        return ["items": rows, "ouverts": rows.filter { ($0["statut"] as? String) != "clos" }.count]
    }
}

extension NovaApp {
    func dossiersRoutes() {
        let s = server
        s.on("GET", "/api/dossiers") { _, res in res.json(Dossiers.snapshot()) }
        s.on("POST", "/api/dossiers") { req, res in
            let (ok, err): (Bool, String) = Dossiers.apply(req.json)
            if !ok { res.json(["ok": false, "error": err], status: 400); return }
            var snap: [String: Any] = Dossiers.snapshot(); snap["ok"] = true
            res.json(snap)
        }
    }
}
