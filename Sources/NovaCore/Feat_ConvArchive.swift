import Foundation

// LOT3 (25/10/2026) — ARCHIVAGE DES CONVERSATIONS (aucune suppression).
//
// Champ OPTIONNEL « archived » sur une conversation de conversations.json (les lecteurs existants l'ignorent ;
// GET /api/conversations le renvoie tel quel puisque Conversations.list() copie tous les champs) :
//   "manuel" — archivée par Ahadi (« Archiver » dans la liste) ;
//   "auto"   — masquée par la règle automatique ;
//   "non"    — désarchivée par Ahadi : la règle automatique ne la touche plus jamais.
// Règle automatique (passe au démarrage + 30 s, puis toutes les heures) : titre « Commande shell » ou titre de
// commande (« Exécute … commande … »), OU dernière activité il y a plus de 2 jours avec 2 messages au plus.
// Jamais le Fil direct. Rien n'est supprimé : le message et son historique restent dans le magasin.

extension Conversations {
    static let cmdTitle: NSRegularExpression? = try? NSRegularExpression(pattern: #"^(?:\[[^\]]{1,30}\]\s*)*(?:ex[ée]cute(?:r|z)?|lance(?:r|z)?|run)\b[^:]{0,40}?\b(?:commande|command)s?\b"#, options: [.caseInsensitive])

    static func isCommandTitle(_ t: String) -> Bool {
        let s: String = t.trimmingCharacters(in: .whitespacesAndNewlines)
        if s.lowercased() == "commande shell" { return true }
        guard let rx = cmdTitle else { return false }
        return rx.firstMatch(in: s, range: NSRange(location: 0, length: (s as NSString).length)) != nil
    }

    /// Pose l'état d'archivage : on = true → « manuel », on = false → « non » (gardée visible). Retourne faux si introuvable.
    @discardableResult func setArchived(_ id: String, on: Bool) -> Bool {
        lock.lock(); defer { lock.unlock() }
        var d: [String: Any] = load()
        guard var c = d[id] as? [String: Any] else { return false }
        c["archived"] = on ? "manuel" : "non"
        c["archived_at"] = nowISO()
        d[id] = c
        f.write(d)
        return true
    }

    /// Règle automatique — n'écrit que « auto » sur des conversations sans état d'archivage. Retourne le nombre masqué.
    @discardableResult func autoArchiveSweep(directId: String, now: Date = Date()) -> Int {
        lock.lock(); defer { lock.unlock() }
        var d: [String: Any] = load()
        let iso: ISO8601DateFormatter = ISO8601DateFormatter()
        var n: Int = 0
        for (k, v) in d {
            guard var c = v as? [String: Any] else { continue }
            if k == directId { continue }
            if let a = c["archived"] as? String, !a.isEmpty { continue }
            let title: String = (c["title"] as? String) ?? ""
            let count: Int = (c["messages"] as? [Any])?.count ?? 0
            var old: Bool = false
            if let u = c["updated"] as? String, let ud = iso.date(from: u) { old = now.timeIntervalSince(ud) > 2 * 86400 }
            var why: String = ""
            if Conversations.isCommandTitle(title) { why = "commande shell" }
            else if old && count <= 2 { why = "plus de 2 jours, " + String(count) + " message(s)" }
            if why.isEmpty { continue }
            c["archived"] = "auto"
            c["archived_at"] = nowISO()
            c["archived_why"] = why
            d[k] = c
            n += 1
        }
        if n > 0 { f.write(d) }
        return n
    }
}

enum ConvArchiveState {
    nonisolated(unsafe) static var timer: DispatchSourceTimer? = nil
}

extension NovaApp {
    func convArchiveRoutes() {
        let s = server
        let cv: Conversations = convs
        let st: Settings = settings
        let t: DispatchSourceTimer = DispatchSource.makeTimerSource(queue: DispatchQueue.global(qos: .utility))
        t.schedule(deadline: .now() + 30, repeating: 3600)
        t.setEventHandler {
            let n: Int = cv.autoArchiveSweep(directId: st.get("direct_thread_id", ""))
            if n > 0 { _ = BlackBox.record(["tool": "conversations", "actor": "Nova", "why": "règle d'archivage automatique : " + String(n) + " conversation(s) masquée(s) de la liste (rien n'est supprimé)", "ok": true, "effect": "écriture"]) }
        }
        t.resume()
        ConvArchiveState.timer = t
        // {id, archived: true|false} — archive (manuel) ou désarchive (gardée visible, la règle auto ne la reprend plus).
        s.on("POST", "/api/conversations/archive") { req, res in
            let id: String = (req.json["id"] as? String) ?? ""
            let on: Bool = (req.json["archived"] as? Bool) ?? true
            if id.isEmpty { res.json(["ok": false, "error": "id requis"], status: 400); return }
            if on && id == st.get("direct_thread_id", "") { res.json(["ok": false, "error": "le Fil direct ne s'archive pas"], status: 409); return }
            let ok: Bool = cv.setArchived(id, on: on)
            let out: [String: Any] = ["ok": ok, "id": id, "archived": on ? "manuel" : "non"]
            res.json(out, status: ok ? 200 : 404)
        }
        // Lance la règle automatique tout de suite (sinon : au démarrage + 30 s, puis toutes les heures).
        s.on("POST", "/api/conversations/archive/auto") { _, res in
            let n: Int = cv.autoArchiveSweep(directId: st.get("direct_thread_id", ""))
            res.json(["ok": true, "masquees": n])
        }
    }
}
