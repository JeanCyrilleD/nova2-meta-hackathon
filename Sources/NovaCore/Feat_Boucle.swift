import Foundation

// V5-P (25/10) — BOUCLE FERMÉE (P5 / #28, VERIF_AUDIT_GEMINI.md).
//  1. Les manquements consignés par Ahadi (notes kind « manquement », écran Âme) sont RELUS dans chaque prompt :
//     les 5 plus récents encore actifs (note.done != true), ≤ 700 caractères, à côté des leçons d'outils (Feat_Lecons).
//  2. Auto-évaluation hebdomadaire ÉCRITE PAR NOVA, le dimanche soir (≥ 19 h, ou au premier passage après si le Mac
//     dormait), à partir de données réelles : actions et échecs de la BlackBox, cartes de confirmation (approuvées,
//     refusées, expirées — confiance_decisions.json), délai jusqu'au GO (go_delais.jsonl), leçons d'outils, manquements.
//  3. Dérive = indicateurs mesurés semaine contre semaine (taux d'erreur, refus, délai médian jusqu'au GO, manquements),
//     avec des seuils simples et affichés. Aucune note inventée, aucun score composite.
// Le délai jusqu'au GO n'était mesuré nulle part : Tools.decide (Tools+Security.swift) appelle GoDelais.note (une ligne).

public enum GoDelais {
    static let journal: Journal = Journal("go_delais.jsonl")
    /// Appelé par Tools.decide (clic Autoriser / Refuser) avec l'horodatage de création de la carte.
    public static func note(created: String?, ok: Bool, kind: String) {
        guard let c = AmeDocParse.date(created) else { return }
        let s: Int = max(0, Int(Date().timeIntervalSince(c)))
        let e: [String: Any] = ["delai_s": s, "ok": ok, "kind": String(kind.prefix(80))]
        journal.add(e)
    }
}

final class BoucleState: @unchecked Sendable {
    static let shared: BoucleState = BoucleState()
    let lock: NSLock = NSLock()
    let reports: JSONFile = JSONFile("boucle_hebdo.json")   // [{semaine, debut, fin, ts, indicateurs, precedente, derives, texte, brain, origine}]
    var hooked: Bool = false
    var running: Bool = false
}

public enum Boucle {
    static func median(_ a: [Int]) -> Int? {
        if a.isEmpty { return nil }
        let s: [Int] = a.sorted()
        if s.count % 2 == 1 { return s[s.count / 2] }
        return (s[s.count / 2 - 1] + s[s.count / 2]) / 2
    }

    /// Indicateurs mesurés sur [from, to[. Chaque valeur vient d'un fichier du magasin ; NSNull quand rien n'est mesurable.
    public static func stats(from: Date, to: Date) -> [String: Any] {
        func inRange(_ v: Any?) -> Bool {
            guard let d = AmeDocParse.date(v) else { return false }
            return d >= from && d < to
        }
        var actions: Int = 0
        var erreurs: Int = 0
        var refusPolitique: Int = 0
        for row in BlackBox.tail(5000) {
            guard inRange(row["ts"]), let e = row["entry"] as? [String: Any] else { continue }
            let tool: String = (e["tool"] as? String) ?? ""
            if tool == "first_paint" { continue }
            actions += 1
            let effect: String = (e["effect"] as? String) ?? ""
            if effect == "refusé" { refusPolitique += 1; continue }
            if (e["ok"] as? Bool) == false { erreurs += 1 }
        }
        var approuve: Int = 0
        var refuse: Int = 0
        var expire: Int = 0
        let decs: [[String: Any]] = JSONFile("confiance_decisions.json").read(default: [[String: Any]]())
        for d in decs where inRange(d["ts"]) {
            let o: String = (d["outcome"] as? String) ?? ""
            if o == "approuve" || o == "modifie" { approuve += 1 } else if o == "refuse" { refuse += 1 } else if o == "expire" { expire += 1 }
        }
        var delais: [Int] = []
        var goRefus: Int = 0
        for g in GoDelais.journal.tail(3000) where inRange(g["ts"]) {
            if (g["ok"] as? Bool) == true, let s = AmeDocParse.int(g["delai_s"]) { delais.append(s) } else { goRefus += 1 }
        }
        var lecons: Int = 0
        let ls: [[String: Any]] = JSONFile("lecons_outils.json").read(default: [[String: Any]]())
        for l in ls where inRange(l["ts"]) { lecons += 1 }
        var manq: Int = 0
        let notes: [[String: Any]] = JSONFile("notes.json").read(default: [[String: Any]]())
        for n in notes where (n["kind"] as? String) == "manquement" && inRange(n["updated"]) { manq += 1 }
        var taux: Any = NSNull()
        if actions > 0 {
            let t: Double = (Double(erreurs) / Double(actions) * 1000).rounded() / 1000
            taux = t
        }
        var med: Any = NSNull()
        if let m = median(delais) { med = m }
        let out: [String: Any] = ["actions": actions, "erreurs": erreurs, "taux_erreur": taux, "refus_politique": refusPolitique,
                                  "cartes_approuvees": approuve, "cartes_refusees": refuse, "cartes_expirees": expire,
                                  "go_n": delais.count, "go_refus": goRefus, "go_median_s": med,
                                  "lecons_outils": lecons, "manquements": manq,
                                  "debut": ISO8601DateFormatter().string(from: from), "fin": ISO8601DateFormatter().string(from: to)]
        return out
    }

