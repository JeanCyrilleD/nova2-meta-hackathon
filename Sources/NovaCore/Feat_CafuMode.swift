import Foundation
import NovaFoundation

// 31/10 (CAFU) : MODE ANALYSE CAFU (audits/cafu/cafu_prompts_AB.txt + skill cafu-note-quality-v2, bloc « Runtime protocol »).
// Une demande de note CAFU / section GHO / brief de contexte (déclencheurs du skill, FR et EN) ne passe PAS par le chat ordinaire :
//   1) cerveau ÉPINGLÉ Spark 1.3 (muse-spark-1.3, API Meta), raisonnement au plus haut niveau accepté — échelle « max → xhigh → high »
//      (doc officielle dev.meta.ai/docs/reasoning : reasoning_effort ∈ none, minimal, low, medium, high, xhigh, max ; « max » accepté par
//      muse-spark-1.3, pas par la variante Contributor). Refus 400/422, réponse vide ou raisonnement sans texte (31/10) → niveau inférieur AVEC avertissement visible dans le fil
//      (« Running at xhigh, max unavailable ») ; jamais de repli silencieux, jamais vers un autre cerveau. max_tokens ≥ 16 000.
//      Température : non envoyée (paramètre non documenté par la Meta Model API au 31/10/2026 — un champ inconnu peut valoir un 400).
//   2) RECHERCHE OBLIGATOIRE AVANT RÉDACTION, dans le code (pas seulement dans le prompt) : (a) Algolia (index « nova-cafu » des notes
//      CAFU passées + index « nova-memoire ») ; (b) ≥ 3 recherches Tavily (actualité 12 mois, sources officielles via include_domains,
//      requête en français pour les pays francophones) en search_depth advanced, max_results 10, include_raw_content ; (c) Tavily Extract
//      sur les meilleures sources primaires. Un outil en échec ou muet → arrêt avec erreur visible, aucune réponse de mémoire.
//      01/11 : un échec Tavily PASSAGER (HTTP 0, 408, 429, 5xx) est réessayé 2 fois (2 s, 5 s) puis la recherche est sautée avec
//      avertissement visible ; l'arrêt n'a lieu que sous le minimum (≥ 3 recherches réussies) ou sur clé/crédits refusés.
//   3) GARDE DE CITATION : une URL citée absente des résultats récupérés → une relance (retirer/remplacer), sinon refus visible.
//      Extract automatique sur chaque URL citée pas encore lue en texte complet.
//   4) JOURNAL : « Sources opened » + modèle et niveau réellement utilisés, dans le fil et dans releves/diag/cafu_runs.jsonl.
// Réglages : cafu_mode (true), cafu_algolia_obligatoire (true), cafu_effort_echelle (["max","xhigh","high"]), cafu_max_tokens (32000),
// cafu_max_tokens_niveau_max (48000 : au niveau max, le raisonnement compte dans max_tokens),
// cafu_tavily_max_recherches (8), cafu_extract_max (6), cafu_plafond_usd (= plafond_par_demande_usd), cafu_dossiers_notes
// ([] : dossiers de notes en plus des livrables CAFU de Nova), cafu_domaines_officiels ([]).
// Test d'acceptation sans écran : dormant/CAFU_TEST_REQUEST → releves/diag/cafu_test.json (rien n'est envoyé à personne).

/// 31/10 (CAFU) : une source récupérée pendant un run CAFU.
struct CafuDoc {
    var url: String
    var title: String
    var published: String
    var retrieved: String
    var content: String
    var full: Bool          // texte complet lu par Tavily Extract
    var pageText: Bool      // contenu de page brut renvoyé par la recherche (include_raw_content)
    var tool: String        // "tavily_search" | "tavily_extract" | "algolia"
    var query: String
    var official: Bool
    var score: Double
}

/// 31/10 (CAFU) : état d'un run — sources, compteurs d'appels, avertissements.
final class CafuLog {
    var docs: [CafuDoc] = []
    var index: [String: Int] = [:]          // URL normalisée → position dans docs (= ensemble des URL récupérées)
    var algoliaCalls: Int = 0
    var algoliaHits: Int = 0
    var tavilySearches: Int = 0
    var tavilyExtractCalls: Int = 0
    var tavilyCredits: Int = 0
    var events: [[String: Any]] = []        // chaque appel d'outil : outil, requête, statut, nombre de résultats
    var warnings: [String] = []

    func add(_ d: CafuDoc) {
        let k: String = CafuMode.norm(d.url)
        if k.isEmpty { return }
        if let i = index[k] {
            if d.full && !docs[i].full {
                var n: CafuDoc = d
                if n.published.isEmpty { n.published = docs[i].published }
                if n.title.isEmpty { n.title = docs[i].title }
                n.query = docs[i].query + " → extract"
                n.pageText = docs[i].pageText
                n.score = max(n.score, docs[i].score)
                n.official = n.official || docs[i].official
                docs[i] = n
            } else if !docs[i].full && docs[i].content.count < d.content.count {
                docs[i].content = d.content
                docs[i].pageText = docs[i].pageText || d.pageText
            }
            if docs[i].published.isEmpty { docs[i].published = d.published }
            if d.official { docs[i].official = true }
            return
        }
        index[k] = docs.count
        docs.append(d)
    }
}

enum CafuMode {
    static let skillName: String = "cafu-note-quality-v2"
    static let oldSkillName: String = "cafu-note-quality"
    static let brainId: String = "spark-1.3"
    static let algoliaIndex: String = "nova-cafu"
    static let calibrationBrief: String = "Draft a 150-word GHO 2027 context paragraph on NGO regulation in Niger and Mali for the child protection cluster, British English, evidence cut-off 31/10/2026, with tagged evidence bullets, two scenarios and three recommendations."
    static let diagDir: String = NSHomeDirectory() + "/spark-local/Nova2/releves/diag"

    // MARK: prompt

    /// Bloc « Runtime protocol » du skill, tel quel (anglais voulu : les notes sont en anglais britannique).
    static var runtimeProtocol: String {
        let c: String = CafuSkillText.content
        if let h = c.range(of: "## Runtime protocol"),
           let a = c.range(of: "```\n", range: h.upperBound..<c.endIndex),
           let b = c.range(of: "\n```", range: a.upperBound..<c.endIndex) {
            return String(c[a.upperBound..<b.lowerBound])
        }
        return "You are a CAFU strategic analyst. You write short, verified notes for humanitarian decision-makers. Accuracy beats speed."
    }

    /// Méthode complète du skill installé (ou embarqué), SANS la référence de calibration ni le test : les faits de contrôle ne
    /// doivent jamais servir de source au brouillon (le test mesure la recherche réelle).
    static var method: String {
        let c: String = NovaSkills.content(skillName) ?? CafuSkillText.content
        if let r = c.range(of: "## Reference: Sahel 2D note") { return String(c[..<r.lowerBound]) }
        if let r = c.range(of: "## Calibration test") { return String(c[..<r.lowerBound]) }
        return c
    }

    static func orchestrationRules(today: String) -> String {
        return """
        NOVA ORCHESTRATION (CAFU mode). Today is \(today).
        The searches required above have ALREADY been run by Nova's orchestration code. Their results are in the RESEARCH DOSSIER in the user message: the internal library (Algolia) first, then web sources [S1]…[Sn], each with its URL, publication date, retrieved date and whether its full text was read. You cannot run more searches in this turn.
        - Use only facts found in the dossier. If a fact is not there, tag it TO CHECK (searched by Nova on \(today), not found). Never fill gaps from memory.
        - Cite web sources by their exact URL as written in the dossier. Any URL that is not in the dossier blocks the answer.
        - Internal library hits are earlier notes or memory: re-verify each fact against the web sources before tagging it SOLID.
        - Your own "Sources opened" list must only contain dossier sources. Nova appends its machine run log after your answer.
        - Output the note, then the QA log and the scores, in the requested language variety (British English by default).
        """
    }

    static func guardNote(_ urls: [String]) -> String {
        return "CITATION GUARD (Nova): your draft cites URL(s) that are NOT in the research dossier:\n" + urls.map { "- " + $0 }.joined(separator: "\n")
            + "\nRewrite the complete answer. Remove these URLs, or replace each one with a source that IS in the dossier (exact URL). If a fact then has no source, tag it TO CHECK. Do not add any other URL."
    }

    // MARK: détection

    static func fold(_ s: String) -> String {
        return s.lowercased().folding(options: .diacriticInsensitive, locale: Locale(identifier: "fr_FR")).replacingOccurrences(of: "’", with: "'")
    }
    static func tokens(_ s: String) -> Set<String> {
        return Set(s.components(separatedBy: CharacterSet.alphanumerics.inverted).filter { !$0.isEmpty })
    }
    /// Expressions qui suffisent seules (déclencheurs du skill, FR et EN).
    static let strongCues: [String] = ["note cafu", "notes cafu", "cafu note", "cafu-note-quality", "strategic analysis note", "note d'analyse strategique",
        "notes d'analyse strategique", "brief de contexte", "context brief", "qa this note", "correct this note", "check before peer review", "rate this draft",
        "draft the 2d section", "section 2d", "global humanitarian overview", "apercu des besoins humanitaires", "apercu humanitaire mondial",
        "paragraphe de contexte", "context paragraph", "/cafu"]
    /// Avec « CAFU » ou « GHO » : un mot d'analyse est exigé.
    static let analysisCues: Set<String> = ["note", "brief", "analyse", "analysis", "paragraphe", "paragraph", "section", "scenario", "scenarios", "contexte",
        "context", "redige", "rediger", "draft", "relis", "corrige", "review", "evalue", "qa"]
    /// Demandes de mise en forme / courrier : restent au chat ordinaire (outils cafu_format_*), sauf expression forte.
    static let formatCues: [String] = ["mise en forme", "mets en forme", "met en forme", "logo", "gabarit", "charte", "mail", "courriel", "teams", "theme", "couleur"]

    static func detect(_ text: String) -> Bool {
        let t: String = fold(text)
        if t.count < 6 { return false }
        if t.hasPrefix("/cafu") { return true }
        for c in strongCues where t.contains(c) { return true }
        let tk: Set<String> = tokens(t)
        let gho: Bool = tk.contains("gho") || tk.contains("hno") || tk.contains("hrp")
        if !(gho || tk.contains("cafu")) { return false }
        if formatCues.contains(where: { t.contains($0) }) { return false }
        return !tk.intersection(analysisCues).isEmpty
    }
    static func isTestCommand(_ text: String) -> Bool { return fold(text).contains("cafu-note-quality-v2 test") }

    // MARK: URL

    static func trimURL(_ raw: String) -> String {
        var u: String = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        while let l = u.last, ".,;:!?_`'\"".contains(l) { u.removeLast() }
        return u
    }
    /// Forme comparable d'une URL : hôte sans « www. », chemin sans « / » final, paramètres utm_ retirés, sans schéma ni ancre.
    static func norm(_ raw: String) -> String {
        let u: String = trimURL(raw)
        guard let c = URLComponents(string: u), let h0 = c.host, !h0.isEmpty else { return "" }
        var h: String = h0.lowercased()
        if h.hasPrefix("www.") { h = String(h.dropFirst(4)) }
        var p: String = c.percentEncodedPath
        while p.hasSuffix("/") { p.removeLast() }
        var q: String = ""
        if let items = c.queryItems {
            let kept: [URLQueryItem] = items.filter { !$0.name.lowercased().hasPrefix("utm_") }
            if !kept.isEmpty { q = "?" + kept.map { $0.name + "=" + ($0.value ?? "") }.joined(separator: "&") }
        }
        return h + p + q
    }
    /// URL http(s) citées dans un texte, dans l'ordre, sans doublon.
    static func cited(_ text: String) -> [String] {
        guard let rx = try? NSRegularExpression(pattern: "https?://[^\\s<>\"'\\])}|»«*]+") else { return [] }
        let ns: NSString = text as NSString
        var out: [String] = []
        for m in rx.matches(in: text, range: NSRange(location: 0, length: ns.length)) {
            let u: String = trimURL(ns.substring(with: m.range))
            if !u.isEmpty && !out.contains(u) { out.append(u) }
        }
        return out
    }

