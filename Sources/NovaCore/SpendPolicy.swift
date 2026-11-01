import Foundation
import NovaFoundation

// WP2 — BUDGET EN ÉCHEC FERMÉ SUR LE CHEMIN EN SERVICE (v1, réglage routage_v2 = false).
//
// Avant (Feat_Depense.swift, LLMSpend.shape) : « paid(id) = price(id) != nil » — tout cerveau sans prix passait pour gratuit
// (spark-open, passerelles…) ; quand le filtrage vidait la chaîne, la chaîne
// D'ORIGINE était rétablie (cerveaux payants ou premium bloqués de retour) ; cumuls en Double arrondis à 4 décimales à chaque
// appel ; aucune réservation avant envoi (deux appels parallèles pouvaient dépenser la même marge).
//
// Ici, code pur (aucun réseau, aucune clé) testé par Tests/NovaCoreTests/WP2BudgetTests.swift :
// • Billing : verifiedFree (base nommée) · metered (prix VERSIONNÉ fournisseur/endpoint/modèle, provenance, date) · unknownBilling.
//   Inconnu ≠ gratuit : jamais choisi automatiquement ; choisi explicitement → réservé et soldé au tarif PLAFOND (prudent).
//   Crédits fournisseur (hackathon, « repi ») ≠ endpoint gratuit : facturation inconnue tant qu'aucun prix n'est versionné.
// • ChainDecision : eligibleChain / blocked(raison) / overrideRequired(raison, coût estimé) — jamais de chaîne d'origine rétablie.
// • Réservation atomique avant envoi dans le grand livre de la phase 2 (CostLedger, SQLite WAL, BEGIN IMMEDIATE), soldée avec
//   l'usage rapporté (mesuré) ; usage absent → réservation gardée ; usage seulement estimé → max(estimé, réservé).
// • Banc strict : le cerveau épinglé ou rien (aucune substitution, ni locale ni par relais).
// Prix : Config/brains.json (registre phase 2, vérifié le 31/10) d'abord ; à défaut la grille historique de Feat_Depense, reprise
// telle quelle avec sa provenance (aucun prix inventé) ; deux sources qui divergent → le coût le plus élevé est retenu.

public enum FreeBasis: String {
    case localEngine = "moteur_local"            // moteur sur le Mac (127.0.0.1), aucun fournisseur facturé
    case onDevice = "sur_appareil"               // réservé (aucun modèle sur l'appareil en version Meta)
    case flatSubscription = "abonnement_forfaitaire"   // CLI couvert par un abonnement (aucun coût par appel sur le budget API)
    case vendorFreeTier = "palier_gratuit_fournisseur"   // 01/11 : palier gratuit PUBLIÉ par le fournisseur (limites écrites, aucun prix par jeton)
}

/// Prix d'un cerveau, attaché au triplet fournisseur / endpoint (hôte) / modèle — pas seulement à l'id « amical » de Nova.
public struct PriceVersion {
    public var provider: String
    public var endpoint: String
    public var model: String
    public var novaId: String
    public var version: String
    public var rate: Rate?               // grille fixe (historique v1) ; nil = tarif du registre seulement
    public var registryId: String?       // entrée de Config/brains.json (calendrier, pointe, palier long gérés par BrainRegistry.cost)
    public var longContext: LongContext?
    public var verified: String?         // AAAA-MM-JJ ; nil = non vérifié (compté quand même)
    public var source: String
    public var conflict: String?
    public init(provider: String, endpoint: String, model: String, novaId: String, version: String, rate: Rate? = nil, registryId: String? = nil,
                longContext: LongContext? = nil, verified: String?, source: String, conflict: String? = nil) {
        self.provider = provider; self.endpoint = endpoint; self.model = model; self.novaId = novaId; self.version = version; self.rate = rate
        self.registryId = registryId; self.longContext = longContext; self.verified = verified; self.source = source; self.conflict = conflict
    }
}

