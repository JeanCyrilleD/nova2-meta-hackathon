import Foundation

// V5-P (25/10) — documents d'âme lus avec tolérance + Gardien des relations branché sur les vrais échanges.
//
// Bugs corrigés (VERIF_AUDIT_GEMINI.md, bugs n°2 et n°3) :
//  · « valeurs » et « laisser » : l'écran écrivait des CHAÎNES, le moteur castait en [[String: Any]] —
//    une seule chaîne faisait échouer tout le cast, le contrat de valeurs n'atteignait jamais le prompt.
//    Désormais : écriture normalisée {text, on, ts} (POST /api/ame/doc) ET lecture tolérante (chaîne = valeur active).
//  · « relations » : une ligne de texte libre faisait échouer le cast du Gardien (Ame.swift) → plus aucune relance.
//    Désormais : les lignes libres sont conservées telles quelles et simplement ignorées par le Gardien.
//  · dates « last » écrites par le web (toISOString → millisecondes « .000Z ») : ISO8601DateFormatter() par défaut
//    ne les lit pas (nil → distantPast → tout le monde « en retard »). Lecture avec et sans fractions de seconde.
//
// Gardien des relations (#10) : « dernier contact » mis à jour depuis les messages RÉELLEMENT reçus et vus par le
// moteur (journal ProactiveFeed : Outlook / Gmail / Teams web, champ « who » = expéditeur), par nom ou adresse.
// Anniversaires : si le document en porte (champ « anniv », JJ/MM, MM-JJ ou AAAA-MM-JJ). Toute relance = proposition
// dans le Fil (Éclat), jamais un envoi.

public enum AmeDocParse {
    /// Les objets d'un document-liste ; toute autre entrée (ligne libre, nombre…) est ignorée — jamais perdue (le fichier n'est pas réécrit ici).
    public static func objects(_ raw: Any) -> [[String: Any]] {
        guard let arr = raw as? [Any] else { return [] }
        var out: [[String: Any]] = []
        for x in arr {
            if let d = x as? [String: Any] { out.append(d) }
        }
        return out
    }

    /// Lignes d'un document de type « valeurs » / « laisser », normalisées {text, on, ts}. Une chaîne nue = une ligne active.
    public static func lines(_ raw: Any) -> [[String: Any]] {
        guard let arr = raw as? [Any] else { return [] }
        var out: [[String: Any]] = []
        for x in arr {
            if let s = x as? String {
                let t: String = s.trimmingCharacters(in: .whitespacesAndNewlines)
                if !t.isEmpty { out.append(["text": t, "on": true, "ts": ""]) }
                continue
            }
            guard let d = x as? [String: Any] else { continue }
            let t0: String = (d["text"] as? String) ?? (d["texte"] as? String) ?? (d["valeur"] as? String) ?? (d["name"] as? String) ?? ""
            let t: String = t0.trimmingCharacters(in: .whitespacesAndNewlines)
            if t.isEmpty { continue }
            let on: Bool = (d["on"] as? Bool) ?? ((d["actif"] as? Bool) ?? true)
            let ts: String = (d["ts"] as? String) ?? ""
            out.append(["text": t, "on": on, "ts": ts])
        }
        return out
    }

    /// Écriture (POST /api/ame/doc) : pour « valeurs » et « laisser », chaque chaîne devient {text, on: true, ts}.
    /// Les objets sont gardés tels quels ; les autres documents passent inchangés.
    public static func normalize(name: String, data: Any) -> Any {
        guard name == "valeurs" || name == "laisser", let arr = data as? [Any] else { return data }
        var out: [Any] = []
        for x in arr {
            if let s = x as? String {
                let t: String = s.trimmingCharacters(in: .whitespacesAndNewlines)
                if t.isEmpty { continue }
                let o: [String: Any] = ["text": t, "on": true, "ts": nowISO()]
                out.append(o)
            } else {
                out.append(x)
            }
        }
        return out
    }

    public static func int(_ v: Any?) -> Int? {
        if let i = v as? Int { return i }
        if let d = v as? Double { return Int(d) }
        if let s = v as? String { return Int(s.trimmingCharacters(in: .whitespacesAndNewlines)) }
        return nil
    }

