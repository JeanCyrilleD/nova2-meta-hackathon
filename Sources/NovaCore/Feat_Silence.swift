import Foundation

// V5-O (25/10/2026) — Innovation 15 « SILENCE » : plafond RÉEL des interruptions proactives.
//
// Branché dans le crochet unique NovaNotifier (send → livraison immédiate, flush → fin de rafale) :
// au moment où une notification native allait s'afficher, SilenceGate.admit décide.
// - silence_mode (défaut true) : le plafond s'applique ; false = comportement d'avant, rien n'est compté.
// - silence_cap (défaut 3, borné 1–10) : notifications natives NON urgentes et PROACTIVES affichées par jour
//   (jour GMT+0, remis à zéro à minuit GMT+0 — Ouagadougou). Au-delà : AUCUNE notification native ; l'élément
//   est consigné dans silence_journal.jsonl (titre, texte, cible) et le compteur « retenues » augmente.
//   Rien n'est perdu : les producteurs écrivent déjà le Fil direct / le journal proactif AVANT d'appeler send.
// - Une alerte URGENTE passe toujours (règle inchangée) ; la source « essai » n'est jamais comptée.
// - ARBITRAGE MAIL (24/10) : Ahadi a demandé explicitement d'être notifié de CHAQUE nouveau mail. Les sources
//   mail:<boîte> (Outlook web, Gmail, Teams, WhatsApp : WebMail.onAlert) et badge:Outlook (pastille Outlook
//   natif = nouveau mail) ne sont donc PAS plafonnées par défaut. silence_mail (défaut false) les y inclut.
//   Le résumé horaire des groupes WhatsApp (mail:wa-groups) n'est pas un mail : il est plafonné.
// - Hors plafond (alertes système, pas des interruptions « de confort ») : credits*, fundings urgents (urgent),
//   toute source inconnue. Les heures calmes existantes (quiet_from / quiet_to, mode concentration) restent la
//   seule règle horaire : elles ne sont pas dupliquées ici, seulement affichées par la route.

enum SilenceGate {
    static let file: JSONFile = JSONFile("silence_compteur.json")
    static let journal: Journal = Journal("silence_journal.jsonl")
    static let lock: NSLock = NSLock()

    static let dayFmt: DateFormatter = {
        let f: DateFormatter = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(secondsFromGMT: 0)
        f.dateFormat = "yyyy-MM-dd"
        return f
    }()

    /// Jour du compteur, en GMT+0.
    static func dayKey(_ now: Date) -> String { return dayFmt.string(from: now) }

    /// Catégorie d'une source : "mail" (plafonnée seulement si silence_mail), "proactif" (plafonnée), nil (jamais comptée).
    static func category(_ source: String) -> String? {
        if source == "essai" { return nil }
        if source == "mail:wa-groups" { return "proactif" }
        if source.hasPrefix("mail:") || source == "badge:Outlook" { return "mail" }
        if source.hasPrefix("dot:") || source.hasPrefix("badge:") { return "proactif" }
        if source == "brief" || source == "fundings" || source == "engagements" || source == "go" || source == "suggestion" { return "proactif" }   // V5-U : « Nova te propose » (Feat_Suggestions.swift) compte dans le plafond
        return nil
    }

    /// Plafond lu dans les réglages, quelle que soit sa forme JSON (nombre entier, décimal ou texte), borné 1–10.
    static func cap(_ st: Settings) -> Int {
        let raw: Any? = st.all()["silence_cap"]
        var n: Int = 3
        if let i: Int = raw as? Int { n = i }
        else if let d: Double = raw as? Double { n = Int(d) }
        else if let s: String = raw as? String, let i: Int = Int(s.trimmingCharacters(in: .whitespaces)) { n = i }
        return Swift.min(10, Swift.max(1, n))
    }

    /// Décision pure (testée hors Swift avec les mêmes cas) : sous le plafond → affichée ; sinon → retenue.
    static func decide(shown: Int, held: Int, cap: Int) -> (allow: Bool, shown: Int, held: Int) {
        if shown < cap { return (true, shown + 1, held) }
        return (false, shown, held + 1)
    }

