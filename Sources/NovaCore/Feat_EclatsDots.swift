import Foundation

// MARK: - V6 ÉCLATS « DOTS » (25/10/2026)
// Demande d'Ahadi : améliorer les Éclats avec ce que font les « dots » d'[tiers] (agents toujours actifs,
// lancés le 29/09/2026), adapté aux règles de Nova : rien n'est envoyé, publié, payé ni supprimé sans
// le GO explicite d'Ahadi ; aucun secret n'est stocké ni affiché.
//   (lot réduit) RETOURS « Utile / Pas utile / Corriger… » → bloc « Leçons d'Ahadi » injecté avant chaque passage ;
//   RÉORIENTER : une consigne d'une ligne servie au passage suivant puis effacée.
// Modèle de données : champs FACULTATIFS sur l'Éclat (reorient) — aucune migration,
// absence = comportement d'avant. Aucun Éclat n'est jamais supprimé ici.
// Toutes les déclarations portent des types explicites (pas de longues chaînes « + », pas de ternaires imbriqués).

enum EclatPlus {
    /// Retours gardés par Éclat, et corrections injectées dans le prompt (lus aussi par conseil_24-10/sim_eclats_dots.py).
    static let feedbackKeep: Int = 30
    static let lessonsMax: Int = 5
    static let feedbackFile: JSONFile = JSONFile("dots_feedback.json")      // { dotId: [ {id, run_id, verdict, note, ts} ] }
    static let lock: NSLock = NSLock()

    struct Prep {
        let suffix: String
        let reoriented: Bool
    }
    /// Blocs ajoutés à la tâche : leçons d'Ahadi, priorité ponctuelle (Réorienter). Une question de suivi n'en reçoit aucun.
    static func prepare(_ d: [String: Any], followUp: Bool) -> Prep {
        if followUp { return Prep(suffix: "", reoriented: false) }
        let id: String = (d["id"] as? String) ?? ""
        var parts: [String] = []
        let l: String = lessonsBlock(id)
        if !l.isEmpty { parts.append(l) }
        let r: String = reorientBlock(d)
        if !r.isEmpty { parts.append(r) }
        let suffix: String = parts.isEmpty ? "" : "\n\n" + parts.joined(separator: "\n\n")
        return Prep(suffix: suffix, reoriented: !r.isEmpty)
    }

