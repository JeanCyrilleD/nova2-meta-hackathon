import Foundation

// LOT3 (25/10/2026) — ALERTES DE COURS BRVM + HISTORIQUE RELEVÉ.
//
// MAGASINS (nouveaux, aucun lecteur historique) :
//   brvm_alertes.json      {items: {SYM: {haut: Double?, bas: Double?, var: Double?, updated}}, updated}
//   brvm_alertes_etat.json {day: "AAAA-MM-JJ", fired: ["SYM|haut", …], log: [{ts, sym, type, price, var, seuil}], last_check, last_check_note}
//   brvm_historique.json   {SYM: [["AAAA-MM-JJ", cours], …]}  — UN point par jour (dernier cours VU par Nova pendant la séance) ;
//                          rien n'est rétro-rempli : la série commence le jour où Nova l'a vue.
// VÉRIFICATION : après chaque rafraîchissement réel des cours (VeillePole.quotes, crochet onFresh), pendant la
// séance BRVM (09:00–15:30 GMT, lun–ven) ; plus une veille de 5 min pendant la séance pour que les alertes
// tournent même écran Finance fermé (une requête brvm.org en cache 60 s). Une alerte déclenchée = UN événement
// du Fil direct (kind « brvm.alerte »), au plus une fois par jour et par alerte (clé SYM|type).
// FAITS SEULS : cours, variation, seuil franchi, heure du relevé, source. Aucun avis d'achat ou de vente.

public enum BRVMAlertes {
    static let file: JSONFile = JSONFile("brvm_alertes.json")
    static let stateFile: JSONFile = JSONFile("brvm_alertes_etat.json")
    static let histFile: JSONFile = JSONFile("brvm_historique.json")
    static let lock: NSLock = NSLock()
    nonisolated(unsafe) static var timer: DispatchSourceTimer? = nil   // PHASE 1 (relu, protégé) : sous lock (startTimer : test + pose)
    static let histDays: Int = 120

    static let gmt: TimeZone = TimeZone(identifier: "GMT") ?? TimeZone(secondsFromGMT: 0)!

    static func gmtCalendar() -> Calendar {
        var c: Calendar = Calendar(identifier: .gregorian)
        c.timeZone = gmt
        return c
    }

    /// Jour de séance (GMT = heure d'Abidjan), AAAA-MM-JJ.
    static func dayGMT(_ d: Date = Date()) -> String {
        let f: DateFormatter = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = gmt
        f.dateFormat = "yyyy-MM-dd"
        return f.string(from: d)
    }

    /// Séance BRVM : lundi–vendredi, 09:00–15:30 GMT (jours fériés non connus du moteur).
    public static func inSession(_ d: Date = Date()) -> Bool {
        let c: Calendar = gmtCalendar()
        let wd: Int = c.component(.weekday, from: d)   // 1 = dimanche, 7 = samedi
        if wd == 1 || wd == 7 { return false }
        let mins: Int = c.component(.hour, from: d) * 60 + c.component(.minute, from: d)
        return mins >= 9 * 60 && mins <= 15 * 60 + 30
    }

    /// Fenêtre de relevé de l'historique : séance + 60 min (le bandeau affiche alors la clôture du jour).
    static func inRecordWindow(_ d: Date = Date()) -> Bool {
        let c: Calendar = gmtCalendar()
        let wd: Int = c.component(.weekday, from: d)
        if wd == 1 || wd == 7 { return false }
        let mins: Int = c.component(.hour, from: d) * 60 + c.component(.minute, from: d)
        return mins >= 9 * 60 && mins <= 16 * 60 + 30
    }

    static func num(_ v: Any?) -> Double? {
        if let n = v as? NSNumber { return n.doubleValue }
        if let s = v as? String {
            let t: String = s.replacingOccurrences(of: " ", with: "").replacingOccurrences(of: "\u{00A0}", with: "").replacingOccurrences(of: ",", with: ".")
            if t.isEmpty { return nil }
            return Double(t)
        }
        return nil
    }

