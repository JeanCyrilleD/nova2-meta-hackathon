import Foundation
import NovaFoundation

/// 29/10 (Ahadi : « les 100 $ sont déjà utilisés, je suis à 120 $ d'API [tiers] ») — dépense réelle des cerveaux PAYANTS.
///
/// Constat (journal du 19/10, 22:14 → 00:00) : 92 appels [tiers] en 1 h 45 sans qu'Ahadi parle à Nova — les tâches de fond
/// (Dots, Éclats, briefs, autonomie) héritaient du cerveau des Réglages ([tiers]) en tête de chaîne.
///
/// Règles (dossier crédits §2 : compteur, alerte 80 %, repli 100 %, jamais de dépassement payé) :
/// • chaque appel d'un cerveau facturé est chiffré au prix VERSIONNÉ (SpendPolicy.swift : fournisseur / endpoint / modèle, provenance, date) ;
/// • une tâche de FOND n'utilise jamais un cerveau « premium » ([tiers], [tiers], Argon, [tiers]) : [tiers] d'abord ;
/// • plafond du jour pour le fond (réglage « budget_fond_jour_usd », 0,75 $) et pour les bancs (« budget_banc_jour_usd », 2 $) ;
/// • budget du mois (réglage « budget_llm_mois_usd », 90 $ par défaut — JAMAIS réécrit par le code) : alerte à 80 %, à 100 %
///   seulement des cerveaux à gratuité VÉRIFIÉE ; sinon rien n'est envoyé (fond) ou une dérogation délibérée est demandée (premier plan).
/// • WP2 (31/10) : échec fermé — facturation inconnue ≠ gratuit, la chaîne d'origine n'est JAMAIS rétablie, réservation atomique
///   avant chaque envoi dans le grand livre de la phase 2 (couts_v2.sqlite, même quand routage_v2 = false), micro-dollars entiers.
///   Interrupteur : réglage « depense_reservations_v1 » (vrai par défaut) ; faux = plus de réservation, la politique reste fermée.
///   Voir docs/BUDGET_V1.md.
/// • diagnostic lisible : releves/diag/depenses.json (totaux, aucun contenu).
public enum LLMSpend {
    static let lock = NSLock()
    static let file: JSONFile = JSONFile("depenses_llm.json")

    /// Cerveaux réservés aux échanges avec Ahadi (jamais en tâche de fond).
    public static let premium: Set<String> = SpendPolicy.premium

    // MARK: - Prix versionnés et grand livre (WP2)

    static func book() -> PriceBook { PriceBook(registry: RoutingV2.registry()) }
    /// Facturation d'un cerveau du catalogue (diagnostic, tableau de bord).
    public static func billing(_ s: BrainSpec) -> Billing { book().billing(s) }
    static var reservationsOn: Bool { Settings().get("depense_reservations_v1", true) }

    final class Boot: @unchecked Sendable { let lock = NSLock(); var done = false }
    static let boot = Boot()
    /// Grand livre partagé avec la phase 2. Au premier usage du processus : reprise UNIQUE du compteur JSON du mois (solde d'ouverture)
    /// et passage en « kept » des réservations orphelines d'un plantage (> 2 h) — toujours comptées.
    static func ledger(now: Date = Date()) -> CostLedger? {
        guard let led = RoutingV2.ledger() else { return nil }
        boot.lock.lock(); defer { boot.lock.unlock() }
        if !boot.done {
            boot.done = true
            let m = spentMicros(now)
            let other: Micros = max(0, m.month - m.dayBg - m.dayBench)
            if led.seedOpeningOnce(monthOther: other, dayBackground: m.dayBg, dayBench: m.dayBench, now: now) {
                _ = BlackBox.record(["tool": "depense", "actor": "Nova", "ok": true, "effect": "config", "why": "grand livre v1 : reprise unique du compteur du mois",
                                     "result": "ouverture \(Money.format(m.month))"])
            }
            _ = led.sweepStale(olderThan: 7200, now: now)
        }
        return led
    }

    static func caps() -> CostLedger.Caps {
        let month: Micros = max(0, Money.micros(usd: monthBudget()))
        return CostLedger.Caps(monthHard: month, dayForeground: month, dayBackground: max(0, Money.micros(usd: bgDayCap())),
                               perTask: Int64.max / 4, dayBench: max(0, Money.micros(usd: benchDayCap())))
    }

