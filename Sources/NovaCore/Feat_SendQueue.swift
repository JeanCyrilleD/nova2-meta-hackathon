import Foundation

// Feat_SendQueue.swift — (M6) envoi d'un brouillon de la file de validation, en un geste, AVEC accord explicite à chaque envoi,
// et (M7) « Demander à Nova » : texte reçu du Service macOS / de Raccourcis, relayé à la bulle par l'évènement « ask ».
// Règles M6 : jamais d'envoi automatique ; refus sans confirm == "ENVOYER" ; refus si l'appel ne vient pas de l'interface
// (en-tête x-nova-provenance posé UNIQUEMENT par NovaSchemeHandler avec un secret en mémoire, inconnu des Dots / curl / .session).
// Mail.app n'est jamais activé (pas de `activate`) ; lancé si besoin par `open -g -j`. Journal : destinataire, objet, heure — jamais le corps.
// WP3/WP4 (31/10) : l'autorisation et l'état d'envoi passent par le service UNIQUE SendApprovals (SendApproval.swift) —
// approbation liée à l'action exacte, consommation atomique, registre SQLite durable, transports Mail / Teams derrière
// SendTransport. Plus de garde « inFlight » en mémoire ni de fenêtre globale Tools.sendAllowed.

public enum SendQueue {
    /// Secret propre à ce lancement, en mémoire seulement. NovaSchemeHandler le pose sur les requêtes de l'interface (nova://app).
    public static let uiSecret: String = UUID().uuidString + UUID().uuidString
    public static let headerName: String = "x-nova-provenance"
    static let log: Journal = Journal("envois.jsonl")

