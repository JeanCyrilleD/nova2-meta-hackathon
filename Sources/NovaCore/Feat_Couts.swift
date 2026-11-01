import Foundation

// Usage et coûts des cerveaux : agrégat par jour et par cerveau du journal réel du routeur (cerveaux_journal.jsonl).
// Le montant en $ est une ESTIMATION : grille de prix modifiable dans le réglage « prix_tokens » (modèle → {in, out} en $ par million de jetons).
// Quand un fournisseur ne renvoie pas les jetons de sortie, ils sont estimés à caractères / 4 (signalé par « out_estimes »).

struct CoutAcc {
    var calls: Int = 0
    var ok: Int = 0
    var fail: Int = 0
    var tokIn: Int = 0
    var tokOut: Int = 0
    var outEstimes: Int = 0
    var msSum: Int = 0
    var msN: Int = 0
    var usd: Double = 0
    var model: String = ""
}

public enum Couts {
    /// Grille par défaut ($ / million de jetons, tarifs publics approximatifs) : la clé est cherchée dans « id du cerveau + modèle ».
    public static let defaultPrices: [String: [String: Double]] = [
        // Tarifs publics octobre 2026. 27/10 : la grille ignorait les modèles
        // Meta — le cerveau par défaut (Spark 1.3, 38 M de jetons/semaine)
        // s'affichait à 0 $. « contributor » (11 car.) bat « muse-spark » au
        // plus-long-préfixe, comme voulu.
        "muse-wonder": ["in": 4.0, "out": 20.0],
        "muse-spark-open": ["in": 1.25, "out": 4.25],   // Baseten, page du compte 01/11/2026
        "muse-spark": ["in": 1.25, "out": 4.25],
        "contributor": ["in": 0.10, "out": 0.20],
    ]
    static let maxBytes: Int = 4_000_000
    /// 31/10 (audit) : un rapport sur plusieurs jours lit davantage du journal (sinon le mois est tronqué) ; « aujourd'hui » reste léger.
    static func bytesFor(_ jours: Int) -> Int { jours <= 1 ? maxBytes : 48_000_000 }

    static func num(_ v: Any?) -> Double {
        if let d = v as? Double { return d }
        if let i = v as? Int { return Double(i) }
        if let s = v as? String { return Double(s) ?? 0 }
        return 0
    }

    /// Fusionne la grille par défaut et le réglage « prix_tokens ».
    static func prices(_ settings: Settings) -> [String: [String: Double]] {
        var p: [String: [String: Double]] = defaultPrices
        let user: [String: Any] = settings.get("prix_tokens", [String: Any]())
        for (k, v) in user {
            guard let d = v as? [String: Any] else { continue }
            let key: String = k.lowercased()
            p[key] = ["in": num(d["in"]), "out": num(d["out"])]
        }
        return p
    }

    /// Prix applicable : la clé la plus longue contenue dans « cerveau + modèle » ; gratuit/local = 0.
    static func price(brain: String, model: String, grid: [String: [String: Double]]) -> (Double, Double) {
        let blob: String = (brain + " " + model).lowercased()
        if brain == "local" || blob.contains("free") || blob.contains("gratuit") { return (0, 0) }
        var best: String = ""
        for k in grid.keys where blob.contains(k) && k.count > best.count { best = k }
        if best.isEmpty { return (0, 0) }
        let g: [String: Double] = grid[best] ?? [:]
        return (g["in"] ?? 0, g["out"] ?? 0)
    }

    static func row(_ brain: String, _ a: CoutAcc) -> [String: Any] {
        let avg: Int = a.msN > 0 ? a.msSum / a.msN : 0
        let usd: Double = (a.usd * 10000).rounded() / 10000
        return ["brain": brain, "model": a.model, "calls": a.calls, "ok": a.ok, "fail": a.fail, "in": a.tokIn, "out": a.tokOut,
                "out_estimes": a.outEstimes, "ms_avg": avg, "usd": usd]
    }