public enum Billing {
    case verifiedFree(FreeBasis, provenance: String)
    case metered(PriceVersion)
    case unknownBilling(String)
    public var label: String {
        switch self { case .verifiedFree: return "verified_free"; case .metered: return "metered"; case .unknownBilling: return "unknown" }
    }
    public var isVerifiedFree: Bool { if case .verifiedFree = self { return true }; return false }
    public var isUnknown: Bool { if case .unknownBilling = self { return true }; return false }
    public var version: String? {
        switch self {
        case .verifiedFree(let b, _): return "gratuit:" + b.rawValue
        case .metered(let p): return p.version
        case .unknownBilling: return "inconnu"
        }
    }
    public var describe: [String: Any] {
        switch self {
        case .verifiedFree(let b, let p): return ["facturation": label, "base": b.rawValue, "provenance": p]
        case .metered(let p):
            var o: [String: Any] = ["facturation": label, "version": p.version, "fournisseur": p.provider, "endpoint": p.endpoint, "modele": p.model,
                                    "source": p.source, "verifie": p.verified ?? "non vérifié"]
            if let c = p.conflict { o["conflit"] = c }
            return o
        case .unknownBilling(let why): return ["facturation": label, "raison": why]
        }
    }
}

public struct PriceBook {
    public let registry: BrainRegistry?
    public let legacy: [PriceVersion]
    /// Tarif plafond (le plus cher connu, entrée et sortie séparément) : sert à réserver et solder une facturation inconnue.
    public let ceiling: Rate

    /// Hôte d'API attendu par fournisseur du registre : un cerveau dont l'endpoint diffère n'hérite pas du prix.
    public static let providerHosts: [String: String] = [
        "meta": "api.meta.ai",
        "baseten": "inference.baseten.co",   // 01/11 : tarif Muse Spark Open relevé sur la page Baseten du compte
    ]
    /// 01/11 : paliers gratuits PUBLIÉS (limites écrites par le fournisseur). Gratuit tant que le compte reste au palier gratuit :
    /// la page publique ne permet pas de vérifier le palier du compte (voir docs/ROUTAGE_META.md §4).
    public static let vendorFreeTier: [String: String] = [:]
    /// Cerveaux payés par des CRÉDITS de fournisseur : consommés, donc pas gratuits ; aucun prix versionné → facturation inconnue.
    public static let creditFunded: [String: String] = [:]

    /// Données de la politique, injectables (tests sur un registre fictif) ; défauts = valeurs de la version Meta ci-dessus.
    public let hosts: [String: String]
    public let freeTier: [String: String]
    public let credits: [String: String]
    public let premium: Set<String>

    public init(registry: BrainRegistry?, legacy: [PriceVersion] = PriceBook.legacyV1, hosts: [String: String] = PriceBook.providerHosts,
                freeTier: [String: String] = PriceBook.vendorFreeTier, credits: [String: String] = PriceBook.creditFunded,
                premium: Set<String> = SpendPolicy.premium) {
        self.registry = registry; self.legacy = legacy
        self.hosts = hosts; self.freeTier = freeTier; self.credits = credits; self.premium = premium
        var ci: Micros = 0, co: Micros = 0, cr: Micros = 0, c5: Micros = 0, c1: Micros = 0
        func see(_ r: Rate?) {
            guard let r = r else { return }
            ci = max(ci, r.inp); co = max(co, r.out); cr = max(cr, r.cacheRead ?? 0); c5 = max(c5, r.cacheWrite5m ?? 0); c1 = max(c1, r.cacheWrite1h ?? 0)
        }
        for p in legacy { see(p.rate) }
        for e in registry?.brains.values.map({ $0 }) ?? [] { see(e.standard); see(e.peak); see(e.offpeak); for s in e.schedule { see(s.rate) } }
        // Plancher de sécurité (hypothèse de réservation de Nova, pas un prix) : jamais un plafond nul — une facturation inconnue
        // n'est jamais comptée 0. Cache lu/écrit : le plus cher connu, au moins le tarif d'entrée plafond.
        let inp: Micros = max(ci, 10 * Money.perUSD)
        ceiling = Rate(inp: inp, out: max(co, 50 * Money.perUSD), cacheRead: max(cr, inp), cacheWrite5m: max(c5, inp), cacheWrite1h: max(c1, c5, inp))
    }

    static func host(_ url: String) -> String { URL(string: url)?.host?.lowercased() ?? "" }

