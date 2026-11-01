import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
#if canImport(FoundationXML)
import FoundationXML
#endif

/// Phase 10 — Pôle Veille : Radar Humanitaire Afrique (WCA & ESA — périmètre SCI + zone élargie), Observatoire Financier BRVM, Briefing Exécutif Matinal.
/// Règle d'or : uniquement des données RÉELLES (flux publics, cours publics, saisies de l'utilisateur). Une source injoignable est DITE, jamais remplacée.
/// Information seulement : aucun conseil d'investissement, aucun ordre de bourse, aucun envoi.
enum VeillePole {
    static let cfg = JSONFile("veille_pole.json")
    static let briefingFile = JSONFile("veille_briefing.json")
    static let cfgLock = NSLock()

    /// Sources publiques du radar (RSS). L'utilisateur peut en ajouter ; ses flux de Veille (réglage « feeds ») sont lus aussi.
    static let defaultRadar: [(name: String, url: String)] = [
        ("ReliefWeb (OCHA)", "https://reliefweb.int/updates/rss.xml"),
        ("ReliefWeb — Sahel", FluxCatalog.rwSearch("sahel")),
        ("ONU Info — Afrique", "https://news.un.org/feed/subscribe/en/news/region/africa/feed/rss.xml"),
        ("The New Humanitarian", "https://www.thenewhumanitarian.org/rss/all.xml"),
        ("RFI — Afrique (Google Actualités)", FluxCatalog.gn("site:rfi.fr afrique")),
        ("France 24 — Afrique (Google Actualités)", FluxCatalog.gn("site:france24.com afrique")),
        ("International Crisis Group", "https://www.crisisgroup.org/rss"),
        ("OCHA", "https://www.unocha.org/rss.xml"),
        ("BBC Afrique", "https://feeds.bbci.co.uk/afrique/rss.xml"),
        ("ACLED (Google Actualités)", FluxCatalog.gn("ACLED conflit Afrique")),
        ("ISS Africa (Google Actualités)", FluxCatalog.gn("site:issafrica.org")),
    ]

