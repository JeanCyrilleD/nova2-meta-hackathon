import Foundation

// 25/10 : LECTURE DIRECTE DE GMAIL (IMAP, LECTURE SEULE) — calquée sur Feat_Zoho.swift. Branchée dans Extras.extraRoutes().
//
// Pourquoi : Gmail n'était lu que par Mail.app (AppleScript), qui dépasse ses 30 s → les Éclats rapportaient
// « Gmail non lu (mail_week timeout) ». Ici Nova lit la boîte Gmail elle-même, toutes les 5 min, en copie locale.
//
// Règles (identiques à Zoho, codées en dur) :
//  - le client IMAP, la liste blanche et le décodage MIME sont PARTAGÉS avec Zoho (ZohoIMAPClient, ZohoGuard,
//    ZohoMime) : CAPABILITY, LOGIN, EXAMINE "INBOX", UID SEARCH, UID FETCH (BODY.PEEK seulement), LOGOUT.
//    STORE, COPY, MOVE, EXPUNGE, APPEND, SELECT… sont refusés AVANT tout envoi : jamais de drapeau, de déplacement,
//    de suppression ni d'envoi ;
//  - identifiant = adresse Gmail + MOT DE PASSE D'APPLICATION [tiers] (16 caractères), saisi par Ahadi lui-même
//    dans Réglages ; il ne vit QU'AU Trousseau (service « nova-gmail-imap ») ; jamais journalisé ni renvoyé à l'UI ;
//  - copie locale gmail_mail.json (expéditeur, objet, date, extrait ≤ 600 car.) ; corps complets lisibles
//    (≤ 12 000 car.) au magasin gmail_bodies.json (200 au plus) ; un message à SECRET a son extrait et son corps masqués.

// MARK: - Clé du Trousseau

extension KnownKeys {
    // 25/10 : mot de passe d'APPLICATION [tiers] de la boîte Gmail, saisi par Ahadi (POST /api/gmail/connect).
    // Trousseau uniquement : aucune variable d'environnement, aucun fichier.
    public static let gmail = KeyRef(service: "nova-gmail-imap", accounts: ["$USER"], envVars: [])
}

struct GmailCtx {
    let bus: Bus
    let settings: Settings
    let briefs: Briefs
    let keys: KeyStore
}

enum Gmail {
    static let file: JSONFile = JSONFile("gmail_mail.json")
    static let bodiesFile: JSONFile = JSONFile("gmail_bodies.json")
    static let journal: Journal = Journal("gmail_journal.jsonl")   // hôte, compte, comptes, durées, classe d'erreur — jamais de secret
    static let lock: NSLock = NSLock()
    nonisolated(unsafe) static var syncing: Bool = false   // PHASE 1 (relu, protégé) : sous lock (sync, état)
    nonisolated(unsafe) static var schedulerStarted: Bool = false   // PHASE 1 (relu, protégé) : sous lock
    static let host: String = "imap.gmail.com"
    static let maxCache: Int = 400
    static let bodiesCap: Int = 200
    static let fetchItems: String = "(UID FLAGS INTERNALDATE RFC822.SIZE BODY.PEEK[HEADER.FIELDS (FROM TO SUBJECT DATE MESSAGE-ID CONTENT-TYPE CONTENT-TRANSFER-ENCODING)] BODY.PEEK[TEXT]<0.20000>)"
    static let lectureSeule: String = "Lecture seule — Nova ne marque, ne déplace, ne supprime et n'envoie rien (IMAP EXAMINE + BODY.PEEK)."
    static let aide: String = "Mot de passe d'application Google : myaccount.google.com › Sécurité › Validation en deux étapes (obligatoire) › Mots de passe des applications — 16 caractères, à coller ici."

    static func load() -> [String: Any] { file.read(default: [String: Any]()) }

    /// Lecture directe active = boîte connectée, mot de passe au Trousseau, au moins une synchro réussie.
    static func directActive() -> Bool {
        lock.lock(); let o: [String: Any] = load(); lock.unlock()
        return (o["connected"] as? Bool) == true && (o["synced_once"] as? Bool) == true
    }

    /// Âge (s) de la dernière synchro réussie ; nil si jamais.
    static func lastOkAge() -> TimeInterval? {
        lock.lock(); let o: [String: Any] = load(); lock.unlock()
        guard let s: String = o["last_ok"] as? String, let d: Date = ISO8601DateFormatter().date(from: s) else { return nil }
        return Date().timeIntervalSince(d)
    }