    public static func currentLane(background: Bool) -> SpendLane { isBench() ? .bench : (background ? .background : .interactive) }

    /// Réserve avant un envoi (routeur v1 ET chemins directs : CAFU, diagnostic, sondes, images). Voir SpendPolicy.preflight.
    public static func preflight(spec s: BrainSpec, estIn: Int, maxOut: Int, calls: Int = 1, lane: SpendLane, task: String? = nil,
                                 worstMaxOut: Int? = nil, worstCalls: Int? = nil, now: Date = Date()) -> Preflight {
        let led: CostLedger? = ledger(now: now)
        let sp = spentMicros(now)
        let floorDay: Micros = lane == .background ? sp.dayBg : (lane == .bench ? sp.dayBench : 0)
        let oid: String? = lane == .background ? nil : led?.activeOverride(lane: lane.ledgerLane, now: now)?.id
        let r: Preflight = SpendPolicy.preflight(ledger: led, book: book(), spec: s, estIn: estIn, maxOut: maxOut, calls: calls, lane: lane, caps: caps(),
                                                 floorMonth: sp.month, floorDay: floorDay, overrideId: oid, task: task, reserveEnabled: reservationsOn,
                                                 worstMaxOut: worstMaxOut, worstCalls: worstCalls, now: now)
        if case .refused(let why) = r {
            _ = BlackBox.record(["tool": "depense", "actor": "Nova", "ok": false, "effect": "lecture", "why": "réservation refusée avant envoi", "result": String(why.prefix(300))])
        }
        return r
    }
    /// POST facturé hors Router vers une API de modèle (Meta Muse Image, SAM…) : aucun prix versionné → facturation inconnue,
    /// réservée AVANT l'envoi au tarif plafond (hypothèse de réservation : entrée ≤ 20 000 jetons, 4 000 en sortie), jamais en tâche
    /// de fond ; rapprochée de l'usage rapporté (« usage » Chat Completions). Refus : (0, {"error":{"message":…}}), rien n'est envoyé.
    public static func guardedPost(_ req: URLRequest, model: String, timeout: TimeInterval) -> (Int, Data) {
        let url: String = req.url?.absoluteString ?? ""
        let sp = BrainSpec(id: "api-" + model, label: model, kind: .chat, baseURL: url, model: model, keys: KeyChain([]), tags: [])
        let estIn: Int = min(20_000, TokenEst.of(String(decoding: req.httpBody ?? Data(), as: UTF8.self)))
        let bg: Bool = !isInteractive()
        let pf: Preflight = preflight(spec: sp, estIn: estIn, maxOut: 4000, lane: currentLane(background: bg))
        guard let tk = pf.ticket else {
            var why: String = "réservation impossible"
            if case .refused(let w) = pf { why = w }
            return (0, jsonData(["error": ["message": "Budget : " + why + " — rien n'est envoyé."]]))
        }
        let (st, data): (Int, Data) = syncPost(req, timeout: timeout)
        let u: [String: Any] = (parseJSON(data)?["usage"] as? [String: Any]) ?? [:]
        let uin: Int = (u["prompt_tokens"] as? Int) ?? 0, uout: Int = (u["completion_tokens"] as? Int) ?? 0
        if (200..<300).contains(st) {
            record(sp.id, inTok: uin, outTok: uout, cacheRead: 0, cacheWrite: 0, background: bg, spec: sp, ticket: tk, measured: uin + uout > 0)
        } else {
            abandon(tk, kind: (st == 401 || st == 403) ? .auth : (st == 402 ? .credit : (st == 404 ? .model : nil)), produced: false)
        }
        return (st, data)
    }
    public static func abandon(_ t: SpendTicket?, kind: ErrKind?, produced: Bool) {
        guard let t = t else { return }
        SpendPolicy.abandon(ledger: ledger(), ticket: t, kind: kind, produced: produced)
    }

    // MARK: - Interactif ou fond

