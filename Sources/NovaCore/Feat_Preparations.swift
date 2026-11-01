import Foundation
#if canImport(EventKit) && os(macOS)
import EventKit
#endif

// 27/10 (Ahadi) — ANTICIPATION : Nova réfléchit AVANT la demande, prépare en arrière-plan et
// soumet à l'appréciation. Trois réflexes, données locales uniquement, aucun cerveau, aucun cloud :
//   1) réunion proche (≤ 36 h) → fiche préparée (participants, engagements et faits liés) ;
//   2) signal de feed (mail, Teams, veille) qui demande une action → tâche préparée
//      (constat, échéance suggérée extraite du texte, premiers pas concrets) ;
//   3) rapprochement : un signal neuf éclaire une recherche ou un fait ancien → proposition reliée.
// Chaque préparation est stockée (preparations.json), publiée au Direct, et n'avance que sur
// décision d'Ahadi : « approuvée » crée l'engagement interne correspondant — jamais d'envoi,
// jamais d'action externe. « rejetée » est définitif pour cette clé (anti-retour durable).

public enum Preparations {
    static let file: JSONFile = JSONFile("preparations.json")
    static let lock: NSLock = NSLock()

    public static let statuts: [String] = ["en_attente", "approuvee", "rejetee", "faite"]

    // MARK: magasin

    public static func all() -> [[String: Any]] {
        lock.lock(); defer { lock.unlock() }
        return file.read(default: [[String: Any]]())
    }

    /// Clés déjà préparées (tout statut) : une même clé ne revient jamais, même rejetée.
    public static func clesConnues() -> Set<String> {
        return Set(all().compactMap { ($0["cle"] as? String) })
    }

    @discardableResult public static func add(_ prep: [String: Any]) -> [String: Any]? {
        lock.lock(); defer { lock.unlock() }
        var l: [[String: Any]] = file.read(default: [[String: Any]]())
        let cle: String = (prep["cle"] as? String) ?? ""
        if cle.isEmpty || l.contains(where: { ($0["cle"] as? String) == cle }) { return nil }
        var p: [String: Any] = prep
        p["id"] = String(UUID().uuidString.prefix(8)).lowercased()
        p["statut"] = "en_attente"
        p["cree"] = nowISO()
        l.append(p)
        file.write(Array(l.suffix(120)))
        return p
    }

    @discardableResult public static func setStatut(id: String, statut: String) -> [String: Any]? {
        guard statuts.contains(statut) else { return nil }
        lock.lock(); defer { lock.unlock() }
        var l: [[String: Any]] = file.read(default: [[String: Any]]())
        guard let i: Int = l.firstIndex(where: { ($0["id"] as? String) == id }) else { return nil }
        l[i]["statut"] = statut
        l[i]["decide"] = nowISO()
        file.write(l)
        return l[i]
    }

    /// Décision d'Ahadi (Mac ou téléphone) : « approuvee » crée l'engagement interne
    /// lié (jamais d'envoi) ; « rejetee » est durable. Renvoie l'id de l'engagement créé.
    @discardableResult public static func decider(id: String, statut: String) -> (prep: [String: Any]?, engagementCree: String) {
        guard let p: [String: Any] = setStatut(id: id, statut: statut) else { return (nil, "") }
        var cree: String = ""
        if statut == "approuvee", let eng: [String: Any] = p["engagement"] as? [String: Any],
           let quoi: String = eng["quoi"] as? String, !quoi.isEmpty {
            DailyState.shared.lock.lock()
            var co: [String: Any] = JSONFile("commitments.json").read(default: [String: Any]())
            var items: [[String: Any]] = (co["items"] as? [[String: Any]]) ?? []
            let cid: String = String(UUID().uuidString.prefix(8)).lowercased()
            items.append(["id": cid, "qui": ((eng["qui"] as? String) ?? ""), "quoi": quoi,
                          "echeance": ((eng["echeance"] as? String) ?? ""), "dir": "moi",
                          "source": "Nova — préparation anticipée", "status": "ouvert",
                          "created": nowISO(), "seen": nowISO(), "alerted": false,
                          "origine": "preparation_anticipation", "preparation_id": id])
            co["items"] = items
            JSONFile("commitments.json").write(co)
            DailyState.shared.lock.unlock()
            cree = cid
        }
        return (p, cree)
    }

