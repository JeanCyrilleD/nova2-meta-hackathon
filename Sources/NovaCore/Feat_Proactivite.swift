import Foundation

// 26/10 (Ahadi) — INITIATIVES : proactivité diverse à intervalles IRRÉGULIERS, dans le style du Fil direct.
// Complète les rituels Muse à heures fixes (Feat_MuseRituels) et les suggestions de contenus externes
// (Feat_Suggestions) par la vie interne d'Ahadi : mémoire qui resurgit, engagement en dérive, attente
// sans réponse, échéance proche, signal de veille non lu. Règles fermées, aucun cerveau, aucun cloud :
// Nova constate un fait local, le formule, propose — Ahadi décide. Rien n'est jamais envoyé.
// Garde-fous : interrupteur maître + un par type (défaut : actif), heures calmes, plafond de 3 par jour,
// anti-doublon durable (proactivite.json), prochain passage tiré dans un intervalle aléatoire propre
// à chaque type (jamais d'heure fixe).

public enum Proactivite {
    static let file: JSONFile = JSONFile("proactivite.json")
    static let lock: NSLock = NSLock()
    nonisolated(unsafe) static var started: Bool = false

    public static let types: [String] = ["memoire", "engagement", "attente", "echeance", "veille", "anticipation"]
    // 27/10 (Ahadi : « je ne vois pas la proactivité ») : le plafond de 3 était épuisé dès 07h08.
    // Relevé à 6 par jour, avec au plus 2 du même type pour garder la variété.
    public static let dailyCap: Int = 6
    public static let typeCap: Int = 2

    /// Intervalles (minutes) entre deux passages d'un type : [min, max] — le tirage irrégulier est la règle.
    public static let ranges: [String: (Int, Int)] = [
        "memoire": (240, 600), "engagement": (300, 720), "attente": (360, 900),
        "echeance": (120, 300), "veille": (300, 780), "anticipation": (150, 420),
    ]

    /// Intervalle déterministe à partir d'un tirage `roll` dans [0, 1] (testable sans hasard).
    public static func intervalMinutes(_ type: String, roll: Double) -> Int {
        let r: (Int, Int) = ranges[type] ?? (240, 480)
        let clamped: Double = min(1, max(0, roll))
        return r.0 + Int(Double(r.1 - r.0) * clamped)
    }

    public static func canFire(countToday: Int, quiet: Bool, master: Bool) -> Bool {
        return master && !quiet && countToday < dailyCap
    }

    static func parseDate(_ s: String) -> Date? {
        if s.isEmpty { return nil }
        let iso: ISO8601DateFormatter = ISO8601DateFormatter()
        if let d: Date = iso.date(from: s) { return d }
        return iso.date(from: String(s.prefix(19)) + "Z")
    }

    static func dayKey(_ d: Date) -> String {
        let f: DateFormatter = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd"
        return f.string(from: d)
    }

    // MARK: sélections pures (fixtures testables)

    /// Rappel mémoire : fait de plus de 45 jours, non sensible, pas déjà ressorti depuis 60 jours.
    /// Le plus ancien éligible d'abord (la mémoire profonde avant la récente).
    public static func pickMemory(facts: [[String: Any]], now: Date, shown: [String: String]) -> [String: Any]? {
        var best: [String: Any]? = nil
        var bestDate: Date = .distantFuture
        for f in facts {
            guard let id: String = f["id"] as? String, !id.isEmpty,
                  let text: String = f["text"] as? String, text.count >= 20,
                  let ts: String = f["ts"] as? String, let d: Date = parseDate(ts) else { continue }
            if Memory.isSensitive(text) { continue }
            if now.timeIntervalSince(d) < 45 * 86400 { continue }
            if let s: String = shown["memoire|" + id], let sd: Date = parseDate(s), now.timeIntervalSince(sd) < 60 * 86400 { continue }
            if d < bestDate { bestDate = d; best = f }
        }
        return best
    }

