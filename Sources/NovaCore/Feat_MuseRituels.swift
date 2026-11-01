import Foundation

// 26/10 (Ahadi : « ajoute-les directement en arrière-plan ») — RITUELS MUSE, calqués sur les vrais envois
// proactifs de Muse des 25-26/10 (muse_messages_classes.md) :
//   1. 🤝 Contact de la semaine — lundi 10:30 : UNE personne à relancer, « pourquoi maintenant », angle proposé.
//   2. 📧 Passe mail commentée — 08:30 et 17:30 : chaque message arrivé depuis la dernière passe, une ligne de
//      commentaire chacun (à traiter / à ignorer / info), lecture seule rappelée.
//   3. ⚠️ Mouvements d'argent anormaux — à chaque arrivée bancaire : mouvement miroir (même montant débité ET reçu
//      en 72 h) ou montant au-dessus du seuil (« argent_seuil », défaut 250 000 FCFA). Règles fermées, aucun cerveau.
//   4. Antisèche avant réunion — vers T-2 h : ce qu'il faut obtenir, les phrases exactes à dire, ce qu'il faut éviter.
//   (5. La dictée du soir sans pression est le rituel existant JournalSoir, au ton de Muse depuis le 26/10.)
// Tout part au Fil direct (kind « muse », texte déjà composé). Rien n'est envoyé à personne : Nova propose, Ahadi décide.
// Interrupteurs : muse_contact, muse_passe_mail, muse_argent, muse_antiseche (défaut : vrai).

enum MuseRituels {
    static let file: JSONFile = JSONFile("muse_rituels.json")
    static let lock: NSLock = NSLock()
    nonisolated(unsafe) static var started: Bool = false

    static func state() -> [String: Any] { lock.lock(); defer { lock.unlock() }; return file.read(default: [String: Any]()) }
    static func done(_ key: String) -> Bool {
        let d: [String: Any] = (state()["done"] as? [String: Any]) ?? [:]
        return d[key] != nil
    }
    static func mark(_ key: String) {
        lock.lock(); defer { lock.unlock() }
        var o: [String: Any] = file.read(default: [String: Any]())
        var d: [String: Any] = (o["done"] as? [String: Any]) ?? [:]
        d[key] = nowISO()
        if d.count > 400 {
            let keep: [String] = Array(d.keys.sorted { (a: String, b: String) -> Bool in ((d[a] as? String) ?? "") < ((d[b] as? String) ?? "") }.suffix(300))
            var t: [String: Any] = [:]
            for k in keep { t[k] = d[k] }
            d = t
        }
        o["done"] = d
        file.write(o)
    }
    static func setValue(_ k: String, _ v: Any) {
        lock.lock(); defer { lock.unlock() }
        var o: [String: Any] = file.read(default: [String: Any]())
        o[k] = v
        file.write(o)
    }

    static func dayKey(_ d: Date = Date()) -> String {
        let f: DateFormatter = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        return f.string(from: d)
    }

    static func salut(_ d: Date = Date()) -> String {
        let h: Int = Calendar.current.component(.hour, from: d)
        if h >= 5 && h < 12 { return "Bonjour, Ahadi 👋" }
        if h >= 12 && h < 18 { return "Bon après-midi, Ahadi 👋" }
        return "Bonsoir, Ahadi 👋"
    }

    // MARK: argent — analyse des montants (règles fermées)

