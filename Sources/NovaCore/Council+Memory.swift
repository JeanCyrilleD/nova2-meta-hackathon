import Foundation

/// LOT G — Mémoire du Conseil : chaque séance (question, avis par membre, décision, actions, statuts, date) dans conseils.json.
/// V3 CONSEIL (24/10) : chaque tour garde aussi refutations [{id,label,role,brain,text,ok,error,target,stance,position,confidence,usage_in,usage_out}],
///   votes [{id,label,role,vote,why}], chair {id,label,planned}, usage {in,out,chair_in,chair_out}, limits, run, sparring, duration_s, cancelled_at ;
///   les avis gagnent model, family, position, confidence, change_mind, usage_in, usage_out. Les anciens tours restent lisibles tels quels.
/// Forme : [{ id, created, updated, title, members: [{id,label,role}], rounds: [{ts, question, avis: [{id,label,role,brain,text,ok,error,tools}],
///           decision, decided, applied, pending, report, actions: [{tool,arg,ok}], exec }] }] — le plus récent d'abord.
public enum CouncilStore {
    static let file: JSONFile = JSONFile("conseils.json")
    static let lock: NSLock = NSLock()
    public static let maxItems: Int = 60
    public static let maxRounds: Int = 12

    public static func all() -> [[String: Any]] {
        let a: [[String: Any]] = file.read(default: [[String: Any]]())
        return a
    }

    public static func get(_ id: String) -> [String: Any]? {
        if id.isEmpty { return nil }
        return all().first { ($0["id"] as? String) == id }
    }

    static func nowISO() -> String { ISO8601DateFormatter().string(from: Date()) }

    /// Ajoute un tour à la séance `id` (créée si absente) et la remet en tête. Retourne l'id de la séance.
    public static func appendRound(id: String, title: String, members: [[String: Any]], round: [String: Any]) -> String {
        lock.lock(); defer { lock.unlock() }
        var a: [[String: Any]] = file.read(default: [[String: Any]]())
        let ms: Int = Int(Date().timeIntervalSince1970 * 1000)
        let sid: String = id.isEmpty ? "c" + String(ms) : id
        let now: String = nowISO()
        var rec: [String: Any] = ["id": sid, "created": now, "title": String(title.prefix(140))]
        if let i = a.firstIndex(where: { ($0["id"] as? String) == sid }) {
            rec = a[i]
            a.remove(at: i)
        }
        var rounds: [[String: Any]] = (rec["rounds"] as? [[String: Any]]) ?? []
        rounds.append(round)
        if rounds.count > maxRounds { rounds = Array(rounds.suffix(maxRounds)) }
        rec["rounds"] = rounds
        rec["members"] = members
        rec["updated"] = now
        a.insert(rec, at: 0)
        if a.count > maxItems { a = Array(a.prefix(maxItems)) }
        file.write(a)
        return sid
    }

    /// Complète le dernier tour de la séance (fin de l'exécution par le président, même si l'interface est fermée).
    public static func patchLastRound(id: String, _ fields: [String: Any]) {
        lock.lock(); defer { lock.unlock() }
        var a: [[String: Any]] = file.read(default: [[String: Any]]())
        guard let i = a.firstIndex(where: { ($0["id"] as? String) == id }) else { return }
        var rec: [String: Any] = a[i]
        var rounds: [[String: Any]] = (rec["rounds"] as? [[String: Any]]) ?? []
        guard !rounds.isEmpty else { return }
        var last: [String: Any] = rounds[rounds.count - 1]
        for (k, v) in fields { last[k] = v }
        rounds[rounds.count - 1] = last
        rec["rounds"] = rounds
        rec["updated"] = nowISO()
        a[i] = rec
        file.write(a)
    }

