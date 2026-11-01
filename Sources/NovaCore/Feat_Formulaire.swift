import Foundation

// 25/10 : OUTIL « formulaire » — Nova remplit un formulaire web dans ses propres volets (Navigateur, Gmail, Outlook…),
// pour Ahadi, sans jamais l'envoyer seule.
// - lire|<volet>            : liste numérotée des champs visibles de la page (libellé, name/id, type, valeur, requis,
//                             options, sélecteur stable) ; champs protégés listés SANS valeur.
// - remplir|<volet>|<json>  : pose les valeurs {champ: valeur} (setter natif + événements, compatible React), N'ENVOIE RIEN ;
//                             le volet affiche un bandeau « Nova a rempli N champs — vérifie, puis Valider l'envoi (carte) ».
// - soumettre|<volet>       : JAMAIS direct. Carte de confirmation (Tools.needConfirm) avec l'adresse de la page, les
//                             valeurs relues et le libellé du bouton ; seul le GO d'Ahadi clique, et seulement si la page
//                             n'a pas changé depuis la carte (empreinte). Traité comme un ENVOI (règle d'or).
// Exclusions DURES (code, deux côtés : ici et web/js/formfill.js) : mot de passe, carte, CVV, IBAN/RIB, n° de compte,
// sécurité sociale, passeport, pièce d'identité, OTP / code de vérification, CAPTCHA — jamais lus ni remplis.
// Une page atteinte par un lien de mail/document n'est remplie que si Ahadi a nommé cette page dans sa demande.
// Les valeurs viennent du cerveau (dires d'Ahadi + profil/mémoire) : l'outil n'invente rien.
// Côté fenêtre : uibridge.js (op « formulaire ») → formfill.js ; constat via POST /api/ui/result (UIPilot).

public enum NovaForm {
    static let usage: String = "formulaire : lire|<volet> · remplir|<volet>|<json {\"champ\": \"valeur\"}> · soumettre|<volet>. Volet : navigateur (défaut), web, gmail, outlook, teams, linkedin… ; champ = n° de la liste de « lire », sélecteur, name/id ou libellé."

    static let knownPanes: Set<String> = ["navigateur", "nav", "web", "tor", "outlook", "ol", "gmail", "gm", "teams", "tm", "whatsapp", "wa",
                                          "telegram", "tg", "facebook", "fb", "instagram", "ig", "linkedin", "li", "x", "twitter"]
    static let mailPanes: Set<String> = ["outlook", "ol", "gmail", "gm", "teams", "tm", "whatsapp", "wa", "telegram", "tg"]
    /// Hôtes d'origine « mail / document » : une page dont le referrer en vient a été ouverte depuis un lien.
    static let linkOriginHosts: [String] = ["mail.google.com", "outlook.office.com", "outlook.office365.com", "outlook.live.com", "teams.microsoft.com", "teams.live.com",
                                            "docs.google.com", "drive.google.com", "sharepoint.com", "onedrive.live.com", "1drv.ms", "safelinks.protection.outlook.com",
                                            "mail.zoho.com", "mail.zoho.eu", "web.whatsapp.com", "web.telegram.org", "dropbox.com", "notion.so", "mail.yahoo.com"]
    /// Hôte « maison » de chaque volet de messagerie (une page hors de ces hôtes y a été atteinte par un lien).
    static let paneHomeHosts: [String: [String]] = [
        "gmail": ["google.com"], "gm": ["google.com"],
        "outlook": ["office.com", "office365.com", "live.com", "microsoft.com", "microsoftonline.com"], "ol": ["office.com", "office365.com", "live.com", "microsoft.com", "microsoftonline.com"],
        "teams": ["microsoft.com", "live.com", "office.com", "microsoftonline.com"], "tm": ["microsoft.com", "live.com", "office.com", "microsoftonline.com"],
        "whatsapp": ["whatsapp.com"], "wa": ["whatsapp.com"], "telegram": ["telegram.org"], "tg": ["telegram.org"],
    ]
    static let genericHostWords: Set<String> = ["www", "www2", "forms", "form", "app", "apps", "login", "secure", "mail", "docs", "web", "portal", "online", "my", "account", "accounts", "auth", "com", "org", "net", "gouv", "gov"]