    /// Dérives : seuils simples, publiés tels quels (aucun score). cur = semaine examinée, prev = semaine d'avant.
    public static func drifts(cur: [String: Any], prev: [String: Any]) -> [[String: Any]] {
        var out: [[String: Any]] = []
        let ca: Int = AmeDocParse.int(cur["actions"]) ?? 0
        let pa: Int = AmeDocParse.int(prev["actions"]) ?? 0
        if ca >= 10 && pa >= 10, let ct = cur["taux_erreur"] as? Double, let pt = prev["taux_erreur"] as? Double, ct - pt >= 0.05 {
            let o: [String: Any] = ["indicateur": "taux d'erreur des actions", "avant": pt, "maintenant": ct, "regle": "hausse ≥ 5 points, ≥ 10 actions chaque semaine"]
            out.append(o)
        }
        let cr: Int = AmeDocParse.int(cur["cartes_refusees"]) ?? 0
        let pr: Int = AmeDocParse.int(prev["cartes_refusees"]) ?? 0
        if cr >= 3 && cr >= 2 * pr {
            let o: [String: Any] = ["indicateur": "propositions refusées par Ahadi", "avant": pr, "maintenant": cr, "regle": "≥ 3 refus et au moins le double de la semaine d'avant"]
            out.append(o)
        }
        let cn: Int = AmeDocParse.int(cur["go_n"]) ?? 0
        let pn: Int = AmeDocParse.int(prev["go_n"]) ?? 0
        if cn >= 3 && pn >= 3, let cm = AmeDocParse.int(cur["go_median_s"]), let pm = AmeDocParse.int(prev["go_median_s"]), Double(cm) >= 1.5 * Double(pm), cm - pm >= 60 {
            let o: [String: Any] = ["indicateur": "délai médian jusqu'au GO (s)", "avant": pm, "maintenant": cm, "regle": "× 1,5 et + 60 s au moins, ≥ 3 GO chaque semaine"]
            out.append(o)
        }
        let cq: Int = AmeDocParse.int(cur["manquements"]) ?? 0
        let pq: Int = AmeDocParse.int(prev["manquements"]) ?? 0
        if cq >= 2 && cq > pq {
            let o: [String: Any] = ["indicateur": "manquements consignés", "avant": pq, "maintenant": cq, "regle": "≥ 2 et plus que la semaine d'avant"]
            out.append(o)
        }
        return out
    }

    /// Les 5 manquements actifs les plus récents : [(titre, leçon, date)].
    static func activeShortcomings(limit: Int = 5) -> [[String: Any]] {
        let notes: [[String: Any]] = JSONFile("notes.json").read(default: [[String: Any]]())
        let m: [[String: Any]] = notes.filter { ($0["kind"] as? String) == "manquement" && ($0["done"] as? Bool) != true }
        let sorted: [[String: Any]] = m.sorted { (($0["updated"] as? String) ?? "") > (($1["updated"] as? String) ?? "") }
        return Array(sorted.prefix(limit))
    }

