import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
#if canImport(FoundationXML)
import FoundationXML
#endif

/// Source de données : toujours (nom, ok, texte). Une source en échec est DITE, jamais remplacée par du texte inventé.
public struct SourceData { public var name: String; public var ok: Bool; public var text: String
    public var asOf: String = ""   // VÉRITÉ-BREFS (23/10) : fraîcheur affichable de la source (date de sa dernière donnée, ou mention de consultation en direct) — generate la met dans l'en-tête « ### » des données.
    public func asDict() -> [String: Any] { ["name": name, "ok": ok, "detail": ok ? "ok" : text] } }

final class RSSParser: NSObject, XMLParserDelegate {
    var items: [(String, String, String)] = []   // titre, lien, date
    // DIAG2-VEILLE : en parallèle, la matière des cartes du feed — description et
    // contenu encodé BRUTS (le nettoyage est fait par le consommateur, via
    // Tools.htmlToText) et l'image que le flux fournit (media:*, enclosure,
    // première <img> des bruts). Aucun consommateur existant de `items` ne change.
    var rich: [(String, String, String, String, String, String)] = []   // titre, lien, date, description, encodé, image
    var cur = "", title = "", link = "", date = "", inItem = false
    var desc = "", encoded = "", img = ""
    static let imgRx = try? NSRegularExpression(pattern: #"<img[^>]+src=["']([^"']+)["']"#, options: [.caseInsensitive])
    static func firstImg(_ a: String, _ b: String) -> String {
        guard let rx = imgRx else { return "" }
        for s in [a, b] where !s.isEmpty {
            if let m = rx.firstMatch(in: s, range: NSRange(location: 0, length: (s as NSString).length)) { return (s as NSString).substring(with: m.range(at: 1)) }
        }
        return ""
    }
    func parser(_ p: XMLParser, didStartElement e: String, namespaceURI: String?, qualifiedName: String?, attributes: [String: String] = [:]) {
        cur = ""; if e == "item" || e == "entry" { inItem = true; title = ""; link = ""; date = ""; desc = ""; encoded = ""; img = "" }
        if inItem, img.isEmpty {
            if e == "media:content" || e == "media:thumbnail", let u = attributes["url"], !u.isEmpty { img = u }
            else if e == "enclosure", let u = attributes["url"], (attributes["type"] ?? "").hasPrefix("image") { img = u }
        }
        if e == "link", inItem, let h = attributes["href"] {
            if attributes["rel"] == "enclosure" { if img.isEmpty, (attributes["type"] ?? "").hasPrefix("image") { img = h } }
            else { link = h }
        }
    }
    func parser(_ p: XMLParser, foundCharacters s: String) { cur += s }
    func parser(_ p: XMLParser, foundCDATA b: Data) { cur += String(decoding: b, as: UTF8.self) }
    func parser(_ p: XMLParser, didEndElement e: String, namespaceURI: String?, qualifiedName: String?) {
        let t = cur.trimmingCharacters(in: .whitespacesAndNewlines)
        if inItem {
            if e == "title" { title = t }
            else if e == "link", !t.isEmpty { link = t }
            else if e == "pubDate" || e == "updated" || e == "published" { date = t }
            else if e == "description" || e == "summary" { if desc.isEmpty || t.count > desc.count { desc = t } }
            else if e == "content:encoded" || e == "content" { if t.count > encoded.count { encoded = t } }
        }
        if e == "item" || e == "entry" {
            inItem = false; items.append((title, link, date))
            rich.append((title, link, date, desc, encoded, img.isEmpty ? RSSParser.firstImg(encoded, desc) : img))
        }
    }
}

public final class Briefs {
    let router: Router, tools: Tools, settings: Settings
    let store = JSONFile("briefs.json")
    let state = JSONFile("briefs_etat.json")
    let log = Journal("briefs_journal.jsonl")
    public var onNew: (([String: Any]) -> Void)? = nil
    /// V2-META : crochet d'illustration Muse Image, fourni par NovaApp (la clé Meta
    /// reste au Trousseau, jamais ici). Reçoit le prompt, retourne le nom du livrable
    /// cafu-img-*.webp déposé (MN2-2), ou nil. Absent → les briefs partent sans
    /// illustration, comme avant.
    public var metaIllustrate: ((String) -> String?)? = nil
    /// DESIGN-IMAGE (22/10/2026) : directive de style permanente de TOUTE image
    /// générée par Nova via Muse Image — la constitution visuelle de Nova
    /// (DESIGN_muse_image_constitution.md) en forme compacte, préfixée au
    /// sujet de chaque prompt. Le plat fade de l'ancien prompt (« illustration
    /// éditoriale plate ») est ABROGÉ : la direction validée par Ahadi est le
    /// volume et le glow du dot orange (12/10/2026).
    public static let designDirective = "STYLE NOVA (directive permanente, constitution visuelle de Nova) — Rendu 3D premium, profondeur réelle, jamais plat. Monde : vide spatial profond #07080F, nébuleuse indigo #0B0E1D vers #141033, particules fines. Matière : verre sombre translucide, bordures fines translucides, reflet spéculaire supérieur, arrière-plan flouté derrière le verre. Lumière unique venue du haut. Un seul accent vivant : orange solaire #FF7A29, dégradé radial #FFC38F vers #FF7A29 vers #C24E12, jamais en grande surface. L'orbe de Nova : sphère 3D à surface vivante, halo de Fresnel, glow orange contenu, anneau fin incliné, étoile blanche à quatre branches #FFF6EC en son cœur. Rouge impérial #D93226 admis en accent secondaire discret. Encre #F2F3F7. Trois plans de profondeur : scène, surfaces de verre, éléments flottants ; ombres douces et profondes. INTERDITS : aucun texte, aucune lettre, aucun logo ; aucun rendu plat, aucune illustration éditoriale, aucun style photo stock ; aucune couleur hors palette."
    var running = Set<String>()
    let lock = NSLock()
    public init(router: Router, tools: Tools, settings: Settings) { self.router = router; self.tools = tools; self.settings = settings }