    static func dmy(_ d: Date) -> String {
        let f: DateFormatter = DateFormatter(); f.locale = Locale(identifier: "en_US_POSIX"); f.dateFormat = "dd/MM/yyyy"
        return f.string(from: d)
    }

    // MARK: pays et sources officielles

    struct Country {
        let en: String
        let fr: String
        let francophone: Bool
        let names: [String]     // formes repliées (minuscules, sans accents) reconnues dans la demande
        let domains: [String]   // sites gouvernementaux / journaux officiels connus (liste de départ, à compléter par cafu_domaines_officiels)
    }
    static let genericOfficial: [String] = ["reliefweb.int", "unocha.org", "icnl.org", "un.org", "unicef.org", "ohchr.org"]
    static let countries: [Country] = [
        Country(en: "Burkina Faso", fr: "Burkina Faso", francophone: true, names: ["burkina"], domains: ["gouvernement.gov.bf", "sig.gov.bf", "presidencedufaso.bf"]),
        Country(en: "Mali", fr: "Mali", francophone: true, names: ["mali"], domains: ["primature.gov.ml", "sgg-mali.ml", "koulouba.ml"]),
        Country(en: "Niger", fr: "Niger", francophone: true, names: ["niger"], domains: ["presidence.ne", "lesahel.org", "anp.ne"]),
        Country(en: "Chad", fr: "Tchad", francophone: true, names: ["chad", "tchad"], domains: ["presidence.td"]),
        Country(en: "Cameroon", fr: "Cameroun", francophone: true, names: ["cameroon", "cameroun"], domains: ["prc.cm", "spm.gov.cm"]),
        Country(en: "Senegal", fr: "Sénégal", francophone: true, names: ["senegal"], domains: ["sec.gouv.sn", "presidence.sn"]),
        Country(en: "Mauritania", fr: "Mauritanie", francophone: true, names: ["mauritania", "mauritanie"], domains: []),
        Country(en: "Côte d'Ivoire", fr: "Côte d'Ivoire", francophone: true, names: ["cote d'ivoire", "ivory coast"], domains: ["gouv.ci"]),
        Country(en: "Benin", fr: "Bénin", francophone: true, names: ["benin"], domains: ["gouv.bj"]),
        Country(en: "Togo", fr: "Togo", francophone: true, names: ["togo"], domains: ["republicoftogo.com"]),
        Country(en: "Guinea", fr: "Guinée", francophone: true, names: ["guinea", "guinee"], domains: []),
        Country(en: "Central African Republic", fr: "République centrafricaine", francophone: true, names: ["central african republic", "centrafrique", "centrafricaine"], domains: []),
        Country(en: "Democratic Republic of the Congo", fr: "République démocratique du Congo", francophone: true, names: ["drc", "rdc", "democratic republic of the congo", "republique democratique du congo"], domains: []),
        Country(en: "Haiti", fr: "Haïti", francophone: true, names: ["haiti"], domains: []),
        Country(en: "Nigeria", fr: "Nigeria", francophone: false, names: ["nigeria"], domains: ["statehouse.gov.ng"]),
        Country(en: "Sudan", fr: "Soudan", francophone: false, names: ["sudan", "soudan"], domains: []),
        Country(en: "South Sudan", fr: "Soudan du Sud", francophone: false, names: ["south sudan", "soudan du sud"], domains: []),
        Country(en: "Somalia", fr: "Somalie", francophone: false, names: ["somalia", "somalie"], domains: []),
        Country(en: "Ethiopia", fr: "Éthiopie", francophone: false, names: ["ethiopia", "ethiopie"], domains: []),
        Country(en: "Yemen", fr: "Yémen", francophone: false, names: ["yemen"], domains: []),
        Country(en: "Syria", fr: "Syrie", francophone: false, names: ["syria", "syrie"], domains: []),
        Country(en: "Afghanistan", fr: "Afghanistan", francophone: false, names: ["afghanistan"], domains: []),
        Country(en: "Ukraine", fr: "Ukraine", francophone: false, names: ["ukraine"], domains: []),
        Country(en: "Myanmar", fr: "Myanmar", francophone: false, names: ["myanmar", "birmanie"], domains: []),
        Country(en: "occupied Palestinian territory", fr: "Territoire palestinien occupé", francophone: false, names: ["gaza", "palestin"], domains: []),
    ]

    static func detectCountries(_ text: String) -> [Country] {
        let t: String = fold(text)
        let tk: Set<String> = tokens(t)
        return countries.filter { (c: Country) -> Bool in
            c.names.contains { (n: String) -> Bool in
                if n.contains(" ") || n.contains("'") { return t.contains(n) }
                if tk.contains(n) { return true }
                return n.count >= 6 && tk.contains(where: { $0.hasPrefix(n) })
            }
        }
    }

    static func host(_ url: String) -> String {
        guard let h0 = URLComponents(string: url)?.host?.lowercased() else { return "" }
        return h0.hasPrefix("www.") ? String(h0.dropFirst(4)) : h0
    }
    static func isOfficial(_ url: String, extra: [String]) -> Bool {
        let h: String = host(url)
        if h.isEmpty { return false }
        let lists: [String] = genericOfficial + extra + countries.flatMap { $0.domains }
        if lists.contains(where: { h == $0 || h.hasSuffix("." + $0) }) { return true }
        for m in [".gov", "gouv.", "gouvernement", "presidence", "primature", "journal-officiel", "journalofficiel", "sgg"] where h.contains(m) { return true }
        return h.hasSuffix(".int")
    }

    // MARK: Tavily (doc officielle docs.tavily.com : /search et /extract)

    struct Query {
        let q: String
        let topic: String
        let domains: [String]
        let label: String
    }

    static func queries(topicEn: String, topicFr: String, countries cs0: [Country], extraDomains: [String], maxN: Int) -> [Query] {
        var out: [Query] = []
        let cs: [Country] = Array(cs0.prefix(3))
        if cs.isEmpty {
            out.append(Query(q: topicEn, topic: "news", domains: [], label: "news, last 12 months"))
            out.append(Query(q: topicEn + " decree official gazette", topic: "general", domains: genericOfficial + extraDomains, label: "official sources"))
            out.append(Query(q: topicFr + " décret journal officiel", topic: "general", domains: [], label: "French-language"))
        } else {
            for c in cs {
                out.append(Query(q: c.en + " " + topicEn, topic: "news", domains: [], label: "news, last 12 months — " + c.en))
                out.append(Query(q: c.en + " " + topicEn + " decree official gazette", topic: "general", domains: c.domains + genericOfficial + extraDomains, label: "official sources — " + c.en))
                if c.francophone { out.append(Query(q: c.fr + " " + topicFr + " décret journal officiel", topic: "general", domains: [], label: "French-language — " + c.fr)) }
            }
            if out.count < 3 {
                out.append(Query(q: cs.map { $0.en }.joined(separator: " ") + " " + topicEn + " OCHA ICNL analysis", topic: "general", domains: [], label: "analysis"))
            }
        }
        return Array(out.prefix(max(3, maxN)))
    }

    static func tavily(_ path: String, key: String, body: [String: Any], timeout: TimeInterval) -> (Int, [String: Any]?, String) {
        guard let u = URL(string: "https://api.tavily.com/" + path) else { return (0, nil, "URL invalide") }
        var rq: URLRequest = URLRequest(url: u)
        rq.httpMethod = "POST"
        rq.timeoutInterval = timeout
        rq.setValue("Bearer " + key, forHTTPHeaderField: "Authorization")
        rq.setValue("application/json", forHTTPHeaderField: "Content-Type")
        rq.httpBody = jsonData(body)
        // 01/11 (run réel 23:07 : « HTTP 0 » sans cause) : HTTPStream direct pour garder la cause (délai, réseau, flux coupé).
        var out: Data = Data()
        let r: HTTPResult = HTTPStream.run(rq, firstByteTimeout: timeout, idleTimeout: timeout, totalTimeout: timeout + 30) { (c: Data) -> Bool in out.append(c); return true }
        if let e = r.error, r.status == 0 || r.status == 200 {
            return (0, nil, "HTTP 0 (pas de réponse complète : " + SecretsGuard.redact(e) + ")")
        }
        let d: Data = r.status >= 400 ? r.body : out
        let o: [String: Any]? = parseJSON(d)
        if r.status == 200 && o == nil { return (0, nil, "HTTP 0 (réponse illisible : JSON incomplet)") }
        let err: String = r.status == 200 ? "" : ("HTTP " + String(r.status) + " " + SecretsGuard.redact(String(decoding: d.prefix(240), as: UTF8.self)))
        return (r.status, o, err)
    }
    /// 01/11 : échec PASSAGER de Tavily (pas de réponse, 408, 429, 5xx) — réessayé, puis la recherche est sautée avec avertissement.
    /// Les autres (401/403 clé refusée, 402/432/433 crédits ou plan) restent un arrêt visible.
    static func tavilyTransient(_ st: Int) -> Bool { st == 0 || st == 408 || st == 429 || (500...599).contains(st) }
    /// 01/11 (run réel 23:07 : un HTTP 0 isolé tuait le run après 3 recherches réussies) : 1 essai + `retries` reprises, avec un court
    /// délai (2 s puis 5 s) entre deux essais, seulement sur échec passager. `tries` = appels réellement envoyés.
    static func withRetry(retries: Int = 2, delays: [TimeInterval] = [2, 5], sleep: (TimeInterval) -> Void = { Thread.sleep(forTimeInterval: $0) },
                          cancel: () -> Bool = { false }, call: () -> (Int, [String: Any]?, String)) -> (st: Int, o: [String: Any]?, err: String, tries: Int) {
        var last: (Int, [String: Any]?, String) = (0, nil, "pas d'essai")
        var tries: Int = 0
        for i in 0...max(0, retries) {
            if i > 0 {
                if cancel() { break }
                sleep(delays.isEmpty ? 2 : delays[min(i - 1, delays.count - 1)])
            }
            last = call()
            tries += 1
            if last.0 == 200 || !tavilyTransient(last.0) { break }
        }
        return (last.0, last.1, last.2, tries)
    }
    /// 01/11 : décision de fin de phase de recherche — le run ne s'arrête que si le minimum requis n'est pas atteint.
    static func searchPhaseVerdict(okSearches: Int, totalResults: Int, skipped: [String]) -> String? {
        let tail: String = skipped.isEmpty ? "" : " ; sautée(s) après 3 essais : " + skipped.joined(separator: " | ")
        if okSearches < 3 { return "moins de 3 recherches Tavily abouties (" + String(okSearches) + tail + ")" }
        if totalResults == 0 { return "les recherches Tavily n'ont renvoyé aucun résultat" + tail }
        return nil
    }
    /// Crédits facturés par Tavily (champ usage.credits si renvoyé, sinon estimation documentée).
    static func credits(_ o: [String: Any]?, fallback: Int) -> Int {
        if let u = o?["usage"] as? [String: Any] {
            if let c = u["credits"] as? Int { return c }
            if let c = u["credits"] as? Double { return Int(c.rounded(.up)) }
        }
        return fallback
    }
    static func str(_ v: Any?) -> String { return (v as? String) ?? "" }
    static func num(_ v: Any?) -> Double {
        if let d = v as? Double { return d }
        if let n = v as? NSNumber { return n.doubleValue }
        return 0
    }