    static func nowISO() -> String { ISO8601DateFormatter().string(from: Date()) }

    // MARK: analyse de texte (pure, testable)

    static let stopwords: Set<String> = ["avec", "pour", "dans", "votre", "vos", "vous", "nous", "leur", "leurs", "cette", "cet", "ces",
        "plus", "faire", "fait", "être", "etre", "avoir", "sont", "aussi", "alors", "ainsi", "merci", "bien", "tout", "tous", "toute",
        "depuis", "avant", "apres", "après", "entre", "chez", "sous", "vers", "sans", "mais", "alors", "lors", "dont", "celui", "celle",
        "the", "and", "for", "with", "your", "this", "that", "from", "please", "thanks", "will", "have", "has", "are", "was", "were"]

    public static func motsCles(_ text: String) -> Set<String> {
        let folded: String = text.lowercased().folding(options: .diacriticInsensitive, locale: Locale(identifier: "fr_FR"))
        var out: Set<String> = []
        var cur: String = ""
        for ch in folded {
            if ch.isLetter || ch.isNumber { cur.append(ch) } else {
                if cur.count >= 5 && !stopwords.contains(cur) { out.insert(cur) }
                cur = ""
            }
        }
        if cur.count >= 5 && !stopwords.contains(cur) { out.insert(cur) }
        return out
    }

    static let signauxAction: [String] = ["merci de", "pour action", "action requise", "reponse attendue", "réponse attendue",
        "en attente de votre", "en attente de retour", "avant le", "echeance", "échéance", "deadline", "urgent",
        "a valider", "à valider", "pour validation", "merci de bien vouloir", "action required", "please review",
        "pour decision", "pour décision", "a traiter", "à traiter", "relance"]

    public static func contientSignalAction(_ text: String) -> Bool {
        let t: String = text.lowercased()
        return signauxAction.contains(where: { t.contains($0) })
    }

    static let moisFR: [String: Int] = ["janvier": 1, "fevrier": 2, "février": 2, "mars": 3, "avril": 4, "mai": 5, "juin": 6,
        "juillet": 7, "aout": 8, "août": 8, "septembre": 9, "octobre": 10, "novembre": 11, "decembre": 12, "décembre": 12]

    /// Échéance suggérée extraite du texte (« avant le 03/11 », « avant le 3 novembre ») → yyyy-MM-dd.
    public static func extraireEcheance(_ text: String, now: Date) -> String? {
        let t: String = text.lowercased()
        let cal: Calendar = Calendar.current
        let y: Int = cal.component(.year, from: now)
        func fmt(_ d: Int, _ m: Int, _ yy: Int) -> String? {
            guard (1...31).contains(d), (1...12).contains(m) else { return nil }
            return String(format: "%04d-%02d-%02d", yy, m, d)
        }
        // « 3 novembre » (avec ou sans année)
        for (nom, num) in moisFR {
            if let r: Range<String.Index> = t.range(of: nom) {
                let avant: String = String(t[t.startIndex..<r.lowerBound])
                let nombres: [Int] = avant.split(whereSeparator: { !$0.isNumber }).compactMap { Int($0) }
                if let d: Int = nombres.last { return fmt(d, num, y) }
            }
        }
        // « 03/11 » ou « 03/11/2026 »
        let chars: [Character] = Array(t)
        var i: Int = 0
        func digits(_ s: Int, _ maxLen: Int) -> (Int, Int)? {
            var v: String = ""; var j: Int = s
            while j < chars.count && chars[j].isNumber && v.count < maxLen { v.append(chars[j]); j += 1 }
            return v.isEmpty ? nil : (Int(v) ?? 0, j)
        }
        while i < chars.count {
            if chars[i].isNumber, let (d, j1) = digits(i, 2), j1 < chars.count, chars[j1] == "/" || chars[j1] == "-" {
                if let (m, j2) = digits(j1 + 1, 2) {
                    var yy: Int = y
                    if j2 < chars.count, chars[j2] == "/" || chars[j2] == "-" {
                        if let (an, _) = digits(j2 + 1, 4) { yy = an < 100 ? 2000 + an : an }
                    }
                    if let s: String = fmt(d, m, yy) { return s }
                }
            }
            i += 1
        }
        return nil
    }

