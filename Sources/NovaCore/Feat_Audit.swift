import Foundation

// 27/10 (demande transmise pour audit externe phrase par phrase) — EXPORT D'AUDIT DES
// CONVERSATIONS : GET /api/audit/conversations?heures=24 (défaut 24, plafond 168).
// Lecture seule stricte : aucune écriture, aucun appel cerveau, aucun réseau sortant.
// Périmètre : échanges Ahadi ↔ Nova (rôles user/assistant) des dernières heures, texte
// complet, cerveau par tour, latence dérivée. Hors périmètre, par construction :
//   • les messages « event » (cartes du Fil direct : contenus mail/Teams déjà triés,
//     ce ne sont pas des échanges avec Nova) ;
//   • les conversations « Hors mémoire » (incognito) : exclues entièrement ;
//   • les secrets : chaque contenu passe SecretsGuard.redact (clés, jetons, codes,
//     IBAN, cartes) — la redaction est comptée et signalée dans la sortie.
// La latence d'un tour = horodatage de la réponse finale stockée − horodatage du
// message d'Ahadi qui l'a déclenchée (dérivée des « ts » stockés, étiquetée comme telle).

public enum AuditConversations {
    public static func buildExport(conversations: [[String: Any]], now: Date, hours: Int) -> [String: Any] {
        let h: Int = min(168, max(1, hours))
        let cutoff: Date = now.addingTimeInterval(-Double(h) * 3600)
        let iso: ISO8601DateFormatter = ISO8601DateFormatter()
        var convOut: [[String: Any]] = []
        var totalMsgs: Int = 0
        var redactions: Int = 0
        var truncated: Bool = false
        for c in conversations {
            if (c["incognito"] as? Bool) == true { continue }
            let msgs: [[String: Any]] = (c["messages"] as? [[String: Any]]) ?? []
            var tour: Int = 0
            var lastUserTs: Date? = nil
            var echanges: [[String: Any]] = []
            for m in msgs {
                let role: String = (m["role"] as? String) ?? ""
                if role != "user" && role != "assistant" { continue }
                guard let tsS: String = m["ts"] as? String, let ts: Date = Proactivite.parseDate(tsS), ts >= cutoff else { continue }
                if totalMsgs >= 2000 { truncated = true; break }
                var content: String = (m["content"] as? String) ?? ""
                let red: String = SecretsGuard.redact(content)
                if red != content { redactions += 1; content = red }
                var e: [String: Any] = ["role": role, "ts": tsS, "contenu": content]
                if role == "user" { tour += 1; lastUserTs = ts }
                e["tour"] = tour
                if role == "assistant" {
                    e["cerveau"] = ((m["brain"] as? String) ?? "")
                    // PAS une latence : simple écart d'horodatages stockés (peut couvrir une
                    // nuit entière si la réponse a été reprise le lendemain). La latence réelle
                    // d'un tour est mesurée par le moteur (ttft_ms/total_ms de l'événement
                    // « done ») et affichée sous chaque réponse depuis le 27/10.
                    if let lu: Date = lastUserTs { e["ecart_horodatages_s"] = Int(ts.timeIntervalSince(lu)) }
                    if let tools: [[String: Any]] = m["tools"] as? [[String: Any]], !tools.isEmpty {
                        e["outils"] = tools.map { (t: [String: Any]) -> [String: Any] in
                            var o: [String: Any] = ["outil": ((t["tool"] as? String) ?? ""), "ok": ((t["ok"] as? Bool) ?? false)]
                            let arg: String = SecretsGuard.redact((t["arg"] as? String) ?? "")
                            if !arg.isEmpty { o["arg"] = String(arg.prefix(300)) }
                            return o
                        }
                    }
                }
                echanges.append(e)
                totalMsgs += 1
            }
            if truncated { break }
            if !echanges.isEmpty {
                convOut.append(["id": ((c["id"] as? String) ?? ""), "titre": String(((c["title"] as? String) ?? "").prefix(120)),
                                "creee": ((c["created"] as? String) ?? ""), "echanges": echanges])
            }
        }
        return ["genere_le": iso.string(from: now), "fenetre_heures": h,
                "conversations": convOut, "total_echanges": totalMsgs,
                "redactions_secrets": redactions, "tronque": truncated,
                "ecart_horodatages_s": "écart entre horodatages stockés — NE mesure PAS la latence (reprises différées incluses). Latence réelle : ttft_ms/total_ms mesurés par le moteur à chaque tour, affichés sous la réponse.",
                "perimetre": "rôles user/assistant uniquement ; fils incognito et cartes Direct (event) exclus ; secrets redactés (SecretsGuard)"]
    }
}

extension NovaApp {
    func auditRoutes() {
        let s = server
        s.on("GET", "/api/audit/conversations") { [self] req, res in
            let hours: Int = Int(req.query["heures"] ?? "24") ?? 24
            let convsAll: [[String: Any]] = convs.list().compactMap { (row: [String: Any]) -> [String: Any]? in
                guard let id: String = row["id"] as? String, var full: [String: Any] = convs.get(id) else { return nil }
                full["id"] = id
                return full
            }
            res.json(AuditConversations.buildExport(conversations: convsAll, now: Date(), hours: hours))
        }
    }
}