    static func status(keys: KeyStore) -> [String: Any] {
        lock.lock(); let o: [String: Any] = load(); let busy: Bool = syncing; lock.unlock()
        let hasPw: Bool = keys.value(KnownKeys.gmail) != nil
        let msgs: [[String: Any]] = (o["messages"] as? [[String: Any]]) ?? []
        let flag: Bool = (o["connected"] as? Bool) == true
        var err: Any = o["error"] ?? NSNull()
        if flag && !hasPw { err = "Mot de passe d'application absent du Trousseau — reconnecte Gmail." }
        let once: Bool = (o["synced_once"] as? Bool) == true
        return ["connected": flag && hasPw, "account": (o["account"] as? String) ?? "", "server": host,
                "last_sync": o["last_sync"] ?? NSNull(), "last_ok": o["last_ok"] ?? NSNull(), "count": msgs.count,
                "unread": o["unread"] ?? NSNull(), "error": err, "error_class": o["error_class"] ?? NSNull(),
                "synced_once": once, "direct_active": flag && once, "syncing": busy,
                "lecture_seule": lectureSeule, "aide": aide, "keychain_service": KnownKeys.gmail.service, "poll_s": 300]
    }

    static func sortedByDate(_ xs: [[String: Any]]) -> [[String: Any]] {
        return xs.sorted { (a: [String: Any], b: [String: Any]) -> Bool in ((a["date"] as? String) ?? "") > ((b["date"] as? String) ?? "") }
    }

    static func messages(limit: Int) -> [[String: Any]] {
        lock.lock(); let o: [String: Any] = load(); lock.unlock()
        let msgs: [[String: Any]] = (o["messages"] as? [[String: Any]]) ?? []
        return Array(sortedByDate(msgs).prefix(limit))
    }

    static func whoOf(_ m: [String: Any]) -> String {
        let n: String = (m["from_name"] as? String) ?? ""
        if !n.isEmpty { return n }
        return (m["from"] as? String) ?? "?"
    }

    /// Deux sections texte non vides jointes (sert à mail_unread : Gmail puis Zoho).
    static func joinSections(_ a: String, _ b: String) -> String {
        if a.isEmpty { return b }
        if b.isEmpty { return a }
        return a + "\n\n" + b
    }

    /// Vue texte pour mail_unread : NON LUS d'abord (copie locale), puis les plus récents. "" si non connecté.
    static func toolText(limit: Int) -> String {
        guard directActive() else { return "" }
        lock.lock(); let o: [String: Any] = load(); lock.unlock()
        let all: [[String: Any]] = sortedByDate((o["messages"] as? [[String: Any]]) ?? [])
        let unreadRows: [[String: Any]] = all.filter { (m: [String: Any]) -> Bool in (m["lu"] as? Bool) == false }
        let rows: [[String: Any]] = unreadRows.isEmpty ? Array(all.prefix(limit)) : Array(unreadRows.prefix(limit))
        var lines: [String] = []
        for m in rows {
            let day: String = String(((m["date"] as? String) ?? "").prefix(16)).replacingOccurrences(of: "T", with: " ")
            let ex: String = String(((m["excerpt"] as? String) ?? "").prefix(220))
            let mark: String = (m["lu"] as? Bool) == false ? "● " : ""
            var line: String = "- " + mark + day + " · " + whoOf(m) + " — " + ((m["subject"] as? String) ?? "")
            if !ex.isEmpty { line += "\n  " + ex }
            lines.append(line)
        }
        let nUnread: String = (o["unread"] as? Int).map { (n: Int) -> String in String(n) } ?? "?"
        let ageMin: Int = Int((lastOkAge() ?? 0) / 60)
        let acc: String = (o["account"] as? String) ?? ""
        var head: String = "Gmail " + acc + " (lecture directe IMAP, lecture seule — synchro il y a " + String(ageMin) + " min) : "
        head += nUnread + " non lus dans la boîte de réception"
        if let e = o["error"] as? String, !e.isEmpty { head = "⚠️ DERNIÈRE SYNCHRO GMAIL EN ÉCHEC (" + String(e.prefix(160)) + ") — copie possiblement périmée.\n" + head }   // 29/10 (audit n°4)
        if unreadRows.isEmpty {
            head += " ; aucun non-lu dans la copie locale, " + String(rows.count) + " plus récents :\n"
        } else {
            head += " ; " + String(rows.count) + " non-lus les plus récents (● = non lu) :\n"
        }
        let tail: String = "\n(corps complet d'un message Gmail : mail_corps {\"de\",\"objet\",\"boite\":\"gmail\"} — le magasin des corps fait foi)"
        return head + lines.joined(separator: "\n") + tail
    }

