import Foundation

/// Catalogue de flux d'information Afrique / sécurité / politique / humanitaire / accès / conflit.
/// L'agent appelle `flux_titres` avec la question : on choisit ici les flux pertinents (pays, thème, région), on les lit en parallèle,
/// et on renvoie titres + dates + liens. Seuls des flux testés depuis le Mac de l'utilisateur figurent dans la liste.
/// Les sites dont la connexion sécurisée échoue sur son réseau (RFI, France 24, Le Monde, Jeune Afrique…) passent par [tiers] Actualités (RSS filtré par site).
enum FluxCatalog {
    struct Feed { let name: String; let url: String; let tags: [String]; let region: String }

    static func gn(_ q: String, _ lang: String = "fr", days: Int = 7) -> String {
        let q = q + " when:\(days)d"   // récents seulement (sinon [tiers] trie par pertinence et remonte de vieux articles)
        let e = q.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed)?.replacingOccurrences(of: "&", with: "%26") ?? q
        return lang == "fr" ? "https://news.google.com/rss/search?q=\(e)&hl=fr&gl=FR&ceid=FR:fr" : "https://news.google.com/rss/search?q=\(e)&hl=en&gl=US&ceid=US:en"
    }
    static func rw(_ code: String) -> String { "https://reliefweb.int/country/\(code)/rss.xml" }
    static func rwSearch(_ q: String) -> String { "https://reliefweb.int/updates/rss.xml?search=" + (q.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? q) }

    /// Flux généraux (tags : securite, conflit, politique, humanitaire, acces, eco ; région : afrique, wca, esa, monde).
    static let general: [Feed] = [
        Feed(name: "RFI Afrique (via Google Actualités)", url: gn("site:rfi.fr afrique"), tags: ["politique", "securite", "conflit", "medias"], region: "afrique"),
        Feed(name: "France 24 Afrique (via Google Actualités)", url: gn("site:france24.com afrique"), tags: ["politique", "securite", "conflit", "medias"], region: "afrique"),
        Feed(name: "Le Monde Afrique (via Google Actualités)", url: gn("site:lemonde.fr afrique"), tags: ["politique", "securite", "medias"], region: "afrique"),
        Feed(name: "Jeune Afrique (via Google Actualités)", url: gn("site:jeuneafrique.com"), tags: ["politique", "eco", "medias"], region: "afrique"),
        Feed(name: "ACLED — conflits et violences (via Google Actualités)", url: gn("ACLED conflit Afrique"), tags: ["securite", "conflit"], region: "afrique"),
        Feed(name: "ISS Africa — sécurité (via Google Actualités)", url: gn("site:issafrica.org"), tags: ["securite", "conflit", "politique"], region: "afrique"),
        Feed(name: "Sahel — sécurité (Google Actualités)", url: gn("Sahel sécurité attaque"), tags: ["securite", "conflit"], region: "wca"),
        Feed(name: "Accès humanitaire Afrique (Google Actualités)", url: gn("accès humanitaire Afrique blocus"), tags: ["acces", "humanitaire", "conflit"], region: "afrique"),
        Feed(name: "ReliefWeb — dernières publications", url: "https://reliefweb.int/updates/rss.xml", tags: ["humanitaire", "acces", "conflit"], region: "monde"),
        Feed(name: "ReliefWeb — Afrique de l'Ouest et du Centre (WCA)", url: rwSearch("\"West and Central Africa\""), tags: ["humanitaire", "acces", "securite"], region: "wca"),
        Feed(name: "ReliefWeb — Afrique de l'Est et australe (ESA)", url: rwSearch("\"Eastern and Southern Africa\""), tags: ["humanitaire", "acces", "securite"], region: "esa"),
        Feed(name: "ReliefWeb — Sahel", url: rwSearch("sahel"), tags: ["humanitaire", "acces", "securite"], region: "wca"),
        Feed(name: "OCHA — actualités", url: "https://www.unocha.org/rss.xml", tags: ["humanitaire", "acces"], region: "monde"),
        Feed(name: "International Crisis Group", url: "https://www.crisisgroup.org/rss", tags: ["conflit", "politique", "securite"], region: "monde"),
        Feed(name: "ONU Info — Afrique", url: "https://news.un.org/feed/subscribe/en/news/region/africa/feed/rss.xml", tags: ["politique", "humanitaire", "securite"], region: "afrique"),
        Feed(name: "BBC Afrique", url: "https://feeds.bbci.co.uk/afrique/rss.xml", tags: ["politique", "securite", "medias"], region: "afrique"),
        Feed(name: "AllAfrica", url: "https://allafrica.com/tools/headlines/rdf/latest/headlines.rdf", tags: ["politique", "eco", "medias"], region: "afrique"),
        Feed(name: "Africanews", url: "https://www.africanews.com/feed/rss", tags: ["politique", "securite", "medias"], region: "afrique"),
        Feed(name: "The Africa Report", url: "https://www.theafricareport.com/feed/", tags: ["politique", "eco"], region: "afrique"),
        Feed(name: "Al Jazeera", url: "https://www.aljazeera.com/xml/rss/all.xml", tags: ["conflit", "politique"], region: "monde"),
    ]

    /// Pays : mots-clés (sans accents, minuscules) → (nom, code ReliefWeb, région).
    static let countries: [(keys: [String], name: String, code: String, region: String)] = [
        (["mali", "bamako"], "Mali", "mli", "wca"), (["burkina", "ouagadougou"], "Burkina Faso", "bfa", "wca"), (["niger ", "niamey", "niger,", "niger."], "Niger", "ner", "wca"),
        (["nigeria", "lagos", "abuja"], "Nigeria", "nga", "wca"), (["cameroun", "cameroon", "yaounde"], "Cameroun", "cmr", "wca"), (["tchad", "chad", "ndjamena"], "Tchad", "tcd", "wca"),
        (["cote d'ivoire", "ivoirien", "abidjan"], "Côte d'Ivoire", "civ", "wca"), (["guinee", "conakry"], "Guinée", "gin", "wca"), (["senegal", "dakar"], "Sénégal", "sen", "wca"),
        (["mauritanie", "nouakchott"], "Mauritanie", "mrt", "wca"), (["benin", "cotonou"], "Bénin", "ben", "wca"), (["togo", "lome"], "Togo", "tgo", "wca"), (["ghana", "accra"], "Ghana", "gha", "wca"),
        (["sierra leone", "freetown"], "Sierra Leone", "sle", "wca"), (["liberia", "monrovia"], "Liberia", "lbr", "wca"),
        (["centrafrique", "bangui"], "Centrafrique", "caf", "wca"), (["libye", "libya", "tripoli"], "Libye", "lby", "afrique"),
        (["soudan du sud", "south sudan", "juba"], "Soudan du Sud", "ssd", "esa"), (["soudan", "sudan", "khartoum"], "Soudan", "sdn", "esa"),
        (["rdc", "congo", "kinshasa", "kivu"], "RDC", "cod", "wca"), (["somalie", "somalia", "mogadiscio"], "Somalie", "som", "esa"), (["ethiopie", "ethiopia", "addis"], "Éthiopie", "eth", "esa"),
        (["mozambique", "cabo delgado"], "Mozambique", "moz", "esa"), (["kenya", "nairobi"], "Kenya", "ken", "esa"), (["ouganda", "uganda", "kampala"], "Ouganda", "uga", "esa"), (["burundi"], "Burundi", "bdi", "esa"),
        (["malawi", "lilongwe"], "Malawi", "mwi", "esa"), (["rwanda", "kigali"], "Rwanda", "rwa", "esa"), (["tanzanie", "tanzania", "dodoma"], "Tanzanie", "tza", "esa"),
        (["zambie", "zambia", "lusaka"], "Zambie", "zmb", "esa"), (["zimbabwe", "harare"], "Zimbabwe", "zwe", "esa"),
    ]

    static func fold(_ s: String) -> String { VeillePole.fold(s) }

    /// Choisit les flux pertinents pour la question. Plafond : 8 flux.
    static func select(_ query: String) -> [Feed] {
        let q = " " + fold(query) + " "
        var out: [Feed] = []
        func add(_ f: Feed) { if !out.contains(where: { $0.url == f.url }) { out.append(f) } }

        // 1. pays cités → ReliefWeb du pays + [tiers] Actualités sur le pays
        for c in countries where c.keys.contains(where: { q.contains($0) }) {
            add(Feed(name: "ReliefWeb — \(c.name)", url: rw(c.code), tags: ["humanitaire", "acces", "securite"], region: c.region))
            add(Feed(name: "\(c.name) — actualités (Google Actualités)", url: gn("\(c.name) actualité sécurité politique"), tags: ["politique", "securite"], region: c.region))
        }
        // 2. région
        let wca = ["sahel", "afrique de l'ouest", "afrique de l ouest", "wca", "afrique centrale", "west africa", "cedeao", "aes "].contains { q.contains($0) }
        let esa = ["esa", "afrique de l'est", "afrique de l est", "afrique australe", "east africa", "corne de l'afrique", "horn of africa"].contains { q.contains($0) }
        if wca { general.filter { $0.region == "wca" }.forEach(add) }
        if esa { general.filter { $0.region == "esa" }.forEach(add) }
        // 3. thèmes
        func has(_ ks: [String]) -> Bool { ks.contains { q.contains($0) } }
        var tags: [String] = []
        if has(["secur", "attaque", "attentat", "djihad", "jihad", "terror", "militaire", "armee", "coup", "violence", "acled"]) { tags += ["securite"] }
        if has(["conflit", "guerre", "combat", "crise", "war"]) { tags += ["conflit"] }
        if has(["humanit", "famine", "deplace", "refugi", "urgence", "ocha", "reliefweb", "cholera", "inondation"]) { tags += ["humanitaire"] }
        if has(["acces", "blocus", "convoi", "ong ", "corridor"]) { tags += ["acces"] }
        if has(["politi", "election", "gouvernement", "junte", "transition", "president", "diplomat", "accord"]) { tags += ["politique"] }
        if has(["econom", "marche", "brvm", "finance", "commerce", "inflation"]) { tags += ["eco"] }
        for t in tags { general.filter { $0.tags.contains(t) && ($0.region == "afrique" || $0.region == "monde" || (wca && $0.region == "wca") || (esa && $0.region == "esa") || out.isEmpty) }.forEach(add) }
        // 4. repli : veille générale
        if out.count < 4 {
            ["RFI Afrique", "France 24 Afrique", "ReliefWeb — dernières", "International Crisis Group", "ONU Info", "ISS Africa", "ACLED"].forEach { n in
                if let f = general.first(where: { $0.name.hasPrefix(n) }) { add(f) }
            }
        }
        // 5. si aucun pays cité mais un thème demandé, on garde au plus 8
        return Array(out.prefix(8))
    }

    /// Lit les flux choisis (+ flux de l'utilisateur) en parallèle. Sortie : tout est DATÉ et classé du plus récent au plus ancien,
    /// avec l'âge en jours calculé par rapport à AUJOURD'HUI ; l'agent doit bâtir sa réponse sur le récent et n'utiliser l'ancien que comme contexte daté.
    static func read(_ query: String, userFeeds: [String]) -> String {
        var feeds = select(query)
        for u in userFeeds where !feeds.contains(where: { $0.url == u }) && feeds.count < 10 {
            feeds.append(Feed(name: URL(string: u)?.host ?? u, url: u, tags: [], region: "perso"))
        }
        struct Row { let title: String; let link: String; let date: Date?; let src: String }
        var rows = [[Row]](repeating: [], count: feeds.count)
        var status = [String](repeating: "", count: feeds.count)
        let lock = NSLock(); let g = DispatchGroup()
        let now = Date()
        for (i, f) in feeds.enumerated() {
            g.enter()
            DispatchQueue.global().async {
                func load(_ url: String, _ t: TimeInterval) -> (ok: Bool, detail: String, items: [Row]) {
                    let r = VeillePole.fetchFeed(url, timeout: t)
                    return (r.ok, r.detail, r.items.map { Row(title: $0.0, link: $0.1, date: VeillePole.parseDate($0.2), src: f.name) })
                }
                var url = f.url
                var r = load(url, 12)
                if !r.ok { Thread.sleep(forTimeInterval: 1); r = load(url, 25) }   // un seul nouvel essai, plus patient
                // [tiers] Actualités : on élargit la fenêtre (7 j → 30 j) seulement s'il y a trop peu de résultats récents
                if r.ok, url.contains("news.google.com"), r.items.filter({ ($0.date ?? .distantPast) > now.addingTimeInterval(-14 * 86400) }).count < 3, url.contains("when%3A7d") || url.contains("when:7d") {
                    url = url.replacingOccurrences(of: "when%3A7d", with: "when%3A30d").replacingOccurrences(of: "when:7d", with: "when:30d")
                    let r2 = load(url, 12); if r2.ok { r = r2 }
                }
                lock.lock(); rows[i] = r.items; status[i] = "\(f.name) — \(r.ok ? "ok (\(r.items.count))" : r.detail)"; lock.unlock(); g.leave()
            }
        }
        _ = g.wait(timeout: .now() + 60)
        // fusion, dédoublonnage (titre), tri du plus récent au plus ancien
        var seen = Set<String>(); var all: [Row] = []
        for r in rows.flatMap({ $0 }) {
            let k = String(fold(r.title).filter { $0.isLetter || $0.isNumber }.prefix(60))
            if k.isEmpty || seen.contains(k) { continue }; seen.insert(k); all.append(r)
        }
        all.sort { ($0.date ?? .distantPast) > ($1.date ?? .distantPast) }
        func age(_ d: Date?) -> Int? { d.map { max(0, Int(now.timeIntervalSince($0) / 86400)) } }
        let iso = ISO8601DateFormatter(); iso.formatOptions = [.withFullDate]
        func line(_ r: Row) -> String { "- [\(r.date.map { iso.string(from: $0) } ?? "date inconnue")\(age(r.date).map { $0 == 0 ? ", aujourd'hui" : ", il y a \($0) j" } ?? "")] \(r.title) — \(r.src) — \(r.link)" }
        let b1 = all.filter { (age($0.date) ?? 999) <= 3 }
        let b2 = all.filter { let a = age($0.date) ?? 999; return a > 3 && a <= 14 }
        let b3 = all.filter { let a = age($0.date) ?? 999; return a > 14 && a <= 60 }
        let nd = all.filter { $0.date == nil }
        let old = all.filter { (age($0.date) ?? 0) > 60 }
        let today = iso.string(from: now)
        var out = ["DATE DU JOUR : \(today). Question : « \(query) ». \(feeds.count) flux lus, \(all.count) titres (dédoublonnés), classés du PLUS RÉCENT au plus ancien.",
                   "RÈGLES POUR TA RÉPONSE : (1) bâtis l'analyse d'abord sur « DERNIERS JOURS » puis « 4 À 14 JOURS » et cite la date de chaque fait ; (2) si ces deux blocs sont vides ou minces, dis-le franchement (« rien de récent dans les flux ») et donne la date du fait le plus récent trouvé ; (3) les blocs « CONTEXTE » et « ANCIEN » ne servent qu'à montrer l'évolution : présente-les comme du passé daté, jamais comme l'actualité ; (4) n'invente aucune date ni aucun fait ; une ligne « date inconnue » n'est pas vérifiable."]
        func section(_ t: String, _ l: [Row], _ n: Int) { if !l.isEmpty { out.append("== \(t) (\(l.count))"); out += l.prefix(n).map(line) } }
        section("DERNIERS JOURS (≤ 3 j)", b1, 20); section("4 À 14 JOURS", b2, 20); section("CONTEXTE (15 à 60 j)", b3, 12); section("ANCIEN (> 60 j, mémoire historique seulement)", old, 5); section("SANS DATE (non vérifiable)", nd, 5)
        if b1.isEmpty && b2.isEmpty { out.append("!! AUCUN titre daté des 14 derniers jours : réponds que les flux ne montrent rien de récent sur ce sujet, et propose d'élargir (autre pays, autre thème, recherche web).") }
        out.append("== ÉTAT DES FLUX"); out += status.map { "- " + $0 }
        return String(out.joined(separator: "\n").prefix(12000))
    }
}