    public func list() -> [[String: Any]] { store.read(default: [[String: Any]]()).reversed() }
    public func markRead(_ id: String) {
        var l = store.read(default: [[String: Any]]()); for i in l.indices where (l[i]["id"] as? String) == id { l[i]["read"] = true }; store.write(l)
    }

    // MARK: connecteurs
    func weather() -> SourceData {
        let lat = settings.get("lat", 12.3714), lon = settings.get("lon", -1.5197), city = settings.get("city", "")
        let u = "https://api.open-meteo.com/v1/forecast?latitude=\(lat)&longitude=\(lon)&current=temperature_2m,weather_code&daily=temperature_2m_max,temperature_2m_min,precipitation_probability_max&timezone=auto&forecast_days=2"
        let (st, body) = Tools.get(u, timeout: 10)
        guard st == 200, let o = parseJSON(Data(body.utf8)), let cur = o["current"] as? [String: Any], let d = o["daily"] as? [String: Any] else {
            return SourceData(name: "Météo (Open-Meteo)", ok: false, text: "indisponible (HTTP \(st))") }
        func arr(_ k: String) -> [Double] { (d[k] as? [Any])?.compactMap { ($0 as? NSNumber)?.doubleValue } ?? [] }
        let mx = arr("temperature_2m_max"), mn = arr("temperature_2m_min"), pr = arr("precipitation_probability_max")
        let t = "\(city) — maintenant \(cur["temperature_2m"] ?? "?") °C ; aujourd'hui min \(mn.first.map { Int($0) } ?? 0) / max \(mx.first.map { Int($0) } ?? 0) °C, pluie \(pr.first.map { Int($0) } ?? 0) % ; demain max \(mx.dropFirst().first.map { Int($0) } ?? 0) °C (Open-Meteo, \(nowISO().prefix(10)))"
        return SourceData(name: "Météo (Open-Meteo)", ok: true, text: t)
    }
    func news() -> SourceData {
        var lines: [String] = []; var errs: [String] = []
        for f in settings.get("feeds", [String]()) {
            let (st, body) = Tools.get(f, timeout: 10)
            guard st == 200, let d = body.data(using: .utf8) else { errs.append("\(f) (HTTP \(st))"); continue }
            let p = RSSParser(); let x = XMLParser(data: d); x.delegate = p; x.parse()
            let host = URL(string: f)?.host ?? f
            for it in p.items.prefix(5) { lines.append("- \(it.0) [\(host), \(it.2.isEmpty ? "date n/c" : it.2)] \(it.1)") }
        }
        if lines.isEmpty { return SourceData(name: "Actualités (RSS)", ok: false, text: "aucun flux lisible : " + errs.joined(separator: " ; ")) }
        return SourceData(name: "Actualités (RSS)", ok: true, text: lines.joined(separator: "\n"))
    }
    func osaSource(_ name: String, _ tool: String) -> SourceData {
        let out = tools.run(tool, "")
        let bad = out.contains("indisponible") || out.contains("a échoué") || out.contains("délai")
        return SourceData(name: name, ok: !bad, text: out)
    }
    func collect(kind: String) -> [SourceData] {
        var s: [SourceData] = []
        let g = DispatchGroup(); let lock = NSLock()
        func add(_ f: @escaping () -> SourceData) { g.enter(); DispatchQueue.global().async { let r = f(); lock.lock(); s.append(r); lock.unlock(); g.leave() } }
        add { self.weather() }
        add { self.osaSource("Agenda (Calendar.app)", "calendar") }
        add { self.osaSource("Mails non lus (Mail.app)", "mail_unread") }
        add { self.osaSource("Rappels (Reminders.app)", "reminders") }
        if kind != "soir" { add { self.news() } }
        g.wait()
        // VÉRITÉ-BREFS (23/10) : la mémoire est DATÉE ligne à ligne (le « ts » du
        // magasin, même présentation que Memory.promptBlock) et la source porte la
        // date de sa dernière entrée (asOf, affichée par generate dans l'en-tête
        // des données). Avant : collect jetait la date — un fait mémorisé le 21/10
        // valait fait courant (cas DAR : « aucune donnée : non vérifié » conclu
        // depuis une mémoire du 21/10 contre un dépôt du 22/10, brief de midi).
        let mem = tools.memory.list().suffix(10)
        if !mem.isEmpty {
            let dated = mem.map { m -> String in
                let t = (m["text"] as? String) ?? ""
                let d = (m["ts"] as? String) ?? ""
                return "- " + t + (d.isEmpty ? "" : " (" + String(d.prefix(10)) + ")")
            }.joined(separator: "\n")
            let newest = (mem.last?["ts"] as? String) ?? ""
            s.append(SourceData(name: "Mémoire Nova", ok: true, text: dated, asOf: newest.isEmpty ? "" : "dernière entrée : " + String(newest.prefix(10)) + " " + String(newest.dropFirst(11).prefix(5))))
        }
        s.append(freshFacts())
        if kind == "soir" { s.append(dotsToday()); s.append(Rituels.laisserSource()) }   // V5-O (#26) : « Ce qu'on laisse » entre dans la Fermeture du soir   // NETTOYAGE-BRIEFS F1 : la Fermeture absorbe les entrées du Bilan du jour (les runs des Dots)
        let order = ["Météo (Open-Meteo)", "Agenda (Calendar.app)", "Mails non lus (Mail.app)", "Faits récents — engagements et courrier lu (72 h)", "Rappels (Reminders.app)", "Actualités (RSS)", "Activité des Dots (aujourd'hui)", "Mémoire Nova"]
        // VÉRITÉ-BREFS : toute source sans date propre est consultée EN DIRECT à
        // l'instant de la collecte — l'en-tête des données le dira (asOf).
        let hhmm = String(nowISO().dropFirst(11).prefix(5))
        s = s.map { var x = $0; if x.asOf.isEmpty { x.asOf = "consultée à l'instant (\(hhmm))" }; return x }
        return s.sorted { (order.firstIndex(of: $0.name) ?? 9) < (order.firstIndex(of: $1.name) ?? 9) }
    }