    /// Liste légère pour GET /api/council/history.
    public static func summaries() -> [[String: Any]] {
        var out: [[String: Any]] = []
        for rec in all() {
            let rounds: [[String: Any]] = (rec["rounds"] as? [[String: Any]]) ?? []
            let members: [[String: Any]] = (rec["members"] as? [[String: Any]]) ?? []
            let labels: [String] = members.compactMap { $0["label"] as? String }
            let last: [String: Any] = rounds.last ?? [:]
            let decided: String = (last["decided"] as? String) ?? ""
            let pending: String = (last["pending"] as? String) ?? ""
            var item: [String: Any] = [:]
            item["id"] = (rec["id"] as? String) ?? ""
            item["title"] = (rec["title"] as? String) ?? ""
            item["created"] = (rec["created"] as? String) ?? ""
            item["updated"] = (rec["updated"] as? String) ?? ""
            item["rounds"] = rounds.count
            item["members"] = labels
            item["decided"] = String(decided.prefix(240))
            item["pending"] = String(pending.prefix(240))
            item["exec"] = (last["exec"] as? String) ?? ""
            out.append(item)
        }
        return out
    }

    /// Fil complet d'une séance, pour une relance : questions, avis nommés, décisions, actions appliquées et en attente.
    public static func context(_ rec: [String: Any], limit: Int = 12000) -> String {
        let rounds: [[String: Any]] = (rec["rounds"] as? [[String: Any]]) ?? []
        var t: String = ""
        let base: Int = max(0, rounds.count - 4)
        for (i, r) in rounds.suffix(4).enumerated() {
            let q: String = (r["question"] as? String) ?? ""
            t += "=== TOUR \(base + i + 1) — question : \(q.prefix(1200))\n"
            let avis: [[String: Any]] = (r["avis"] as? [[String: Any]]) ?? []
            for a in avis {
                let lab: String = (a["label"] as? String) ?? "membre"
                let role: String = (a["role"] as? String) ?? ""
                let txt: String = (a["text"] as? String) ?? ""
                if txt.isEmpty { continue }
                t += "### \(lab) (\(role))\n\(txt.prefix(900))\n"
            }
            // V3 CONSEIL : réfutations et vote du tour, pour que la relance reparte du débat et pas seulement de la synthèse.
            let refs: [[String: Any]] = (r["refutations"] as? [[String: Any]]) ?? []
            for x in refs {
                let lab: String = (x["label"] as? String) ?? "membre"
                let txt: String = (x["text"] as? String) ?? ""
                if txt.isEmpty { continue }
                t += "RÉFUTATION — \(lab)\n\(txt.prefix(500))\n"
            }
            let votes: [[String: Any]] = (r["votes"] as? [[String: Any]]) ?? []
            let voteLines: [String] = votes.compactMap { v -> String? in
                let vv: String = (v["vote"] as? String) ?? ""
                if vv.isEmpty { return nil }
                let lab: String = (v["label"] as? String) ?? "membre"
                return "- \(lab) : \(vv)"
            }
            if !voteLines.isEmpty { t += "VOTE :\n" + voteLines.joined(separator: "\n") + "\n" }
            let dec: String = (r["decision"] as? String) ?? ""
            if !dec.isEmpty { t += "DÉCISION DU PRÉSIDENT :\n\(dec.prefix(1600))\n" }
            let app: String = (r["applied"] as? String) ?? ""
            if !app.isEmpty { t += "APPLIQUÉ :\n\(app.prefix(800))\n" }
            let pen: String = (r["pending"] as? String) ?? ""
            if !pen.isEmpty { t += "EN ATTENTE DU GO D'AHADI :\n\(pen.prefix(800))\n" }
            t += "\n"
        }
        if t.count > limit { t = String(t.suffix(limit)) }
        return t
    }

    /// Corps d'une rubrique (« ## Titre » ou « **Titre** ») dont le titre contient `key` (minuscules, sans accents), jusqu'à la rubrique suivante.
    public static func section(_ text: String, _ key: String) -> String {
        let lines: [String] = text.components(separatedBy: "\n")
        var out: [String] = []
        var inside: Bool = false
        for line in lines {
            let t: String = line.trimmingCharacters(in: .whitespaces)
            let boldHead: Bool = t.hasPrefix("**") && t.hasSuffix("**") && t.count < 70
            let isHead: Bool = t.hasPrefix("#") || boldHead
            if isHead {
                if inside { break }
                let low: String = t.lowercased().folding(options: .diacriticInsensitive, locale: nil)
                if low.contains(key) { inside = true }
                continue
            }
            if inside { out.append(line) }
        }
        return out.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
