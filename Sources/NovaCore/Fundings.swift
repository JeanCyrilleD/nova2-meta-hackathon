import Foundation

// V4 (24/10/2026) — CAMPAGNE FUNDINGS (Bloc 4 du cahier d'Ahadi). Branché dans Extras.extraRoutes().
// Source : DOSSIER_fundings_Nova2_2026-10-24.md (spec NON NÉGOCIABLE §0–§5), coupure 2026-10-24T14:45:00Z.
//
// Règles codées en dur ici (§0 et §5) :
//  - le magasin fundings_campaign.json est AMORCÉ une fois (seed versionné) ; un amorçage ultérieur
//    n'ajoute que des entrées absentes — un statut mis à jour ensuite n'est JAMAIS écrasé ;
//  - un statut ne change QUE sur preuve d'un message du programme lui-même (champ preuve + expéditeur) ;
//  - montants ACQUIS et montants VISÉS : deux compteurs séparés, jamais additionnés ;
//  - aucun mot de passe, aucun identifiant secret, aucune donnée SCI, rien hors campagne
//    (les sujets RH personnels sont hors campagne : ils ne sont écrits nulle part) ;
//  - zéro brouillon, zéro envoi : ce module enregistre et affiche, il n'émet rien vers l'extérieur.

enum Fundings {
    static let file: JSONFile = JSONFile("fundings_campaign.json")
    static let lock: NSLock = NSLock()
    static let seedVersion: Int = 2   // V5-I : v2 = point d'Ahadi du 24/10 20:13 GMT (migration douce, voir seedV2Patches)
    static let cutOff: String = "2026-10-24T14:45:00Z"
    static let sourceDossier: String = "dossier Fundings du 24/10/2026 (coupure 14:45 GMT)"
    static let categories: [String] = ["APPROBATION", "REFUS", "RÉPONSE ATTENDUE", "ACTION REQUISE", "SIMPLE ACCUSÉ"]
    static let doctrine: String = "Chaque approbation → intégration nommée sous 7 jours, fonction visible à la démo du 03/11 ; jamais présentée comme du cash levé."
    static let regles: [String] = [
        "Un statut n'est « confirmé » que sur message du programme lui-même. « Candidature reçue » ≠ « approuvé ».",
        "Les montants « visés » ne sont jamais présentés comme acquis ni additionnés aux crédits acquis.",
        "Zéro brouillon automatique (ordre du 23/10 07:56) ; zéro envoi sans GO d'Ahadi item par item.",
        "Jamais d'identifiant, de mot de passe ni de donnée SCI dans ce canal.",
        "Refusés / garés / clos : verrouillés — aucune relance sans décision d'Ahadi.",
    ]
    static let identite: [String: Any] = [
        "nom": "Nova", "porteur": "", "note": "version publique (hackathon) : identité de campagne retirée",
    ]