    /// Engagement en dérive : « moi » ouvert, sans échéance, créé/vu il y a plus de 10 jours.
    public static func pickDrift(items: [[String: Any]], now: Date, shown: [String: String]) -> [String: Any]? {
        var best: [String: Any]? = nil
        var bestDate: Date = .distantFuture
        for it in items {
            guard (it["status"] as? String) == "ouvert", (it["dir"] as? String) == "moi",
                  ((it["echeance"] as? String) ?? "").isEmpty,
                  let id: String = it["id"] as? String, !id.isEmpty else { continue }
            let ref: String = ((it["seen"] as? String) ?? "").isEmpty ? ((it["created"] as? String) ?? "") : ((it["seen"] as? String) ?? "")
            guard let d: Date = parseDate(ref), now.timeIntervalSince(d) > 10 * 86400 else { continue }
            if let s: String = shown["engagement|" + id], let sd: Date = parseDate(s), now.timeIntervalSince(sd) < 21 * 86400 { continue }
            if d < bestDate { bestDate = d; best = it }
        }
        return best
    }

    /// Attente sans réponse : « eux » ouvert depuis plus de 5 jours.
    public static func pickWaiting(items: [[String: Any]], now: Date, shown: [String: String]) -> [String: Any]? {
        var best: [String: Any]? = nil
        var bestDate: Date = .distantFuture
        for it in items {
            guard (it["status"] as? String) == "ouvert", (it["dir"] as? String) == "eux",
                  let id: String = it["id"] as? String, !id.isEmpty,
                  let d: Date = parseDate((it["created"] as? String) ?? ""), now.timeIntervalSince(d) > 5 * 86400 else { continue }
            if let s: String = shown["attente|" + id], let sd: Date = parseDate(s), now.timeIntervalSince(sd) < 21 * 86400 { continue }
            if d < bestDate { bestDate = d; best = it }
        }
        return best
    }

    /// Échéance : ouverte, datée, en retard ou à moins de 48 h. La plus urgente d'abord.
    public static func pickDue(items: [[String: Any]], now: Date, shown: [String: String]) -> [String: Any]? {
        let df: DateFormatter = DateFormatter()
        df.locale = Locale(identifier: "en_US_POSIX")
        df.dateFormat = "yyyy-MM-dd"
        var best: [String: Any]? = nil
        var bestDate: Date = .distantFuture
        for it in items {
            guard (it["status"] as? String) == "ouvert",
                  let ech: String = it["echeance"] as? String, ech.count == 10,
                  let id: String = it["id"] as? String, !id.isEmpty,
                  let d: Date = df.date(from: ech) else { continue }
            if d.timeIntervalSince(now) > 48 * 3600 { continue }
            if let s: String = shown["echeance|" + id], let sd: Date = parseDate(s), now.timeIntervalSince(sd) < 3 * 86400 { continue }
            if d < bestDate { bestDate = d; best = it }
        }
        return best
    }

    /// Veille : unité non lue de plus de 12 h, la plus récente de celles-là (encore fraîche, déjà oubliée).
    public static func pickVeille(units: [[String: Any]], now: Date, shown: [String: String]) -> [String: Any]? {
        var best: [String: Any]? = nil
        var bestDate: Date = .distantPast
        for u in units {
            guard (u["read"] as? Bool) != true,
                  let id: String = u["id"] as? String, !id.isEmpty,
                  let title: String = u["title"] as? String, !title.isEmpty,
                  let d: Date = parseDate((u["ts"] as? String) ?? "") else { continue }
            let age: TimeInterval = now.timeIntervalSince(d)
            if age < 12 * 3600 || age > 10 * 86400 { continue }
            if let s: String = shown["veille|" + id], let sd: Date = parseDate(s), now.timeIntervalSince(sd) < 30 * 86400 { continue }
            if d > bestDate { bestDate = d; best = u }
        }
        return best
    }