    /// VÉRITÉ-BREFS (23/10) : les faits frais du magasin, joints à CHAQUE brief —
    /// engagements OUVERTS (commitments.json, chacun daté par « created » et son
    /// échéance) et corps de courrier LUS dans les dernières 72 h
    /// (webmail_bodies.json, chacun daté par « ts »). Avant ce lot, collect ne
    /// voyait ni les engagements ni les corps lus : un dossier en mouvement dont
    /// le dernier état mémorisé datait de plusieurs jours était conclu « aucune
    /// donnée / non vérifié » depuis la seule mémoire (cas DAR, brief de midi du
    /// 23/10). Patron dotsToday : lecture directe des magasins, aucune écriture.
    func freshFacts() -> SourceData {
        var lines: [String] = []
        let co: [String: Any] = JSONFile("commitments.json").read(default: [String: Any]())
        let items = (co["items"] as? [[String: Any]]) ?? []
        let open = items.filter { (($0["status"] as? String) ?? "ouvert") == "ouvert" }
        // Dossiers en mouvement d'abord : ceux qui portent une échéance (par date
        // croissante), puis les autres par création décroissante.
        let withEch = open.filter { !(($0["echeance"] as? String) ?? "").isEmpty }.sorted { (($0["echeance"] as? String) ?? "") < (($1["echeance"] as? String) ?? "") }
        let noEch = open.filter { (($0["echeance"] as? String) ?? "").isEmpty }.sorted { (($0["created"] as? String) ?? "") > (($1["created"] as? String) ?? "") }
        for c in (withEch + noEch).prefix(20) {
            let created = String(((c["created"] as? String) ?? "").prefix(10))
            let ech = (c["echeance"] as? String) ?? ""
            let dir = ((c["dir"] as? String) ?? "moi") == "eux" ? "on me doit" : "je dois"
            let quoi = String(((c["quoi"] as? String) ?? "").prefix(110))
            lines.append("• Engagement ouvert (créé le \(created.isEmpty ? "date n/c" : created)) — \(dir) : \(quoi) (\((c["qui"] as? String) ?? ""))\(ech.isEmpty ? "" : " · échéance : \(ech)")")
        }
        if open.count > 20 { lines.append("• … et \(open.count - 20) autre(s) engagement(s) ouvert(s) non listés.") }
        let bodies: [String: Any] = JSONFile("webmail_bodies.json").read(default: [String: Any]())
        let cutoff = Date().addingTimeInterval(-72 * 3600)
        let iso = ISO8601DateFormatter()
        var recent: [(String, String, String, String)] = []
        for (k, v) in bodies {
            guard let d = v as? [String: Any], let ts = d["ts"] as? String, let dt = iso.date(from: ts), dt > cutoff else { continue }
            let parts = k.split(separator: "│", omittingEmptySubsequences: false).map(String.init)
            let flat = ((d["body"] as? String) ?? "").replacingOccurrences(of: "\n", with: " ")
            recent.append((ts, parts.first ?? "", parts.count > 1 ? parts[1] : "", String(flat.prefix(160))))
        }
        for r in recent.sorted(by: { $0.0 > $1.0 }).prefix(8) {
            lines.append("• Courrier lu le \(String(r.0.prefix(10))) à \(String(r.0.dropFirst(11).prefix(5))) — \(r.1) — « \(r.2) » : \(r.3)")
        }
        if lines.isEmpty { return SourceData(name: "Faits récents — engagements et courrier lu (72 h)", ok: true, text: "Aucun engagement ouvert ni corps de courrier lu dans les dernières 72 h au magasin.") }
        return SourceData(name: "Faits récents — engagements et courrier lu (72 h)", ok: true, text: lines.joined(separator: "\n"))
    }