    static func reorientBlock(_ d: [String: Any]) -> String {
        guard let r = d["reorient"] as? [String: Any] else { return "" }
        let t: String = ((r["text"] as? String) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        if t.isEmpty { return "" }
        return "PRIORITÉ D'AHADI POUR CE PASSAGE (consigne ponctuelle : elle prime sur l'ordre habituel de ta mission, jamais sur les règles) : " + String(t.prefix(300))
    }

    // MARK: retours et leçons
    static func feedback(_ dot: String) -> [[String: Any]] {
        let all: [String: Any] = feedbackFile.read(default: [String: Any]())
        return (all[dot] as? [[String: Any]]) ?? []
    }
    static func stats(_ items: [[String: Any]]) -> [String: Int] {
        var u: Int = 0
        var p: Int = 0
        var c: Int = 0
        for it in items {
            let v: String = (it["verdict"] as? String) ?? ""
            if v == "utile" { u += 1 }
            else if v == "pas_utile" { p += 1 }
            else if v == "corriger" { c += 1 }
        }
        return ["utile": u, "pas_utile": p, "corriger": c]
    }
    static func lessonsBlock(_ dot: String) -> String {
        let items: [[String: Any]] = feedback(dot)
        if items.isEmpty { return "" }
        let st: [String: Int] = stats(items)
        let u: Int = st["utile"] ?? 0
        let p: Int = st["pas_utile"] ?? 0
        var lines: [String] = []
        var head: String = "LEÇONS D'AHADI (ses retours sur tes passages — applique-les) : utile " + String(u) + " · pas utile " + String(p)
        if u + p > 0 {
            let pct: Int = Int((Double(u) * 100.0 / Double(u + p)).rounded())
            head += " (" + String(pct) + " % utile)"
        }
        lines.append(head + ".")
        var corr: [[String: Any]] = []
        for it in items.reversed() {
            let note: String = ((it["note"] as? String) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            if note.isEmpty { continue }
            corr.append(it)
            if corr.count >= lessonsMax { break }
        }
        for it in corr {
            let ts: String = String(((it["ts"] as? String) ?? "").prefix(10))
            let note: String = String(((it["note"] as? String) ?? "").prefix(240))
            let v: String = (it["verdict"] as? String) ?? ""
            let tag: String = v == "pas_utile" ? "pas utile" : "à corriger"
            lines.append("- [" + ts + "] " + tag + " : " + note)
        }
        if p > u && u + p >= 3 { lines.append("Tes derniers passages ont été jugés peu utiles : va droit à ce qui est nouveau et actionnable, ou réponds « RAS ».") }
        return lines.joined(separator: "\n")
    }
    static let verdicts: Set<String> = ["utile", "pas_utile", "corriger"]
    static func addFeedback(dot: String, runId: String, verdict: String, note: String) -> [String: Any] {
        lock.lock(); defer { lock.unlock() }
        var all: [String: Any] = feedbackFile.read(default: [String: Any]())
        var l: [[String: Any]] = (all[dot] as? [[String: Any]]) ?? []
        let clean: String = String(note.trimmingCharacters(in: .whitespacesAndNewlines).prefix(300))
        // Un seul verdict par run : un nouveau clic remplace l'ancien (la note est gardée si la nouvelle est vide).
        var keptNote: String = clean
        if !runId.isEmpty, let i = l.firstIndex(where: { ($0["run_id"] as? String) == runId }) {
            if keptNote.isEmpty { keptNote = (l[i]["note"] as? String) ?? "" }
            l.remove(at: i)
        }
        let item: [String: Any] = ["id": String(UUID().uuidString.prefix(8)).lowercased(), "run_id": runId, "verdict": verdict, "note": keptNote, "ts": nowISO()]
        l.append(item)
        all[dot] = Array(l.suffix(feedbackKeep))
        feedbackFile.write(all)
        return item
    }
    static func deleteFeedback(dot: String, id: String) -> Bool {
        lock.lock(); defer { lock.unlock() }
        var all: [String: Any] = feedbackFile.read(default: [String: Any]())
        let l: [[String: Any]] = (all[dot] as? [[String: Any]]) ?? []
        let kept: [[String: Any]] = l.filter { ($0["id"] as? String) != id }
        if kept.count == l.count { return false }
        all[dot] = kept
        feedbackFile.write(all)
        return true
    }

    /// Après un passage abouti : la consigne « Réorienter » a servi une fois, elle est effacée.
    static func afterRun(_ id: String, prep: Prep, dots: Dots) {
        if !prep.reoriented || id.isEmpty { return }
        guard var cur = dots.list().first(where: { ($0["id"] as? String) == id }) else { return }
        if cur["reorient"] == nil { return }
        cur.removeValue(forKey: "persona")
        cur.removeValue(forKey: "reorient")
        dots.save(cur)
    }
}

extension NovaApp {
    /// V6 ÉCLATS « DOTS » : routes /api/dots/feedback (+ /delete), /api/dots/reorient.
    func eclatsDotsRoutes() {
        let s: HTTPServer = server
        let ds: Dots = dots
        // Réorienter : une consigne d'une ligne, servie au prochain passage puis effacée.
        s.on("POST", "/api/dots/reorient") { req, res in
            let j: [String: Any] = req.json
            let id: String = (j["id"] as? String) ?? ""
            guard var d = ds.list().first(where: { ($0["id"] as? String) == id }) else { res.json(["error": "Éclat introuvable"], status: 404); return }
            d.removeValue(forKey: "persona")
            let t: String = String(((j["text"] as? String) ?? "").replacingOccurrences(of: "\n", with: " ").trimmingCharacters(in: .whitespacesAndNewlines).prefix(300))
            if t.isEmpty { d.removeValue(forKey: "reorient") } else { d["reorient"] = ["text": t, "ts": nowISO()] }
            ds.save(d)
            res.json(["ok": true, "id": id, "reorient": t])
        }
        // Retours : Utile / Pas utile / Corriger… (note courte) — 30 derniers par Éclat.
        s.on("POST", "/api/dots/feedback") { req, res in
            let j: [String: Any] = req.json
            let dot: String = (j["dot"] as? String) ?? ""
            let verdict: String = (j["verdict"] as? String) ?? ""
            let runId: String = (j["run_id"] as? String) ?? ""
            let note: String = (j["note"] as? String) ?? ""
            if dot.isEmpty || !EclatPlus.verdicts.contains(verdict) { res.json(["ok": false, "error": "dot et verdict (utile, pas_utile, corriger) requis"], status: 400); return }
            if verdict == "corriger" && note.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { res.json(["ok": false, "error": "une correction demande une note"], status: 400); return }
            if !ds.list().contains(where: { ($0["id"] as? String) == dot }) { res.json(["ok": false, "error": "Éclat introuvable"], status: 404); return }
            let item: [String: Any] = EclatPlus.addFeedback(dot: dot, runId: runId, verdict: verdict, note: note)
            res.json(["ok": true, "item": item, "stats": EclatPlus.stats(EclatPlus.feedback(dot))])
        }
        s.on("GET", "/api/dots/feedback") { req, res in
            let dot: String = req.query["dot"] ?? ""
            let fb: [[String: Any]] = EclatPlus.feedback(dot)
            res.json(["items": Array(fb.reversed()), "stats": EclatPlus.stats(fb), "bloc": EclatPlus.lessonsBlock(dot)])
        }
        s.on("POST", "/api/dots/feedback/delete") { req, res in
            let j: [String: Any] = req.json
            let ok: Bool = EclatPlus.deleteFeedback(dot: (j["dot"] as? String) ?? "", id: (j["id"] as? String) ?? "")
            res.json(["ok": ok])
        }
    }
}