    /// Compteurs du jour (GMT+0) ; un fichier d'un autre jour vaut zéro.
    static func today(_ now: Date = Date()) -> (day: String, shown: Int, held: Int) {
        let d: String = dayKey(now)
        lock.lock()
        let s: [String: Any] = file.read(default: [String: Any]())
        lock.unlock()
        if (s["day"] as? String) != d { return (d, 0, 0) }
        return (d, (s["shown"] as? Int) ?? 0, (s["held"] as? Int) ?? 0)
    }

    /// Appelé par NovaNotifier juste avant d'afficher une notification native NON urgente.
    /// true = l'afficher ; false = retenue (consignée, comptée).
    static func admit(source: String, title: String, body: String, target: [String: String], now: Date = Date()) -> Bool {
        // Nova au premier plan : NovaNotify n'affiche rien (la notification est déjà sous les yeux d'Ahadi) — rien n'est compté.
        if NovaNotifier.post != nil && NovaNotifier.appActive?() == true { return true }
        let st: Settings = Settings()
        if !st.get("silence_mode", true) { return true }
        guard let cat: String = category(source) else { return true }
        if cat == "mail" && !st.get("silence_mail", false) { return true }
        let c: Int = cap(st)
        let d: String = dayKey(now)
        lock.lock()
        let s: [String: Any] = file.read(default: [String: Any]())
        let sameDay: Bool = (s["day"] as? String) == d
        let shown0: Int = sameDay ? ((s["shown"] as? Int) ?? 0) : 0
        let held0: Int = sameDay ? ((s["held"] as? Int) ?? 0) : 0
        let r: (allow: Bool, shown: Int, held: Int) = decide(shown: shown0, held: held0, cap: c)
        let next: [String: Any] = ["day": d, "shown": r.shown, "held": r.held, "cap": c]
        file.write(next)
        lock.unlock()
        if !r.allow {
            let ev: [String: Any] = ["day": d, "source": source, "title": String(title.prefix(120)), "body": String(body.prefix(220)),
                                     "module": target["module"] ?? "", "id": target["id"] ?? "", "cap": c]
            journal.add(ev)
        }
        return r.allow
    }

    /// Les éléments retenus aujourd'hui (les plus récents d'abord), pour l'écran Réglages.
    static func heldToday(_ now: Date = Date(), limit: Int = 8) -> [[String: Any]] {
        let d: String = dayKey(now)
        let rows: [[String: Any]] = journal.tail(200).filter { (e: [String: Any]) -> Bool in (e["day"] as? String) == d }
        var out: [[String: Any]] = []
        for e in rows.reversed().prefix(limit) {
            let one: [String: Any] = ["ts": (e["ts"] as? String) ?? "", "source": (e["source"] as? String) ?? "", "title": (e["title"] as? String) ?? "",
                                      "body": (e["body"] as? String) ?? "", "module": (e["module"] as? String) ?? "", "id": (e["id"] as? String) ?? ""]
            out.append(one)
        }
        return out
    }
}

extension NovaApp {
    /// V5-O : une seule ligne dans Extras.extraRoutes() branche les trois innovations (Silence, Chronobiologie, Rituels).
    func v5oRoutes() {
        silenceRoutes()
        chronoRoutes()      // Feat_Chrono.swift
        rituelsRoutes()     // Feat_Daily.swift
    }

    func silenceRoutes() {
        let s = server
        let st: Settings = settings
        let br: Briefs = briefs
        // GET /api/silence → {on, cap, mail, today:{day, shown, held}, quiet:{from, to, now}, held_items:[…]}
        s.on("GET", "/api/silence") { _, res in
            let t: (day: String, shown: Int, held: Int) = SilenceGate.today()
            let today: [String: Any] = ["day": t.day, "shown": t.shown, "held": t.held]
            let quiet: [String: Any] = ["from": st.get("quiet_from", "22:00"), "to": st.get("quiet_to", "07:00"), "now": br.inQuietHours()]
            let out: [String: Any] = ["on": st.get("silence_mode", true), "cap": SilenceGate.cap(st), "mail": st.get("silence_mail", false),
                                      "today": today, "quiet": quiet, "held_items": SilenceGate.heldToday()]
            res.json(out)
        }
    }
}