    // MARK: Algolia (bibliothèque interne)

    /// Interroge « nova-cafu » (notes CAFU passées, textes primaires lus) puis « nova-memoire ». Clé de RECHERCHE si présente,
    /// sinon la clé d'écriture (comportement d'AlgoliaRelay depuis le 29/10, côté moteur seulement). ok = au moins un index a répondu.
    static func algoliaQuery(_ q: String) -> (ok: Bool, hits: [[String: Any]], err: String, calls: Int, keyKind: String, states: [String: String]) {
        if Credits.isOpen("algolia") { return (false, [], "disjoncteur Algolia ouvert (échecs récents)", 0, "", [:]) }
        let c = AlgoliaRelay.creds(KeychainStore())
        if c.app.isEmpty { return (false, [], "Application ID Algolia absent du Trousseau (nova-algolia-app)", 0, "", [:]) }
        let key: String = c.search.isEmpty ? c.admin : c.search
        let kind: String = c.search.isEmpty ? "clé d'écriture (clé de recherche absente)" : "clé de recherche"
        if key.isEmpty { return (false, [], "clé de RECHERCHE Algolia absente (Trousseau « nova-algolia-search ») et aucune clé d'écriture : la bibliothèque interne n'est pas interrogeable", 0, "", [:]) }
        if c.search.isEmpty && AlgoliaRelay.searchDeniedForAdmin() { return (false, [], "la clé d'écriture n'a pas le droit search : ajoute la Search-only key nova-algolia-search", 0, kind, [:]) }   // 31/10 (Algolia biblio)
        // 31/10 (Algolia biblio) : + l'index unique « nova-bibliotheque » (toutes les bibliothèques de Nova et les fichiers du Mac hors sensibles).
        let r = algoliaSearchIndexes([algoliaIndex, AlgoliaBiblio.index, AlgoliaRelay.index], q: q) { (idx: String, timeout: TimeInterval) -> (Int, Data) in
            let body: [String: Any] = ["query": String(q.prefix(400)), "hitsPerPage": idx == AlgoliaBiblio.index ? 6 : 8, "removeWordsIfNoResults": "allOptional"]
            let (st, d): (Int, Data) = AlgoliaRelay.request(app: c.app, key: key, path: "/1/indexes/" + idx + "/query", body: body, timeout: timeout)
            if st == 200 { Credits.count("algolia", n: 1, units: 1, unit: "requête") }
            else if st > 0 && st != 404 { AlgoliaRelay.failed(status: st, detail: String(decoding: d.prefix(300), as: UTF8.self), op: "search", adminKey: c.search.isEmpty) }   // 31/10 (Algolia biblio) : filtre avant disjoncteur
            return (st, d)
        }
        return (r.ok, r.hits, r.errs.joined(separator: " ; "), r.calls, kind, r.states)
    }
    /// 01/11 (run réel 23:07 : « nova-cafu : HTTP 0 » — 1re requête Algolia du run, connexion à froid, délai 8 s ; les deux index suivants
    /// répondaient) : un HTTP 0 (aucune réponse) est réessayé UNE fois avec un délai de 15 s. 404 = index pas encore versé. ok = au moins un
    /// index a répondu ; `states` dit honnêtement ce que chaque index a fait.
    static func algoliaSearchIndexes(_ indexes: [String], q: String, request: (String, TimeInterval) -> (Int, Data))
        -> (ok: Bool, hits: [[String: Any]], errs: [String], calls: Int, states: [String: String]) {
        var hits: [[String: Any]] = []
        var okAny: Bool = false
        var errs: [String] = []
        var calls: Int = 0
        var states: [String: String] = [:]
        for idx in indexes {
            var (st, d): (Int, Data) = request(idx, 8)
            calls += 1
            var tries: Int = 1
            if st == 0 { (st, d) = request(idx, 15); calls += 1; tries = 2 }
            if st == 200 {
                okAny = true
                let hs: [[String: Any]] = (parseJSON(d)?["hits"] as? [[String: Any]]) ?? []
                for h in hs { var m: [String: Any] = h; m["_index"] = idx; hits.append(m) }
                states[idx] = "ok : " + String(hs.count) + " résultat(s)" + (tries > 1 ? " (après une reprise : 1er essai sans réponse)" : "")
            } else if st == 404 && idx != AlgoliaRelay.index {
                errs.append("index « " + idx + " » absent (rien encore versé)")
                states[idx] = "absent (404 : rien encore versé)"
            } else if st == 0 {
                errs.append(idx + " : HTTP 0 (aucune réponse en 8 s puis 15 s — réseau ou hôte Algolia injoignable)")
                states[idx] = "échec : aucune réponse (2 essais)"
            } else {
                errs.append(idx + " : HTTP " + String(st))
                states[idx] = "échec : HTTP " + String(st)
            }
        }
        return (okAny, hits, errs, calls, states)
    }

    static let ingestState: JSONFile = JSONFile("algolia_cafu.json")

    /// Dossiers de notes CAFU : les livrables de Nova (<données Nova>/cafu : cafu-note-*, cafu-doc-*) + cafu_dossiers_notes.
    static func noteDirs() -> [String] {
        var out: [String] = [Livrables.dir.path]
        // Défaut vide : lire ~/Documents déclencherait une demande d'autorisation macOS au démarrage ; Ahadi ajoute ses dossiers ici.
        let extra: [String] = Settings().get("cafu_dossiers_notes", [String]())
        for e in extra {
            let p: String = (e as NSString).expandingTildeInPath
            if !out.contains(p) { out.append(p) }
        }
        return out
    }

    static func noteTitle(_ raw: String, html: Bool, fallback: String) -> String {
        if html {
            for pat in ["<title[^>]*>([\\s\\S]*?)</title>", "<h1[^>]*>([\\s\\S]*?)</h1>"] {
                if let rx = try? NSRegularExpression(pattern: pat, options: [.caseInsensitive]),
                   let m = rx.firstMatch(in: raw, range: NSRange(location: 0, length: (raw as NSString).length)), m.numberOfRanges > 1 {
                    let t: String = Tools.htmlToText((raw as NSString).substring(with: m.range(at: 1)), limit: 200)
                    if !t.isEmpty { return t }
                }
            }
        } else {
            for l in raw.components(separatedBy: "\n").prefix(40) where l.hasPrefix("# ") { return String(l.dropFirst(2)).trimmingCharacters(in: .whitespaces) }
        }
        return fallback
    }
    static func noteDate(name: String, mtime: Double) -> String {
        if let r = name.range(of: "20[0-9]{6}", options: .regularExpression) {
            let s: String = String(name[r])
            let y: String = String(s.prefix(4)), mo: String = String(s.dropFirst(4).prefix(2)), d: String = String(s.suffix(2))
            return d + "/" + mo + "/" + y
        }
        return dmy(Date(timeIntervalSince1970: mtime))
    }

    static func batchUpload(_ recs: [[String: Any]]) -> (sent: Int, err: String) {
        let c = AlgoliaRelay.creds(KeychainStore())
        if c.app.isEmpty || c.admin.isEmpty { return (0, "Application ID ou clé d'écriture Algolia absente") }
        if Credits.isOpen("algolia") { return (0, "disjoncteur Algolia ouvert") }
        var sent: Int = 0
        var i: Int = 0
        while i < recs.count {
            let chunk: [[String: Any]] = Array(recs[i..<min(i + 100, recs.count)])
            let reqs: [[String: Any]] = chunk.map { (r: [String: Any]) -> [String: Any] in ["action": "updateObject", "body": r] }
            let (code, d): (Int, Data) = AlgoliaRelay.request(app: c.app, key: c.admin, path: "/1/indexes/" + algoliaIndex + "/batch", body: ["requests": reqs], timeout: 30)
            if code != 200 {
                if code > 0 { AlgoliaRelay.failed(status: code, detail: String(decoding: d.prefix(300), as: UTF8.self), op: "write", adminKey: true) }   // 31/10 (Algolia biblio)
                return (sent, "HTTP " + String(code) + " : " + SecretsGuard.redact(String(decoding: d.prefix(200), as: UTF8.self)))
            }
            sent += chunk.count
            i += 100
        }
        return (sent, "")
    }

    /// Versement incrémental des notes CAFU (nouvelles ou modifiées) dans l'index « nova-cafu » : 1 enregistrement par tranche de
    /// 6 000 caractères (6 au plus par note). État : <données Nova>/algolia_cafu.json ; diag : releves/diag/algolia_cafu_etat.json.
    @discardableResult
    static func ingestNotes() -> [String: Any] {
        var diag: [String: Any] = ["generated": nowISO(), "index": algoliaIndex, "dossiers": noteDirs()]
        defer { try? jsonData(diag).write(to: URL(fileURLWithPath: diagDir + "/algolia_cafu_etat.json")) }
        let c = AlgoliaRelay.creds(KeychainStore())
        if c.app.isEmpty || c.admin.isEmpty { diag["etat"] = "non versé : Application ID ou clé d'écriture Algolia absente"; return diag }
        if Credits.isOpen("algolia") { diag["etat"] = "non versé : disjoncteur Algolia ouvert"; return diag }
        var st: [String: Any] = ingestState.read(default: [String: Any]())
        var seen: [String: Double] = [:]
        for (k, v) in ((st["fichiers"] as? [String: Any]) ?? [:]) { seen[k] = num(v) }
        let fm: FileManager = FileManager.default
        var recs: [[String: Any]] = []
        var files: Int = 0, changed: Int = 0
        let livr: String = Livrables.dir.path
        for dir in noteDirs() {
            guard let en = fm.enumerator(atPath: dir) else { continue }
            var n: Int = 0
            while let rel = en.nextObject() as? String {
                n += 1
                if n > 3000 { break }
                let ext: String = (rel as NSString).pathExtension.lowercased()
                guard ["html", "htm", "md", "txt"].contains(ext) else { continue }
                let name: String = (rel as NSString).lastPathComponent
                if dir == livr && !(name.hasPrefix("cafu-note") || name.hasPrefix("cafu-doc")) { continue }
                let path: String = dir + "/" + rel
                guard let at = try? fm.attributesOfItem(atPath: path), let md = at[.modificationDate] as? Date else { continue }
                if ((at[.size] as? NSNumber)?.intValue ?? 0) > 3_000_000 { continue }
                let mt: Double = md.timeIntervalSince1970
                files += 1
                if let old = seen[path], abs(old - mt) < 1 { continue }
                guard let raw = try? String(contentsOfFile: path, encoding: .utf8) else { continue }
                let isHTML: Bool = ext.hasPrefix("htm")
                let text: String = isHTML ? Tools.htmlToText(raw, limit: 40000) : String(raw.prefix(40000))
                seen[path] = mt
                if text.count < 80 { continue }
                let title: String = noteTitle(raw, html: isHTML, fallback: name)
                let date: String = noteDate(name: name, mtime: mt)
                var k: Int = 0
                var i: String.Index = text.startIndex
                while i < text.endIndex && k < 6 {
                    let j: String.Index = text.index(i, offsetBy: 6000, limitedBy: text.endIndex) ?? text.endIndex
                    recs.append(["objectID": "note:" + path + "#" + String(k), "type": "note-cafu", "title": title, "date": date,
                                 "url": "file://" + path, "confiance": "note CAFU passée — faits à revérifier avant reprise",
                                 "text": String(text[i..<j]), "chunk": k])
                    k += 1
                    i = j
                }
                changed += 1
            }
        }
        let up = batchUpload(recs)
        if up.err.isEmpty { st["fichiers"] = seen }   // en cas d'échec : on retentera au prochain passage
        st["versés_total"] = ((st["versés_total"] as? Int) ?? 0) + up.sent
        st["at"] = nowISO()
        ingestState.write(st)
        diag["fichiers_vus"] = files
        diag["notes_nouvelles_ou_modifiees"] = changed
        diag["enregistrements_verses"] = up.sent
        diag["versés_total"] = st["versés_total"] ?? 0
        diag["etat"] = up.err.isEmpty ? "ok" : "échec : " + up.err
        return diag
    }