    /// NETTOYAGE-BRIEFS F1 (23/10) : les entrées du Bilan du jour, absorbées par la
    /// Fermeture du soir — les passages de Dots du jour ayant réussi (même matière
    /// que DotScheduler.bilanTask, qui nourrissait le Dot bilan, désormais en pause).
    /// Lecture directe des magasins (patron Dots.buildSummary) ; runs en cours et
    /// runs en échec exclus, le Dot bilan lui-même exclu.
    func dotsToday() -> SourceData {
        let day = String(ISO8601DateFormatter().string(from: Date()).prefix(10))
        let runs: [[String: Any]] = JSONFile("dots_runs.json").read(default: [[String: Any]]())
        var names: [String: String] = [:]
        for d in JSONFile("dots.json").read(default: [[String: Any]]()) { if let id = d["id"] as? String { names[id] = (d["name"] as? String) ?? id } }
        let mine = runs.filter { (($0["ts"] as? String) ?? "").hasPrefix(day) && (($0["dot"] as? String) ?? "") != "bilan" && ($0["ok"] as? Bool) == true && ($0["statut"] as? String) != "en_cours" }
        if mine.isEmpty { return SourceData(name: "Activité des Dots (aujourd'hui)", ok: true, text: "Aucun passage de Dot réussi enregistré aujourd'hui.") }
        let lines = mine.suffix(10).map { r -> String in
            let id = (r["dot"] as? String) ?? "?"
            let hhmm = String(((r["ts"] as? String) ?? "").dropFirst(11).prefix(5))
            let rawStatus = (r["status"] as? String) ?? ""
            let st = rawStatus.isEmpty ? "OK" : rawStatus
            let firstLine = ((r["result"] as? String) ?? "").split(separator: "\n").map(String.init).first { !$0.hasPrefix("STATUT") && !$0.trimmingCharacters(in: .whitespaces).isEmpty } ?? ""
            return "• \(names[id] ?? id) (\(hhmm), \(st)) : \(String(firstLine.prefix(220)))"
        }
        return SourceData(name: "Activité des Dots (aujourd'hui)", ok: true, text: lines.joined(separator: "\n"))
    }