    static func texteUnite(_ u: [String: Any]) -> String {
        let parts: [String] = [((u["title"] as? String) ?? ""), ((u["standfirst"] as? String) ?? ""), ((u["text"] as? String) ?? "")]
        return parts.filter { !$0.isEmpty }.joined(separator: "\n")
    }

    // MARK: sélections (pures, testables)

    /// Signal de feed récent (< 72 h) qui demande une action → tâche préparée.
    public static func pickFeedAction(units: [[String: Any]], now: Date, cles: Set<String>) -> [String: Any]? {
        var best: [String: Any]? = nil
        var bestTs: String = ""
        for u in units {
            guard let id: String = u["id"] as? String, !id.isEmpty,
                  let ts: String = u["ts"] as? String,
                  let d: Date = Proactivite.parseDate(ts) else { continue }
            let age: TimeInterval = now.timeIntervalSince(d)
            if age < 0 || age > 72 * 3600 { continue }
            let cle: String = "feed|" + id
            if cles.contains(cle) { continue }
            let txt: String = texteUnite(u)
            if !contientSignalAction(txt) { continue }
            if ts <= bestTs { continue }
            let title: String = ((u["title"] as? String) ?? "Signal sans titre")
            let ech: String = extraireEcheance(txt, now: now) ?? ""
            let quoi: String = "Traiter : " + String(title.prefix(140))
            let prepare: String = "Constat : ce signal demande une action de ta part.\n"
                + "Extrait : « " + String(txt.prefix(320)) + " »\n"
                + (ech.isEmpty ? "Échéance : aucune date lue dans le texte — à fixer.\n" : "Échéance suggérée (lue dans le texte) : " + ech + ".\n")
                + "Préparé pour toi :\n1) l'engagement correspondant, prêt à créer ;\n2) le premier pas concret : ouvrir la source et répondre ou transmettre ;\n3) rien n'est envoyé — tu valides d'abord."
            best = ["cle": cle, "genre": "tache", "titre": "Tâche préparée — " + String(title.prefix(80)),
                    "pourquoi": "Signal reçu il y a " + String(max(1, Int(age / 3600))) + " h qui demande une action.",
                    "prepare": prepare, "source": ["type": "feed", "id": id, "titre": title],
                    "engagement": ["quoi": quoi, "qui": ((u["source_label"] as? String) ?? (u["box"] as? String) ?? ""), "echeance": ech]]
            bestTs = ts
        }
        return best
    }

    /// Rapprochement : signal neuf (< 48 h) × fait ou recherche ancien (> 30 jours), ≥ 2 mots-clés partagés.
    public static func pickRapprochement(units: [[String: Any]], facts: [[String: Any]], now: Date, cles: Set<String>) -> [String: Any]? {
        var best: [String: Any]? = nil
        var bestScore: Int = 1
        for u in units {
            guard let id: String = u["id"] as? String, !id.isEmpty,
                  let ts: String = u["ts"] as? String, let d: Date = Proactivite.parseDate(ts) else { continue }
            let age: TimeInterval = now.timeIntervalSince(d)
            if age < 0 || age > 48 * 3600 { continue }
            let ku: Set<String> = motsCles(texteUnite(u))
            if ku.count < 2 { continue }
            for f in facts {
                guard let fid: String = f["id"] as? String, !fid.isEmpty,
                      let ftext: String = f["text"] as? String, ftext.count >= 20,
                      let fts: String = f["ts"] as? String, let fd: Date = Proactivite.parseDate(fts) else { continue }
                if now.timeIntervalSince(fd) < 30 * 86400 { continue }
                if Memory.isSensitive(ftext) { continue }
                let cle: String = "rapproche|" + id + "|" + fid
                if cles.contains(cle) { continue }
                let shared: Set<String> = ku.intersection(motsCles(ftext))
                if shared.count <= bestScore { continue }
                bestScore = shared.count
                let jours: Int = Int(now.timeIntervalSince(fd) / 86400)
                best = ["cle": cle, "genre": "rapprochement",
                        "titre": "Rapprochement préparé — " + String(((u["title"] as? String) ?? "signal").prefix(70)),
                        "pourquoi": "Ce signal neuf rejoint un point noté il y a " + String(jours) + " jours (mots partagés : " + shared.sorted().prefix(4).joined(separator: ", ") + ").",
                        "prepare": "Signal neuf : « " + String(texteUnite(u).prefix(280)) + " »\nPoint ancien : « " + String(ftext.prefix(280)) + " »\nProposition : je rouvre le point ancien à la lumière du signal et je te dis ce qui a changé — dis-moi si tu veux cette synthèse.",
                        "source": ["type": "feed", "id": id, "titre": ((u["title"] as? String) ?? "")],
                        "lie": ["type": "memoire", "id": fid]]
            }
        }
        return best
    }

