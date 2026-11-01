import Foundation
#if canImport(EventKit) && os(macOS)
import EventKit
#endif

// Feat_Daily.swift — « Nova Plus » : (A) Mode réunion, (B) Résumé du matin en une page, (C) Surveillance des engagements.
// Règles : lecture seule partout ; les seules écritures sont locales (fichiers JSON de Nova, brouillons via draft_reply) ; rien n'est envoyé.
// Minuteurs : DispatchSource gardés par une référence statique forte (DailyState.shared), périodes ≥ 10 min, sans chevauchement.

// MARK: - État partagé

final class DailyState: @unchecked Sendable {
    static let shared: DailyState = DailyState()
    let lock: NSLock = NSLock()
    var timers: [DispatchSourceTimer] = []
    var started: Bool = false
    var prepRunning: Set<String> = []
    var morningRunning: Bool = false
    var scanRunning: Bool = false
    var eventsAt: Date = Date.distantPast
    var events: [[String: Any]] = []
    var calNote: String = ""
    let work: DispatchQueue = DispatchQueue(label: "nova.daily.work", qos: .utility, attributes: .concurrent)
    let prepFile: JSONFile = JSONFile("meeting_prep.json")
    let commitFile: JSONFile = JSONFile("commitments.json")
    let morningFile: JSONFile = JSONFile("morning.json")
}

// MARK: - Utilitaires (agenda, texte, JSON)

enum DailyCal {
    static let months: [String: Int] = [
        "janvier": 1, "janv": 1, "février": 2, "fevrier": 2, "févr": 2, "mars": 3, "avril": 4, "avr": 4, "mai": 5, "juin": 6,
        "juillet": 7, "juil": 7, "août": 8, "aout": 8, "septembre": 9, "sept": 9, "octobre": 10, "oct": 10, "novembre": 11, "nov": 11,
        "décembre": 12, "decembre": 12, "déc": 12,
        "january": 1, "jan": 1, "february": 2, "feb": 2, "march": 3, "mar": 3, "april": 4, "apr": 4, "may": 5, "june": 6, "jun": 6,
        "july": 7, "jul": 7, "august": 8, "aug": 8, "september": 9, "sep": 9, "october": 10, "november": 11, "december": 12, "dec": 12,
    ]
    static let stopWords: Set<String> = ["réunion", "reunion", "point", "meeting", "avec", "pour", "dans", "call", "weekly", "hebdo", "hebdomadaire",
                                         "daily", "sync", "the", "and", "des", "les", "une", "sur", "entre", "rendez", "vous", "teams", "zoom", "visio"]
    static let iso: ISO8601DateFormatter = ISO8601DateFormatter()
    static let fullFormatters: [DateFormatter] = {
        var out: [DateFormatter] = []
        let locales: [Locale] = [Locale.current, Locale(identifier: "fr_FR"), Locale(identifier: "en_US")]
        for loc in locales {
            let a: DateFormatter = DateFormatter()
            a.locale = loc; a.dateStyle = .full; a.timeStyle = .medium; a.isLenient = true
            out.append(a)
            let b: DateFormatter = DateFormatter()
            b.locale = loc; b.dateStyle = .full; b.timeStyle = .short; b.isLenient = true
            out.append(b)
        }
        return out
    }()
    static let labelFmt: DateFormatter = {
        let f: DateFormatter = DateFormatter()
        f.locale = Locale(identifier: "fr_FR"); f.dateFormat = "EEEE d MMMM 'à' HH:mm"
        return f
    }()
    static let hmFmt: DateFormatter = {
        let f: DateFormatter = DateFormatter()
        f.locale = Locale(identifier: "fr_FR"); f.dateFormat = "HH:mm"
        return f
    }()
    static let dayFmt: DateFormatter = {
        let f: DateFormatter = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX"); f.dateFormat = "yyyy-MM-dd"
        return f
    }()
    static let longDayFmt: DateFormatter = {
        let f: DateFormatter = DateFormatter()
        f.locale = Locale(identifier: "fr_FR"); f.dateFormat = "EEEE d MMMM yyyy"
        return f
    }()

    static func norm(_ s: String) -> String {
        var t: String = s.replacingOccurrences(of: "\u{202F}", with: " ")
        t = t.replacingOccurrences(of: "\u{00A0}", with: " ")
        return t.trimmingCharacters(in: .whitespacesAndNewlines)
    }
    static func groups(_ pattern: String, _ s: String) -> [String]? {
        guard let rx: NSRegularExpression = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else { return nil }
        let ns: NSString = s as NSString
        guard let m: NSTextCheckingResult = rx.firstMatch(in: s, options: [], range: NSRange(location: 0, length: ns.length)) else { return nil }
        var out: [String] = []
        for i in 0..<m.numberOfRanges {
            let r: NSRange = m.range(at: i)
            out.append(r.location == NSNotFound ? "" : ns.substring(with: r))
        }
        return out
    }
    /// Dates telles que les écrit l'outil calendar (EventKit .full/.medium dans la langue du Mac, ou AppleScript « as string »).
    static func parseDate(_ raw: String) -> Date? {
        let s: String = norm(raw)
        if s.isEmpty { return nil }
        for f in fullFormatters { if let d: Date = f.date(from: s) { return d } }
        return regexDate(s)
    }
    static func regexDate(_ s: String) -> Date? {
        var day: Int = 0
        var month: Int = 0
        var year: Int = 0
        if let g: [String] = groups("(\\d{1,2})(?:er)?\\s+([^\\s\\d,\\.]+)\\.?\\s+(\\d{4})", s), g.count == 4, let m: Int = months[g[2].lowercased()] {
            day = Int(g[1]) ?? 0; month = m; year = Int(g[3]) ?? 0
        } else if let g: [String] = groups("([A-Za-z]+)\\.?\\s+(\\d{1,2}),?\\s+(\\d{4})", s), g.count == 4, let m: Int = months[g[1].lowercased()] {
            day = Int(g[2]) ?? 0; month = m; year = Int(g[3]) ?? 0
        } else if let g: [String] = groups("(\\d{1,2})/(\\d{1,2})/(\\d{4})", s), g.count == 4 {
            day = Int(g[1]) ?? 0; month = Int(g[2]) ?? 0; year = Int(g[3]) ?? 0
        }
        if day <= 0 || month <= 0 || month > 12 || year < 2000 { return nil }
        var hour: Int = 0
        var minute: Int = 0
        if let t: [String] = groups("(\\d{1,2})[:h](\\d{2})(?::\\d{2})?\\s*([AaPp][Mm])?", s), t.count == 4 {
            hour = Int(t[1]) ?? 0; minute = Int(t[2]) ?? 0
            let ap: String = t[3].lowercased()
            if ap == "pm" && hour < 12 { hour += 12 }
            if ap == "am" && hour == 12 { hour = 0 }
        }
        var c: DateComponents = DateComponents()
        c.year = year; c.month = month; c.day = day; c.hour = hour; c.minute = minute
        return Calendar.current.date(from: c)
    }
    /// Lignes « date | titre | calendrier » → événements triés (doublons Calendrier/Outlook retirés).
    static func parse(_ text: String) -> [[String: Any]] {
        var out: [[String: Any]] = []
        var seen: Set<String> = []
        for rawLine in text.components(separatedBy: "\n") {
            let line: String = norm(rawLine)
            let parts: [String] = line.components(separatedBy: " | ")
            if parts.count < 2 { continue }
            guard let d: Date = parseDate(parts[0]) else { continue }
            let title: String = parts[1].trimmingCharacters(in: .whitespaces)
            if title.isEmpty { continue }
            let cal: String = parts.count > 2 ? parts[2].trimmingCharacters(in: .whitespaces) : ""
            let isoStr: String = iso.string(from: d)
            let key: String = title + "|" + isoStr
            if seen.contains(key) { continue }
            seen.insert(key)
            let ev: [String: Any] = ["title": title, "when": parts[0], "cal": cal, "start": isoStr, "ts": d.timeIntervalSince1970,
                                     "label": labelFmt.string(from: d), "hhmm": hmFmt.string(from: d), "key": key]
            out.append(ev)
        }
        out.sort { (a: [String: Any], b: [String: Any]) -> Bool in
            let x: Double = (a["ts"] as? Double) ?? 0
            let y: Double = (b["ts"] as? Double) ?? 0
            return x < y
        }
        return out
    }
    static func keywords(_ s: String) -> [String] {
        let parts: [String] = s.lowercased().components(separatedBy: CharacterSet.alphanumerics.inverted)
        var out: [String] = []
        for p in parts where p.count > 3 && !stopWords.contains(p) && !out.contains(p) { out.append(p) }
        return Array(out.prefix(6))
    }
    static func relevantLines(_ text: String, _ words: [String], max: Int) -> [String] {
        if words.isEmpty { return [] }
        var out: [String] = []
        for l in text.components(separatedBy: "\n") {
            let low: String = l.lowercased()
            var hit: Bool = false
            for w in words where low.contains(w) { hit = true; break }
            if hit {
                let t: String = l.trimmingCharacters(in: .whitespaces)
                if !t.isEmpty { out.append(String(t.prefix(300))) }
            }
            if out.count >= max { break }
        }
        return out
    }
    static func clip(_ s: String, _ n: Int) -> String {
        if s.count <= n { return s }
        return String(s.prefix(n)) + " […]"
    }
    static func jsonSlice(_ s: String, open: Character, close: Character) -> Any? {
        guard let a: String.Index = s.firstIndex(of: open), let b: String.Index = s.lastIndex(of: close), a < b else { return nil }
        let sub: String = String(s[a...b])
        guard let d: Data = sub.data(using: .utf8) else { return nil }
        return try? JSONSerialization.jsonObject(with: d, options: [])
    }
    /// V6 (25/10) : la partie « MARCHÉ » de brvm_cours est un objet JSON (parfois tronqué) — jamais affiché brut.
    /// On relit chaque cotation plate {sym, price, var} et on rend 2 lignes lisibles (variations à 1 décimale, format français).
    static func marketLines(_ raw: String) -> [String] {
        var movers: [(sym: String, v: Double)] = []
        guard let rx: NSRegularExpression = try? NSRegularExpression(pattern: #"\{[^{}]*\}"#, options: []) else { return [] }
        let ns: NSString = raw as NSString
        let found: [NSTextCheckingResult] = rx.matches(in: raw, options: [], range: NSRange(location: 0, length: ns.length))
        for m in found {
            let piece: String = ns.substring(with: m.range)
            guard let d: Data = piece.data(using: .utf8),
                  let o: [String: Any] = (try? JSONSerialization.jsonObject(with: d, options: [])) as? [String: Any] else { continue }
            guard let sym: String = o["sym"] as? String, let n: NSNumber = o["var"] as? NSNumber, o["price"] != nil else { continue }
            movers.append((sym: sym, v: n.doubleValue))
        }
        if movers.isEmpty { return [] }
        let nf: NumberFormatter = NumberFormatter()
        nf.locale = Locale(identifier: "fr_FR")
        nf.numberStyle = .decimal
        nf.minimumFractionDigits = 1
        nf.maximumFractionDigits = 1
        var up: Int = 0
        var down: Int = 0
        for m in movers {
            if m.v > 0 { up += 1 } else if m.v < 0 { down += 1 }
        }
        var out: [String] = []
        out.append("Marché : " + String(movers.count) + " valeurs relevées, " + String(up) + " en hausse, " + String(down) + " en baisse.")
        let sorted: [(sym: String, v: Double)] = movers.sorted { (a: (sym: String, v: Double), b: (sym: String, v: Double)) -> Bool in abs(a.v) > abs(b.v) }
        var parts: [String] = []
        for m in sorted.prefix(3) where m.v != 0 {
            let num: String = nf.string(from: NSNumber(value: m.v)) ?? String(format: "%.1f", m.v)
            let sign: String = m.v > 0 ? "+" : ""
            parts.append(m.sym + " " + sign + num + " %")
        }
        if !parts.isEmpty { out.append("Plus fortes variations : " + parts.joined(separator: " · ")) }
        return out
    }
    /// V6 (25/10) : un mail promotionnel ou une lettre d'information n'est jamais « urgent ».
    static func looksPromo(_ s: String) -> Bool {
        let t: String = s.lowercased()
        let keys: [String] = ["offre spéciale", "offre speciale", "profitez", "% de réduction", "code promo", "newsletter", "webinaire", "webinar",
                              "formation internationale", "certifiante", "inscrivez-vous", "dernière chance", "black friday", "soldes", "unsubscribe", "désabonner"]
        return keys.contains(where: { (k: String) -> Bool in t.contains(k) })
    }
    static func strings(_ v: Any?, max: Int) -> [String] {
        guard let arr: [Any] = v as? [Any] else {
            if let s: String = v as? String, !s.isEmpty { return [s] }
            return []
        }
        var out: [String] = []
        for x in arr {
            if let s: String = x as? String {
                let t: String = s.trimmingCharacters(in: .whitespacesAndNewlines)
                if !t.isEmpty { out.append(String(t.prefix(260))) }
            }
            if out.count >= max { break }
        }
        return out
    }
    static func limitWords(_ s: String, _ n: Int) -> String {
        let w: [String] = s.split(whereSeparator: { (c: Character) -> Bool in c == " " || c == "\n" }).map { (x: Substring) -> String in String(x) }
        if w.count <= n { return w.joined(separator: " ") }
        return w.prefix(n).joined(separator: " ") + "…"
    }
    static func simplify(_ s: String) -> String {
        let low: String = s.lowercased().folding(options: .diacriticInsensitive, locale: Locale(identifier: "fr_FR"))
        let parts: [String] = low.components(separatedBy: CharacterSet.alphanumerics.inverted).filter { (p: String) -> Bool in !p.isEmpty }
        return parts.joined(separator: " ")
    }
    static func unavailable(_ s: String) -> Bool {
        return s.contains("indisponible") || s.contains("a échoué") || s.contains("ne répond pas") || s.hasPrefix("Refusé") || s.contains("Budget d'autonomie")
    }
    /// Échéance « AAAA-MM-JJ » → ce jour-là à 18:00 (heure locale).
    static func deadline(_ due: String) -> Date? {
        guard due.count == 10, let d: Date = dayFmt.date(from: due) else { return nil }
        return Calendar.current.date(byAdding: .hour, value: 18, to: Calendar.current.startOfDay(for: d))
    }
}

// MARK: - Invitation (participants) — VAGUE 1 brief pré-réunion

/// Participants d'une réunion lus dans l'INVITATION (EventKit, lecture seule, seulement si l'accès Calendrier est déjà
/// accordé — jamais de demande d'autorisation ici). Nova ne rejoint jamais la réunion : aucun bot, aucun enregistrement.
enum DailyInvite {
    static func lookup(title: String, start: Date?) -> [String: Any] {
        #if canImport(EventKit) && os(macOS)
        if !Tools.ekAuthorized(.event) { return ["ok": false, "people": [[String: Any]](), "note": "accès Calendrier non accordé à Nova : participants non lus"] }
        let store: EKEventStore = EKEventStore()
        let center: Date = start ?? Date()
        let pred: NSPredicate = store.predicateForEvents(withStart: center.addingTimeInterval(-12 * 3600), end: center.addingTimeInterval(12 * 3600), calendars: nil)
        let evs: [EKEvent] = store.events(matching: pred)
        let want: String = DailyCal.simplify(title)
        var best: EKEvent? = nil
        var bestGap: Double = Double.greatestFiniteMagnitude
        for e in evs {
            let t: String = e.title ?? ""
            if DailyCal.simplify(t) != want { continue }
            let sd: Date = e.startDate ?? center
            let gap: Double = abs(sd.timeIntervalSince(center))
            if gap < bestGap { best = e; bestGap = gap }
        }
        guard let ev: EKEvent = best else { return ["ok": false, "people": [[String: Any]](), "note": "invitation introuvable dans Calendrier"] }
        var people: [[String: Any]] = []
        var seen: Set<String> = []
        var all: [(EKParticipant, String)] = []
        if let org: EKParticipant = ev.organizer { all.append((org, "organisateur")) }
        for p in ev.attendees ?? [] { all.append((p, "invité")) }
        for (p, role) in all {
            if p.isCurrentUser { continue }
            let d: [String: Any] = DailyInvite.person(p, role: role)
            let k: String = (((d["email"] as? String) ?? "") + "|" + ((d["nom"] as? String) ?? "")).lowercased()
            let mailKey: String = ((d["email"] as? String) ?? "").lowercased()
            if seen.contains(k) || (!mailKey.isEmpty && seen.contains(mailKey)) { continue }
            seen.insert(k)
            if !mailKey.isEmpty { seen.insert(mailKey) }
            people.append(d)
            if people.count >= 25 { break }
        }
        let notes: String = String((ev.notes ?? "").prefix(1500))
        return ["ok": true, "people": people, "location": ev.location ?? "", "notes": notes,
                "note": people.isEmpty ? "invitation sans autre participant que toi" : ""]
        #else
        return ["ok": false, "people": [[String: Any]](), "note": "invitation illisible hors macOS"]
        #endif
    }

