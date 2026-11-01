import Foundation

// 25/10 : AUTOTEST DE LA NUIT — Nova se teste elle-même à 03:30 (et à la demande : POST /api/autotest/run).
// Branché dans Extras.extraRoutes() ; lu par GET /api/autotest/last (écran Système, web/js/modules/systeme-autotest.js).
//
// Contrôles (chacun : ok / ko, détail MESURÉ, durée, cause probable si ko), tous en parallèle, chacun sous délai :
//  - cerveaux : un appel minuscule par cerveau activé (Spark, [tiers], local) via Router.diagnose — JAMAIS [tiers] ;
//  - sources de courrier : Outlook local (MailAPI.outlook), Gmail (lecture directe IMAP, sinon Mail.app), Zoho (état
//    de la lecture directe), Teams (MailAPI.teams) — les mêmes fonctions que les outils ;
//  - agenda (Tools.ekCalendarText, la voie native de l'outil calendar), cours BRVM (VeillePole.quotes), TV
//    (NovaMedia.tvHealth sur 2 chaînes connues), échecs d'Éclats des 24 h (dots_runs.json), disque et batterie.
// Budget : < 60 s au total, aucun appel [tiers], aucune écriture hors autotest.json. Le matin (≥ 07:00, hors heures
// calmes), UN seul événement du Fil direct : « Autotest de la nuit : N/M OK », ne listant que les KO.

enum Autotest {
    static let file: JSONFile = JSONFile("autotest.json")   // {runs: [≤ 14 passages, plus récent d'abord], published_day}
    static let lock: NSLock = NSLock()
    nonisolated(unsafe) static var running: Bool = false   // PHASE 1 (relu, protégé) : sous lock (run, état, publication)
    nonisolated(unsafe) static var started: Bool = false   // PHASE 1 (relu, protégé) : sous lock (démarrage unique)
    nonisolated(unsafe) static var timer: DispatchSourceTimer? = nil
    static let keep: Int = 14
    static let nightMinute: Int = 3 * 60 + 30
    static let morningMinute: Int = 7 * 60
    static let tvChannels: [(String, String)] = [
        ("France 24", "https://live.france24.com/hls/live/2037179-b/F24_FR_HI_HLS/master_5000.m3u8"),
        ("Africanews FR", "https://cdn-euronews.akamaized.net/live/eds/africanews-fr/25050/index.m3u8"),
    ]
    static let brainIds: [String] = ["spark-1.3", "spark-1.2"]

    static let dayFmt: DateFormatter = {
        let f: DateFormatter = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone.current
        f.dateFormat = "yyyy-MM-dd"
        return f
    }()

    static func ms(_ t0: Date) -> Int { Int(Date().timeIntervalSince(t0) * 1000) }

    /// Ligne de résultat. skip = contrôle sans objet (source non connectée) : affiché, non compté.
    static func row(_ id: String, _ groupe: String, _ label: String, ok: Bool, detail: String, cause: String, ms: Int, skip: Bool) -> [String: Any] {
        var r: [String: Any] = ["id": id, "groupe": groupe, "label": label, "ok": ok, "detail": String(detail.prefix(300)), "ms": ms, "skip": skip]
        if !ok && !cause.isEmpty { r["cause"] = String(cause.prefix(300)) }
        return r
    }

    /// Exécute `work` sous délai : au-delà de `budget`, la ligne est KO « délai dépassé » (le travail tardif est ignoré).
    static func timed(_ id: String, _ groupe: String, _ label: String, budget: TimeInterval,
                      _ work: @escaping () -> (ok: Bool, detail: String, cause: String, skip: Bool)) -> [String: Any] {
        let t0: Date = Date()
        let sem: DispatchSemaphore = DispatchSemaphore(value: 0)
        let box: AutotestBox = AutotestBox()
        DispatchQueue.global(qos: .utility).async {
            let r: (ok: Bool, detail: String, cause: String, skip: Bool) = work()
            box.set(r)
            sem.signal()
        }
        if sem.wait(timeout: .now() + budget) == .timedOut {
            let lim: String = String(Int(budget)) + " s"
            return row(id, groupe, label, ok: false, detail: "pas de réponse en " + lim, cause: "délai dépassé (> " + lim + ") — service bloqué ou réseau lent", ms: ms(t0), skip: false)
        }
        guard let r = box.get() else {
            return row(id, groupe, label, ok: false, detail: "aucun résultat", cause: "contrôle interrompu", ms: ms(t0), skip: false)
        }
        return row(id, groupe, label, ok: r.ok, detail: r.detail, cause: r.cause, ms: ms(t0), skip: r.skip)
    }