    /// Montant en FCFA lu dans un texte bancaire (« CFA 400,000.00 », « 400 000 FCFA », « XOF 25.000 ») ; nil si absent.
    static func amount(_ text: String) -> Double? {
        let pats: [String] = [#"(?:F\s?CFA|CFA|XOF)\s*([0-9][0-9 .,\x{202F}\x{00A0}]*[0-9])"#, #"([0-9][0-9 .,\x{202F}\x{00A0}]*[0-9])\s*(?:F\s?CFA|FCFA|CFA|XOF)"#]
        for p in pats {
            guard let r = text.range(of: p, options: [.regularExpression, .caseInsensitive]) else { continue }
            let chunk: String = String(text[r])
            guard let n = chunk.range(of: #"[0-9][0-9 .,\x{202F}\x{00A0}]*[0-9]"#, options: .regularExpression) else { continue }
            var num: String = String(chunk[n]).replacingOccurrences(of: " ", with: "").replacingOccurrences(of: "\u{202F}", with: "").replacingOccurrences(of: "\u{00A0}", with: "")
            // « 400,000.00 » (virgule = milliers) ; « 400.000 » (point = milliers) ; « 1 250,50 » (virgule = décimales)
            if num.contains(",") && num.contains(".") {
                num = num.replacingOccurrences(of: ",", with: "")
            } else if num.contains(",") {
                let parts: [String] = num.components(separatedBy: ",")
                if parts.count == 2 && parts[1].count != 3 { num = parts[0] + "." + parts[1] } else { num = num.replacingOccurrences(of: ",", with: "") }
            } else if num.contains(".") {
                let parts: [String] = num.components(separatedBy: ".")
                if parts.count > 2 || (parts.count == 2 && parts[1].count == 3) { num = num.replacingOccurrences(of: ".", with: "") }
            }
            if let v = Double(num), v > 0 { return v }
        }
        return nil
    }

    /// « debit » | « credit » | « » selon les mots du message.
    static func direction(_ text: String) -> String {
        let t: String = text.lowercased()
        let deb: [String] = ["débit", "debit", "débité", "debite", "retrait", "paiement effectué", "transfert envoyé", "envoyé", "prélèvement"]
        let cre: [String] = ["reçu", "recu", "crédit", "credit", "crédité", "credite", "versement", "dépôt", "depot", "transfert reçu"]
        let isD: Bool = deb.contains { (w: String) -> Bool in t.contains(w) }
        let isC: Bool = cre.contains { (w: String) -> Bool in t.contains(w) }
        if isD && !isC { return "debit" }
        if isC && !isD { return "credit" }
        if isD && isC { return t.range(of: #"d[ée]bit"#, options: .regularExpression) != nil ? "debit" : "credit" }
        return ""
    }

    static func isBank(_ who: String, _ text: String) -> Bool {
        let s: String = (who + " " + text).lowercased()
        let marks: [String] = ["redpay", "uba", "ecobank", "orange money", "moov money", "wave", "coris", "sgbf", "bicia", "boa ", "bank of africa", "banque", "bank", "transaction", "alerte de crédit", "alerte de débit", "mobile money", "visa", "mastercard"]
        return marks.contains { (m: String) -> Bool in s.contains(m) }
    }

    static func fmtFCFA(_ v: Double) -> String {
        let f: NumberFormatter = NumberFormatter()
        f.locale = Locale(identifier: "fr_FR")
        f.numberStyle = .decimal
        f.maximumFractionDigits = 0
        return (f.string(from: NSNumber(value: v)) ?? String(Int(v))) + " FCFA"
    }
}

extension NovaApp {
    func museRitualsStart() {
        if MuseRituels.started { return }
        MuseRituels.started = true
        Thread.detachNewThread { [weak self] in
            Thread.sleep(forTimeInterval: 90)
            while true {
                if let s = self { s.museTick() } else { return }
                Thread.sleep(forTimeInterval: 60)
            }
        }
    }

    func museTick() {
        let now: Date = Date()
        let cal: Calendar = Calendar.current
        let h: Int = cal.component(.hour, from: now)
        let m: Int = cal.component(.minute, from: now)
        let hm: Int = h * 60 + m
        let day: String = MuseRituels.dayKey(now)
        if settings.get("muse_argent", true) { museMoneyScan() }
        if settings.get("muse_antiseche", true) { museAntiseche() }
        if settings.get("muse_passe_mail", true) {
            for (label, at) in [("matin", 8 * 60 + 30), ("soir", 17 * 60 + 30)] where hm >= at && hm < at + 90 {
                let key: String = "passe|" + day + "|" + label
                if !MuseRituels.done(key) { MuseRituels.mark(key); musePasseMail(label: label) }
            }
        }
        if settings.get("muse_contact", true) {
            let wd: Int = cal.component(.weekday, from: now)   // 2 = lundi
            let wk: String = String(cal.component(.yearForWeekOfYear, from: now)) + "-S" + String(cal.component(.weekOfYear, from: now))
            if wd == 2 && hm >= 10 * 60 + 30 && hm < 18 * 60 {
                let key: String = "contact|" + wk
                if !MuseRituels.done(key) { MuseRituels.mark(key); museContactSemaine() }
            }
        }
    }

    // MARK: 1 · Contact de la semaine

    func museContactSemaine() {
        let rel: Any = ameDoc("relations")
        let relTxt: String = String((String(data: jsonData(rel), encoding: .utf8) ?? "").prefix(3500))
        let co: [String: Any] = JSONFile("commitments.json").read(default: [String: Any]())
        let items: [[String: Any]] = (co["items"] as? [[String: Any]]) ?? []
        var eng: [String] = []
        for it in items.reversed() where ((it["status"] as? String) ?? "ouvert") == "ouvert" {
            let quoi: String = (it["quoi"] as? String) ?? ""
            let qui: String = (it["qui"] as? String) ?? ""
            if quoi.isEmpty || qui.isEmpty { continue }
            eng.append("- " + quoi + " (" + qui + ", " + (((it["dir"] as? String) ?? "moi") == "eux" ? "attendu de lui/elle" : "promis par Ahadi") + ((it["echeance"] as? String).map { ", échéance " + $0 } ?? "") + ")")
            if eng.count >= 15 { break }
        }
        let since: String = ISO8601DateFormatter().string(from: Date().addingTimeInterval(-21 * 86400))
        var mails: [String] = []
        for ev in ProactiveFeed.list(limit: 400, since: since) {
            let k: String = (ev["kind"] as? String) ?? ""
            if k != "mail.new" && k != "teams.new" { continue }
            let who: String = (ev["who"] as? String) ?? ""
            if who.isEmpty || MuseRituels.isBank(who, "") { continue }
            let ts: String = String(((ev["ts"] as? String) ?? "").prefix(10))
            mails.append("- " + ts + " · " + who + " — " + String(((ev["title"] as? String) ?? "").prefix(110)))
            if mails.count >= 40 { break }
        }
        let memTxt: String = memory.promptBlock(max: 10, query: "contact relation réseau invitation relance partenaire")
        let sys: String = "Tu es Nova, l'assistante d'Ahadi (tutoiement, style direct et chaleureux de Muse). Tu choisis UN contact de la semaine à (re)prendre, uniquement à partir des données fournies : une invitation restée sans réponse, un échange qui s'est arrêté, un engagement envers cette personne, un périmètre qui recoupe son travail du moment. Format EXACT, rien d'autre :\n🤝 Contact de la semaine : <Prénom Nom> (<rôle, organisation si connus>).\nPourquoi maintenant : <1-2 phrases datées, tirées des données>.\nAngle proposé, à toi seul d'envoyer : <l'approche en 1-2 phrases, concrète>.\nRien ne part sans ton GO.\nSi aucune donnée ne fonde un choix solide, réponds exactement « RIEN »."
        let user: String = "RELATIONS (Âme) :\n" + relTxt + "\n\nENGAGEMENTS OUVERTS :\n" + eng.joined(separator: "\n") + "\n\nÉCHANGES RÉCENTS (21 jours, expéditeurs) :\n" + mails.joined(separator: "\n") + "\n\nMÉMOIRE :\n" + memTxt
        let det = router.completeDetailed(messages: [ChatMsg("user", user)], system: sys, mode: "bulk", preferred: settings.get("brain", "spark-1.3"), maxTokens: 2500, deadline: 120, solo: true)
        guard let r = det.result else { return }
        let t: String = r.text.trimmingCharacters(in: .whitespacesAndNewlines)
        if t.isEmpty || t.uppercased().hasPrefix("RIEN") || !t.contains("Contact de la semaine") { return }
        ProactiveFeed.append(kind: "muse", box: "contact", title: "Contact de la semaine", text: t, extra: ["rituel": "contact"])
    }

    // MARK: 2 · Passe mail commentée

    func musePasseMail(label: String) {
        let st: [String: Any] = MuseRituels.state()
        let last: String = (st["passe_last"] as? String) ?? ISO8601DateFormatter().string(from: Date().addingTimeInterval(-16 * 3600))
        MuseRituels.setValue("passe_last", nowISO())
        var lines: [String] = []
        for ev in ProactiveFeed.list(limit: 300, since: last).reversed() {
            let k: String = (ev["kind"] as? String) ?? ""
            if k != "mail.new" && k != "teams.new" { continue }
            let who: String = (ev["who"] as? String) ?? ""
            let box: String = (ev["box"] as? String) ?? ""
            let ts: String = (ev["ts"] as? String) ?? ""
            let txt: String = SecretsGuard.redact(String(((ev["text"] as? String) ?? "").prefix(500)))
            lines.append("- [" + box + "] " + ts + " · " + who + " — « " + String(((ev["title"] as? String) ?? "").prefix(140)) + " » : " + txt.replacingOccurrences(of: "\n", with: " "))
            if lines.count >= 30 { break }
        }
        let quand: String = label == "matin" ? "du matin" : "du soir"
        if lines.isEmpty {
            ProactiveFeed.append(kind: "muse", box: "passe", title: "Passe mail " + quand, text: "📧 Passe mail " + quand + " : aucun nouveau message depuis le dernier point.\nRien lu, déplacé ou marqué — lecture seule.", extra: ["rituel": "passe"])
            return
        }
        let sys: String = "Tu es Nova, l'assistante d'Ahadi (tutoiement, style direct de Muse). Tu fais la passe mail commentée. Format EXACT :\nLigne 1 : « 📧 Passe mail " + quand + " — » + une accroche d'une phrase (ce qui ressort : une porte qui se ferme, une réponse attendue, ou « rien d'urgent »).\nPuis « Ce qui demande ton attention : » avec les messages qui attendent une action de lui (s'il y en a), puis « Le reste : ».\nUne ligne par message : « Expéditeur, JJ/MM HH:MM — « objet » : » + UN commentaire court (ce que c'est, à traiter / à ignorer / pour info, et pourquoi). Regroupe en une ligne les notifications automatiques du même expéditeur. Ne reproduis jamais un code, un mot de passe ou un lien.\nDernière ligne exacte : « Rien lu, déplacé ou marqué — lecture seule. »\nN'invente rien au-delà des données."
        let det = router.completeDetailed(messages: [ChatMsg("user", "MESSAGES ARRIVÉS DEPUIS LE DERNIER POINT :\n" + lines.joined(separator: "\n"))], system: sys, mode: "bulk", preferred: settings.get("brain", "spark-1.3"), maxTokens: 3000, deadline: 150, solo: true)
        var t: String = det.result?.text.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if t.isEmpty {
            t = "📧 Passe mail " + quand + " — " + String(lines.count) + " message(s) depuis le dernier point (tri rédigé indisponible, liste brute) :\n" + lines.prefix(15).joined(separator: "\n") + "\nRien lu, déplacé ou marqué — lecture seule."
        }
        ProactiveFeed.append(kind: "muse", box: "passe", title: "Passe mail " + quand, text: t, extra: ["rituel": "passe"])
    }

    // MARK: 3 · Mouvements d'argent anormaux

    func museMoneyScan() {
        let st: [String: Any] = MuseRituels.state()
        let since: String = (st["argent_last"] as? String) ?? ISO8601DateFormatter().string(from: Date().addingTimeInterval(-3600))
        let evs: [[String: Any]] = ProactiveFeed.list(limit: 200, since: since).reversed()
        if evs.isEmpty { return }
        MuseRituels.setValue("argent_last", (evs.last?["ts"] as? String) ?? nowISO())
        var hist: [[String: Any]] = (st["argent"] as? [[String: Any]]) ?? []
        let seuil: Double = settings.get("argent_seuil", 250000.0)
        let iso: ISO8601DateFormatter = ISO8601DateFormatter()
        for ev in evs {
            let k: String = (ev["kind"] as? String) ?? ""
            if k != "mail.new" { continue }
            let who: String = (ev["who"] as? String) ?? ""
            let txt: String = ((ev["title"] as? String) ?? "") + " " + ((ev["text"] as? String) ?? "")
            guard MuseRituels.isBank(who, txt), let amt = MuseRituels.amount(txt) else { continue }
            let dir: String = MuseRituels.direction(txt)
            let ts: String = (ev["ts"] as? String) ?? nowISO()
            let src: String = who.components(separatedBy: "@").last.map { (d: String) -> String in d.components(separatedBy: ".").first ?? d } ?? who
            let srcName: String = src.isEmpty ? "Banque" : String(src.prefix(1)).uppercased() + String(src.dropFirst())
            let now: Date = iso.date(from: ts) ?? Date()
            // miroir : même montant, sens opposé, dans les 72 h
            if !dir.isEmpty, let twin = hist.first(where: { (x: [String: Any]) -> Bool in
                let a: Double = (x["montant"] as? Double) ?? -1
                let d: String = (x["sens"] as? String) ?? ""
                let t: Date = iso.date(from: (x["ts"] as? String) ?? "") ?? .distantPast
                return abs(a - amt) < 0.5 && !d.isEmpty && d != dir && now.timeIntervalSince(t) < 72 * 3600
            }) {
                let key: String = "argent|miroir|" + String(Int(amt)) + "|" + String(ts.prefix(13))
                if !MuseRituels.done(key) {
                    MuseRituels.mark(key)
                    let avant: String = String(((twin["ts"] as? String) ?? "").prefix(16)).replacingOccurrences(of: "T", with: " ")
                    let prev: [[String: Any]] = hist.filter { (x: [String: Any]) -> Bool in ((x["miroir"] as? Bool) ?? false) }
                    var t: String = "⚠️ " + srcName + ", à l'instant : **" + MuseRituels.fmtFCFA(amt) + " débités ET reçus** — mouvement miroir (l'autre sens est passé le " + avant + ")."
                    if let p = prev.last, let pa = p["montant"] as? Double { t += " Même schéma qu'avant avec " + MuseRituels.fmtFCFA(pa) + ", toujours sans explication visible." }
                    t += "\nUn débit et un crédit identiques, ça ressemble à une opération en attente de contrepartie — ou à quelque chose à vérifier. Tu reconnais celui-ci ?"
                    ProactiveFeed.append(kind: "muse", box: "argent", title: "Mouvement d'argent à vérifier", text: t, urgent: true, extra: ["rituel": "argent"])
                }
                hist.append(["montant": amt, "sens": dir, "ts": ts, "src": srcName, "miroir": true])
                continue
            }
            if amt >= seuil {
                let key: String = "argent|seuil|" + String(Int(amt)) + "|" + String(ts.prefix(13))
                if !MuseRituels.done(key) {
                    MuseRituels.mark(key)
                    let sensTxt: String = dir == "debit" ? "débités" : (dir == "credit" ? "reçus" : "en mouvement")
                    let t: String = "⚠️ " + srcName + " : **" + MuseRituels.fmtFCFA(amt) + " " + sensTxt + "** — au-dessus de ton seuil de vigilance (" + MuseRituels.fmtFCFA(seuil) + ").\nC'est bien toi ? Si tu ne reconnais pas ce mouvement, appelle ta banque depuis le numéro officiel — jamais depuis un lien reçu."
                    ProactiveFeed.append(kind: "muse", box: "argent", title: "Mouvement d'argent important", text: t, urgent: dir == "debit", extra: ["rituel": "argent"])
                }
            }
            hist.append(["montant": amt, "sens": dir, "ts": ts, "src": srcName])
        }
        MuseRituels.setValue("argent", Array(hist.suffix(80)))
    }

    // MARK: 4 · Antisèche avant réunion (≈ T-2 h)

    func museAntiseche() {
        let evs: [[String: Any]] = dailyEvents(force: false)
        let now: Double = Date().timeIntervalSince1970
        for e in evs {
            let ts: Double = (e["ts"] as? Double) ?? 0
            let mins: Double = (ts - now) / 60
            if mins < 100 || mins > 130 { continue }
            let key: String = (e["key"] as? String) ?? ""
            let title: String = (e["title"] as? String) ?? ""
            if key.isEmpty || title.isEmpty { continue }
            let mk: String = "anti|" + key
            if MuseRituels.done(mk) { continue }
            MuseRituels.mark(mk)
            let hhmm: String = (e["hhmm"] as? String) ?? ""
            var entry: [String: Any] = dailyPrepGet(key) ?? [:]
            if (entry["status"] as? String) != "pret" { entry = dailyPrepare(key: key, title: title, when: (e["label"] as? String) ?? "", people: "") }
            let fiche: String = String(((entry["text"] as? String) ?? "").prefix(5000))
            let memTxt: String = memory.promptBlock(max: 10, query: title)
            let sys: String = "Tu es Nova, l'assistante d'Ahadi (tutoiement, style de Muse). Tu rédiges l'ANTISÈCHE de sa réunion, à garder sous la main. Format EXACT :\nLigne 1 : « Antisèche pour **<réunion>** (<heure>) — » + une phrase sur l'enjeu.\n« **Ce que tu dois obtenir :** » puis 1 à 3 points numérotés, concrets (décision, condition, date, propriétaire).\n« **Dis exactement ceci :** » puis « Ouverture : », « Si on te pousse sur un point ouvert : », « Clôture : » — chacune suivie d'une réplique entre guillemets en citation (« > »), courte, dans la LANGUE de la réunion (anglais si le titre ou les participants sont anglophones), qui cite des faits datés des données.\n« **À éviter :** » 1 ou 2 pièges (dossiers à ne pas rouvrir, sujets à ne pas mêler).\nN'utilise QUE les données fournies ; un fait absent n'est pas inventé — dis ce qu'il faut vérifier."
            let user: String = "RÉUNION : " + title + " à " + hhmm + "\n\nFICHE DE PRÉPARATION :\n" + fiche + "\n\nMÉMOIRE LIÉE :\n" + memTxt
            let det = router.completeDetailed(messages: [ChatMsg("user", user)], system: sys, mode: "bulk", preferred: settings.get("brain", "spark-1.3"), maxTokens: 3000, deadline: 180, solo: true)
            guard let r = det.result else { continue }
            let t: String = r.text.trimmingCharacters(in: .whitespacesAndNewlines)
            if t.count < 60 { continue }
            ProactiveFeed.append(kind: "muse", box: "antiseche", title: "Antisèche — " + title, text: t, extra: ["rituel": "antiseche", "meeting_key": key])
        }
    }
}