    /// Champs protégés (sur libellé / name / clé JSON, texte replié sans accents) — même famille que SENS dans formfill.js.
    static let sensitiveRx: NSRegularExpression = try! NSRegularExpression(pattern: #"(mot de passe|password|passwd|passcode|\bpin\b|code pin|numero de (la )?carte|n° de carte|card ?(number|no|num)|cardnumber|credit ?card|carte (bancaire|de credit)|\bcc-?(number|num|csc|exp|name)|\bcvv|\bcvc|\bcsc\b|cryptogramme|security code|code de securite|\biban\b|\brib\b|\bbic\b|\bswift\b|numero de compte|n° de compte|account ?(number|no|num)|routing|sort code|\bssn\b|social security|securite sociale|passport|passeport|national ?id|identite nationale|carte d.identite|piece d.identite|\bcni\b|\bnin\b|\botp\b|one.?time|code de verification|verification code|code de confirmation|confirmation code|code (recu|envoye) par sms|\b2fa\b|\btotp\b|captcha)"#, options: .caseInsensitive)
    /// Valeurs qui ressemblent à un numéro de carte (13 à 19 chiffres) ou à un IBAN : jamais posées, quel que soit le champ.
    static let cardValueRx: NSRegularExpression = try! NSRegularExpression(pattern: #"^\s*(\d[ -]?){13,19}\s*$"#, options: [])
    static let ibanValueRx: NSRegularExpression = try! NSRegularExpression(pattern: #"^\s*[A-Za-z]{2}\d{2}[ ]?([A-Za-z0-9]{4}[ ]?){3,8}[A-Za-z0-9]{0,4}\s*$"#, options: [])

    static func fold(_ s: String) -> String {
        return s.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: Locale(identifier: "fr_FR")).lowercased()
    }
    static func isSensitive(_ s: String) -> Bool {
        let f: String = fold(s).replacingOccurrences(of: "_", with: " ").replacingOccurrences(of: "-", with: " ")
        return Tools.match(sensitiveRx, f) || Tools.match(sensitiveRx, fold(s))
    }
    static func looksLikeSecretValue(_ v: String) -> Bool {
        if Tools.match(ibanValueRx, v) { return true }
        if !Tools.match(cardValueRx, v) { return false }
        return luhn(v)   // 25/10 : un long numéro de téléphone (13 chiffres) n'est pas une carte — seule une suite valide Luhn est refusée
    }
    static func luhn(_ v: String) -> Bool {
        var digits: [Int] = []
        for ch in v { if let d = ch.wholeNumberValue { digits.append(d) } }
        if digits.count < 13 { return false }
        var sum: Int = 0
        var dbl: Bool = false
        for d in digits.reversed() {
            var x: Int = d
            if dbl {
                x = x * 2
                if x > 9 { x = x - 9 }
            }
            sum += x
            dbl = !dbl
        }
        return sum % 10 == 0
    }
    static func host(_ u: String) -> String {
        guard let url = URL(string: u), let h = url.host else { return "" }
        return h.lowercased()
    }
    static func hostMatches(_ h: String, _ base: String) -> Bool {
        return h == base || h.hasSuffix("." + base)
    }

    /// Vrai si la page a été atteinte par un lien venu d'un mail ou d'un document.
    static func fromLink(pane: String, url: String, referrer: String) -> Bool {
        let h: String = host(url)
        let rh: String = host(referrer)
        if !rh.isEmpty && rh != h {
            for b in linkOriginHosts where hostMatches(rh, b) { return true }
        }
        if h.contains("safelinks") || url.contains("google.com/url?") { return true }
        if let homes = paneHomeHosts[pane] {
            var home: Bool = false
            for b in homes where hostMatches(h, b) { home = true }
            if !home { return true }
        }
        return false
    }
    /// Vrai si la demande d'Ahadi nomme cette page (adresse, hôte ou mot distinctif de l'hôte).
    static func askedFor(url: String, why: String) -> Bool {
        let w: String = fold(why)
        if w.isEmpty { return false }
        var h: String = host(url)
        if h.hasPrefix("www.") { h = String(h.dropFirst(4)) }
        if h.isEmpty { return false }
        if w.contains(h) { return true }
        let labels: [String] = h.split(separator: ".").map { String($0) }
        for l in labels.dropLast() {
            if l.count < 4 || genericHostWords.contains(l) { continue }
            if w.contains(l) { return true }
        }
        return false
    }

    /// 25/10 : vrai booléen JSON (true/false), pas un nombre 0/1 ponté en Bool.
    static func jsonBool(_ v: Any) -> Bool? {
        guard let n = v as? NSNumber else { return nil }
        let t: String = String(cString: n.objCType)
        if t != "c" && t != "B" { return nil }
        return n.boolValue
    }
    static func str(_ v: Any) -> String {
        if let s = v as? String { return s }
        if let b = jsonBool(v) { return b ? "oui" : "non" }
        if let a = v as? [Any] {
            let parts: [String] = a.map { str($0) }
            return parts.joined(separator: ", ")
        }
        return "\(v)"
    }
    static func failText(_ r: [String: Any]) -> String {
        let err: String = (r["erreur"] as? String) ?? "échec sans motif"
        return "ÉCHEC (constaté par la fenêtre) : " + err + "."
    }

    // MARK: outil

    public static func tool(_ arg: String, why: String) -> String {
        var p: [String] = arg.split(separator: "|", maxSplits: 2, omittingEmptySubsequences: false).map { String($0).trimmingCharacters(in: .whitespacesAndNewlines) }
        // 26/10 : formes tolérées « lire @navigateur », « remplir @navigateur {json} », « lire navigateur » (Spark n'écrivait pas les |).
        if let head: String = p.first, head.contains(" ") {
            let ws: [String] = head.split(separator: " ", maxSplits: 2, omittingEmptySubsequences: true).map { String($0) }
            var paneW: String = ws.count > 1 ? ws[1] : ""
            if paneW.hasPrefix("@") { paneW = String(paneW.dropFirst()) }
            if ws.count > 1 && knownPanes.contains(paneW.lowercased()) {
                var rebuilt: [String] = [ws[0], paneW]
                if ws.count > 2 { rebuilt.append(ws[2]) } else if p.count > 1 { rebuilt.append(contentsOf: p.dropFirst()) }
                p = rebuilt
            } else if ws.count > 1 && (ws[1].hasPrefix("{") || ws[1].hasPrefix("[")) {
                p = [ws[0], "navigateur", ws.dropFirst().joined(separator: " ")]
            }
        }
        let verb: String = NovaMedia.norm(p.first ?? "")
        var pane: String = p.count > 1 ? p[1].lowercased() : ""
        if pane.hasPrefix("@") { pane = String(pane.dropFirst()) }
        if pane.isEmpty { pane = "navigateur" }
        if !knownPanes.contains(pane) { return "formulaire : volet inconnu « " + pane + " ». " + usage }
        switch verb {
        case "lire", "champs", "liste":
            return lire(pane)
        case "remplir", "saisir", "fill":
            let json: String = p.count > 2 ? p[2] : ""
            return remplir(pane, json, why: why)
        case "soumettre", "envoyer", "valider", "submit":
            return soumettre(pane, why: why)
        case "effacer", "annuler":
            let r: [String: Any]? = UIPilot.shared.request("formulaire", ["pane": pane, "act": "effacer"], timeout: 15)
            if r == nil { return UIPilot.render(nil) }
            return "Bandeau et surlignage de Nova retirés du volet (les valeurs saisies restent dans la page)."
        default:
            return usage
        }
    }

    static func lire(_ pane: String) -> String {
        guard let r = UIPilot.shared.request("formulaire", ["pane": pane, "act": "lire"], timeout: 30) else { return UIPilot.render(nil) }
        if (r["ok"] as? Bool) != true { return failText(r) }
        let champs: [[String: Any]] = (r["champs"] as? [[String: Any]]) ?? []
        let url: String = (r["url"] as? String) ?? ""
        let titre: String = (r["titre"] as? String) ?? ""
        if champs.isEmpty { return "Aucun champ de formulaire visible sur « " + titre + " » (" + url + ")." }
        var lines: [String] = ["Formulaire — « " + titre + " » (" + url + ") : \(champs.count) champ(s) visibles :"]
        var aToi: [String] = []
        for c in champs {
            let n: Int = (c["n"] as? Int) ?? 0
            let label: String = (c["label"] as? String) ?? ""
            let name: String = (c["name"] as? String) ?? ""
            let id: String = (c["id"] as? String) ?? ""
            let type: String = (c["type"] as? String) ?? ""
            let sel: String = (c["sel"] as? String) ?? ""
            let shown: String = label.isEmpty ? (name.isEmpty ? id : name) : label
            // double garde : le moteur re-teste le libellé / name / id / type, même si la fenêtre n'a rien signalé
            var protege: Bool = (c["sensible"] as? Bool) == true || type == "password"
            if !protege && isSensitive(label + " " + name + " " + id) { protege = true }
            if protege {
                lines.append("\(n)) " + shown + " [" + type + "] — PROTÉGÉ : à remplir par toi (jamais lu ni rempli par Nova)")
                aToi.append(shown)
                continue
            }
            var line: String = "\(n)) " + shown + " [" + type + "]"
            if !name.isEmpty && name != shown { line += " name=" + name }
            if (c["requis"] as? Bool) == true { line += " · requis" }
            if let note = c["note"] as? String, !note.isEmpty { line += " · " + note }
            if let v = c["valeur"] as? String, !v.isEmpty { line += " · valeur « " + v + " »" }
            if let opts = c["options"] as? [String], !opts.isEmpty {
                let o: String = opts.prefix(12).joined(separator: " / ")
                line += " · options : " + o
            }
            line += " · sel " + sel
            lines.append(line)
        }
        if (r["captcha"] as? Bool) == true {
            lines.append("CAPTCHA présent : à résoudre par Ahadi lui-même (Nova ne résout jamais de CAPTCHA).")
        }
        if !aToi.isEmpty { lines.append("À remplir par toi : " + aToi.joined(separator: ", ") + ".") }
        lines.append("Suite : formulaire remplir|" + pane + "|{\"<n° ou libellé>\": \"valeur\"} — valeurs tirées UNIQUEMENT de ce qu'Ahadi a dit ou de son profil/mémoire ; une donnée inconnue reste vide et se demande. Rien n'est envoyé sans soumettre + carte.")
        let out: String = lines.joined(separator: "\n")
        return String(out.prefix(5000))
    }

    static func remplir(_ pane: String, _ json: String, why: String) -> String {
        guard !json.isEmpty, let o = parseJSON(Data(json.utf8)) else { return "formulaire : remplir|<volet>|<json> — JSON objet attendu, ex. {\"1\": \"Ahadi\", \"Adresse e-mail\": \"…\"}." }
        var vals: [String: Any] = [:]
        var refused: [String] = []
        for (k, v) in o {
            let sv: String = str(v)
            if isSensitive(k) {
                refused.append(k)
                continue
            }
            if looksLikeSecretValue(sv) {
                refused.append(k + " (valeur de type carte/IBAN)")
                continue
            }
            if let b = jsonBool(v) { vals[k] = b } else if let a = v as? [Any] { vals[k] = a.map { str($0) } } else { vals[k] = sv }
        }
        if vals.isEmpty {
            if refused.isEmpty { return "formulaire : aucune valeur à remplir." }
            return "Refusé : champs protégés (mot de passe, carte, IBAN, identité, code de vérification…) — à remplir par Ahadi lui-même : " + refused.joined(separator: ", ") + ". Rien n'a été saisi."
        }
        // Règle du lien : une page ouverte depuis un mail / document n'est remplie que si Ahadi l'a nommée.
        guard let og = UIPilot.shared.request("formulaire", ["pane": pane, "act": "origine"], timeout: 15) else { return UIPilot.render(nil) }
        if (og["ok"] as? Bool) != true { return failText(og) }
        let url: String = (og["url"] as? String) ?? ""
        let ref: String = (og["referrer"] as? String) ?? ""
        if fromLink(pane: pane, url: url, referrer: ref) && !askedFor(url: url, why: why) {
            _ = BlackBox.record(["tool": "formulaire", "actor": "Assistant", "why": "refus : page atteinte par un lien (" + host(url) + ")", "ok": false, "effect": "refusé"])
            return "Refusé : cette page (" + host(url) + ") a été atteinte par un lien de mail ou de document, et la demande d'Ahadi ne la nomme pas. Nova ne remplit pas un formulaire venu d'un lien sans que tu demandes cette page précise (cite son adresse ou son site). Rien n'a été saisi."
        }
        guard let r = UIPilot.shared.request("formulaire", ["pane": pane, "act": "remplir", "valeurs": vals], timeout: 30) else { return UIPilot.render(nil) }
        _ = BlackBox.record(["tool": "formulaire", "actor": "Assistant", "why": "remplir " + host(url), "ok": (r["ok"] as? Bool) == true, "effect": "interface"])
        let faits: [[String: Any]] = (r["remplis"] as? [[String: Any]]) ?? []
        let echecs: [[String: Any]] = (r["echecs"] as? [[String: Any]]) ?? []
        var aToi: [String] = (r["a_remplir_par_toi"] as? [String]) ?? []
        for x in refused where !aToi.contains(x) { aToi.append(x) }
        var lines: [String] = []
        if faits.isEmpty {
            lines.append("ÉCHEC (constaté par la fenêtre) : aucun champ rempli sur " + url + ".")
        } else {
            lines.append("CONSTAT VÉRIFIÉ (valeurs relues dans la page) — \(faits.count) champ(s) rempli(s) sur " + url + ", RIEN n'est envoyé :")
            for f in faits {
                let champ: String = (f["champ"] as? String) ?? "?"
                let val: String = (f["valeur"] as? String) ?? ""
                lines.append("- " + champ + " : « " + val + " »")
            }
        }
        if !echecs.isEmpty {
            var parts: [String] = []
            for e in echecs {
                let champ: String = (e["champ"] as? String) ?? "?"
                let err: String = (e["erreur"] as? String) ?? "échec"
                parts.append(champ + " (" + err + ")")
            }
            lines.append("Non remplis : " + parts.joined(separator: " ; ") + ".")
        }
        if !aToi.isEmpty { lines.append("À remplir par toi (protégés, laissés vides) : " + aToi.joined(separator: ", ") + ".") }
        if !faits.isEmpty { lines.append("Le volet affiche le bandeau « Nova a rempli … — vérifie, puis Valider l'envoi (carte) ». Envoi : formulaire soumettre|" + pane + " (carte de confirmation, GO d'Ahadi obligatoire).") }
        return String(lines.joined(separator: "\n").prefix(4000))
    }

    static func soumettre(_ pane: String, why: String) -> String {
        if why.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return "Refusé : envoyer un formulaire n'est permis que dans la conversation avec Ahadi, sur sa demande (jamais depuis un Dot, un relais ou un mail). Rien n'a été envoyé."
        }
        guard let r = UIPilot.shared.request("formulaire", ["pane": pane, "act": "resume"], timeout: 20) else { return UIPilot.render(nil) }
        if (r["ok"] as? Bool) != true { return failText(r) }
        let url: String = (r["url"] as? String) ?? ""
        let bouton: String = (r["bouton"] as? String) ?? ""
        let emp: String = (r["empreinte"] as? String) ?? ""
        if (r["paiement"] as? Bool) == true {
            return "Refusé : le bouton « " + bouton + " » engage un paiement ou une commande — Nova ne paie jamais. À valider par Ahadi lui-même dans le volet. Rien n'a été envoyé."
        }
        if (r["captcha"] as? Bool) == true && (r["captcha_resolu"] as? Bool) != true {
            return "ÉCHEC : un CAPTCHA non résolu protège ce formulaire — à résoudre par Ahadi lui-même dans le volet (Nova n'en résout jamais), puis redemande l'envoi. Rien n'a été envoyé."
        }
        let champs: [[String: Any]] = (r["champs"] as? [[String: Any]]) ?? []
        let sensibles: [String] = (r["sensibles"] as? [String]) ?? []
        var card: [String] = ["formulaire soumettre|" + pane, "Page : " + url, "Bouton cliqué : « " + bouton + " »", "Valeurs :"]
        if champs.isEmpty { card.append("- (aucune valeur relue)") }
        for c in champs.prefix(30) {
            let l: String = (c["label"] as? String) ?? "?"
            let v: String = (c["valeur"] as? String) ?? ""
            card.append("- " + l + " : " + v)
        }
        if !sensibles.isEmpty { card.append("Champs protégés (non lus par Nova) : " + sensibles.joined(separator: ", ")) }
        let cmd: String = card.joined(separator: "\n")
        // RÈGLE D'OR : carte à chaque fois (needConfirm ignore autorisation_totale) ; la clé contient la page, les valeurs
        // et le bouton : si quoi que ce soit change avant le GO, une nouvelle carte est demandée.
        if let m = Tools.needConfirm(cmd, kind: "ENVOI d'un formulaire web — rien ne part sans ton GO (vérifie la page, les valeurs et le bouton)") { return m }
        guard let s = UIPilot.shared.request("formulaire", ["pane": pane, "act": "soumettre", "empreinte": emp, "confirmed": true], timeout: 30) else { return UIPilot.render(nil) }
        let ok: Bool = (s["ok"] as? Bool) == true
        _ = BlackBox.record(["tool": "formulaire", "actor": "Assistant", "why": "soumettre " + host(url) + " après GO d'Ahadi (bouton « " + bouton + " »)", "ok": ok, "effect": "envoi"])
        if !ok { return failText(s) + " Rien n'a été envoyé." }
        let effet: [String: Any] = (s["effet"] as? [String: Any]) ?? [:]
        let apres: String = (effet["url_apres"] as? String) ?? ""
        let titre: String = (effet["titre_apres"] as? String) ?? ""
        let extrait: String = (effet["extrait_apres"] as? String) ?? ""
        var out: String = "CONSTAT : formulaire envoyé après le GO d'Ahadi — clic sur « " + bouton + " » (" + url + ")."
        if !apres.isEmpty { out += " Page ensuite : " + apres + (titre.isEmpty ? "" : " — « " + titre + " »") + "." }
        if !extrait.isEmpty { out += " Début du texte affiché : " + String(extrait.prefix(240)) }
        out += " Vérifie le message de confirmation du site avant de dire que la demande est acceptée."
        return out
    }
}