    // MARK: contrôles

    static func brainCheck(router: Router, id: String) -> (ok: Bool, detail: String, cause: String, skip: Bool) {
        let rows: [[String: Any]] = router.diagnose(ids: [id])
        guard let r: [String: Any] = rows.first else {
            return (false, "cerveau introuvable", "absent du catalogue ou moteur local arrêté", false)
        }
        let etat: String = (r["etat"] as? String) ?? ""
        let det: String = (r["detail"] as? String) ?? ""
        if etat == "prêt" { return (true, det, "", false) }
        if etat == "sans clé" { return (false, det, "clé absente du Trousseau", true) }
        return (false, det, "le cerveau ne répond pas : " + det, false)
    }

    /// Cerveaux activés à tester : Spark, [tiers], local — jamais un cerveau [tiers] (coût nul la nuit).
    static func brainTargets(router: Router) -> [(String, String)] {
        var out: [(String, String)] = []
        for id in brainIds {
            if router.disabled.contains(id) { continue }
            if id == "local" {
                if let l: BrainSpec = router.localSpec() { out.append((id, l.label)) }
                continue
            }
            guard let sp: BrainSpec = router.brains.first(where: { (b: BrainSpec) -> Bool in b.id == id }) else { continue }
            out.append((id, sp.label))
        }
        return out
    }

    static func outlookCheck() -> (ok: Bool, detail: String, cause: String, skip: Bool) {
        let r: (items: [MailItem]?, source: String, err: String) = MailAPI.outlook(query: nil, limit: 5)
        // 26/10 : le nouvel Outlook pour Mac ne sert rien par AppleScript (0 message) — la lecture réelle passe par le volet web.
        let webAge: TimeInterval? = WebMail.snapshotAge("ol")
        if let items: [MailItem] = r.items, !items.isEmpty { return (true, String(items.count) + " messages lus · " + r.source, "", false) }
        if let age = webAge, age <= 12 * 3600 { return (true, "lecture web : dernière synchro il y a " + Autotest.ageText(Int(age / 60)) + " (Outlook local vide)", "", false) }
        if let items: [MailItem] = r.items { return (true, String(items.count) + " messages lus · " + r.source, "", false) }
        return (false, "Outlook local illisible", r.err.isEmpty ? "base Outlook absente ou accès refusé" : r.err, false)
    }

    static func ageText(_ mins: Int) -> String {
        if mins < 60 { return String(max(mins, 0)) + " min" }
        let h: Int = mins / 60
        return String(h) + " h"
    }

    static func teamsCheck() -> (ok: Bool, detail: String, cause: String, skip: Bool) {
        let r: (items: [MailItem]?, source: String, err: String) = MailAPI.teams(limit: 5)
        if let items: [MailItem] = r.items { return (true, String(items.count) + " messages lus · " + r.source, "", false) }
        // 26/10 : Teams est branché par la session web (WebMail « tm ») — c'est la voie de lecture réelle ; le local n'est qu'un plus.
        if let age: TimeInterval = WebMail.snapshotAge("tm") {
            let mins: Int = Int(age / 60)
            if age <= 12 * 3600 {
                return (true, "lecture web : dernière synchro il y a " + Autotest.ageText(mins), "", false)
            }
            return (false, "session web Teams non synchronisée depuis " + Autotest.ageText(mins), "ouvre Teams dans Messages pour rafraîchir la session", false)
        }
        return (false, "Teams illisible (local et web)", r.err.isEmpty ? "notifications / cache Teams indisponibles ; session web non connectée" : r.err + " ; session web non connectée", false)
    }