    /// Vue « semaine » pour mail_week : messages Gmail des n derniers jours (copie locale). "" si non connecté.
    static func weekText(days: Int) -> String {
        guard directActive() else { return "" }
        let since: Date = Date().addingTimeInterval(-Double(days) * 86400)
        let iso: ISO8601DateFormatter = ISO8601DateFormatter()
        var lines: [String] = []
        var total: Int = 0
        for m in messages(limit: maxCache) {
            let ds: String = (m["date"] as? String) ?? ""
            guard let d: Date = iso.date(from: ds), d >= since else { continue }
            total += 1
            if lines.count >= 60 { continue }
            let ex: String = String(((m["excerpt"] as? String) ?? "").prefix(140))
            let day: String = String(ds.prefix(16)).replacingOccurrences(of: "T", with: " ")
            var line: String = "REÇU (Gmail) | " + day + " | " + whoOf(m) + " | " + ((m["subject"] as? String) ?? "")
            if !ex.isEmpty { line += " — " + ex }
            lines.append(line)
        }
        if total == 0 { return "Gmail (lecture directe, " + String(days) + " derniers jours) : aucun message reçu dans la copie locale." }
        let head: String = "Gmail (lecture directe IMAP, copie locale en lecture seule, " + String(days) + " derniers jours) : REÇU (Gmail) TOTAL " + String(total) + "\n"
        let tail: String = "\n(Gmail : boîte de réception seulement ; corps complet : mail_corps {\"de\",\"objet\",\"boite\":\"gmail\"})"
        return head + lines.joined(separator: "\n") + tail
    }

    // MARK: magasin des corps

    static func bodyRow(_ m: ZohoParsed, subject: String, secret: Bool) -> [String: Any] {
        let iso: String = ISO8601DateFormatter().string(from: m.date)
        var row: [String: Any] = ["from": m.fromAddr, "from_name": m.fromName, "subject": subject, "date": iso, "ts": nowISO()]
        if secret {
            row["state"] = "masqué"; row["body"] = ""; row["len"] = 0
        } else if m.full.count < 10 {
            row["state"] = "vide"; row["body"] = ""; row["len"] = m.full.count
        } else {
            row["state"] = "lu"; row["body"] = m.full; row["len"] = m.full.count
        }
        return row
    }

    static func feedExtra(row: [String: Any], key: String) -> [String: Any] {
        let state: String = (row["state"] as? String) ?? ""
        var extra: [String: Any] = ["gmail_key": key]
        if state == "lu" {
            let b: String = (row["body"] as? String) ?? ""
            extra["body"] = "lu"
            extra["bodyVia"] = "gmail-imap"
            extra["bodyExcerpt"] = String(b.prefix(1500))
        } else if state == "masqué" {
            extra["body"] = "masqué"
        }
        return extra
    }

    /// À appeler SOUS `lock`.
    static func storeBodies(_ rows: [String: [String: Any]]) {
        var all: [String: [String: Any]] = bodiesFile.read(default: [String: [String: Any]]())
        for (k, v) in rows { all[k] = v }
        if all.count > bodiesCap {
            let sorted: [(key: String, value: [String: Any])] = all.sorted { (a: (key: String, value: [String: Any]), b: (key: String, value: [String: Any])) -> Bool in
                ((a.value["date"] as? String) ?? "") > ((b.value["date"] as? String) ?? "")
            }
            var kept: [String: [String: Any]] = [:]
            for e in sorted.prefix(bodiesCap) { kept[e.key] = e.value }
            all = kept
        }
        bodiesFile.write(all)
    }

    static func body(forKey key: String) -> [String: Any]? {
        lock.lock(); defer { lock.unlock() }
        let all: [String: [String: Any]] = bodiesFile.read(default: [String: [String: Any]]())
        return all[key]
    }

    static func bodyLookup(de: String, objet: String) -> [[String: Any]] {
        let dq: String = Zoho.normQ(de)
        let oq: String = Zoho.normQ(objet)
        lock.lock()
        let all: [String: [String: Any]] = bodiesFile.read(default: [String: [String: Any]]())
        lock.unlock()
        var hits: [[String: Any]] = []
        for (_, e) in all {
            if dq.isEmpty && oq.isEmpty {
                if ((e["state"] as? String) ?? "") == "lu" { hits.append(e) }
                continue
            }
            let who: String = Zoho.normQ(((e["from_name"] as? String) ?? "") + " " + ((e["from"] as? String) ?? ""))
            let subj: String = Zoho.normQ((e["subject"] as? String) ?? "")
            let deOK: Bool = dq.isEmpty || who.contains(dq)
            let obOK: Bool = oq.isEmpty || subj.contains(oq) || (!subj.isEmpty && oq.contains(subj))
            if deOK && obOK { hits.append(e) }
        }
        return Array(sortedByDate(hits).prefix(5))
    }

