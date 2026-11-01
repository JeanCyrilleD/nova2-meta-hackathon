import Foundation
import NovaFoundation

// 26/10 (Ahadi : « il n'arrive pas à faire directement des brouillons de mail dans Outlook, Gmail et Teams ») —
// outil « mail_brouillon » : dépose un BROUILLON là où Ahadi l'attend, sans jamais rien envoyer.
//  · Gmail : IMAP APPEND dans le dossier \Drafts du compte (IMAP ne sait pas envoyer) — visible partout.
//  · Outlook : volet Outlook web de Nova, en arrière-plan : « Nouveau message », destinataires, objet, corps ;
//    Outlook enregistre le brouillon sur le serveur — visible dans Outlook partout. Jamais de clic sur Envoyer, jamais Entrée.
//  · Teams : le texte est posé dans la zone de saisie de la conversation demandée (volet Teams de Nova), sans Entrée.
// Réservé à l'assistant de conversation, sur demande explicite d'Ahadi (même règle que draft_reply).
public enum MailBrouillon {
    static func esc(_ s: String) -> String {
        s.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;").replacingOccurrences(of: ">", with: "&gt;")
    }

    /// Corps → HTML (déjà en HTML : tel quel ; sinon paragraphes et sauts de ligne).
    static func html(_ body: String) -> String {
        let t: String = body.trimmingCharacters(in: .whitespacesAndNewlines)
        if t.range(of: #"<(p|div|br|ul|ol|li|b|strong|table|h[1-6])[\s>/]"#, options: [.regularExpression, .caseInsensitive]) != nil { return t }
        let paras: [String] = t.components(separatedBy: "\n\n")
        var out: String = ""
        for p in paras {
            let inner: String = esc(p).replacingOccurrences(of: "\n", with: "<br>")
            out += "<p>"
            out += inner
            out += "</p>"
        }
        return out
    }

    /// HTML → texte brut (pour Teams).
    static func plain(_ body: String) -> String {
        var t: String = body.replacingOccurrences(of: #"(?i)<br\s*/?>"#, with: "\n", options: .regularExpression)
        t = t.replacingOccurrences(of: #"(?i)</(p|div|li|h[1-6])>"#, with: "\n", options: .regularExpression)
        t = t.replacingOccurrences(of: #"(?i)<li[^>]*>"#, with: "• ", options: .regularExpression)
        t = t.replacingOccurrences(of: #"<[^>]+>"#, with: "", options: .regularExpression)
        t = t.replacingOccurrences(of: "&nbsp;", with: " ").replacingOccurrences(of: "&amp;", with: "&").replacingOccurrences(of: "&lt;", with: "<").replacingOccurrences(of: "&gt;", with: ">")
        t = t.replacingOccurrences(of: #"\n{3,}"#, with: "\n\n", options: .regularExpression)
        return t.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// En-tête RFC 2047 (UTF-8, base64) si non ASCII.
    static func hdr(_ s: String) -> String {
        if s.allSatisfy({ (c: Character) -> Bool in c.isASCII }) { return s }
        return "=?UTF-8?B?" + Data(s.utf8).base64EncodedString() + "?="
    }

    static func addrList(_ s: String) -> String {
        let parts: [String] = s.components(separatedBy: CharacterSet(charactersIn: ",;")).map { (x: String) -> String in x.trimmingCharacters(in: .whitespaces) }.filter { (x: String) -> Bool in !x.isEmpty }
        return parts.joined(separator: ", ")
    }

    static func rfc822(from: String, to: String, cc: String, subject: String, html: String) -> Data {
        let df: DateFormatter = DateFormatter()
        df.locale = Locale(identifier: "en_US_POSIX")
        df.dateFormat = "EEE, dd MMM yyyy HH:mm:ss Z"
        var lines: [String] = []
        lines.append("From: " + from)
        if !to.isEmpty { lines.append("To: " + addrList(to)) }
        if !cc.isEmpty { lines.append("Cc: " + addrList(cc)) }
        lines.append("Subject: " + hdr(subject))
        lines.append("Date: " + df.string(from: Date()))
        lines.append("MIME-Version: 1.0")
        lines.append("Content-Type: text/html; charset=UTF-8")
        lines.append("Content-Transfer-Encoding: base64")
        lines.append("")
        let page: String = "<html><head><meta charset=\"utf-8\"></head><body>" + html + "</body></html>"
        let b64: String = Data(page.utf8).base64EncodedString(options: [.lineLength76Characters, .endLineWithCarriageReturn, .endLineWithLineFeed])
        lines.append(b64)
        return Data(lines.joined(separator: "\r\n").utf8)
    }

    static func gmail(to: String, cc: String, subject: String, body: String) -> String {
        Gmail.lock.lock()
        let o: [String: Any] = Gmail.load()
        Gmail.lock.unlock()
        let account: String = (o["account"] as? String) ?? ""
        guard (o["connected"] as? Bool) == true, !account.isEmpty else { return "Brouillon Gmail non créé : Gmail n'est pas connecté dans Nova (Réglages › Connexions)." }
        guard let pw: String = KeychainStore().value(KnownKeys.gmail), !pw.isEmpty else { return "Brouillon Gmail non créé : mot de passe d'application absent du Trousseau (reconnecte Gmail dans Réglages)." }
        let c: ZohoIMAPClient = ZohoIMAPClient()
        defer { c.close() }
        if let e: String = c.connect(host: Gmail.host, port: 993, timeout: 15) { return "Brouillon Gmail non créé : serveur injoignable (" + e + ")." }
        guard c.greeting(timeout: 15) else { return "Brouillon Gmail non créé : le serveur n'a pas répondu." }
        let lr: ZohoReply = c.login(email: account, password: pw)
        guard lr.status == "OK" else { return "Brouillon Gmail non créé : Google refuse la connexion (" + lr.status + ")." }
        guard let box: String = c.draftsMailbox() else { _ = c.command("LOGOUT", ""); return "Brouillon Gmail non créé : dossier des brouillons introuvable sur le compte." }
        let msg: Data = rfc822(from: account, to: to, cc: cc, subject: subject, html: html(body))
        let r: ZohoReply = c.appendDraft(mailbox: box, message: msg)
        _ = c.command("LOGOUT", "")
        guard r.status == "OK" else { return "Brouillon Gmail non créé : le serveur a répondu " + r.status + " (" + String(r.text.prefix(120)) + ")." }
        _ = BlackBox.record(["tool": "mail_brouillon", "actor": "Nova", "why": "brouillon Gmail déposé à la demande d'Ahadi (« " + String(subject.prefix(80)) + " »), rien envoyé", "ok": true, "effect": "écrit"])
        return "✅ Brouillon Gmail créé dans « " + box + " » du compte " + account + " — objet « " + subject + " »" + (to.isEmpty ? "" : ", pour " + addrList(to)) + ". Rien n'est envoyé : ouvre Brouillons dans Gmail pour relire et envoyer toi-même."
    }

    static func viaPane(pane: String, args: [String: Any], label: String) -> String {
        var a: [String: Any] = args
        a["pane"] = pane
        a["sub"] = "brouillon"
        guard let r: [String: Any] = UIPilot.shared.request("page", a, timeout: 70) else {
            return "Brouillon " + label + " non créé : la fenêtre de Nova n'a pas répondu (volet " + label + " injoignable)."
        }
        let ok: Bool = (r["ok"] as? Bool) ?? false
        let msg: String = (r["message"] as? String) ?? ((r["erreur"] as? String) ?? "")
        if ok {
            _ = BlackBox.record(["tool": "mail_brouillon", "actor": "Nova", "why": "brouillon " + label + " déposé à la demande d'Ahadi, rien envoyé", "ok": true, "effect": "écrit"])
            return "✅ " + msg
        }
        return "Brouillon " + label + " non créé : " + (msg.isEmpty ? "échec sans motif" : msg)
    }

    /// Argument JSON : {"boite":"gmail|outlook|teams","a":"…","cc":"…","objet":"…","corps":"…","conversation":"…"}.
    public static func tool(_ arg: String) -> String {
        guard let o: [String: Any] = parseJSON(Data(arg.utf8)) else { return "mail_brouillon : JSON attendu {\"boite\",\"a\",\"cc\",\"objet\",\"corps\",\"conversation\"}." }
        let boite: String = ((o["boite"] as? String) ?? "").lowercased()
        let to: String = (o["a"] as? String) ?? ((o["to"] as? String) ?? "")
        let cc: String = (o["cc"] as? String) ?? ""
        let subject: String = (o["objet"] as? String) ?? ((o["subject"] as? String) ?? "")
        let body: String = (o["corps"] as? String) ?? ((o["body"] as? String) ?? "")
        if body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return "mail_brouillon : corps vide — rédige le texte complet avant de déposer le brouillon." }
        if boite.contains("gmail") || boite == "gm" {
            return gmail(to: to, cc: cc, subject: subject, body: body)
        }
        if boite.contains("outlook") || boite == "ol" {
            return viaPane(pane: "outlook", args: ["a": addrList(to), "cc": addrList(cc), "objet": subject, "html": html(body)], label: "Outlook")
        }
        if boite.contains("teams") || boite == "tm" {
            let conv: String = (o["conversation"] as? String) ?? to
            if conv.trimmingCharacters(in: .whitespaces).isEmpty { return "mail_brouillon Teams : précise « conversation » (nom de la personne ou du groupe)." }
            return viaPane(pane: "teams", args: ["conversation": conv, "texte": plain(body)], label: "Teams")
        }
        return "mail_brouillon : « boite » doit valoir gmail, outlook ou teams."
    }
}


// 29/10 : dépôt d'un brouillon DANS la boîte depuis une carte du Fil direct (clic d'Ahadi = sa demande explicite).
extension NovaApp {
    func brouillonBoiteRoutes() {
        server.on("POST", "/api/brouillon/boite") { req, res in
            var o: [String: Any] = [:]
            o["boite"] = (req.json["boite"] as? String) ?? ""
            o["a"] = (req.json["a"] as? String) ?? ""
            o["conversation"] = (req.json["conversation"] as? String) ?? ""
            o["objet"] = (req.json["objet"] as? String) ?? ""
            o["corps"] = (req.json["corps"] as? String) ?? ""
            let arg: String = jsonString(o)
            let r: String = MailBrouillon.tool(arg)
            let ok: Bool = r.hasPrefix("✅")
            let msg: String = ok ? String(r.dropFirst(2)) : r
            let out: [String: Any] = ["ok": ok, "message": msg]
            res.json(out)
        }
    }
}