    /// Date ISO avec ou sans millisecondes (web : toISOString), ou « AAAA-MM-JJ » (midi local).
    public static func date(_ v: Any?) -> Date? {
        guard let s0 = v as? String else { return nil }
        let s: String = s0.trimmingCharacters(in: .whitespacesAndNewlines)
        if s.isEmpty { return nil }
        let f1: ISO8601DateFormatter = ISO8601DateFormatter()
        if let d = f1.date(from: s) { return d }
        let f2: ISO8601DateFormatter = ISO8601DateFormatter()
        f2.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let d = f2.date(from: s) { return d }
        if s.count >= 10 {
            let df: DateFormatter = DateFormatter()
            df.locale = Locale(identifier: "en_US_POSIX")
            df.dateFormat = "yyyy-MM-dd"
            if let d = df.date(from: String(s.prefix(10))) { return d.addingTimeInterval(12 * 3600) }
        }
        return nil
    }

    /// Minuscules, sans accents, tout ce qui n'est ni lettre ni chiffre devient espace.
    public static func fold(_ s: String) -> String {
        let low: String = s.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: Locale(identifier: "fr_FR")).lowercased()
        var out: String = ""
        for ch in low { out.append(ch.isLetter || ch.isNumber ? ch : " ") }
        return out
    }
    public static func tokens(_ s: String) -> [String] {
        return fold(s).split(separator: " ").map { String($0) }.filter { $0.count >= 2 }
    }
}

final class RelationsState: @unchecked Sendable {
    static let shared: RelationsState = RelationsState()
    let lock: NSLock = NSLock()
    let file: JSONFile = JSONFile("relations_sync.json")   // {last_sync, updated, checked, events, note}
    var started: Bool = false
    var lastSync: Date = Date.distantPast
    var lastBirthdayDay: String = ""
}

public enum RelationsGardien {
    static let boxLabel: [String: String] = ["ol": "Outlook", "gm": "Gmail", "tm": "Teams", "wa": "WhatsApp"]

    /// Contacts dus : cadence > 0, dernier contact connu et plus vieux que la cadence, hors deuil. Lignes libres ignorées.
    /// Un contact sans date lisible n'est PAS déclaré « en retard » (on ne sait pas) — même règle que l'écran Relations.
    public static func dueNames(_ raw: Any, now: Date) -> [String] {
        var out: [String] = []
        for r in AmeDocParse.objects(raw) {
            if (r["deuil"] as? Bool) == true { continue }
            guard let n = r["name"] as? String, !n.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { continue }
            guard let cad = AmeDocParse.int(r["cadence"]), cad > 0 else { continue }
            guard let last = AmeDocParse.date(r["last"]) else { continue }
            if now.timeIntervalSince(last) > Double(cad) * 86400 { out.append(n) }
        }
        return out
    }

    /// Adresses et alias d'un contact (champs facultatifs « email », « emails », « alias »).
    static func handles(_ c: [String: Any]) -> [String] {
        var out: [String] = []
        for k in ["email", "alias"] {
            if let s = c[k] as? String { out.append(contentsOf: s.components(separatedBy: CharacterSet(charactersIn: ",;"))) }
            if let a = c[k] as? [Any] { for x in a { if let s = x as? String { out.append(s) } } }
        }
        if let a = c["emails"] as? [Any] { for x in a { if let s = x as? String { out.append(s) } } }
        return out.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
    }

    /// Le message vient-il de ce contact ? Adresse : contenue telle quelle dans l'expéditeur. Nom ou alias : TOUS ses mots
    /// (≥ 2 lettres) présents comme mots entiers dans l'expéditeur (« Awa » ↔ « Awa Exemple <awa@…> »).
    public static func matches(_ c: [String: Any], who: String) -> Bool {
        let w: String = who.trimmingCharacters(in: .whitespacesAndNewlines)
        if w.isEmpty { return false }
        let wl: String = w.lowercased()
        let wt: Set<String> = Set(AmeDocParse.tokens(w))
        var names: [String] = []
        if let n = c["name"] as? String { names.append(n) }
        for h in handles(c) {
            if h.contains("@") {
                if wl.contains(h.lowercased()) { return true }
            } else {
                names.append(h)
            }
        }
        for n in names {
            let nt: [String] = AmeDocParse.tokens(n)
            if nt.isEmpty { continue }
            var all: Bool = true
            for t in nt where !wt.contains(t) { all = false; break }
            if all { return true }
        }
        return false
    }