    /// Posé par la boucle agent quand le run vient d'Ahadi (chat, voix) ; tout le reste est « fond ».
    public static func setInteractive(_ on: Bool) {
        if on { Thread.current.threadDictionary["nova.interactive"] = true }
        else { Thread.current.threadDictionary.removeObject(forKey: "nova.interactive") }
    }
    public static func isInteractive() -> Bool { (Thread.current.threadDictionary["nova.interactive"] as? Bool) == true }
    /// 30/10 (GO 1) : appels du BANC de qualité — comptés à part (« banc »), jamais dans les dépenses d'Ahadi ni dans le plafond du fond.
    public static func setBench(_ on: Bool) {
        if on { Thread.current.threadDictionary["nova.banc"] = true } else { Thread.current.threadDictionary.removeObject(forKey: "nova.banc") }
    }
    static func isBench() -> Bool { (Thread.current.threadDictionary["nova.banc"] as? Bool) == true }
    /// 30/10 (GO 4) : posé par BrainRunner quand le préfixe système part avec un cache d'1 h (écriture facturée au tarif 1 h).
    public static func noteCache1h() { Thread.current.threadDictionary["nova.cw1h"] = true }

    // MARK: - Compteurs

    static func dayKey(_ d: Date = Date()) -> String { let f = DateFormatter(); f.locale = Locale(identifier: "en_US_POSIX"); f.dateFormat = "yyyy-MM-dd"; return f.string(from: d) }
    static func monthKey(_ d: Date = Date()) -> String { String(dayKey(d).prefix(7)) }

    /// Compteur entier (micro-dollars) d'un objet JSON ; ancienne ligne sans compteur entier → reprise UNE fois depuis le champ USD.
    static func mic(_ o: [String: Any]?, _ usdKey: String, _ microKey: String) -> Micros {
        guard let o = o else { return 0 }
        if let n = o[microKey] as? NSNumber { return n.int64Value }
        return Money.micros(usd: (o[usdKey] as? NSNumber)?.doubleValue ?? 0)
    }

    /// Chiffre et compte un appel abouti. `ticket` (réservation d'avant envoi) est rapproché dans le grand livre ; `measured` = usage
    /// rapporté par le fournisseur (faux : jetons estimés par Nova, marqués « estime »). Gratuité vérifiée : rien n'est compté.
    /// Facturation inconnue : comptée au tarif plafond (jamais 0), marquée « facturation_inconnue ».
    public static func record(_ id: String, inTok: Int, outTok: Int, cacheRead: Int, cacheWrite: Int, background: Bool,
                              spec: BrainSpec? = nil, ticket: SpendTicket? = nil, measured: Bool = true) {
        let cw1h: Bool = (Thread.current.threadDictionary["nova.cw1h"] as? Bool) == true
        Thread.current.threadDictionary.removeObject(forKey: "nova.cw1h")
        let bk: PriceBook = book()
        let s: BrainSpec? = spec ?? Catalog.defaults().first(where: { $0.id == id })
        let b: Billing = ticket?.billing ?? s.map { bk.billing($0) } ?? Billing.unknownBilling("cerveau « \(id) » absent du catalogue")
        let u = Usage(input: inTok, cacheRead: cacheRead, cacheWrite5m: cw1h ? 0 : cacheWrite, cacheWrite1h: cw1h ? cacheWrite : 0, output: outTok)
        var c: Micros = bk.cost(b, usage: u)
        if let t = ticket { c = SpendPolicy.settle(ledger: ledger(), book: bk, ticket: t, usage: u, measured: measured) }
        if b.isVerifiedFree { return }
        var extra: [String: Int] = [:]
        if b.isUnknown { extra["facturation_inconnue"] = 1 }
        if !measured || u.isEmpty { extra["estime"] = 1 }
        addSpend(id, micros: c, inTok: inTok, outTok: outTok, cacheRead: cacheRead, background: background, extra: extra)
    }