    // MARK: état durable

    static func state() -> [String: Any] { lock.lock(); defer { lock.unlock() }; return file.read(default: [String: Any]()) }

    static func shownMap() -> [String: String] { (state()["shown"] as? [String: String]) ?? [:] }

    static func countToday(_ now: Date) -> Int {
        let o: [String: Any] = state()
        if (o["day"] as? String) != dayKey(now) { return 0 }
        return (o["count"] as? Int) ?? 0
    }

    static func countToday(_ type: String, _ now: Date) -> Int {
        let o: [String: Any] = state()
        if (o["day"] as? String) != dayKey(now) { return 0 }
        let counts: [String: Any] = (o["type_counts"] as? [String: Any]) ?? [:]
        if let n = counts[type] as? Int { return n }
        return 0
    }

    static func nextDue(_ type: String) -> Date {
        let n: [String: Any] = (state()["next"] as? [String: Any]) ?? [:]
        if let e = n[type] as? Double { return Date(timeIntervalSince1970: e) }
        if let e = n[type] as? Int { return Date(timeIntervalSince1970: Double(e)) }
        return .distantPast
    }

    static func recordFired(type: String, key: String, now: Date) {
        lock.lock(); defer { lock.unlock() }
        var o: [String: Any] = file.read(default: [String: Any]())
        var shown: [String: String] = (o["shown"] as? [String: String]) ?? [:]
        shown[key] = ISO8601DateFormatter().string(from: now)
        if shown.count > 300 {
            let keep: [String] = Array(shown.keys.sorted { (a: String, b: String) -> Bool in (shown[a] ?? "") < (shown[b] ?? "") }.suffix(200))
            var t: [String: String] = [:]
            for k in keep { t[k] = shown[k] }
            shown = t
        }
        o["shown"] = shown
        var next: [String: Any] = (o["next"] as? [String: Any]) ?? [:]
        let mins: Int = intervalMinutes(type, roll: Double.random(in: 0...1))
        next[type] = now.addingTimeInterval(Double(mins) * 60).timeIntervalSince1970
        o["next"] = next
        if (o["day"] as? String) == dayKey(now) {
            o["count"] = ((o["count"] as? Int) ?? 0) + 1
            var counts: [String: Any] = (o["type_counts"] as? [String: Any]) ?? [:]
            counts[type] = ((counts[type] as? Int) ?? 0) + 1
            o["type_counts"] = counts
        } else {
            o["day"] = dayKey(now); o["count"] = 1
            o["type_counts"] = [type: 1]
        }
        o["last"] = ["type": type, "ts": ISO8601DateFormatter().string(from: now), "key": key]
        file.write(o)
    }

    static func reschedule(type: String, now: Date) {
        lock.lock(); defer { lock.unlock() }
        var o: [String: Any] = file.read(default: [String: Any]())
        var next: [String: Any] = (o["next"] as? [String: Any]) ?? [:]
        // Rien à signaler : on retente dans 45 à 120 min (toujours irrégulier, jamais de sondage serré).
        next[type] = now.addingTimeInterval(Double.random(in: 45...120) * 60).timeIntervalSince1970
        o["next"] = next
        file.write(o)
    }
}

extension NovaApp {
    func proactiviteStart() {
        if Proactivite.started { return }
        Proactivite.started = true
        proactiviteRoutes()
        Thread.detachNewThread { [weak self] in
            Thread.sleep(forTimeInterval: 240)
            while true {
                if let s = self { s.proactiviteTick() } else { return }
                Thread.sleep(forTimeInterval: 300)
            }
        }
    }