    /// Tri : coût estimé décroissant, puis nombre d'appels.
    static func byCost(_ x: [String: Any], _ y: [String: Any]) -> Bool {
        let ux: Double = (x["usd"] as? Double) ?? 0
        let uy: Double = (y["usd"] as? Double) ?? 0
        if ux != uy { return ux > uy }
        let cx: Int = (x["calls"] as? Int) ?? 0
        let cy: Int = (y["calls"] as? Int) ?? 0
        return cx > cy
    }

    /// Coût estimé d'aujourd'hui tous cerveaux (Lot B 27/10 : plafond quotidien).
    public static func todayUsd(journal: URL, settings: Settings) -> Double {
        let r: [String: Any] = report(journal: journal, settings: settings, jours: 1)
        let brains: [[String: Any]] = (r["brains"] as? [[String: Any]]) ?? []
        return brains.reduce(0) { $0 + (($1["usd"] as? Double) ?? 0) }
    }

    /// Agrège les `jours` derniers jours (heure locale du Mac).
    static func report(journal: URL, settings: Settings, jours: Int) -> [String: Any] {
        let grid: [String: [String: Double]] = prices(settings)
        let iso: ISO8601DateFormatter = ISO8601DateFormatter()
        let dayFmt: DateFormatter = DateFormatter()
        dayFmt.locale = Locale(identifier: "en_US_POSIX")
        dayFmt.dateFormat = "yyyy-MM-dd"
        let since: Date = Calendar.current.startOfDay(for: Date()).addingTimeInterval(-Double(jours - 1) * 86400)
        let today: String = dayFmt.string(from: Date())
        var byDay: [String: [String: CoutAcc]] = [:]
        var byBrain: [String: CoutAcc] = [:]
        for line in BrainRank.tailLines(journal, maxBytes: bytesFor(jours)) {
            if line.isEmpty { continue }
            guard let e = parseJSON(Data(line.utf8)) else { continue }
            guard let brain = e["brain"] as? String, let ts = e["ts"] as? String, let when = iso.date(from: ts) else { continue }
            if when < since { continue }
            if e["sovereign"] != nil { continue }   // essais du modèle local souverain : journalisés à part, gratuits
            let day: String = dayFmt.string(from: when)
            let model: String = e["model"] as? String ?? ""
            let ok: Bool = (e["ok"] as? Bool) ?? false
            var tIn: Int = Int(num(e["in"]))
            var tOut: Int = Int(num(e["out"]))
            var estimated: Int = 0
            if ok, tOut == 0 {
                let chars: Int = Int(num(e["chars"]))
                if chars > 0 { tOut = chars / 4; estimated = tOut }
            }
            if !ok { tIn = 0; tOut = 0 }
            let pr: (Double, Double) = price(brain: brain, model: model, grid: grid)
            // 31/10 (audit) : les jetons de cache étaient ignorés. Lecture = 10 % du prix d'entrée, écriture = 125 %.
            let cRead: Int = ok ? Int(num(e["cache_read"])) : 0
            let cWrite: Int = ok ? Int(num(e["cache_write"])) : 0
            let usd: Double = (Double(tIn) * pr.0 + Double(tOut) * pr.1 + Double(cRead) * pr.0 * 0.10 + Double(cWrite) * pr.0 * 1.25) / 1_000_000
            let ms: Int = Int(num(e["ms"]))
            var dayMap: [String: CoutAcc] = byDay[day] ?? [:]
            var a: CoutAcc = dayMap[brain] ?? CoutAcc()
            var b: CoutAcc = byBrain[brain] ?? CoutAcc()
            a.calls += 1; b.calls += 1
            if ok { a.ok += 1; b.ok += 1 } else { a.fail += 1; b.fail += 1 }
            a.tokIn += tIn; b.tokIn += tIn
            a.tokOut += tOut; b.tokOut += tOut
            a.outEstimes += estimated; b.outEstimes += estimated
            if ok, ms > 0 { a.msSum += ms; a.msN += 1; b.msSum += ms; b.msN += 1 }
            a.usd += usd; b.usd += usd
            if !model.isEmpty { a.model = model; b.model = model }
            dayMap[brain] = a
            byDay[day] = dayMap
            byBrain[brain] = b
        }
        var days: [[String: Any]] = []
        var todayRow: [String: Any] = ["day": today, "calls": 0, "usd": 0.0, "brains": [[String: Any]]()]
        for day in byDay.keys.sorted(by: >) {
            let map: [String: CoutAcc] = byDay[day] ?? [:]
            var rows: [[String: Any]] = []
            var calls: Int = 0
            var usd: Double = 0
            for (brain, a) in map {
                rows.append(row(brain, a))
                calls += a.calls
                usd += a.usd
            }
            rows.sort(by: byCost)
            let usdR: Double = (usd * 10000).rounded() / 10000
            let d: [String: Any] = ["day": day, "calls": calls, "usd": usdR, "brains": rows]
            days.append(d)
            if day == today { todayRow = d }
        }
        var brains: [[String: Any]] = []
        var totalUsd: Double = 0
        var totalCalls: Int = 0
        for (brain, b) in byBrain {
            brains.append(row(brain, b))
            totalUsd += b.usd
            totalCalls += b.calls
        }
        brains.sort(by: byCost)
        let totalR: Double = (totalUsd * 10000).rounded() / 10000
        var gridOut: [String: Any] = [:]
        for (k, v) in grid { gridOut[k] = v }
        return ["estimation": true,
                "note": "Estimation : jetons du journal du routeur × grille « prix_tokens » ($ par million de jetons). Sorties non mesurées estimées à caractères / 4.",
                "jours": jours, "today": todayRow, "days": days, "brains": brains,
                "total": ["calls": totalCalls, "usd": totalR], "prix_tokens": gridOut,
                "dots_brain_key": "dots_brain", "dots_brain": settings.get("dots_brain", "")]
    }
}