    /// Réponse de mail_corps pour Gmail (magasin d'abord). nil : aucune correspondance (l'appelant continue ses voies).
    static func corpsToolText(de: String, objet: String) -> String? {
        let hits: [[String: Any]] = bodyLookup(de: de, objet: objet)
        guard let z: [String: Any] = hits.first else { return nil }
        let state: String = (z["state"] as? String) ?? ""
        let who0: String = (z["from_name"] as? String) ?? ""
        let who: String = who0.isEmpty ? ((z["from"] as? String) ?? "?") : who0
        let subj: String = (z["subject"] as? String) ?? ""
        let day: String = String(((z["date"] as? String) ?? "").prefix(16)).replacingOccurrences(of: "T", with: " ")
        let ident: String = "message du " + day + ", de " + who + ", objet « " + subj + " »"
        var others: String = ""
        if hits.count > 1 {
            let rest: [String] = hits.dropFirst().map { (e: [String: Any]) -> String in "« " + ((e["subject"] as? String) ?? "") + " »" }
            others = "\n\n(Autres messages Gmail correspondants : " + rest.joined(separator: " ; ") + " — précise l'objet pour les distinguer.)"
        }
        if state == "masqué" {
            return "MESSAGE GMAIL À CORPS MASQUÉ — " + ident + " : il contient un code, un mot de passe ou un autre secret ; Nova ne stocke ni ne cite ce corps." + others
        }
        if state != "lu" {
            return "MESSAGE GMAIL SANS TEXTE LISIBLE — " + ident + " : corps vide ou non décodable (image, pièce jointe seule)." + others
        }
        let b: String = (z["body"] as? String) ?? ""
        let lead: String = "CORPS GMAIL AU MAGASIN — " + ident + " ; lu en lecture directe IMAP (EXAMINE + BODY.PEEK : rien n'est marqué lu). Ce texte fait foi pour l'analyse :\n\n"
        return lead + b + others
    }

    // MARK: connexion

    static func testLogin(email: String, password: String) -> (ok: Bool, errClass: String, message: String) {
        let c: ZohoIMAPClient = ZohoIMAPClient()
        defer { c.close() }
        if let e: String = c.connect(host: host, port: 993, timeout: 15) { return (false, "reseau", "Serveur Gmail injoignable : " + e + ".") }
        guard c.greeting(timeout: 15) else { return (false, "protocole", "Le serveur Gmail n'a pas répondu comme un serveur IMAP.") }
        let r: ZohoReply = c.login(email: email, password: password)
        if r.status == "OK" { _ = c.command("LOGOUT", ""); return (true, "", "") }
        if r.status == "NO" {
            return (false, "auth", "Google a refusé la connexion : vérifie l'adresse et le mot de passe d'APPLICATION (pas ton mot de passe Google). " + aide)
        }
        return (false, "protocole", "Réponse inattendue du serveur Gmail (" + r.status + ").")
    }

    static func connect(email: String, password: String, ctx: GmailCtx) -> (body: [String: Any], status: Int) {
        let mail: String = email.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard mail.range(of: #"^[^@\s"]+@[^@\s"]+\.[a-z]{2,}$"#, options: .regularExpression) != nil else {
            let b: [String: Any] = ["ok": false, "error": "Adresse invalide."]; return (b, 400)
        }
        // [tiers] affiche le mot de passe d'application en 4 groupes : les espaces sont retirés.
        let pw: String = password.components(separatedBy: .whitespacesAndNewlines).joined()
        guard !pw.isEmpty, pw.count <= 64, ZohoIMAPClient.quoted(pw) != nil else {
            let b: [String: Any] = ["ok": false, "error": "Mot de passe d'application vide ou contenant des caractères non pris en charge."]; return (b, 400)
        }
        let t0: Date = Date()
        let r: (ok: Bool, errClass: String, message: String) = testLogin(email: mail, password: pw)
        journal.add(["op": "connexion", "host": host, "account": mail, "ok": r.ok, "error_class": r.errClass, "ms": Int(Date().timeIntervalSince(t0) * 1000)])
        guard r.ok else {
            let b: [String: Any] = ["ok": false, "error": r.message, "error_class": r.errClass]
            return (b, r.errClass == "auth" ? 401 : 502)
        }
        guard KeychainStore.save(service: KnownKeys.gmail.service, value: pw) else {
            let b: [String: Any] = ["ok": false, "error": "Connexion réussie, mais le Trousseau a refusé l'écriture — rien n'a été enregistré."]
            return (b, 500)
        }
        (ctx.keys as? KeychainStore)?.forget()
        lock.lock()
        var o: [String: Any] = load()
        if (o["account"] as? String) != mail {
            o["messages"] = [[String: Any]](); o["uids"] = [Int](); o["uidvalidity"] = ""; o["synced_once"] = false
        }
        o["account"] = mail; o["connected"] = true
        o["error"] = NSNull(); o["error_class"] = NSNull(); o["connected_at"] = nowISO()
        file.write(o)
        lock.unlock()
        _ = BlackBox.record(["tool": "gmail", "actor": "Ahadi", "why": "Gmail connecté en lecture directe (" + mail + ") — mot de passe d'application au Trousseau « " + KnownKeys.gmail.service + " », lecture seule", "ok": true, "effect": "écrit"])
        DispatchQueue.global(qos: .utility).async { _ = sync(ctx: ctx, reason: "connexion") }
        let b: [String: Any] = ["ok": true, "account": mail, "server": host]
        return (b, 200)
    }

