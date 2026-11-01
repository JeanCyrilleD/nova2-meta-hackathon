import Foundation

// V5-P (25/10) — ARCHÉOLOGUE (#30) : « sujet + période » dans Savoir.
// POST /api/archeo {sujet, depuis?: "AAAA-MM-JJ", jusqua?: "AAAA-MM-JJ", synthese?: Bool}
//  → traces DATÉES retrouvées dans la période : messages des conversations (rôle user/assistant, les événements
//    composés par Nova exclus — même règle que ameSearch), faits de la mémoire, rapports des Éclats, documents indexés
//    (date = modification du fichier). Ordre chronologique, 60 au plus.
//  → si synthese = true et qu'il y a des traces : l'intelligence « archeo » de l'Âme (même consigne que ameThink
//    kind « archeo ») retrace l'évolution, à partir de CES traces seulement.
// Lecture seule : rien n'est écrit, envoyé ni supprimé.

extension NovaApp {
    static func archeoWords(_ q: String) -> [String] {
        var out: [String] = []
        for w in AmeDocParse.tokens(q) where w.count >= 3 && !NovaApp.stop.contains(w) {
            if !out.contains(w) { out.append(w) }
        }
        return Array(out.prefix(8))
    }
    /// Un texte correspond si au moins la moitié des mots du sujet y figurent (tous s'il y en a 1 ou 2).
    static func archeoMatch(_ text: String, _ words: [String]) -> Bool {
        if words.isEmpty || text.isEmpty { return false }
        let need: Int = words.count <= 2 ? words.count : (words.count + 1) / 2
        var n: Int = 0
        for w in words where text.range(of: w, options: [.caseInsensitive, .diacriticInsensitive]) != nil { n += 1 }
        return n >= need
    }
    static func archeoSnippet(_ text: String, _ words: [String]) -> String {
        let flat: String = text.replacingOccurrences(of: "\n", with: " ")
        for w in words {
            if let r = flat.range(of: w, options: [.caseInsensitive, .diacriticInsensitive]) {
                let before: Int = flat.distance(from: flat.startIndex, to: r.lowerBound)
                let startOff: Int = max(0, before - 90)
                let start: String.Index = flat.index(flat.startIndex, offsetBy: startOff)
                let end: String.Index = flat.index(r.upperBound, offsetBy: 150, limitedBy: flat.endIndex) ?? flat.endIndex
                return (startOff > 0 ? "…" : "") + String(flat[start..<end]) + (end < flat.endIndex ? "…" : "")
            }
        }
        return String(flat.prefix(240))
    }

    func archeoTraces(sujet: String, from: Date, to: Date) -> [[String: Any]] {
        let words: [String] = NovaApp.archeoWords(sujet)
        if words.isEmpty { return [] }
        let iso: ISO8601DateFormatter = ISO8601DateFormatter()
        var rows: [(Date, [String: Any])] = []
        // Conversations
        for c in convs.list().prefix(300) {
            guard let id = c["id"] as? String, let full = convs.get(id), let ms = full["messages"] as? [[String: Any]] else { continue }
            let title: String = (full["title"] as? String) ?? ""
            var perConv: Int = 0
            for m in ms {
                let role: String = (m["role"] as? String) ?? ""
                if role != "user" && role != "assistant" { continue }
                guard let d = AmeDocParse.date(m["ts"]), d >= from, d <= to else { continue }
                let t: String = (m["content"] as? String) ?? ""
                if !NovaApp.archeoMatch(t, words) { continue }
                let o: [String: Any] = ["date": iso.string(from: d), "source": "conversation", "qui": role == "user" ? "Ahadi" : "Nova", "titre": title, "conv": id, "texte": NovaApp.archeoSnippet(t, words)]
                rows.append((d, o))
                perConv += 1
                if perConv >= 6 { break }
            }
        }
        // Mémoire
        for f in memory.list() {
            if (f["forgiven"] as? Bool) == true { continue }
            guard let d = AmeDocParse.date(f["ts"]), d >= from, d <= to else { continue }
            let t: String = (f["text"] as? String) ?? ""
            if !NovaApp.archeoMatch(t, words) { continue }
            let o: [String: Any] = ["date": iso.string(from: d), "source": "mémoire", "qui": "", "titre": "", "texte": String(t.prefix(300))]
            rows.append((d, o))
        }
        // Rapports des Éclats
        for r in dots.history().prefix(400) {
            guard let d = AmeDocParse.date(r["ts"]), d >= from, d <= to else { continue }
            let t: String = ((r["task"] as? String) ?? "") + " — " + ((r["result"] as? String) ?? "")
            if !NovaApp.archeoMatch(t, words) { continue }
            let o: [String: Any] = ["date": iso.string(from: d), "source": "éclat", "qui": (r["dot"] as? String) ?? "", "titre": "", "texte": NovaApp.archeoSnippet(t, words)]
            rows.append((d, o))
        }
        // Documents indexés (date de modification du fichier)
        for h in Knowledge.shared.search(sujet, limit: 10) {
            let p: String = (h["path"] as? String) ?? ""
            if p.isEmpty { continue }
            let attrs: [FileAttributeKey: Any] = (try? FileManager.default.attributesOfItem(atPath: p)) ?? [:]
            guard let d = attrs[.modificationDate] as? Date, d >= from, d <= to else { continue }
            let t: String = (h["text"] as? String) ?? ""
            let o: [String: Any] = ["date": iso.string(from: d), "source": "document", "qui": "", "titre": (p as NSString).lastPathComponent, "chemin": p, "texte": NovaApp.archeoSnippet(t, words), "date_note": "date de modification du fichier"]
            rows.append((d, o))
        }
        rows.sort { $0.0 < $1.0 }
        if rows.count > 60 {
            // On garde le début et la fin de la période : l'évolution se lit aux deux bouts.
            let head: [(Date, [String: Any])] = Array(rows.prefix(30))
            let tail: [(Date, [String: Any])] = Array(rows.suffix(30))
            rows = head + tail
        }
        return rows.map { $0.1 }
    }