    /// Garde d'étanchéité : tout texte entrant qui ressemble à un secret, à une donnée SCI ou au hors-campagne est refusé.
    static let forbiddenRx: NSRegularExpression = try! NSRegularExpression(pattern: #"mot\s+de\s+passe|password|passwd|\bmdp\b|\botp\b|code\s+de\s+(?:v[ée]rification|s[ée]curit[ée])|api[_\s-]?key\s*[:=]|secret\s*[:=]|token\s*[:=]|bearer\s+[a-z0-9]|\bsk-[a-z0-9_-]{8,}|probation|save\s+the\s+children|\bSCI\b"#, options: [.caseInsensitive])
    static func forbidden(_ s: String) -> Bool {
        forbiddenRx.firstMatch(in: s, range: NSRange(location: 0, length: (s as NSString).length)) != nil
    }

    // MARK: amorçage (photographie de référence du dossier)

    static func prog(_ id: String, _ section: String, _ programme: String, statut: String, montant: String,
                     acquisUSD: Double? = nil, viseUSD: Double? = nil, confirme: Bool = true,
                     action: String = "", echeance: String = "", refs: String = "", note: String = "") -> [String: Any] {
        var o: [String: Any] = ["id": id, "section": section, "programme": programme, "statut": statut, "montant": montant,
                                "action": action, "echeance": echeance, "refs": refs, "note": note,
                                "source": sourceDossier, "maj": cutOff]
        if let a = acquisUSD { o["montant_acquis_usd"] = a; o["confirme"] = confirme }
        if let v = viseUSD { o["montant_vise_usd"] = v }
        if section == "clos" { o["verrou"] = true }
        return o
    }

    static let attente22: String = "SOUMIS le 22/10 — confirmation reçue, en attente de décision"

    static let seedProgrammes: [[String: Any]] = []   // version publique (hackathon) : données personnelles de campagne retirées — le module démarre vide

    static func ech(_ id: String, _ date: String, _ label: String, programme: String, heure: String = "", approx: Bool = false) -> [String: Any] {
        ["id": id, "date": date, "heure": heure, "label": label, "programme": programme, "approx": approx, "source": sourceDossier]
    }
    /// §4 — échéances et alertes programmées. Les sujets RH personnels sont HORS CAMPAGNE :
    /// le dossier ordonne de ne pas l'afficher dans Nova — elle n'est donc pas écrite, ni ici ni ailleurs.
    static let seedEcheances: [[String: Any]] = []   // version publique (hackathon) : données personnelles de campagne retirées — le module démarre vide

    /// V5-I — migration v2 (point d'Ahadi du 24/10 20:13 GMT) : champs corrigés sur les lignes DÉJÀ amorcées.
    /// Une ligne n'est corrigée que si elle n'a jamais été touchée depuis l'amorçage v1 (maj == coupure et source == dossier) :
    /// un statut mis à jour par un message de programme n'est JAMAIS écrasé (l'écart est consigné dans migration_v2).
    static let seedV2Patches: [String: [String: Any]] = {
        var out: [String: [String: Any]] = [:]
        for id in ["daytona", "composio"] {
            guard let p = seedProgrammes.first(where: { ($0["id"] as? String) == id }) else { continue }
            var f: [String: Any] = [:]
            for k in ["statut", "montant", "montant_acquis_usd", "confirme", "action", "echeance"] { if let v = p[k] { f[k] = v } }
            out[id] = f
        }
        return out
    }()
    static let seedV2Source: String = "point d'Ahadi du 24/10/2026 20:13 GMT"

    /// Amorce le magasin une fois ; un seed de version supérieure n'ajoute QUE les entrées absentes. Verrou tenu par l'appelant.
    static func ensureSeededLocked() -> [String: Any] {
        var o: [String: Any] = file.read(default: [String: Any]())
        let cur: Int = (o["seed_version"] as? Int) ?? 0
        if cur >= seedVersion, o["programmes"] != nil { return o }
        var progs: [[String: Any]] = (o["programmes"] as? [[String: Any]]) ?? []
        let have: Set<String> = Set(progs.compactMap { (p: [String: Any]) -> String? in p["id"] as? String })
        if cur >= 1 && cur < 2 {
            var log: [[String: Any]] = []
            for i in progs.indices {
                let id: String = (progs[i]["id"] as? String) ?? ""
                guard let patch = seedV2Patches[id] else { continue }
                let untouched: Bool = (progs[i]["maj"] as? String) == cutOff && (progs[i]["source"] as? String) == sourceDossier
                if untouched {
                    for (k, v) in patch { progs[i][k] = v }
                    progs[i]["source"] = sourceDossier + " · corrigé par le " + seedV2Source
                    log.append(["id": id, "applique": true])
                } else {
                    log.append(["id": id, "applique": false, "motif": "ligne mise à jour depuis l'amorçage (message de programme) : conservée telle quelle"])
                }
            }
            o["migration_v2"] = ["ts": nowISO(), "source": seedV2Source, "lignes": log] as [String: Any]
        }
        for p in seedProgrammes where !have.contains((p["id"] as? String) ?? "") { progs.append(p) }
        var echs: [[String: Any]] = (o["echeances"] as? [[String: Any]]) ?? []
        let haveE: Set<String> = Set(echs.compactMap { (e: [String: Any]) -> String? in e["id"] as? String })
        for e in seedEcheances where !haveE.contains((e["id"] as? String) ?? "") { echs.append(e) }
        o["programmes"] = progs
        o["echeances"] = echs
        if o["events"] == nil { o["events"] = [[String: Any]]() }
        if o["seeded_at"] == nil { o["seeded_at"] = nowISO() }
        o["seed_version"] = seedVersion
        o["cut_off"] = cutOff
        file.write(o)
        return o
    }

    // MARK: lecture

    static let utc: TimeZone = TimeZone(identifier: "UTC") ?? TimeZone.current
    static func dayDate(_ s: String) -> Date? {
        let f: DateFormatter = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX"); f.timeZone = utc; f.dateFormat = "yyyy-MM-dd"
        return f.date(from: String(s.prefix(10)))
    }
    /// Jours restants (fuseau de Ouagadougou = GMT) entre aujourd'hui et la date ; négatif si passée.
    static func daysLeft(_ s: String, now: Date = Date()) -> Int? {
        guard let d: Date = dayDate(s) else { return nil }
        var cal: Calendar = Calendar(identifier: .gregorian); cal.timeZone = utc
        return cal.dateComponents([.day], from: cal.startOfDay(for: now), to: cal.startOfDay(for: d)).day
    }
    static func num(_ v: Any?) -> Double? {
        if let n = v as? NSNumber { return n.doubleValue }
        if let s = v as? String { return Double(s.replacingOccurrences(of: " ", with: "").replacingOccurrences(of: ",", with: ".")) }
        return nil
    }
    /// Défense en profondeur : rien de hors campagne ne ressort, même si quelqu'un l'avait écrit à la main dans le fichier.
    static func clean(_ l: [[String: Any]]) -> [[String: Any]] {
        l.filter { (x: [String: Any]) -> Bool in
            let t: String = ((x["label"] as? String) ?? "") + " " + ((x["programme"] as? String) ?? "") + " " + ((x["statut"] as? String) ?? "")
            return t.range(of: "probation", options: .caseInsensitive) == nil
        }
    }

    static func sortedEcheances(_ raw: [[String: Any]], now: Date = Date()) -> [[String: Any]] {
        var out: [[String: Any]] = []
        for var e in clean(raw) {
            let d: String = (e["date"] as? String) ?? ""
            guard let n: Int = daysLeft(d, now: now) else { continue }
            e["days_left"] = n
            e["passee"] = n < 0
            out.append(e)
        }
        func key(_ e: [String: Any]) -> String { ((e["date"] as? String) ?? "") + " " + ((e["heure"] as? String) ?? "") }
        let fut: [[String: Any]] = out.filter { (($0["days_left"] as? Int) ?? 0) >= 0 }.sorted { key($0) < key($1) }
        let past: [[String: Any]] = out.filter { (($0["days_left"] as? Int) ?? 0) < 0 }.sorted { key($0) > key($1) }
        return fut + past
    }

    static func state() -> [String: Any] {
        lock.lock()
        let o: [String: Any] = ensureSeededLocked()
        lock.unlock()
        let progs: [[String: Any]] = clean((o["programmes"] as? [[String: Any]]) ?? [])
        let acquis: [[String: Any]] = progs.filter { ($0["section"] as? String) == "acquis" }
        let attente: [[String: Any]] = progs.filter { ($0["section"] as? String) == "en_attente" }
        let clos: [[String: Any]] = progs.filter { ($0["section"] as? String) == "clos" }.map { (p: [String: Any]) -> [String: Any] in
            var q: [String: Any] = p; q["verrou"] = true; q["relance"] = "aucune sans GO d'Ahadi"; return q
        }
        // Deux compteurs, jamais additionnés : acquis confirmés (et, à part, acquis en validation) ≠ montants visés.
        var acquisUSD: Double = 0, validationUSD: Double = 0, viseUSD: Double = 0
        for p in acquis {
            if let a: Double = num(p["montant_acquis_usd"]) {
                if (p["confirme"] as? Bool) == false { validationUSD += a } else { acquisUSD += a }
            }
        }
        for p in acquis + attente { if let v: Double = num(p["montant_vise_usd"]) { viseUSD += v } }
        let echs: [[String: Any]] = sortedEcheances((o["echeances"] as? [[String: Any]]) ?? [])
        let prochaines: [[String: Any]] = Array(echs.filter { (($0["days_left"] as? Int) ?? -1) >= 0 }.prefix(3))
        let events: [[String: Any]] = Array(clean((o["events"] as? [[String: Any]]) ?? []).reversed().prefix(100))
        let totals: [String: Any] = [
            "acquis_usd": acquisUSD, "acquis_en_validation_usd": validationUSD, "vise_usd": viseUSD,
            "n_acquis": acquis.count, "n_en_attente": attente.count, "n_clos": clos.count,
            "note": "Compteurs séparés : les montants visés ne sont jamais additionnés aux crédits acquis.",
        ]
        return ["identite": identite, "cut_off": cutOff, "seed_version": (o["seed_version"] as? Int) ?? seedVersion,
                "acquis": acquis, "en_attente": attente, "clos": clos,
                "echeances": echs, "prochaines": prochaines, "events": events, "totals": totals,
                "categories": categories, "doctrine": doctrine, "regles": regles, "generated": nowISO()]
    }

    // MARK: événements de surveillance

    static func canonCategorie(_ raw: String) -> String? {
        let f: String = raw.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: Locale(identifier: "fr_FR")).uppercased()
            .replacingOccurrences(of: "_", with: " ").trimmingCharacters(in: .whitespacesAndNewlines)
        switch f {
        case "APPROBATION": return "APPROBATION"
        case "REFUS": return "REFUS"
        case "REPONSE ATTENDUE": return "RÉPONSE ATTENDUE"
        case "ACTION REQUISE": return "ACTION REQUISE"
        case "SIMPLE ACCUSE": return "SIMPLE ACCUSÉ"
        default: return nil
        }
    }
    static func fold(_ s: String) -> String {
        s.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: Locale(identifier: "fr_FR")).trimmingCharacters(in: .whitespacesAndNewlines)
    }
    static func matchIndex(_ progs: [[String: Any]], _ name: String) -> Int? {
        let n: String = fold(name)
        guard !n.isEmpty else { return nil }
        if let i = progs.firstIndex(where: { fold(($0["id"] as? String) ?? "") == n || fold(($0["programme"] as? String) ?? "") == n }) { return i }
        guard n.count >= 4 else { return nil }
        return progs.firstIndex(where: { (p: [String: Any]) -> Bool in
            let pn: String = fold((p["programme"] as? String) ?? "")
            let first: String = pn.split(separator: " ").first.map { String($0) } ?? pn
            return pn.hasPrefix(n) || n.hasPrefix(pn) || (first.count >= 4 && n.hasPrefix(first))
        })
    }
    static func clip(_ v: Any?, _ n: Int) -> String {
        String(((v as? String) ?? "").trimmingCharacters(in: .whitespacesAndNewlines).prefix(n))
    }

    /// V5-S (25/10) : origine d'un événement — « pilote » (POST /api/fundings/event, passes de surveillance) ou
    /// « zoho-direct » (lecture directe de la boîte campagne, Feat_Zoho.swift). Clé de programme pour l'anti-doublon.
    static func origineOf(_ v: Any?) -> String { fold((v as? String) ?? "") == "zoho-direct" ? "zoho-direct" : "pilote" }
    static func eventKey(_ e: [String: Any]) -> String {
        let pid: String = (e["programme_id"] as? String) ?? ""
        return pid.isEmpty ? fold((e["programme"] as? String) ?? "") : pid
    }

    /// Enregistre un résultat de surveillance. Retourne (réponse, statut HTTP, événement à pousser au Fil direct ou nil).
    /// zohoActive (V5-S) : la lecture directe Zoho est connectée ET a déjà synchronisé — un push du pilote qui
    /// recouvre un message déjà lu en direct est ignoré (200, duplicate:true) ; sinon le comportement est inchangé.
    static func ingest(_ j: [String: Any], zohoActive: Bool = false) -> (body: [String: Any], status: Int, push: [String: Any]?) {
        let programme: String = clip(j["programme"], 120)
        guard !programme.isEmpty else { let b: [String: Any] = ["error": "programme requis"]; return (b, 400, nil) }
        guard let cat: String = canonCategorie(clip(j["categorie"], 40)) else {
            let b: [String: Any] = ["error": "categorie ∈ APPROBATION | REFUS | RÉPONSE ATTENDUE | ACTION REQUISE | SIMPLE ACCUSÉ"]
            return (b, 400, nil)
        }
        var rec: [String: Any] = ["programme": programme, "categorie": cat,
                                  "statut": clip(j["statut"], 300), "montant": clip(j["montant"], 120), "action": clip(j["action"], 300),
                                  "echeance": clip(j["echeance"], 40), "expediteur": clip(j["expediteur"], 160), "objet": clip(j["objet"], 240),
                                  "phrase_cle": clip(j["phrase_cle"], 400), "source": clip(j["source"], 120)]
        let all: String = rec.values.compactMap { $0 as? String }.joined(separator: " ")
        if forbidden(all) {
            let b: [String: Any] = ["error": "refusé : contenu hors périmètre campagne (secret, identifiant, donnée SCI ou hors campagne) — rien n'a été enregistré"]
            return (b, 422, nil)
        }
        // Preuve : seul un message DU PROGRAMME (expéditeur nommé) peut changer un statut.
        let pv: Any? = j["preuve"]
        let preuveStr: String = fold((pv as? String) ?? "")
        let preuve: Bool = ((pv as? Bool) == true || preuveStr == "message_programme" || preuveStr == "message du programme" || preuveStr == "programme")
            && !((rec["expediteur"] as? String) ?? "").isEmpty
        rec["preuve"] = preuve
        if let mu: Double = num(j["montant_usd"]), mu > 0, mu < 100_000_000 { rec["montant_usd"] = mu }
        // V5-S : origine, identifiant du message et date du message (posés APRÈS le filtre d'étanchéité :
        // un Message-ID n'est pas du contenu et pourrait déclencher un faux refus).
        let origine: String = origineOf(j["origine"])
        let msgId: String = clip(j["message_id"], 240)
        let dateMsg: String = clip(j["date_message"], 40)
        rec["origine"] = origine
        if !msgId.isEmpty { rec["message_id"] = msgId }
        if !dateMsg.isEmpty { rec["date_message"] = dateMsg }

        lock.lock()
        var o: [String: Any] = ensureSeededLocked()
        var progs: [[String: Any]] = (o["programmes"] as? [[String: Any]]) ?? []
        var events: [[String: Any]] = (o["events"] as? [[String: Any]]) ?? []
        // Anti-doublon : la même passe relue deux fois ne crée pas deux événements.
        let sig: String = [programme, cat, (rec["objet"] as? String) ?? "", (rec["expediteur"] as? String) ?? "", (rec["statut"] as? String) ?? ""].map { fold($0) }.joined(separator: "|")
        if let dup = events.first(where: { ($0["sig"] as? String) == sig }) {
            lock.unlock()
            let b: [String: Any] = ["ok": true, "deja": true, "event": dup]
            return (b, 200, nil)
        }
        let idx: Int? = matchIndex(progs, programme)
        // V5-S — anti-doublon par programme + message : la clé de programme est l'id du dossier quand il est reconnu.
        let progKey: String = idx.map { (i: Int) -> String in (progs[i]["id"] as? String) ?? fold(programme) } ?? fold(programme)
        let objetF: String = fold((rec["objet"] as? String) ?? "")
        let dayMsg: String = String(dateMsg.prefix(10))
        if !msgId.isEmpty, let dup = events.first(where: { eventKey($0) == progKey && (($0["message_id"] as? String) ?? "") == msgId }) {
            lock.unlock()
            let b: [String: Any] = ["ok": true, "deja": true, "duplicate": true, "event": dup, "motif": "même programme, même message"]
            return (b, 200, nil)
        }
        // Bascule : lecture directe active → un push du pilote déjà vu en direct (même programme, même message-id
        // ou même objet [+ même jour si les deux sont datés]) est ignoré ; les pushes que Zoho n'a pas vus passent.
        // Dans l'autre sens, un message lu en direct déjà poussé par le pilote ne crée pas un second événement.
        let other: String = origine == "pilote" ? "zoho-direct" : "pilote"
        if (origine == "pilote" && zohoActive) || origine == "zoho-direct", !objetF.isEmpty,
           let dup = events.first(where: { (e: [String: Any]) -> Bool in
               guard origineOf(e["origine"]) == other, eventKey(e) == progKey else { return false }
               guard fold((e["objet"] as? String) ?? "") == objetF else { return false }
               let d2: String = String(((e["date_message"] as? String) ?? "").prefix(10))
               return dayMsg.isEmpty || d2.isEmpty || d2 == dayMsg
           }) {
            lock.unlock()
            let why: String = origine == "pilote" ? "déjà lu en direct dans la boîte Zoho — push du pilote ignoré" : "déjà consigné par le pilote — aucun second événement"
            let b: [String: Any] = ["ok": true, "deja": true, "duplicate": true, "event": dup, "motif": why]
            return (b, 200, nil)
        }
        var applique: Bool = false
        var motif: String = ""
        if let i = idx {
            rec["programme_id"] = (progs[i]["id"] as? String) ?? ""
            rec["programme"] = (progs[i]["programme"] as? String) ?? programme
            let majP: String = (progs[i]["maj"] as? String) ?? ""
            if preuve && !dateMsg.isEmpty && !majP.isEmpty && dateMsg < majP {
                // V5-S : un message plus ancien que la dernière mise à jour de la ligne ne l'écrase jamais (relecture de l'historique de la boîte).
                motif = "statut inchangé : message antérieur à la dernière mise à jour de la ligne (" + majP + ")"
            } else if preuve {
                var p: [String: Any] = progs[i]
                let st: String = (rec["statut"] as? String) ?? ""
                p["statut"] = st.isEmpty ? cat : st
                p["derniere_categorie"] = cat
                p["maj"] = nowISO()
                p["source"] = "message du programme (" + ((rec["expediteur"] as? String) ?? "") + ")"
                if !((rec["action"] as? String) ?? "").isEmpty { p["action"] = rec["action"] }
                if !((rec["echeance"] as? String) ?? "").isEmpty { p["echeance"] = rec["echeance"] }
                if cat == "APPROBATION" {
                    if let v = p["montant_vise_usd"] { p["vise_initial_usd"] = v; p.removeValue(forKey: "montant_vise_usd") }
                    if let mu: Double = rec["montant_usd"] as? Double { p["montant_acquis_usd"] = mu; p["confirme"] = true }
                    if !((rec["montant"] as? String) ?? "").isEmpty { p["montant"] = rec["montant"] }
                    p["section"] = "acquis"
                } else if cat == "REFUS" {
                    if let v = p["montant_vise_usd"] { p["vise_initial_usd"] = v; p.removeValue(forKey: "montant_vise_usd") }
                    p["section"] = "clos"; p["verrou"] = true
                }
                progs[i] = p
                applique = true
                motif = "statut mis à jour sur message du programme"
            } else {
                motif = "statut inchangé : la source n'est pas un message du programme (preuve absente)"
            }
        } else {
            motif = "programme absent du dossier — événement consigné, aucun statut touché"
        }
        rec["statut_applique"] = applique
        rec["motif"] = motif
        let eid: String = String(UUID().uuidString.prefix(8)).lowercased()
        rec["id"] = eid
        rec["ts"] = nowISO()
        rec["sig"] = sig
        rec["lu"] = false
        // ACTION REQUISE datée (AAAA-MM-JJ) → alerte ajoutée aux échéances.
        let echeance: String = (rec["echeance"] as? String) ?? ""
        if cat == "ACTION REQUISE", dayDate(echeance) != nil, echeance.count >= 10 {
            var echs: [[String: Any]] = (o["echeances"] as? [[String: Any]]) ?? []
            let label: String = ((rec["action"] as? String) ?? "").isEmpty ? "Action requise" : ((rec["action"] as? String) ?? "")
            echs.append(["id": "ev-" + eid, "date": String(echeance.prefix(10)), "heure": "", "label": label,
                         "programme": (rec["programme_id"] as? String) ?? programme, "approx": false, "source": "événement " + eid])
            o["echeances"] = echs
        }
        events.append(rec)
        o["events"] = Array(events.suffix(500))
        o["programmes"] = progs
        file.write(o)
        lock.unlock()
        let b: [String: Any] = ["ok": true, "event": rec, "statut_applique": applique, "motif": motif]
        return (b, 200, rec)
    }

    static func markRead(_ id: String) -> Bool {
        lock.lock(); defer { lock.unlock() }
        var o: [String: Any] = ensureSeededLocked()
        var events: [[String: Any]] = (o["events"] as? [[String: Any]]) ?? []
        var changed: Bool = false
        for i in events.indices where id == "*" || (events[i]["id"] as? String) == id {
            if (events[i]["lu"] as? Bool) != true { events[i]["lu"] = true; changed = true }
        }
        if changed { o["events"] = events; file.write(o) }
        return changed
    }

    /// V5-H : notification native (cliquable → Feeds › Fundings) pour les seuls événements qui demandent l'attention
    /// d'Ahadi — APPROBATION, REFUS, ACTION REQUISE. SIMPLE ACCUSÉ et RÉPONSE ATTENDUE : rien (le Fil direct suffit).
    /// Sans preuve (message du programme), le statut n'a pas bougé : la notification le dit.
    static func notify(_ rec: [String: Any], urgent: Bool, enabled: Bool, quiet: Bool) {
        let cat: String = (rec["categorie"] as? String) ?? ""
        guard ["APPROBATION", "REFUS", "ACTION REQUISE"].contains(cat) else { return }
        func v(_ k: String) -> String { ((rec[k] as? String) ?? "").trimmingCharacters(in: .whitespacesAndNewlines) }
        var parts: [String] = []
        if cat == "APPROBATION" { parts.append("Approuvé" + (v("montant").isEmpty ? "" : " · " + v("montant"))) }
        else if cat == "REFUS" { parts.append("Refusé — ligne verrouillée, aucune relance sans ton GO") }
        else {
            parts.append("Action requise" + (v("action").isEmpty ? "" : " : " + v("action")))
            if !v("echeance").isEmpty { parts.append("échéance " + v("echeance")) }
        }
        if (rec["preuve"] as? Bool) != true { parts.append("non confirmé par le programme, statut inchangé") }
        NovaNotifier.send(source: "fundings", title: "Nova — Fundings · " + v("programme"), body: parts.joined(separator: " · "),
                          target: ["module": "veille", "id": "fundings:" + v("id")], urgent: urgent, enabled: enabled, quiet: quiet)
    }

    /// Fil direct : même mécanisme que tous les producteurs — le journal proactif est écrit,
    /// puis le matérialiseur (App) compose le message (DirectCompose.templateText « fundings »)
    /// et publie direct.appended. Le canal se lit sur kind/box = "fundings".
    /// V5-S : factorisé hors de la route pour servir aussi la lecture directe Zoho (Feat_Zoho.swift) ;
    /// notify = false pour les messages anciens relus à la première synchronisation (pas de rafale de notifications).
    static func publish(_ rec: [String: Any], bus busRef: Bus, settings st: Settings, briefs br: Briefs, notify doNotify: Bool) {
        let cat: String = (rec["categorie"] as? String) ?? ""
        let prog: String = (rec["programme"] as? String) ?? ""
        var urgent: Bool = false
        if cat == "ACTION REQUISE", let n: Int = Fundings.daysLeft((rec["echeance"] as? String) ?? ""), n >= 0, n <= 2 { urgent = true }
        ProactiveFeed.append(kind: "fundings", box: "fundings", title: prog + " — " + cat, text: Fundings.directText(rec),
                             urgent: urgent, who: (rec["expediteur"] as? String) ?? "")
        busRef.publish("fundings", ["event": rec])
        if doNotify {
            Fundings.notify(rec, urgent: urgent, enabled: st.get("notify", true), quiet: br.inQuietHours())   // V5-H : APPROBATION / REFUS / ACTION REQUISE seulement
        }
        let origine: String = (rec["origine"] as? String) ?? "pilote"
        _ = BlackBox.record(["tool": "fundings", "actor": "Nova", "why": "Fundings : événement « \(cat) » consigné pour \(prog) (\(origine)) — \((rec["motif"] as? String) ?? "")", "ok": true, "effect": "écrit"])
    }

    /// Texte producteur du Fil direct (lignes « Clé : valeur », format fermé lu par DirectCompose.templateText « fundings »).
    static func directText(_ rec: [String: Any]) -> String {
        func v(_ k: String) -> String { ((rec[k] as? String) ?? "").trimmingCharacters(in: .whitespacesAndNewlines) }
        var lines: [String] = [
            "Programme : " + v("programme"),
            "Catégorie : " + v("categorie"),
            "Statut : " + (v("statut").isEmpty ? v("categorie") : v("statut")),
            "Montant : " + (v("montant").isEmpty ? "—" : v("montant")),
            "Action : " + (v("action").isEmpty ? "aucune" : v("action")),
            "Échéance : " + (v("echeance").isEmpty ? "—" : v("echeance")),
        ]
        if !v("expediteur").isEmpty { lines.append("De : " + v("expediteur")) }
        if !v("objet").isEmpty { lines.append("Objet : " + v("objet")) }
        if !v("phrase_cle").isEmpty { lines.append("Phrase clé : " + v("phrase_cle")) }
        if !v("source").isEmpty { lines.append("Source : " + v("source")) }
        else if v("origine") == "zoho-direct" { lines.append("Source : lecture directe de la boîte Zoho (lecture seule)") }
        lines.append("Preuve : " + (((rec["preuve"] as? Bool) ?? false) ? "message du programme" : "non — statut inchangé"))
        return lines.joined(separator: "\n")
    }
}