    /// 31/10 : écriture commune d'une dépense déjà chiffrée (cerveaux du routeur).
    /// WP2 : cumuls en micro-dollars ENTIERS (champs *_micros) ; les champs *_usd sont recalculés depuis eux (jamais d'arrondi cumulé).
    /// `extra` : compteurs additionnels cumulés dans la ligne du cerveau (ex. in_audio, out_audio, estime).
    static func addSpend(_ id: String, micros c: Micros, inTok: Int, outTok: Int, cacheRead: Int, background: Bool, extra: [String: Int] = [:]) {
        // 31/10 : coût de la DEMANDE en cours (fil du chat) — plafond par demande et coût affiché sous la réponse.
        let tour: Micros = ((Thread.current.threadDictionary["nova.tour_micros"] as? NSNumber)?.int64Value ?? 0) + c
        Thread.current.threadDictionary["nova.tour_micros"] = NSNumber(value: tour)
        lock.lock()
        var o: [String: Any] = file.read(default: [String: Any]())
        let dk: String = dayKey(), mk: String = monthKey()
        var days: [String: Any] = (o["jours"] as? [String: Any]) ?? [:]
        var d: [String: Any] = (days[dk] as? [String: Any]) ?? [:]
        let side: String = isBench() ? "banc" : (background ? "fond" : "ahadi")
        let tot: Micros = mic(d, "total_usd", "total_micros") + c
        d["total_micros"] = tot; d["total_usd"] = Money.usd(tot)
        let sm: Micros = mic(d, side + "_usd", side + "_micros") + c
        d[side + "_micros"] = sm; d[side + "_usd"] = Money.usd(sm)
        d[side + "_appels"] = ((d[side + "_appels"] as? Int) ?? 0) + 1
        var per: [String: Any] = (d["cerveaux"] as? [String: Any]) ?? [:]
        var b: [String: Any] = (per[id] as? [String: Any]) ?? [:]
        b["appels"] = ((b["appels"] as? Int) ?? 0) + 1
        let bm: Micros = mic(b, "usd", "micros") + c
        b["micros"] = bm; b["usd"] = Money.usd(bm)
        b["in"] = ((b["in"] as? Int) ?? 0) + inTok
        b["out"] = ((b["out"] as? Int) ?? 0) + outTok
        b["cache_lu"] = ((b["cache_lu"] as? Int) ?? 0) + cacheRead
        for (k, v) in extra { b[k] = ((b[k] as? Int) ?? 0) + v }   // 31/10 (voix/mémoire/Live)
        per[id] = b; d["cerveaux"] = per; days[dk] = d
        // 40 jours glissants au plus
        if days.count > 40 { for k in days.keys.sorted().prefix(days.count - 40) { days.removeValue(forKey: k) } }
        o["jours"] = days
        var months: [String: Any] = (o["mois"] as? [String: Any]) ?? [:]
        var monthsM: [String: Any] = (o["mois_micros"] as? [String: Any]) ?? [:]
        let mPrev: Micros = (monthsM[mk] as? NSNumber)?.int64Value ?? Money.micros(usd: (months[mk] as? NSNumber)?.doubleValue ?? 0)
        let mTotalM: Micros = mPrev + c
        monthsM[mk] = mTotalM; o["mois_micros"] = monthsM
        let mTotal: Double = Money.usd(mTotalM)
        months[mk] = mTotal; o["mois"] = months
        // Alertes 80 % / 100 % : une seule fois par mois chacune.
        let budget: Double = monthBudget()
        var alerts: [String: Any] = (o["alertes"] as? [String: Any]) ?? [:]
        var fire: String? = nil
        if budget > 0 {
            if mTotal >= budget, alerts[mk + "-100"] == nil { alerts[mk + "-100"] = nowISO(); fire = "100" }
            else if mTotal >= budget * 0.8, alerts[mk + "-80"] == nil { alerts[mk + "-80"] = nowISO(); fire = "80" }
        }
        o["alertes"] = alerts
        file.write(o)
        lock.unlock()
        writeDiag()
        if let f = fire {
            let txt: String = f == "100"
                ? String(format: "Budget du mois atteint (%.2f $ sur %.0f $) : Nova n'utilise plus que des cerveaux à gratuité vérifiée ; au premier plan, une dérogation délibérée est demandée. Tu peux relever le budget dans Réglages.", mTotal, budget)
                : String(format: "80 %% du budget du mois consommé (%.2f $ sur %.0f $).", mTotal, budget)
            _ = BlackBox.record(["tool": "depense", "actor": "Nova", "ok": f != "100", "effect": "config", "why": txt, "result": "budget_" + f])
            NovaNotifier.send(source: "depense-llm", title: "Nova — dépense des cerveaux", body: txt, target: ["module": "reglages"], sound: false)
        }
    }