    /// Produit un brief. NETTOYAGE-BRIEFS S1 (23/10) : toujours LE résultat, ou rien
    /// encore — si aucun cerveau ne répond, RIEN n'est publié (ni item stocké, ni
    /// carte Feed, ni écho ProactiveFeed) : l'échec est journalisé (ok: false, motif
    /// réel) et confié à la Reprise, qui relancera ce brief au retour du cerveau et
    /// publiera alors le vrai brief. (Avant : un item « données brutes » était publié
    /// à la place, puis la reprise publiait le vrai brief juste après — deux
    /// « Fermeture du soir » à 18:00 et 18:01 le 22/10.)
    @discardableResult
    public func generate(kind: String, label: String, manual: Bool, catchUp: Bool = false) -> [String: Any] {
        lock.lock(); if running.contains(kind) { lock.unlock(); return ["error": "déjà en cours"] }; running.insert(kind); lock.unlock()
        defer { lock.lock(); running.remove(kind); lock.unlock() }
        let t0 = Date()
        let src = collect(kind: kind)
        let df = DateFormatter(); df.locale = Locale(identifier: "fr_FR"); df.dateFormat = "EEEE d MMMM yyyy, HH:mm"
        var data = src.map { "### \($0.name)\($0.asOf.isEmpty ? "" : " — \($0.asOf)")\($0.ok ? "" : " — INDISPONIBLE")\n\($0.text)" }.joined(separator: "\n\n")
        // 29/10 (chantier 5) : tendance du banc qualité nocturne, une ligne dans le brief du matin.
        if kind == "matin" { let q: String = QualiteNuit.briefLine(); if !q.isEmpty { data += "\n\n### Santé de Nova (banc de la nuit)\n" + q } }
        // NETTOYAGE-BRIEFS F1+F2 (23/10) : la Fermeture du soir absorbe les 3 blocs du
        // Bilan du jour (fait / reste / demain) et le Brief du matin absorbe le Cap du
        // jour (3 priorités prouvées + première action de 10 minutes) — les deux Dots
        // sont mis en pause par la migration briefs_cleanup_v1 (Dots.swift).
        let focus = kind == "soir" ? "Fais la fermeture de la journée en quatre blocs : 1) FAIT AUJOURD'HUI — ce que les Dots ont livré (source « Activité des Dots ») et ce qui a été traité ; 2) RESTE OUVERT — rappels non faits, mails en attente, inachevés ; 3) DEMAIN — l'agenda de demain et ce qu'il faut préparer (3 points maximum) ; 4) CE QU'ON LAISSE — d'après la source « Ce qu'on laisse », ce qu'Ahadi a lui-même choisi de ne pas reprendre ce soir, avec l'autorisation explicite de le lâcher ; si cette source est vide, propose UNE seule chose du bloc RESTE OUVERT qui peut attendre demain sans risque, présentée comme une proposition. Termine par un conseil de repos si la journée a été chargée."
            : (kind == "midi" ? "Fais un point de mi-journée : ce qui change pour l'après-midi, mails/rappels à traiter."
               : "Fais le brief du matin : l'essentiel de la journée (agenda, mails à traiter, rappels), la météo en une ligne, 3 titres d'actualité utiles. Termine par une section « CAP DU JOUR » : les 3 priorités du jour, chacune PROUVÉE par une donnée ci-dessus (un mail, un rendez-vous ou un rappel, cité), et pour chacune une première action concrète faisable en 10 minutes.")
        // 26/10 (Ahadi : « même type que Muse ») : salutation à l'heure + prénom, BLUF, tri HAUTE/MOYENNE/BASSE commenté,
        // action probable, une initiative non demandée, clôture DOTS 🟢🟡🔴.
        let hourNow: Int = Calendar.current.component(.hour, from: Date())
        // 26/10 (style général Muse) : 05:00–11:59 Bonjour · 12:00–17:59 Bon après-midi · 18:00–04:59 Bonsoir — virgule et prénom.
        let salut: String
        if hourNow >= 5 && hourNow < 12 { salut = "Bonjour, Ahadi" } else if hourNow >= 12 && hourNow < 18 { salut = "Bon après-midi, Ahadi" } else { salut = "Bonsoir, Ahadi" }
        let museFormat: String = "STYLE MUSE (calqué sur ses vrais messages à Ahadi) : 1re ligne « \(salut) 👋 » suivie, sur la même ligne, d'une accroche qui annonce combien de choses comptent et pourquoi maintenant (ex. « Trois portes à fermer ce matin, avant que les fenêtres ne passent : »). Puis 2 à 4 points numérotés, chacun avec un titre en gras qui nomme le sujet ET la décision attendue (ex. « **1. Mémoire — envoi ce matin ?** »), suivi de 1 à 3 phrases concrètes : le contexte précis (dates, chiffres, état, depuis quand c'est en attente), ce qui manque, puis le geste attendu de lui posé comme une question directe ou une consigne (« C'est toi qui envoies. »). Si tu repères une anomalie (mouvement d'argent inhabituel, invitation restée sans réponse, chiffre incohérent, échéance qui glisse), un point « ⚠️ » dédié qui dit ce que ça ressemble à être et demande s'il reconnaît. Si une source plus fraîche contredit un fait déjà annoncé, corrige-le franchement (« je corrige : … »). Termine par une ligne « Horloge du jour : » avec les rendez-vous et échéances du jour séparés par « · » (heure inconnue = « heure inconnue »). Ajoute, seulement si une donnée la fonde, « 💡 Idée du jour : » une initiative non demandée. Tutoiement, gras sur les faits clés, emojis à sens stable seulement (👋 ✅ ⚠️ 📅 💰 🤝), jamais de jargon d'outil, jamais « aucune donnée » si une source fraîche existe. Si vraiment rien ne compte, une seule phrase qui le dit."
        let sys = Persona.system(title: "Ahadi", memory: "", voice: false, tools: false,
                                 extra: "TÂCHE : \(focus) \(museFormat) N'utilise QUE les données fournies ci-dessous ; pour une source marquée INDISPONIBLE, écris une seule ligne disant laquelle et pourquoi. Aucun chiffre ni fait hors données. Cite la source entre parenthèses. FRAÎCHEUR : chaque source ci-dessous porte sa date — pour un fait daté ou un dossier en cours, la source la plus récente fait foi. Il est INTERDIT de conclure « aucune donnée », « non vérifié » ou « pas d'information » depuis une source plus vieille que le fait ou l'échéance qu'elle contredit : rapporte alors le fait le plus récent trouvé, avec sa date et sa source. Si un point reste sans donnée après consultation des sources fraîches (Faits récents, Mails, Agenda, Mémoire datée), dis-le en nommant la source la plus fraîche consultée et sa date.")
        // 29/10 (chantier 2) : un brief est un LIVRABLE pour Ahadi — rédigé par le cerveau principal ([tiers]), pas rabattu sur le cerveau
        // économique des tâches de fond. 3 briefs/jour ≈ 0,15 $.
        let briefWasInteractive: Bool = LLMSpend.isInteractive()
        LLMSpend.setInteractive(true)
        defer { if !briefWasInteractive { LLMSpend.setInteractive(false) } }
        let det = router.completeDetailed(messages: [ChatMsg("user", "Nous sommes le \(df.string(from: Date())).\n\nDONNÉES RÉELLES COLLECTÉES :\n\n\(data)")], system: sys, mode: "bulk", preferred: settings.get("brain", "spark-1.3"), maxTokens: 4000, deadline: 180, solo: false)   /* 29/10 (Ahadi : « les briefs n'arrivent pas ») : Spark d'abord, puis la chaîne — un brief n'est plus perdu quand Spark ne répond pas ; le cerveau réel est nommé dans l'item */   // APPLY-BRIEFS H1+H2+H3 : cerveau verrouillé épinglé (avant : preferred absent), plafond 900 → 4 000 (la réflexion consommait tout avant le premier mot visible), date-butoir de fond 120 s (avant : les 25 s pensées pour le chat) · REVUE-GATE 22/10 : solo: true adopté — l'épinglage devient réel (chaîne réduite au cerveau du réglage, filet local coupé), comme radarPass/brainText (FIX-RADAR) ; avant, un échec du préféré faisait parcourir la chaîne et pouvait faire rédiger le brief par un autre cerveau sans le nommer
        let res = det.result
        var text: String; var brain: String
        if let r = res { text = r.text; brain = router.spec(r.brain)?.label ?? r.brain }
        else {
            // NETTOYAGE-BRIEFS S1 (23/10) : échec de synthèse → AUCUNE publication
            // (ni store, ni onNew — donc ni carte Feed ni écho ProactiveFeed). Le
            // journal garde la trace complète (ok: false + motif réel, APPLY-BRIEFS
            // H4) et les notes de Reprise (cerveau, et agenda si la source Agenda est
            // refusée) sont posées comme avant : la Reprise relancera ce brief au
            // retour de la dépendance et publiera alors le vrai brief, seul. Le
            // garde-fou « recovered » d'App lit le magasin en exigeant un cerveau
            // réel (jamais « aucun ») : ne plus stocker l'échec ne le trompe pas.
            brain = "aucun (synthèse non produite)"
            log.add(["kind": kind, "ok": false, "err": det.error ?? "", "brain": brain, "illustration": "", "ms": Int(Date().timeIntervalSince(t0) * 1000), "manual": manual, "rattrapage": catchUp, "sources_ok": src.filter { $0.ok }.count, "sources": src.count, "publication": "aucune — échec non publié (S1), reprise confiée à Reprise"])
            Reprise.note(producer: "brief", key: kind, dep: "brain:" + settings.get("brain", "spark-1.3"), label: label)
            if src.contains(where: { $0.name == "Agenda (Calendar.app)" && ($0.text.contains("pas accordé") || $0.text.contains("illisible")) }) { Reprise.note(producer: "brief", key: kind, dep: "calendar", label: label) }
            return ["error": "synthèse non produite : \(det.error ?? "aucun cerveau n'a répondu") — rien n'a été publié ; la reprise relancera ce brief au retour du cerveau"]
        }
        var item: [String: Any] = ["id": UUID().uuidString.prefix(8).lowercased().description, "kind": kind, "title": label, "ts": nowISO(), "text": text, "brain": brain,
                                   "sources": src.map { $0.asDict() }, "read": false, "manual": manual, "rattrapage": catchUp, "ms": Int(Date().timeIntervalSince(t0) * 1000)]
        // V2-META : un brief réellement synthétisé reçoit son illustration Muse Image
        // (deuxième produit Meta du flux ; forme d'appel prouvée côté connecteur le
        // 22/10/2026) — déposée en livrable cafu-img-*.webp (MN2-2) et référencée
        // dans l'item. Crochet absent, réglage coupé ou échec : le brief part sans
        // illustration et le journal le dit (champ « illustration » vide) — jamais
        // bloquant, jamais d'image inventée.
        if res != nil, settings.get("brief_illustration", true), let ill = metaIllustrate {
            let amb = kind == "soir" ? "au coucher du soleil" : (kind == "midi" ? "en pleine lumière de mi-journée" : "au lever du soleil")
            let prompt = Briefs.designDirective + " Sujet : skyline de Ouagadougou (Burkina Faso) \(amb), vue à travers le verre de l'observatoire — silhouettes sombres au loin, l'orbe orange de Nova au premier plan."
            if let name = ill(prompt) { item["illustration"] = name }
        }
        var l = store.read(default: [[String: Any]]()); l.append(item); store.write(Array(l.suffix(200)))
        // 27/10 (Ahadi : « pas de brief ce matin ») : le brief partait dans Feeds + notification macOS,
        // jamais dans Conversations où Ahadi regarde. Il y arrive désormais comme chaque Direct,
        // avec son ouverture (le texte complet reste dans le module Temps/Accueil).
        let apercu: String = String(text.prefix(700))
        ProactiveFeed.append(kind: "brief", box: "briefs", title: label,
                             text: apercu + "\n— Brief complet dans Accueil et Feeds.",
                             extra: ["brief_id": item["id"] ?? "", "brief_kind": kind])
        log.add(["kind": kind, "ok": res != nil, "err": det.error ?? "", "brain": brain, "illustration": (item["illustration"] as? String) ?? "", "ms": item["ms"] ?? 0, "manual": manual, "rattrapage": catchUp, "sources_ok": src.filter { $0.ok }.count, "sources": src.count])   // APPLY-BRIEFS H4 : le motif réel de l'échec est journalisé, plus jamais jeté
        // AUTONOMIE A3 (22/10) : dépendance absente → reprise UNIQUE au retour de la
        // dépendance (Reprise.swift). La note « cerveau » est posée dans la branche
        // d'échec ci-dessus (S1 : plus aucun retour ici quand res == nil) ; ne
        // subsiste à ce point que la note « agenda refusé », qui vaut aussi quand
        // la synthèse a réussi sans l'agenda — le brief du jour sera régénéré avec
        // l'agenda dès l'accès revenu.
        if src.contains(where: { $0.name == "Agenda (Calendar.app)" && ($0.text.contains("pas accordé") || $0.text.contains("illisible")) }) { Reprise.note(producer: "brief", key: kind, dep: "calendar", label: label) }
        onNew?(item)
        return item
    }

    // MARK: planificateur
    static func minutes(_ hhmm: String) -> Int? {
        let p = hhmm.split(separator: ":").compactMap { Int($0) }; return p.count == 2 ? p[0] * 60 + p[1] : nil
    }
    public func inQuietHours(_ now: Date = Date()) -> Bool {
        // Mode concentration : silence jusqu'à l'heure choisie (réglage « focus_until », epoch en secondes)
        if (settings.get("focus_until", 0.0) as Double) > now.timeIntervalSince1970 { return true }
        guard let a = Briefs.minutes(settings.get("quiet_from", "22:00")), let b = Briefs.minutes(settings.get("quiet_to", "07:00")) else { return false }
        let c = Calendar.current.dateComponents([.hour, .minute], from: now); let m = (c.hour ?? 0) * 60 + (c.minute ?? 0)
        return a > b ? (m >= a || m < b) : (m >= a && m < b)
    }
    /// À appeler toutes les ~20 s. Rattrape un brief manqué (Mac éteint/en veille) jusqu'à 10 h après l'heure prévue.
    public func tick(now: Date = Date()) {
        let cal = Calendar.current; let c = cal.dateComponents([.hour, .minute], from: now)
        let m = (c.hour ?? 0) * 60 + (c.minute ?? 0)
        let day = String(ISO8601DateFormatter().string(from: now).prefix(10))
        var st = state.read(default: [String: String]())
        for b in settings.get("briefs", [[String: Any]]()) {
            guard (b["enabled"] as? Bool) == true, let id = b["id"] as? String, Rituels.allows(id, settings: settings), let t = Briefs.minutes(b["time"] as? String ?? ""), st[id] != day, st[id] != "en_cours:" + day else { continue }   // V5-O : rituels_on + ritual_<id> (Feat_Daily.swift)
            if m >= t && m - t <= 600 {
                // 29/10 (audit n°10) : « en cours » d'abord, « fait » seulement après la génération — un arrêt de Nova pendant
                // les ≤ 180 s de rédaction ne fait plus perdre le brief du jour (repris au redémarrage).
                st[id] = "en_cours:" + day; state.write(st)
                let late = m - t > 3
                let th = Thread {
                    _ = self.generate(kind: b["kind"] as? String ?? id, label: b["label"] as? String ?? id, manual: false, catchUp: late)
                    var s2 = self.state.read(default: [String: String]()); s2[id] = day; self.state.write(s2)
                }; th.stackSize = 16 << 20; th.start()
            }
        }
    }
    public func startScheduler() {
        var s0 = state.read(default: [String: String]())
        var changed: Bool = false
        for (k, v) in s0 where v.hasPrefix("en_cours:") { s0[k] = nil; changed = true }   // 29/10 : brief interrompu par un arrêt → refait
        if changed { state.write(s0) }
        Thread.detachNewThread { while true { Thread.sleep(forTimeInterval: 20); self.tick() } }
    }
}