    public func billing(_ s: BrainSpec) -> Billing {
        if s.kind == .local { return .verifiedFree(.localEngine, provenance: "moteur local sur le Mac (\(PriceBook.host(s.baseURL))) : aucun fournisseur facturé") }
        if s.baseURL.hasPrefix("cli://muse") { return .verifiedFree(.flatSubscription, provenance: "CLI Muse Code couvert par l'abonnement : aucun coût par appel sur le budget API") }
        if let why = credits[s.id] { return .unknownBilling(why) }
        if let why = freeTier[s.id] { return .verifiedFree(.vendorFreeTier, provenance: why) }
        let h: String = PriceBook.host(s.baseURL)
        var reg: PriceVersion? = nil
        if let r = registry, let e = r.brains.values.first(where: { ($0.novaSpec == s.id || $0.id == s.id) && $0.apiModel == s.model }),   // v2 renomme parfois le cerveau en id du registre
           let ph = hosts[e.provider], ph == h {
            let zero: Bool = e.standard.map { $0.inp == 0 && $0.out == 0 } ?? false   // tarif nul publié ≠ gratuité vérifiée
            if !zero && (e.standard != nil || e.peakPriced) {
                reg = PriceVersion(provider: e.provider, endpoint: h, model: e.apiModel, novaId: s.id, version: "brains.json#\(e.id)@\(e.verified ?? "non-verifie")",
                                   registryId: e.id, verified: e.verified, source: "Config/brains.json")
            }
        }
        let leg: PriceVersion? = legacy.first { $0.novaId == s.id && $0.endpoint == h && $0.model == s.model }
        if var p = reg {
            if let l = leg {
                p.rate = l.rate; p.longContext = l.longContext
                p.conflict = "deux grilles (\(p.version) et \(l.version)) : le coût le plus élevé des deux est retenu"
            }
            return .metered(p)
        }
        if let l = leg { return .metered(l) }
        return .unknownBilling("aucun prix versionné pour \(h.isEmpty ? s.baseURL : h) / \(s.model) (cerveau \(s.id)) — facturation inconnue, jamais gratuite")
    }

    func fixedCost(_ r: Rate, _ lc: LongContext?, _ u: Usage) -> Micros {
        var mi: Int64 = 1000, mo: Int64 = 1000, mc: Int64 = 1000
        if let l = lc, u.promptTokens > l.thresholdInputTokens { mi = l.inMilli; mo = l.outMilli; mc = l.cacheMilli }
        let div: Int64 = 1_000_000 * 1000
        func term(_ tok: Int, _ price: Micros, _ mult: Int64) -> Micros { Money.mulDivCeil(Int64(tok), price * mult, div) }
        var c: Micros = term(u.inputTokens, r.inp, mi) + term(u.outputTokens, r.out, mo)
        c += term(u.cacheRead, r.cacheRead ?? r.inp, mc)
        c += term(u.cacheWrite5m, r.cacheWrite5m ?? r.inp, mc)
        c += term(u.cacheWrite1h, r.cacheWrite1h ?? r.cacheWrite5m ?? r.inp, mc)
        return c
    }
    public func ceilingCost(_ u: Usage) -> Micros { fixedCost(ceiling, nil, u) }

    /// Coût en micro-dollars entiers, arrondi au supérieur une seule fois par appel (jamais de cumul arrondi).
    public func cost(_ b: Billing, usage u: Usage, at d: Date = Date()) -> Micros {
        switch b {
        case .verifiedFree: return 0
        case .unknownBilling: return ceilingCost(u)
        case .metered(let p):
            var c: Micros = 0
            if let rid = p.registryId {
                guard let r = registry, let x = r.cost(rid, usage: u, at: d) else { return ceilingCost(u) }   // registre illisible : prudent
                c = x
            }
            if let r = p.rate { c = max(c, fixedCost(r, p.longContext, u)) }
            return c
        }
    }

    // MARK: Grille historique v1 (Feat_Depense.price au 31/10/2026), attachée à l'endpoint et au modèle du catalogue (Brains.swift).
    // Reprise TELLE QUELLE avec sa provenance ; « verified » = date écrite dans le commentaire d'origine, nil quand il disait
    // « estimation ». Aucun prix nouveau ici. glm-flash n'y figure plus : l'ancien « 0 » n'était pas une gratuité vérifiée
    // (le registre publie 0,15 / 0,50 $).