    func archeoRoutes() {
        let s = server
        s.on("POST", "/api/archeo") { [self] req, res in
            let j: [String: Any] = req.json
            let sujet: String = ((j["sujet"] as? String) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            if NovaApp.archeoWords(sujet).isEmpty { let e: [String: Any] = ["error": "sujet trop court (au moins un mot de 3 lettres)"]; res.json(e, status: 400); return }
            let from: Date = AmeDocParse.date(j["depuis"]).map { $0.addingTimeInterval(-12 * 3600) } ?? Date.distantPast
            let to: Date = AmeDocParse.date(j["jusqua"]).map { $0.addingTimeInterval(12 * 3600) } ?? Date()
            if from > to { let e: [String: Any] = ["error": "période inversée"]; res.json(e, status: 400); return }
            let traces: [[String: Any]] = archeoTraces(sujet: String(sujet.prefix(160)), from: from, to: to)
            var counts: [String: Int] = [:]
            for t in traces { counts[(t["source"] as? String) ?? "?", default: 0] += 1 }
            var body: [String: Any] = ["sujet": sujet, "traces": traces, "count": traces.count, "sources": counts,
                                       "mots": NovaApp.archeoWords(sujet), "depuis": (j["depuis"] as? String) ?? "", "jusqua": (j["jusqua"] as? String) ?? ""]
            if (j["synthese"] as? Bool) == true && !traces.isEmpty {
                var lines: [String] = []
                for t in traces {
                    let d: String = String(((t["date"] as? String) ?? "").prefix(10))
                    let src: String = (t["source"] as? String) ?? ""
                    let qui: String = (t["qui"] as? String) ?? ""
                    let tx: String = String(((t["texte"] as? String) ?? "").prefix(260))
                    lines.append("[" + d + ", " + src + (qui.isEmpty ? "" : ", " + qui) + "] " + tx)
                }
                let sys: String = "TU ES L'ARCHÉOLOGUE. Retrace l'ÉVOLUTION de la pensée de l'utilisateur sur le sujet demandé, dans l'ordre chronologique, avec les dates, et dis ce qui a changé. Appuie-toi UNIQUEMENT sur les traces fournies ; cite des extraits courts et datés ; si les traces sont trop maigres pour conclure, dis-le franchement. Pas de flatterie."
                if let r = ameAsk(sys, "Sujet : " + sujet + "\n\nTraces retrouvées (période demandée) :\n" + lines.joined(separator: "\n"), deep: true, maxTokens: 1400) {
                    body["synthese"] = r.text
                    body["brain"] = r.brain
                } else {
                    body["synthese_error"] = "aucun cerveau n'a répondu (crédit épuisé ou hors ligne ?)"
                }
            }
            res.json(body)
        }
    }
}