    /// Événements « message reçu » exploitables : mail.new / teams.new avec un expéditeur, hors lots résumés et lignes brutes.
    static func exchanges() -> [[String: Any]] {
        var out: [[String: Any]] = []
        for e in ProactiveFeed.list(limit: 200) {
            let kind: String = (e["kind"] as? String) ?? ""
            guard kind == "mail.new" || kind == "teams.new" else { continue }
            let who: String = (e["who"] as? String) ?? ""
            if who.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { continue }
            let title: String = (e["title"] as? String) ?? ""
            if title.contains("lot résumé") || title.contains("ligne(s) nouvelle(s)") { continue }
            out.append(e)
        }
        return out
    }

    /// Met à jour « last » des contacts depuis les échanges réels. Ne recule jamais une date (une saisie plus récente d'Ahadi gagne).
    /// Le document est réécrit seulement si quelque chose change, toutes ses entrées (lignes libres comprises) dans le même ordre.
    @discardableResult public static func sync(now: Date = Date()) -> [String: Any] {
        let st: RelationsState = RelationsState.shared
        st.lock.lock(); defer { st.lock.unlock() }
        let f: JSONFile = JSONFile("ame_relations.json")
        var arr: [Any] = f.read(default: [Any]())
        let evs: [[String: Any]] = exchanges()
        var updated: [String] = []
        var checked: Int = 0
        for i in arr.indices {
            guard var c = arr[i] as? [String: Any], let name = c["name"] as? String, !name.isEmpty else { continue }
            checked += 1
            let cur: Date? = AmeDocParse.date(c["last"])
            var best: (Date, [String: Any])? = nil
            for e in evs {
                guard let d = AmeDocParse.date(e["ts"]) else { continue }
                if let b = best, b.0 >= d { continue }
                if matches(c, who: (e["who"] as? String) ?? "") { best = (d, e) }
            }
            guard let b = best else { continue }
            if let cd = cur, cd >= b.0 { continue }
            let box: String = (b.1["box"] as? String) ?? ""
            let label: String = boxLabel[box] ?? box
            let title: String = String(((b.1["title"] as? String) ?? "").prefix(70))
            c["last"] = (b.1["ts"] as? String) ?? nowISO()
            c["last_source"] = "message reçu (" + label + ")" + (title.isEmpty ? "" : " — « " + title + " »")
            c["last_auto"] = true
            arr[i] = c
            updated.append(name)
        }
        if !updated.isEmpty { f.write(arr) }
        st.lastSync = now
        let state: [String: Any] = ["last_sync": nowISO(), "updated": updated, "checked": checked, "events": evs.count,
                                    "note": evs.isEmpty ? "aucun message reçu avec expéditeur dans le journal des volets (Outlook, Gmail, Teams web) — rien à rapprocher" : ""]
        st.file.write(state)
        return state
    }

    /// Jours jusqu'au prochain anniversaire (0 = aujourd'hui), nil si le champ est absent ou illisible.
    /// Formes : « JJ/MM », « JJ/MM/AAAA », « JJ.MM », « MM-JJ », « AAAA-MM-JJ ».
    public static func birthdayIn(_ v: Any?, now: Date) -> Int? {
        guard let s0 = v as? String else { return nil }
        let s: String = s0.trimmingCharacters(in: .whitespacesAndNewlines)
        if s.isEmpty { return nil }
        let parts: [String] = s.split(whereSeparator: { $0 == "-" || $0 == "/" || $0 == "." }).map { String($0) }
        var m: Int = 0
        var d: Int = 0
        if parts.count == 3 && parts[0].count == 4 { m = Int(parts[1]) ?? 0; d = Int(parts[2]) ?? 0 }
        else if parts.count == 2 && s.contains("-") { m = Int(parts[0]) ?? 0; d = Int(parts[1]) ?? 0 }
        else if parts.count >= 2 { d = Int(parts[0]) ?? 0; m = Int(parts[1]) ?? 0 }
        guard m >= 1, m <= 12, d >= 1, d <= 31 else { return nil }
        let cal: Calendar = Calendar.current
        let today: Date = cal.startOfDay(for: now)
        let y: Int = cal.component(.year, from: today)
        for yy in [y, y + 1] {
            var dc: DateComponents = DateComponents()
            dc.year = yy; dc.month = m; dc.day = d
            if let dt = cal.date(from: dc), dt >= today { return cal.dateComponents([.day], from: today, to: dt).day }
        }
        return nil
    }