    /// Arrondi d'AFFICHAGE seulement (jamais appliqué à un cumul).
    static func round4(_ x: Double) -> Double { (x * 10000).rounded() / 10000 }

    // MARK: - Réglages (exposés, jamais réécrits par le code)

    static func settingUSD(_ k: String, _ def: Double) -> Double {
        let s = Settings().all()
        if let v = s[k] as? NSNumber { return v.doubleValue }
        return def
    }
    static func monthBudget() -> Double { settingUSD("budget_llm_mois_usd", 90) }
    static func bgDayCap() -> Double { settingUSD("budget_fond_jour_usd", 0.75) }   // 30/10 (GO 3) : 1,50 → 0,75 $ par jour pour le fond
    /// 31/10 (audit, 15,54 $ de bancs en une nuit) : plafond QUOTIDIEN de tous les bancs réunis (réglage « budget_banc_jour_usd », 2 $).
    static func benchDayCap() -> Double { settingUSD("budget_banc_jour_usd", 2.0) }
    /// Configuration recommandée (docs/BUDGET_V1.md) : enveloppe d'Ahadi 100–125 $/mois HORS abonnement [tiers] Max — affichée, jamais appliquée seule.
    public static let recommended: [String: Any] = [
        "budget_llm_mois_usd": ["min": 100, "max": 125, "conseil": 110, "note": "hors outils de développement (non facturés à Nova)"] as [String: Any],
        "budget_fond_jour_usd": 0.75, "budget_banc_jour_usd": 2.0, "voix_live_reserve_min": 10, "depense_reservations_v1": true,
        "garde_fournisseur": "garder aussi les plafonds de dépense côté fournisseur (console Meta, Baseten) quand ils existent",
    ]

    /// 31/10 : coût de la demande en cours sur CE fil (remis à zéro au début de chaque message).
    public static func turnReset() { Thread.current.threadDictionary["nova.tour_micros"] = NSNumber(value: Int64(0)) }
    public static func turnSpent() -> Double { Money.usd((Thread.current.threadDictionary["nova.tour_micros"] as? NSNumber)?.int64Value ?? 0) }

    /// 31/10 : dépense du banc aujourd'hui (disjoncteur du banc comparatif) et dépense du jour par cerveau.
    static func benchToday() -> (usd: Double, perBrain: [String: Double]) {
        lock.lock(); defer { lock.unlock() }
        let o: [String: Any] = file.read(default: [String: Any]())
        let d: [String: Any] = ((o["jours"] as? [String: Any])?[dayKey()] as? [String: Any]) ?? [:]
        var per: [String: Double] = [:]
        for (k, v) in (d["cerveaux"] as? [String: Any]) ?? [:] { per[k] = Money.usd(mic(v as? [String: Any], "usd", "micros")) }
        return (Money.usd(mic(d, "banc_usd", "banc_micros")), per)
    }

    static func spentMicros(_ now: Date = Date()) -> (month: Micros, dayBg: Micros, dayBench: Micros) {
        lock.lock(); defer { lock.unlock() }
        let o: [String: Any] = file.read(default: [String: Any]())
        let mk: String = monthKey(now)
        let m: Micros = ((o["mois_micros"] as? [String: Any])?[mk] as? NSNumber)?.int64Value
            ?? Money.micros(usd: ((o["mois"] as? [String: Any])?[mk] as? NSNumber)?.doubleValue ?? 0)
        let d: [String: Any]? = (o["jours"] as? [String: Any])?[dayKey(now)] as? [String: Any]
        return (m, mic(d, "fond_usd", "fond_micros"), mic(d, "banc_usd", "banc_micros"))
    }
    static func spent() -> (month: Double, dayBg: Double) {
        let m = spentMicros()
        return (Money.usd(m.month), Money.usd(m.dayBg))
    }

    // MARK: - Politique de chaîne (WP2 : résultat explicite, jamais la chaîne d'origine rétablie)