    /// Bloc du suffixe dynamique du prompt (≤ 700 caractères). Vide s'il n'y a rien à relire.
    public static func promptBlock() -> String {
        var s: String = ""
        let items: [[String: Any]] = activeShortcomings(limit: 5)
        if !items.isEmpty {
            s = "MANQUEMENTS RELEVÉS PAR AHADI (les plus récents encore actifs — ne les répète pas) :"
            for n in items {
                let t: String = String(((n["title"] as? String) ?? "").replacingOccurrences(of: "\n", with: " ").prefix(110))
                let l: String = String(((n["body"] as? String) ?? "").replacingOccurrences(of: "\n", with: " ").prefix(110))
                if t.isEmpty { continue }
                let line: String = "\n- " + t + (l.isEmpty ? "" : " → leçon : " + l)
                if s.count + line.count > 620 { break }
                s += line
            }
        }
        let reps: [[String: Any]] = BoucleState.shared.reports.read(default: [[String: Any]]())
        if let last = reps.last, let ds = last["derives"] as? [[String: Any]], !ds.isEmpty,
           let ts = AmeDocParse.date(last["ts"]), Date().timeIntervalSince(ts) < 8 * 86400 {
            let names: [String] = ds.compactMap { $0["indicateur"] as? String }
            let line: String = "\nDÉRIVE MESURÉE la semaine passée : " + names.joined(separator: ", ") + " en hausse — sois plus prudent sur ces points."
            if s.count + line.count <= 700 { s += line }
        }
        return s.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Clé du dernier dimanche (AAAA-MM-JJ) dont 19 h est passé, et cette borne.
    static func lastSundayBoundary(now: Date) -> (String, Date)? {
        let cal: Calendar = Calendar.current
        var d: Date = cal.startOfDay(for: now)
        let df: DateFormatter = DateFormatter()
        df.locale = Locale(identifier: "en_US_POSIX")
        df.dateFormat = "yyyy-MM-dd"
        for _ in 0..<9 {
            if cal.component(.weekday, from: d) == 1, let at19 = cal.date(bySettingHour: 19, minute: 0, second: 0, of: d), now >= at19 {
                return (df.string(from: d), at19)
            }
            guard let p = cal.date(byAdding: .day, value: -1, to: d) else { return nil }
            d = p
        }
        return nil
    }
}

extension NovaApp {
    /// Compose Persona.envProvider (déjà composé par leconsStart) avec le bloc des manquements. Une seule fois.
    func boucleHookPrompt() {
        let st: BoucleState = BoucleState.shared
        st.lock.lock()
        let already: Bool = st.hooked
        st.hooked = true
        st.lock.unlock()
        if already { return }
        let old: (() -> String)? = Persona.envProvider
        Persona.envProvider = {
            let a: String = old?() ?? ""
            let b: String = Boucle.promptBlock()
            if b.isEmpty { return a }
            if a.isEmpty { return b }
            return a + "\n" + b
        }
    }

    /// Écrit le rapport de la semaine [end - 7 j, end[ (comparée à la précédente). Nova rédige ; les chiffres viennent du magasin.
    @discardableResult func boucleWriteReport(key: String, end: Date, origine: String) -> [String: Any] {
        let st: BoucleState = BoucleState.shared
        st.lock.lock()
        if st.running { st.lock.unlock(); let busy: [String: Any] = ["error": "rédaction déjà en cours"]; return busy }
        st.running = true
        st.lock.unlock()
        let start: Date = end.addingTimeInterval(-7 * 86400)
        let cur: [String: Any] = Boucle.stats(from: start, to: end)
        let prev: [String: Any] = Boucle.stats(from: start.addingTimeInterval(-7 * 86400), to: start)
        let ds: [[String: Any]] = Boucle.drifts(cur: cur, prev: prev)
        let notes: [[String: Any]] = JSONFile("notes.json").read(default: [[String: Any]]())
        let f: ISO8601DateFormatter = ISO8601DateFormatter()
        var weekManq: [String] = []
        for n in notes {
            guard (n["kind"] as? String) == "manquement", let d = AmeDocParse.date(n["updated"]), d >= start, d < end else { continue }
            let t: String = (n["title"] as? String) ?? ""
            let b: String = (n["body"] as? String) ?? ""
            weekManq.append("- " + String((t + " → " + b).prefix(200)))
        }
        let lecons: [[String: Any]] = JSONFile("lecons_outils.json").read(default: [[String: Any]]())
        var weekLec: [String] = []
        for l in lecons {
            guard weekLec.count < 8, let d = AmeDocParse.date(l["ts"]), d >= start, d < end else { continue }
            let tool: String = (l["tool"] as? String) ?? "?"
            let err: String = String(((l["error"] as? String) ?? "").prefix(120))
            let fixed: Bool = !(((l["fix"] as? String) ?? "").isEmpty)
            weekLec.append("- outil " + tool + " : " + err + (fixed ? " (résolu)" : " (non résolu)"))
        }
        var data: String = "SEMAINE du " + String(f.string(from: start).prefix(10)) + " au " + String(f.string(from: end).prefix(10)) + "\n"
        data += "INDICATEURS (semaine examinée) : " + jsonLine(cur) + "\n"
        data += "INDICATEURS (semaine précédente) : " + jsonLine(prev) + "\n"
        data += "DÉRIVES DÉTECTÉES (règles fixes) : " + (ds.isEmpty ? "aucune" : jsonLine(ds)) + "\n"
        data += "MANQUEMENTS CONSIGNÉS PAR AHADI CETTE SEMAINE :\n" + (weekManq.isEmpty ? "(aucun)" : weekManq.joined(separator: "\n")) + "\n"
        data += "LEÇONS D'OUTILS DE LA SEMAINE :\n" + (weekLec.isEmpty ? "(aucune)" : weekLec.joined(separator: "\n"))
        let sys: String = "TU ÉCRIS TON AUTO-ÉVALUATION HEBDOMADAIRE (boucle fermée, principe P5). En français, 120 à 220 mots, trois parties courtes en markdown : **Ce qui a tenu**, **Ce qui a dérapé** (avec les chiffres fournis), **Ma règle pour la semaine prochaine** (une seule, concrète). Appuie-toi UNIQUEMENT sur les chiffres et listes fournis ; cite-les ; n'invente aucune note, aucun score, aucun événement. Si les données sont trop maigres, dis-le en une phrase. Pas de flatterie, pas d'excuse."
        let r: (text: String, brain: String)? = ameAsk(sys, data, deep: false, maxTokens: 900)
        var rep: [String: Any] = ["semaine": key, "debut": f.string(from: start), "fin": f.string(from: end), "ts": nowISO(), "origine": origine,
                                  "indicateurs": cur, "precedente": prev, "derives": ds]
        if let rr = r { rep["texte"] = rr.text; rep["brain"] = rr.brain } else { rep["texte"] = ""; rep["brain"] = ""; rep["note"] = "aucun cerveau n'a répondu : indicateurs seuls" }
        st.lock.lock()
        var l: [[String: Any]] = st.reports.read(default: [[String: Any]]())
        l.removeAll { ($0["semaine"] as? String) == key }
        l.append(rep)
        st.reports.write(Array(l.suffix(26)))
        st.running = false
        st.lock.unlock()
        if !ds.isEmpty || r != nil {
            publishDot(id: "boucle-hebdo", name: "Boucle fermée", emoji: "🔁", color: "#64748b", summary: "Mon auto-évaluation de la semaine est écrite" + (ds.isEmpty ? "" : " — " + String(ds.count) + " dérive(s) mesurée(s)") + ". Âme › Auto-évaluation.")
        }
        return rep
    }