    static func usd(_ i: Double, _ o: Double, cr: Double? = nil, cw: Double? = nil, cw1h: Double? = nil) -> Rate {
        Rate(inp: Money.micros(usd: i), out: Money.micros(usd: o), cacheRead: cr.map { Money.micros(usd: $0) },
             cacheWrite5m: cw.map { Money.micros(usd: $0) }, cacheWrite1h: (cw1h ?? cw.map { $0 * 1.6 }).map { Money.micros(usd: $0) })
    }
    static func v1(_ id: String, _ prov: String, _ host: String, _ model: String, _ r: Rate, verified: String?, note: String, lc: LongContext? = nil) -> PriceVersion {
        PriceVersion(provider: prov, endpoint: host, model: model, novaId: id, version: "feat_depense-v1#\(id)@\(verified ?? "non-verifie")", rate: r,
                     longContext: lc, verified: verified, source: "Feat_Depense.price (grille historique) — " + note)
    }
    public static let legacyV1: [PriceVersion] = {
        let meta: String = "api.meta.ai"
        return [
            v1("wonder-1.0", "meta", meta, "muse-wonder-1.0", usd(4.0, 20.0), verified: "2026-10-31", note: "grille Meta publiée"),
            v1("spark-1.3", "meta", meta, "muse-spark-1.3", usd(1.25, 4.25), verified: "2026-10-31", note: "grille Meta publiée"),
            v1("spark-1.2", "meta", meta, "muse-spark-1.2", usd(1.25, 4.25), verified: "2026-10-31", note: "grille Meta publiée"),
            v1("spark-1.1", "meta", meta, "muse-spark-1.1", usd(1.25, 4.25), verified: "2026-10-31", note: "grille Meta publiée"),
            v1("spark-1.3-contributor", "meta", meta, "muse-spark-1.3-contributor", usd(0.10, 0.20), verified: "2026-10-31", note: "grille Meta publiée"),
            v1("spark-1.2-contributor", "meta", meta, "muse-spark-1.2-contributor", usd(0.10, 0.20), verified: "2026-10-31", note: "grille Meta publiée"),
        ]
    }()
}

// MARK: - Voies, décision de chaîne, réservation

public enum SpendLane: String {
    case interactive, background, bench
    public var ledgerLane: Lane { switch self { case .interactive: return .foreground; case .background: return .background; case .bench: return .bench } }
}

public enum ChainDecision {
    case eligibleChain([BrainSpec], note: String?)
    case blocked(String)
    case overrideRequired(String, estimatedCost: Micros)
    public var chain: [BrainSpec] { if case .eligibleChain(let c, _) = self { return c }; return [] }
}

/// État du budget vu par la décision (le grand livre le fournit ; les tests le simulent).
public struct SpendState {
    public var monthCommitted: Micros, monthCap: Micros
    public var dayCommitted: Micros, dayCap: Micros       // voie fond ou banc ; premier plan : dayCap = monthCap
    public var overrideRemaining: Micros
    public init(monthCommitted: Micros = 0, monthCap: Micros, dayCommitted: Micros = 0, dayCap: Micros, overrideRemaining: Micros = 0) {
        self.monthCommitted = monthCommitted; self.monthCap = monthCap; self.dayCommitted = dayCommitted; self.dayCap = dayCap; self.overrideRemaining = overrideRemaining
    }
}

public struct SpendTicket {
    public let id: String?          // nil = gratuité vérifiée (rien à réserver) ou réservations coupées
    public let billing: Billing
    public let lane: SpendLane
    public let estimate: Micros
    public let brain: String
}
public enum Preflight {
    case go(SpendTicket)
    case refused(String)
    public var ticket: SpendTicket? { if case .go(let t) = self { return t }; return nil }
}

public enum SpendPolicy {
    /// Cerveaux réservés aux échanges avec Ahadi (jamais en tâche de fond) — même liste que LLMSpend.premium.
    public static let premium: Set<String> = ["wonder-1.0"]