    // MARK: classification (sur les TITRES : le flux RSS lu ne fournit que titre, lien, date)
    static func fold(_ s: String) -> String {
        s.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: Locale(identifier: "fr_FR")).replacingOccurrences(of: "’", with: "'")
    }
    static let countryDefs: [(String, String)] = [
        ("Mali", #"\bmali\b"#), ("Burkina Faso", #"\bburkina(?: faso)?\b"#), ("Niger", #"\bniger\b"#), ("Tchad", #"\b(?:tchad|chad)\b"#),
        ("Mauritanie", #"\bmauritani[ae]\b"#), ("Nigeria", #"\bnigeria\b"#), ("Sénégal", #"\bsenegal\b"#),
        ("Guinée-Bissau", #"\bguinee[- ]bissau\b|\bguinea[- ]bissau\b"#), ("Guinée", #"\b(?:guinee|guinea)\b(?![- ]*(?:bissau|equatorial))"#),
        ("Côte d'Ivoire", #"\bcote d.ivoire\b|\bivory coast\b"#), ("Bénin", #"\bbenin\b"#), ("Togo", #"\btogo\b"#), ("Ghana", #"\bghana\b"#),
        ("Gambie", #"\b(?:gambie|gambia)\b"#), ("Sierra Leone", #"\bsierra leone\b"#), ("Liberia", #"\bliberia\b"#),
        ("Cap-Vert", #"\b(?:cap[- ]vert|cabo verde|cape verde)\b"#), ("Cameroun", #"\b(?:cameroun|cameroon)\b"#),
        ("RD Congo", #"\b(?:rdc|rd congo|congo[- ]kinshasa|kinshasa|kivu|drc|democratic republic of the congo)\b"#),
        ("Soudan du Sud", #"\b(?:soudan du sud|south sudan)\b"#), ("Soudan", #"(?<!south )(?:soudan|sudan)\b(?! du sud)"#),
        ("Éthiopie", #"\b(?:ethiopie|ethiopia)\b"#), ("Somalie", #"\b(?:somalie|somalia)\b"#), ("Kenya", #"\bkenya\b"#),
        ("Mozambique", #"\bmozambique\b"#), ("Ouganda", #"\b(?:ouganda|uganda)\b"#),
        ("Malawi", #"\bmalawi\b"#), ("Rwanda", #"\brwanda\b"#), ("Tanzanie", #"\b(?:tanzanie|tanzania)\b"#),
        ("Zambie", #"\b(?:zambie|zambia)\b"#), ("Zimbabwe", #"\bzimbabwe\b"#),
    ]
    static let regionRx = #"\b(?:sahel|afrique de l.ouest|west africa|lac tchad|lake chad|liptako|gourma|cedeao|ecowas|alliance des etats du sahel|corne de l.afrique|horn of africa|afrique de l.est|east(?:ern)? africa|afrique australe|southern africa|eastern and southern africa)\b"#
    /// Pays ESA de countryDefs (toute autre définition est WCA ou zone élargie) — répartition régionale du radar et quotas du briefing.
    static let esaCountries: Set<String> = ["Éthiopie", "Somalie", "Soudan", "Soudan du Sud", "Kenya", "Mozambique", "Ouganda", "Malawi", "Rwanda", "Tanzanie", "Zambie", "Zimbabwe"]
    static func region(of country: String) -> String { esaCountries.contains(country) ? "esa" : "wca" }
    static let themeDefs: [(String, String)] = [
        ("securite", #"attaque|attentat|djihad|jihad|terroris|militaire|armee|coup d.etat|junte|conflit|violen|enlev|securit|combat|embuscade|attack|insurg|militan|killed|armed|clash|abduct|tentative de coup|coup attempt|security|jnim|boko haram|groupe arme|massacre"#),
        ("humanitaire", #"humanitaire|refugi|deplace|famine|insecurite alimentaire|malnutrition|cholera|inondation|urgence|epidemie|secheresse|crise alimentaire|humanitarian|displac|food insecurity|hunger|flood|drought|outbreak|emergency|asylum|enfants|children|civils|civilians"#),
        ("financement", #"financement|fonds|bailleur|donateur|appel de fonds|budget|coupes? budg|coupes? dans l.aide|funding cut|aid cut|funding|donor|appeal|grant|pledge|usaid|plan de reponse|response plan|\bhrp\b|\bcerf\b"#),
    ]
    static let countryRx: [(String, NSRegularExpression)] = countryDefs.compactMap { d in (try? NSRegularExpression(pattern: d.1)).map { (d.0, $0) } }
    static let regionRegex = try! NSRegularExpression(pattern: regionRx)
    static let themeRx: [(String, NSRegularExpression)] = themeDefs.compactMap { d in (try? NSRegularExpression(pattern: d.1)).map { (d.0, $0) } }
    static func hit(_ rx: NSRegularExpression, _ s: String) -> Bool { rx.firstMatch(in: s, range: NSRange(location: 0, length: (s as NSString).length)) != nil }

    static func parseDate(_ s: String) -> Date? {
        let t = s.trimmingCharacters(in: .whitespacesAndNewlines); if t.isEmpty { return nil }
        let f = DateFormatter(); f.locale = Locale(identifier: "en_US_POSIX")
        for fmt in ["EEE, dd MMM yyyy HH:mm:ss Z", "EEE, dd MMM yyyy HH:mm:ss zzz", "EEE, d MMM yyyy HH:mm:ss Z", "dd MMM yyyy HH:mm:ss Z", "yyyy-MM-dd'T'HH:mm:ssXXXXX", "yyyy-MM-dd'T'HH:mm:ss.SSSXXXXX", "yyyy-MM-dd'T'HH:mm:ssZ"] {
            f.dateFormat = fmt; if let d = f.date(from: t) { return d }
        }
        return ISO8601DateFormatter().date(from: t)
    }

    // MARK: flux
    static func fetchFeed(_ url: String, timeout: TimeInterval = 12) -> (ok: Bool, detail: String, items: [(String, String, String)], rich: [(String, String, String, String, String, String)]) {
        guard let u = URL(string: url), let h = u.host, !Tools.isInternalHost(h), u.scheme == "https" || u.scheme == "http" else { return (false, "adresse refusée", [], []) }
        let (st, body) = Tools.get(url, timeout: timeout)
        guard st == 200 else { return (false, st == 0 ? "injoignable (réseau ou délai ; \(Int(timeout)) s)" : "HTTP \(st)", [], []) }
        guard let d = body.data(using: .utf8) else { return (false, "contenu illisible", [], []) }
        let p = RSSParser(); let x = XMLParser(data: d); x.delegate = p; let parsed = x.parse()
        if p.items.isEmpty && !parsed { return (false, "flux illisible (RSS/Atom invalide)", [], []) }
        return (true, p.items.isEmpty ? "flux vide" : "ok", p.items, p.rich)
    }

    /// Brief d'une carte du feed : le texte que le flux fournit DÉJÀ (description,
    /// sinon contenu encodé), nettoyé et borné. Vide si le flux ne donne rien
    /// d'exploitable — l'item part alors SANS brief, jamais avec un texte inventé.
    static func briefText(desc: String, encoded: String) -> String {
        let raw = desc.count >= 80 ? desc : (encoded.isEmpty ? desc : encoded)
        let t = Tools.htmlToText(raw, limit: 900)
        if t.count <= 460 { return t }
        let cut = String(t.prefix(460))
        if let r = cut.range(of: ". ", options: .backwards) { return String(cut[..<r.upperBound]).trimmingCharacters(in: .whitespaces) }
        if let r = cut.range(of: " ", options: .backwards) { return String(cut[..<r.lowerBound]) + "…" }
        return cut + "…"
    }

    static func radarSources(_ settings: Settings) -> [(name: String, url: String, builtin: Bool)] {
        var out = defaultRadar.map { (name: $0.name, url: $0.url, builtin: true) }
        let extra = (cfg.read(default: [String: Any]())["radar_extra"] as? [String]) ?? []
        for u in extra + settings.get("feeds", [String]()) where !out.contains(where: { $0.url == u }) {
            out.append((name: URL(string: u)?.host ?? u, url: u, builtin: false))
        }
        return out
    }

    /// Radar : articles réels des sources, filtrés sur la zone (titre cite un pays du périmètre — SCI WCA/ESA ou zone élargie — ou la région), classés par thème.
    static func radar(settings: Settings, days: Int) -> [String: Any] {
        let srcs = radarSources(settings)
        var per = srcs.map { ["name": $0.name, "url": $0.url, "ok": false, "detail": "délai dépassé", "total": 0, "kept": 0, "builtin": $0.builtin] as [String: Any] }
        var raw: [(Int, String, String, String, String, String, String)] = []   // index source, titre, lien, date, description, encodé, image
        let g = DispatchGroup(); let lock = NSLock()
        for (i, sc) in srcs.enumerated() {
            g.enter()
            Thread.detachNewThread {
                defer { g.leave() }
                let r = fetchFeed(sc.url)
                lock.lock()
                per[i]["ok"] = r.ok; per[i]["detail"] = r.detail; per[i]["total"] = r.items.count
                for it in r.rich.prefix(60) { raw.append((i, it.0, it.1, it.2, it.3, it.4, it.5)) }
                lock.unlock()
            }
        }
        _ = g.wait(timeout: .now() + 20)
        lock.lock(); let got = raw; var perOut = per; lock.unlock()
        let limit = Date().addingTimeInterval(-Double(max(1, min(days, 90))) * 86400)
        var items: [[String: Any]] = []; var seen = Set<String>(); var outZone = 0, stale = 0, dup = 0, noTheme = 0
        var themeCount: [String: Int] = ["securite": 0, "humanitaire": 0, "financement": 0]; var countryCount: [String: Int] = [:]
        for (i, title, link, date, desc, encoded, img) in got {
            let when = parseDate(date)
            if let w = when, w < limit { stale += 1; continue }
            let key = link.isEmpty ? fold(title) : link
            if !seen.insert(key).inserted { dup += 1; continue }
            let f = fold(title)
            var countries = countryRx.filter { hit($0.1, f) }.map { $0.0 }
            let region = hit(regionRegex, f)
            if countries.isEmpty && !region { outZone += 1; continue }
            if countries.isEmpty { countries = ["Région (Afrique)"] }
            let themes = themeRx.filter { hit($0.1, f) }.map { $0.0 }
            if themes.isEmpty { noTheme += 1; continue }   // dans la zone mais ni sécurité, ni humanitaire, ni financement : pas un signal du radar
            for t in themes { themeCount[t, default: 0] += 1 }
            for c in countries { countryCount[c, default: 0] += 1 }
            perOut[i]["kept"] = ((perOut[i]["kept"] as? Int) ?? 0) + 1
            var item: [String: Any] = ["title": title, "link": link, "date": date, "ts": when?.timeIntervalSince1970 ?? 0, "source": srcs[i].name, "themes": themes, "countries": countries]
            let brief = VeillePole.briefText(desc: desc, encoded: encoded)
            if !brief.isEmpty { item["brief"] = brief }
            if !img.isEmpty { item["img"] = img }
            items.append(item)
        }
        items.sort { (($0["ts"] as? Double) ?? 0) > (($1["ts"] as? Double) ?? 0) }
        let top = countryCount.sorted { $0.value != $1.value ? $0.value > $1.value : $0.key < $1.key }
        var synth: [String] = []
        let okSrc = perOut.filter { ($0["ok"] as? Bool) == true }.count
        synth.append("\(items.count) signal(aux) retenu(s) sur \(got.count) article(s) lus dans \(okSrc) source(s) joignable(s) sur \(srcs.count) (fenêtre \(days) j ; \(outZone) hors zone, \(noTheme) sans thème radar, \(stale) trop ancien(s), \(dup) doublon(s) écartés).")
        if !items.isEmpty {
            synth.append("Thèmes (un article peut en cumuler plusieurs) : sécurité \(themeCount["securite"] ?? 0) · humanitaire \(themeCount["humanitaire"] ?? 0) · financement \(themeCount["financement"] ?? 0).")
            synth.append("Pays / zones les plus cités : " + top.prefix(5).map { "\($0.key) (\($0.value))" }.joined(separator: ", ") + ".")
            var regW = 0, regE = 0
            for (name, n) in countryCount { if esaCountries.contains(name) { regE += n } else if !name.hasPrefix("Région") { regW += n } }
            synth.append("Répartition régionale des citations de pays : WCA \(regW) · ESA \(regE).")
            for (k, label) in [("securite", "sécurité"), ("humanitaire", "humanitaire"), ("financement", "financement")] {
                if let it = items.first(where: { (($0["themes"] as? [String]) ?? []).contains(k) }) {
                    synth.append("Dernier signal \(label) : « \((it["title"] as? String) ?? "") » (\((it["source"] as? String) ?? ""), \((it["date"] as? String) ?? "date n/c")).")
                }
            }
        }
        return ["generated": nowISO(), "window_days": days, "sources": perOut, "items": Array(items.prefix(120)),
                "counts": ["themes": themeCount, "countries": countryCount.map { ["name": $0.key, "n": $0.value] as [String: Any] }.sorted { ($0["n"] as? Int ?? 0) > ($1["n"] as? Int ?? 0) },
                           "read": got.count, "kept": items.count, "out_of_zone": outZone, "no_theme": noTheme, "stale": stale, "duplicates": dup],
                "synthese": synth, "limits": "Classement par mots-clés sur les titres uniquement ; le brief de chaque carte est la description fournie par le flux, nettoyée — pas une analyse. Un signal est un indice à vérifier à la source."]
    }

    // MARK: BRVM
    nonisolated(unsafe) static var quoteCache: (at: Date, q: [String: (price: Double, var: Double)])? = nil
    static let quoteLock = NSLock()
    /// LOT3 (25/10) : crochet appelé après chaque relevé RÉEL des cours (jamais sur le cache) — posé par brvmAlertesRoutes.
    nonisolated(unsafe) static var onFresh: (([String: (price: Double, var: Double)]) -> Void)? = nil
    /// Cours du bandeau public brvm.org (cache 60 s). En cas d'échec : derniers cours connus + message, ou rien.
    static func quotes() -> (q: [String: (price: Double, var: Double)], at: Date?, err: String?) {
        quoteLock.lock(); let c = quoteCache; quoteLock.unlock()
        if let c = c, Date().timeIntervalSince(c.at) < 60 { return (c.q, c.at, nil) }
        let (st, html) = Tools.get("https://www.brvm.org/fr/cours-actions/0", timeout: 15)
        if st == 200 {
            let q = PortfolioParser.parseQuotes(html)
            if !q.isEmpty { quoteLock.lock(); quoteCache = (Date(), q); quoteLock.unlock(); onFresh?(q); return (q, Date(), nil) }   // LOT3 : alertes + historique relevé (Feat_BRVMAlertes.swift)
            return (c?.q ?? [:], c?.at, "cours BRVM illisibles (la page publique a changé de format)")
        }
        return (c?.q ?? [:], c?.at, "BRVM injoignable (\(st == 0 ? "réseau ou délai" : "HTTP \(st)"))")
    }
    static func companyName(_ sym: String) -> String {
        guard let n = PortfolioParser.symbols.first(where: { $0.1 == sym })?.0 else { return sym }
        return n.capitalized
    }
    static func brvm() -> [String: Any] {
        let (q, at, err) = quotes()
        let c = cfg.read(default: [String: Any]())
        let rows: [[String: Any]] = q.keys.sorted().map { ["sym": $0, "name": companyName($0), "price": q[$0]!.price, "var": q[$0]!.var] }
        var o: [String: Any] = ["quotes": rows, "watch": (c["watch"] as? [String]) ?? [], "dividends": (c["dividends"] as? [[String: Any]]) ?? [],
                                "source": "brvm.org (bandeau public des cours, peut être différé)", "generated": nowISO(),
                                "disclaimer": "Information et simulation uniquement — ni conseil d'investissement, ni recommandation, ni exécution d'ordre. Les dividendes affichés sont ceux que tu as saisis."]
        if let at = at { o["quotes_at"] = ISO8601DateFormatter().string(from: at) }
        if let e = err { o["error"] = e }
        return o
    }

    static func isDate(_ s: String) -> Bool { s.range(of: #"^\d{4}-\d{2}-\d{2}$"#, options: .regularExpression) != nil }
    static func saveConfig(_ j: [String: Any]) -> [String: Any] {
        cfgLock.lock(); defer { cfgLock.unlock() }
        var c = cfg.read(default: [String: Any]())
        if let w = j["watch"] as? [String] {
            var seen = Set<String>(); var out: [String] = []
            for s in w.map({ $0.trimmingCharacters(in: .whitespaces).uppercased() }) where s.range(of: #"^[A-Z0-9]{2,8}$"#, options: .regularExpression) != nil && seen.insert(s).inserted { out.append(s) }
            c["watch"] = Array(out.prefix(60))
        }
        if let d = j["dividends"] as? [[String: Any]] {
            var out: [[String: Any]] = []
            for e in d.prefix(200) {
                let sym = ((e["sym"] as? String) ?? "").trimmingCharacters(in: .whitespaces).uppercased()
                let amt = (e["amount"] as? NSNumber)?.doubleValue ?? Double(((e["amount"] as? String) ?? "").replacingOccurrences(of: ",", with: ".")) ?? 0
                let date = ((e["date"] as? String) ?? "").trimmingCharacters(in: .whitespaces)
                guard sym.range(of: #"^[A-Z0-9]{2,8}$"#, options: .regularExpression) != nil, amt > 0, amt <= 1_000_000, date.isEmpty || isDate(date) else { continue }
                out.append(["sym": sym, "amount": amt, "date": date, "note": String(((e["note"] as? String) ?? "").prefix(120))])
            }
            c["dividends"] = out
        }
        if let r = j["radar_extra"] as? [String] {
            c["radar_extra"] = Array(r.map { $0.trimmingCharacters(in: .whitespaces) }.filter { s in
                guard let u = URL(string: s), let h = u.host, u.scheme == "https" || u.scheme == "http" else { return false }; return !Tools.isInternalHost(h) }.prefix(20))
        }
        cfg.write(c)
        return c
    }

    // MARK: texte du briefing
    static func upcomingDividends(_ c: [String: Any], within days: Int = 45) -> [[String: Any]] {
        let today = String(nowISO().prefix(10)); let end = String(ISO8601DateFormatter().string(from: Date().addingTimeInterval(Double(days) * 86400)).prefix(10))
        return (((c["dividends"] as? [[String: Any]]) ?? []).filter { let d = ($0["date"] as? String) ?? ""; return !d.isEmpty && d >= today && d <= end }).sorted { (($0["date"] as? String) ?? "") < (($1["date"] as? String) ?? "") }
    }
    static func stripForSpeech(_ t: String) -> String {
        var s = t.replacingOccurrences(of: #"\[([^\]]+)\]\([^)]*\)"#, with: "$1", options: .regularExpression)
        s = s.replacingOccurrences(of: #"[#*_`>|]"#, with: "", options: .regularExpression)
        s = s.replacingOccurrences(of: #"(?m)^\s*[-•]\s+"#, with: "", options: .regularExpression)
        return s.replacingOccurrences(of: #"\s*\n+\s*"#, with: ". ", options: .regularExpression).replacingOccurrences(of: #"\.\s*\."#, with: ".", options: .regularExpression).trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

extension NovaApp {
    func veilleRoutes() {
        let s = server
        s.on("GET", "/api/veille/radar") { [self] req, res in
            let r = VeillePole.radar(settings: settings, days: Int(req.query["days"] ?? "") ?? 21)
            res.json(r)
            VeillePole.rememberRadar(r)   // V4-C : dernier relevé réel du radar (carte thermique et pays des unités de Feeds)
            // BUILD-FEED-DIRECT vague 1 (§A.5.2) : chaque collecte du radar propose
            // ses signaux à la passe de sélection-rédaction du Feed — en fil détaché
            // (la réponse du radar n'attend jamais le cerveau) ; la garde de
            // signature de la passe rend les collectes répétées sans effet.
            let items = (r["items"] as? [[String: Any]]) ?? []
            let failed = ((r["sources"] as? [[String: Any]]) ?? []).filter { ($0["ok"] as? Bool) != true }.map { ($0["name"] as? String) ?? "?" }
            let rt = router, st = settings
            Thread.detachNewThread { FeedUnits.radarPass(router: rt, settings: st, items: items, failed: failed) }
        }
        // DIAG2-VEILLE : extraction d'UN article pour le dépliage « Lire » du feed —
        // même code et mêmes gardes que l'outil web_fetch (Tools.swift) : la page est
        // lue par le moteur, le texte revient nettoyé ; la page entière, elle, s'ouvre
        // dans le volet Navigateur (jamais dans le navigateur système).
        s.on("GET", "/api/veille/article") { req, res in
            let u = (req.query["url"] ?? "").trimmingCharacters(in: .whitespaces)
            guard let url = URL(string: u), let host = url.host, (url.scheme == "https" || url.scheme == "http"),
                  !Tools.isInternalHost(host), !Tools.resolvesInternal(host) else { res.json(["ok": false, "error": "adresse refusée (hôte interne ou invalide)"]); return }
            let (st, body) = Tools.get(u, timeout: 15)
            guard st == 200 else { res.json(["ok": false, "error": st == 0 ? "page injoignable (réseau ou délai ; 15 s)" : "page inaccessible (HTTP \(st))"]); return }
            func meta(_ prop: String) -> String {
                guard let rx = try? NSRegularExpression(pattern: "<meta[^>]+(?:property|name)=[\"']\(prop)[\"'][^>]+content=[\"']([^\"']+)[\"']", options: [.caseInsensitive]),
                      let m = rx.firstMatch(in: body, range: NSRange(location: 0, length: (body as NSString).length)) else { return "" }
                return (body as NSString).substring(with: m.range(at: 1))
            }
            res.json(["ok": true, "url": u, "title": meta("og:title"), "img": meta("og:image"), "text": Tools.htmlToText(body, limit: 20000)])
        }
        s.on("GET", "/api/veille/brvm") { _, res in res.json(VeillePole.brvm()) }
        s.on("POST", "/api/veille/config") { req, res in
            let c = VeillePole.saveConfig(req.json); res.json(["ok": true, "config": c])
        }
        s.on("GET", "/api/veille/briefing") { _, res in
            let l = VeillePole.briefingFile.read(default: [[String: Any]]()); res.json(["item": l.last.map { $0 as Any } ?? NSNull(), "count": l.count] as [String: Any])
        }
        s.on("POST", "/api/veille/briefing") { [self] _, res in res.json(veilleBriefing()) }
        feedsRoutes(); prewarmFeedsOverview()   // V4-C (24/10) : onglet Feeds (ex-Veille) — /api/feeds/overview|feedback|pin
    }

    /// Briefing Exécutif Matinal : agenda + rappels + météo + radar + BRVM + dividendes saisis. Le cerveau rédige à partir de ces SEULES données ; sinon données brutes, dites comme telles.
    func veilleBriefing() -> [String: Any] {
        var src: [SourceData] = []; let lock = NSLock(); let g = DispatchGroup()
        func add(_ f: @escaping () -> SourceData) { g.enter(); Thread.detachNewThread { let r = f(); lock.lock(); src.append(r); lock.unlock(); g.leave() } }
        add { self.briefs.weather() }
        add { self.briefs.osaSource("Agenda (Calendar.app)", "calendar") }
        add { self.briefs.osaSource("Rappels (Reminders.app)", "reminders") }
        var radar: [String: Any] = [:]; var bv: [String: Any] = [:]
        g.enter(); Thread.detachNewThread { let r = VeillePole.radar(settings: self.settings, days: 7); lock.lock(); radar = r; lock.unlock(); g.leave() }
        g.enter(); Thread.detachNewThread { let r = VeillePole.brvm(); lock.lock(); bv = r; lock.unlock(); g.leave() }
        let done = g.wait(timeout: .now() + 70) == .success
        lock.lock(); var sources = src; let radarD = radar, bvD = bv; lock.unlock()
        for n in ["Météo (Open-Meteo)", "Agenda (Calendar.app)", "Rappels (Reminders.app)"] where !sources.contains(where: { $0.name == n }) {
            sources.append(SourceData(name: n, ok: false, text: "délai dépassé (\(done ? "" : "70 s")) — la source n'a pas répondu"))
        }
        // Radar
        let rSrc = (radarD["sources"] as? [[String: Any]]) ?? []
        let rItems = (radarD["items"] as? [[String: Any]]) ?? []
        if radarD.isEmpty { sources.append(SourceData(name: "Radar Afrique", ok: false, text: "délai dépassé")) }
        else {
            let bad = rSrc.filter { ($0["ok"] as? Bool) != true }.map { "\($0["name"] ?? "?") : \($0["detail"] ?? "")" }
            var t = ((radarD["synthese"] as? [String]) ?? []).joined(separator: "\n")
            // Parade anti-bruit (extension ESA) : les items transmis au brief sont QUOTÉS par région —
            // au plus 6 WCA et 4 ESA sur les 10, items déjà triés du plus récent au plus ancien.
            // Sans quota, le volume ESA pourrait remplir seul la fenêtre et évincer le Sahel, priorité CAFU.
            func itemRegion(_ it: [String: Any]) -> String { VeillePole.region(of: ((it["countries"] as? [String]) ?? []).first ?? "") }
            func sigLine(_ it: [String: Any]) -> String { "- \(it["title"] ?? "") [\(it["source"] ?? ""), \(it["date"] ?? "date n/c")] thèmes: \(((it["themes"] as? [String]) ?? []).joined(separator: "/"))" }
            var picked: [[String: Any]] = []; var nW = 0, nE = 0
            for it in rItems {
                if itemRegion(it) == "esa" { if nE < 4 { picked.append(it); nE += 1 } } else if nW < 6 { picked.append(it); nW += 1 }
                if picked.count >= 10 { break }
            }
            let wItems = picked.filter { itemRegion($0) != "esa" }, eItems = picked.filter { itemRegion($0) == "esa" }
            t += "\nSignaux récents — Afrique de l'Ouest & Centre / Sahel (priorité CAFU) :\n" + (wItems.isEmpty ? "(aucun signal retenu)" : wItems.map(sigLine).joined(separator: "\n"))
            t += "\nSignaux récents — Afrique de l'Est & australe :\n" + (eItems.isEmpty ? "(aucun signal retenu)" : eItems.map(sigLine).joined(separator: "\n"))
            if !bad.isEmpty { t += "\nSources injoignables : " + bad.joined(separator: " ; ") }
            sources.append(SourceData(name: "Radar Afrique (flux publics)", ok: rSrc.contains { ($0["ok"] as? Bool) == true } && !rItems.isEmpty, text: rItems.isEmpty ? "aucun signal retenu. " + t : t))
        }
        // BRVM
        let cfgNow = VeillePole.cfg.read(default: [String: Any]())
        if bvD.isEmpty { sources.append(SourceData(name: "BRVM (cours publics)", ok: false, text: "délai dépassé")) }
        else {
            let rows = (bvD["quotes"] as? [[String: Any]]) ?? []
            if rows.isEmpty { sources.append(SourceData(name: "BRVM (cours publics)", ok: false, text: (bvD["error"] as? String) ?? "aucun cours")) }
            else {
                let watch = (bvD["watch"] as? [String]) ?? []
                func line(_ r: [String: Any]) -> String { "\(r["sym"] ?? "") (\(r["name"] ?? "")) : \(Int((r["price"] as? Double) ?? 0)) FCFA, variation \(String(format: "%+.2f", (r["var"] as? Double) ?? 0)) %" }
                var t: String
                let w = rows.filter { watch.contains(($0["sym"] as? String) ?? "") }
                if !w.isEmpty { t = "Valeurs suivies par l'utilisateur :\n" + w.map { "- " + line($0) }.joined(separator: "\n") }
                else {
                    let sorted = rows.sorted { (($0["var"] as? Double) ?? 0) > (($1["var"] as? Double) ?? 0) }
                    t = "Aucune valeur suivie ; plus fortes variations du bandeau (\(rows.count) valeurs) :\nHausses :\n" + sorted.prefix(3).map { "- " + line($0) }.joined(separator: "\n") + "\nBaisses :\n" + sorted.suffix(3).reversed().map { "- " + line($0) }.joined(separator: "\n")
                }
                let dv = VeillePole.upcomingDividends(cfgNow)
                if !dv.isEmpty { t += "\nDividendes saisis par l'utilisateur à venir (45 j) :\n" + dv.map { "- \($0["sym"] ?? "") : \(Int(($0["amount"] as? Double) ?? 0)) FCFA/action le \($0["date"] ?? "") \($0["note"] ?? "")" }.joined(separator: "\n") }
                if let e = bvD["error"] as? String { t += "\n(Attention : \(e) — cours possiblement anciens.)" }
                sources.append(SourceData(name: "BRVM (cours publics brvm.org)", ok: bvD["error"] == nil, text: t))
            }
        }
        let order = ["Météo (Open-Meteo)", "Agenda (Calendar.app)", "Rappels (Reminders.app)", "Radar Afrique (flux publics)", "Radar Afrique", "BRVM (cours publics brvm.org)", "BRVM (cours publics)"]
        sources.sort { (order.firstIndex(of: $0.name) ?? 9) < (order.firstIndex(of: $1.name) ?? 9) }

        let df = DateFormatter(); df.locale = Locale(identifier: "fr_FR"); df.dateFormat = "EEEE d MMMM yyyy, HH:mm"
        let data = sources.map { "### \($0.name)\($0.ok ? "" : " — INDISPONIBLE")\n\($0.text)" }.joined(separator: "\n\n")
        let sys = Persona.system(title: settings.get("user_title", "Capitaine"), memory: "", voice: false, tools: false,
            extra: "TÂCHE : rédige le BRIEFING EXÉCUTIF MATINAL de l'utilisateur à partir des SEULES données fournies. Structure Markdown : un titre ; 1) Agenda du jour ; 2) Radar humanitaire Afrique : les signaux fournis sont déjà séparés en deux blocs régionaux — présente d'abord l'Afrique de l'Ouest & le Sahel (priorité), puis l'Afrique de l'Est & australe ; 3 signaux maximum PAR RÉGION, avec la source ; si un bloc est vide, écris en une ligne qu'il n'y a aucun signal pour cette région plutôt que de le remplir avec ceux de l'autre ; 3) BRVM : faits uniquement (cours, variations, dividendes saisis) — JAMAIS de conseil d'achat, de vente ou de conservation, ni de prévision ; 4) À traiter aujourd'hui (rappels). Pour chaque source marquée INDISPONIBLE, écris une seule ligne disant laquelle et pourquoi. Aucun chiffre ni fait hors des données ; cite la source entre parenthèses. Termine par un bloc <PARLE>…</PARLE> : version ORALE de 120 à 180 mots, phrases courtes, sans markdown ni symbole, nombres écrits comme on les dit, qui reprend l'essentiel et rappelle que la partie BRVM est de l'information et non un conseil.")
        let det = router.completeDetailed(messages: [ChatMsg("user", "Nous sommes le \(df.string(from: Date())).\n\nDONNÉES RÉELLES COLLECTÉES :\n\n\(data)")], system: sys, mode: "fast", preferred: settings.get("brain", "spark-1.3"), maxTokens: 4000, deadline: 120, solo: true)   // APPLY-BRIEFS H1+H2+H3 : cerveau verrouillé épinglé (avant : preferred absent), plafond 1 400 → 4 000, date-butoir de fond 120 s · REVUE-GATE 22/10 : solo: true adopté — même épinglage réel que radarPass (FIX-RADAR), la passe autonome ne peut plus être servie par la chaîne ni le filet local
        let res = det.result
        var text: String, parle = "", brain: String, llm = false
        if let r = res {
            llm = true; brain = router.spec(r.brain)?.label ?? r.brain; text = r.text
            if let rx = try? NSRegularExpression(pattern: #"<PARLE>([\s\S]*?)</PARLE>"#, options: [.caseInsensitive]) {
                let ns = text as NSString
                if let m = rx.firstMatch(in: text, range: NSRange(location: 0, length: ns.length)) {
                    parle = ns.substring(with: m.range(at: 1)).trimmingCharacters(in: .whitespacesAndNewlines)
                    text = rx.stringByReplacingMatches(in: text, range: NSRange(location: 0, length: ns.length), withTemplate: "").trimmingCharacters(in: .whitespacesAndNewlines)
                }
            }
            if let i = text.range(of: "<PARLE>", options: .caseInsensitive) { text = String(text[..<i.lowerBound]).trimmingCharacters(in: .whitespacesAndNewlines) }   // balise non refermée
            if parle.isEmpty { parle = String(VeillePole.stripForSpeech(text).prefix(900)) }
        } else {
            brain = "aucun (synthèse non produite)"   // APPLY-BRIEFS H4 : cf. Briefs.swift — le motif réel est conservé dans l'item (champ err)
            text = "**Briefing exécutif — données brutes** (synthèse non produite : \(det.error ?? "aucun cerveau n'a répondu") ; note non rédigée)\n\n" + data
            parle = ""
        }
        let item: [String: Any] = ["id": UUID().uuidString.prefix(8).lowercased().description, "ts": nowISO(), "title": "Briefing Exécutif Matinal", "text": text, "parle": parle,
                                   "brain": brain, "llm": llm, "err": det.error ?? "", "sources": sources.map { $0.asDict() }]   // APPLY-BRIEFS H4 : motif réel de l'échec conservé avec l'item
        var l = VeillePole.briefingFile.read(default: [[String: Any]]()); l.append(item); VeillePole.briefingFile.write(Array(l.suffix(30)))
        // BUILD-FEED-DIRECT vague 1 (§A.5.2) : le radar fraîchement collecté pour ce
        // briefing alimente aussi la passe de rédaction du Feed (fil détaché).
        let failedNames = rSrc.filter { ($0["ok"] as? Bool) != true }.map { ($0["name"] as? String) ?? "?" }
        let rt = router, st = settings
        Thread.detachNewThread { FeedUnits.radarPass(router: rt, settings: st, items: rItems, failed: failedNames) }
        return item
    }
}

// MARK: - V4-C (24/10/2026) — onglet FEEDS (ex-Veille), Bloc 3 du cahier d'Ahadi
//
// Le web compose l'écran ; le moteur fournit ici UNIQUEMENT des faits relevés :
//  - pôle de chaque unité (vocabulaire fermé : fundings, wca, esa, brvm, decisions, pulses, autre) ;
//  - pays de l'unité (dernier relevé réel du radar, sinon les titres) ;
//  - « Pourquoi ça compte pour toi » : liens vers des faits RÉELS (mémoire des projets, mémoire de Nova
//    datée, programmes de la campagne Fundings, lignes BRVM suivies) — absent quand rien ne se relie ;
//  - poids source/thème appris des 👍/👎 (feeds_weights.json) ;
//  - activité réelle (Éclats, passes radar, cours BRVM en cache, Fundings), horodatages du moteur ;
//  - échéances Fundings + Engagements, carte thermique par pays.
// Aucun appel réseau dans la vue d'ensemble : elle ne lit que des magasins et des caches.

extension VeillePole {
    static let radarLast: JSONFile = JSONFile("veille_radar_last.json")
    static let weightsFile: JSONFile = JSONFile("feeds_weights.json")
    static let weightsLock: NSLock = NSLock()
    static let poles: [String] = ["fundings", "wca", "esa", "brvm", "decisions", "pulses"]
    static let focusCountries: [String] = ["Burkina Faso", "Mali", "Niger", "RD Congo", "Soudan", "Éthiopie", "Somalie"]

    /// Dernier relevé du radar : comptes par pays et pays de chaque lien (pour relier les unités rédigées).
    static func rememberRadar(_ r: [String: Any]) {
        let items: [[String: Any]] = (r["items"] as? [[String: Any]]) ?? []
        var links: [String: [String]] = [:]
        for it in items.prefix(160) {
            if let l = it["link"] as? String, !l.isEmpty { links[l] = (it["countries"] as? [String]) ?? [] }
        }
        let counts: [String: Any] = (r["counts"] as? [String: Any]) ?? [:]
        let srcs: [[String: Any]] = (r["sources"] as? [[String: Any]]) ?? []
        let okN: Int = srcs.filter { ($0["ok"] as? Bool) == true }.count
        radarLast.write(["generated": (r["generated"] as? String) ?? nowISO(), "window_days": (r["window_days"] as? Int) ?? 0,
                         "countries": (counts["countries"] as? [[String: Any]]) ?? [], "links": links,
                         "read": (counts["read"] as? Int) ?? 0, "kept": (counts["kept"] as? Int) ?? 0,
                         "sources_ok": okN, "sources_total": srcs.count] as [String: Any])
    }

    static func countriesIn(_ text: String) -> [String] {
        let f: String = fold(text)
        return countryRx.filter { hit($0.1, f) }.map { $0.0 }
    }

    static let brvmRx: NSRegularExpression = try! NSRegularExpression(pattern: #"\bbrvm\b|\bsbif\b|bourse r[eé]gionale|\buemoa\b.*(?:march|bourse)|sonatel|orange c[oô]te|\bsgbci\b|ecobank|\bfcfa\b.*(?:action|cours)"#, options: [.caseInsensitive])

    /// Pôle d'une unité du journal (vocabulaire fermé, règles fermées — aucun cerveau).
    static func pole(of u: [String: Any], countries: [String]) -> String {
        let kicker: String = ((u["kicker"] as? String) ?? "").uppercased()
        let origin: String = (u["origin"] as? String) ?? ""
        if origin == "fundings" { return "fundings" }
        let text: String = ((u["title"] as? String) ?? "") + " " + ((u["standfirst"] as? String) ?? "")
        if kicker.contains("BRVM") || hit(brvmRx, text) { return "brvm" }
        if (((u["action"] as? [String: Any])?["type"] as? String) ?? "") == "decision" || kicker == "ALERTE" { return "decisions" }
        if ["BRIEF DU MATIN", "POINT DE MI-JOURNÉE", "FERMETURE DU SOIR"].contains(kicker) { return "pulses" }
        if kicker == "AFRIQUE DE L'EST" { return "esa" }
        if kicker == "SAHEL" || kicker == "AFRIQUE DE L'OUEST" { return "wca" }
        let real: [String] = countries.filter { !$0.hasPrefix("Région") }
        if let c = real.first { return region(of: c) }
        return "autre"
    }

    static func weights() -> [String: Any] {
        weightsLock.lock(); defer { weightsLock.unlock() }
        return weightsFile.read(default: [String: Any]())
    }
    /// 👍/👎 : ±1 sur la source ET sur le pôle (bornes −5…+5) ; même signal répété = retrait (bascule).
    static func feedback(id: String, source: String, theme: String, signal: String) -> [String: Any] {
        weightsLock.lock(); defer { weightsLock.unlock() }
        var w: [String: Any] = weightsFile.read(default: [String: Any]())
        var votes: [String: String] = (w["votes"] as? [String: String]) ?? [:]
        var src: [String: Int] = (w["sources"] as? [String: Int]) ?? [:]
        var th: [String: Int] = (w["themes"] as? [String: Int]) ?? [:]
        let prev: String = votes[id] ?? ""
        let next: String = (signal == prev) ? "" : signal
        func delta(_ v: String) -> Int { v == "up" ? 1 : (v == "down" ? -1 : 0) }
        let d: Int = delta(next) - delta(prev)
        if d != 0 {
            if !source.isEmpty { src[source] = max(-5, min(5, (src[source] ?? 0) + d)) }
            if !theme.isEmpty { th[theme] = max(-5, min(5, (th[theme] ?? 0) + d)) }
        }
        if next.isEmpty { votes.removeValue(forKey: id) } else { votes[id] = next }
        if votes.count > 2000 { votes = [:] }
        w["votes"] = votes; w["sources"] = src; w["themes"] = th; w["updated"] = nowISO()
        weightsFile.write(w)
        return ["ok": true, "signal": next, "source_weight": src[source] ?? 0, "theme_weight": th[theme] ?? 0]
    }

    /// « Pourquoi ça compte pour toi » : seulement des liens vers des faits réels ; [] sinon (l'encadré est alors absent).
    struct FoldedFact { let text: String; let ts: String; let folded: String }
    // 01/11 : noms de projets / programmes repliés une fois (le repliement fr_FR coûte, et il était refait pour chaque unité).
    nonisolated(unsafe) static var foldMemoMap: [String: String] = [:]
    static let foldMemoLock: NSLock = NSLock()
    static func foldMemo(_ s: String) -> String {
        foldMemoLock.lock(); if let v = foldMemoMap[s] { foldMemoLock.unlock(); return v }; foldMemoLock.unlock()
        let v: String = fold(s)
        foldMemoLock.lock(); if foldMemoMap.count > 5000 { foldMemoMap.removeAll() }; foldMemoMap[s] = v; foldMemoLock.unlock()
        return v
    }
    static func prefoldFacts(_ facts: [[String: Any]]) -> [FoldedFact] {
        facts.compactMap { (f: [String: Any]) -> FoldedFact? in
            let t: String = (f["text"] as? String) ?? ""
            guard !Memory.isSensitive(t) else { return nil }
            return FoldedFact(text: t, ts: (f["ts"] as? String) ?? "", folded: fold(t))
        }
    }
    static func impact(_ u: [String: Any], countries: [String], facts: [[String: Any]], projects: [String],
                       programmes: [[String: Any]], watch: [String], folded: [FoldedFact]? = nil) -> [[String: Any]] {
        let raw: String = ["title", "standfirst", "body", "keys"].map { (k: String) -> String in (u[k] as? String) ?? "" }.joined(separator: " ")
        let text: String = fold(raw)
        var out: [[String: Any]] = []
        var seen: Set<String> = []
        func add(_ dossier: String, _ fait: String, _ src: String, _ date: String = "") {
            guard out.count < 3, !seen.contains(dossier) else { return }
            seen.insert(dossier)
            var o: [String: Any] = ["dossier": dossier, "fait": fait, "src": src]
            if !date.isEmpty { o["date"] = date }
            out.append(o)
        }
        func wordHit(_ needle: String) -> Bool {
            let fn: String = VeillePole.foldMemo(needle)
            guard text.contains(fn) else { return false }   // 01/11 : filtre par sous-chaîne avant la regex — 37 s mesurés sur 200 unités sans lui
            let n: String = NSRegularExpression.escapedPattern(for: fn)
            return text.range(of: "\\b" + n + "\\b", options: .regularExpression) != nil
        }
        for nom in projects where nom.count >= 4 && wordHit(nom) {
            add(nom, "Dossier suivi dans ta mémoire des projets.", "projets")
        }
        for p in programmes {
            let name: String = (p["programme"] as? String) ?? ""
            let id: String = (p["id"] as? String) ?? ""
            if (name.count >= 5 && wordHit(name)) || (id.count >= 6 && !id.contains("-") && wordHit(id)) {
                add("Campagne Fundings", name + " — " + String(((p["statut"] as? String) ?? "").prefix(120)), "fundings")
            }
        }
        // 01/11 : faits filtrés (sensibles écartés) et repliés UNE fois par calcul (prefoldFacts), pas par unité —
        // 200 unités × 300 faits × regex de sensibilité dépassaient le délai de 20 s de l'Accueil.
        let usable: [FoldedFact] = folded ?? VeillePole.prefoldFacts(facts)
        for c in countries where !c.hasPrefix("Région") {
            let fc: String = fold(c)
            if let f = usable.last(where: { $0.folded.contains(fc) }) {
                add(c, String(f.text.prefix(180)), "mémoire", String(f.ts.prefix(10)))
            }
        }
        for kw in ["gho 2027", "gho", "hrp", "cerf", "soudan 2030", "sbif"] where text.contains(kw) {
            if let f = usable.last(where: { $0.folded.contains(kw) }) {
                add(kw.uppercased(), String(f.text.prefix(180)), "mémoire", String(f.ts.prefix(10)))
            }
        }
        let up: String = raw.uppercased()
        for sym in watch where up.contains(sym) && up.range(of: "\\b" + NSRegularExpression.escapedPattern(for: sym) + "\\b", options: .regularExpression) != nil {
            add("BRVM", "Ligne suivie : " + sym, "brvm")
        }
        return out
    }
}

extension NovaApp {
    func feedsRoutes() {
        let s = server
        s.on("GET", "/api/feeds/overview") { [self] _, res in res.json(feedsOverview()) }
        s.on("POST", "/api/feeds/feedback") { req, res in
            let j: [String: Any] = req.json
            let id: String = String(((j["id"] as? String) ?? "").prefix(200))
            let sig: String = (j["signal"] as? String) ?? ""
            guard !id.isEmpty, sig == "up" || sig == "down" else { res.json(["error": "id et signal (up|down) requis"], status: 400); return }
            res.json(VeillePole.feedback(id: id, source: String(((j["source"] as? String) ?? "").prefix(120)),
                                         theme: String(((j["theme"] as? String) ?? "").prefix(40)), signal: sig))
        }
        s.on("POST", "/api/feeds/pin") { req, res in
            let j: [String: Any] = req.json
            let id: String = (j["id"] as? String) ?? ""
            guard !id.isEmpty else { res.json(["error": "id requis"], status: 400); return }
            let on: Bool = (j["pinned"] as? Bool) ?? true
            res.json(["ok": FeedUnits.setUserPin(id, on), "pinned": on])
        }
    }

    // Cache court (15 s) : le calcul complet (135 unités enrichies d'impacts) prenait 3,5 s mesurés à chaque
    // affichage d'Accueil, Veille ou Peek. Votes et épingles restent visibles sous 15 s.
    static var feedsOverviewCache: (at: Date, value: [String: Any])? = nil
    static let feedsOverviewLock: NSLock = NSLock()

    /// Vue d'ensemble de Feeds : uniquement des magasins et des caches (aucun appel réseau, aucun cerveau).
    // 01/11 : « Feeds injoignable — délai dépassé (20 s) ». Servir le dernier calcul tout de suite (même ancien)
    // et recalculer en arrière-plan, un seul calcul à la fois ; seul le tout premier appel attend.
    static var feedsOverviewComputing: Bool = false
    static func feedsTimingWrite(_ tm: [[String: Any]], units: Int, facts: Int) {
        let o: [String: Any] = ["ts": ISO8601DateFormatter().string(from: Date()), "etapes": tm, "unites": units, "faits": facts]
        if let d = try? JSONSerialization.data(withJSONObject: o, options: [.prettyPrinted]) {
            try? d.write(to: Paths.diagFile("feeds_overview_timing.json"))
        }
    }
    func feedsOverview() -> [String: Any] {
        NovaApp.feedsOverviewLock.lock()
        if let c: (at: Date, value: [String: Any]) = NovaApp.feedsOverviewCache {
            let stale: Bool = Date().timeIntervalSince(c.at) >= 15
            let launch: Bool = stale && !NovaApp.feedsOverviewComputing
            if launch { NovaApp.feedsOverviewComputing = true }
            NovaApp.feedsOverviewLock.unlock()
            if launch {
                DispatchQueue.global(qos: .utility).async { [self] in
                    _ = self.computeFeedsOverview()
                    NovaApp.feedsOverviewLock.lock(); NovaApp.feedsOverviewComputing = false; NovaApp.feedsOverviewLock.unlock()
                }
            }
            return c.value
        }
        NovaApp.feedsOverviewLock.unlock()
        return computeFeedsOverview()
    }
    /// Préchauffe le cache au démarrage pour que le premier affichage d'Accueil n'attende pas.
    func prewarmFeedsOverview() {
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 3) { [self] in
            NovaApp.feedsOverviewLock.lock()
            let skip: Bool = NovaApp.feedsOverviewCache != nil || NovaApp.feedsOverviewComputing
            if !skip { NovaApp.feedsOverviewComputing = true }
            NovaApp.feedsOverviewLock.unlock()
            guard !skip else { return }
            _ = self.computeFeedsOverview()
            NovaApp.feedsOverviewLock.lock(); NovaApp.feedsOverviewComputing = false; NovaApp.feedsOverviewLock.unlock()
        }
    }
    func computeFeedsOverview() -> [String: Any] {
        var tm: [[String: Any]] = [["etape": "debut", "ms": 0]]; var t0: Date = Date()
        NovaApp.feedsTimingWrite(tm, units: -1, facts: -1)
        func mark(_ n: String) { tm.append(["etape": n, "ms": Int(Date().timeIntervalSince(t0) * 1000)]); t0 = Date(); NovaApp.feedsTimingWrite(tm, units: -1, facts: -1) }   // écrit à chaque étape : une étape bloquée reste visible
        let now: Date = Date()
        let iso: ISO8601DateFormatter = ISO8601DateFormatter()
        let radar: [String: Any] = VeillePole.radarLast.read(default: [String: Any]())
        mark("radar")
        let links: [String: [String]] = (radar["links"] as? [String: [String]]) ?? [:]
        let w: [String: Any] = VeillePole.weights()
        let wSrc: [String: Int] = (w["sources"] as? [String: Int]) ?? [:]
        let wTh: [String: Int] = (w["themes"] as? [String: Int]) ?? [:]
        let votes: [String: String] = (w["votes"] as? [String: String]) ?? [:]
        let facts: [[String: Any]] = Array(tools.memory.list().suffix(300))
        let foldedFacts: [VeillePole.FoldedFact] = VeillePole.prefoldFacts(facts)
        mark("memoire")
        let projects: [String] = ProjectMemory.items().compactMap { (p: [String: Any]) -> String? in
            let n: String = ((p["nom"] as? String) ?? "").trimmingCharacters(in: .whitespacesAndNewlines); return n.isEmpty ? nil : n
        }
        let fund: [String: Any] = Fundings.state()
        mark("fundings")
        let programmes: [[String: Any]] = ((fund["acquis"] as? [[String: Any]]) ?? []) + ((fund["en_attente"] as? [[String: Any]]) ?? []) + ((fund["clos"] as? [[String: Any]]) ?? [])
        let watch: [String] = (VeillePole.cfg.read(default: [String: Any]())["watch"] as? [String]) ?? []
        mark("watch")

        // Unités du journal, enrichies (pôle, pays, impact, poids).
        var unread: [String: Int] = [:]
        var units: [[String: Any]] = []
        for var u in FeedUnits.list() {
            let link: String = (u["link"] as? String) ?? (u["originRef"] as? String) ?? ""
            var countries: [String] = links[link] ?? []
            if countries.isEmpty { countries = VeillePole.countriesIn(((u["title"] as? String) ?? "") + " " + ((u["standfirst"] as? String) ?? "")) }
            let pole: String = VeillePole.pole(of: u, countries: countries)
            let srcName: String = (((u["sources"] as? [[String: Any]]) ?? []).first?["name"] as? String) ?? ""
            u["pole"] = pole
            u["countries"] = countries
            u["weight"] = (wSrc[srcName] ?? 0) + (wTh[pole] ?? 0)
            if let v = votes[(u["id"] as? String) ?? ""] { u["vote"] = v }
            let imp: [[String: Any]] = VeillePole.impact(u, countries: countries, facts: facts, projects: projects, programmes: programmes, watch: watch, folded: foldedFacts)
            if !imp.isEmpty { u["impact"] = imp }
            if (u["read"] as? Bool) != true { unread[pole, default: 0] += 1; unread["tout", default: 0] += 1 }
            units.append(u)
        }
        // Ordre : jour décroissant ; dans le jour, épinglées (Ahadi puis briefs), puis poids appris, puis récence.
        units.sort { (a: [String: Any], b: [String: Any]) -> Bool in
            let da: String = String(((a["ts"] as? String) ?? "").prefix(10)), db: String = String(((b["ts"] as? String) ?? "").prefix(10))
            if da != db { return da > db }
            let pa: Int = ((a["user_pin"] as? Bool) == true ? 2 : 0) + ((a["pinned"] as? Bool) == true ? 1 : 0)
            let pb: Int = ((b["user_pin"] as? Bool) == true ? 2 : 0) + ((b["pinned"] as? Bool) == true ? 1 : 0)
            if pa != pb { return pa > pb }
            let wa: Int = (a["weight"] as? Int) ?? 0, wb: Int = (b["weight"] as? Int) ?? 0
            if wa != wb { return wa > wb }
            return ((a["ts"] as? String) ?? "") > ((b["ts"] as? String) ?? "")
        }
        mark("unites")
        // Fundings : événements non lus → pôle fundings (et décisions pour ACTION REQUISE).
        let fEvents: [[String: Any]] = (fund["events"] as? [[String: Any]]) ?? []
        for e in fEvents where (e["lu"] as? Bool) != true {
            unread["fundings", default: 0] += 1; unread["tout", default: 0] += 1
            if (e["categorie"] as? String) == "ACTION REQUISE" { unread["decisions", default: 0] += 1 }
        }

        // Échéances : Fundings (§4) + Engagements ouverts datés — les 3 prochaines.
        var dues: [[String: Any]] = []
        for e in ((fund["echeances"] as? [[String: Any]]) ?? []) where ((e["days_left"] as? Int) ?? -1) >= 0 {
            dues.append(["kind": "fundings", "date": (e["date"] as? String) ?? "", "heure": (e["heure"] as? String) ?? "", "label": (e["label"] as? String) ?? "",
                         "days_left": (e["days_left"] as? Int) ?? 0, "ref": (e["programme"] as? String) ?? "", "approx": (e["approx"] as? Bool) ?? false])
        }
        let commit: [String: Any] = DailyState.shared.commitFile.read(default: [String: Any]())
        mark("commit")
        for c in ((commit["items"] as? [[String: Any]]) ?? []) {
            let st: String = (c["status"] as? String) ?? "ouvert"
            let ech: String = (c["echeance"] as? String) ?? ""
            let quoi: String = (c["quoi"] as? String) ?? ""
            guard st == "ouvert", ech.count == 10, let n: Int = Fundings.daysLeft(ech, now: now), n >= 0,
                  !SecretsGuard.containsSecret(quoi) else { continue }   // V5-V (25/10) : une échéance RH est une échéance légitime ; seuls les secrets sont écartés
            dues.append(["kind": "engagement", "date": ech, "heure": "", "label": quoi, "days_left": n,
                         "ref": (c["id"] as? String) ?? "", "qui": (c["qui"] as? String) ?? "", "dir": (c["dir"] as? String) ?? ""])
        }
        dues.sort { (a: [String: Any], b: [String: Any]) -> Bool in
            (((a["date"] as? String) ?? "") + ((a["heure"] as? String) ?? "")) < (((b["date"] as? String) ?? "") + ((b["heure"] as? String) ?? ""))
        }

        // Carte thermique : pays du dernier relevé réel du radar (les pays SCI suivis toujours listés, même à 0).
        var heatMap: [String: Int] = [:]
        for c in ((radar["countries"] as? [[String: Any]]) ?? []) {
            if let n = c["name"] as? String, !n.hasPrefix("Région") { heatMap[n] = (c["n"] as? Int) ?? 0 }
        }
        var heat: [[String: Any]] = VeillePole.focusCountries.map { (c: String) -> [String: Any] in ["name": c, "n": heatMap[c] ?? 0, "region": VeillePole.region(of: c), "focus": true] }
        for (c, n) in heatMap.sorted(by: { $0.value > $1.value }) where !VeillePole.focusCountries.contains(c) && n > 0 {
            heat.append(["name": c, "n": n, "region": VeillePole.region(of: c), "focus": false])
        }

        // Activité réelle (horodatages du moteur, jamais simulés).
        var ticker: [[String: Any]] = []
        mark("heat")
        let act: [String: Any] = engagementsActivity()
        mark("activite")
        for r in ((act["running"] as? [[String: Any]]) ?? []).prefix(4) {
            ticker.append(["icon": "🟢", "label": ((r["label"] as? String) ?? (r["name"] as? String) ?? ""), "ts": (r["since"] as? String) ?? "", "live": true, "ecran": (r["ecran"] as? String) ?? ""])
        }
        for r in ((act["recent"] as? [[String: Any]]) ?? []).prefix(4) {
            let ok: Bool? = r["ok"] as? Bool
            ticker.append(["icon": ok == false ? "🟠" : "✅", "label": ((r["name"] as? String) ?? "") + " · " + ((r["label"] as? String) ?? ""), "ts": (r["ts"] as? String) ?? "", "ecran": (r["ecran"] as? String) ?? ""])
        }
        if let pass = FeedUnits.journal.tail(60).last(where: { ($0["origin"] as? String) == "radar" }) {
            let ok: Bool = (pass["ok"] as? Bool) ?? false
            let kept: Int = (pass["kept"] as? Int) ?? 0
            let err: String = (pass["err"] as? String) ?? ""
            let label: String = ok ? (err.isEmpty ? "Sélection du radar · \(kept) unité(s) rédigée(s)" : "Sélection du radar · " + err) : "Sélection du radar · échec : " + String(err.prefix(90))
            ticker.append(["icon": ok ? "📡" : "🟠", "label": label, "ts": (pass["ts"] as? String) ?? ""])
        }
        if let g = radar["generated"] as? String {
            ticker.append(["icon": "🌍", "label": "Radar Afrique · \((radar["kept"] as? Int) ?? 0) signal(aux) retenu(s) sur \((radar["read"] as? Int) ?? 0) article(s) — \((radar["sources_ok"] as? Int) ?? 0)/\((radar["sources_total"] as? Int) ?? 0) sources joignables", "ts": g])
        }
        VeillePole.quoteLock.lock(); let qc = VeillePole.quoteCache; VeillePole.quoteLock.unlock()
        if let qc = qc {
            ticker.append(["icon": "📈", "label": "Cours BRVM · \(qc.q.count) valeurs relevées (brvm.org)", "ts": iso.string(from: qc.at), "ecran": "finance"])
        }
        if let e = fEvents.first {
            ticker.append(["icon": "💰", "label": "Fundings · " + ((e["programme"] as? String) ?? "") + " — " + ((e["categorie"] as? String) ?? ""), "ts": (e["ts"] as? String) ?? ""])
        }
        let note: String = FeedUnits.radarNote()
        mark("radarNote")
        if note.contains("en cours") { ticker.insert(["icon": "⏳", "label": note, "ts": "", "live": true], at: 0) }
        ticker.sort { (a: [String: Any], b: [String: Any]) -> Bool in
            let la: Bool = (a["live"] as? Bool) == true, lb: Bool = (b["live"] as? Bool) == true
            if la != lb { return la }
            return ((a["ts"] as? String) ?? "") > ((b["ts"] as? String) ?? "")
        }

        mark("ticker")
        NovaApp.feedsTimingWrite(tm, units: units.count, facts: facts.count)
        let out: [String: Any] = ["generated": nowISO(), "units": units, "note": note, "unread": unread,
                "fundings": ["prochaines": (fund["prochaines"] as? [[String: Any]]) ?? [], "events": Array(fEvents.prefix(30)), "totals": fund["totals"] ?? [String: Any]()] as [String: Any],
                "echeances": Array(dues.prefix(3)), "heat": heat,
                "radar": ["generated": radar["generated"] ?? "", "window_days": radar["window_days"] ?? 0] as [String: Any],
                "ticker": Array(ticker.prefix(10)), "weights": ["sources": wSrc, "themes": wTh] as [String: Any]]
        NovaApp.feedsOverviewLock.lock()
        NovaApp.feedsOverviewCache = (at: Date(), value: out)
        NovaApp.feedsOverviewLock.unlock()
        return out
    }
}