    /// Textes primaires lus (Tavily Extract) pendant un run : versés dans « nova-cafu » (type source-primaire) pour les runs suivants.
    static func saveSources(_ docs: [CafuDoc]) -> String {
        let recs: [[String: Any]] = docs.filter { $0.full }.map { (d: CafuDoc) -> [String: Any] in
            ["objectID": "source:" + norm(d.url), "type": d.official ? "source-primaire" : "source-lue", "title": d.title, "date": d.published,
             "recupere": d.retrieved, "url": d.url,
             "confiance": d.official ? "texte officiel lu en entier (Tavily Extract) le " + d.retrieved : "source lue en entier (Tavily Extract) le " + d.retrieved,
             "text": String(d.content.prefix(6000))]
        }
        if recs.isEmpty { return "aucune" }
        let up = batchUpload(recs)
        return up.err.isEmpty ? String(up.sent) + " versée(s)" : "échec : " + up.err
    }

    // MARK: skill

    /// Installe le skill v2 s'il est absent ou plus ancien (champ « version » de l'en-tête) ; archive « cafu-note-quality » (v1)
    /// en <données Nova>/skills/_archive_cafu-note-quality_<date> (le « _ » l'exclut du magasin, rien n'est effacé).
    @discardableResult
    static func installSkill() -> String {
        let fm: FileManager = FileManager.default
        var note: String
        let cur: String? = NovaSkills.content(skillName)
        let curV: Int = cur.flatMap { Int((NovaSkills.frontMatter($0)["version"] ?? "").trimmingCharacters(in: .whitespaces)) } ?? 0
        if cur == nil || curV < CafuSkillText.version {
            note = NovaSkills.save(name: skillName, content: CafuSkillText.content) ? "installé (v" + String(CafuSkillText.version) + ")" : "ÉCHEC d'écriture du skill"
        } else {
            note = "déjà à jour (v" + String(curV) + ")"
        }
        let old: URL = NovaSkills.dir.appendingPathComponent(oldSkillName, isDirectory: true)
        if fm.fileExists(atPath: old.path) {
            let f: DateFormatter = DateFormatter(); f.locale = Locale(identifier: "en_US_POSIX"); f.dateFormat = "yyyyMMdd-HHmmss"
            let arch: URL = NovaSkills.dir.appendingPathComponent("_archive_" + oldSkillName + "_" + f.string(from: Date()), isDirectory: true)
            if (try? fm.moveItem(at: old, to: arch)) != nil {
                NovaSkills.writeIndex(NovaSkills.scan())
                note += " ; « cafu-note-quality » remplacé (archivé : " + arch.lastPathComponent + ")"
            }
        }
        _ = BlackBox.record(["tool": "skill_install", "actor": "Nova", "ok": !note.hasPrefix("ÉCHEC"), "effect": "config",
                             "why": "mode CAFU : skill cafu-note-quality-v2 au magasin (31/10)", "result": note])
        return note
    }

    /// Démarrage : skill puis versement des notes (arrière-plan, jamais bloquant).
    static func bootstrap() {
        let s: String = installSkill()
        let d: [String: Any] = ingestNotes()
        try? jsonData(["generated": nowISO(), "skill": s, "algolia_notes": d["etat"] ?? ""]).write(to: URL(fileURLWithPath: diagDir + "/cafu_demarrage.json"))
    }

    // MARK: plan de recherche

    /// Sujet de recherche (EN/FR) et pays couverts. Spark 1.3 en effort « low » (appel court), repli déterministe si la réponse
    /// n'est pas exploitable ; les pays reconnus dans la demande sont toujours ajoutés.
    static func plan(runner: BrainRunner, spec: BrainSpec, ask: String, cancel: @escaping () -> Bool) -> (en: String, fr: String, countries: [Country], viaModel: Bool) {
        let sys: String = "You prepare web searches for a humanitarian analyst. Read the request and return ONLY a JSON object, no prose: {\"topic_en\": \"5-10 word search phrase in English, without country names\", \"topic_fr\": \"the same phrase in French\", \"countries\": [\"English name of every country covered\"]}"
        var out: String = ""
        var uin: Int = 0, uout: Int = 0
        let user: String = String(ask.prefix(6000))
        // WP2 : chemin direct (hors Router) — réservé AVANT l'envoi ; refusé → repli déterministe ci-dessous, aucun appel.
        let pf: Preflight = LLMSpend.preflight(spec: spec, estIn: TokenEst.of(sys) + TokenEst.of(user), maxOut: 1500,
                                               lane: LLMSpend.currentLane(background: false))   // demande d'Ahadi (comptée « ahadi » comme avant)
        if let tk = pf.ticket {
            do {
                try runner.stream(spec, messages: [ChatMsg("user", user)], system: sys, maxTokens: 1500, mode: "fast", firstTokenTimeout: CafuMode.planFirstTokenTimeout, cancel: cancel,
                                  onDelta: { out += $0 }, onUsage: { uin = $0; uout = $1 }, reasoningOverride: "low")
                LLMSpend.record(spec.id, inTok: uin > 0 ? uin : TokenEst.of(sys) + TokenEst.of(user), outTok: uout > 0 ? uout : TokenEst.of(out), cacheRead: 0, cacheWrite: 0,
                                background: false, spec: spec, ticket: tk, measured: uin > 0 || uout > 0)
            } catch let f as BrainFailure {
                LLMSpend.abandon(tk, kind: f.kind, produced: !out.isEmpty)
                out = ""
            } catch {
                LLMSpend.abandon(tk, kind: nil, produced: !out.isEmpty)
                out = ""
            }
        }
        var en: String = "", fr: String = ""
        var names: [String] = []
        if let a = out.firstIndex(of: "{"), let b = out.lastIndex(of: "}"), a < b, let o = parseJSON(Data(String(out[a...b]).utf8)) {
            en = str(o["topic_en"]).trimmingCharacters(in: .whitespacesAndNewlines)
            fr = str(o["topic_fr"]).trimmingCharacters(in: .whitespacesAndNewlines)
            names = (o["countries"] as? [String]) ?? []
        }
        var cs: [Country] = detectCountries(ask)
        for n in names {
            let f: String = fold(n).trimmingCharacters(in: .whitespaces)
            if f.isEmpty { continue }
            if let c = countries.first(where: { fold($0.en) == f || fold($0.fr) == f || $0.names.contains(f) }) {
                if !cs.contains(where: { $0.en == c.en }) { cs.append(c) }
            } else if !cs.contains(where: { fold($0.en) == f }) {
                cs.append(Country(en: n, fr: n, francophone: false, names: [], domains: []))
            }
        }
        let viaModel: Bool = !en.isEmpty
        if en.isEmpty { en = String(ask.prefix(160)) }
        if fr.isEmpty { fr = en }
        return (String(en.prefix(160)), String(fr.prefix(160)), cs, viaModel)
    }

    // MARK: dossier et journal

    static func dossier(log: CafuLog, library: String, today: String) -> String {
        var s: String = "RESEARCH DOSSIER — retrieved by Nova before drafting (" + today + ").\n\n"
        s += "INTERNAL LIBRARY (Algolia: past CAFU notes, saved primary texts, Nova memory, Nova libraries and Ahadi's Mac documents):\n" + library + "\n\n"
        s += "WEB SOURCES (Tavily). Cite only these URLs, exactly as written.\n"
        let order: [Int] = log.docs.indices.filter { log.docs[$0].tool != "algolia" }.sorted { (a: Int, b: Int) -> Bool in
            let x: CafuDoc = log.docs[a], y: CafuDoc = log.docs[b]
            if x.full != y.full { return x.full }
            if x.official != y.official { return x.official }
            return x.score > y.score
        }
        var budget: Int = 170_000
        var n: Int = 0
        for i in order {
            let d: CafuDoc = log.docs[i]
            n += 1
            let title: String = d.title.isEmpty ? "(untitled)" : d.title
            let pub: String = d.published.isEmpty ? "not stated by the search engine" : d.published
            let off: String = d.official ? "yes" : "no"
            let full: String = d.full ? "yes" : "no"
            let kind: String = d.full ? "" : (d.pageText ? " · page text returned by the search" : " · search excerpt only")
            var block: String = "\n[S\(n)] \(title)\nURL: \(d.url)\nPublished: \(pub)\nRetrieved: \(d.retrieved) · found by: \(d.tool) (\(d.query))"
            block += "\nOfficial domain: \(off) · full text read (extract): \(full)\(kind)\n"
            let cap: Int = d.full ? 12_000 : (d.pageText ? 2_500 : 500)
            let body: String = String(d.content.prefix(min(cap, max(0, budget))))
            block += body.isEmpty ? "(content omitted: dossier size limit)\n" : body + "\n"
            budget -= body.count
            s += block
        }
        if n == 0 { s += "(none)\n" }
        return s + "\nEND OF DOSSIER\n"
    }

    // MARK: - Échelle de raisonnement (31/10, test réel CAFU 20:58 : « reasoning_effort = max : réponse vide »)

