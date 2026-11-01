import Foundation

// 24/10 (soir) — demande d'Ahadi : la jauge « Mails non lus » de l'Accueil affichait 0 parce qu'elle ne lisait
// que l'Outlook local. Trois sources réelles, une par service, chacune datée et nommée :
//   · Outlook / Teams : pastille du Dock des apps natives (lsappinfo StatusLabel, relevée toutes les 60 s par
//     la boucle de surveillance d'App.swift) ;
//   · Gmail / Outlook web / Teams web : compteur entre parenthèses du titre de la page du volet
//     (« Boîte de réception (798) - … - Gmail », « (3) Chat | Microsoft Teams »), posté par uibridge.js
//     avec chaque instantané (/api/webmail, champ « titre »).
// La pastille native prime quand elle est fraîche (< 10 min) ; sinon le titre du volet (< 30 min) ; sinon
// « inconnu » (nil) — jamais de zéro inventé. Lecture seule : rien n'est ouvert, marqué lu ni envoyé.
// V5-S (25/10) : 4e boîte « Zoho » (zm), relevée par la lecture directe IMAP de la boîte campagne.
public enum MailCounts {
    static let lock: NSLock = NSLock()
    nonisolated(unsafe) static var badges: [String: (n: Int, at: Date)] = [:]   // "ol" | "tm"
    nonisolated(unsafe) static var titles: [String: (n: Int, at: Date)] = [:]   // "ol" | "gm" | "tm"

    /// Pastille du Dock d'une app native (n = 0 quand l'app tourne sans pastille).
    public static func setBadge(_ box: String, _ n: Int) {
        lock.lock(); badges[box] = (max(0, n), Date()); lock.unlock()
    }

    /// V5-S (25/10) : boîte Zoho campagne — non-lus relevés par la lecture directe IMAP (UID SEARCH UNSEEN, lecture seule),
    /// posés à chaque synchronisation (Feat_Zoho.swift). nil = boîte déconnectée.
    nonisolated(unsafe) static var zoho: (n: Int, at: Date)? = nil
    public static func setZoho(_ n: Int?) {
        lock.lock()
        if let v = n { zoho = (max(0, v), Date()) } else { zoho = nil }
        lock.unlock()
    }

    /// 25/10 : Gmail en lecture directe IMAP (Feat_Gmail.swift) — non-lus de la boîte de réception (UID SEARCH UNSEEN),
    /// posés à chaque synchronisation ; prioritaires sur la pastille et le titre du volet quand frais (15 min). nil = déconnecté.
    nonisolated(unsafe) static var gmail: (n: Int, at: Date)? = nil
    public static func setGmail(_ n: Int?) {
        lock.lock()
        if let v = n { gmail = (max(0, v), Date()) } else { gmail = nil }
        lock.unlock()
    }

    /// Titre d'un volet web : le premier « (nombre) » est le compteur de non-lus du service.
    public static func setTitle(_ box: String, _ title: String) {
        guard ["ol", "gm", "tm"].contains(box) else { return }
        let t: String = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty else { return }
        var n: Int = 0
        if let r = t.range(of: #"\((\d{1,6})\)"#, options: .regularExpression) {
            let digits: String = String(t[r]).filter { $0.isNumber }
            n = Int(digits) ?? 0
        }
        lock.lock(); titles[box] = (n, Date()); lock.unlock()
    }

    static var lastFile: JSONFile { JSONFile("mail_counts_last.json") }
    nonisolated(unsafe) static var lastCache: [String: [String: Any]]? = nil
    static func remember(_ id: String, _ n: Int, _ at: Date) {
        lock.lock(); defer { lock.unlock() }
        var c: [String: [String: Any]] = lastCache ?? lastFile.read(default: [String: [String: Any]]())
        let prevN: Int? = c[id]?["n"] as? Int
        let prevAt: Double = (c[id]?["at"] as? Double) ?? 0
        c[id] = ["n": n, "at": at.timeIntervalSince1970]
        lastCache = c
        if prevN != n || at.timeIntervalSince1970 - prevAt > 300 { lastFile.write(c) }
    }
    static func lastKnown(_ id: String, now: Date) -> (n: Int, at: Date, age: String)? {
        lock.lock(); defer { lock.unlock() }
        if lastCache == nil { lastCache = lastFile.read(default: [String: [String: Any]]()) }
        guard let e = lastCache?[id], let n = e["n"] as? Int, let t = e["at"] as? Double else { return nil }
        let at: Date = Date(timeIntervalSince1970: t)
        let sec: TimeInterval = now.timeIntervalSince(at)
        if sec > 86400 || sec < 0 { return nil }
        let mins: Int = Int(sec / 60)
        let age: String = mins < 60 ? "il y a " + String(mins) + " min" : "il y a " + String(mins / 60) + " h"
        return (n: n, at: at, age: age)
    }