    static func overReason(_ st: SpendState, lane: SpendLane) -> String? {
        if st.monthCap <= 0 { return "budget du mois à 0 $ (réglage budget_llm_mois_usd) : aucun cerveau payant" }
        if st.monthCommitted >= st.monthCap { return "budget du mois atteint (\(Money.format(st.monthCommitted)) engagés sur \(Money.format(st.monthCap)))" }
        if lane != .interactive && st.dayCommitted >= st.dayCap {
            return lane == .bench ? "plafond du jour des bancs atteint (\(Money.format(st.dayCommitted)) sur \(Money.format(st.dayCap)))"
                                  : "plafond du jour des tâches de fond atteint (\(Money.format(st.dayCommitted)) sur \(Money.format(st.dayCap)))"
        }
        return nil
    }

    /// Décision explicite sur la chaîne d'un appel. Jamais la chaîne d'origine rétablie : chaîne vide après filtrage = blocked ou
    /// overrideRequired (sauf `freeFallback` : un moteur gratuit vérifié sera ajouté par le routeur — chaîne vide rendue telle quelle).
    public static func decide(chain: [BrainSpec], all: [BrainSpec], usable: (String) -> Bool, lane: SpendLane, pinned: String?,
                              state st: SpendState, book: PriceBook, freeFallback: Bool = false,
                              estimate: (BrainSpec, Billing) -> Micros) -> ChainDecision {
        if chain.isEmpty { return .eligibleChain([], note: nil) }
        let bill: [String: Billing] = Dictionary((chain + all).map { ($0.id, book.billing($0)) }, uniquingKeysWith: { a, _ in a })
        func b(_ s: BrainSpec) -> Billing { bill[s.id] ?? book.billing(s) }
        let over: String? = overReason(st, lane: lane)
        let overrideOK: Bool = over != nil && lane != .background && st.overrideRemaining > 0
        // Banc strict : le cerveau épinglé, sous son nom, ou rien.
        if lane == .bench, let p = pinned {
            guard let s = chain.first(where: { $0.id == p }) else {
                return .blocked("Banc strict : « \(p) » n'est pas dans la chaîne (indisponible, coupé ou sans clé) — aucune substitution par un autre cerveau.")
            }
            if let why = over, !b(s).isVerifiedFree, !overrideOK {
                return .overrideRequired("Banc strict : \(why) — « \(p) » n'est remplacé par aucun autre cerveau ; rien n'est envoyé sans dérogation.", estimatedCost: estimate(s, b(s)))
            }
            return .eligibleChain([s], note: (over != nil && overrideOK) ? "banc : dérogation active" : nil)
        }
        var notes: [String] = []
        // Facturation inconnue : jamais choisie automatiquement ; épinglée au premier plan seulement (réservée au tarif plafond).
        let dropped: [String] = chain.filter { b($0).isUnknown && !($0.id == pinned && lane != .background) }.map { $0.id }
        var out: [BrainSpec] = chain.filter { !dropped.contains($0.id) }
        if !dropped.isEmpty { notes.append("facturation inconnue écartée (≠ gratuit) : " + dropped.joined(separator: ", ")) }
        if let why = over, !overrideOK {
            let before: [BrainSpec] = out
            out = out.filter { b($0).isVerifiedFree }
            notes.append(why + " : cerveaux à gratuité vérifiée seulement")
            if out.isEmpty && !freeFallback {
                if lane == .background {
                    return .blocked("Tâche de fond non envoyée : \(why), et aucun cerveau à gratuité vérifiée dans la chaîne. Rien n'est rétabli ; elle sera reprise quand le plafond le permettra.")
                }
                let target: BrainSpec? = before.first(where: { $0.id == pinned }) ?? before.first ?? chain.first
                return .overrideRequired("\(why) : aucun cerveau à gratuité vérifiée disponible. Rien n'est envoyé ; il faut une dérogation délibérée (montant, durée, motif) ou relever le budget dans Réglages.",
                                         estimatedCost: target.map { estimate($0, b($0)) } ?? 0)
            }
        } else if lane == .background {
            // Fond : jamais premium (Wonder) — Spark en tête.
            out = out.filter { !book.premium.contains($0.id) }
            if out.count != chain.count || out.first?.id != chain.first?.id { notes.append("tâche de fond : cerveau économique") }
        }
        if over != nil && overrideOK { notes.append("plafond dépassé : dérogation active (reste \(Money.format(st.overrideRemaining)))") }
        if out.isEmpty && !freeFallback {
            return .blocked("Aucun cerveau éligible : \(notes.joined(separator: " ; ")) — échec fermé, la chaîne d'origine n'est pas rétablie.")
        }
        return .eligibleChain(out, note: notes.isEmpty ? nil : notes.joined(separator: " ; "))
    }