    /// Résultat d'un essai à un niveau de raisonnement.
    enum EffortAttempt: Equatable {
        case text(String)                              // texte visible : la note
        case descend(warning: String, error: String)   // niveau indisponible (refus 400/422, réponse vide, raisonnement sans texte)
        case fail(String)                              // autre échec : arrêt visible, jamais de repli vers un autre cerveau
    }
    /// Plafond de sortie par niveau : chez Meta, le raisonnement compte dans max_tokens — au niveau « max », il a consommé
    /// les 32 000 jetons sans texte visible (≈ 280 s, réponse vide). Le niveau max reçoit donc plus de place.
    static func maxTokens(effort: String, base: Int, atMax: Int) -> Int { effort == "max" ? max(base, atMax) : base }
    /// Délai du premier mot visible : le raisonnement non diffusé le précède (≈ 120 jetons/s observés) — jamais sous 300 s.
    static func firstTokenTimeout(maxTokens: Int) -> TimeInterval { TimeInterval(max(300, maxTokens / 100)) }
    /// 01/11 (test réel 23:00 : « aucune réponse après 60 s », 86 s, aucun appel d'outil — le client du test codait 60 s en dur) :
    /// délais du CLIENT du test d'acceptation (dormant/CAFU_TEST_REQUEST → /api/chat local). Le run traverse la préparation
    /// (Trousseau, versement Algolia, plan), les recherches, puis le raisonnement NON diffusé de Spark 1.3 au niveau max.
    /// Premier octet = délai du premier mot au niveau max + 300 s de préparation ; silence ≥ 600 s et ≥ ce délai + 120 s ;
    /// durée totale ≥ 3 600 s.
    static func testClientTimeouts(maxTokensAtMax: Int) -> (firstByte: TimeInterval, idle: TimeInterval, total: TimeInterval) {
        let ftt: TimeInterval = firstTokenTimeout(maxTokens: maxTokensAtMax)
        let first: TimeInterval = ftt + 300
        let idle: TimeInterval = max(600, ftt + 120)
        return (first, idle, max(3600, first + idle + 1800))
    }
    /// 01/11 : plan de recherche (Spark 1.3, effort « low », 1 500 jetons, repli déterministe) — 120 s avant repli, plus 60 s.
    /// Pas le délai du niveau max : cet appel ne raisonne pas longuement et son échec ne bloque rien.
    static let planFirstTokenTimeout: TimeInterval = 120
    /// 01/11 (run réel 23:07 : « max_tokens: 32000 » journalisé alors que le niveau max reçoit 48 000) : le journal donnait le plafond
    /// du niveau UTILISÉ, vide quand le run s'arrête avant la rédaction (→ la base). Désormais : plafond prévu pour le niveau de
    /// départ de l'échelle (ou le niveau utilisé), plafond par niveau, et plafond réellement ENVOYÉ (0 = rien n'a été envoyé à Spark).
    static func journalMaxTokens(level: String, ladder: [String], base: Int, atMax: Int, sent: Int) -> [String: Any] {
        let lv: String = level.isEmpty ? (ladder.first ?? "max") : level
        var per: [String: Int] = [:]
        for l in ladder { per[l] = maxTokens(effort: l, base: base, atMax: atMax) }
        let mt: Int = maxTokens(effort: lv, base: base, atMax: atMax)
        return ["max_tokens": mt, "max_tokens_niveau": lv, "max_tokens_par_niveau": per, "max_tokens_envoye": sent,
                "premier_mot_s": Int(firstTokenTimeout(maxTokens: mt))]
    }
    /// « Réponse vide » au sens de l'échelle : aucun texte visible (flux vide, raisonnement seul, espaces seulement).
    static func emptyReason(out: String, failure: String?) -> String? {
        guard out.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        guard let f = failure else { return "réponse vide" }
        if f.contains("raisonnement sans texte") { return "raisonnement sans texte" }
        if f.contains("réponse vide") { return "réponse vide" }
        return nil
    }
    /// Parcourt l'échelle à partir de `start` : un niveau indisponible descend d'un cran AVEC avertissement visible
    /// (« Running at xhigh, max unavailable (…) ») ; le dernier niveau indisponible est un échec visible.
    static func runLadder(_ ladder: [String], from start: Int, warn: (String) -> Void,
                          attempt: (String) -> EffortAttempt) -> (text: String, level: String, err: String) {
        var i: Int = max(0, start)
        while i < ladder.count {
            let eff: String = ladder[i]
            switch attempt(eff) {
            case .text(let t): return (t, eff, "")
            case .fail(let e): return ("", eff, e)
            case .descend(let w, let e):
                guard i + 1 < ladder.count else { return ("", eff, e) }
                warn("Running at \(ladder[i + 1]), \(eff) unavailable (\(w))")
                i += 1
            }
        }
        return ("", "", "aucun niveau de raisonnement accepté")
    }

    static func runLog(log: CafuLog, level: String, maxTok: Int, citedKeys: Set<String>, unread: [String], guardRetried: Bool, today: String) -> String {
        var s: String = "\n\n---\nNova run log (CAFU mode, \(today))\n"
        s += "Model: Muse Spark 1.3 (muse-spark-1.3, Meta Model API) · reasoning_effort: \(level) · max_tokens: \(maxTok) · temperature: not sent (not documented by the Meta Model API)\n"
        s += "Searches before drafting: Algolia \(log.algoliaCalls) call(s), \(log.algoliaHits) hit(s) · Tavily \(log.tavilySearches) search(es), \(log.tavilyExtractCalls) extract call(s) · Tavily credits used: \(log.tavilyCredits)\n"
        let guardTxt: String = guardRetried ? "passed after one rewrite" : "passed"
        s += "Citation guard: \(guardTxt) (no cited URL outside the retrieved set)\n"
        for w in log.warnings where !w.hasPrefix("Running at") { s += "Warning: " + w + "\n" }
        if !unread.isEmpty { s += "Cited but full text NOT read (extract failed): " + unread.joined(separator: ", ") + "\n" }
        s += "Sources opened:\n"
        var others: Int = 0
        for d in log.docs {
            let isCited: Bool = citedKeys.contains(norm(d.url))
            if !(d.full || isCited || d.tool == "algolia") { others += 1; continue }
            let tool: String = d.tool == "tavily_extract" ? "Tavily extract" : (d.tool == "algolia" ? "Algolia" : "Tavily search")
            let pub: String = d.published.isEmpty ? "not stated" : String(d.published.prefix(32))
            let full: String = d.full ? "yes" : "no"
            let ct: String = isCited ? "yes" : "no"
            s += "- \(tool) | query: \"\(d.query)\" | \(d.url) | published: \(pub) | retrieved: \(d.retrieved) | full text read: \(full) | cited: \(ct)\n"
        }
        if others > 0 { s += "(" + String(others) + " further search result(s) seen as excerpts only — full list in releves/diag/cafu_runs.jsonl)\n" }
        return s
    }

    static func appendRun(_ o: [String: Any]) {
        let path: String = diagDir + "/cafu_runs.jsonl"
        var line: Data = jsonData(o)
        line.append(0x0A)
        if let h = FileHandle(forWritingAtPath: path) {
            h.seekToEndOfFile(); h.write(line); h.closeFile()
        } else {
            try? line.write(to: URL(fileURLWithPath: path))
        }
    }
}