    /// {boxes:[{id, name, unread|null, source, at}], total|null}
    public static func snapshot() -> [String: Any] {
        let now: Date = Date()
        let iso: ISO8601DateFormatter = ISO8601DateFormatter()
        lock.lock()
        let b: [String: (n: Int, at: Date)] = badges
        let t: [String: (n: Int, at: Date)] = titles
        let z: (n: Int, at: Date)? = zoho
        let g: (n: Int, at: Date)? = gmail
        lock.unlock()
        var rows: [[String: Any]] = []
        var total: Int = 0
        var known: Int = 0
        for (id, name) in [("tm", "Teams"), ("ol", "Outlook"), ("gm", "Gmail")] {
            var row: [String: Any] = ["id": id, "name": name]
            if id == "gm", let x = g, now.timeIntervalSince(x.at) < 900 {   // 25/10 : lecture directe Gmail d'abord
                row["unread"] = x.n; row["source"] = "lecture directe de Gmail (IMAP, lecture seule) — boîte principale seulement, sans Promotions ni Réseaux sociaux"; row["at"] = iso.string(from: x.at)
                total += x.n; known += 1
            } else if let x = b[id], now.timeIntervalSince(x.at) < 600 {
                row["unread"] = x.n; row["source"] = "pastille de l'app " + name; row["at"] = iso.string(from: x.at)
                total += x.n; known += 1
            } else if let x = t[id], now.timeIntervalSince(x.at) < 1800 {
                row["unread"] = x.n; row["source"] = "titre du volet " + name + " dans Nova"; row["at"] = iso.string(from: x.at)
                total += x.n; known += 1
            } else if let lv = MailCounts.lastKnown(id, now: now) {
                // 26/10 : au démarrage, le dernier relevé (≤ 24 h) s'affiche au lieu de « — », marqué comme tel.
                row["unread"] = lv.n; row["stale"] = true; row["source"] = "dernier relevé " + name + " (" + lv.age + ")"; row["at"] = iso.string(from: lv.at)
                total += lv.n; known += 1
            } else {
                row["unread"] = NSNull(); row["source"] = name + " non relevé (app fermée ou volet non ouvert)"
            }
            if row["stale"] == nil, let n = row["unread"] as? Int, let a = row["at"] as? String, let d = iso.date(from: a) { MailCounts.remember(id, n, d) }
            rows.append(row)
        }
        // 4e boîte : Zoho campagne (lecture directe ; relevé jugé frais 15 min, la synchro tourne toutes les 5 min).
        var zr: [String: Any] = ["id": "zm", "name": "Zoho"]
        if let x = z, now.timeIntervalSince(x.at) < 900 {
            zr["unread"] = x.n; zr["source"] = "lecture directe de la boîte Zoho (IMAP, lecture seule)"; zr["at"] = iso.string(from: x.at)
            total += x.n; known += 1
        } else if let lv = MailCounts.lastKnown("zm", now: now) {
            zr["unread"] = lv.n; zr["stale"] = true; zr["source"] = "dernier relevé Zoho (" + lv.age + ")"; zr["at"] = iso.string(from: lv.at)
            total += lv.n; known += 1
        } else {
            zr["unread"] = NSNull(); zr["source"] = "Zoho non relevé (boîte non connectée dans Nova ou synchro en attente)"
        }
        if zr["stale"] == nil, let n = zr["unread"] as? Int, let x = z { MailCounts.remember("zm", n, x.at) }
        rows.append(zr)
        var o: [String: Any] = ["boxes": rows, "generated": iso.string(from: now)]
        o["total"] = known > 0 ? (total as Any) : (NSNull() as Any)
        return o
    }
}