// MARK: - Budget visible (VAGUE 1, 24/10/2026) — patron « budget Raycast »
// Résumé jour / mois par cerveau, plafond mensuel réglable (réglage « budget_cap_usd », 0 = aucun plafond).
// À 80 % puis 100 % du plafond : signalement UNE fois par mois et par seuil (Pulse, bus, notification).
// JAMAIS de coupure : le plafond informe, il ne bloque aucun cerveau — et l'écran le dit.

public enum CoutsBudget {
    static let etat: JSONFile = JSONFile("budget_etat.json")
    static let lock: NSLock = NSLock()

    static func monthKey(_ d: Date) -> String {
        let f: DateFormatter = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM"
        return f.string(from: d)
    }
    static func monthLabel(_ d: Date) -> String {
        let f: DateFormatter = DateFormatter()
        f.locale = Locale(identifier: "fr_FR")
        f.dateFormat = "LLLL yyyy"
        return f.string(from: d)
    }
    static func round4(_ x: Double) -> Double { (x * 10000).rounded() / 10000 }

    /// Plafond mensuel en $ (0 = aucun plafond).
    static func cap(_ settings: Settings) -> Double {
        let v: Any? = settings.all()["budget_cap_usd"]
        let d: Double = Couts.num(v)
        return d > 0 ? d : 0
    }