extension NovaApp {
    /// 31/10 (CAFU) : run complet du mode CAFU sur la route /api/chat (le message d'Ahadi est déjà dans le fil, « meta » déjà émis).
    func cafuRun(cid: String, ask askIn: String, test testIn: Bool, incognito: Bool, chatT0: Date, res: Response) {
        let log: CafuLog = CafuLog()
        let today: String = CafuMode.dmy(Date())
        let isTest: Bool = testIn || CafuMode.isTestCommand(askIn)
        let ask: String = isTest && CafuMode.isTestCommand(askIn) ? CafuMode.calibrationBrief : askIn
        let ladder0: [String] = settings.get("cafu_effort_echelle", ["max", "xhigh", "high"])
        let ladder: [String] = ladder0.isEmpty ? ["max", "xhigh", "high"] : ladder0
        let maxTok: Int = max(16000, settings.get("cafu_max_tokens", 32000))
        let maxTokAtMax: Int = max(maxTok, settings.get("cafu_max_tokens_niveau_max", 48000))   // 31/10 : le raisonnement « max » compte dans max_tokens
        let algoliaRequired: Bool = settings.get("cafu_algolia_obligatoire", true)
        let capTurn: Double = settings.get("cafu_plafond_usd", settings.get("plafond_par_demande_usd", 0.40))
        let extraDomains: [String] = settings.get("cafu_domaines_officiels", [String]())
        let maxSearches: Int = min(12, max(3, settings.get("cafu_tavily_max_recherches", 8)))
        let maxExtract: Int = min(20, max(1, settings.get("cafu_extract_max", 6)))
        let cancel: () -> Bool = { Tools.isStopped(cid, since: chatT0) }
        var level: String = ""
        var citedList: [String] = []
        var outsideFinal: [String] = []
        var unread: [String] = []
        var guardRetried: Bool = false
        var stepIdx: Int = 0
        var sentTok: Int = 0              // 01/11 : max_tokens réellement envoyé au dernier appel de rédaction (0 = aucun)
        var okSearches: Int = 0
        var stepsLog: [String] = []       // 01/11 : étapes horodatées (où passe le temps : préparation, recherches, rédaction)
        var algoliaStates: [String: String] = [:]   // 01/11 : état honnête index par index (nova-cafu, nova-bibliotheque, nova-memoire)
        var relectureInfo: [String: Any] = [:]       // 01/11 (bonus open-weight) : passe de relecture Spark Open (Baseten)

        func step(_ tool: String, _ arg: String, _ state: String) {
            stepIdx += 1
            let ts: String = nowISO()
            let sec: Int = Int(Date().timeIntervalSince(chatT0))
            stepsLog.append(ts + " (+" + String(sec) + " s) " + tool + " [" + state + "] " + String(arg.prefix(200)))
            res.sse("step", ["id": "cafu-" + String(stepIdx), "index": stepIdx, "tool": tool, "arg": String(arg.prefix(240)), "state": state, "ts": ts])
        }
        func summary(ok: Bool, error: String) -> [String: Any] {
            let citedKeys: Set<String> = Set(citedList.map { CafuMode.norm($0) })
            let srcs: [[String: Any]] = log.docs.map { (d: CafuDoc) -> [String: Any] in
                ["outil": d.tool, "requete": d.query, "url": d.url, "titre": d.title, "publie": d.published, "recupere": d.retrieved,
                 "texte_complet_lu": d.full, "texte_de_page_recherche": d.pageText, "officiel": d.official, "cite": citedKeys.contains(CafuMode.norm(d.url))]
            }
            let conv: String = incognito ? "hors mémoire" : cid
            let demande: String = String(SecretsGuard.redact(ask).prefix(400))
            let cost: Double = (LLMSpend.turnSpent() * 10000).rounded() / 10000
            let ms: Int = Int(Date().timeIntervalSince(chatT0) * 1000)
            var s: [String: Any] = ["ts": nowISO(), "ok": ok, "test": isTest, "conversation": conv, "demande": demande]
            s["cerveau"] = CafuMode.brainId
            s["modele"] = "muse-spark-1.3"
            s["raisonnement_utilise"] = level
            s["echelle"] = ladder
            for (k, v) in CafuMode.journalMaxTokens(level: level, ladder: ladder, base: maxTok, atMax: maxTokAtMax, sent: sentTok) { s[k] = v }
            s["temperature"] = "non envoyée (non documentée par l'API Meta)"
            s["avertissements"] = log.warnings
            s["algolia_appels"] = log.algoliaCalls
            s["algolia_resultats"] = log.algoliaHits
            s["tavily_recherches"] = log.tavilySearches
            s["tavily_recherches_reussies"] = okSearches
            s["algolia_index"] = algoliaStates
            s["etapes"] = stepsLog
            if !relectureInfo.isEmpty { s["relecture_open_weight"] = relectureInfo }
            s["tavily_extract_appels"] = log.tavilyExtractCalls
            s["tavily_credits"] = log.tavilyCredits
            s["appels"] = log.events
            s["citations"] = citedList
            s["citations_hors_ensemble"] = outsideFinal
            s["citees_non_lues"] = unread
            s["garde_relance"] = guardRetried
            s["sources"] = srcs
            s["cout_llm_usd"] = cost
            s["duree_ms"] = ms
            if !error.isEmpty { s["erreur"] = error }
            return s
        }
        func finish(ok: Bool, text: String, error: String) {
            let sm: [String: Any] = summary(ok: ok, error: error)
            CafuMode.appendRun(sm)
            res.sse("cafu_run", sm)
            res.sse("delta", ["t": text])
            let ckBrain: String = level.isEmpty ? "Spark 1.3 · mode CAFU" : "Spark 1.3 · mode CAFU (\(level))"
            _ = convs.checkpoint(cid, content: text, brain: ckBrain, final: true)
            if ok { ChatTasks.clear(cid) }
            let lv: String = level.isEmpty ? "non lancé" : level
            let why: String = "mode CAFU : recherche obligatoire puis Spark 1.3 (\(lv))"
            let result: String = ok ? "note livrée, \(log.tavilySearches) recherches Tavily, \(log.tavilyCredits) crédits" : String(error.prefix(200))
            _ = BlackBox.record(["tool": "cafu_mode", "actor": "Nova", "ok": ok, "effect": "lecture", "why": why, "result": result])
            let label: String = level.isEmpty ? "Spark 1.3 · mode CAFU" : "Spark 1.3 · mode CAFU · \(level)"
            let totalMs: Int = Int(Date().timeIntervalSince(chatT0) * 1000)
            let cost: Double = (LLMSpend.turnSpent() * 10000).rounded() / 10000
            res.sse("done", ["brain": CafuMode.brainId, "label": label, "light": false, "ttft_ms": -1, "total_ms": totalMs, "cout_usd": cost])
        }
        func fail(_ why: String) {
            step("mode CAFU", "arrêt : " + why, "err")
            let msg: String = "⛔ Mode CAFU arrêté avant rédaction : " + why
                + "\nAucune réponse n'a été rédigée de mémoire (règle CAFU : rechercher d'abord). Corrige la cause puis relance, ou coupe le mode avec le réglage « cafu_mode » = false."
            finish(ok: false, text: msg, error: why)
        }

        // 01/11 (test réel 23:00 : le client n'a rien vu en 60 s) : commentaire SSE de 2 Ko d'emblée — certains clients HTTP retiennent
        // les premiers octets d'un flux avant de le livrer ; un commentaire « : » est ignoré par les lecteurs SSE (web et test).
        res.chunk(Data((":" + String(repeating: " ", count: 2048) + "\n\n").utf8))
        step("mode CAFU", "demande de note CAFU / GHO / brief de contexte : recherche obligatoire, puis Spark 1.3 au raisonnement maximal", "ok")

        // 1) Cerveau épinglé, clés et budget.
        guard let spec = router.spec(CafuMode.brainId) else { fail("Spark 1.3 (spark-1.3) absent du catalogue des cerveaux"); return }
        if router.disabled.contains(spec.id) { fail("Spark 1.3 est coupé dans tes réglages (brains_off) — réactive-le, ou coupe le mode CAFU"); return }
        if spec.keys.resolve(router.runner.keys) == nil { fail("clé Meta Model API absente du Trousseau (Connexions › Meta Model API — Muse)"); return }
        let spent = LLMSpend.spent()
        if spent.month >= LLMSpend.monthBudget() {
            let a: String = String(format: "%.2f", spent.month), b: String = String(format: "%.0f", LLMSpend.monthBudget())
            fail("budget LLM du mois atteint (\(a) $ sur \(b) $)"); return
        }
        if Credits.isOpen("tavily") { fail("Tavily indisponible : disjoncteur ouvert après des échecs récents (crédits épuisés ou clé refusée ?)"); return }
        guard let tk = KeychainStore().value(KnownKeys.tavilyNova), !tk.isEmpty else { fail("clé Tavily absente du Trousseau (service « nova-tavily »)"); return }

        // 2) Bibliothèque interne à jour (notes nouvelles ou modifiées), puis plan de recherche.
        let ing: [String: Any] = CafuMode.ingestNotes()
        step("algolia", "notes CAFU versées dans l'index nova-cafu : " + CafuMode.str(ing["etat"]), (CafuMode.str(ing["etat"]) == "ok") ? "ok" : "err")
        if cancel() { fail("arrêté par Ahadi"); return }
        let plan = CafuMode.plan(runner: router.runner, spec: spec, ask: ask, cancel: cancel)
        step("plan", "sujet : " + plan.en + " · pays : " + (plan.countries.isEmpty ? "aucun reconnu" : plan.countries.map { $0.en }.joined(separator: ", ")), "ok")
        if !plan.viaModel { log.warnings.append("Search plan built without the model (planner reply unusable): queries use the raw request.") }

        // 3a) Algolia.
        let aq: String = (plan.countries.map { $0.en }.joined(separator: " ") + " " + plan.en).trimmingCharacters(in: .whitespaces)
        let al = CafuMode.algoliaQuery(aq)
        algoliaStates = al.states
        log.algoliaCalls += al.calls
        log.events.append(["outil": "algolia", "requete": aq, "ok": al.ok, "resultats": al.hits.count, "cle": al.keyKind, "note": al.err,
                           "index": algoliaStates])
        // 01/11 : état honnête — l'index des notes CAFU muet n'est pas masqué par les résultats des autres index ; la clé employée est dite.
        if al.ok, let st = algoliaStates[CafuMode.algoliaIndex], !st.hasPrefix("ok") {
            log.warnings.append("CAFU notes index (" + CafuMode.algoliaIndex + ") " + st + ": internal hits come only from the other indexes.")
        }
        if al.keyKind.hasPrefix("clé d'écriture") {
            log.warnings.append("Algolia searched with the write key: no search-only key (Keychain « nova-algolia-search ») — add it to stop using the write key for reads.")
        }
        var library: String = ""
        if !al.ok {
            if algoliaRequired {
                fail("bibliothèque interne Algolia indisponible — " + al.err + ". Si seule la clé de recherche manque : ajoute-la au Trousseau (« nova-algolia-search »), ou mets le réglage « cafu_algolia_obligatoire » à false pour continuer sans la bibliothèque interne")
                return
            }
            log.warnings.append("Internal library (Algolia) unavailable: " + al.err + " — run continued because cafu_algolia_obligatoire = false.")
            library = "(unavailable: " + al.err + ")"
        } else {
            log.algoliaHits = al.hits.count
            var lines: [String] = []
            for (i, h) in al.hits.enumerated() {
                let url: String = CafuMode.str(h["url"]).isEmpty ? CafuMode.str(h["ref"]) : CafuMode.str(h["url"])
                let conf: String = CafuMode.str(h["confiance"]).isEmpty ? "Nova memory, unverified" : CafuMode.str(h["confiance"])
                let txt: String = CafuMode.str(h["text"]).isEmpty ? CafuMode.str(h["snippet"]) : CafuMode.str(h["text"])
                let ttl: String = CafuMode.str(h["title"]).isEmpty ? "(untitled)" : CafuMode.str(h["title"])
                let dt: String = CafuMode.str(h["date"]).isEmpty ? "not stated" : CafuMode.str(h["date"])
                let src: String = url.isEmpty ? "none" : url
                let idx: String = CafuMode.str(h["_index"])
                let exc: String = String(txt.prefix(700)).replacingOccurrences(of: "\n", with: " ")
                lines.append("- [L\(i + 1)] \(ttl) | date: \(dt) | source: \(src) | confidence: \(conf) | index: \(idx)\n  excerpt: \(exc)")
                if url.hasPrefix("http") {
                    log.add(CafuDoc(url: url, title: CafuMode.str(h["title"]), published: CafuMode.str(h["date"]), retrieved: today, content: String(txt.prefix(2500)),
                                    full: false, pageText: false, tool: "algolia", query: aq, official: CafuMode.isOfficial(url, extra: extraDomains), score: 0))
                }
            }
            let errTail: String = al.err.isEmpty ? "" : " — " + al.err
            library = lines.isEmpty ? "(searched: no earlier note or verified fact on this topic\(errTail))" : lines.joined(separator: "\n")
        }
        let alTail: String = al.err.isEmpty ? "" : " — " + al.err
        let alIdxErr: Bool = algoliaStates.values.contains(where: { $0.hasPrefix("échec") })
        step("algolia", "bibliothèque interne : \(al.hits.count) résultat(s)\(alTail)", (al.ok && !alIdxErr) ? "ok" : "err")

        // 3b) Tavily : ≥ 3 recherches (actualité 12 mois, sources officielles, français pour les pays francophones).
        let qs: [CafuMode.Query] = CafuMode.queries(topicEn: plan.en, topicFr: plan.fr, countries: plan.countries, extraDomains: extraDomains, maxN: maxSearches)
        var totalResults: Int = 0
        var skipped: [String] = []
        queryLoop: for qq in qs {
            if cancel() { fail("arrêté par Ahadi"); return }
            var attempts: [[String]] = [qq.domains]
            if !qq.domains.isEmpty { attempts.append([]) }   // domaines officiels sans résultat → une reprise sans filtre, comptée
            for (ai, doms) in attempts.enumerated() {
                let qtext: String = ai == 0 ? qq.q : qq.q + " government official text"
                var body: [String: Any] = ["query": String(qtext.prefix(380)), "search_depth": "advanced", "max_results": 10, "include_raw_content": true,
                                           "topic": qq.topic, "time_range": "year", "include_usage": true]
                if qq.topic == "general" { body["include_published_date"] = true }
                if !doms.isEmpty { body["include_domains"] = Array(Set(doms)).sorted() }
                // 01/11 : 90 s par essai (recherche advanced + raw_content), 2 reprises sur échec passager.
                let rr = CafuMode.withRetry(cancel: cancel) { CafuMode.tavily("search", key: tk, body: body, timeout: 90) }
                let (st, o, err) = (rr.st, rr.o, rr.err)
                log.tavilySearches += rr.tries
                if st != 200 {
                    if st > 0 && !CafuMode.tavilyTransient(st) { Credits.providerFailed("tavily", status: st, detail: err) }   // 01/11 : un échec passager sauté n'ouvre pas le disjoncteur
                    log.events.append(["outil": "tavily_search", "requete": qtext, "type": qq.label, "ok": false, "erreur": err, "essais": rr.tries,
                                       "sautee": CafuMode.tavilyTransient(st)])
                    if cancel() { fail("arrêté par Ahadi"); return }
                    if CafuMode.tavilyTransient(st) {
                        let w: String = "Tavily search skipped after " + String(rr.tries) + " attempts (" + qq.label + "): " + (err.isEmpty ? "no response" : err)
                        log.warnings.append(w)
                        skipped.append(qq.label + " : " + (err.isEmpty ? "pas de réponse" : err))
                        step("tavily", qq.label + " : sautée après " + String(rr.tries) + " essais — " + (err.isEmpty ? "pas de réponse" : err), "err")
                        continue queryLoop
                    }
                    fail("recherche Tavily en échec (" + qq.label + ") : " + (err.isEmpty ? "pas de réponse" : err))
                    return
                }
                let cr: Int = CafuMode.credits(o, fallback: 2)
                log.tavilyCredits += cr
                Credits.count("tavily", n: cr)
                okSearches += 1
                let results: [[String: Any]] = (o?["results"] as? [[String: Any]]) ?? []
                log.events.append(["outil": "tavily_search", "requete": qtext, "type": qq.label, "ok": true, "resultats": results.count, "credits": cr,
                                   "domaines": doms])
                step("tavily", qq.label + " : " + String(results.count) + " résultat(s)", "ok")
                for r in results {
                    let u: String = CafuMode.str(r["url"])
                    if u.isEmpty { continue }
                    let raw: String = CafuMode.str(r["raw_content"])
                    log.add(CafuDoc(url: u, title: CafuMode.str(r["title"]), published: CafuMode.str(r["published_date"]), retrieved: today,
                                    content: raw.isEmpty ? CafuMode.str(r["content"]) : raw, full: false, pageText: !raw.isEmpty, tool: "tavily_search",
                                    query: qtext, official: CafuMode.isOfficial(u, extra: extraDomains), score: CafuMode.num(r["score"])))
                }
                totalResults += results.count
                if !results.isEmpty { break }
            }
        }
        if let why = CafuMode.searchPhaseVerdict(okSearches: okSearches, totalResults: totalResults, skipped: skipped) { fail(why); return }

        // 3c) Tavily Extract sur les meilleures sources primaires (domaines officiels d'abord, puis pertinence).
        let cand: [String] = log.docs.filter { $0.tool == "tavily_search" }.sorted { (a: CafuDoc, b: CafuDoc) -> Bool in
            if a.official != b.official { return a.official }
            return a.score > b.score
        }.prefix(maxExtract).map { $0.url }
        func extract(_ urls: [String], why: String) -> (ok: Int, err: String) {
            if urls.isEmpty { return (0, "") }
            var okN: Int = 0
            var i: Int = 0
            while i < urls.count {
                let part: [String] = Array(urls[i..<min(i + 20, urls.count)])
                i += 20
                let rr = CafuMode.withRetry(cancel: cancel) {
                    CafuMode.tavily("extract", key: tk, body: ["urls": part, "extract_depth": "advanced", "format": "markdown", "include_usage": true, "timeout": 60], timeout: 90)
                }
                let (st, o, err) = (rr.st, rr.o, rr.err)
                log.tavilyExtractCalls += rr.tries
                if st != 200 {
                    if st > 0 { Credits.providerFailed("tavily", status: st, detail: err) }
                    log.events.append(["outil": "tavily_extract", "motif": why, "urls": part, "ok": false, "erreur": err])
                    return (okN, err.isEmpty ? "pas de réponse" : err)
                }
                let rs: [[String: Any]] = (o?["results"] as? [[String: Any]]) ?? []
                let failed: [[String: Any]] = (o?["failed_results"] as? [[String: Any]]) ?? []
                let cr: Int = CafuMode.credits(o, fallback: rs.isEmpty ? 0 : 2 * ((rs.count + 4) / 5))
                log.tavilyCredits += cr
                if cr > 0 { Credits.count("tavily", n: cr) }
                let echecs: [String] = failed.map { (f: [String: Any]) -> String in CafuMode.str(f["url"]) + " : " + CafuMode.str(f["error"]) }
                log.events.append(["outil": "tavily_extract", "motif": why, "urls": part, "ok": true, "lues": rs.count, "echecs": echecs, "credits": cr])
                for r in rs {
                    let u: String = CafuMode.str(r["url"])
                    let raw: String = CafuMode.str(r["raw_content"])
                    if u.isEmpty || raw.count < 200 { continue }
                    okN += 1
                    log.add(CafuDoc(url: u, title: "", published: "", retrieved: today, content: raw, full: true, pageText: true, tool: "tavily_extract",
                                    query: why, official: CafuMode.isOfficial(u, extra: extraDomains), score: 0))
                }
            }
            return (okN, "")
        }
        if cancel() { fail("arrêté par Ahadi"); return }
        let ex = extract(cand, why: "top primary sources")
        if !ex.err.isEmpty && ex.ok == 0 { fail("Tavily Extract en échec : " + ex.err); return }
        if !ex.err.isEmpty { log.warnings.append("Tavily Extract partly failed after retries: " + ex.err) }
        if ex.ok == 0 { fail("Tavily Extract n'a rendu aucun texte complet sur les " + String(cand.count) + " meilleures sources"); return }
        step("tavily", "extract : " + String(ex.ok) + " texte(s) complet(s) lus sur " + String(cand.count), "ok")

        // 4) Rédaction : Spark 1.3 épinglé, raisonnement max → xhigh → high (refus visible, jamais silencieux).
        let sys: String = CafuMode.runtimeProtocol + "\n\n" + CafuMode.orchestrationRules(today: today)
            + "\n\nFULL METHOD — skill cafu-note-quality-v2 (apply it; the calibration reference facts are deliberately withheld):\n" + CafuMode.method
        let userBlock: String = CafuMode.dossier(log: log, library: library, today: today) + "\n\nREQUEST FROM AHADI:\n" + ask
        var msgs: [ChatMsg] = isTest ? [] : convs.history(cid, tokenBudget: 6000)
        if let li = msgs.lastIndex(where: { $0.role == "user" }) { msgs[li] = ChatMsg("user", userBlock) } else { msgs.append(ChatMsg("user", userBlock)) }
        res.sse("brain", ["id": spec.id, "label": spec.label])

        func callSpark(_ m: [ChatMsg]) -> (text: String, err: String) {
            let start: Int = level.isEmpty ? 0 : (ladder.firstIndex(of: level) ?? 0)   // un niveau accepté est gardé pour la relance
            let r = CafuMode.runLadder(ladder, from: start, warn: { (w: String) in log.warnings.append(w); step("raisonnement", w, "err") }) { (eff: String) -> CafuMode.EffortAttempt in
                if capTurn > 0 && LLMSpend.turnSpent() >= capTurn {
                    let a: String = String(format: "%.2f", LLMSpend.turnSpent()), b: String = String(format: "%.2f", capTurn)
                    return .fail("plafond de dépense de la demande atteint (\(a) $ sur \(b) $ — réglage cafu_plafond_usd)")
                }
                let tok: Int = CafuMode.maxTokens(effort: eff, base: maxTok, atMax: maxTokAtMax)
                let ftt: TimeInterval = CafuMode.firstTokenTimeout(maxTokens: tok)
                step("cerveau", "Spark 1.3 rédige (reasoning_effort = " + eff + ", max_tokens = " + String(tok) + ", premier mot ≤ " + String(Int(ftt)) + " s)", "ok")
                var out: String = ""
                var uin: Int = 0, uout: Int = 0
                var stop: String = ""
                var lastKA: Date = Date()
                // WP2 : chemin direct (hors Router) — chaque niveau de raisonnement (relance) est réservé AVANT l'envoi.
                let pf: Preflight = LLMSpend.preflight(spec: spec, estIn: TokenEst.of(sys) + TokenEst.of(m), maxOut: tok,
                                                       lane: LLMSpend.currentLane(background: false))   // demande d'Ahadi (comptée « ahadi » comme avant)
                guard let tk = pf.ticket else {
                    if case .refused(let why) = pf { return .fail("Budget : " + why + " — rien n'est envoyé.") }
                    return .fail("Budget : réservation impossible")
                }
                sentTok = tok
                log.events.append(["outil": "spark", "raisonnement": eff, "max_tokens": tok, "premier_mot_s": Int(ftt)])
                do {
                    // La note est retenue jusqu'à la garde de citation (rien n'est montré avant) : commentaire SSE « : cafu » toutes les
                    // 10 s pour que le fil reste vivant pendant la rédaction (ignoré par les lecteurs SSE).
                    try router.runner.stream(spec, messages: m, system: sys, maxTokens: tok, mode: "deep", firstTokenTimeout: ftt, cancel: cancel,
                                             onDelta: { (t: String) in
                                                 out += t
                                                 if Date().timeIntervalSince(lastKA) > 10 { lastKA = Date(); res.chunk(Data(": cafu\n\n".utf8)) }
                                             },
                                             onUsage: { uin = $0; uout = $1 }, onStop: { stop = $0 }, reasoningOverride: eff)
                } catch let f as BrainFailure {
                    LLMSpend.abandon(tk, kind: f.kind, produced: !out.isEmpty)   // réponse vide : réservation gardée (raisonnement facturé)
                    let failMsg: String = "Spark 1.3 a échoué (reasoning_effort = " + eff + ") : " + f.message
                    if out.isEmpty && (f.message.contains("HTTP 400") || f.message.contains("HTTP 422")) {
                        return .descend(warning: "API refused reasoning_effort \"\(eff)\": " + String(f.message.prefix(160)), error: failMsg)
                    }
                    if let why = CafuMode.emptyReason(out: out, failure: f.message) { return .descend(warning: why, error: failMsg) }
                    return .fail(failMsg)
                } catch {
                    LLMSpend.abandon(tk, kind: nil, produced: !out.isEmpty)
                    return .fail("Spark 1.3 : " + error.localizedDescription)
                }
                LLMSpend.record(spec.id, inTok: uin > 0 ? uin : TokenEst.of(sys) + TokenEst.of(m), outTok: uout > 0 ? uout : TokenEst.of(out), cacheRead: 0, cacheWrite: 0,
                                background: false, spec: spec, ticket: tk, measured: uin > 0 || uout > 0)
                if let why = CafuMode.emptyReason(out: out, failure: nil) {   // flux terminé sans texte visible (espaces seulement)
                    return .descend(warning: why, error: "Spark 1.3 a échoué (reasoning_effort = " + eff + ") : " + why)
                }
                if stop == "max_tokens" { log.warnings.append("Output reached the " + String(tok) + "-token cap: the note may be truncated.") }
                if stop == "cut" { log.warnings.append("The stream was cut before the end: the note may be incomplete.") }
                return .text(out)
            }
            if r.err.isEmpty { level = r.level }
            return (r.text, r.err)
        }

        if cancel() { fail("arrêté par Ahadi"); return }
        let r1 = callSpark(msgs)
        if r1.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { fail(r1.err.isEmpty ? "Spark 1.3 n'a rendu aucun texte" : r1.err); return }
        var note: String = r1.text

        // 5) Garde de citation : URL hors des résultats récupérés → une relance, sinon refus visible.
        var outside: [String] = CafuMode.cited(note).filter { log.index[CafuMode.norm($0)] == nil }
        if !outside.isEmpty {
            guardRetried = true
            step("garde de citation", String(outside.count) + " URL hors des résultats récupérés : relance unique pour les retirer ou les remplacer", "err")
            let r2 = callSpark(msgs + [ChatMsg("assistant", note), ChatMsg("user", CafuMode.guardNote(outside))])
            if !r2.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { note = r2.text }
            outside = CafuMode.cited(note).filter { log.index[CafuMode.norm($0)] == nil }
            if !outside.isEmpty {
                outsideFinal = outside
                citedList = CafuMode.cited(note)
                let msg: String = "⛔ Réponse bloquée par la garde de citation (mode CAFU) : après une relance, la note cite encore des URL absentes des résultats récupérés :\n"
                    + outside.map { "- " + $0 }.joined(separator: "\n") + "\nLe brouillon n'est pas affiché (journal : releves/diag/cafu_runs.jsonl). Relance la demande ou précise les sources à utiliser."
                step("garde de citation", "refus : " + String(outside.count) + " URL hors ensemble", "err")
                finish(ok: false, text: msg, error: "garde de citation : " + outside.joined(separator: ", ") + (r2.err.isEmpty ? "" : " ; relance : " + r2.err))
                return
            }
        }
        citedList = CafuMode.cited(note)
        step("garde de citation", String(citedList.count) + " URL citée(s), toutes dans les résultats récupérés", "ok")

        // 6) Extract automatique sur chaque URL citée pas encore lue en texte complet.
        let citedKeys: Set<String> = Set(citedList.map { CafuMode.norm($0) })
        var toRead: [String] = []
        for k in citedKeys { if let i = log.index[k], !log.docs[i].full { toRead.append(log.docs[i].url) } }
        if !toRead.isEmpty {
            let ex2 = extract(toRead, why: "cited URL")
            if !ex2.err.isEmpty { log.warnings.append("Extract on cited URLs failed: " + ex2.err) }
            step("tavily", "extract des URL citées : " + String(ex2.ok) + "/" + String(toRead.count) + " lue(s) en texte complet", ex2.err.isEmpty ? "ok" : "err")
        }
        for k in citedKeys { if let i = log.index[k], !log.docs[i].full { unread.append(log.docs[i].url) } }
        let saved: String = CafuMode.saveSources(log.docs)
        log.events.append(["outil": "algolia_ecriture", "objet": "textes lus versés dans nova-cafu", "resultat": saved])

        // 6 bis) 01/11 (bonus open-weight) : Spark Open (poids ouverts Meta, Baseten) relit la note rédigée par Spark 1.3 —
        // faits, étiquettes, score. Seul le texte de la note part (masqué par SecretsGuard). Réglage cafu_relecture_open_weight (défaut vrai).
        var relecture: String = ""
        if settings.get("cafu_relecture_open_weight", true) && !cancel() {
            if capTurn > 0 && LLMSpend.turnSpent() >= capTurn {
                step("relecture open-weight", "sautée : plafond de dépense de la demande atteint", "err")
                relectureInfo = ["statut": "saute", "detail": "plafond de la demande"]
            } else {
                step("relecture open-weight", "Spark Open relit la note : faits, étiquettes, score (Baseten, poids ouverts Meta)", "ok")
                let rv = MetaSpecialites.relireNoteCafu(router: router, note: note, cancel: cancel)
                relectureInfo = ["statut": rv.statut, "modele": "meta-models/muse-spark-open", "fournisseur": "baseten",
                                 "cout_usd": (rv.cost * 1_000_000).rounded() / 1_000_000, "tarif": "1,25 $ / 4,25 $ par M (page Baseten du compte, 01/11/2026)"]
                if !rv.detail.isEmpty { relectureInfo["detail"] = String(rv.detail.prefix(300)) }
                if let t = rv.text {
                    relecture = t
                    step("relecture open-weight", "Spark Open : relecture reçue (" + String(format: "%.4f", rv.cost) + " $ au tarif Baseten)", "ok")
                } else {
                    step("relecture open-weight", "Spark Open : " + rv.statut + " — " + String(rv.detail.prefix(160)), "err")
                }
            }
        }

        // 7) Fil : avertissement de niveau en tête, note, journal machine.
        var head: String = ""
        for w in log.warnings where w.hasPrefix("Running at") { head += "⚠️ " + w + "\n" }
        if !head.isEmpty { head += "\n" }
        let relBlock: String = relecture.isEmpty ? "" : ("\n\n---\nSpark Open QA review (open-weight Meta model on Baseten, after drafting by Spark 1.3)\n" + relecture)
        let text: String = head + note.trimmingCharacters(in: .whitespacesAndNewlines)
            + CafuMode.runLog(log: log, level: level, maxTok: CafuMode.maxTokens(effort: level, base: maxTok, atMax: maxTokAtMax), citedKeys: citedKeys, unread: unread, guardRetried: guardRetried, today: today)
            + relBlock
        finish(ok: true, text: text, error: "")
    }