    func jsonLine(_ o: Any) -> String {
        return String(decoding: jsonData(o), as: UTF8.self)
    }

    func boucleWeeklyIfDue(now: Date) {
        guard let bound = Boucle.lastSundayBoundary(now: now) else { return }
        let key: String = bound.0
        let end: Date = bound.1
        let reps: [[String: Any]] = BoucleState.shared.reports.read(default: [[String: Any]]())
        if reps.contains(where: { ($0["semaine"] as? String) == key }) { return }
        if now.timeIntervalSince(end) > 6 * 86400 { return }   // borne trop ancienne (≥ 6 j) : on attend le prochain dimanche plutôt qu'un rapport tardif
        _ = boucleWriteReport(key: key, end: end, origine: "dimanche 19 h")
    }

    // Cache court (30 s) : deux passes de statistiques sur 14 jours prenaient 2 s mesurées à chaque ouverture de l'écran Âme.
    static var boucleCache: (at: Date, value: [String: Any])? = nil
    static let boucleLock: NSLock = NSLock()

    func boucleRoutes() {
        let s = server
        s.on("GET", "/api/boucle") { _, res in
            NovaApp.boucleLock.lock()
            if let c: (at: Date, value: [String: Any]) = NovaApp.boucleCache, Date().timeIntervalSince(c.at) < 30 {
                NovaApp.boucleLock.unlock()
                res.json(c.value)
                return
            }
            NovaApp.boucleLock.unlock()
            let now: Date = Date()
            let cur: [String: Any] = Boucle.stats(from: now.addingTimeInterval(-7 * 86400), to: now)
            let prev: [String: Any] = Boucle.stats(from: now.addingTimeInterval(-14 * 86400), to: now.addingTimeInterval(-7 * 86400))
            let reps: [[String: Any]] = BoucleState.shared.reports.read(default: [[String: Any]]())
            let body: [String: Any] = ["courante": cur, "precedente": prev, "derives": Boucle.drifts(cur: cur, prev: prev),
                                       "rapports": Array(reps.suffix(8).reversed()), "prompt": Boucle.promptBlock(),
                                       "manquements_actifs": Boucle.activeShortcomings(limit: 50).count]
            NovaApp.boucleLock.lock()
            NovaApp.boucleCache = (at: Date(), value: body)
            NovaApp.boucleLock.unlock()
            res.json(body)
        }
        s.on("POST", "/api/boucle/rediger") { [self] _, res in
            let now: Date = Date()
            let df: DateFormatter = DateFormatter()
            df.locale = Locale(identifier: "en_US_POSIX")
            df.dateFormat = "yyyy-MM-dd"
            let r: [String: Any] = boucleWriteReport(key: "demande-" + df.string(from: now), end: now, origine: "à la demande")
            res.json(r)
        }
    }
}