    func proactiviteTick() {
        let now: Date = Date()
        guard settings.get("proactivite_on", true) else { return }
        guard Proactivite.canFire(countToday: Proactivite.countToday(now), quiet: briefs.inQuietHours(now), master: true) else { return }
        let shown: [String: String] = Proactivite.shownMap()
        for type in Proactivite.types {
            if !settings.get("proactivite_" + type, true) { continue }
            if Proactivite.countToday(type, now) >= Proactivite.typeCap { continue }
            if now < Proactivite.nextDue(type) { continue }
            if proactiviteGenerate(type: type, now: now, shown: shown) {
                return   // une seule initiative par passage : le Direct reste lisible
            }
            Proactivite.reschedule(type: type, now: now)
        }
    }

    /// Génère une initiative d'un type (données locales réelles). true si une carte est partie au Direct.
    @discardableResult func proactiviteGenerate(type: String, now: Date, shown: [String: String]) -> Bool {
        let commits: [[String: Any]] = (JSONFile("commitments.json").read(default: [String: Any]())["items"] as? [[String: Any]]) ?? []
        switch type {
        case "anticipation":
            // 27/10 : préparations en arrière-plan soumises à l'appréciation (Feat_Preparations.swift).
            return anticipationGenerate(now: now)
        case "memoire":
            guard let f: [String: Any] = Proactivite.pickMemory(facts: tools.memory.list(), now: now, shown: shown),
                  let text: String = f["text"] as? String, let ts: String = f["ts"] as? String,
                  let d: Date = Proactivite.parseDate(ts) else { return false }
            let days: Int = Int(now.timeIntervalSince(d) / 86400)
            ProactiveFeed.append(kind: "initiative", box: "memoire", title: "Souvenir qui resurgit",
                text: "🧠 Il y a " + String(days) + " jours, tu avais noté :\n« " + String(text.prefix(500)) + " »\nProposition : je peux retrouver le contexte complet et te dire ce qui a changé depuis — dis « oui » et je m'y mets.",
                extra: ["initiative": "memoire", "fact_id": (f["id"] as? String) ?? ""])
            Proactivite.recordFired(type: type, key: "memoire|" + ((f["id"] as? String) ?? ""), now: now)
            return true
        case "engagement":
            guard let it: [String: Any] = Proactivite.pickDrift(items: commits, now: now, shown: shown),
                  let quoi: String = it["quoi"] as? String else { return false }
            let ref: String = ((it["seen"] as? String) ?? "").isEmpty ? ((it["created"] as? String) ?? "") : ((it["seen"] as? String) ?? "")
            let days: Int = Proactivite.parseDate(ref).map { Int(now.timeIntervalSince($0) / 86400) } ?? 0
            ProactiveFeed.append(kind: "initiative", box: "engagements", title: "Engagement en dérive",
                text: "📌 « " + String(quoi.prefix(220)) + " » — sans mouvement depuis " + String(days) + " jours.\nProposition : je prépare le point d'avancement ou le brouillon de relance, tu valides avant tout envoi.",
                extra: ["initiative": "engagement", "commitment_id": (it["id"] as? String) ?? ""])
            Proactivite.recordFired(type: type, key: "engagement|" + ((it["id"] as? String) ?? ""), now: now)
            return true
        case "attente":
            guard let it: [String: Any] = Proactivite.pickWaiting(items: commits, now: now, shown: shown),
                  let quoi: String = it["quoi"] as? String else { return false }
            let qui: String = ((it["qui"] as? String) ?? "").isEmpty ? "ton interlocuteur" : ((it["qui"] as? String) ?? "")
            let days: Int = Proactivite.parseDate((it["created"] as? String) ?? "").map { Int(now.timeIntervalSince($0) / 86400) } ?? 0
            ProactiveFeed.append(kind: "initiative", box: "attentes", title: "Attente sans réponse",
                text: "⏳ Tu attends depuis " + String(days) + " jours : « " + String(quoi.prefix(220)) + " » (" + qui + ").\nProposition : je rédige une relance courte et polie en brouillon — rien ne part sans ton GO.",
                extra: ["initiative": "attente", "commitment_id": (it["id"] as? String) ?? ""])
            Proactivite.recordFired(type: type, key: "attente|" + ((it["id"] as? String) ?? ""), now: now)
            return true
        case "echeance":
            guard let it: [String: Any] = Proactivite.pickDue(items: commits, now: now, shown: shown),
                  let quoi: String = it["quoi"] as? String, let ech: String = it["echeance"] as? String else { return false }
            let df: DateFormatter = DateFormatter()
            df.locale = Locale(identifier: "en_US_POSIX")
            df.dateFormat = "yyyy-MM-dd"
            let overdue: Bool = (df.date(from: ech) ?? now) < now
            ProactiveFeed.append(kind: "initiative", box: "echeances", title: overdue ? "Échéance dépassée" : "Échéance proche",
                text: (overdue ? "🔴 Échéance dépassée (" : "🟠 Échéance le ") + ech + (overdue ? ")" : "") + " : « " + String(quoi.prefix(220)) + " ».\nProposition : je rassemble ce qu'il faut pour clore ce point et je te soumets le pas suivant.",
                urgent: overdue, extra: ["initiative": "echeance", "commitment_id": (it["id"] as? String) ?? ""])
            Proactivite.recordFired(type: type, key: "echeance|" + ((it["id"] as? String) ?? ""), now: now)
            return true
        case "veille":
            guard let u: [String: Any] = Proactivite.pickVeille(units: FeedUnits.list(), now: now, shown: shown),
                  let title: String = u["title"] as? String else { return false }
            let stand: String = ((u["standfirst"] as? String) ?? "")
            ProactiveFeed.append(kind: "initiative", box: "veille", title: "Signal de veille à lire",
                text: "🌍 Publié dans ta veille et pas encore lu :\n« " + String(title.prefix(220)) + " »" + (stand.isEmpty ? "" : "\n" + String(stand.prefix(280))) + "\nProposition : je te le résume en 3 points reliés à tes dossiers en cours.",
                extra: ["initiative": "veille", "unit_id": (u["id"] as? String) ?? ""])
            Proactivite.recordFired(type: type, key: "veille|" + ((u["id"] as? String) ?? ""), now: now)
            return true
        default:
            return false
        }
    }