extension NovaApp {
    func fundingsRoutes() {
        let s = server
        let busRef: Bus = bus
        let st: Settings = settings
        let br: Briefs = briefs
        s.on("GET", "/api/fundings") { _, res in
            res.json(Fundings.state())
        }
        s.on("POST", "/api/fundings/event") { req, res in
            // V5-S : bascule propre — tant que la lecture directe Zoho n'est pas active, comportement inchangé ;
            // dès qu'elle l'est, un push qui recouvre un message déjà lu en direct est ignoré (duplicate:true).
            let r: (body: [String: Any], status: Int, push: [String: Any]?) = Fundings.ingest(req.json, zohoActive: Zoho.directActive())
            res.json(r.body, status: r.status)
            guard let rec = r.push else { return }
            Fundings.publish(rec, bus: busRef, settings: st, briefs: br, notify: true)
        }
        s.on("POST", "/api/fundings/read") { req, res in
            let id: String = (req.json["id"] as? String) ?? ""
            if id.isEmpty { res.json(["error": "id requis (ou « * » pour tout)"], status: 400); return }
            res.json(["ok": true, "changed": Fundings.markRead(id)])
        }

        // V5-I (24/10) — CRÉDITS ACQUIS : suivi, alertes, replis (Credits.swift). Aucune de ces routes n'envoie quoi que ce soit
        // à l'extérieur, sauf l'export [tiers] (LECTURE de l'index, déclenchée par le clic d'Ahadi ; aucune suppression).
        let keyStore: KeyStore = keys
        Credits.startScheduler()   // alertes J-30 / J-7 / J-1, date d'alerte posée, budget 50/80/95 % — 1re vérification 2 min après le lancement, puis toutes les heures
        s.on("GET", "/api/credits") { _, res in
            res.json(Credits.state(settings: st))
        }
        s.on("POST", "/api/credits/rearm") { req, res in
            let p: String = String(((req.json["provider"] as? String) ?? "").prefix(40))
            if p.isEmpty { res.json(["error": "provider requis"], status: 400); return }
            res.json(["ok": true, "rearme": Credits.rearm(p)])
        }
        s.on("POST", "/api/credits/amd/activate") { _, res in
            // Verrou explicite d'Ahadi : aucune activation AMD depuis Nova, quelle que soit la demande.
            _ = BlackBox.record(["tool": "credits", "actor": "Nova", "ok": false, "effect": "refus", "why": "Activation AMD Developer Cloud refusée : règle d'Ahadi « ne pas activer tant que les charges GPU ne sont pas prêtes » (crédits valables 30 jours après activation)", "result": "amd_locked"])
            NovaNotifier.send(source: "credits-amd", title: "Nova — AMD verrouillé", body: "Activation refusée : les 100 $ AMD s'évaporent 30 jours après activation. Règle : ne pas activer tant que les charges GPU ne sont pas prêtes.",
                              target: ["module": "veille", "id": "fundings:credit-amd"], sound: false)
            res.json(["ok": false, "verrou": true, "error": "AMD : ne pas activer tant que les charges GPU de Nova ne sont pas prêtes (crédits valables 30 jours après activation). Nova n'active jamais AMD."], status: 423)
        }
        s.on("POST", "/api/credits/check") { _, res in
            res.json(["ok": true, "envoyees": Credits.checkAlerts()])
        }
    }
}