    static func gmailCheck(keys: KeyStore) -> (ok: Bool, detail: String, cause: String, skip: Bool) {
        let st: [String: Any] = Gmail.status(keys: keys)
        if (st["connected"] as? Bool) == true {
            let acc: String = (st["account"] as? String) ?? ""
            guard let pw: String = keys.value(KnownKeys.gmail), !pw.isEmpty else {
                return (false, "mot de passe absent du Trousseau", "reconnecte Gmail dans Réglages › Données & comptes", false)
            }
            let r: (ok: Bool, errClass: String, message: String) = Gmail.testLogin(email: acc, password: pw)
            let age: Int = Int((Gmail.lastOkAge() ?? -60) / 60)
            let ageTxt: String = age < 0 ? "jamais synchronisé" : "dernière synchro il y a " + String(age) + " min"
            if r.ok { return (true, "lecture directe IMAP : connexion OK · " + ageTxt, "", false) }
            return (false, "lecture directe IMAP refusée · " + ageTxt, r.message, false)
        }
        #if os(macOS)
        let running: (Int32, String) = runProcess("/usr/bin/pgrep", ["-x", "Mail"], timeout: 3)
        if running.0 != 0 {
            return (false, "Gmail non connecté en lecture directe, Mail.app fermé", "connecte Gmail en lecture directe (Réglages › Données & comptes) : Mail.app dépasse souvent son délai", false)
        }
        let r: (Int32, String) = runProcess("/usr/bin/osascript", ["-e", "tell application \"Mail\" to get unread count of inbox"], timeout: 12)
        let out: String = r.1.trimmingCharacters(in: .whitespacesAndNewlines)
        if r.0 == 0 && Int(out) != nil { return (true, "Mail.app : " + out + " non lus (tous comptes)", "", false) }
        return (false, "Mail.app ne répond pas", "Mail.app bloqué ou Automatisation refusée — connecte Gmail en lecture directe", false)
        #else
        return (false, "Mail.app indisponible sur cette plateforme", "plateforme", true)
        #endif
    }

    static func zohoCheck(keys: KeyStore) -> (ok: Bool, detail: String, cause: String, skip: Bool) {
        let st: [String: Any] = Zoho.status(keys: keys)
        if (st["connected"] as? Bool) != true { return (false, "boîte Zoho non connectée", "", true) }
        let errTxt: String = (st["error"] as? String) ?? ""
        var ageMin: Int = -1
        if let s: String = st["last_ok"] as? String, let d: Date = ISO8601DateFormatter().date(from: s) { ageMin = Int(Date().timeIntervalSince(d) / 60) }
        let ageTxt: String = ageMin < 0 ? "jamais synchronisée" : "dernière synchro il y a " + String(ageMin) + " min"
        if !errTxt.isEmpty { return (false, ageTxt, errTxt, false) }
        if ageMin < 0 || ageMin > 20 { return (false, ageTxt, "synchro en retard (attendue toutes les 5 min)", false) }
        let n: Int = (st["count"] as? Int) ?? 0
        return (true, ageTxt + " · " + String(n) + " messages en copie locale", "", false)
    }

    static func calendarCheck() -> (ok: Bool, detail: String, cause: String, skip: Bool) {
        #if canImport(EventKit) && os(macOS)
        guard let t: String = Tools.ekCalendarText() else {
            return (false, "agenda illisible", "accès Calendrier non accordé à Nova (Réglages Système › Confidentialité › Calendriers)", false)
        }
        let n: Int = t.split(separator: "\n").count
        return (true, "lecture native EventKit · " + String(n) + " lignes sur 7 jours", "", false)
        #else
        return (false, "EventKit indisponible sur cette plateforme", "plateforme", true)
        #endif
    }

    static func brvmCheck() -> (ok: Bool, detail: String, cause: String, skip: Bool) {
        let r: (q: [String: (price: Double, var: Double)], at: Date?, err: String?) = VeillePole.quotes()
        if let e: String = r.err { return (false, String(r.q.count) + " cours en cache", e, false) }
        if r.q.isEmpty { return (false, "aucun cours lu", "page brvm.org vide ou format changé", false) }
        return (true, String(r.q.count) + " cours lus sur brvm.org", "", false)
    }

    static func tvCheck(_ url: String) -> (ok: Bool, detail: String, cause: String, skip: Bool) {
        let r: (Bool, String) = NovaMedia.tvHealth(url)
        if r.0 { return (true, "manifeste, variante et segment lus", "", false) }
        return (false, "flux injouable", r.1.isEmpty ? "flux muet" : r.1, false)
    }