    /// 31/10 (CAFU) : TEST D'ACCEPTATION SANS ÉCRAN. dormant/CAFU_TEST_REQUEST (ou .json, contenu facultatif {"brief": "…"}) → le brief
    /// de calibration du skill passe par la vraie route /api/chat (fil « hors mémoire », aucun outil, RIEN n'est envoyé à personne) ;
    /// résultat et journal dans releves/diag/cafu_test.json. La demande est renommée dormant/CAFU_TEST_REQUEST.done.json.
    func cafuTestPoll(root: String) {
        let fm: FileManager = FileManager.default
        var req: String = ""
        for n in ["CAFU_TEST_REQUEST", "CAFU_TEST_REQUEST.json"] where fm.fileExists(atPath: root + "/dormant/" + n) { req = root + "/dormant/" + n; break }
        if req.isEmpty { return }
        let cfg: [String: Any] = (try? Data(contentsOf: URL(fileURLWithPath: req))).flatMap { parseJSON($0) } ?? [:]
        try? fm.removeItem(atPath: root + "/dormant/CAFU_TEST_REQUEST.done.json")
        try? fm.moveItem(atPath: req, toPath: root + "/dormant/CAFU_TEST_REQUEST.done.json")
        Thread.detachNewThread { [weak self] in self?.cafuTestRun(cfg, root: root) }
    }

