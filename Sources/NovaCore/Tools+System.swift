import Foundation
#if os(macOS)
import AppKit
#endif
#if canImport(EventKit) && os(macOS)
import EventKit
#endif
#if os(macOS)
import ApplicationServices
#endif
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

// Découpé de Tools.swift (19/10) : osascript, EventKit, HTML, HTTP GET — code déplacé à l'identique.
extension Tools {
    nonisolated(unsafe) static var osaCache: [String: (Date, String)] = [:]
    static let osaLock = NSLock()
    /// osascript avec cache (3 min) et repli sur le dernier résultat réussi : Calendrier/Mail sont lents à répondre (parfois > 30 s).
    // Lecture native EventKit : UNIQUEMENT si l'accès est déjà accordé (jamais de demande d'autorisation ici). nil => chemin osascript.
    #if canImport(EventKit) && os(macOS)
    static func ekAuthorized(_ type: EKEntityType) -> Bool {
        let st = EKEventStore.authorizationStatus(for: type)
        if #available(macOS 14.0, *) { return st == .fullAccess }
        return st == .authorized
    }
    /// État d'accès EventKit, nommé pour les messages d'erreur (même vocabulaire que la page Droits).
    enum EKAccess { case granted, notDetermined, denied, writeOnly, restricted, unknown }
    static func ekAccess(_ type: EKEntityType) -> EKAccess {
        let st = EKEventStore.authorizationStatus(for: type)
        if #available(macOS 14.0, *) {
            switch st {
            case .fullAccess, .authorized: return .granted
            case .writeOnly: return .writeOnly
            case .denied: return .denied
            case .notDetermined: return .notDetermined
            case .restricted: return .restricted
            @unknown default: return .unknown
            }
        }
        switch st {
        case .authorized: return .granted
        case .denied: return .denied
        case .notDetermined: return .notDetermined
        case .restricted: return .restricted
        default: return .unknown
        }
    }
    /// Demande d'accès EventKit. À N'APPELER QUE depuis un geste explicite de l'utilisateur
    /// (route POST /api/droits/request-*, P-CAL-3) — jamais depuis un outil, un Dot ou un démarrage.
    static func ekRequestAccess(_ type: EKEntityType, completion: @escaping (Bool) -> Void) {
        let store = EKEventStore()
        if #available(macOS 14.0, *) {
            if type == .event { store.requestFullAccessToEvents { ok, _ in completion(ok) } }
            else { store.requestFullAccessToReminders { ok, _ in completion(ok) } }
        } else {
            store.requestAccess(to: type) { ok, _ in completion(ok) }
        }
    }
    /// L'Automatisation vers une app est-elle refusée à Nova ? Teste SANS jamais afficher la
    /// demande (même technique que la page Droits). true seulement si refus établi (-1743) ;
    /// app fermée (-600) ou jamais demandé (-1744) => false (le repli scripté reste permis).
    static func automationRefused(_ bundleID: String) -> Bool {
        let wild: UInt32 = 0x2A2A2A2A   // '****' (typeWildCard)
        let target: NSAppleEventDescriptor = NSAppleEventDescriptor(bundleIdentifier: bundleID)
        return AEDeterminePermissionToAutomateTarget(target.aeDesc, AEEventClass(wild), AEEventID(wild), false) == -1743
    }
    /// Même forme que la sortie du script AppleScript : « date | titre | calendrier » par ligne.
    static func ekCalendarText() -> String? {
        guard ekAuthorized(.event) else { return nil }
        let store = EKEventStore()
        let cal = Calendar.current
        let d0 = cal.startOfDay(for: Date()); let d1 = d0.addingTimeInterval(7 * 86400)
        let df = DateFormatter(); df.locale = Locale.current; df.dateStyle = .full; df.timeStyle = .medium
        var lines: [String] = []
        for c in store.calendars(for: .event) {
            let cn = c.title
            if cn.contains("fériés") || cn.contains("Birthdays") || cn.contains("Anniversaires") || cn.contains("Siri") || cn.contains("Scheduled") { continue }
            let evs = store.events(matching: store.predicateForEvents(withStart: d0, end: d1, calendars: [c])).sorted { $0.startDate < $1.startDate }
            for e in evs where e.startDate >= d0 && e.startDate < d1 {
                lines.append(df.string(from: e.startDate) + " | " + (e.title ?? "") + " | " + cn)
            }
        }
        return lines.joined(separator: "\n")
    }
    static func ekRemindersText() -> String? {
        guard ekAuthorized(.reminder) else { return nil }
        let store = EKEventStore()
        let sem = DispatchSemaphore(value: 0)
        var names: [String] = []
        store.fetchReminders(matching: store.predicateForIncompleteReminders(withDueDateStarting: nil, ending: nil, calendars: nil)) { rs in
            names = (rs ?? []).prefix(20).map { $0.title ?? "" }
            sem.signal()
        }
        if sem.wait(timeout: .now() + 10) == .timedOut { return nil }
        return names.joined(separator: "\n")
    }
    #endif

    public static func osaCached(_ key: String, _ script: String, timeout: TimeInterval = 40, ttl: TimeInterval = 180) -> (ok: Bool, out: String) {
        osaLock.lock(); let c = osaCache[key]; osaLock.unlock()
        if let c = c, Date().timeIntervalSince(c.0) < ttl { return (true, c.1) }
        let r = osa(script, timeout: timeout)
        if r.ok { osaLock.lock(); osaCache[key] = (Date(), r.out); osaLock.unlock(); return r }
        if let c = c { return (true, c.1 + "\n(données de il y a \(Int(Date().timeIntervalSince(c.0) / 60)) min : Calendrier/Mail n'a pas répondu à temps)") }
        return r
    }
    public static func osa(_ script: String, timeout: TimeInterval = 25) -> (ok: Bool, out: String) {
        #if os(macOS)
        // Calendrier / Mail / Rappels doivent tourner : on les lance en arrière-plan (sans les afficher) s'ils sont fermés.
        if let rx = try? NSRegularExpression(pattern: #"tell application "(Calendar|Mail|Reminders|Notes|Contacts|Messages)""#) {
            let ns = script as NSString; var launched = Set<String>()
            for m in rx.matches(in: script, range: NSRange(location: 0, length: ns.length)) {
                let app = ns.substring(with: m.range(at: 1)); if launched.insert(app).inserted {
                    let (rc, _) = runProcess("/usr/bin/pgrep", ["-x", app == "Calendar" ? "Calendar" : app], timeout: 3)
                    if rc != 0 { _ = runProcess("/usr/bin/open", ["-g", "-a", app], timeout: 10); Thread.sleep(forTimeInterval: 2.5) }
                }
            }
        }
        // WP5 (A/N/O) : exécutable de chemin fixe, sans shell intermédiaire ; durée, sortie et annulation du run bornées ;
        // stderr capturé à part, assaini et borné (les erreurs -1743 / -600 restent lisibles).
        let scope: RunScope? = RunScope.current
        let r: BoundedResult = BoundedProcess.run("/usr/bin/osascript", ["-e", script], timeout: timeout, maxOutput: 1024 * 1024, cancel: { scope?.cancel() ?? false })
        if r.timedOut { return (false, "délai dépassé (\(Int(timeout)) s) — l'app n'a pas répondu") }
        if r.cancelled { return (false, "osascript annulé (arrêt du run)") }
        if let le = r.launchError { return (false, "osascript a échoué (lancement : \(le))") }
        if r.code != 0 { return (false, "osascript a échoué (code \(r.code)) : \(shortError(Knowledge.redact(BoundedProcess.sanitize(r.err + (r.out.isEmpty ? "" : " " + r.out))), 300)) — si « Not authorized » / -1743 : Réglages Système › Confidentialité › Automatisation.") }
        let o: String = r.out + (r.err.isEmpty ? "" : (r.out.isEmpty ? "" : "\n") + r.err)   // « log » d'AppleScript sort sur stderr : gardé comme avant (2>&1)
        return (true, o.trimmingCharacters(in: .whitespacesAndNewlines))
        #else
        return (false, "indisponible hors macOS")
        #endif
    }

    public static func htmlToText(_ h: String, limit: Int = 6000) -> String {
        var s = h
        for pat in ["<script[\\s\\S]*?</script>", "<style[\\s\\S]*?</style>", "<!--[\\s\\S]*?-->", "<[^>]+>"] {
            s = s.replacingOccurrences(of: pat, with: " ", options: .regularExpression)
        }
        for (a, b) in [("&nbsp;", " "), ("&amp;", "&"), ("&quot;", "\""), ("&#39;", "'"), ("&lt;", "<"), ("&gt;", ">"), ("&rsquo;", "’"), ("&#x27;", "'")] { s = s.replacingOccurrences(of: a, with: b) }
        s = s.replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression).trimmingCharacters(in: .whitespaces)
        return String(s.prefix(limit))
    }

    /// 29/10 (Ahadi : « toujours pas autonome ni capable » — HDX a répondu 202 et Nova a abandonné) : lecture de page tenace.
    /// 1) en-têtes d'un vrai Safari ; 2) 202/429/503/504 → 2 nouveaux essais (3 s, 7 s) ; 3) page refusée (401/403/202 persistant)
    /// ou quasi vide (rendu JavaScript) → Tavily Extract (clé nova-tavily) ; 4) sinon ÉCHEC nommé avec les pistes restantes.
    static func fetchResilient(_ url: String) -> String {
        // WP5 (K) : web_fetch suit les redirections UNE PAR UNE, chacune revalidée (schéma, userinfo, hôte interne, résolution DNS).
        var (st, body, refused) = Tools.getChecked(url, timeout: 15)
        if let r = refused { return "URL refusée (\(r))." }
        var tries: Int = 0
        while [202, 429, 503, 504].contains(st) && tries < 2 {
            Thread.sleep(forTimeInterval: tries == 0 ? 3 : 7); tries += 1
            (st, body, refused) = Tools.getChecked(url, timeout: 15)
            if let r = refused { return "URL refusée (\(r))." }
        }
        let text: String = st == 200 ? Tools.htmlToText(body) : ""
        if st == 200 && text.count >= 400 { return "Contenu de \(url) (\(nowISO().prefix(10))) :\n" + text }
        // Repli : Tavily Extract (rendu côté Tavily, contourne les pages JavaScript et beaucoup de refus anti-robot).
        if !Credits.isOpen("tavily"), let tk = KeychainStore().value(KnownKeys.tavilyNova), !tk.isEmpty, let eu = URL(string: "https://api.tavily.com/extract") {
            var rq = URLRequest(url: eu); rq.httpMethod = "POST"
            rq.setValue("Bearer \(tk)", forHTTPHeaderField: "Authorization"); rq.setValue("application/json", forHTTPHeaderField: "Content-Type")
            rq.httpBody = try? JSONSerialization.data(withJSONObject: ["urls": [url], "extract_depth": "advanced"])
            let (est, ed) = syncGet(rq, timeout: 30)
            if est == 200, let o = parseJSON(ed), let rs = o["results"] as? [[String: Any]], let raw = rs.first?["raw_content"] as? String, raw.count >= 200 {
                Credits.count("tavily", n: 2)
                return "Contenu de \(url) (via Tavily Extract — page refusée en direct, HTTP \(st), \(nowISO().prefix(10))) :\n" + String(raw.prefix(20000))
            }
            if est > 0 && est != 200 { Credits.providerFailed("tavily", status: est, detail: String(data: ed.prefix(300), encoding: .utf8) ?? "") }
        }
        if st == 200 && !text.isEmpty { return "Contenu de \(url) (\(nowISO().prefix(10)), page courte ou rendue en JavaScript) :\n" + text }
        return "ÉCHEC : page inaccessible (HTTP \(st) après \(tries + 1) essai(s) et repli Tavily Extract). Pistes restantes : web_search sur le titre exact ou le sujet, version en cache ou miroir (archive.org/web/…), page de téléchargement directe (CSV/XLSX/PDF), API publique du site."
    }
    /// Refus d'une destination web_fetch (nil = permise) : URL analysée (NetPolicy) puis résolution DNS de l'hôte.
    static func fetchDestinationRefusal(_ u: URL) -> String? {
        if let r = NetPolicy.fetchRefusal(u.absoluteString) { return r }
        guard let h = u.host, !NetPolicy.resolvesInternal(h) else { return "hôte interne après résolution" }
        return nil
    }
    /// GET de web_fetch : mêmes en-têtes que get(_:), corps ≤ 5 Mo, au plus 5 redirections, chacune revalidée.
    static func getChecked(_ url: String, timeout: TimeInterval = 12) -> (Int, String, String?) {
        guard let u = URL(string: url) else { return (0, "URL invalide", nil) }
        if let r = fetchDestinationRefusal(u) { return (0, "", r) }
        var rq = URLRequest(url: u); rq.timeoutInterval = timeout
        rq.setValue("Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.0 Safari/605.1.15", forHTTPHeaderField: "User-Agent")
        rq.setValue("text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8", forHTTPHeaderField: "Accept")
        rq.setValue("fr-FR,fr;q=0.9,en;q=0.8", forHTTPHeaderField: "Accept-Language")
        let r = SafeHTTP.get(rq, timeout: timeout, maxBytes: 5 * 1024 * 1024, maxRedirects: 5) { next in Tools.fetchDestinationRefusal(next) }
        if let why = r.refused { return (0, "", why) }
        return (r.status, String(data: r.data, encoding: .utf8) ?? String(data: r.data, encoding: .isoLatin1) ?? "", nil)
    }
    static func get(_ url: String, timeout: TimeInterval = 12) -> (Int, String) {
        guard let u = URL(string: url) else { return (0, "URL invalide") }
        var r = URLRequest(url: u); r.timeoutInterval = timeout
        r.setValue("Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.0 Safari/605.1.15", forHTTPHeaderField: "User-Agent")   // 29/10 : vrai navigateur (« Nova/1.0 » était refusé par plusieurs sites)
        r.setValue("text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8", forHTTPHeaderField: "Accept")
        r.setValue("fr-FR,fr;q=0.9,en;q=0.8", forHTTPHeaderField: "Accept-Language")
        let (st, d) = syncGet(r, timeout: timeout)
        return (st, String(data: d, encoding: .utf8) ?? String(data: d, encoding: .isoLatin1) ?? "")
    }
}