    func proactiviteRoutes() {
        let s = server
        s.on("GET", "/api/proactivite") { [self] _, res in
            let now: Date = Date()
            let o: [String: Any] = Proactivite.state()
            var next: [String: Any] = [:]
            for t in Proactivite.types {
                let d: Date = Proactivite.nextDue(t)
                next[t] = d == .distantPast ? "à venir" : ISO8601DateFormatter().string(from: d)
            }
            res.json(["on": settings.get("proactivite_on", true), "types": Proactivite.types,
                      "actifs": Dictionary(uniqueKeysWithValues: Proactivite.types.map { (t: String) -> (String, Bool) in (t, settings.get("proactivite_" + t, true)) }),
                      "aujourdhui": Proactivite.countToday(now), "plafond": Proactivite.dailyCap,
                      "prochains": next, "dernier": o["last"] ?? NSNull()])
        }
        // Déclenchement manuel (tests, démonstration) : même garde-fous de contenu, sans attendre le tirage.
        s.on("POST", "/api/proactivite/declencher") { [self] req, res in
            let type: String = (req.json["type"] as? String) ?? ""
            guard Proactivite.types.contains(type) else { res.json(["error": "type : " + Proactivite.types.joined(separator: " | ")], status: 400); return }
            guard settings.get("proactivite_on", true), settings.get("proactivite_" + type, true) else { res.json(["status": "desactive", "type": type]); return }
            let fired: Bool = proactiviteGenerate(type: type, now: Date(), shown: Proactivite.shownMap())
            res.json(["status": fired ? "initiative_envoyee_au_direct" : "rien_a_signaler", "type": type])
        }
    }
}