    func cafuTestRun(_ cfg: [String: Any], root: String) {
        let out: String = root + "/releves/diag/cafu_test.json"
        let started: String = nowISO()
        let brief: String = ((cfg["brief"] as? String) ?? "").isEmpty ? CafuMode.calibrationBrief : ((cfg["brief"] as? String) ?? "")
        try? jsonData(["started": started, "etat": "en cours", "brief": brief]).write(to: URL(fileURLWithPath: out))
        guard server.port > 0, let url = URL(string: "http://127.0.0.1:" + String(server.port) + "/api/chat") else {
            try? jsonData(["started": started, "etat": "échec", "erreur": "serveur local pas prêt"]).write(to: URL(fileURLWithPath: out)); return
        }
        var r: URLRequest = URLRequest(url: url)
        r.httpMethod = "POST"
        r.setValue("application/json", forHTTPHeaderField: "Content-Type")
        r.setValue(server.token, forHTTPHeaderField: "x-nova-token")
        r.httpBody = jsonData(["text": brief, "incognito": true, "tools": false, "mode": "deep", "cafu_test": true, "autonomie": "cowork"])
        let lock: NSLock = NSLock()
        var buf: Data = Data()
        let t0: Date = Date()
        // 01/11 (test réel 23:00 : 60 s en dur → « aucune réponse après 60 s ») : délais tirés du plafond du niveau max.
        let base: Int = max(16000, settings.get("cafu_max_tokens", 32000))
        let tmo = CafuMode.testClientTimeouts(maxTokensAtMax: max(base, settings.get("cafu_max_tokens_niveau_max", 48000)))
        let hr: HTTPResult = HTTPStream.run(r, firstByteTimeout: tmo.firstByte, idleTimeout: tmo.idle, totalTimeout: tmo.total) { (d: Data) -> Bool in
            lock.lock(); buf.append(d); lock.unlock(); return true
        }
        lock.lock(); let raw: String = String(decoding: buf, as: UTF8.self); lock.unlock()
        var answer: String = "", steps: [String] = [], errs: [String] = []
        var run: [String: Any] = [:]
        for block in raw.components(separatedBy: "\n\n") {
            var ev: String = "", data: String = ""
            for l in block.components(separatedBy: "\n") {
                if l.hasPrefix("event: ") { ev = String(l.dropFirst(7)) } else if l.hasPrefix("data: ") { data += String(l.dropFirst(6)) }
            }
            guard !ev.isEmpty, let o = parseJSON(Data(data.utf8)) else { continue }
            switch ev {
            case "delta": answer += CafuMode.str(o["t"])
            case "step": steps.append(CafuMode.str(o["ts"]) + " " + CafuMode.str(o["tool"]) + " [" + CafuMode.str(o["state"]) + "] " + CafuMode.str(o["arg"]))
            case "error": errs.append(String(CafuMode.str(o["message"]).prefix(300)))
            case "cafu_run": run = o
            default: break
            }
        }
        let level: String = CafuMode.str(run["raisonnement_utilise"])
        let warns: [String] = (run["avertissements"] as? [String]) ?? []
        let cited: [String] = (run["citations"] as? [String]) ?? []
        let outside: [String] = (run["citations_hors_ensemble"] as? [String]) ?? []
        let unreadC: [String] = (run["citees_non_lues"] as? [String]) ?? []
        let algN: Int = (run["algolia_appels"] as? Int) ?? 0
        let tavN: Int = (run["tavily_recherches_reussies"] as? Int) ?? 0   // 01/11 : recherches RÉUSSIES (les essais repris ne comptent pas)
        let exN: Int = (run["tavily_extract_appels"] as? Int) ?? 0
        let levelOK: Bool = level == "max" || (level == "xhigh" && warns.contains(where: { $0.hasPrefix("Running at xhigh") }))
        let runOK: Bool = (run["ok"] as? Bool) == true
        var checks: [String: Bool] = [:]
        checks["raisonnement_max_ou_xhigh_avec_avertissement"] = levelOK
        checks["algolia_au_moins_1_appel"] = algN >= 1
        checks["tavily_au_moins_3_recherches"] = tavN >= 3
        checks["extract_appele"] = exN >= 1
        checks["urls_citees_toutes_lues_en_texte_complet"] = !cited.isEmpty && unreadC.isEmpty
        checks["aucune_url_citee_hors_ensemble"] = runOK && outside.isEmpty
        let infraOK: Bool = checks.values.allSatisfy { $0 }
        let low: String = answer.lowercased()
        let committees: Bool = answer.contains("CROCSAD") || answer.contains("CLOCSAD") || answer.contains("CAOCSAD")
        var hints: [String: Bool] = [:]
        hints["1_niger_2900_en_2025"] = answer.contains("2,900") && low.contains("2025")
        hints["2_date_21_04_2026_et_afp_22_04"] = answer.contains("21/04/2026") && answer.contains("22/04")
        hints["3_motif_comptes_2024_et_novembre_2025"] = low.contains("2024") && low.contains("november 2025")
        hints["4_mali_decret_2026_0152_13_03_2026_journal_officiel_10pct"] = answer.contains("2026-0152") && answer.contains("13/03/2026") && answer.contains("10%") && low.contains("gazette")
        hints["5_non_objection_et_comites"] = low.contains("non-objection") && committees
        hints["6_enfants_dans_le_texte"] = low.contains("child")
        hints["7_etiquettes_presentes"] = answer.contains("SOLID") || answer.contains("REPORTED")
        hints["10_qa_log_et_scores"] = low.contains("qa log")
        var allErrs: [String] = errs
        if let he = hr.error { allErrs.append(he) }
        let ms: Int = Int(Date().timeIntervalSince(t0) * 1000)
        var doc: [String: Any] = ["started": started, "finished": nowISO(), "etat": "terminé", "brief": brief, "http": hr.status, "ms": ms]
        doc["reussi_infrastructure"] = infraOK
        doc["verifications"] = checks
        doc["indices_calibration"] = hints
        doc["indices_note"] = "repères automatiques (simples recherches de texte) des critères 1-10 du skill — pas une notation : relire la note"
        doc["raisonnement"] = level
        doc["avertissements"] = warns
        doc["appels"] = ["algolia": algN, "tavily_recherches_reussies": tavN, "tavily_recherches_envoyees": (run["tavily_recherches"] as? Int) ?? 0, "tavily_extract": exN]
        doc["delais_client_s"] = ["premier_octet": Int(tmo.firstByte), "silence": Int(tmo.idle), "total": Int(tmo.total)]
        doc["max_tokens"] = run["max_tokens"] ?? 0
        doc["max_tokens_envoye"] = run["max_tokens_envoye"] ?? 0
        doc["algolia_index"] = run["algolia_index"] ?? [String: String]()
        if let e = run["erreur"] as? String, !e.isEmpty { doc["erreur_run"] = e }
        doc["tavily_credits"] = run["tavily_credits"] ?? 0
        doc["cout_llm_usd"] = run["cout_llm_usd"] ?? 0
        doc["citations"] = cited
        doc["citations_hors_ensemble"] = outside
        doc["citees_non_lues"] = unreadC
        doc["sources"] = run["sources"] ?? [Any]()
        doc["etapes"] = steps
        doc["erreurs"] = allErrs
        doc["note"] = String(SecretsGuard.redact(answer).prefix(40000))
        try? jsonData(doc).write(to: URL(fileURLWithPath: out))
        _ = BlackBox.record(["tool": "cafu_test", "actor": "Nova", "ok": infraOK, "effect": "lecture",
                             "why": "test d'acceptation du mode CAFU (brief de calibration, fil hors mémoire, rien d'envoyé)", "result": infraOK ? "infrastructure conforme" : "à vérifier : releves/diag/cafu_test.json"])
    }
}