    static func disconnect(ctx: GmailCtx) -> [String: Any] {
        var deleted: Bool = false
        #if os(macOS)
        for _ in 0..<3 {
            let r: (Int32, String) = runProcess("/usr/bin/security", ["delete-generic-password", "-a", KeychainStore.user, "-s", KnownKeys.gmail.service], timeout: 5)
            if r.0 == 0 { deleted = true } else { break }
        }
        #endif
        (ctx.keys as? KeychainStore)?.forget()
        lock.lock()
        var o: [String: Any] = load()
        let acc: String = (o["account"] as? String) ?? ""
        o["connected"] = false; o["synced_once"] = false; o["error"] = NSNull(); o["error_class"] = NSNull(); o["disconnected_at"] = nowISO()
        file.write(o)
        lock.unlock()
        MailCounts.setGmail(nil)
        journal.add(["op": "déconnexion", "account": acc, "trousseau_efface": deleted])
        _ = BlackBox.record(["tool": "gmail", "actor": "Ahadi", "why": "Gmail (lecture directe) déconnecté — mot de passe " + (deleted ? "effacé du" : "absent du") + " Trousseau ; repli sur Mail.app et le volet Gmail", "ok": true, "effect": "écrit"])
        ctx.bus.publish("gmail", ["connected": false])
        return ["ok": true, "trousseau_efface": deleted]
    }

    static func fail(_ message: String, _ cls: String, account: String, t0: Date, ctx: GmailCtx) -> [String: Any] {
        lock.lock()
        var o: [String: Any] = load()
        let wasAuth: Bool = ((o["error_class"] as? String) ?? "") == "auth"
        o["error"] = message; o["error_class"] = cls; o["last_sync"] = nowISO()
        file.write(o)
        lock.unlock()
        // 29/10 (audit n°4) : une déconnexion (auth) arrête la synchro — Ahadi est prévenu UNE fois, pas seulement le bus.
        if cls == "auth" && !wasAuth {
            NovaNotifier.send(source: "mail:auth:gmail", title: "Nova — Gmail déconnecté", body: message, target: ["module": "reglages"])
            _ = BlackBox.record(["tool": "gmail", "actor": "Nova", "ok": false, "effect": "lecture", "why": "Gmail déconnecté (auth) — synchro suspendue, Ahadi prévenu", "result": "auth"])
        }
        journal.add(["op": "synchro", "host": host, "account": account, "ok": false, "error_class": cls, "ms": Int(Date().timeIntervalSince(t0) * 1000)])
        ctx.bus.publish("gmail", ["error": message])
        return ["ok": false, "error": message, "error_class": cls]
    }

    /// Le volet Gmail de Nova a-t-il déjà publié ce message au Fil direct (même objet, 48 h) ? Évite la double carte.
    static func paneAlreadyShown(subject: String) -> Bool {
        let t: String = String(subject.prefix(140))
        if t.count < 4 { return false }
        let limit: String = ISO8601DateFormatter().string(from: Date().addingTimeInterval(-48 * 3600))
        for e in ProactiveFeed.list(limit: 150, since: limit) {
            if (e["box"] as? String) != "gm" || (e["kind"] as? String) != "mail.new" { continue }
            if e["gmail_key"] != nil { continue }
            let title: String = (e["title"] as? String) ?? ""
            let text: String = (e["text"] as? String) ?? ""
            if title == t || text.contains(t) { return true }
        }
        return false
    }