    #if canImport(EventKit) && os(macOS)
    static func person(_ p: EKParticipant, role: String) -> [String: Any] {
        var mail: String = ""
        let u: String = p.url.absoluteString
        if u.lowercased().hasPrefix("mailto:") { mail = String(u.dropFirst(7)).removingPercentEncoding ?? String(u.dropFirst(7)) }
        let name: String = (p.name ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        var statut: String = ""
        switch p.participantStatus {
        case .accepted: statut = "a accepté"
        case .declined: statut = "a décliné"
        case .tentative: statut = "peut-être"
        case .pending: statut = "sans réponse"
        default: statut = ""
        }
        return ["nom": name.isEmpty ? mail : name, "email": mail, "role": role, "statut": statut]
    }
    #endif

    /// Mots-clés de recherche tirés des participants (noms ≥ 4 lettres, partie locale de l'adresse).
    static func words(_ people: [[String: Any]]) -> [String] {
        var out: [String] = []
        for p in people {
            let nom: String = DailyCal.simplify((p["nom"] as? String) ?? "")
            for w in nom.components(separatedBy: " ") where w.count >= 4 && !DailyCal.stopWords.contains(w) && !out.contains(w) { out.append(w) }
            let mail: String = ((p["email"] as? String) ?? "").lowercased()
            if let at: String.Index = mail.firstIndex(of: "@") {
                let local: String = String(mail[mail.startIndex..<at])
                for w in local.components(separatedBy: CharacterSet(charactersIn: "._-+")) where w.count >= 4 && !out.contains(w) { out.append(w) }
            }
        }
        return Array(out.prefix(12))
    }
}

// MARK: - Routes et logique

extension NovaApp {
    func dailyRoutes() {
        let s = server

        // ───────── (A) Mode réunion ─────────
        s.on("GET", "/api/meeting/next") { [self] req, res in
            let force: Bool = (req.query["force"] ?? "") == "1"
            let evs: [[String: Any]] = dailyEvents(force: force)
            let now: Double = Date().timeIntervalSince1970
            var next: Any = NSNull()
            var past: Any = NSNull()
            for e in evs {
                let ts: Double = (e["ts"] as? Double) ?? 0
                if ts >= now - 15 * 60 && ts <= now + 3 * 3600 { next = dailyDecorate(e, now: now); break }
            }
            for e in evs.reversed() {
                let ts: Double = (e["ts"] as? Double) ?? 0
                if ts < now - 20 * 60 && ts >= now - 4 * 3600 { past = dailyDecorate(e, now: now); break }
            }
            let st: DailyState = DailyState.shared
            st.lock.lock(); let note: String = st.calNote; st.lock.unlock()
            res.json(["next": next, "past": past, "count": evs.count, "note": note, "ts": nowISO()])
        }
        // NDL (24/10) : la frise « Aujourd'hui » de l'Accueil — tous les événements du jour, décorés (lecture seule)
        s.on("GET", "/api/today") { [self] _, res in
            let now: Double = Date().timeIntervalSince1970
            let evs: [[String: Any]] = dailyEvents(force: false)
            let items: [[String: Any]] = evs.map { dailyDecorate($0, now: now) }
            res.json(["items": items, "ts": nowISO()])
        }
        s.on("GET", "/api/meeting/prep") { [self] req, res in
            let key: String = req.query["key"] ?? ""
            let title: String = req.query["title"] ?? ""
            if !key.isEmpty, let e: [String: Any] = dailyPrepGet(key) { res.json(e); return }
            if !title.isEmpty, let e: [String: Any] = dailyPrepFind(title: title) { res.json(e); return }
            res.json(["status": "absent", "key": key])
        }
        s.on("POST", "/api/meeting/prep") { [self] req, res in
            let j: [String: Any] = req.json
            let title: String = ((j["title"] as? String) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            if title.isEmpty { res.json(["error": "titre requis"], status: 400); return }
            let when: String = (j["when"] as? String) ?? ""
            let start: String = (j["start"] as? String) ?? ""
            let people: String = (j["people"] as? String) ?? ""
            let force: Bool = (j["force"] as? Bool) ?? false
            var key: String = (j["key"] as? String) ?? ""
            if key.isEmpty { key = title + "|" + (start.isEmpty ? when : start) }
            if !force, let c: [String: Any] = dailyPrepGet(key) {
                let status: String = (c["status"] as? String) ?? ""
                let epoch: Double = (c["epoch"] as? Double) ?? 0
                let fresh: Bool = Date().timeIntervalSince1970 - epoch < 12 * 3600
                if status == "pret" && fresh { res.json(c); return }
                if status == "en_cours" && dailyIsPreparing(key) { res.json(c); return }
            }
            DailyState.shared.work.async { [self] in _ = dailyPrepare(key: key, title: title, when: when, people: people) }
            res.json(["key": key, "title": title, "when": when, "status": "en_cours"])
        }
        s.on("POST", "/api/meeting/followup") { [self] req, res in
            let j: [String: Any] = req.json
            let title: String = ((j["title"] as? String) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            let notes: String = ((j["notes"] as? String) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            let key: String = (j["key"] as? String) ?? ""
            if title.isEmpty && notes.isEmpty { res.json(["error": "titre ou notes requis"], status: 400); return }
            res.json(dailyFollowup(title: title, notes: notes, key: key))
        }

        // ───────── (B) Résumé du matin ─────────
        s.on("GET", "/api/morning") { [self] req, res in
            let force: Bool = (req.query["force"] ?? "") == "1"
            let st: DailyState = DailyState.shared
            let saved: [String: Any] = st.morningFile.read(default: [String: Any]())
            let epoch: Double = (saved["epoch"] as? Double) ?? 0
            let page: Any = saved["page"] ?? NSNull()
            let sameDay: Bool = Calendar.current.isDateInToday(Date(timeIntervalSince1970: epoch))
            let fresh: Bool = sameDay && Date().timeIntervalSince1970 - epoch < 1800
            if fresh && !force { res.json(["status": "pret", "cached": true, "page": page]); return }
            st.lock.lock()
            let running: Bool = st.morningRunning
            if !running { st.morningRunning = true }
            st.lock.unlock()
            if !running {
                st.work.async { [self] in
                    let p: [String: Any] = dailyMorningCompile()
                    let rec: [String: Any] = ["epoch": Date().timeIntervalSince1970, "page": p]
                    st.morningFile.write(rec)
                    st.lock.lock(); st.morningRunning = false; st.lock.unlock()
                }
            }
            res.json(["status": "en_cours", "cached": false, "page": page])
        }

        // ───────── (C) Engagements ─────────
        s.on("GET", "/api/commitments") { [self] _, res in
            let st: DailyState = DailyState.shared
            let o: [String: Any] = st.commitFile.read(default: [String: Any]())
            let items: [[String: Any]] = dailySortCommitments((o["items"] as? [[String: Any]]) ?? [])
            st.lock.lock(); let running: Bool = st.scanRunning; st.lock.unlock()
            res.json(["items": items, "last_scan": o["last_scan"] ?? "", "last_note": o["last_note"] ?? "", "running": running])
        }
        s.on("POST", "/api/commitments/scan") { [self] _, res in
            let st: DailyState = DailyState.shared
            st.lock.lock(); let running: Bool = st.scanRunning; st.lock.unlock()
            if !running { st.work.async { [self] in _ = dailyScanCommitments() } }
            res.json(["status": "en_cours"])
        }
        s.on("POST", "/api/commitments/update") { [self] req, res in
            let j: [String: Any] = req.json
            let id: String = (j["id"] as? String) ?? ""
            let status: String = (j["status"] as? String) ?? ""
            if id.isEmpty || !["ouvert", "fait", "ignore"].contains(status) { res.json(["error": "id et statut (ouvert|fait|ignore) requis"], status: 400); return }
            let st: DailyState = DailyState.shared
            st.lock.lock()
            var o: [String: Any] = st.commitFile.read(default: [String: Any]())
            var items: [[String: Any]] = (o["items"] as? [[String: Any]]) ?? []
            var found: Bool = false
            for i in items.indices where (items[i]["id"] as? String) == id { items[i]["status"] = status; found = true }
            o["items"] = items
            st.commitFile.write(o)
            st.lock.unlock()
            res.json(["ok": found])
        }

        dailyStartTimers()
    }

    // MARK: minuteurs

    func dailyStartTimers() {
        let st: DailyState = DailyState.shared
        st.lock.lock()
        if st.started { st.lock.unlock(); return }
        st.started = true
        st.lock.unlock()
        // Réunions + alertes d'échéance : toutes les 10 min (1er passage après 4 min de calme au démarrage).
        let t1: DispatchSourceTimer = DispatchSource.makeTimerSource(queue: DispatchQueue(label: "nova.daily.meeting", qos: .utility))
        t1.schedule(deadline: .now() + 240, repeating: 600, leeway: .seconds(5))
        t1.setEventHandler { [weak self] in
            guard let me = self else { return }
            me.dailyMeetingTick()
            me.dailyCommitmentAlerts()
        }
        // Scan des engagements : 2 fois par jour (et jamais deux scans automatiques à moins de 6 h d'écart, même après un redémarrage).
        let t2: DispatchSourceTimer = DispatchSource.makeTimerSource(queue: DispatchQueue(label: "nova.daily.commitments", qos: .utility))
        t2.schedule(deadline: .now() + 1200, repeating: 12 * 3600, leeway: .seconds(60))
        t2.setEventHandler { [weak self] in
            guard let me = self else { return }
            if !me.settings.get("commitments_auto_scan", true) { return }
            let o: [String: Any] = st.commitFile.read(default: [String: Any]())
            let last: Double = (o["last_epoch"] as? Double) ?? 0
            if Date().timeIntervalSince1970 - last < 6 * 3600 { return }
            _ = me.dailyScanCommitments()
        }
        st.lock.lock(); st.timers.append(t1); st.timers.append(t2); st.lock.unlock()
        t1.resume()
        t2.resume()
    }

    func dailyMeetingTick() {
        if !settings.get("meeting_auto_prep", true) { return }
        if !Rituels.allows("reunion", settings: settings) { return }   // V5-O : rituel « Brief pré-réunion » (rituels_on + ritual_reunion)
        let lead: Double = Double(Rituels.meetingLead(settings))   // V5-O : avance réglable 30 / 60 / 120 min (meeting_brief_lead_min, défaut 30)
        let evs: [[String: Any]] = dailyEvents(force: false)
        let now: Double = Date().timeIntervalSince1970
        for e in evs {
            let ts: Double = (e["ts"] as? Double) ?? 0
            let mins: Double = (ts - now) / 60
            if mins <= 0 || mins > lead + 10 { continue }   // VAGUE 1 : brief à T-lead (tic de 10 min : premier passage entre T-(lead+10) et T-lead)
            let key: String = (e["key"] as? String) ?? ""
            let title: String = (e["title"] as? String) ?? ""
            let label: String = (e["label"] as? String) ?? ""
            if key.isEmpty || title.isEmpty { continue }
            var entry: [String: Any] = dailyPrepGet(key) ?? [:]
            if (entry["notified"] as? Bool) == true { continue }
            if (entry["status"] as? String) != "pret" { entry = dailyPrepare(key: key, title: title, when: label, people: "") }
            dailyPrepPatch(key, ["notified": true])
            Rituels.mark("reunion")   // V5-O : dernier passage réel du rituel
            let ev: [String: Any] = ["phase": "ready", "key": key, "title": title, "when": label, "minutes": Int(mins),
                                     "status": (entry["status"] as? String) ?? "", "auto": true]
            bus.publish("meeting", ev)
            // PROCHAT (21/10) : l'alerte réunion entre aussi au journal proactif —
            // le bus seul est sans abonné web et sans rejeu, elle était perdue.
            ProactiveFeed.append(kind: "meeting", box: "cal", title: title + " — " + label,
                                 text: "Réunion dans \(Int(mins)) min. Préparation : \((entry["status"] as? String) ?? "—").")
            // VAGUE 1 : notification d'arrivée dans le Pulse du jour (une carte par réunion).
            let nP: Int = ((entry["participants"] as? [[String: Any]]) ?? []).count
            var lignes: [String] = [nP > 0 ? String(nP) + " participant(s) lus dans l'invitation." : "Participants : " + ((entry["participants_note"] as? String) ?? "non lus") + "."]
            if let q = (entry["questions"] as? [String])?.first, !q.isEmpty { lignes.append("Première question à poser : " + q) }
            lignes.append("Nova ne rejoint jamais la réunion : le brief est pour toi seul.")
            let ok: Bool = (entry["status"] as? String) == "pret"
            pulseArrival(cat: "reunion", titre: (ok ? "Brief prêt : " : "Brief partiel : ") + title + " à " + ((e["hhmm"] as? String) ?? ""),
                         lignes: lignes, sourceNom: "Invitation + fiche Nova", sourceDate: (e["start"] as? String) ?? nowISO(),
                         action: ["type": "ouvrir", "module": "temps", "label": "Lire le brief"], ref: "r:" + key)
        }
    }

    // MARK: agenda

    func dailyEvents(force: Bool) -> [[String: Any]] {
        let st: DailyState = DailyState.shared
        st.lock.lock()
        let fresh: Bool = !force && Date().timeIntervalSince(st.eventsAt) < 120
        let cached: [[String: Any]] = st.events
        st.lock.unlock()
        if fresh { return cached }
        let txt: String = tools.run("calendar", "", why: "Mode réunion : lecture de l'agenda (lecture seule)", actor: "Nova")
        let evs: [[String: Any]] = DailyCal.parse(txt)
        var note: String = ""
        if evs.isEmpty && DailyCal.unavailable(txt) { note = String(txt.prefix(200)) }
        st.lock.lock(); st.eventsAt = Date(); st.events = evs; st.calNote = note; st.lock.unlock()
        return evs
    }

    func dailyDecorate(_ e: [String: Any], now: Double) -> [String: Any] {
        var o: [String: Any] = e
        let ts: Double = (e["ts"] as? Double) ?? 0
        o["minutes"] = Int((ts - now) / 60)
        let key: String = (e["key"] as? String) ?? ""
        if let p: [String: Any] = dailyPrepGet(key) { o["prep_status"] = (p["status"] as? String) ?? "" } else { o["prep_status"] = "absent" }
        return o
    }

    // MARK: fiches de réunion (cache meeting_prep.json)

    func dailyPrepGet(_ key: String) -> [String: Any]? {
        let all: [String: Any] = DailyState.shared.prepFile.read(default: [String: Any]())
        return all[key] as? [String: Any]
    }
    func dailyPrepFind(title: String) -> [String: Any]? {
        let all: [String: Any] = DailyState.shared.prepFile.read(default: [String: Any]())
        let want: String = DailyCal.simplify(title)
        var best: [String: Any]? = nil
        var bestEpoch: Double = 0
        for (_, v) in all {
            guard let e: [String: Any] = v as? [String: Any] else { continue }
            let t: String = DailyCal.simplify((e["title"] as? String) ?? "")
            let ep: Double = (e["epoch"] as? Double) ?? 0
            if t == want && ep > bestEpoch && Date().timeIntervalSince1970 - ep < 2 * 86400 { best = e; bestEpoch = ep }
        }
        return best
    }
    func dailyPrepPut(_ key: String, _ entry: [String: Any]) {
        let st: DailyState = DailyState.shared
        st.lock.lock()
        var all: [String: Any] = st.prepFile.read(default: [String: Any]())
        all[key] = entry
        if all.count > 40 {
            var pairs: [(String, Double)] = []
            for (k, v) in all {
                let ep: Double = ((v as? [String: Any])?["epoch"] as? Double) ?? 0
                pairs.append((k, ep))
            }
            let sorted: [(String, Double)] = pairs.sorted { (a: (String, Double), b: (String, Double)) -> Bool in a.1 > b.1 }
            var keep: [String: Any] = [:]
            for (k, _) in sorted.prefix(40) { keep[k] = all[k] }
            all = keep
        }
        st.prepFile.write(all)
        st.lock.unlock()
    }
    func dailyPrepPatch(_ key: String, _ patch: [String: Any]) {
        let st: DailyState = DailyState.shared
        st.lock.lock()
        var all: [String: Any] = st.prepFile.read(default: [String: Any]())
        var e: [String: Any] = (all[key] as? [String: Any]) ?? ["key": key, "epoch": Date().timeIntervalSince1970]
        for (k, v) in patch { e[k] = v }
        all[key] = e
        st.prepFile.write(all)
        st.lock.unlock()
    }
    func dailyIsPreparing(_ key: String) -> Bool {
        let st: DailyState = DailyState.shared
        st.lock.lock(); let r: Bool = st.prepRunning.contains(key); st.lock.unlock()
        return r
    }

    /// BRIEF PRÉ-RÉUNION (VAGUE 1, patron Granola) : participants de l'invitation, derniers échanges avec eux (mails, Teams,
    /// courrier lu), engagements en cours avec eux, faits mémoire, documents — puis le cerveau « deep » rédige contexte,
    /// décisions attendues et 3 questions à poser. Participants et engagements sont DÉTERMINISTES (jamais rédigés par le
    /// cerveau). Synchrone : à appeler hors du fil principal. Nova ne rejoint jamais la réunion.
    @discardableResult
    func dailyPrepare(key: String, title: String, when: String, people: String) -> [String: Any] {
        let st: DailyState = DailyState.shared
        st.lock.lock()
        if st.prepRunning.contains(key) { st.lock.unlock(); return ["key": key, "title": title, "status": "en_cours"] }
        st.prepRunning.insert(key)
        st.lock.unlock()
        defer { st.lock.lock(); st.prepRunning.remove(key); st.lock.unlock() }
        let t0: Date = Date()
        let notified: Bool = (dailyPrepGet(key)?["notified"] as? Bool) ?? false
        dailyPrepPut(key, ["key": key, "title": title, "when": when, "status": "en_cours", "ts": nowISO(), "epoch": t0.timeIntervalSince1970, "notified": notified])

        // Participants : l'invitation d'abord (EventKit), sinon ceux fournis par l'appelant.
        var startDate: Date? = nil
        if let bar: String.Index = key.lastIndex(of: "|") { startDate = DailyCal.iso.date(from: String(key[key.index(after: bar)...])) }
        let invite: [String: Any] = DailyInvite.lookup(title: title, start: startDate)
        var participants: [[String: Any]] = (invite["people"] as? [[String: Any]]) ?? []
        var participantsNote: String = (invite["note"] as? String) ?? ""
        let given: String = people.trimmingCharacters(in: .whitespacesAndNewlines)
        if participants.isEmpty && !given.isEmpty {
            for n in given.components(separatedBy: CharacterSet(charactersIn: ",;")) {
                let t: String = n.trimmingCharacters(in: .whitespaces)
                if !t.isEmpty { participants.append(["nom": t, "email": "", "role": "indiqué", "statut": ""]) }
            }
            participantsNote = "participants indiqués à la demande (invitation non lue)"
        }
        let names: [String] = participants.compactMap { ($0["nom"] as? String) }.filter { !$0.isEmpty }
        let nameWords: [String] = DailyInvite.words(participants)
        let titleWords: [String] = DailyCal.keywords(title)
        var words: [String] = titleWords
        for w in nameWords where !words.contains(w) { words.append(w) }
        let peopleLine: String = names.prefix(8).joined(separator: ", ")
        let searchWords: [String] = words

        let why: String = "Brief pré-réunion « " + String(title.prefix(80)) + " » (lecture seule)"
        var mailBlock: String = ""
        var teamsBlock: String = ""
        var docsBlock: String = ""
        var memBlock: String = ""
        var srcOK: [String: Bool] = [:]
        let g: DispatchGroup = DispatchGroup()
        let l: NSLock = NSLock()

        g.enter()
        DispatchQueue.global(qos: .utility).async { [self] in
            let raw: String = tools.run("mail_week", "7", why: why, actor: "Nova")
            let hits: [String] = DailyCal.relevantLines(raw, searchWords, max: 30)
            let b: String
            if DailyCal.unavailable(raw) && hits.isEmpty { b = "INDISPONIBLE : " + String(raw.prefix(240)) }
            else if hits.isEmpty { b = "Aucun mail des 7 derniers jours ne mentionne : " + searchWords.joined(separator: ", ") + "." }
            else { b = hits.joined(separator: "\n") }
            l.lock(); mailBlock = b; srcOK["mails"] = !hits.isEmpty; l.unlock()
            g.leave()
        }
        g.enter()
        DispatchQueue.global(qos: .utility).async { [self] in
            let raw: String = tools.run("teams_read", "", why: why, actor: "Nova")
            let hits: [String] = DailyCal.relevantLines(raw, searchWords, max: 20)
            let b: String
            if raw.hasPrefix("Teams : le volet") { b = "INDISPONIBLE : volet Teams de Nova non connecté." }
            else if hits.isEmpty { b = "Aucun échange Teams récent visible ne mentionne : " + searchWords.joined(separator: ", ") + "." }
            else { b = hits.joined(separator: "\n") }
            l.lock(); teamsBlock = b; srcOK["teams"] = !hits.isEmpty; l.unlock()
            g.leave()
        }
        g.enter()
        DispatchQueue.global(qos: .utility).async { [self] in
            var paths: [String] = []
            var queries: [String] = [title]
            if !peopleLine.isEmpty { queries.append(names.first ?? peopleLine) }
            for q in queries {
                let out: String = tools.run("find", q, why: why, actor: "Nova")
                for line in out.components(separatedBy: "\n") {
                    let t: String = line.trimmingCharacters(in: .whitespaces)
                    if !t.hasPrefix("/") { continue }
                    let low: String = t.lowercased()
                    if low.contains("/library/") || low.contains("/.") || low.contains(".app/") || low.hasSuffix(".app") { continue }
                    if !paths.contains(t) { paths.append(t) }
                    if paths.count >= 8 { break }
                }
            }
            var b: String = ""
            if paths.isEmpty { b = "Aucun document Spotlight trouvé pour « " + title + " »." }
            else {
                b = "Documents trouvés :\n" + paths.map { (x: String) -> String in "- " + x }.joined(separator: "\n")
                let readable: [String] = ["txt", "md", "docx", "doc", "rtf", "pdf", "odt"]
                var nRead: Int = 0
                for path in paths {
                    if nRead >= 2 { break }
                    let ext: String = (path as NSString).pathExtension.lowercased()
                    if !readable.contains(ext) { continue }
                    let txt: String = tools.run("read_file", path, why: why, actor: "Nova")
                    if txt.hasPrefix("Chemin refusé") || txt.hasPrefix("Fichier introuvable") || txt.hasPrefix("Lecture du document impossible") { continue }
                    nRead += 1
                    let name: String = (path as NSString).lastPathComponent
                    b += "\n\nExtrait de « " + name + " » :\n" + DailyCal.clip(txt, 1200)
                }
            }
            l.lock(); docsBlock = b; srcOK["documents"] = !paths.isEmpty; l.unlock()
            g.leave()
        }
        g.enter()
        DispatchQueue.global(qos: .utility).async { [self] in
            var raw: String = tools.run("recall", title, why: why, actor: "Nova")
            var hit: Bool = !raw.hasPrefix("Rien en mémoire")
            for n in names.prefix(2) {
                let r2: String = tools.run("recall", n, why: why, actor: "Nova")
                if !r2.hasPrefix("Rien en mémoire") { raw += "\n\n— À propos de " + n + " :\n" + r2; hit = true }
            }
            l.lock(); memBlock = DailyCal.clip(raw, 2000); srcOK["memoire"] = hit; l.unlock()
            g.leave()
        }

        // Engagements en cours avec les participants (ou liés au sujet) — déterministe, depuis commitments.json.
        var engagements: [[String: Any]] = []
        let co: [String: Any] = st.commitFile.read(default: [String: Any]())
        for c in dailySortCommitments((co["items"] as? [[String: Any]]) ?? []) {
            if ((c["status"] as? String) ?? "ouvert") != "ouvert" { continue }
            let qui: String = DailyCal.simplify((c["qui"] as? String) ?? "")
            let quoi: String = DailyCal.simplify((c["quoi"] as? String) ?? "")
            var hit: Bool = false
            for w in nameWords where qui.contains(w) { hit = true; break }
            if !hit { for w in titleWords where quoi.contains(DailyCal.simplify(w)) { hit = true; break } }
            if !hit { continue }
            engagements.append(["id": c["id"] ?? "", "quoi": c["quoi"] ?? "", "qui": c["qui"] ?? "", "dir": c["dir"] ?? "moi",
                                "echeance": c["echeance"] ?? "", "source": c["source"] ?? ""])
            if engagements.count >= 8 { break }
        }
        // Courrier LU récemment de ces personnes (corps déjà lus par Nova, 14 jours) — déterministe.
        var lus: [String] = []
        if !nameWords.isEmpty {
            let bodies: [String: Any] = JSONFile("webmail_bodies.json").read(default: [String: Any]())
            let cutoff: Date = Date().addingTimeInterval(-14 * 86400)
            var rows: [(String, String)] = []
            for (k, v) in bodies {
                guard let d = v as? [String: Any], let ts = d["ts"] as? String, let dt: Date = DailyCal.iso.date(from: ts), dt > cutoff else { continue }
                let parts: [String] = k.components(separatedBy: "│")
                let from: String = parts.first ?? ""
                let low: String = DailyCal.simplify(from)
                var hit: Bool = false
                for w in nameWords where low.contains(w) { hit = true; break }
                if !hit { continue }
                let subject: String = parts.count > 1 ? parts[1] : ""
                let flat: String = ((d["body"] as? String) ?? "").replacingOccurrences(of: "\n", with: " ")
                var row: String = String(ts.prefix(10)) + " — " + from
                row += " — « " + subject + " » : "
                row += String(flat.prefix(220))
                rows.append((ts, row))
            }
            for r in rows.sorted(by: { (a: (String, String), b: (String, String)) -> Bool in a.0 > b.0 }).prefix(6) { lus.append(r.1) }
        }
        _ = g.wait(timeout: .now() + 200)

        l.lock()
        var data: String = "### Participants (invitation)\n"
        if participants.isEmpty { data += "Non lus : " + (participantsNote.isEmpty ? "aucune information" : participantsNote) + "." }
        else {
            var rowsP: [String] = []
            for p in participants {
                let nom: String = (p["nom"] as? String) ?? ""
                let mail: String = (p["email"] as? String) ?? ""
                let role: String = (p["role"] as? String) ?? ""
                let stat: String = (p["statut"] as? String) ?? ""
                var line: String = "- " + nom
                if !mail.isEmpty { line += " <" + mail + ">" }
                line += " · " + role
                if !stat.isEmpty { line += " · " + stat }
                rowsP.append(line)
            }
            data += rowsP.joined(separator: "\n")
        }
        let inviteNotes: String = (invite["notes"] as? String) ?? ""
        if !inviteNotes.isEmpty { data += "\n\n### Texte de l'invitation\n" + DailyCal.clip(inviteNotes, 1200) }
        data += "\n\n### Mails (7 derniers jours, lignes liées au sujet ou aux participants)\n" + mailBlock
        data += "\n\n### Courrier lu de ces participants (14 jours)\n" + (lus.isEmpty ? "Aucun corps de mail lu de ces personnes." : lus.joined(separator: "\n"))
        data += "\n\n### Teams\n" + teamsBlock
        data += "\n\n### Engagements en cours (suivis par Nova)\n"
        if engagements.isEmpty { data += "Aucun engagement ouvert lié à ces personnes ou à ce sujet." }
        else {
            var rowsE: [String] = []
            for c in engagements {
                let dirTxt: String = ((c["dir"] as? String) ?? "moi") == "eux" ? "on me doit" : "je dois"
                let ech: String = (c["echeance"] as? String) ?? ""
                let quoiTxt: String = (c["quoi"] as? String) ?? ""
                let quiTxt: String = (c["qui"] as? String) ?? ""
                var line: String = "- " + dirTxt + " : " + quoiTxt + " (" + quiTxt + ")"
                if !ech.isEmpty { line += " · échéance " + ech }
                rowsE.append(line)
            }
            data += rowsE.joined(separator: "\n")
        }
        data += "\n\n### Documents (Spotlight, lecture seule)\n" + docsBlock
        data += "\n\n### Mémoire Nova\n" + memBlock
        var sources: [String: Bool] = srcOK
        l.unlock()
        sources["invitation"] = !participants.isEmpty
        sources["engagements"] = !engagements.isEmpty
        sources["courrier_lu"] = !lus.isEmpty

        let name: String = settings.get("name", "Ahadi")
        let sys: String = "Tu es Nova, l'assistant personnel de " + name + ". Tu rédiges en français un BRIEF PRÉ-RÉUNION, lu en 1 minute. "
            + "Utilise UNIQUEMENT les données fournies : aucun fait, nom, chiffre ou date absent des données ; marque [À vérifier] toute supposition ; si une source est INDISPONIBLE, dis-le. "
            + "Réponds UNIQUEMENT par un objet JSON strict, sans autre texte : "
            + "{\"contexte\":\"2 phrases BLUF : de quoi il s'agit et ce qui est en jeu\",\"echanges\":[\"3 à 5 faits récents datés avec ces personnes, chacun suivi de sa source entre parenthèses\"],"
            + "\"decisions\":[\"1 à 3 décisions attendues de cette réunion\"],\"questions\":[\"exactement 3 questions à poser, courtes\"],\"vigilance\":\"une ligne ou vide\"}. "
            + "N'envoie et ne propose d'envoyer aucun message. Nova ne participe pas à la réunion."
        var head: String = "Réunion : « " + title + " »"
        if !when.isEmpty { head += " — " + when }
        if !peopleLine.isEmpty { head += "\nParticipants : " + peopleLine }
        let prompt: String = head + "\n\nDONNÉES COLLECTÉES :\n\n" + data
        let r: (text: String, brain: String)? = router.complete(messages: [ChatMsg("user", prompt)], system: sys, mode: "deep", maxTokens: 1400)
        var entry: [String: Any] = ["key": key, "title": title, "when": when, "people": peopleLine, "ts": nowISO(), "epoch": Date().timeIntervalSince1970,
                                    "sources": sources, "ms": Int(Date().timeIntervalSince(t0) * 1000), "notified": notified,
                                    "participants": participants, "participants_note": participantsNote, "engagements": engagements,
                                    "location": (invite["location"] as? String) ?? "", "bot": false]
        var partsMd: String = "## Participants\n"
        if participants.isEmpty { partsMd += "Non lus : " + (participantsNote.isEmpty ? "aucune information" : participantsNote) + ".\n" }
        else {
            for p in participants.prefix(12) {
                let st2: String = (p["statut"] as? String) ?? ""
                let nom: String = (p["nom"] as? String) ?? ""
                let role: String = (p["role"] as? String) ?? ""
                var line: String = "- " + nom + " · " + role
                if !st2.isEmpty { line += " · " + st2 }
                partsMd += line + "\n"
            }
        }
        var engMd: String = "## Engagements en cours avec eux\n"
        if engagements.isEmpty { engMd += "Aucun engagement ouvert lié à ces personnes ou à ce sujet.\n" }
        else {
            for c in engagements {
                let dirTxt: String = ((c["dir"] as? String) ?? "moi") == "eux" ? "On te doit" : "Tu dois"
                let ech: String = (c["echeance"] as? String) ?? ""
                let quoiTxt: String = (c["quoi"] as? String) ?? ""
                let quiTxt: String = (c["qui"] as? String) ?? ""
                var line: String = "- " + dirTxt + " : " + quoiTxt + " (" + quiTxt + ")"
                if !ech.isEmpty { line += " · " + ech }
                engMd += line + "\n"
            }
        }
        let okNames: [String] = sources.filter { $0.value }.map { $0.key }.sorted()
        let srcLine: String = "Sources : " + (okNames.isEmpty ? "aucune source n'a renvoyé de donnée liée" : okNames.joined(separator: ", ")) + "."
        if let rr = r {
            entry["brain"] = router.spec(rr.brain)?.label ?? rr.brain
            if let o: [String: Any] = DailyCal.jsonSlice(rr.text, open: "{", close: "}") as? [String: Any] {
                let contexte: String = ((o["contexte"] as? String) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
                let echanges: [String] = DailyCal.strings(o["echanges"], max: 6)
                let decisions: [String] = DailyCal.strings(o["decisions"], max: 3)
                let questions: [String] = DailyCal.strings(o["questions"], max: 3)
                let vigilance: String = ((o["vigilance"] as? String) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
                entry["contexte"] = contexte
                entry["echanges"] = echanges
                entry["decisions"] = decisions
                entry["questions"] = questions
                entry["vigilance"] = vigilance
                var md: String = contexte.isEmpty ? "" : "**" + contexte + "**\n\n"
                md += partsMd + "\n## Derniers échanges\n"
                if echanges.isEmpty { md += "Aucun échange récent retrouvé avec ces personnes.\n" }
                for x in echanges { md += "- " + x + "\n" }
                md += "\n" + engMd
                md += "\n## Décisions attendues\n"
                if decisions.isEmpty { md += "Aucune décision identifiée dans les données.\n" }
                for x in decisions { md += "- " + x + "\n" }
                md += "\n## 3 questions à poser\n"
                for (i, q) in questions.enumerated() { md += String(i + 1) + ". " + q + "\n" }
                if !vigilance.isEmpty { md += "\n**Vigilance :** " + vigilance + "\n" }
                md += "\n" + srcLine
                entry["text"] = md
            } else {
                entry["text"] = partsMd + "\n" + engMd + "\n" + rr.text + "\n\n" + srcLine
            }
            entry["status"] = "pret"
        } else {
            entry["status"] = "erreur"
            entry["brain"] = "aucun"
            entry["text"] = "**Aucun cerveau n'a répondu : voici les données brutes rassemblées.**\n\n" + partsMd + "\n" + engMd + "\n" + data
        }
        dailyPrepPut(key, entry)
        return entry
    }

    /// GET /api/meeting/brief?key= : le brief de la réunion ; absent ou périmé (> 12 h) → préparation lancée en arrière-plan.
    func dailyBrief(key: String, force: Bool) -> [String: Any] {
        if !force, let e: [String: Any] = dailyPrepGet(key) {
            let status: String = (e["status"] as? String) ?? ""
            let maxAge: Double = ((e["veille"] as? Bool) == true) ? 20 * 3600 : 12 * 3600   // AUTONOMIE (25/10) : fiche préparée la veille à 20:30 → encore valable le lendemain
            let fresh: Bool = Date().timeIntervalSince1970 - ((e["epoch"] as? Double) ?? 0) < maxAge
            if status == "en_cours" && dailyIsPreparing(key) { return e }
            if (status == "pret" || status == "erreur") && fresh && e["participants"] != nil { return e }
        }
        if dailyIsPreparing(key) { return ["key": key, "status": "en_cours"] }
        var title: String = ""
        var when: String = ""
        for e in dailyEvents(force: false) where (e["key"] as? String) == key {
            title = (e["title"] as? String) ?? ""
            when = (e["label"] as? String) ?? ""
            break
        }
        if title.isEmpty, let bar: String.Index = key.lastIndex(of: "|") { title = String(key[key.startIndex..<bar]) }
        if title.isEmpty { return ["key": key, "status": "absent", "error": "réunion introuvable dans l'agenda"] }
        let t: String = title
        let w: String = when
        DailyState.shared.work.async { [self] in _ = dailyPrepare(key: key, title: t, when: w, people: "") }
        return ["key": key, "title": title, "when": when, "status": "en_cours"]
    }

    /// Actions de suivi : synthèse + brouillons enregistrés via draft_reply (jamais envoyés).
    func dailyFollowup(title: String, notes: String, key: String) -> [String: Any] {
        var context: String = ""
        var prep: [String: Any]? = nil
        if !key.isEmpty { prep = dailyPrepGet(key) }
        if prep == nil && !title.isEmpty { prep = dailyPrepFind(title: title) }
        if let p = prep, let t = p["text"] as? String { context = DailyCal.clip(t, 2500) }
        let name: String = settings.get("name", "Ahadi")
        let sys: String = "Tu es Nova, l'assistant de " + name + ". Après une réunion, tu proposes des ACTIONS DE SUIVI. Réponds UNIQUEMENT par un objet JSON strict, sans autre texte : "
            + "{\"resume\":\"2 phrases\",\"actions\":[{\"action\":\"…\",\"qui\":\"…\",\"echeance\":\"AAAA-MM-JJ ou vide\"}],"
            + "\"brouillons\":[{\"to\":\"destinataire ou vide\",\"subject\":\"objet\",\"body\":\"texte\"}]}. "
            + "Au plus 6 actions et 2 brouillons. Chaque brouillon suit la charte : salutation, une phrase de contexte, points clés en liste, action demandée en gras (**…**), formule de clôture. "
            + "N'invente aucun fait absent des notes ou de la fiche ; écris [à préciser] si une information manque."
        var prompt: String = "Réunion : « " + (title.isEmpty ? "sans titre" : title) + " »\nAujourd'hui : " + DailyCal.dayFmt.string(from: Date())
        if !notes.isEmpty { prompt += "\n\nNOTES DE RÉUNION :\n" + DailyCal.clip(notes, 8000) }
        if !context.isEmpty { prompt += "\n\nFICHE DE PRÉPARATION :\n" + context }
        guard let r: (text: String, brain: String) = router.complete(messages: [ChatMsg("user", prompt)], system: sys, mode: "deep", maxTokens: 1600) else {
            return ["ok": false, "error": "Aucun cerveau n'a répondu (vérifie les clés dans Système › Réglages)."]
        }
        guard let o: [String: Any] = DailyCal.jsonSlice(r.text, open: "{", close: "}") as? [String: Any] else {
            return ["ok": true, "resume": "", "actions": [Any](), "drafts": [Any](), "raw": r.text, "brain": r.brain, "note": "Réponse non structurée : aucun brouillon enregistré."]
        }
        var actions: [[String: Any]] = []
        for a in ((o["actions"] as? [Any]) ?? []).prefix(6) {
            guard let d = a as? [String: Any] else { continue }
            let act: String = (d["action"] as? String) ?? ""
            if act.isEmpty { continue }
            actions.append(["action": String(act.prefix(240)), "qui": String(((d["qui"] as? String) ?? "").prefix(80)), "echeance": String(((d["echeance"] as? String) ?? "").prefix(10))])
        }
        var drafts: [[String: Any]] = []
        for b in ((o["brouillons"] as? [Any]) ?? []).prefix(2) {
            guard let d = b as? [String: Any] else { continue }
            let body: String = (d["body"] as? String) ?? ""
            if body.isEmpty { continue }
            let draft: [String: Any] = ["to": (d["to"] as? String) ?? "", "subject": (d["subject"] as? String) ?? ("Suivi : " + title), "body": body]
            var saved: String = "Brouillon non enregistré."
            if let jd: Data = try? JSONSerialization.data(withJSONObject: draft, options: []), let js: String = String(data: jd, encoding: .utf8) {
                saved = tools.run("draft_reply", js, why: "Actions de suivi de la réunion « " + String(title.prefix(80)) + " »", actor: "Nova")
            }
            var shown: [String: Any] = draft
            shown["saved"] = saved
            drafts.append(shown)
        }
        return ["ok": true, "resume": (o["resume"] as? String) ?? "", "actions": actions, "drafts": drafts, "brain": r.brain,
                "note": "Brouillons enregistrés dans Nova, à valider : rien n'a été envoyé."]
    }

    // MARK: (B) résumé du matin

    func dailyMorningCompile() -> [String: Any] {
        let t0: Date = Date()
        let why: String = "Résumé du matin (lecture seule)"
        var mailRaw: String = ""
        var brvmRaw: String = ""
        var evs: [[String: Any]] = []
        let g: DispatchGroup = DispatchGroup()
        let l: NSLock = NSLock()
        g.enter()
        DispatchQueue.global(qos: .utility).async { [self] in
            let r: String = tools.run("mail_unread", "", why: why, actor: "Nova")
            l.lock(); mailRaw = r; l.unlock(); g.leave()
        }
        g.enter()
        DispatchQueue.global(qos: .utility).async { [self] in
            let r: String = tools.run("brvm_cours", "", why: why, actor: "Nova")
            l.lock(); brvmRaw = r; l.unlock(); g.leave()
        }
        g.enter()
        DispatchQueue.global(qos: .utility).async { [self] in
            let r: [[String: Any]] = dailyEvents(force: false)
            l.lock(); evs = r; l.unlock(); g.leave()
        }
        _ = g.wait(timeout: .now() + 150)
        l.lock()
        let mails: String = mailRaw
        // 24/10 : la fiche du matin est écrite sur disque et affichée hors coffre — positions personnelles retirées si le coffre
        // n'est pas ouvert, numéros de compte masqués dans tous les cas (cerveau compris).
        var brvmKeep: [String] = []
        var brvmMine: Bool = false
        let brvmVaultOpen: Bool = VaultSession.shared.isOpen()
        for ln in brvmRaw.components(separatedBy: "\n") {
            let tl: String = ln.trimmingCharacters(in: .whitespaces)
            if tl.hasPrefix("MES VALEURS SUIVIES") { brvmMine = true }
            else if tl.hasPrefix("MARCHÉ") { brvmMine = false }
            if brvmMine && !brvmVaultOpen { continue }
            brvmKeep.append(ln.replacingOccurrences(of: #"compte (\d{3,})(\d{4})"#, with: "compte …$2", options: .regularExpression))
        }
        if !brvmVaultOpen && brvmRaw.contains("MES VALEURS SUIVIES") { brvmKeep.insert("Positions personnelles masquées : coffre verrouillé.", at: 0) }
        let brvm: String = brvmKeep.joined(separator: "\n")
        let events: [[String: Any]] = evs
        l.unlock()

        // Agenda du jour (déterministe)
        var agenda: [String] = []
        let today: [[String: Any]] = events.filter { (e: [String: Any]) -> Bool in
            Calendar.current.isDateInToday(Date(timeIntervalSince1970: (e["ts"] as? Double) ?? 0))
        }
        for e in today.prefix(4) {
            let hm: String = (e["hhmm"] as? String) ?? ""
            let t: String = (e["title"] as? String) ?? ""
            agenda.append(hm + " — " + t)
        }
        if today.count > 4 { agenda.append("(+ " + String(today.count - 4) + " autre(s) événement(s))") }
        if agenda.isEmpty {
            let st: DailyState = DailyState.shared
            st.lock.lock(); let note: String = st.calNote; st.lock.unlock()
            agenda.append(note.isEmpty ? "Aucun événement aujourd'hui." : "Agenda indisponible : " + String(note.prefix(120)))
        }

        // Échéances (engagements détectés, ouverts, en retard ou dans les 3 jours)
        var due: [String] = []
        let co: [String: Any] = DailyState.shared.commitFile.read(default: [String: Any]())
        let open: [[String: Any]] = dailySortCommitments((co["items"] as? [[String: Any]]) ?? []).filter { (c: [String: Any]) -> Bool in
            ((c["status"] as? String) ?? "ouvert") == "ouvert"
        }
        let now: Date = Date()
        for c in open {
            let d: String = (c["echeance"] as? String) ?? ""
            guard let dl: Date = DailyCal.deadline(d) else { continue }
            let days: Double = dl.timeIntervalSince(now) / 86400
            if days > 3 || days < -14 { continue }
            let dir: String = ((c["dir"] as? String) ?? "moi") == "eux" ? "On me doit" : "Je dois"
            let quoi: String = (c["quoi"] as? String) ?? ""
            let qui: String = (c["qui"] as? String) ?? ""
            var line: String = dir + " : " + quoi
            if !qui.isEmpty { line += " — " + qui }
            if days < 0 { line += " · EN RETARD (" + d + ")" } else { line += " · " + d }
            due.append(line)
            if due.count >= 4 { break }
        }
        if due.isEmpty { due.append(open.isEmpty ? "Aucun engagement détecté (lance un scan dans la section Engagements)." : "Aucune échéance dans les 3 prochains jours.") }

        // Dots du jour (déterministe)
        var dotLines: [String] = []
        let names: [String: String] = Dictionary(dots.list().compactMap { (d: [String: Any]) -> (String, String)? in
            guard let id = d["id"] as? String else { return nil }
            let n: String = (d["name"] as? String) ?? id
            return (id, n)
        }, uniquingKeysWith: { (a: String, _: String) -> String in a })
        var lastByDot: [String: [String: Any]] = [:]
        for r in dots.history() {   // du plus récent au plus ancien
            guard let ts = r["ts"] as? String, let d: Date = DailyCal.iso.date(from: ts), Calendar.current.isDateInToday(d) else { continue }
            let id: String = (r["dot"] as? String) ?? "?"
            if lastByDot[id] == nil { lastByDot[id] = r }
        }
        if lastByDot.isEmpty { dotLines.append("Aucun Dot n'est encore passé aujourd'hui.") }
        else {
            var okN: Int = 0
            var bad: [String] = []
            var unread: Int = 0
            for (id, r) in lastByDot {
                if (r["ok"] as? Bool) == true { okN += 1 } else { bad.append(names[id] ?? id) }
                if (r["read"] as? Bool) == false { unread += 1 }
            }
            dotLines.append(String(lastByDot.count) + " Dot(s) passé(s) aujourd'hui : " + String(okN) + " OK, " + String(bad.count) + " en échec.")
            if !bad.isEmpty { dotLines.append("En échec : " + bad.prefix(5).joined(separator: ", ")) }
            if unread > 0 { dotLines.append(String(unread) + " rapport(s) non lu(s) dans Dots.") }
        }

        // Mails urgents + BRVM + version à écouter (cerveau « fast »)
        let mailOK: Bool = !DailyCal.unavailable(mails) || mails.contains(" | ")
        let brvmOK: Bool = !brvm.isEmpty && !brvm.hasPrefix("Cours BRVM indisponibles")
        var mailLines: [String] = []
        var brvmLines: [String] = []
        var listen: String = ""
        var brain: String = "aucun"
        let sys: String = "Tu es Nova. Tu prépares un RÉSUMÉ DU MATIN lisible en 30 secondes, en français. Réponds UNIQUEMENT par un objet JSON strict : "
            + "{\"mails\":[\"2 à 4 lignes : les mails urgents ou importants, expéditeur + objet + pourquoi\"],\"brvm\":[\"2 à 3 lignes factuelles avec chiffres et date de la source\"],"
            + "\"ecouter\":\"texte parlé de 120 mots maximum, phrases courtes, couvrant agenda, mails, échéances, BRVM et Dots\"}. "
            + "N'utilise QUE les données fournies ; source indisponible = une ligne qui le dit. FRAÎCHEUR : pour un fait daté ou un dossier en cours, la source la plus récente fait foi ; toute absence (« aucune donnée », « non vérifié ») nomme la source la plus fraîche consultée et sa date. Aucun conseil d'achat ou de vente."
        var prompt: String = "Nous sommes le " + DailyCal.longDayFmt.string(from: Date()) + "."
        prompt += "\n\n### Mails non lus\n" + DailyCal.clip(mails, 4000)
        prompt += "\n\n### BRVM\n" + DailyCal.clip(brvm, 2500)
        prompt += "\n\n### Agenda du jour\n" + agenda.joined(separator: "\n")
        prompt += "\n\n### Échéances\n" + due.joined(separator: "\n")
        prompt += "\n\n### Dots\n" + dotLines.joined(separator: "\n")
        if let r: (text: String, brain: String) = router.complete(messages: [ChatMsg("user", prompt)], system: sys, mode: "fast", maxTokens: 900),
           let o: [String: Any] = DailyCal.jsonSlice(r.text, open: "{", close: "}") as? [String: Any] {
            mailLines = DailyCal.strings(o["mails"], max: 4)
            brvmLines = DailyCal.strings(o["brvm"], max: 3)
            listen = DailyCal.limitWords((o["ecouter"] as? String) ?? "", 120)
            brain = r.brain
        }
        if mailLines.isEmpty {
            if !mailOK { mailLines.append("Mail indisponible : " + String(mails.prefix(140))) }
            else {
                for line in mails.components(separatedBy: "\n") where line.contains(" | ") {
                    let p: [String] = line.components(separatedBy: " | ")
                    // 24/10 : sans cerveau, on n'affiche ni adresses brutes ni expéditeurs automatiques (no-reply, newsletters).
                    let rawFrom: String = p[0]
                    let lowFrom: String = rawFrom.lowercased()
                    if ["no-reply", "noreply", "donotreply", "newsletter", "notification"].contains(where: { lowFrom.contains($0) }) { continue }
                    var who: String = rawFrom.replacingOccurrences(of: #"<[^>]*>"#, with: "", options: .regularExpression).replacingOccurrences(of: "\"", with: "").trimmingCharacters(in: .whitespaces)
                    if who.isEmpty { who = rawFrom }
                    if p.count >= 2 && DailyCal.looksPromo(p[1]) { continue }
                    if p.count >= 2 { mailLines.append(who + " — " + p[1]) }
                    if mailLines.count >= 4 { break }
                }
                if mailLines.isEmpty { mailLines.append("Aucun mail non lu à regarder (promotions et envois automatiques écartés).") }
            }
        }
        if brvmLines.isEmpty {
            if !brvmOK { brvmLines.append("Cours BRVM indisponibles.") }
            else {
                var inMine: Bool = false
                for line in brvm.components(separatedBy: "\n") {
                    let t: String = line.trimmingCharacters(in: .whitespaces)
                    // 24/10 : les positions personnelles (portefeuilles) ne figurent dans la fiche que coffre ouvert — la fiche est écrite sur disque et affichée hors coffre.
                    if t.hasPrefix("MES VALEURS SUIVIES") { inMine = true; if !VaultSession.shared.isOpen() { continue } }
                    if t.hasPrefix("MARCHÉ") { inMine = false; continue }
                    if inMine && !VaultSession.shared.isOpen() { continue }
                    if t.hasPrefix("{") {
                        // V6 : le JSON du marché devient 2 lignes lisibles (jamais affiché brut).
                        for ml in DailyCal.marketLines(t) where brvmLines.count < 3 { brvmLines.append(ml) }
                        break
                    }
                    let masked: String = t.replacingOccurrences(of: #"compte (\d{3,})(\d{4})"#, with: "compte …$2", options: .regularExpression)
                    if !masked.isEmpty { brvmLines.append(String(masked.prefix(180))) }
                    if brvmLines.count >= 3 { break }
                }
            }
        }
        if listen.isEmpty {
            let endDot: (String) -> String = { (x: String) -> String in
                var t: String = x.trimmingCharacters(in: .whitespaces)
                while t.hasSuffix(".") { t.removeLast() }
                return t + ". "
            }
            var spoken: String = "Bonjour. Agenda : " + endDot(agenda.prefix(2).joined(separator: " ; "))
            spoken += "Mails : " + endDot(mailLines.prefix(2).joined(separator: " ; "))
            spoken += "Échéances : " + endDot(due.prefix(2).joined(separator: " ; "))
            spoken += "Dots : " + (dotLines.first ?? "")
            listen = DailyCal.limitWords(spoken, 120)
        }
        let sections: [[String: Any]] = [
            ["id": "mails", "title": "Mails non lus à regarder", "icon": "✉️", "lines": mailLines, "ok": mailOK],
            ["id": "agenda", "title": "Agenda du jour", "icon": "📅", "lines": agenda, "ok": true],
            ["id": "echeances", "title": "Échéances", "icon": "⏰", "lines": due, "ok": true],
            ["id": "brvm", "title": "BRVM", "icon": "📈", "lines": brvmLines, "ok": brvmOK],
            ["id": "dots", "title": "Dots", "icon": "✦", "lines": dotLines, "ok": true],
        ]
        return ["date": DailyCal.longDayFmt.string(from: Date()), "generated": nowISO(), "sections": sections, "ecouter": listen,
                "brain": brain, "ms": Int(Date().timeIntervalSince(t0) * 1000)]
    }

    // MARK: (C) engagements

    func dailySortCommitments(_ items: [[String: Any]]) -> [[String: Any]] {
        return items.sorted { (a: [String: Any], b: [String: Any]) -> Bool in
            let sa: Int = ((a["status"] as? String) ?? "ouvert") == "ouvert" ? 0 : 1
            let sb: Int = ((b["status"] as? String) ?? "ouvert") == "ouvert" ? 0 : 1
            if sa != sb { return sa < sb }
            let da: String = (a["echeance"] as? String) ?? ""
            let db: String = (b["echeance"] as? String) ?? ""
            let xa: String = da.isEmpty ? "9999" : da
            let xb: String = db.isEmpty ? "9999" : db
            return xa < xb
        }
    }

    /// Analyse mail_week + teams_read → promesses dans les deux sens, dédoublonnées dans commitments.json. Synchrone.
    @discardableResult
    func dailyScanCommitments() -> [String: Any] {
        let st: DailyState = DailyState.shared
        st.lock.lock()
        if st.scanRunning { st.lock.unlock(); return ["status": "en_cours"] }
        st.scanRunning = true
        st.lock.unlock()
        defer { st.lock.lock(); st.scanRunning = false; st.lock.unlock() }
        let why: String = "Surveillance des engagements (lecture seule)"
        let mails: String = tools.run("mail_week", "7", why: why, actor: "Nova")
        let teams: String = tools.run("teams_read", "", why: why, actor: "Nova")
        let name: String = settings.get("name", "Ahadi")
        let todayStr: String = DailyCal.dayFmt.string(from: Date())
        let sys: String = "Tu extrais des ENGAGEMENTS explicites (promesses) de messages professionnels. Réponds UNIQUEMENT par un tableau JSON strict, sans aucun autre texte : "
            + "[{\"qui\":\"personne concernée\",\"quoi\":\"l'engagement, court\",\"echeance\":\"AAAA-MM-JJ ou vide\",\"dir\":\"moi|eux\",\"source\":\"mail|teams : extrait court\"}]. "
            + "dir = \"moi\" quand " + name + " (l'utilisateur, ou un mail ENVOYÉ) a promis quelque chose ; \"eux\" quand quelqu'un a promis quelque chose à " + name + ". "
            + "Convertis les dates relatives (demain, vendredi, fin de semaine) par rapport à aujourd'hui. N'invente rien ; [] s'il n'y a aucun engagement. 25 éléments au plus."
        var prompt: String = "Aujourd'hui : " + todayStr + " (" + DailyCal.longDayFmt.string(from: Date()) + ")."
        prompt += "\n\n=== MAILS (7 jours) ===\n" + DailyCal.clip(mails, 9000)
        prompt += "\n\n=== TEAMS ===\n" + DailyCal.clip(teams, 5000)
        var o: [String: Any] = st.commitFile.read(default: [String: Any]())
        guard let r: (text: String, brain: String) = router.complete(messages: [ChatMsg("user", prompt)], system: sys, mode: "deep", maxTokens: 1800) else {
            st.lock.lock()
            o = st.commitFile.read(default: [String: Any]())
            o["last_note"] = "Scan impossible : aucun cerveau n'a répondu (" + nowISO() + ")."
            st.commitFile.write(o)
            st.lock.unlock()
            return ["ok": false, "error": "aucun cerveau n'a répondu"]
        }
        let arr: [Any] = (DailyCal.jsonSlice(r.text, open: "[", close: "]") as? [Any]) ?? []
        st.lock.lock()
        o = st.commitFile.read(default: [String: Any]())
        var items: [[String: Any]] = (o["items"] as? [[String: Any]]) ?? []
        var index: [String: Int] = [:]
        for (i, it) in items.enumerated() {
            let kd: String = (it["dir"] as? String) ?? ""
            let kq: String = String(DailyCal.simplify((it["quoi"] as? String) ?? "").prefix(60))
            let kw: String = DailyCal.simplify((it["qui"] as? String) ?? "")
            index[kd + "|" + kq + "|" + kw] = i
        }
        var added: Int = 0
        for x in arr.prefix(25) {
            guard let c = x as? [String: Any] else { continue }
            let quoi: String = String(((c["quoi"] as? String) ?? "").trimmingCharacters(in: .whitespacesAndNewlines).prefix(220))
            if quoi.isEmpty { continue }
            let qui: String = String(((c["qui"] as? String) ?? "").prefix(80))
            let dir: String = ((c["dir"] as? String) ?? "moi") == "eux" ? "eux" : "moi"
            var ech: String = (c["echeance"] as? String) ?? ""
            if DailyCal.deadline(ech) == nil { ech = "" }
            let src: String = String(((c["source"] as? String) ?? "").prefix(160))
            let kq: String = String(DailyCal.simplify(quoi).prefix(60))
            let kw: String = DailyCal.simplify(qui)
            let k: String = dir + "|" + kq + "|" + kw
            if let i: Int = index[k] {
                if ((items[i]["echeance"] as? String) ?? "").isEmpty && !ech.isEmpty { items[i]["echeance"] = ech; items[i]["alerted"] = false }
                items[i]["seen"] = nowISO()
                continue
            }
            let item: [String: Any] = ["id": String(UUID().uuidString.prefix(8)).lowercased(), "qui": qui, "quoi": quoi, "echeance": ech, "dir": dir,
                                       "source": src, "status": "ouvert", "created": nowISO(), "seen": nowISO(), "alerted": false]
            items.append(item)
            index[k] = items.count - 1
            added += 1
        }
        if items.count > 300 {   // on garde les ouverts, puis les plus récents
            let openItems: [[String: Any]] = items.filter { ((($0["status"] as? String) ?? "ouvert") == "ouvert") }
            let closed: [[String: Any]] = items.filter { ((($0["status"] as? String) ?? "ouvert") != "ouvert") }
            items = Array((openItems + closed.suffix(Swift.max(0, 300 - openItems.count))).prefix(300))
        }
        let partial: String = DailyCal.unavailable(mails) ? " Mail indisponible pendant ce scan." : ""
        o["items"] = items
        o["last_scan"] = nowISO()
        o["last_epoch"] = Date().timeIntervalSince1970
        o["last_note"] = String(added) + " nouvel(s) engagement(s) ; " + String(items.count) + " au total (mails des 7 derniers jours : objets et aperçus, Teams visible)." + partial
        st.commitFile.write(o)
        st.lock.unlock()
        return ["ok": true, "added": added, "total": items.count, "brain": r.brain]
    }

    /// Alerte 24 h avant l'échéance (une seule fois par engagement).
    func dailyCommitmentAlerts() {
        let st: DailyState = DailyState.shared
        var alerts: [[String: Any]] = []
        st.lock.lock()
        var o: [String: Any] = st.commitFile.read(default: [String: Any]())
        var items: [[String: Any]] = (o["items"] as? [[String: Any]]) ?? []
        let now: Date = Date()
        for i in items.indices {
            if ((items[i]["status"] as? String) ?? "ouvert") != "ouvert" { continue }
            if (items[i]["alerted"] as? Bool) == true { continue }
            guard let dl: Date = DailyCal.deadline((items[i]["echeance"] as? String) ?? "") else { continue }
            let left: Double = dl.timeIntervalSince(now)
            if left > 24 * 3600 || left < -3 * 86400 { continue }
            items[i]["alerted"] = true
            var a: [String: Any] = items[i]
            a["retard"] = left < 0
            a["heures"] = Int(left / 3600)
            alerts.append(a)
        }
        if !alerts.isEmpty { o["items"] = items; st.commitFile.write(o) }
        st.lock.unlock()
        for a in alerts { bus.publish("commitment", a) }
    }
}

// MARK: - V5-O (25/10/2026) — Innovations 20 & 26 « RITUELS » : les rituels réels, branchés

/// Inventaire (vérifié dans le code le 25/10) — chaque rituel listé existe et tourne vraiment :
/// - Briefs planifiés (Briefs.tick, réglage « briefs ») : Brief du matin 07:30, Point de midi 12:30 (désactivé par défaut),
///   Fermeture du soir 18:00 — qui reçoit désormais « Ce qu'on laisse » (document Âme « laisser », Rituels.laisserSource).
/// - Brief pré-réunion (dailyMeetingTick) : T-30 min par défaut, réglable 30 / 60 / 120 (meeting_brief_lead_min).
/// - Rituels-Éclats du pack d'âme (ids imp-rituel-* / imp-ame-* du parc : sparring anglais 07:30, veille BRVM 16:30,
///   dictée du soir 21:30, hebdomadaires) : ils tournent par le DotScheduler ; leur interrupteur est leur pause réelle.
///   Absents du parc → listés « non disponible », jamais simulés.
/// - Rêve nocturne 23:30 (Ame.ameStart) : listé avec son dernier passage réel ; son interrupteur n'est PAS branché ici
///   (boucle dans Ame.swift, hors périmètre de ce lot) — l'écran le dit.
/// Interrupteurs : rituels_on (global, défaut true) + ritual_<id> (défaut true). Garde unique : Rituels.allows.
enum Rituels {
    static let lock: NSLock = NSLock()
    static let etat: JSONFile = JSONFile("rituels_etat.json")
    static let leads: [Int] = [30, 60, 120]
    /// Rituels-Éclats quotidiens attendus par le pack d'âme (§5) : clé cherchée dans l'id, nom, horaire du pack.
    static let expectedEclats: [(key: String, nom: String, heure: String)] = [("sparring", "Sparring anglais", "07:30"), ("brvm", "Veille BRVM", "16:30"), ("dictee", "Dictée du soir", "21:30")]

    static func allows(_ id: String, settings st: Settings) -> Bool {
        if !st.get("rituels_on", true) { return false }
        return st.get("ritual_" + id, true)
    }
    static func mark(_ id: String) {
        lock.lock()
        var e: [String: Any] = etat.read(default: [String: Any]())
        e[id] = nowISO()
        etat.write(e)
        lock.unlock()
    }
    static func lastRun(_ id: String) -> String? {
        lock.lock()
        let e: [String: Any] = etat.read(default: [String: Any]())
        lock.unlock()
        return e[id] as? String
    }
    static func meetingLead(_ st: Settings) -> Int {
        let raw: Any? = st.all()["meeting_brief_lead_min"]
        var n: Int = 30
        if let i: Int = raw as? Int { n = i }
        else if let d: Double = raw as? Double { n = Int(d) }
        else if let s: String = raw as? String, let i: Int = Int(s) { n = i }
        return leads.contains(n) ? n : 30
    }
    static func isRitualDot(_ id: String) -> Bool { return id.hasPrefix("imp-rituel-") || id.hasPrefix("imp-ame-") }

    /// « Ce qu'on laisse » (document Âme « laisser », ame_laisser.json) : ce qu'Ahadi a lui-même choisi de lâcher.
    /// Lu tel quel (texte + date) ; entrée désactivée (on == false) ignorée ; formes tolérées : objet {text, ts} ou texte nu.
    static func laisserSource() -> SourceData {
        let name: String = "Ce qu'on laisse (choisi par Ahadi, document Âme)"
        let raw: [Any] = JSONFile("ame_laisser.json").read(default: [Any]())
        var lines: [String] = []
        var newest: String = ""
        for x in raw.suffix(12) {
            if let t: String = x as? String {
                let tt: String = t.trimmingCharacters(in: .whitespacesAndNewlines)
                if !tt.isEmpty { lines.append("- " + String(tt.prefix(200))) }
                continue
            }
            guard let d: [String: Any] = x as? [String: Any] else { continue }
            if (d["on"] as? Bool) == false { continue }
            let t: String = ((d["text"] as? String) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            if t.isEmpty { continue }
            let ts: String = (d["ts"] as? String) ?? ""
            if ts > newest { newest = ts }
            lines.append("- " + String(t.prefix(200)) + (ts.isEmpty ? "" : " (" + String(ts.prefix(10)) + ")"))
        }
        if lines.isEmpty { return SourceData(name: name, ok: true, text: "Rien n'est inscrit dans « Ce qu'on laisse » (écran Âme).") }
        var src: SourceData = SourceData(name: name, ok: true, text: lines.suffix(6).joined(separator: "\n"))
        if !newest.isEmpty { src.asOf = "dernière entrée : " + String(newest.prefix(10)) }
        return src
    }
}

extension NovaApp {
    /// GET /api/rituels → [{id, nom, heure, actif, dernier_passage, type, disponible, interrupteur, note?, lead?, choix?}]
    func rituelsList() -> [[String: Any]] {
        let globalOn: Bool = settings.get("rituels_on", true)
        let flag: (String) -> Bool = { [settings] (id: String) -> Bool in settings.get("ritual_" + id, true) }
        var out: [[String: Any]] = []
        let past: [[String: Any]] = briefs.list()
        for b in settings.get("briefs", [[String: Any]]()) {
            guard let id: String = b["id"] as? String else { continue }
            let kind: String = (b["kind"] as? String) ?? id
            let enabled: Bool = (b["enabled"] as? Bool) == true
            let lastTs: String? = past.first(where: { (x: [String: Any]) -> Bool in (x["kind"] as? String) == kind })?["ts"] as? String
            let last: Any = lastTs.map { (s: String) -> Any in s } ?? NSNull()
            var row: [String: Any] = ["id": id, "nom": (b["label"] as? String) ?? id, "heure": (b["time"] as? String) ?? "", "type": "brief",
                                      "actif": globalOn && flag(id) && enabled, "dernier_passage": last, "disponible": true, "interrupteur": true]
            if kind == "soir" { row["note"] = "Fait · reste ouvert · demain · Ce qu'on laisse" }
            out.append(row)
        }
        let lead: Int = Rituels.meetingLead(settings)
        let reu: [String: Any] = ["id": "reunion", "nom": "Brief pré-réunion", "heure": "T-" + String(lead) + " min", "type": "reunion",
                                  "actif": globalOn && flag("reunion") && settings.get("meeting_auto_prep", true),
                                  "dernier_passage": (Rituels.lastRun("reunion") as Any?) ?? NSNull(), "disponible": true, "interrupteur": true,
                                  "lead": lead, "choix": Rituels.leads]
        out.append(reu)
        var found: Set<String> = []
        for d in dots.list() {
            guard let id: String = d["id"] as? String else { continue }
            // FLOTTE V1 (25/10) : la veille BRVM de clôture est faite par l'Éclat « Portefeuille BRVM » (lun-ven 16:30) ;
            // le rituel « imp-rituel-brvm », doublon, est retiré — un Éclat retiré n'est plus listé parmi les rituels.
            let isBourse: Bool = id == "portefeuille"
            if !Rituels.isRitualDot(id) && !isBourse { continue }
            if (d["retired"] as? Bool) == true && (d["paused"] as? Bool) == true { continue }
            for k in Rituels.expectedEclats where id.contains(k.key) { found.insert(k.key) }
            if isBourse { found.insert("brvm") }
            let paused: Bool = (d["paused"] as? Bool) == true
            let last: Any = (dots.history(id).first?["ts"] as? String).map { (s: String) -> Any in s } ?? NSNull()
            var row: [String: Any] = ["id": "eclat:" + id, "nom": (d["name"] as? String) ?? id, "heure": (d["schedule"] as? String) ?? "", "type": "eclat",
                                      "actif": globalOn && !paused, "dernier_passage": last, "disponible": true, "interrupteur": true]
            if paused && (d["paused_by"] as? String) == "rituels" { row["note"] = "en pause : rituels coupés" }
            else if paused { row["note"] = "Éclat en pause" }
            if isBourse {
                row["actif"] = !paused
                row["interrupteur"] = false
                row["note"] = "Éclat de fond — réglable dans Éclats"
            }
            out.append(row)
        }
        for k in Rituels.expectedEclats where !found.contains(k.key) {
            let row: [String: Any] = ["id": "eclat:" + k.key, "nom": k.nom, "heure": k.heure, "type": "eclat", "actif": false, "dernier_passage": NSNull(),
                                      "disponible": false, "interrupteur": false, "note": "aucun Éclat de ce rituel dans le parc"]
            out.append(row)
        }
        let reves: [[String: Any]] = JSONFile("ame_reves.json").read(default: [[String: Any]]())
        let lastDream: Any = (reves.last?["ts"] as? String).map { (s: String) -> Any in s } ?? NSNull()
        let reve: [String: Any] = ["id": "reve", "nom": "Rêve nocturne (distillation de la journée)", "heure": "23:30", "type": "ame", "actif": true,
                                   "dernier_passage": lastDream, "disponible": true, "interrupteur": false,
                                   "note": "tourne chaque nuit ; interrupteur pas encore branché (Âme) · dernier passage = dernières propositions retenues"]
        out.append(reve)
        return out
    }

    /// Pause / reprise réelle d'un rituel-Éclat (même champ que POST /api/dots/control). by = "rituels" : posée par l'interrupteur global.
    func rituelsSetDot(_ d: [String: Any], paused: Bool, by: String?) {
        var dd: [String: Any] = d
        dd.removeValue(forKey: "persona")
        dd["paused"] = paused
        if let b: String = by { dd["paused_by"] = b } else { dd.removeValue(forKey: "paused_by") }
        dots.save(dd)
    }

    func rituelsRoutes() {
        let s = server
        s.on("GET", "/api/rituels") { [self] _, res in res.json(rituelsList()) }
        // POST /api/rituels/global {on} : interrupteur global — briefs, réunion (garde Rituels.allows) et rituels-Éclats (pause réelle).
        s.on("POST", "/api/rituels/global") { [self] req, res in
            guard let on: Bool = req.json["on"] as? Bool else { let e: [String: Any] = ["ok": false, "error": "on (booléen) requis"]; res.json(e, status: 400); return }
            settings.set(["rituels_on": on])
            for d in dots.list() {
                guard let id: String = d["id"] as? String, Rituels.isRitualDot(id) else { continue }
                let paused: Bool = (d["paused"] as? Bool) == true
                if !on && !paused { rituelsSetDot(d, paused: true, by: "rituels") }
                if on && paused && (d["paused_by"] as? String) == "rituels" && settings.get("ritual_eclat:" + id, true) { rituelsSetDot(d, paused: false, by: nil) }
            }
            _ = BlackBox.record(["tool": "rituels", "actor": "Ahadi", "why": "Rituels " + (on ? "réactivés" : "coupés") + " (interrupteur global, Réglages)", "ok": true, "effect": "config"])
            let out: [String: Any] = ["ok": true, "on": on, "items": rituelsList()]
            res.json(out)
        }
        // POST /api/rituels/toggle {id, on} : interrupteur individuel (ritual_<id>) + le champ réel du rituel.
        s.on("POST", "/api/rituels/toggle") { [self] req, res in
            let j: [String: Any] = req.json
            let id: String = (j["id"] as? String) ?? ""
            guard !id.isEmpty, let on: Bool = j["on"] as? Bool else { let e: [String: Any] = ["ok": false, "error": "id et on requis"]; res.json(e, status: 400); return }
            let globalOn: Bool = settings.get("rituels_on", true)
            var done: Bool = false
            if id.hasPrefix("eclat:") {
                let did: String = String(id.dropFirst(6))
                if let d: [String: Any] = dots.list().first(where: { (x: [String: Any]) -> Bool in (x["id"] as? String) == did }), Rituels.isRitualDot(did) {
                    settings.set(["ritual_" + id: on])
                    if !on { rituelsSetDot(d, paused: true, by: nil) }
                    else if globalOn { rituelsSetDot(d, paused: false, by: nil) }
                    else { rituelsSetDot(d, paused: true, by: "rituels") }
                    done = true
                }
            } else if id == "reunion" {
                settings.set(["ritual_reunion": on, "meeting_auto_prep": on])
                done = true
            } else {
                var bl: [[String: Any]] = settings.get("briefs", [[String: Any]]())
                for i in bl.indices where (bl[i]["id"] as? String) == id { bl[i]["enabled"] = on; done = true }
                if done { settings.set(["briefs": bl, "ritual_" + id: on]) }
            }
            if !done { let e: [String: Any] = ["ok": false, "error": "rituel inconnu ou sans interrupteur : " + id]; res.json(e, status: 404); return }
            _ = BlackBox.record(["tool": "rituels", "actor": "Ahadi", "why": "Rituel « " + id + " » " + (on ? "activé" : "coupé") + " (Réglages)", "ok": true, "effect": "config"])
            let out: [String: Any] = ["ok": true, "id": id, "on": on, "items": rituelsList()]
            res.json(out)
        }
        // POST /api/rituels/lead {min} : avance du brief pré-réunion (30, 60 ou 120 min).
        s.on("POST", "/api/rituels/lead") { [self] req, res in
            let n: Int = (req.json["min"] as? Int) ?? 0
            guard Rituels.leads.contains(n) else { let e: [String: Any] = ["ok": false, "error": "min ∈ {30, 60, 120}"]; res.json(e, status: 400); return }
            settings.set(["meeting_brief_lead_min": n])
            let out: [String: Any] = ["ok": true, "lead": n, "items": rituelsList()]
            res.json(out)
        }
    }
}