    /// Chaîne AppleScript littérale (échappe \ et ").
    static func q(_ s: String) -> String {
        "\"" + s.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"") + "\""
    }
    static func recipients(_ to: String) -> [String] {
        to.split(whereSeparator: { $0 == "," || $0 == ";" || $0 == "\n" })
            .map { $0.trimmingCharacters(in: .whitespaces) }.filter { $0.contains("@") }
    }
    /// Corps : on retire le gras Markdown (**…**) qui n'a pas de sens dans un mail texte.
    static func plain(_ b: String) -> String { b.replacingOccurrences(of: "**", with: "") }

    static func script(to: [String], subject: String, body: String, sender: String) -> String {
        var s = "tell application \"Mail\"\n"
        s += "set m to make new outgoing message with properties {subject:\(q(subject)), content:\(q(body)), visible:false}\n"
        if !sender.isEmpty { s += "set sender of m to \(q(sender))\n" }
        s += "tell m\n"
        for r in to { s += "make new to recipient at end of to recipients with properties {address:\(q(r))}\n" }
        s += "end tell\nsend m\nend tell\nreturn \"ok\""
        return s
    }

    static func ensureMail() {
        #if os(macOS)
        let (rc, _) = runProcess("/usr/bin/pgrep", ["-x", "Mail"], timeout: 3)
        if rc != 0 { _ = runProcess("/usr/bin/open", ["-g", "-j", "-a", "Mail"], timeout: 10); Thread.sleep(forTimeInterval: 3) }
        #endif
    }

    /// Transport réel du canal du brouillon (les tests injectent des simulateurs dans SendApprovals.execute).
    static func transport(for d: [String: Any]) -> SendTransport {
        ((d["channel"] as? String) ?? "mail") == "teams" ? TeamsPaneTransport() : MailAppTransport()
    }

    /// Journal utilisateur des envois (liste « Envoyés » de l'interface) — une ligne par TENTATIVE de transport.
    /// Jamais le corps ; état et motif court, preuve (force) — pas de contenu dans le journal de diagnostic (BlackBox).
    static func journal(_ r: SendResult, via: String) {
        guard let rec = r.record, rec.transportStartedAt != nil, rec.state != .sending else { return }
        let s = rec.snapshot
        var e: [String: Any] = ["draft": rec.draftId, "action": rec.actionId, "channel": s.channel.rawValue,
                                "ok": rec.state == .submitted || rec.state == .verified, "state": rec.state.rawValue, "code": rec.code, "via": via]
        if s.channel == .teams { e["to"] = s.recipients; e["subject"] = "" } else { e["to"] = s.recipients.joined(separator: ", "); e["subject"] = s.subject; e["account"] = s.sender }
        if let ev = rec.submission { e["evidence"] = ev.strength.rawValue }
        log.add(e)
        let who: String = s.recipients.joined(separator: ", ")
        let input: String = s.channel == .teams ? "Teams « " + who + " »" : "À " + who + " — " + s.subject
        let why: String = via == "bouton" ? "Envoi confirmé (ENVOYER) depuis la file de validation" : "Envoi approuvé dans la conversation (carte « Envoi à approuver » puis « envoie »)"
        Tools.actions.add(["id": String(UUID().uuidString.prefix(8)).lowercased(), "tool": "mail_send", "actor": "Toi", "why": why,
                           "input": input, "ok": rec.state == .submitted, "effect": "envoyé", "result": rec.state.rawValue + " : " + rec.code])
    }

    /// Message rendu au cerveau (et à Ahadi) pour un envoi demandé dans la conversation.
    static func chatMessage(_ r: SendResult) -> String {
        let s = r.record?.snapshot
        let who: String = s?.recipients.joined(separator: ", ") ?? "?"
        switch r.code {
        case .submitted, .verified:
            if s?.channel == .teams {
                let weak: Bool = r.record?.submission?.strength == .weakReadback
                return "✅ Message Teams soumis dans « " + who + " »" + (weak ? " et relu dans le fil (preuve FAIBLE : extrait du texte, pas un reçu) — non vérifié par identifiant." : ".")
            }
            return "✅ Envoyé via Mail à " + who + " — objet « " + (s?.subject ?? "") + " » (soumission acceptée par Mail ; la livraison n'est pas encore vérifiée)."
        case .needsApproval, .expired:
            let a: String = r.record?.actionId ?? "?"
            return "APPROBATION REQUISE (rien n'est parti) : l'envoi " + a + " n'est pas approuvé par Ahadi pour CETTE version. Le moteur affiche à la fin de ta réponse la carte « Envoi à approuver » (destinataires, expéditeur, objet, corps, empreinte). Dis-lui en une phrase qu'il lui suffit de répondre « envoie » (ou « go ») au prochain message pour l'envoyer tel quel. Ne rappelle pas mail_envoyer dans ce tour. Écrire « confirmé » n'autorise rien."
        case .changed: return "Envoi refusé : " + r.detail + ". Rappelle mail_envoyer au prochain tour pour afficher la nouvelle version."
        case .wrongScope: return "Envoi refusé : " + r.detail + " — l'approbation ne vaut que pour la conversation et le tour où Ahadi l'a donnée."
        case .inProgress: return "Envoi déjà en cours pour ce brouillon — aucun second envoi."
        case .alreadySent: return "Ce brouillon est déjà envoyé (" + (r.record?.state.rawValue ?? "") + ") — aucun second envoi."
        case .uncertain, .deliveryUnknown:
            return "⚠️ Envoi INCERTAIN vers " + who + " : " + r.detail + ". Ne le renvoie pas : demande à Ahadi de vérifier (Éléments envoyés / fil Teams) ; aucune relance automatique."
        case .failed: return "Envoi échoué, rien n'est parti : " + r.detail + ". Une nouvelle approbation sera nécessaire pour réessayer."
        case .refused, .notFound, .invalid: return "Envoi refusé : " + r.detail + "."
        }
    }

    /// Envoi demandé DEPUIS LE CHAT (27/10, retour Ahadi : « une fois que je lui donne l'ordre, il doit le faire »).
    /// WP3 : l'ordre « envoie » ne vaut plus autorisation à lui seul — la première demande affiche la carte « Envoi à
    /// approuver » ; la confirmation explicite d'Ahadi au message suivant approuve EXACTEMENT cette version (pas de
    /// seconde confirmation ensuite). Toutes les autres serrures restent : coche dure verte, jamais de double envoi,
    /// journal sans corps. Sans id : uniquement s'il n'existe qu'UN brouillon « à valider » du jour, sinon la liste.
    static func performChatSend(id rawId: String, tl: Tools) -> String {
        let l = tl.drafts.read(default: [[String: Any]]())
        let wanted = rawId.trimmingCharacters(in: .whitespacesAndNewlines)
        let idx: Int?
        if !wanted.isEmpty, wanted != "dernier" {
            idx = l.firstIndex(where: { ($0["id"] as? String) == wanted })
            guard idx != nil else { return "Envoi impossible : brouillon « " + wanted + " » introuvable dans la file." }
        } else {
            let fresh = l.enumerated().filter { e in
                let st = ((e.element["status"] as? String) ?? "").lowercased()
                guard st.hasPrefix("à valider") || st.hasPrefix("a valider") else { return false }
                let ts = (e.element["ts"] as? String) ?? ""
                return ts.isEmpty || ts >= String(nowISO().prefix(10)) // même jour : fenêtre large mais bornée
            }
            guard fresh.count == 1, let only = fresh.first else {
                if fresh.isEmpty { return "Envoi impossible : aucun brouillon « à valider » du jour dans la file. Prépare d'abord le brouillon (draft_reply ou mail_brouillon), montre-le à Ahadi, puis il confirme l'envoi." }
                let list = fresh.map { e in "« " + (((e.element["subject"] as? String) ?? "").isEmpty ? ((e.element["target"] as? String) ?? "?") : ((e.element["subject"] as? String) ?? "?")) + " » (id " + ((e.element["id"] as? String) ?? "?") + ")" }.joined(separator: " · ")
                return "Envoi en attente de précision : plusieurs brouillons à valider — " + list + ". Ahadi doit dire lequel (« envoie <id> »)."
            }
            idx = only.offset
        }
        guard let i = idx else { return "Envoi impossible : brouillon introuvable." }
        let id = (l[i]["id"] as? String) ?? ""
        if let st = l[i]["status"] as? String, st.lowercased().hasPrefix("envoy") { return "Ce brouillon est déjà marqué envoyé — aucun second envoi." }
        let fails = DraftLint.hardFailures(l[i])
        guard fails.isEmpty else { return "Envoi refusé : coche gabarit en échec — " + fails.map { $0.label }.joined(separator: " · ") + ". Corrige le brouillon puis redemande l'envoi." }
        let r = SendApprovals.shared.execute(draftId: id, ctx: ExecContext.current, transport: SendQueue.transport(for: l[i]))
        SendQueue.journal(r, via: "ordre-chat")
        return SendQueue.chatMessage(r)
    }
}