    /// État du budget pour une voie : engagé = max(grand livre, compteur JSON) ; dérogation active (premier plan / banc).
    static func state(lane: SpendLane, now: Date = Date()) -> SpendState {
        let c = caps()
        let sp = spentMicros(now)
        let led: CostLedger? = ledger(now: now)
        var month: Micros = sp.month
        var day: Micros = lane == .background ? sp.dayBg : (lane == .bench ? sp.dayBench : 0)
        var rem: Micros = 0
        if let l = led {
            let lm = l.committed(month: PeakWindows.monthKey(now)); if lm != Int64.max { month = max(month, lm) } else { month = Int64.max / 4 }
            if lane != .interactive { let ld = l.committed(day: PeakWindows.dayKey(now), lane: lane.ledgerLane); day = ld == Int64.max ? Int64.max / 4 : max(day, ld) }
            if lane != .background { rem = l.activeOverride(lane: lane.ledgerLane, now: now)?.remaining ?? 0 }
        }
        let dayCap: Micros = lane == .background ? c.dayBackground : (lane == .bench ? (c.dayBench ?? c.monthHard) : c.monthHard)
        return SpendState(monthCommitted: month, monthCap: c.monthHard, dayCommitted: day, dayCap: dayCap, overrideRemaining: rem)
    }

    /// Décide la chaîne d'un appel du routeur v1. `freeFallback` : un moteur local (gratuit vérifié) sera ajouté ensuite par le routeur.
    public static func decideChain(_ chain: [BrainSpec], all: [BrainSpec], usable: (String) -> Bool, lane: SpendLane, pinned: String?,
                                   estIn: Int, maxOut: Int, freeFallback: Bool) -> ChainDecision {
        let bk: PriceBook = book()
        return SpendPolicy.decide(chain: chain, all: all, usable: usable, lane: lane, pinned: pinned, state: state(lane: lane), book: bk, freeFallback: freeFallback,
                                  estimate: { (s: BrainSpec, b: Billing) -> Micros in SpendPolicy.estimate(book: bk, billing: b, estIn: estIn, maxOut: maxOut) })
    }

    /// Ancienne interface (gardée pour les autres branches) : rend la chaîne décidée — VIDE si bloquée, jamais la chaîne d'origine.
    @available(*, deprecated, message: "WP2 : utiliser decideChain (résultat explicite)")
    public static func shape(_ chain: [BrainSpec], all: [BrainSpec], usable: (String) -> Bool, background: Bool) -> (chain: [BrainSpec], note: String?) {
        switch decideChain(chain, all: all, usable: usable, lane: currentLane(background: background), pinned: nil, estIn: 0, maxOut: 0, freeFallback: false) {
        case .eligibleChain(let c, let n): return (c, n)
        case .blocked(let why): return ([], why)
        case .overrideRequired(let why, _): return ([], why)
        }
    }

    // MARK: - Dérogations (délibérées, bornées, expirantes, journalisées)

    /// Plafonds d'une dérogation : montant ≤ réglage « derogation_max_usd » (25 $ par défaut), durée 1 min – 24 h, motif obligatoire,
    /// voies premier plan et/ou banc seulement (jamais le fond). Journalisée dans la boîte noire et dans le grand livre.
    public static func grantOverride(usd: Double, minutes: Int, reason: String, lanes: Set<SpendLane>, actor: String = "Ahadi", now: Date = Date()) -> (id: String?, error: String?) {
        let maxUSD: Double = settingUSD("derogation_max_usd", 25)
        let why: String = reason.trimmingCharacters(in: .whitespacesAndNewlines)
        guard usd > 0, usd <= maxUSD else { return (nil, String(format: "montant hors bornes (0 < montant ≤ %.2f $, réglage derogation_max_usd)", maxUSD)) }
        guard minutes >= 1, minutes <= 1440 else { return (nil, "durée hors bornes (1 min à 24 h)") }
        guard why.count >= 3 else { return (nil, "motif obligatoire") }
        let ls: Set<Lane> = Set(lanes.filter { $0 != .background }.map { $0.ledgerLane })
        guard !ls.isEmpty else { return (nil, "voie interdite : une dérogation ne vaut jamais pour les tâches de fond") }
        guard let led = ledger(now: now) else { return (nil, "grand livre indisponible") }
        guard let id = led.grantOverride(max: Money.micros(usd: usd), until: now.addingTimeInterval(Double(minutes) * 60), lanes: ls, reason: why, actor: actor, now: now) else {
            return (nil, "écriture refusée")
        }
        _ = BlackBox.record(["tool": "depense_derogation", "actor": actor, "ok": true, "effect": "config",
                             "why": String(why.prefix(200)), "result": "dérogation \(id.prefix(8)) : \(String(format: "%.2f", usd)) $ pendant \(minutes) min (\(ls.map { $0.rawValue }.sorted().joined(separator: ",")))"])
        return (id, nil)
    }
    public static func revokeOverride(_ id: String, actor: String = "Ahadi") -> Bool {
        let ok: Bool = ledger()?.revokeOverride(id) ?? false
        _ = BlackBox.record(["tool": "depense_derogation", "actor": actor, "ok": ok, "effect": "config", "why": "révocation", "result": String(id.prefix(8))])
        return ok
    }