    /// Réunion ≤ 36 h → fiche préparée (participants, engagements liés, faits liés).
    public static func pickReunion(events: [[String: Any]], commitments: [[String: Any]], facts: [[String: Any]], now: Date, cles: Set<String>) -> [String: Any]? {
        var best: [String: Any]? = nil
        var bestStart: Date = .distantFuture
        for e in events {
            guard let titre: String = e["titre"] as? String, !titre.isEmpty,
                  let debutS: String = e["debut"] as? String, let debut: Date = Proactivite.parseDate(debutS) else { continue }
            let delta: TimeInterval = debut.timeIntervalSince(now)
            if delta < -1800 || delta > 36 * 3600 { continue }
            let cle: String = "reunion|" + titre.lowercased() + "|" + String(debutS.prefix(16))
            if cles.contains(cle) { continue }
            if debut >= bestStart { continue }
            let kt: Set<String> = motsCles(titre)
            var lignes: [String] = []
            let df: DateFormatter = DateFormatter()
            df.locale = Locale(identifier: "fr_FR")
            df.dateFormat = "EEEE d MMMM 'à' HH:mm"
            lignes.append("Réunion : " + titre + " — " + df.string(from: debut) + ".")
            let parts: [String] = (e["participants"] as? [String]) ?? []
            if !parts.isEmpty { lignes.append("Participants : " + parts.prefix(8).joined(separator: ", ") + ".") }
            var lies: [String] = []
            for c in commitments where (c["status"] as? String) == "ouvert" {
                let quoi: String = (c["quoi"] as? String) ?? ""
                if !quoi.isEmpty && !kt.isDisjoint(with: motsCles(quoi)) { lies.append("• " + String(quoi.prefix(120))) }
                if lies.count >= 3 { break }
            }
            if !lies.isEmpty { lignes.append("Engagements ouverts liés :\n" + lies.joined(separator: "\n")) }
            var faits: [String] = []
            for f in facts {
                let ft: String = (f["text"] as? String) ?? ""
                if ft.count >= 20 && motsCles(ft).intersection(kt).count >= 2 { faits.append("• " + String(ft.prefix(160))) }
                if faits.count >= 2 { break }
            }
            if !faits.isEmpty { lignes.append("Points de ta mémoire sur ce sujet :\n" + faits.joined(separator: "\n")) }
            lignes.append("Proposition : j'arrive à la réunion avec ces éléments ; dis-moi si tu veux un ordre du jour en 3 points préparé avant.")
            best = ["cle": cle, "genre": "reunion", "titre": "Réunion préparée — " + String(titre.prefix(70)),
                    "pourquoi": "Réunion dans " + String(max(1, Int(delta / 3600))) + " h : fiche prête avant que tu la demandes.",
                    "prepare": lignes.joined(separator: "\n"),
                    "source": ["type": "agenda", "id": cle, "titre": titre],
                    "engagement": ["quoi": "Préparer : " + String(titre.prefix(120)), "qui": parts.first ?? "", "echeance": String(debutS.prefix(10))]]
            bestStart = debut
        }
        return best
    }

    // MARK: agenda structuré (EventKit, lecture seule)