extension NovaApp {
    /// À AJOUTER par l'intégrateur dans novaPlusRoutes() : sendQueueRoutes()   // Feat_SendQueue.swift
    func sendQueueRoutes() {
        let s = server
        let tl = tools
        let bs = bus

        // WP3/WP4 : le service unique lit et reflète la file de brouillons ; reprise PRUDENTE des envois interrompus.
        SendApprovals.shared.configure(drafts: { tl.drafts.read(default: [[String: Any]]()) }, updateDraft: { id, fields in
            var l = tl.drafts.read(default: [[String: Any]]())
            guard let k = l.firstIndex(where: { ($0["id"] as? String) == id }) else { return }
            for (a, b) in fields { l[k][a] = b }
            tl.drafts.write(l)
        })
        let rec = SendApprovals.shared.recoverAtStartup()
        if rec.failed + rec.unknown + rec.dropped > 0 {
            _ = BlackBox.record(["tool": "envoi", "actor": "Nova", "effect": "lecture", "ok": true, "why": "reprise au démarrage (aucune relance)",
                                 "result": "échoués=\(rec.failed) incertains=\(rec.unknown) approbations_retombées=\(rec.dropped)"])
        }

        // M6 — envoi confirmé d'un brouillon
        s.on("POST", "/api/drafts/send") { req, res in
            // LOT4 P-D1 : provenance = secret de session EN MÉMOIRE, injecté par le natif dans les seules
            // pages de l'UI (main.swift : window.__novaProv, origine gardée, cadre principal) et posé en
            // en-tête UNIQUEMENT par les handlers de geste d'envoi du web. Les outils agent tournent en
            // processus — aucun canal HTTP, et le secret ne transite ni par settings, ni par les prompts.
            let prov = req.headers[SendQueue.headerName]
            guard prov == SendQueue.uiSecret else {
                let absent = (prov ?? "").isEmpty
                res.json(["ok": false, "code": absent ? "provenance_absente" : "provenance_invalide",
                          "error": absent ? "Envoi refusé : provenance d'interface absente — l'envoi ne part que du bouton d'envoi de Nova, après saisie de ENVOYER (jamais d'un Dot, d'un outil ou d'un script)."
                                           : "Envoi refusé : provenance d'interface invalide (session expirée ?) — relance Nova, puis réessaie depuis le bouton d'envoi."], status: 403); return
            }
            let j = req.json
            guard (j["confirm"] as? String) == "ENVOYER" else {
                res.json(["ok": false, "error": "Confirmation manquante : tape exactement ENVOYER."], status: 400); return
            }
            let id = j["id"] as? String ?? ""
            let l = tl.drafts.read(default: [[String: Any]]())
            guard let i = l.firstIndex(where: { ($0["id"] as? String) == id }) else { res.json(["ok": false, "error": "brouillon introuvable"], status: 404); return }
            if let st = l[i]["status"] as? String, st.lowercased().hasPrefix("envoy") { res.json(["ok": false, "error": "déjà envoyé"], status: 409); return }
            // P-DRAFT-3 — L'APERÇU VALIDÉ FAIT FOI, LIÉ PAR EMPREINTE : seuls les champs DU MAGASIN
            // partent (plus aucune surcharge par la requête — WP3 : ni compte ni destinataire) ; la coche dure
            // doit être verte et l'empreinte « expect » affichée par la carte doit égaler l'empreinte recalculée.
            let fails = DraftLint.hardFailures(l[i])
            guard fails.isEmpty else { res.json(["ok": false, "code": "coche_rouge", "error": "coche gabarit en échec : " + fails.map { $0.label }.joined(separator: " · "), "items": fails.map { $0.dict() }], status: 409); return }
            guard let expect = j["expect"] as? String, !expect.isEmpty else { res.json(["ok": false, "code": "expect_manquant", "error": "aperçu non lié : recharge la carte du brouillon puis reconfirme"], status: 400); return }
            guard expect == DraftLint.hash(l[i]) else { res.json(["ok": false, "code": "modifie_depuis_apercu", "error": "le brouillon a changé depuis l'aperçu — relis la nouvelle version puis reconfirme"], status: 409); return }
            // WP3 : le geste ENVOYER sur la carte liée par empreinte = approbation (source ui), consommée
            // atomiquement dans cette requête par le MÊME service que le chat et la voix.
            let uictx = ExecContext(conversationId: "ui", source: .ui, actor: "Ahadi")
            let r = SendApprovals.shared.sendFromUI(draftId: id, expectFNV: expect, ctx: uictx, transport: SendQueue.transport(for: l[i]))
            SendQueue.journal(r, via: "bouton")
            let snap = r.record?.snapshot
            switch r.code {
            case .submitted, .verified:
                if snap?.channel == .teams {
                    let target: String = snap?.recipients.first ?? ""
                    let ev: String = r.record?.submission?.strength.rawValue ?? ""
                    bs.publish("draft_sent", ["id": id, "channel": "teams", "target": target, "verified": false, "state": r.record?.state.rawValue ?? ""])
                    res.json(["ok": true, "channel": "teams", "target": target, "verified": false, "state": r.record?.state.rawValue ?? "", "evidence": ev,
                              "detail": ev == EvidenceStrength.weakReadback.rawValue ? "message relu dans le fil (preuve faible : extrait du texte, pas un reçu)" : "soumis — vérifie le volet avant tout renvoi"])
                } else {
                    let to: [String] = snap?.recipients ?? []
                    let subject: String = snap?.subject ?? ""
                    bs.publish("draft_sent", ["id": id, "to": to.joined(separator: ", "), "subject": subject, "state": r.record?.state.rawValue ?? ""])
                    res.json(["ok": true, "to": to, "subject": subject, "state": r.record?.state.rawValue ?? "", "action": r.record?.actionId ?? ""])
                }
            case .deliveryUnknown, .uncertain:
                res.json(["ok": false, "code": "delivery_unknown", "state": SendState.deliveryUnknown.rawValue, "action": r.record?.actionId ?? "",
                          "error": "Envoi INCERTAIN : " + r.detail + ". Vérifie (Éléments envoyés / fil Teams) avant tout renvoi."], status: 409)
            case .failed:
                res.json(["ok": false, "code": "echec_transport", "error": r.detail], status: 502)
            case .inProgress, .alreadySent:
                res.json(["ok": false, "code": r.code.rawValue, "error": r.detail], status: 409)
            case .notFound:
                res.json(["ok": false, "code": "introuvable", "error": r.detail], status: 404)
            case .changed, .needsApproval, .expired, .wrongScope:
                res.json(["ok": false, "code": "modifie_depuis_apercu", "error": r.detail], status: 409)
            case .refused, .invalid:
                res.json(["ok": false, "code": r.code.rawValue, "error": r.detail], status: 400)
            }
        }
        s.on("GET", "/api/drafts/sent") { _, res in res.json(["items": Array(SendQueue.log.tail(100).reversed())]) }
        // WP4 : registre des envois (états, motifs, force de la preuve) — sans corps, objet ni adresse.
        s.on("GET", "/api/sends") { _, res in res.json(["items": SendApprovals.shared.all().suffix(100).reversed().map { $0.summary }]) }
        // WP4 : Ahadi tranche un envoi incertain (« pas parti ») — interface seulement ; « parti » se prouve par /api/drafts/verify.
        s.on("POST", "/api/sends/resolve") { req, res in
            guard req.headers[SendQueue.headerName] == SendQueue.uiSecret else { res.json(["ok": false, "code": "provenance", "error": "réservé à l'interface de Nova"], status: 403); return }
            let aid: String = (req.json["action"] as? String) ?? ""
            let r = SendApprovals.shared.resolveUnknown(actionId: aid, notSent: (req.json["not_sent"] as? Bool) == true, ctx: ExecContext(conversationId: "ui", source: .ui, actor: "Ahadi"))
            res.json(["ok": r.code == .failed, "detail": r.detail, "state": r.record?.state.rawValue ?? ""], status: r.code == .failed ? 200 : 409)
        }
        // P-DRAFT-3 (re-préparé v6) — PREUVE RELUE. WP4 : vérification de LIVRAISON séparée de la soumission —
        // « verified » seulement si UN message des Éléments envoyés correspond (objet + premier destinataire de
        // l'instantané APPROUVÉ) et que son Message-ID est lu. « Non retrouvé » n'annule pas l'envoi : il le signale
        // pour vérification humaine — jamais un faux vert. Teams : jamais « verified » sans identifiant du fournisseur.
        s.on("POST", "/api/drafts/verify") { req, res in
            let id = (req.json["id"] as? String) ?? ""
            let r = SendApprovals.shared.verify(draftId: id, verifier: MailSentVerifier())
            guard r.record != nil else { res.json(["ok": false, "error": "aucun envoi soumis pour ce brouillon"], status: 404); return }
            let found: Bool = r.code == .verified
            SendQueue.log.add(["draft": id, "action": r.record?.actionId ?? "", "verify": found, "state": r.record?.state.rawValue ?? ""])   // "ts" ajouté par Journal ; ni objet ni corps
            res.json(["ok": true, "verified": found, "state": r.record?.state.rawValue ?? "", "detail": found ? "retrouvé dans les Éléments envoyés (Message-ID lu)" : r.detail])
        }

        // M7 — « Demander à Nova » : Service macOS (main.swift) et Raccourcis Apple (curl + jeton). N'exécute rien : ouvre la bulle pré-remplie.
        s.on("POST", "/api/ask/push") { req, res in
            let t = String(((req.json["text"] as? String) ?? "").prefix(8000)).trimmingCharacters(in: .whitespacesAndNewlines)
            guard !t.isEmpty else { res.json(["ok": false, "error": "texte vide"], status: 400); return }
            let src = String(((req.json["source"] as? String) ?? "raccourci").prefix(40))
            bs.publish("ask", ["text": t, "source": src])
            res.json(["ok": true])
        }
    }
}