    static func validSym(_ s: String) -> Bool {
        return s.range(of: #"^[A-Z0-9]{2,8}$"#, options: .regularExpression) != nil
    }

    // MARK: alertes (lecture / écriture)

    public static func items() -> [String: [String: Any]] {
        let o: [String: Any] = file.read(default: [String: Any]())
        return (o["items"] as? [String: [String: Any]]) ?? [:]
    }

    /// Remplace les alertes d'UN symbole ({sym, haut, bas, var} ; champ vide ou nul = retiré ; tout vide = alerte supprimée).
    static func save(_ j: [String: Any]) -> (ok: Bool, error: String, items: [String: [String: Any]]) {
        let sym: String = ((j["sym"] as? String) ?? "").trimmingCharacters(in: .whitespaces).uppercased()
        if !validSym(sym) { return (false, "symbole BRVM attendu (2 à 8 lettres ou chiffres)", items()) }
        let haut: Double? = num(j["haut"])
        let bas: Double? = num(j["bas"])
        let vr: Double? = num(j["var"])
        if let h = haut, !(h > 0 && h < 10_000_000) { return (false, "seuil haut invalide", items()) }
        if let b = bas, !(b > 0 && b < 10_000_000) { return (false, "seuil bas invalide", items()) }
        if let h = haut, let b = bas, b >= h { return (false, "le seuil bas doit être inférieur au seuil haut", items()) }
        if let v = vr, !(v > 0 && v <= 100) { return (false, "variation attendue entre 0 et 100 %", items()) }
        lock.lock()
        var o: [String: Any] = file.read(default: [String: Any]())
        var all: [String: [String: Any]] = (o["items"] as? [String: [String: Any]]) ?? [:]
        if haut == nil && bas == nil && vr == nil {
            all.removeValue(forKey: sym)
        } else {
            var e: [String: Any] = ["updated": nowISO()]
            if let h = haut { e["haut"] = h }
            if let b = bas { e["bas"] = b }
            if let v = vr { e["var"] = v }
            all[sym] = e
            if all.count > 80 { lock.unlock(); return (false, "80 symboles sous alerte au plus", items()) }
        }
        o["items"] = all
        o["updated"] = nowISO()
        file.write(o)
        lock.unlock()
        return (true, "", all)
    }

    // MARK: historique relevé

    static func record(_ q: [String: (price: Double, var: Double)], now: Date) {
        if !inRecordWindow(now) || q.isEmpty { return }
        let day: String = dayGMT(now)
        lock.lock()
        var h: [String: Any] = histFile.read(default: [String: Any]())
        for (sym, v) in q where v.price > 0 {
            var serie: [[Any]] = (h[sym] as? [[Any]]) ?? []
            if let last = serie.last, (last.first as? String) == day {
                serie[serie.count - 1] = [day, v.price]
            } else {
                serie.append([day, v.price])
            }
            if serie.count > histDays { serie = Array(serie.suffix(histDays)) }
            h[sym] = serie
        }
        histFile.write(h)
        lock.unlock()
    }

    public static func history(_ syms: [String]) -> [String: [[Any]]] {
        let h: [String: Any] = histFile.read(default: [String: Any]())
        var out: [String: [[Any]]] = [:]
        for s in syms {
            if let serie = h[s] as? [[Any]] { out[s] = serie }
        }
        return out
    }

    // MARK: vérification

    /// Crochet appelé après un rafraîchissement RÉEL des cours (jamais sur le cache).
    public static func onFresh(_ q: [String: (price: Double, var: Double)]) {
        let now: Date = Date()
        Thread.detachNewThread {
            BRVMAlertes.record(q, now: now)
            BRVMAlertes.check(q, now: now)
        }
    }

    static func fmtNum(_ v: Double) -> String {
        let f: NumberFormatter = NumberFormatter()
        f.locale = Locale(identifier: "fr_FR")
        f.numberStyle = .decimal
        f.maximumFractionDigits = 2
        return f.string(from: NSNumber(value: v)) ?? String(v)
    }
    static func fmtVar(_ v: Double) -> String {
        let sign: String = v > 0 ? "+" : ""
        return sign + fmtNum((v * 100).rounded() / 100) + " %"
    }

    static func check(_ q: [String: (price: Double, var: Double)], now: Date) {
        let all: [String: [String: Any]] = items()
        let day: String = dayGMT(now)
        lock.lock()
        var st: [String: Any] = stateFile.read(default: [String: Any]())
        if (st["day"] as? String) != day { st["day"] = day; st["fired"] = [String]() }
        var fired: [String] = (st["fired"] as? [String]) ?? []
        var log: [[String: Any]] = (st["log"] as? [[String: Any]]) ?? []
        st["last_check"] = nowISO()
        if !inSession(now) {
            st["last_check_note"] = "hors séance (09:00–15:30 GMT, lun–ven) : aucune alerte évaluée"
            stateFile.write(st)
            lock.unlock()
            return
        }
        var hits: [[String: Any]] = []
        for (sym, a) in all.sorted(by: { $0.key < $1.key }) {
            guard let v = q[sym], v.price > 0 else { continue }
            if let h = num(a["haut"]), v.price >= h, !fired.contains(sym + "|haut") {
                fired.append(sym + "|haut")
                hits.append(["sym": sym, "type": "haut", "price": v.price, "var": v.var, "seuil": h])
            }
            if let b = num(a["bas"]), v.price <= b, !fired.contains(sym + "|bas") {
                fired.append(sym + "|bas")
                hits.append(["sym": sym, "type": "bas", "price": v.price, "var": v.var, "seuil": b])
            }
            if let x = num(a["var"]), abs(v.var) >= x, !fired.contains(sym + "|var") {
                fired.append(sym + "|var")
                hits.append(["sym": sym, "type": "var", "price": v.price, "var": v.var, "seuil": x])
            }
        }
        for var hRec in hits { hRec["ts"] = nowISO(); log.append(hRec) }
        st["fired"] = fired
        st["log"] = Array(log.suffix(200))
        st["last_check_note"] = String(all.count) + " symbole(s) sous alerte évalué(s) ; " + String(hits.count) + " déclenchement(s)"
        stateFile.write(st)
        lock.unlock()
        for hRec in hits { publish(hRec, now: now) }
    }

    static func publish(_ hRec: [String: Any], now: Date) {
        let sym: String = (hRec["sym"] as? String) ?? ""
        let type: String = (hRec["type"] as? String) ?? ""
        let price: Double = num(hRec["price"]) ?? 0
        let vr: Double = num(hRec["var"]) ?? 0
        let seuil: Double = num(hRec["seuil"]) ?? 0
        let name: String = VeillePole.companyName(sym)
        let hf: DateFormatter = DateFormatter()
        hf.locale = Locale(identifier: "fr_FR")
        hf.timeZone = gmt
        hf.dateFormat = "HH:mm"
        let heure: String = hf.string(from: now) + " GMT"
        var title: String = ""
        var fait: String = ""
        if type == "haut" {
            title = sym + " au-dessus de ton seuil haut"
            fait = sym + " (" + name + ") cote " + fmtNum(price) + " FCFA, au-dessus du seuil haut de " + fmtNum(seuil) + " FCFA."
        } else if type == "bas" {
            title = sym + " sous ton seuil bas"
            fait = sym + " (" + name + ") cote " + fmtNum(price) + " FCFA, sous le seuil bas de " + fmtNum(seuil) + " FCFA."
        } else {
            title = sym + " : variation du jour " + fmtVar(vr)
            fait = sym + " (" + name + ") varie de " + fmtVar(vr) + " sur la séance (seuil de ±" + fmtNum(seuil) + " %), cours " + fmtNum(price) + " FCFA."
        }
        var text: String = fait
        text += "\nVariation du jour : " + fmtVar(vr) + " · relevé à " + heure + " · source : brvm.org (bandeau public, peut être différé)."
        text += "\nAlerte posée par toi dans Finance — une fois par jour. Information uniquement, ni conseil ni ordre."
        ProactiveFeed.append(kind: "brvm.alerte", box: "brvm", title: "BRVM — " + title, text: text, urgent: false, who: "",
                             extra: ["sym": sym, "alerte": type, "day": dayGMT(now)])
        _ = BlackBox.record(["tool": "brvm_alertes", "actor": "Nova", "why": "alerte BRVM déclenchée : " + sym + " (" + type + ") à " + fmtNum(price) + " FCFA", "ok": true, "effect": "lecture"])
    }

    /// Veille de séance : toutes les 5 min, un relevé (cache 60 s de VeillePole) — le crochet onFresh fait le reste.
    static func startTimer() {
        lock.lock()
        if timer != nil { lock.unlock(); return }
        let t: DispatchSourceTimer = DispatchSource.makeTimerSource(queue: DispatchQueue.global(qos: .utility))
        t.schedule(deadline: .now() + 120, repeating: 300)
        t.setEventHandler {
            let now: Date = Date()
            if !BRVMAlertes.inRecordWindow(now) { return }
            if BRVMAlertes.items().isEmpty && !BRVMAlertes.inSession(now) { return }
            _ = VeillePole.quotes()
        }
        t.resume()
        timer = t
        lock.unlock()
    }

    public static func snapshot() -> [String: Any] {
        let now: Date = Date()
        let all: [String: [String: Any]] = items()
        var rows: [[String: Any]] = []
        for (sym, a) in all.sorted(by: { $0.key < $1.key }) {
            var r: [String: Any] = ["sym": sym, "name": VeillePole.companyName(sym)]
            if let h = num(a["haut"]) { r["haut"] = h }
            if let b = num(a["bas"]) { r["bas"] = b }
            if let v = num(a["var"]) { r["var"] = v }
            if let u = a["updated"] as? String { r["updated"] = u }
            rows.append(r)
        }
        let st: [String: Any] = stateFile.read(default: [String: Any]())
        let log: [[String: Any]] = (st["log"] as? [[String: Any]]) ?? []
        let today: String = dayGMT(now)
        let todayHits: [[String: Any]] = log.filter { (x: [String: Any]) -> Bool in
            let ts: String = (x["ts"] as? String) ?? ""
            guard let d = ISO8601DateFormatter().date(from: ts) else { return false }
            return dayGMT(d) == today
        }
        var o: [String: Any] = ["items": rows, "declenchees": Array(todayHits.reversed()), "recentes": Array(log.suffix(20).reversed()),
                                "seance": ["ouverte": inSession(now), "horaires": "lun–ven 09:00–15:30 GMT"] as [String: Any],
                                "regle": "Une alerte se déclenche au plus une fois par jour, pendant la séance, après un relevé réel des cours. Faits seuls — ni conseil ni ordre."]
        if let lc = st["last_check"] as? String { o["derniere_verif"] = lc }
        if let n = st["last_check_note"] as? String { o["derniere_verif_note"] = n }
        return o
    }
}

extension NovaApp {
    func brvmAlertesRoutes() {
        let s = server
        VeillePole.onFresh = { q in BRVMAlertes.onFresh(q) }
        BRVMAlertes.startTimer()
        s.on("GET", "/api/brvm/alertes") { _, res in res.json(BRVMAlertes.snapshot()) }
        s.on("POST", "/api/brvm/alertes") { req, res in
            let r: (ok: Bool, error: String, items: [String: [String: Any]]) = BRVMAlertes.save(req.json)
            if !r.ok { res.json(["ok": false, "error": r.error], status: 400); return }
            var snap: [String: Any] = BRVMAlertes.snapshot()
            snap["ok"] = true
            res.json(snap)
        }
        // Historique RELEVÉ par Nova (un point par jour vu en séance) — jamais reconstitué ni interpolé.
        s.on("GET", "/api/brvm/historique") { req, res in
            let raw: String = (req.query["syms"] ?? "").uppercased()
            let syms: [String] = raw.split(separator: ",").map { (x: Substring) -> String in String(x).trimmingCharacters(in: .whitespaces) }.filter { (x: String) -> Bool in BRVMAlertes.validSym(x) }
            res.json(["series": BRVMAlertes.history(Array(syms.prefix(80))),
                      "note": "Un point par jour de séance : dernier cours vu par Nova sur brvm.org. La série commence au premier relevé — aucun historique reconstitué."])
        }
    }
}