    /// Échecs d'Éclats des 24 dernières heures (dots_runs.json), avec le motif lu dans le rapport.
    static func eclatsCheck() -> (ok: Bool, detail: String, cause: String, skip: Bool) {
        let runs: [[String: Any]] = JSONFile("dots_runs.json").read(default: [[String: Any]]())
        let dots: [[String: Any]] = JSONFile("dots.json").read(default: [[String: Any]]())
        var names: [String: String] = [:]
        for d in dots {
            if let id: String = d["id"] as? String { names[id] = (d["name"] as? String) ?? id }
        }
        let iso: ISO8601DateFormatter = ISO8601DateFormatter()
        let since: Date = Date().addingTimeInterval(-24 * 3600)
        var total: Int = 0
        var fails: [String] = []
        var resolved: Int = 0
        // 26/10 : un échec suivi d'un passage réussi du même Éclat est résolu — on ne signale que les échecs encore ouverts.
        var lastOK: [String: Date] = [:]
        for r in runs {
            if (r["statut"] as? String) == "en_cours" { continue }
            guard let ts: String = r["ts"] as? String, let d: Date = iso.date(from: ts) else { continue }
            let st: String = (r["status"] as? String) ?? ""
            if st == "ECHEC" || (r["ok"] as? Bool) == false { continue }
            let dotId: String = (r["dot"] as? String) ?? "?"
            if let prev: Date = lastOK[dotId], prev >= d { continue }
            lastOK[dotId] = d
        }
        for r in runs {
            if (r["statut"] as? String) == "en_cours" { continue }
            guard let ts: String = r["ts"] as? String, let d: Date = iso.date(from: ts), d >= since else { continue }
            total += 1
            let st: String = (r["status"] as? String) ?? ""
            let failed: Bool = st == "ECHEC" || (r["ok"] as? Bool) == false
            if !failed { continue }
            let dotId: String = (r["dot"] as? String) ?? "?"
            if let ok: Date = lastOK[dotId], ok > d { resolved += 1; continue }
            let nm: String = names[dotId] ?? dotId
            let res: String = ((r["result"] as? String) ?? "").replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
            let why: String = res.isEmpty ? "rapport vide" : String(res.prefix(90))
            fails.append(nm + " (" + why + ")")
        }
        let resolvedTxt: String = resolved > 0 ? " (" + String(resolved) + " échec(s) résolu(s) par un passage suivant)" : ""
        if fails.isEmpty { return (true, String(total) + " passages en 24 h, aucun échec ouvert" + resolvedTxt, "", false) }
        let shown: String = fails.prefix(4).joined(separator: " ; ")
        let more: String = fails.count > 4 ? " ; +" + String(fails.count - 4) : ""
        return (false, String(fails.count) + " échec(s) sur " + String(total) + " passages en 24 h", shown + more, false)
    }

    static func diskCheck() -> (ok: Bool, detail: String, cause: String, skip: Bool) {
        #if os(macOS)
        let keys: Set<URLResourceKey> = [.volumeTotalCapacityKey, .volumeAvailableCapacityForImportantUsageKey]
        guard let v: URLResourceValues = try? URL(fileURLWithPath: "/").resourceValues(forKeys: keys),
              let tot: Int = v.volumeTotalCapacity, let avail: Int64 = v.volumeAvailableCapacityForImportantUsage, tot > 0 else {
            return (false, "capacité du disque illisible", "API volume indisponible", false)
        }
        let freeGB: Double = Double(avail) / 1_000_000_000
        let pct: Int = Int(Double(avail) / Double(tot) * 100)
        let txt: String = String(format: "%.0f Go libres (%ld %%)", freeGB, pct)
        if freeGB < 10 { return (false, txt, "disque presque plein (< 10 Go) : caches, téléchargements, sauvegardes locales", false) }
        return (true, txt, "", false)
        #else
        return (false, "disque non mesuré sur cette plateforme", "plateforme", true)
        #endif
    }