    // MARK: - Diagnostic

    public static func writeDiag() {
        lock.lock()
        let o: [String: Any] = file.read(default: [String: Any]())
        lock.unlock()
        let root: String = NSHomeDirectory() + "/spark-local/Nova2/releves/diag"
        let days: [String: Any] = (o["jours"] as? [String: Any]) ?? [:]
        var recent: [String: Any] = [:]
        for k in days.keys.sorted().suffix(10) { recent[k] = days[k] }
        let doc: [String: Any] = ["generated": nowISO(), "budget_mois_usd": monthBudget(), "plafond_fond_jour_usd": bgDayCap(), "plafond_banc_jour_usd": benchDayCap(),
                                  "mois": (o["mois"] as? [String: Any]) ?? [:], "jours": recent, "alertes": (o["alertes"] as? [String: Any]) ?? [:]]
        try? jsonData(doc).write(to: URL(fileURLWithPath: root + "/depenses.json"))
    }

    public static func summary() -> [String: Any] {
        let sp = spent()
        return ["mois_usd": round4(sp.month), "fond_jour_usd": round4(sp.dayBg), "budget_mois_usd": monthBudget(), "plafond_fond_jour_usd": bgDayCap()]
    }

    /// GET /api/depense : réglages en vigueur, configuration recommandée, engagé (grand livre), dérogations, facturation de chaque cerveau.
    public static func status(brains: [BrainSpec], now: Date = Date()) -> [String: Any] {
        let led: CostLedger? = ledger(now: now)
        let bk: PriceBook = book()
        var bills: [String: Any] = [:]
        for s in brains { bills[s.id] = bk.billing(s).describe }
        let ovs: [[String: Any]] = (led?.overrides(limit: 10) ?? []).map { (o: CostLedger.Override) -> [String: Any] in
            ["id": o.id, "max_usd": Money.usd(o.max), "utilise_usd": Money.usd(o.used), "expire": ISO8601DateFormatter().string(from: o.expires),
             "active": !o.revoked && now < o.expires && o.remaining > 0, "voies": o.lanes.map { $0.rawValue }.sorted(), "motif": o.reason, "par": o.actor]
        }
        let mk: String = PeakWindows.monthKey(now)
        var gl: [String: Any] = ["disponible": led != nil]
        if let l = led {
            gl["engage_mois_usd"] = Money.usd(l.committed(month: mk))
            gl["fond_jour_usd"] = Money.usd(l.committed(day: PeakWindows.dayKey(now), lane: .background))
            gl["banc_jour_usd"] = Money.usd(l.committed(day: PeakWindows.dayKey(now), lane: .bench))
        }
        return ["reglages": ["budget_llm_mois_usd": monthBudget(), "budget_fond_jour_usd": bgDayCap(), "budget_banc_jour_usd": benchDayCap(),
                             "depense_reservations_v1": reservationsOn, "derogation_max_usd": settingUSD("derogation_max_usd", 25)] as [String: Any],
                "recommande": recommended, "compteur_json": summary(),
                "grand_livre": gl,
                "derogations": ovs, "facturation": bills, "plafond_inconnu_usd_par_M": ["entree": Money.usd(bk.ceiling.inp), "sortie": Money.usd(bk.ceiling.out)]]
    }
}