    /// Une synchronisation : LOGIN, EXAMINE "INBOX", UID SEARCH, UID FETCH (PEEK), LOGOUT. Jamais deux à la fois.
    static func sync(ctx: GmailCtx, reason: String) -> [String: Any] {
        lock.lock()
        if syncing { lock.unlock(); let b: [String: Any] = ["ok": false, "busy": true, "error": "Synchronisation déjà en cours."]; return b }
        syncing = true
        let o0: [String: Any] = load()
        lock.unlock()
        defer { lock.lock(); syncing = false; lock.unlock() }
        let account: String = (o0["account"] as? String) ?? ""
        let t0: Date = Date()
        guard (o0["connected"] as? Bool) == true, !account.isEmpty else {
            let b: [String: Any] = ["ok": false, "error": "Gmail non connecté dans Nova."]; return b
        }
        guard let pw: String = ctx.keys.value(KnownKeys.gmail), !pw.isEmpty else {
            return fail("Mot de passe d'application absent du Trousseau — reconnecte Gmail dans Réglages.", "trousseau", account: account, t0: t0, ctx: ctx)
        }
        let days: Int = max(1, min(30, ctx.settings.get("gmail_jours", 7)))
        let sinceDay: String = ZohoMime.posix("dd-MMM-yyyy").string(from: Date().addingTimeInterval(-Double(days) * 86400))
        let c: ZohoIMAPClient = ZohoIMAPClient()
        defer { c.close() }
        if let e: String = c.connect(host: host, port: 993, timeout: 15) {
            return fail("Serveur Gmail injoignable : " + e + ".", "reseau", account: account, t0: t0, ctx: ctx)
        }
        guard c.greeting(timeout: 15) else {
            return fail("Le serveur Gmail n'a pas répondu comme un serveur IMAP.", "protocole", account: account, t0: t0, ctx: ctx)
        }
        let lr: ZohoReply = c.login(email: account, password: pw)
        guard lr.status == "OK" else {
            if lr.status == "NO" {
                return fail("Google refuse la connexion (mot de passe d'application révoqué ?) — reconnecte Gmail dans Réglages. Synchronisation automatique suspendue.", "auth", account: account, t0: t0, ctx: ctx)
            }
            return fail("Connexion IMAP interrompue (" + lr.status + ").", "protocole", account: account, t0: t0, ctx: ctx)
        }
        let ex: ZohoReply = c.command("EXAMINE", "\"INBOX\"")
        guard ex.status == "OK" else {
            return fail("Boîte de réception Gmail illisible (" + ex.status + ").", "protocole", account: account, t0: t0, ctx: ctx)
        }
        var uidValidity: String = ""
        for u in ex.untagged {
            for t in u.texts { if let v: String = ZohoMime.firstGroup(t, #"UIDVALIDITY (\d+)"#) { uidValidity = v } }
        }
        let sr: ZohoReply = c.command("UID SEARCH", "SINCE " + sinceDay)
        guard sr.status == "OK" else {
            return fail("Recherche refusée par Gmail (" + sr.status + ").", "protocole", account: account, t0: t0, ctx: ctx)
        }
        let uids: [Int] = Zoho.searchUIDs(sr)
        let ur: ZohoReply = c.command("UID SEARCH", "UNSEEN")
        let unseenOK: Bool = ur.status == "OK"
        let unseen: Set<Int> = unseenOK ? Set(Zoho.searchUIDs(ur)) : Set<Int>()
        // 29/10 (Ahadi : « 2 650 non lus Gmail, surtout des lettres d'info ») : le compteur de l'Accueil ne garde que la
        // boîte PRINCIPALE de Gmail (onglets Promotions / Réseaux sociaux / Notifications exclus) — recherche Gmail native.
        let pr: ZohoReply = c.command("UID SEARCH", "X-GM-RAW \"category:primary is:unread\"")
        let primaryN: Int? = pr.status == "OK" ? Zoho.searchUIDs(pr).count : nil
        let prevValidity: String = (o0["uidvalidity"] as? String) ?? ""
        let known: Set<Int> = prevValidity == uidValidity ? Set((o0["uids"] as? [Int]) ?? []) : Set<Int>()
        let freshAll: [Int] = uids.filter { (u: Int) -> Bool in !known.contains(u) }.sorted()
        let fresh: [Int] = Array(freshAll.suffix(150))
        var raws: [ZohoRaw] = []
        var i: Int = 0
        while i < fresh.count {
            let end: Int = min(i + 15, fresh.count)
            let batch: [Int] = Array(fresh[i..<end])
            let seq: String = batch.map { (u: Int) -> String in String(u) }.joined(separator: ",")
            let fr: ZohoReply = c.command("UID FETCH", seq + " " + fetchItems)
            for u in fr.untagged { if let r: ZohoRaw = ZohoMime.parseFetch(u) { raws.append(r) } }
            if fr.status != "OK" { break }
            i += 15
        }
        _ = c.command("LOGOUT", "")
        c.close()

        // Traitement hors réseau : copie locale, magasin des corps, Fil direct.
        let first: Bool = (o0["synced_once"] as? Bool) != true
        var cache: [[String: Any]] = (o0["messages"] as? [[String: Any]]) ?? []
        if prevValidity != uidValidity { cache = [] }
        var haveKeys: Set<String> = Set(cache.compactMap { (x: [String: Any]) -> String? in x["key"] as? String })
        var newMsgs: [[String: Any]] = []
        var feedN: Int = 0
        var skipped: Int = 0
        let now: Date = Date()
        let iso: ISO8601DateFormatter = ISO8601DateFormatter()
        let notifyOn: Bool = ctx.settings.get("notify", true) && ctx.settings.get("notify_mail", true)
        var bodyRows: [String: [String: Any]] = [:]
        for r in raws.sorted(by: { (a: ZohoRaw, b: ZohoRaw) -> Bool in a.uid < b.uid }) {
            let m: ZohoParsed = ZohoMime.parse(r, uidValidity: uidValidity)
            let subjShown: String = SecretsGuard.containsSecret(m.subject) ? "(objet masqué — secret)" : m.subject
            let fullProbe: String = m.subject + "\n" + m.full
            let secretFull: Bool = SecretsGuard.containsSecret(fullProbe) || ZohoFundings.rx(ZohoFundings.secretRx, fullProbe)
            let row: [String: Any] = bodyRow(m, subject: subjShown, secret: secretFull)
            bodyRows[m.key] = row
            if haveKeys.contains(m.key) { continue }
            haveKeys.insert(m.key)
            let recent: Bool = now.timeIntervalSince(m.date) < 48 * 3600
            let probe: String = m.subject + "\n" + m.text
            let secret: Bool = secretFull || SecretsGuard.containsSecret(probe) || ZohoFundings.rx(ZohoFundings.secretRx, probe)
            let excerpt: String = secret ? "(extrait masqué : code, mot de passe ou autre secret)" : ZohoMime.flat(m.text, 600)
            let isUnread: Bool = unseenOK ? unseen.contains(m.uid) : !r.seen
            let who: String = m.fromName.isEmpty ? m.fromAddr : m.fromName
            newMsgs.append(["key": m.key, "uid": m.uid, "uidvalidity": uidValidity, "message_id": m.messageId,
                            "from_name": m.fromName, "from": m.fromAddr, "domain": ZohoMime.domain(m.fromAddr),
                            "subject": subjShown, "date": iso.string(from: m.date), "excerpt": excerpt,
                            "lu": !isUnread, "size": m.size])
            // Fil direct : arrivées nouvelles NON LUES (première synchro : 5 plus récentes de moins de 48 h).
            if !isUnread || !recent { continue }
            if paneAlreadyShown(subject: subjShown) { continue }
            let publishIt: Bool = first ? feedN < 5 : feedN < 10
            if publishIt {
                var lines: [String] = []
                let fromLine: String = m.fromName.isEmpty ? m.fromAddr : m.fromName + " <" + m.fromAddr + ">"
                lines.append("De : " + String(fromLine.prefix(120)))
                if !subjShown.isEmpty { lines.append("Objet : " + String(subjShown.prefix(200))) }
                lines.append("Heure : " + Zoho.heure(m.date))
                if !excerpt.isEmpty { lines.append("Aperçu : " + String(excerpt.prefix(300))) }
                let extra: [String: Any] = feedExtra(row: row, key: m.key)
                let title: String = subjShown.isEmpty ? who : String(subjShown.prefix(140))
                ProactiveFeed.append(kind: "mail.new", box: "gm", title: title, text: lines.joined(separator: "\n"), urgent: false, who: who, extra: extra)
                feedN += 1
                if !first {
                    NovaNotifier.send(source: "mail:gm", title: "Nova — Gmail · " + who, body: String(subjShown.prefix(140)),
                                      target: ["module": "messages", "id": "gm"], urgent: false, enabled: notifyOn, quiet: ctx.briefs.inQuietHours())
                }
            } else {
                skipped += 1
            }
        }
        if skipped > 0 && !first {
            ProactiveFeed.append(kind: "mail.new", box: "gm", title: "Gmail — lot résumé (" + String(skipped) + " messages)",
                                 text: "+" + String(skipped) + " messages Gmail non lus récents (lecture directe ; liste dans Réglages › Gmail et dans la boîte).", urgent: false, who: "")
        }
        cache.append(contentsOf: newMsgs)
        if cache.count > maxCache { cache = Array(cache.suffix(maxCache)) }
        let uidSet: Set<Int> = Set(uids)
        if unseenOK {
            for k in cache.indices {
                if let u: Int = cache[k]["uid"] as? Int, (cache[k]["uidvalidity"] as? String) == uidValidity { cache[k]["lu"] = !unseen.contains(u) }
            }
        }
        let fetchedUIDs: Set<Int> = Set(raws.map { (r: ZohoRaw) -> Int in r.uid })
        let knownAfter: [Int] = Array(known.union(fetchedUIDs)).filter { (u: Int) -> Bool in uidSet.contains(u) }.sorted()
        let ms: Int = Int(Date().timeIntervalSince(t0) * 1000)
        lock.lock()
        var o: [String: Any] = load()
        let still: Bool = (o["account"] as? String) == account && (o["connected"] as? Bool) == true
        if still {
            o["messages"] = cache; o["uids"] = knownAfter; o["uidvalidity"] = uidValidity
            o["synced_once"] = true; o["last_sync"] = nowISO(); o["last_ok"] = nowISO()
            o["error"] = NSNull(); o["error_class"] = NSNull(); o["last_duration_ms"] = ms
            if unseenOK { o["unread"] = unseen.count }
            file.write(o)
            if !bodyRows.isEmpty { storeBodies(bodyRows) }
        }
        lock.unlock()
        if still && unseenOK { MailCounts.setGmail(primaryN ?? unseen.count) }
        journal.add(["op": "synchro", "host": host, "account": account, "ok": true, "raison": reason, "vus": uids.count, "nouveaux": newMsgs.count,
                     "fil_direct": feedN, "non_lus": unseen.count, "ms": ms])
        ctx.bus.publish("gmail", ["synced": true, "nouveaux": newMsgs.count])
        let b: [String: Any] = ["ok": true, "nouveaux": newMsgs.count, "fil_direct": feedN, "non_lus": unseen.count, "ms": ms]
        return b
    }

    static func startScheduler(ctx: GmailCtx) {
        lock.lock()
        if schedulerStarted { lock.unlock(); return }
        schedulerStarted = true
        lock.unlock()
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 75) { tick(ctx: ctx) }
    }
    static func tick(ctx: GmailCtx) {
        lock.lock(); let o: [String: Any] = load(); lock.unlock()
        let on: Bool = (o["connected"] as? Bool) == true && ((o["error_class"] as? String) ?? "") != "auth"
        if on { _ = sync(ctx: ctx, reason: "minuterie (5 min)") }
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 300) { tick(ctx: ctx) }
    }
}