    static func batteryCheck() -> (ok: Bool, detail: String, cause: String, skip: Bool) {
        #if os(macOS)
        let r: (Int32, String) = runProcess("/usr/bin/pmset", ["-g", "batt"], timeout: 4)
        let out: String = r.1
        let ac: Bool = out.contains("AC Power")
        guard let m: String = ZohoMime.firstGroup(out, #"(\d{1,3})%"#), let pct: Int = Int(m) else {
            return (true, ac ? "sur secteur (pas de batterie lue)" : "aucune batterie lue", "", ac == false)
        }
        let src: String = ac ? "secteur" : "batterie"
        let txt: String = String(pct) + " % · " + src
        if !ac && pct < 20 { return (false, txt, "batterie faible hors secteur : Nova peut être suspendue la nuit", false) }
        return (true, txt, "", false)
        #else
        return (false, "batterie non mesurée sur cette plateforme", "plateforme", true)
        #endif
    }

    // MARK: passage

    /// Un passage complet (< 60 s). nil si un passage est déjà en cours.
    static func run(router: Router, keys: KeyStore, reason: String) -> [String: Any]? {
        lock.lock()
        if running { lock.unlock(); return nil }
        running = true
        lock.unlock()
        defer { lock.lock(); running = false; lock.unlock() }
        let t0: Date = Date()
        var jobs: [() -> [String: Any]] = []
        for (id, label) in brainTargets(router: router) {
            let bid: String = id
            jobs.append({ () -> [String: Any] in timed("cerveau." + bid, "Cerveaux", label, budget: 25) { () -> (ok: Bool, detail: String, cause: String, skip: Bool) in brainCheck(router: router, id: bid) } })
        }
        jobs.append({ () -> [String: Any] in timed("mail.outlook", "Courrier", "Outlook (local)", budget: 15) { () -> (ok: Bool, detail: String, cause: String, skip: Bool) in outlookCheck() } })
        jobs.append({ () -> [String: Any] in timed("mail.gmail", "Courrier", "Gmail", budget: 25) { () -> (ok: Bool, detail: String, cause: String, skip: Bool) in gmailCheck(keys: keys) } })
        jobs.append({ () -> [String: Any] in timed("mail.zoho", "Courrier", "Zoho (campagne)", budget: 5) { () -> (ok: Bool, detail: String, cause: String, skip: Bool) in zohoCheck(keys: keys) } })
        jobs.append({ () -> [String: Any] in timed("mail.teams", "Courrier", "Teams", budget: 15) { () -> (ok: Bool, detail: String, cause: String, skip: Bool) in teamsCheck() } })
        jobs.append({ () -> [String: Any] in timed("agenda", "Données", "Agenda", budget: 15) { () -> (ok: Bool, detail: String, cause: String, skip: Bool) in calendarCheck() } })
        jobs.append({ () -> [String: Any] in timed("brvm", "Données", "Cours BRVM", budget: 20) { () -> (ok: Bool, detail: String, cause: String, skip: Bool) in brvmCheck() } })
        for (name, url) in tvChannels {
            let u: String = url
            let n: String = name
            jobs.append({ () -> [String: Any] in timed("tv." + n, "Médias", "TV · " + n, budget: 25) { () -> (ok: Bool, detail: String, cause: String, skip: Bool) in tvCheck(u) } })
        }
        jobs.append({ () -> [String: Any] in timed("eclats", "Éclats", "Échecs d'Éclats (24 h)", budget: 5) { () -> (ok: Bool, detail: String, cause: String, skip: Bool) in eclatsCheck() } })
        jobs.append({ () -> [String: Any] in timed("disque", "Mac", "Disque", budget: 5) { () -> (ok: Bool, detail: String, cause: String, skip: Bool) in diskCheck() } })
        jobs.append({ () -> [String: Any] in timed("batterie", "Mac", "Batterie", budget: 6) { () -> (ok: Bool, detail: String, cause: String, skip: Bool) in batteryCheck() } })

        let results: AutotestRows = AutotestRows(count: jobs.count)
        let g: DispatchGroup = DispatchGroup()
        for (i, job) in jobs.enumerated() {
            g.enter()
            DispatchQueue.global(qos: .utility).async {
                let r: [String: Any] = job()
                results.put(i, r)
                g.leave()
            }
        }
        _ = g.wait(timeout: .now() + 58)
        let checks: [[String: Any]] = results.all()
        var okN: Int = 0
        var total: Int = 0
        for c in checks {
            if (c["skip"] as? Bool) == true { continue }
            total += 1
            if (c["ok"] as? Bool) == true { okN += 1 }
        }
        let now: Date = Date()
        let run: [String: Any] = ["ts": nowISO(), "day": dayFmt.string(from: now), "raison": reason, "ok_n": okN, "total": total,
                                  "ms": ms(t0), "checks": checks]
        lock.lock()
        var o: [String: Any] = file.read(default: [String: Any]())
        var runs: [[String: Any]] = (o["runs"] as? [[String: Any]]) ?? []
        runs.insert(run, at: 0)
        o["runs"] = Array(runs.prefix(keep))
        file.write(o)
        lock.unlock()
        return run
    }