    /// Estimation prudente de `calls` appels : chaque suite relit l'entrée et la sortie déjà produite (entrée + k × sortie max).
    public static func estimate(book: PriceBook, billing: Billing, estIn: Int, maxOut: Int, calls: Int = 1, at: Date = Date()) -> Micros {
        var tot: Micros = 0
        for k in 0..<max(1, calls) { tot += book.cost(billing, usage: Usage(input: max(0, estIn) + k * max(0, maxOut), output: max(0, maxOut)), at: at) }
        return tot
    }

    /// Réserve AVANT l'envoi. Gratuité vérifiée : rien à réserver. Grand livre absent : refus (aucun envoi payant).
    public static func preflight(ledger: CostLedger?, book: PriceBook, spec s: BrainSpec, estIn: Int, maxOut: Int, calls: Int = 1, lane: SpendLane,
                                 caps: CostLedger.Caps, floorMonth: Micros = 0, floorDay: Micros = 0, overrideId: String? = nil,
                                 task: String? = nil, reserveEnabled: Bool = true, now: Date = Date()) -> Preflight {
        let b: Billing = book.billing(s)
        let est: Micros = b.isVerifiedFree ? 0 : estimate(book: book, billing: b, estIn: estIn, maxOut: maxOut, calls: calls, at: now)
        if b.isUnknown && lane == .background {   // même règle que decide() : une facturation inconnue n'est jamais engagée par le fond
            return .refused("\(s.label) : facturation inconnue — jamais en tâche de fond (aucun prix versionné)")
        }
        if b.isVerifiedFree || !reserveEnabled { return .go(SpendTicket(id: nil, billing: b, lane: lane, estimate: est, brain: s.id)) }
        guard let led = ledger else { return .refused("\(s.label) : grand livre des coûts indisponible — aucun envoi payant") }
        let tk: String = task ?? ("v1-" + String(UUID().uuidString.prefix(8)).lowercased())
        switch led.reserve(task: tk, lane: lane.ledgerLane, brain: s.id, profile: "v1-" + lane.rawValue, dataClass: .personal, estimate: est, caps: caps, now: now,
                           floorMonth: floorMonth, floorDay: floorDay, overrideId: lane == .background ? nil : overrideId,
                           billing: b.label, priceVersion: b.version) {
        case .reserved(let id): return .go(SpendTicket(id: id, billing: b, lane: lane, estimate: est, brain: s.id))
        case .refused(let why): return .refused("\(s.label) : \(why)")
        }
    }

    /// Rapprochement après un appel abouti. Mesuré → coût réel ; usage absent → réservation gardée ; seulement estimé → le plus
    /// grand de l'estimé et du réservé (jamais sous-compté). Rend le coût retenu pour le compteur affiché.
    @discardableResult
    public static func settle(ledger: CostLedger?, book: PriceBook, ticket t: SpendTicket, usage u: Usage, measured: Bool, now: Date = Date()) -> Micros {
        let c: Micros = book.cost(t.billing, usage: u, at: now)
        guard let id = t.id, let led = ledger else { return c }
        if u.isEmpty { led.settle(id, usage: nil, cost: nil, now: now); return t.estimate }
        if measured { led.settle(id, usage: u, cost: c, now: now, measure: "measured"); return c }
        if c > t.estimate { led.settle(id, usage: u, cost: c, now: now, measure: "estimated"); return c }
        led.settle(id, usage: nil, cost: nil, now: now)
        return t.estimate
    }

    /// Échec, annulation, délai : libérée SEULEMENT si le fournisseur a refusé avant traitement (clé, crédit, modèle) sans rien produire ;
    /// sinon gardée (une requête annulée ou expirée a pu être facturée).
    public static func abandon(ledger: CostLedger?, ticket t: SpendTicket, kind: ErrKind?, produced: Bool) {
        guard let id = t.id, let led = ledger else { return }
        if let k = kind, !produced, k == .auth || k == .credit || k == .model { led.release(id, reason: "refus du fournisseur avant traitement : \(k.rawValue)") }
        else { led.settle(id, usage: nil, cost: nil) }
    }
}