    public static func evenements36h(now: Date) -> [[String: Any]] {
        #if canImport(EventKit) && os(macOS)
        guard Tools.ekAuthorized(.event) else { return [] }
        let store: EKEventStore = EKEventStore()
        let end: Date = now.addingTimeInterval(36 * 3600)
        var out: [[String: Any]] = []
        let iso: ISO8601DateFormatter = ISO8601DateFormatter()
        for c in store.calendars(for: .event) {
            let cn: String = c.title
            if cn.contains("fériés") || cn.contains("Birthdays") || cn.contains("Anniversaires") || cn.contains("Siri") || cn.contains("Scheduled") { continue }
            let evs: [EKEvent] = store.events(matching: store.predicateForEvents(withStart: now.addingTimeInterval(-1800), end: end, calendars: [c]))
            for e in evs {
                let parts: [String] = (e.attendees ?? []).compactMap { $0.name }
                out.append(["titre": e.title ?? "", "debut": iso.string(from: e.startDate), "participants": parts])
            }
        }
        return out
        #else
        return []
        #endif
    }
}

extension NovaApp {
    /// Un passage d'anticipation : prépare UNE chose, la stocke, la propose au Direct. Rien d'externe.
    @discardableResult func anticipationGenerate(now: Date) -> Bool {
        let cles: Set<String> = Preparations.clesConnues()
        let commits: [[String: Any]] = (JSONFile("commitments.json").read(default: [String: Any]())["items"] as? [[String: Any]]) ?? []
        let facts: [[String: Any]] = tools.memory.list()
        let units: [[String: Any]] = FeedUnits.list()
        let prep: [String: Any]? = Preparations.pickReunion(events: Preparations.evenements36h(now: now), commitments: commits, facts: facts, now: now, cles: cles)
            ?? Preparations.pickFeedAction(units: units, now: now, cles: cles)
            ?? Preparations.pickRapprochement(units: units, facts: facts, now: now, cles: cles)
        guard let p: [String: Any] = prep, let saved: [String: Any] = Preparations.add(p),
              let pid: String = saved["id"] as? String else { return false }
        let icon: String = ((saved["genre"] as? String) == "reunion") ? "🗓️" : (((saved["genre"] as? String) == "rapprochement") ? "🔗" : "🧭")
        ProactiveFeed.append(kind: "preparation", box: "anticipation",
            title: icon + " " + ((saved["titre"] as? String) ?? "Préparation"),
            text: ((saved["pourquoi"] as? String) ?? "") + "\n" + String(((saved["prepare"] as? String) ?? "").prefix(1800))
                + "\n— Préparé en arrière-plan, en attente de ton appréciation (préparation " + pid + " : approuvée = je crée l'engagement interne, rejetée = elle ne reviendra pas).",
            extra: ["preparation_id": pid, "genre": ((saved["genre"] as? String) ?? "")])
        Proactivite.recordFired(type: "anticipation", key: (saved["cle"] as? String) ?? pid, now: now)
        return true
    }

    func preparationsRoutes() {
        let s = server
        s.on("GET", "/api/preparations") { _, res in
            let l: [[String: Any]] = Preparations.all()
            let attente: Int = l.filter { ($0["statut"] as? String) == "en_attente" }.count
            res.json(["preparations": Array(l.suffix(60).reversed()), "en_attente": attente, "total": l.count])
        }
        // Décision d'Ahadi : approuvée crée l'engagement interne lié (aucun envoi) ; rejetée est durable.
        s.on("POST", "/api/preparations/statut") { [self] req, res in
            let id: String = (req.json["id"] as? String) ?? ""
            let statut: String = (req.json["statut"] as? String) ?? ""
            guard !id.isEmpty, ["approuvee", "rejetee", "faite"].contains(statut) else {
                res.json(["error": "id et statut (approuvee|rejetee|faite) requis"], status: 400); return
            }
            let decided: (prep: [String: Any]?, engagementCree: String) = Preparations.decider(id: id, statut: statut)
            guard decided.prep != nil else {
                res.json(["error": "preparation introuvable"], status: 404); return
            }
            res.json(["statut": statut, "id": id, "engagement_cree": decided.engagementCree])
        }
        // Déclenchement manuel (tests) : prépare tout de suite si quelque chose est mûr.
        s.on("POST", "/api/preparations/declencher") { [self] _, res in
            let fait: Bool = anticipationGenerate(now: Date())
            res.json(["status": fait ? "preparation_creee" : "rien_a_preparer", "en_attente": Preparations.all().filter { ($0["statut"] as? String) == "en_attente" }.count])
        }
    }
}