    /// Résumé du jour et du mois en cours, par cerveau. `label` traduit l'id d'un cerveau en libellé lisible.
    static func summary(journal: URL, settings: Settings, label: (String) -> String) -> [String: Any] {
        let now: Date = Date()
        let cal: Calendar = Calendar.current
        let dom: Int = cal.component(.day, from: now)
        let rep: [String: Any] = Couts.report(journal: journal, settings: settings, jours: max(1, dom))
        let month: String = monthKey(now)
        var accCalls: [String: Int] = [:]
        var accUsd: [String: Double] = [:]
        var mCalls: Int = 0
        var mUsd: Double = 0
        for d in (rep["days"] as? [[String: Any]]) ?? [] {
            let day: String = (d["day"] as? String) ?? ""
            if !day.hasPrefix(month) { continue }
            for b in (d["brains"] as? [[String: Any]]) ?? [] {
                let id: String = (b["brain"] as? String) ?? "?"
                let c: Int = (b["calls"] as? Int) ?? 0
                let u: Double = (b["usd"] as? Double) ?? 0
                accCalls[id] = (accCalls[id] ?? 0) + c
                accUsd[id] = (accUsd[id] ?? 0) + u
                mCalls += c
                mUsd += u
            }
        }
        var monthBrains: [[String: Any]] = []
        for (id, c) in accCalls {
            monthBrains.append(["brain": id, "label": label(id), "calls": c, "usd": round4(accUsd[id] ?? 0)])
        }
        monthBrains.sort { (x: [String: Any], y: [String: Any]) -> Bool in
            let ux: Double = (x["usd"] as? Double) ?? 0
            let uy: Double = (y["usd"] as? Double) ?? 0
            if ux != uy { return ux > uy }
            return ((x["calls"] as? Int) ?? 0) > ((y["calls"] as? Int) ?? 0)
        }
        let todayRaw: [String: Any] = (rep["today"] as? [String: Any]) ?? [:]
        var todayBrains: [[String: Any]] = []
        for b in (todayRaw["brains"] as? [[String: Any]]) ?? [] {
            let id: String = (b["brain"] as? String) ?? "?"
            todayBrains.append(["brain": id, "label": label(id), "calls": (b["calls"] as? Int) ?? 0, "usd": (b["usd"] as? Double) ?? 0.0])
        }
        let capUsd: Double = cap(settings)
        let mUsdR: Double = round4(mUsd)
        let daysInMonth: Int = cal.range(of: .day, in: .month, for: now)?.count ?? 30
        let projection: Double = dom > 0 ? round4(mUsd / Double(dom) * Double(daysInMonth)) : mUsdR
        var out: [String: Any] = [
            "estimation": true, "devise": "USD",
            "note": (rep["note"] as? String) ?? "",
            "today": ["day": (todayRaw["day"] as? String) ?? "", "calls": (todayRaw["calls"] as? Int) ?? 0, "usd": (todayRaw["usd"] as? Double) ?? 0.0, "brains": todayBrains],
            "month": ["mois": month, "label": monthLabel(now), "calls": mCalls, "usd": mUsdR, "brains": monthBrains, "projection_usd": projection, "jour": dom, "jours": daysInMonth],
            "cap_usd": capUsd, "coupure": false,
            "ts": nowISO(),
        ]
        if capUsd > 0 {
            let pct: Double = mUsd / capUsd * 100
            let lvl: String = pct >= 100 ? "depasse" : (pct >= 80 ? "alerte80" : "ok")
            out["pct"] = Int(pct.rounded())
            out["niveau"] = lvl
            out["reste_usd"] = round4(max(0, capUsd - mUsd))
            if lvl == "depasse" { out["message"] = "Plafond mensuel dépassé (estimation). Rien n'est coupé : Nova continue, c'est à toi de décider." }
            else if lvl == "alerte80" { out["message"] = "80 % du plafond mensuel atteints (estimation). Rien n'est coupé." }
            else { out["message"] = "" }
        } else {
            out["pct"] = NSNull()
            out["niveau"] = "aucun_plafond"
            out["message"] = ""
        }
        return out
    }

    /// Seuils franchis ce mois-ci et pas encore signalés (au plus un signalement par seuil et par mois).
    /// Retourne le seuil à signaler (80 ou 100), ou 0.
    static func newlyCrossed(_ b: [String: Any]) -> Int {
        guard let pct: Int = b["pct"] as? Int else { return 0 }
        let month: String = ((b["month"] as? [String: Any])?["mois"] as? String) ?? ""
        lock.lock(); defer { lock.unlock() }
        var st: [String: Any] = etat.read(default: [String: Any]())
        if (st["mois"] as? String) != month { st = ["mois": month, "a80": false, "a100": false] }
        var level: Int = 0
        if pct >= 100 && (st["a100"] as? Bool) != true { level = 100; st["a100"] = true; st["a80"] = true }
        else if pct >= 80 && (st["a80"] as? Bool) != true { level = 80; st["a80"] = true }
        if level > 0 { st["signale"] = nowISO(); etat.write(st) }
        else if (st["mois"] as? String) == month { etat.write(st) }
        return level
    }
}

extension NovaApp {
    func budgetSummary() -> [String: Any] {
        let r: Router = router
        return CoutsBudget.summary(journal: router.journal.url, settings: settings, label: { (id: String) -> String in r.spec(id)?.label ?? id })
    }

