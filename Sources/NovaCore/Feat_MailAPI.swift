import Foundation

// LECTURE LOCALE des mails Outlook (bureau) et des messages Teams — complément des voies existantes (Mail.app, boîtes web).
// Aucune API, aucun compte, aucun envoi : lecture seule de ce qui est déjà sur le Mac.
//  Outlook : 1) base locale du profil (sqlite3 -readonly ; copie temporaire si verrouillée) ; 2) AppleScript si Outlook tourne déjà
//            (lancé au besoin en arrière-plan par `open -g -j`, jamais `activate`).
//  Teams   : 1) base des notifications macOS filtrée sur Teams ; 2) cache local du nouveau Teams (heuristique : fragments <p>…</p>).
// Rien n'est journalisé (ni objets ni contenus). Caches de 120 s pour la sobriété.

public struct MailItem {
    public var box: String
    public var from: String
    public var subject: String
    public var date: String
    public var preview: String
    public var full: String = ""   // 25/10 : texte COMPLET quand la source le porte (notification Teams, fragment du cache) — jamais journalisé
    public func dict() -> [String: Any] { ["box": box, "from": from, "subject": subject, "date": date, "preview": preview] }
}

public enum MailAPI {
    static let lock: NSLock = NSLock()
    static var cache: [String: (Date, [MailItem], String)] = [:]
    static var home: String { NSHomeDirectory() }

    static var outlookDataDir: String {
        home + "/Library/Group Containers/UBF8T346G9.Office/Outlook/Outlook 15 Profiles/Main Profile/Data"
    }
    static var outlookDB: String { outlookDataDir + "/Outlook.sqlite" }
    static var notifDBCandidates: [String] {
        [home + "/Library/Group Containers/group.com.apple.usernoted/db2/db"]
    }
    static var teamsRoot: String {
        home + "/Library/Containers/com.microsoft.teams2/Data/Library/Application Support/Microsoft/MSTeams/EBWebView"
    }