// MARK: - Routes

extension NovaApp {
    func gmailRoutes() {
        let s = server
        let ctx: GmailCtx = GmailCtx(bus: bus, settings: settings, briefs: briefs, keys: keys)
        Gmail.startScheduler(ctx: ctx)
        s.on("GET", "/api/gmail/status") { _, res in
            res.json(Gmail.status(keys: ctx.keys))
        }
        s.on("GET", "/api/gmail/messages") { req, res in
            let n: Int = min(200, max(1, Int(req.query["limit"] ?? "50") ?? 50))
            let b: [String: Any] = ["messages": Gmail.messages(limit: n), "lecture_seule": Gmail.lectureSeule]
            res.json(b)
        }
        s.on("POST", "/api/gmail/connect") { req, res in
            let j: [String: Any] = req.json
            let r: (body: [String: Any], status: Int) = Gmail.connect(email: (j["email"] as? String) ?? "", password: (j["password"] as? String) ?? "", ctx: ctx)
            res.json(r.body, status: r.status)   // jamais le mot de passe : {ok, account, server} ou {ok:false, error}
        }
        s.on("POST", "/api/gmail/disconnect") { _, res in
            res.json(Gmail.disconnect(ctx: ctx))
        }
        s.on("POST", "/api/gmail/sync") { _, res in
            let r: [String: Any] = Gmail.sync(ctx: ctx, reason: "demande d'Ahadi")
            res.json(r)
        }
    }
}