    static func last() -> [String: Any] {
        lock.lock()
        let o: [String: Any] = file.read(default: [String: Any]())
        let busy: Bool = running
        lock.unlock()
        let runs: [[String: Any]] = (o["runs"] as? [[String: Any]]) ?? []
        let hist: [[String: Any]] = runs.map { (r: [String: Any]) -> [String: Any] in
            ["ts": r["ts"] ?? "", "ok_n": r["ok_n"] ?? 0, "total": r["total"] ?? 0, "ms": r["ms"] ?? 0, "raison": r["raison"] ?? ""]
        }
        var out: [String: Any] = ["running": busy, "history": hist, "heure": "03:30", "published_day": o["published_day"] ?? ""]
        if let l: [String: Any] = runs.first { out["last"] = l } else { out["last"] = NSNull() }
        return out
    }

    /// Texte de l'événement du matin : seulement les KO, avec leur cause probable.
    static func morningText(_ run: [String: Any]) -> (title: String, text: String, allOK: Bool) {
        let okN: Int = (run["ok_n"] as? Int) ?? 0
        let total: Int = (run["total"] as? Int) ?? 0
        let title: String = "Autotest de la nuit : " + String(okN) + "/" + String(total) + " OK"
        var lines: [String] = []
        for c in (run["checks"] as? [[String: Any]]) ?? [] {
            if (c["skip"] as? Bool) == true || (c["ok"] as? Bool) == true { continue }
            let lab: String = (c["label"] as? String) ?? ""
            let det: String = (c["detail"] as? String) ?? ""
            let cause: String = (c["cause"] as? String) ?? ""
            var l: String = "• " + lab + " — " + det
            if !cause.isEmpty { l += " (cause probable : " + cause + ")" }
            lines.append(l)
        }
        let secs: Int = ((run["ms"] as? Int) ?? 0) / 1000
        if lines.isEmpty {
            return (title, "Tout est au vert : " + String(total) + " contrôles en " + String(secs) + " s (cerveaux, courrier, agenda, BRVM, TV, Éclats, Mac). Détail : Système › Autotest de la nuit.", true)
        }
        let head: String = String(lines.count) + " contrôle(s) en échec cette nuit :\n"
        return (title, head + lines.joined(separator: "\n") + "\n(Détail et relance : Système › Autotest de la nuit.)", false)
    }

    /// Publie l'événement du matin une seule fois par jour, pour le passage de la nuit du jour.
    static func publishMorning(today: String) {
        lock.lock()
        var o: [String: Any] = file.read(default: [String: Any]())
        let runs: [[String: Any]] = (o["runs"] as? [[String: Any]]) ?? []
        let night: [String: Any]? = runs.first(where: { (r: [String: Any]) -> Bool in (r["day"] as? String) == today && (r["raison"] as? String) == "nuit" })
        guard let run: [String: Any] = night, (o["published_day"] as? String) != today else { lock.unlock(); return }
        o["published_day"] = today
        file.write(o)
        lock.unlock()
        let m: (title: String, text: String, allOK: Bool) = morningText(run)
        ProactiveFeed.append(kind: "autotest", box: "nova", title: m.title, text: m.text, urgent: false, who: "", extra: ["autotest_ts": (run["ts"] as? String) ?? ""])
    }