    // ───────── utilitaires ─────────
    static func sh(_ cmd: String, _ args: [String], timeout: TimeInterval) -> (Int32, String) {
        // stderr renvoyé dans la sortie pour diagnostiquer (« database is locked », « authorization denied »…). Jamais journalisé.
        var all: [String] = ["-c", cmd + " 2>&1", "nova-sh"]
        all.append(contentsOf: args)
        return runProcess("/bin/sh", all, timeout: timeout)
    }
    static func cached(_ key: String) -> (Date, [MailItem], String)? {
        lock.lock(); defer { lock.unlock() }
        if let c = cache[key], Date().timeIntervalSince(c.0) < 120 { return c }
        return nil
    }
    static func store(_ key: String, _ items: [MailItem], _ src: String) {
        lock.lock(); cache[key] = (Date(), items, src); lock.unlock()
    }
    static func clip(_ s: String, _ n: Int) -> String {
        let t: String = s.replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression).trimmingCharacters(in: .whitespacesAndNewlines)
        if t.count <= n { return t }
        return String(t.prefix(n)) + "…"
    }
    static func sqlQuote(_ s: String) -> String { "'" + s.replacingOccurrences(of: "'", with: "''") + "'" }

    /// Lance sqlite3 en lecture seule ; séparateur \u{1F} entre colonnes, \u{1E} entre lignes. Copie temporaire si la base est verrouillée.
    static func sqlite(_ db: String, _ sql: String) -> (ok: Bool, rows: [[String]], err: String) {
        guard FileManager.default.fileExists(atPath: db) else { return (false, [], "base absente") }
        guard FileManager.default.isReadableFile(atPath: db) else { return (false, [], "accès refusé (Accès complet au disque)") }
        let cmd: String = "/usr/bin/sqlite3 -readonly -cmd '.timeout 2000' -separator \"$(printf '\\037')\" -newline \"$(printf '\\036')\" \"$1\" \"$2\""
        var (code, out) = sh(cmd, [db, sql], timeout: 20)
        if code != 0 && (out.contains("locked") || out.contains("busy")) {
            let tmp: String = NSTemporaryDirectory() + "nova-ro-" + UUID().uuidString
            let fm: FileManager = FileManager.default
            try? fm.createDirectory(atPath: tmp, withIntermediateDirectories: true)
            let dst: String = tmp + "/db.sqlite"
            for suf in ["", "-wal", "-shm"] { try? fm.copyItem(atPath: db + suf, toPath: dst + suf) }
            (code, out) = sh(cmd, [dst, sql], timeout: 30)
            try? fm.removeItem(atPath: tmp)
        }
        if code != 0 { return (false, [], shortError(out, 200)) }
        var rows: [[String]] = []
        for line in out.components(separatedBy: "\u{1E}") {
            let l: String = line.trimmingCharacters(in: .newlines)
            if l.isEmpty { continue }
            rows.append(l.components(separatedBy: "\u{1F}"))
        }
        return (true, rows, "")
    }

    static func columns(_ db: String, _ table: String) -> [String] {
        let r = sqlite(db, "PRAGMA table_info(" + table + ");")
        var cols: [String] = []
        for row in r.rows where row.count > 1 { cols.append(row[1]) }
        return cols
    }
    static func pick(_ cols: [String], _ cands: [String]) -> String? {
        for c in cands where cols.contains(c) { return c }
        return nil
    }

    // ───────── Outlook : base locale ─────────
    /// filter : nil = non lus ; sinon recherche texte (objet, expéditeur, aperçu).
    static func outlookSQLite(query: String?, limit: Int) -> (items: [MailItem]?, err: String) {
        let db: String = outlookDB
        if !FileManager.default.fileExists(atPath: db) { return (nil, "base Outlook locale introuvable") }
        let cols: [String] = columns(db, "Mail")
        if cols.isEmpty { return (nil, "table Mail illisible (Accès complet au disque requis ?)") }
        let cFrom: String = pick(cols, ["Message_SenderList", "Message_SenderAddressList", "Message_FromList"]) ?? "''"
        let cSubj: String = pick(cols, ["Message_NormalizedSubject", "Message_Subject"]) ?? "''"
        let cDate: String = pick(cols, ["Message_TimeReceived", "Message_TimeSent"]) ?? "0"
        let cPrev: String = pick(cols, ["Message_Preview"]) ?? "''"
        var wh: [String] = []
        if let q = query {
            let like: String = sqlQuote("%" + q + "%")
            wh.append("(" + cSubj + " LIKE " + like + " OR " + cFrom + " LIKE " + like + " OR " + cPrev + " LIKE " + like + ")")
        } else {
            if let cRead = pick(cols, ["Message_ReadFlag", "Message_IsRead"]) { wh.append(cRead + " = 0") } else { return (nil, "colonne « lu » absente") }
        }
        if cols.contains("Message_IsOutgoingMessage") { wh.append("IFNULL(Message_IsOutgoingMessage,0) = 0") }
        let dateExpr: String = "CASE WHEN " + cDate + " > 100000000 THEN datetime(" + cDate + ", 'unixepoch', 'localtime') ELSE '' END"
        var sql: String = "SELECT " + cFrom + ", " + cSubj + ", " + dateExpr + ", substr(" + cPrev + ",1,300) FROM Mail"
        if !wh.isEmpty { sql += " WHERE " + wh.joined(separator: " AND ") }
        sql += " ORDER BY " + cDate + " DESC LIMIT " + String(limit) + ";"
        let r = sqlite(db, sql)
        if !r.ok { return (nil, r.err) }
        var items: [MailItem] = []
        for row in r.rows where row.count >= 4 {
            items.append(MailItem(box: "Outlook", from: clip(row[0], 80), subject: clip(row[1], 160), date: row[2], preview: clip(row[3], 220)))
        }
        return (items, "")
    }

    // ───────── Outlook : AppleScript (Outlook classique ; le nouvel Outlook répond peu) ─────────
    static func outlookRunning() -> Bool {
        let (c, _) = runProcess("/usr/bin/pgrep", ["-x", "Microsoft Outlook"], timeout: 3)
        return c == 0
    }
    static func outlookInstalled() -> Bool {
        FileManager.default.fileExists(atPath: "/Applications/Microsoft Outlook.app")
    }
    static func outlookAppleScript(query: String?, limit: Int, launch: Bool) -> (items: [MailItem]?, err: String) {
        if !outlookInstalled() { return (nil, "Outlook non installé") }
        if !outlookRunning() {
            if !launch { return (nil, "Outlook non lancé") }
            _ = runProcess("/usr/bin/open", ["-g", "-j", "-b", "com.microsoft.Outlook"], timeout: 10)
            Thread.sleep(forTimeInterval: 4)
        }
        var cond: String = "is read of m is false"
        if let q = query {
            let esc: String = q.replacingOccurrences(of: "\\", with: "").replacingOccurrences(of: "\"", with: "").replacingOccurrences(of: "\n", with: " ").replacingOccurrences(of: "\r", with: " ")
            cond = "(subject of m contains \"" + esc + "\")"
        }
        let script: String = """
        tell application id "com.microsoft.Outlook"
            set out to ""
            set n to 0
            set msgs to messages of inbox
            set total to count of msgs
            if total > 300 then set total to 300
            repeat with i from 1 to total
                set m to item i of msgs
                try
                    if \(cond) then
                        set s to ""
                        try
                            set s to (address of sender of m)
                        end try
                        set p to ""
                        try
                            set p to plain text content of m
                            if (length of p) > 220 then set p to text 1 thru 220 of p
                        end try
                        set out to out & s & (ASCII character 31) & (subject of m) & (ASCII character 31) & ((time received of m) as string) & (ASCII character 31) & p & (ASCII character 30)
                        set n to n + 1
                        if n ≥ \(limit) then exit repeat
                    end if
                end try
            end repeat
            return out
        end tell
        """
        let (code, out) = sh("/usr/bin/osascript -e \"$1\"", [script], timeout: 30)
        if code != 0 {
            if out.contains("-1743") || out.contains("Not authorized") || out.contains("pas autoris") { return (nil, "droit Automatisation manquant") }
            return (nil, "AppleScript Outlook : " + shortError(out, 160))
        }
        var items: [MailItem] = []
        for rec in out.components(separatedBy: "\u{1E}") {
            let f: [String] = rec.trimmingCharacters(in: .newlines).components(separatedBy: "\u{1F}")
            if f.count < 4 { continue }
            items.append(MailItem(box: "Outlook", from: clip(f[0], 80), subject: clip(f[1], 160), date: f[2], preview: clip(f[3], 220)))
        }
        return (items, "")
    }

    static func outlook(query: String?, limit: Int = 30) -> (items: [MailItem]?, source: String, err: String) {
        let key: String = "ol|" + (query ?? "")
        if let c = cached(key) { return (c.1, c.2, "") }
        let a = outlookSQLite(query: query, limit: limit)
        if let it = a.items { store(key, it, "base locale"); return (it, "base locale", "") }
        let b = outlookAppleScript(query: query, limit: limit, launch: true)
        if let it = b.items { store(key, it, "AppleScript"); return (it, "AppleScript", "") }
        return (nil, "", a.err + " ; " + b.err)
    }

    // ───────── Teams ─────────
    static func teamsFromNotifications(limit: Int) -> (items: [MailItem]?, err: String) {
        guard let db = notifDBCandidates.first(where: { FileManager.default.fileExists(atPath: $0) }) else { return (nil, "base de notifications introuvable") }
        let sql: String = "SELECT hex(r.data), r.delivered_date FROM record r JOIN app a ON a.app_id = r.app_id WHERE a.identifier LIKE '%teams%' ORDER BY r.delivered_date DESC LIMIT " + String(limit) + ";"
        let r = sqlite(db, sql)
        if !r.ok { return (nil, "notifications : " + r.err) }
        var items: [MailItem] = []
        for row in r.rows where row.count >= 2 {
            guard let data = hexData(row[0]) else { continue }
            guard let pl = (try? PropertyListSerialization.propertyList(from: data, options: [], format: nil)) as? [String: Any] else { continue }
            let req: [String: Any] = (pl["req"] as? [String: Any]) ?? [:]
            let title: String = (req["titl"] as? String) ?? ""
            let sub: String = (req["subt"] as? String) ?? ""
            let body: String = (req["body"] as? String) ?? ""
            if title.isEmpty && body.isEmpty { continue }
            var date: String = ""
            if let d = Double(row[1]) {
                let f: DateFormatter = DateFormatter(); f.dateFormat = "yyyy-MM-dd HH:mm"
                date = f.string(from: Date(timeIntervalSinceReferenceDate: d))
            }
            // 25/10 : aperçu de liste porté à 600 car. (teams_read rend le TEXTE, pas seulement l'expéditeur) ; texte complet ≤ 4 000.
            let fullBody: String = String(body.trimmingCharacters(in: .whitespacesAndNewlines).prefix(4000))
            items.append(MailItem(box: "Teams", from: clip(title, 80), subject: clip(sub, 120), date: date, preview: clip(body, 600), full: fullBody))
        }
        return (items, "")
    }
    static func hexData(_ hex: String) -> Data? {
        let chars: [UInt8] = Array(hex.utf8)
        if chars.count % 2 != 0 { return nil }
        var d: Data = Data(capacity: chars.count / 2)
        var i: Int = 0
        while i < chars.count {
            guard let b = UInt8(String(bytes: chars[i..<(i + 2)], encoding: .ascii) ?? "", radix: 16) else { return nil }
            d.append(b); i += 2
        }
        return d
    }
    /// Heuristique : fichiers LevelDB récents du cache IndexedDB de Teams → fragments HTML <p>…</p> des messages.
    static func teamsFromCache(limit: Int) -> (items: [MailItem]?, err: String) {
        let fm: FileManager = FileManager.default
        if !fm.fileExists(atPath: teamsRoot) { return (nil, "cache Teams introuvable") }
        var files: [(String, Date)] = []
        if let en = fm.enumerator(atPath: teamsRoot) {
            while let rel = en.nextObject() as? String {
                if !rel.contains("indexeddb.leveldb") { continue }
                if !(rel.hasSuffix(".log") || rel.hasSuffix(".ldb")) { continue }
                let p: String = teamsRoot + "/" + rel
                let attrs: [FileAttributeKey: Any] = (try? fm.attributesOfItem(atPath: p)) ?? [:]
                let size: Int = (attrs[.size] as? Int) ?? 0
                if size <= 0 || size > 16_000_000 { continue }
                files.append((p, (attrs[.modificationDate] as? Date) ?? Date.distantPast))
            }
        }
        if files.isEmpty { return (nil, "cache Teams vide ou illisible") }
        files.sort { $0.1 > $1.1 }
        var seen: Set<String> = []
        var items: [MailItem] = []
        let rx: NSRegularExpression? = try? NSRegularExpression(pattern: "<p>([^<]{3,400})</p>", options: [])
        for (p, d) in files.prefix(4) {
            guard let data = fm.contents(atPath: p), let rx = rx else { continue }
            let text: String = String(decoding: data, as: UTF8.self)
            let ns: NSString = text as NSString
            let ms: [NSTextCheckingResult] = rx.matches(in: text, options: [], range: NSRange(location: 0, length: ns.length))
            let f: DateFormatter = DateFormatter(); f.dateFormat = "yyyy-MM-dd HH:mm"
            for m in ms.reversed() {
                let raw: String = ns.substring(with: m.range(at: 1))
                let t: String = clip(raw, 400)
                if t.count < 3 || seen.contains(t) { continue }
                seen.insert(t)
                items.append(MailItem(box: "Teams (cache)", from: "", subject: "", date: f.string(from: d), preview: t, full: clip(raw, 4000)))
                if items.count >= limit { break }
            }
            if items.count >= limit { break }
        }
        if items.isEmpty { return (nil, "cache Teams : aucun message reconnu") }
        return (items, "")
    }
    static func teams(limit: Int = 25) -> (items: [MailItem]?, source: String, err: String) {
        if let c = cached("teams") { return (c.1, c.2, "") }
        let a = teamsFromNotifications(limit: limit)
        if let it = a.items, !it.isEmpty { store("teams", it, "notifications macOS"); return (it, "notifications macOS", "") }
        let b = teamsFromCache(limit: limit)
        if let it = b.items { store("teams", it, "cache Teams"); return (it, "cache Teams", "") }
        return (nil, "", a.err + " ; " + b.err)
    }

    // ───────── 25/10 : texte complet d'un message Teams (lecture locale) ─────────
    static func normT(_ s: String) -> String {
        var t: String = s.lowercased().replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
        t = t.replacingOccurrences(of: "…", with: "").replacingOccurrences(of: "...", with: "")
        return t.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Fragments de garde tirés d'un aperçu de liste Teams : l'aperçu lui-même, et l'aperçu sans son
    /// préfixe d'auteur (« Jean : … », « Vous : … ») — 30 premiers caractères normalisés, ≥ 12.
    static func teamsFragments(_ apercu: String) -> [String] {
        let a: String = normT(apercu)
        var out: [String] = []
        let f0: String = String(a.prefix(30)).trimmingCharacters(in: .whitespaces)
        if f0.count >= 12 { out.append(f0) }
        if let r = a.range(of: ": "), a.distance(from: a.startIndex, to: r.lowerBound) <= 40 {
            let rest: String = String(a[r.upperBound...])
            let f1: String = String(rest.prefix(30)).trimmingCharacters(in: .whitespaces)
            if f1.count >= 12 { out.append(f1) }
        }
        return out
    }

    /// Texte COMPLET d'un message Teams relu localement (notifications macOS, puis cache de l'app) pour une
    /// ligne de la liste du volet. Garde (même discipline que le pont Mail.app) : un fragment de l'aperçu
    /// relevé au volet doit se retrouver dans le texte trouvé — sinon nil (jamais de « corps » deviné).
    static func teamsFull(name: String, fragment: String) -> (text: String, source: String, date: String)? {
        let frags: [String] = teamsFragments(fragment)
        if frags.isEmpty { return nil }
        let r = teams(limit: 60)
        guard let items = r.items else { return nil }
        for m in items {
            let body: String = m.full.isEmpty ? m.preview : m.full
            let nb: String = normT(body)
            if !frags.contains(where: { (f: String) -> Bool in nb.contains(f) }) { continue }
            if body.trimmingCharacters(in: .whitespacesAndNewlines).count < 8 { continue }
            return (body, r.source, m.date)
        }
        return nil
    }

    /// REPRISE TEAMS (26/10, diagnostic d'Ahadi « les directs Teams ne listent que les noms ») :
    /// repli par NOM quand la garde sur fragment echoue — cas reel du volet web Teams deconnecte,
    /// dont les lignes ne portent que le statut de presence (« Out of office », « Busy »…) au lieu
    /// de l'apercu du message. On cherche alors, dans les memes sources locales (notifications
    /// macOS puis cache Teams), le message le plus recent dont l'expediteur ou le titre contient
    /// le nom de la conversation. Contenu reel et date, jamais devine : nil si rien de solide.
    static func teamsByName(_ name: String) -> (text: String, source: String, date: String)? {
        let needle: String = normT(name)
        guard needle.count >= 3 else { return nil }
        let r = teams(limit: 60)
        guard let items = r.items else { return nil }
        for m in items {
            let who: String = normT(m.from + " " + m.subject)
            guard who.contains(needle) || needle.contains(normT(m.from)) && !normT(m.from).isEmpty else { continue }
            let body: String = m.full.isEmpty ? m.preview : m.full
            if body.trimmingCharacters(in: .whitespacesAndNewlines).count >= 20 { return (body, r.source, m.date) }
        }
        return nil
    }

    /// Recherche pour l'outil mail_corps (boite teams) : messages lus localement dont l'expéditeur (titre de la
    /// notification) et/ou le texte contiennent la requête — 3 au plus, du plus récent au plus ancien.
    static func teamsSearch(de: String, texte: String) -> (items: [MailItem], source: String) {
        let dq: String = normT(de)
        let tq: String = normT(texte)
        if dq.isEmpty && tq.isEmpty { return ([], "") }
        let r = teams(limit: 60)
        guard let items = r.items else { return ([], "") }
        var out: [MailItem] = []
        for m in items {
            let body: String = m.full.isEmpty ? m.preview : m.full
            let who: String = normT(m.from + " " + m.subject)
            let nb: String = normT(body)
            let deOK: Bool = dq.isEmpty || who.contains(dq) || nb.contains(dq)
            let txOK: Bool = tq.isEmpty || nb.contains(tq) || who.contains(tq)
            if deOK && txOK { out.append(m) }
            if out.count >= 3 { break }
        }
        return (out, r.source)
    }

    // ───────── état ─────────
    static func status() -> [String: Any] {
        var ol: String = "ok"
        if !outlookInstalled() && !FileManager.default.fileExists(atPath: outlookDB) { ol = "non installé" }
        else if FileManager.default.fileExists(atPath: outlookDB) {
            ol = FileManager.default.isReadableFile(atPath: outlookDB) && !columns(outlookDB, "Mail").isEmpty ? "ok (base locale)" : "base locale illisible : Accès complet au disque manquant"
            if !ol.hasPrefix("ok") && outlookRunning() { ol += " ; Outlook lancé (AppleScript possible)" }
        } else if !outlookRunning() { ol = "non lancé" }
        else { ol = "lancé (AppleScript ; droit Automatisation à vérifier)" }
        let t = teams(limit: 10)
        let tm: String = t.items != nil ? ("ok (" + t.source + ", " + String(t.items!.count) + ")") : ("vide : " + t.err)
        return ["outlook": ol, "teams": tm, "outlookDB": FileManager.default.fileExists(atPath: outlookDB)]
    }

    /// 25/10 : corps complet d'un événement du Fil direct — magasin Outlook/Gmail/Teams (par événement),
    /// magasin Zoho (clé zoho_key), sinon l'extrait du journal ; états honnêtes sinon (protégé, masqué, non lu).
    static func corpsForFeed(_ fid: String) -> [String: Any] {
        guard let ev: [String: Any] = ProactiveFeed.list(limit: 200).first(where: { (e: [String: Any]) -> Bool in (e["id"] as? String) == fid }) else {
            return ["ok": false, "state": "absent", "error": "événement hors du journal (200 derniers)"]
        }
        let state: String = (ev["body"] as? String) ?? ""
        if let zk = ev["zoho_key"] as? String, !zk.isEmpty, let z: [String: Any] = Zoho.body(forKey: zk) {
            let zs: String = (z["state"] as? String) ?? ""
            let zb: String = (z["body"] as? String) ?? ""
            if zs == "lu" && !zb.isEmpty { return ["ok": true, "state": "lu", "via": "zoho-imap", "body": zb, "len": zb.count] }
            return ["ok": false, "state": zs.isEmpty ? state : zs]
        }
        // 25/10 : arrivée Gmail en lecture directe (Feat_Gmail.swift) — magasin gmail_bodies.json (clé gmail_key).
        if let gk = ev["gmail_key"] as? String, !gk.isEmpty, let g: [String: Any] = Gmail.body(forKey: gk) {
            let gs: String = (g["state"] as? String) ?? ""
            let gb: String = (g["body"] as? String) ?? ""
            if gs == "lu" && !gb.isEmpty { return ["ok": true, "state": "lu", "via": "gmail-imap", "body": gb, "len": gb.count] }
            return ["ok": false, "state": gs.isEmpty ? state : gs]
        }
        if let st = BodyFetcher.storedBody(forEvent: fid) {
            return ["ok": true, "state": "lu", "via": st.via, "body": st.body, "len": st.body.count, "ts": st.ts]
        }
        let ex: String = ((ev["bodyExcerpt"] as? String) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        if state == "lu" && !ex.isEmpty {
            return ["ok": true, "state": "lu", "via": (ev["bodyVia"] as? String) ?? "", "body": ex, "len": ex.count, "extrait": true]
        }
        return ["ok": false, "state": state.isEmpty ? "non lu" : state]
    }

    /// Texte pour l'outil mail_unread (à brancher en priorité par l'intégrateur). nil si aucune source locale ne répond.
    public static func unreadText() -> String? {
        let r = outlook(query: nil, limit: 30)
        guard let items = r.items else { return nil }
        // FIXES-MAIL (24/10) : la base locale d'Outlook bureau peut dire 0 alors que le volet
        // Outlook web en montre beaucoup (compte non synchronisé dans l'app bureau, base périmée).
        // 0 n'est donc jamais présenté comme vérité : sans instantané web, nil → mail_unread
        // poursuit (Mail.app, volets) ; avec instantané, le 0 est qualifié.
        if items.isEmpty {
            if WebMail.report() == nil { return nil }
            return "Outlook (bureau, " + r.source + ") : 0 non lu dans la base LOCALE de l'app bureau — cette base peut être périmée ou ne pas couvrir le compte web ; les boîtes web ci-dessous font foi pour Outlook web et Gmail."
        }
        var lines: [String] = ["Mails non lus — Outlook bureau (" + r.source + ", " + nowISO() + ") : " + String(items.count)]
        for m in items {
            let l: String = "• " + m.date + " | " + m.from + " | " + m.subject + (m.preview.isEmpty ? "" : " — " + m.preview)
            lines.append(l)
        }
        return lines.joined(separator: "\n")
    }

    /// Texte pour l'outil teams_read : messages Teams lus LOCALEMENT (notifications macOS, puis cache du Teams bureau). nil si rien.
    public static func teamsText() -> String? {
        let r = teams(limit: 25)
        guard let items = r.items, !items.isEmpty else { return nil }
        var lines: [String] = ["Messages Teams — app bureau (" + r.source + ", " + nowISO() + ") : " + String(items.count)]
        for m in items {
            let l: String = "• " + m.date + " | " + m.from + " | " + m.subject + (m.preview.isEmpty ? "" : " — " + m.preview)
            lines.append(l)
        }
        return lines.joined(separator: "\n")
    }
}

extension NovaApp {
    func mailApiRoutes() {
        let s = server
        s.on("GET", "/api/mailapi/status") { _, res in
            res.json(MailAPI.status())
        }
        s.on("GET", "/api/mailapi/unread") { _, res in
            let r = MailAPI.outlook(query: nil, limit: 30)
            let items: [[String: Any]] = (r.items ?? []).map { $0.dict() }
            res.json(["ok": r.items != nil, "source": r.source, "error": r.err, "boxes": [["box": "Outlook", "count": items.count, "items": items]]])
        }
        s.on("GET", "/api/mailapi/search") { req, res in
            let q: String = (req.query["q"] ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            if q.count < 2 { res.json(["ok": false, "error": "requête trop courte"], status: 400); return }
            let r = MailAPI.outlook(query: String(q.prefix(100)), limit: 40)
            res.json(["ok": r.items != nil, "source": r.source, "error": r.err, "items": (r.items ?? []).map { $0.dict() }])
        }
        s.on("GET", "/api/mailapi/teams") { _, res in
            let r = MailAPI.teams(limit: 25)
            res.json(["ok": r.items != nil, "source": r.source, "error": r.err, "items": (r.items ?? []).map { $0.dict() }])
        }
        // 25/10 : CORPS COMPLET d'une arrivée du Fil direct, pour la carte (« Lire le message complet »).
        // Lecture seule des magasins (webmail_bodies.json, zoho_bodies.json, journal) — rien n'est relu ni marqué.
        s.on("GET", "/api/mail/corps") { req, res in
            let fid: String = (req.query["feed"] ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            if fid.isEmpty { res.json(["ok": false, "error": "feed manquant"], status: 400); return }
            res.json(MailAPI.corpsForFeed(fid))
        }
        s.on("POST", "/api/mailapi/refresh") { _, res in
            MailAPI.lock.lock(); MailAPI.cache.removeAll(); MailAPI.lock.unlock()
            res.json(["ok": true])
        }
    }
}