    /// Anniversaires dans les `within` jours, hors deuil : [(nom, jours)].
    public static func birthdays(_ raw: Any, now: Date, within: Int = 2) -> [(String, Int)] {
        var out: [(String, Int)] = []
        for c in AmeDocParse.objects(raw) {
            if (c["deuil"] as? Bool) == true { continue }
            guard let n = c["name"] as? String, !n.isEmpty, let k = birthdayIn(c["anniv"], now: now), k <= within else { continue }
            out.append((n, k))
        }
        return out.sorted { $0.1 < $1.1 }
    }
}

extension NovaApp {
    /// V5-P : point d'entrée unique du lot P (une ligne dans Extras.extraRoutes()). Routes + veille de fond + bloc de prompt.
    func ameViveRoutes() {
        relationsRoutes()
        revesRoutes()
        boucleRoutes()
        archeoRoutes()
        deuilRoutes()
        boucleHookPrompt()
        ameViveStart()
    }

    func relationsRoutes() {
        let s = server
        s.on("GET", "/api/relations/etat") { [self] _, res in
            let raw: Any = ameDoc("relations")
            let all: [Any] = (raw as? [Any]) ?? []
            let objs: [[String: Any]] = AmeDocParse.objects(raw)
            let libres: Int = all.count - objs.count
            var bd: [[String: Any]] = []
            for (n, k) in RelationsGardien.birthdays(raw, now: Date(), within: 30) { let o: [String: Any] = ["name": n, "jours": k]; bd.append(o) }
            let body: [String: Any] = ["sync": RelationsState.shared.file.read(default: [String: Any]()), "lignes_libres": libres, "contacts": objs.count,
                                       "dus": RelationsGardien.dueNames(raw, now: Date()), "anniversaires": bd,
                                       "sources": "messages reçus vus par Nova dans les volets Outlook, Gmail et Teams web (journal des 200 derniers événements)"]
            res.json(body)
        }
        s.on("POST", "/api/relations/sync") { _, res in
            let r: [String: Any] = RelationsGardien.sync()
            res.json(r)
        }
    }

    /// Veille de fond du lot P : un seul fil, une passe toutes les 5 minutes (premier passage 90 s après le démarrage).
    /// Rattrape aussi ce que le Mac endormi a manqué : chaque passe compare à la DERNIÈRE exécution réussie, pas à l'horloge.
    func ameViveStart() {
        let st: RelationsState = RelationsState.shared
        st.lock.lock()
        if st.started { st.lock.unlock(); return }
        st.started = true
        st.lock.unlock()
        Thread.detachNewThread { [self] in
            Thread.sleep(forTimeInterval: 90)
            while true {
                let now: Date = Date()
                // 1) Relations : rapprochement avec les échanges réels, toutes les 30 min.
                st.lock.lock(); let due: Bool = now.timeIntervalSince(st.lastSync) > 1800; st.lock.unlock()
                if due { _ = RelationsGardien.sync(now: now) }
                // 2) Anniversaires : une fois par jour dès 9 h, hors heures calmes — proposition seulement.
                let day: String = String(nowISO().prefix(10))
                let hh: Int = Calendar.current.component(.hour, from: now)
                st.lock.lock(); let bdDone: Bool = st.lastBirthdayDay == day; st.lock.unlock()
                if hh >= 9, !bdDone, !briefs.inQuietHours() {
                    st.lock.lock(); st.lastBirthdayDay = day; st.lock.unlock()
                    let bds: [(String, Int)] = RelationsGardien.birthdays(ameDoc("relations"), now: now, within: 2)
                    if !bds.isEmpty {
                        var parts: [String] = []
                        for (n, k) in bds {
                            var when: String = " (dans " + String(k) + " j)"
                            if k == 0 { when = " (aujourd'hui)" } else if k == 1 { when = " (demain)" }
                            parts.append(n + when)
                        }
                        let txt: String = parts.joined(separator: ", ")
                        publishDot(id: "relations-anniv", name: "Gardien des relations", emoji: "🎂", color: "#8b5cf6", summary: "Anniversaire : " + txt + ". Un brouillon de message t'attend dans Relations si tu le veux — rien n'est envoyé.")
                    }
                }
                // 3) Rêves : rattrapage si la distillation de 23:30 a été manquée (Mac endormi ou éteint).
                reveCatchUp(now: now)
                // 4) Boucle fermée : auto-évaluation hebdomadaire (dimanche soir, ou au premier passage après).
                boucleWeeklyIfDue(now: now)
                Thread.sleep(forTimeInterval: 300)
            }
        }
    }
}