    /// Lit le budget et signale un seuil franchi (80 % / 100 %) : carte Pulse, bus, notification macOS hors heures calmes.
    /// Ne coupe jamais rien.
    @discardableResult
    func budgetWatch() -> [String: Any] {
        let b: [String: Any] = budgetSummary()
        let lvl: Int = CoutsBudget.newlyCrossed(b)
        if lvl > 0 {
            let month: [String: Any] = (b["month"] as? [String: Any]) ?? [:]
            let usd: Double = (month["usd"] as? Double) ?? 0
            let capUsd: Double = (b["cap_usd"] as? Double) ?? 0
            let usdS: String = String(format: "%.2f", usd).replacingOccurrences(of: ".", with: ",")
            let capS: String = String(format: "%.2f", capUsd).replacingOccurrences(of: ".", with: ",")
            let titre: String = lvl >= 100 ? "Plafond mensuel des cerveaux dépassé" : "80 % du plafond mensuel des cerveaux atteints"
            let l1: String = "Estimation du mois : " + usdS + " $ sur un plafond de " + capS + " $."
            let l2: String = "Rien n'est coupé : Nova continue de répondre. Ajuste le plafond ou le cerveau si tu le souhaites."
            pulseArrival(cat: "budget", titre: titre, lignes: [l1, l2], sourceNom: "Journal des cerveaux (estimation)", sourceDate: nowISO(),
                         action: ["type": "ouvrir", "module": "finance", "label": "Voir les coûts"], ref: "budget:" + ((month["mois"] as? String) ?? "") + ":" + String(lvl))
            bus.publish("budget", ["niveau": lvl, "usd": usd, "cap_usd": capUsd, "ts": nowISO()])
            #if os(macOS)
            if settings.get("notify", true), !briefs.inQuietHours() {
                _ = Tools.osa("display notification \"" + l1 + "\" with title \"Nova — " + titre + "\"", timeout: 5)
            }
            #endif
        }
        return b
    }
}

extension NovaApp {
    /// GET /api/couts?jours=7 — usage et coût estimé par jour et par cerveau.
    func coutsRoutes() {
        let s: HTTPServer = server
        let settingsRef: Settings = settings
        let url: URL = router.journal.url
        s.on("GET", "/api/couts") { req, res in
            let raw: Int = Int(req.query["jours"] ?? "7") ?? 7
            let jours: Int = max(1, min(90, raw))
            res.json(Couts.report(journal: url, settings: settingsRef, jours: jours))
        }
        // WP2 : budget en échec fermé — réglages en vigueur (jamais réécrits), configuration recommandée (100–125 $/mois hors
        // [tiers] Max), engagé du grand livre, dérogations et facturation de chaque cerveau (aucune clé, aucun contenu).
        let rt: Router = router
        s.on("GET", "/api/depense") { _, res in res.json(LLMSpend.status(brains: rt.brains)) }
        // Dérogation DÉLIBÉRÉE : {"confirmer": "DEROGATION", "montant_usd": 5, "duree_min": 60, "motif": "…", "voies": ["interactive","bench"]}.
        // Bornée (derogation_max_usd, 24 h), expirante, journalisée ; jamais pour les tâches de fond.
        s.on("POST", "/api/depense/derogation") { req, res in
            let j: [String: Any] = req.json
            guard (j["confirmer"] as? String) == "DEROGATION" else { res.json(["ok": false, "erreur": "confirmation explicite requise (confirmer = DEROGATION)"], status: 400); return }
            let usd: Double = (j["montant_usd"] as? NSNumber)?.doubleValue ?? 0
            let mins: Int = (j["duree_min"] as? NSNumber)?.intValue ?? 0
            let lanes: Set<SpendLane> = Set(((j["voies"] as? [String]) ?? ["interactive"]).compactMap { SpendLane(rawValue: $0) })
            let r = LLMSpend.grantOverride(usd: usd, minutes: mins, reason: (j["motif"] as? String) ?? "", lanes: lanes)
            if let id = r.id { res.json(["ok": true, "id": id]) } else { res.json(["ok": false, "erreur": r.error ?? "refusée"], status: 400) }
        }
        s.on("POST", "/api/depense/derogation/revoquer") { req, res in
            let id: String = (req.json["id"] as? String) ?? ""
            res.json(["ok": LLMSpend.revokeOverride(id)])
        }
    }
}