    static func tick(router: Router, keys: KeyStore, briefs: Briefs, bus: Bus) {
        let now: Date = Date()
        let c: DateComponents = Calendar.current.dateComponents([.hour, .minute], from: now)
        let m: Int = (c.hour ?? 0) * 60 + (c.minute ?? 0)
        let today: String = dayFmt.string(from: now)
        lock.lock()
        let o: [String: Any] = file.read(default: [String: Any]())
        let busy: Bool = running
        lock.unlock()
        let runs: [[String: Any]] = (o["runs"] as? [[String: Any]]) ?? []
        let doneTonight: Bool = runs.contains(where: { (r: [String: Any]) -> Bool in (r["day"] as? String) == today && (r["raison"] as? String) == "nuit" })
        if !busy && !doneTonight && m >= nightMinute && m <= nightMinute + 120 {
            if let r: [String: Any] = run(router: router, keys: keys, reason: "nuit") {
                bus.publish("autotest", ["ok_n": r["ok_n"] ?? 0, "total": r["total"] ?? 0])
            }
            return
        }
        if m >= morningMinute && doneTonight && (o["published_day"] as? String) != today && !briefs.inQuietHours(now) {
            publishMorning(today: today)
        }
    }

    static func start(router: Router, keys: KeyStore, briefs: Briefs, bus: Bus) {
        lock.lock()
        if started { lock.unlock(); return }
        started = true
        lock.unlock()
        let t: DispatchSourceTimer = DispatchSource.makeTimerSource(queue: DispatchQueue(label: "nova.autotest.tick", qos: .utility))
        t.schedule(deadline: .now() + 90, repeating: 120, leeway: .seconds(10))
        t.setEventHandler { tick(router: router, keys: keys, briefs: briefs, bus: bus) }
        lock.lock(); timer = t; lock.unlock()
        t.resume()
    }
}

/// Boîte thread-safe pour le résultat d'un contrôle sous délai.
final class AutotestBox: @unchecked Sendable {
    private let lock: NSLock = NSLock()
    private var value: (ok: Bool, detail: String, cause: String, skip: Bool)? = nil
    func set(_ v: (ok: Bool, detail: String, cause: String, skip: Bool)) { lock.lock(); value = v; lock.unlock() }
    func get() -> (ok: Bool, detail: String, cause: String, skip: Bool)? { lock.lock(); defer { lock.unlock() }; return value }
}

/// Résultats ordonnés (index du contrôle) ; un contrôle qui n'a pas rendu dans le budget global est simplement absent.
final class AutotestRows: @unchecked Sendable {
    private let lock: NSLock = NSLock()
    private var rows: [[String: Any]?]
    init(count: Int) { rows = Array(repeating: nil, count: count) }
    func put(_ i: Int, _ r: [String: Any]) { lock.lock(); if i < rows.count { rows[i] = r }; lock.unlock() }
    func all() -> [[String: Any]] { lock.lock(); defer { lock.unlock() }; return rows.compactMap { (x: [String: Any]?) -> [String: Any]? in x } }
}

// MARK: - Routes

extension NovaApp {
    func autotestRoutes() {
        let s = server
        let r: Router = router
        let k: KeyStore = keys
        let b: Briefs = briefs
        let bs: Bus = bus
        Autotest.start(router: r, keys: k, briefs: b, bus: bs)
        DiagVoix.start(app: self)
        integrationsRoutes()   // 29/10 : veille des intégrations (Feat_Integrations.swift)
        museRitualsStart()   // 26/10 : rituels proactifs façon Muse (Feat_MuseRituels.swift)   // 26/10 : miroir de diagnostic voix dans ~/spark-local/Nova2/releves/diag
        s.on("GET", "/api/autotest/last") { _, res in
            res.json(Autotest.last())
        }
        // Synchrone (< 60 s) : renvoie le passage complet ; {status: en_cours} si un passage tourne déjà.
        s.on("POST", "/api/autotest/run") { _, res in
            guard let run: [String: Any] = Autotest.run(router: r, keys: k, reason: "demande d'Ahadi") else {
                let busy: [String: Any] = ["status": "en_cours"]
                res.json(busy)
                return
            }
            bs.publish("autotest", ["ok_n": run["ok_n"] ?? 0, "total": run["total"] ?? 0])
            res.json(run)
        }
    }
}
