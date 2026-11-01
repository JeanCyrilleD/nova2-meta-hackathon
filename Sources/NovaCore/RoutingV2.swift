import Foundation
import NovaFoundation

// PHASE 2 — branchement du registre, de la politique de données et du grand livre dans Router.chat.
// Interrupteur : réglage « routage_v2 » (settings.json), FAUX par défaut → Router.chat se comporte exactement comme avant.
// Vrai : la chaîne de cerveaux vient du profil (Config/brains.json), filtrée par la classe de données (Config/provider_terms.json),
// chaque appel est réservé atomiquement dans couts_v2.sqlite avant l'envoi, soldé après ; aucun moteur local (règle 6) ;
// tout refus = échec fermé avec message clair. Voir docs/ROUTAGE_V2.md.

public enum RoutingV2 {
    public static var enabled: Bool { Settings().get("routage_v2", false) }

    /// Cache du registre et du grand livre : un seul objet, chaque champ lu/écrit sous son verrou (pas de nonisolated(unsafe)).
    final class Cache: @unchecked Sendable {
        let lock = NSLock()
        var registry: BrainRegistry? = nil
        var ledger: CostLedger? = nil
    }
    static let cache = Cache()

    public static func registry() -> BrainRegistry? {
        cache.lock.lock(); defer { cache.lock.unlock() }
        if let r = cache.registry { return r }
        cache.registry = BrainRegistry.loadDefault()
        return cache.registry
    }
    /// Relit Config/*.json (après une mise à jour des prix ou des conditions).
    public static func reload() { cache.lock.lock(); cache.registry = nil; cache.lock.unlock() }
    public static func ledger() -> CostLedger? {
        cache.lock.lock(); defer { cache.lock.unlock() }
        if let l = cache.ledger { return l }
        cache.ledger = CostLedger(path: Paths.file("couts_v2.sqlite").path)
        return cache.ledger
    }

    // MARK: - Contexte de la demande (fil courant, même mécanisme que LLMSpend.setInteractive)

    /// Étiquette les éléments d'entrée de la demande en cours (classe de chacun : "public", "personal", "sci_internal", "vault").
    /// Sans étiquette, la demande est « personal » (brief 2.3).
    public static func setContext(items: [String?]? = nil, profile: String? = nil, task: String? = nil, urgent: Bool? = nil,
                                  touchID: Bool = false, vaultProvider: String? = nil) {
        let td = Thread.current.threadDictionary
        if let i = items { td["nova.v2.items"] = i.map { $0 ?? "" } }
        if let p = profile { td["nova.v2.profile"] = p }
        if let t = task { td["nova.v2.task"] = t }
        if let u = urgent { td["nova.v2.urgent"] = u }
        td["nova.v2.touchid"] = touchID
        if let v = vaultProvider { td["nova.v2.vault"] = v } else { td.removeObject(forKey: "nova.v2.vault") }
    }
    public static func clearContext() {
        for k in ["nova.v2.items", "nova.v2.profile", "nova.v2.task", "nova.v2.urgent", "nova.v2.touchid", "nova.v2.vault"] {
            Thread.current.threadDictionary.removeObject(forKey: k)
        }
    }
    static func ctxItems() -> [String?] {
        guard let a = Thread.current.threadDictionary["nova.v2.items"] as? [String] else { return [nil] }
        return a.map { $0.isEmpty ? nil : $0 }
    }

    /// Profil par défaut d'un mode historique du routeur (si l'appelant n'a pas posé de profil).
    /// bulk : bulk_public seulement si TOUTE l'entrée est étiquetée publique ; sinon triage (cerveaux autorisés en personal).
    public static func profileFor(mode: String, cls: DataClass) -> String {
        switch mode {
        case "deep": return "deep"
        case "voice": return "reflex"
        case "bulk": return cls == .publicData ? "bulk_public" : "triage"
        default: return "main"
        }
    }

    /// Correspondance cerveau du registre → id de cerveau Nova à réutiliser (même id si le modèle est inchangé ; sinon id du registre,
    /// pour que deux modèles d'un même fournisseur ne se confondent pas dans la chaîne).
    static func specId(_ e: BrainEntry, base: BrainSpec) -> String { base.model == e.apiModel ? base.id : e.id }

    public struct Prepared {
        public var chain: [BrainSpec]
        public var byspec: [String: (brain: String, cand: RouteCandidate)]
        public var cls: DataClass
        public var profile: String
        public var task: String
        public var lane: Lane
        public var disclosure: String
        public var notes: [String]
    }
    public enum Outcome { case ok(Prepared); case blocked(String) }

    /// Construit la chaîne v2 d'un appel. Aucune clé n'est lue ici (résolution par le KeyStore du routeur, comme avant).
    static func prepare(router: Router, mode: String, preferred: String?, estIn: Int, maxOut: Int, background: Bool, now: Date = Date()) -> Outcome {
        guard let reg = registry() else { return .blocked("Routage v2 : Config/brains.json ou Config/provider_terms.json illisible — aucun envoi. Coupe « routage_v2 » ou corrige la configuration.") }
        guard let led = ledger() else { return .blocked("Routage v2 : grand livre couts_v2.sqlite inaccessible — aucun envoi.") }
        let td = Thread.current.threadDictionary
        let items: [String?] = ctxItems()
        let cls0: DataClass = DataClass.resolve(items)
        let profile: String = (td["nova.v2.profile"] as? String) ?? profileFor(mode: mode, cls: cls0)
        let task: String = (td["nova.v2.task"] as? String) ?? ("chat-" + String(UUID().uuidString.prefix(8)).lowercased())
        let lane: Lane = background ? .background : .foreground
        let ctx = PolicyContext(now: now, sciPolicyConfirmed: Settings().get("sciPolicyConfirmed", false),
                                touchIDConfirmed: (td["nova.v2.touchid"] as? Bool) ?? false, vaultProvider: td["nova.v2.vault"] as? String)
        // Un cerveau épinglé (id Nova) est traduit en id du registre ; il passe les MÊMES contraintes que les autres.
        var pinned: String? = nil
        if let p = preferred, !p.isEmpty, p != "auto" {
            pinned = reg.brains.values.first(where: { $0.novaSpec == p || $0.id == p })?.id
        }
        let req = RouteRequest(profile: profile, items: items, lane: lane, estInputTokens: estIn, maxOutputTokens: maxOut,
                               urgent: (td["nova.v2.urgent"] as? Bool) ?? !background, preferred: pinned)
        let up: (String) -> Bool = { (id: String) -> Bool in
            guard let e = reg.brains[id], let ns = e.novaSpec, let base = router.brains.first(where: { $0.id == ns }) else { return false }
            _ = base
            // Coupure « Cerveaux actifs » respectée, sauf pour le cerveau épinglé à la main (même règle que plan()).
            return id == pinned ? router.usableIgnoringOff(ns) : router.usable(ns)
        }
        let plan: RoutePlan = RoutePlanner.plan(req, reg: reg, ctx: ctx, budget: led.budgetView(task: task, lane: lane, now: now), isUp: up)
        switch plan {
        case .blocked(_, let why, _): return .blocked(why)
        case .queued(_, let why): return .blocked(why)
        case .ok(let cls, let cands, let notes):
            var chain: [BrainSpec] = []
            var map: [String: (brain: String, cand: RouteCandidate)] = [:]
            for c in cands {
                guard let e = reg.brains[c.brainId], let ns = e.novaSpec, var s = router.brains.first(where: { $0.id == ns }) else { continue }
                let sid: String = specId(e, base: s)
                if map[sid] != nil { continue }
                s.id = sid; s.model = e.apiModel
                chain.append(s); map[sid] = (brain: e.id, cand: c)
            }
            if chain.isEmpty { return .blocked("Routage v2 : aucun cerveau du profil « \(profile) » n'est installé dans Nova — échec fermé.") }
            let hosts: String = Array(Set(chain.map { URL(string: $0.baseURL)?.host ?? $0.baseURL })).sorted().joined(separator: ", ")
            let maxEst: Micros = cands.map { $0.estimate }.max() ?? 0
            let disc: String = "Sortie du Mac : données « \(cls.rawValue) » → \(hosts) · profil \(profile) · coût estimé ≤ \(Money.format(maxEst))"
            return .ok(Prepared(chain: chain, byspec: map, cls: cls, profile: profile, task: task, lane: lane, disclosure: disc, notes: notes))
        }
    }

    /// Réserve juste avant l'envoi à `specId`. Facteur d'appels : suites automatiques (≤ 2) et repli protocole texte (1).
    static func reserve(_ p: Prepared, specId: String, estIn: Int, maxOut: Int, calls: Int, now: Date = Date()) -> CostLedger.Reservation {
        guard let reg = registry(), let led = ledger(), let m = p.byspec[specId] else { return .refused("routage v2 : cerveau hors plan") }
        guard let one = reg.cost(m.brain, usage: Usage(input: estIn, output: maxOut), at: now, batch: false /* envoi synchrone : l'API Batch n'est pas encore branchée → plein tarif */) else { return .refused("prix illisible") }
        let est: Micros = one * Int64(max(1, calls))
        return led.reserve(task: p.task, lane: p.lane, brain: m.brain, profile: p.profile, dataClass: p.cls, estimate: est, caps: CostLedger.Caps(reg), now: now)
    }

    /// Solde un appel abouti. Aucun usage rapporté → réservation gardée. Écriture de cache comptée au tarif 1 h (prudent).
    static func settle(_ resId: String, _ p: Prepared, specId: String, inTok: Int, outTok: Int, cacheRead: Int, cacheWrite: Int, now: Date = Date()) {
        guard let reg = registry(), let led = ledger(), let m = p.byspec[specId] else { return }
        let u = Usage(input: inTok, cacheRead: cacheRead, cacheWrite1h: cacheWrite, output: outTok)
        led.settle(resId, usage: u.isEmpty ? nil : u, cost: reg.cost(m.brain, usage: u, at: now, batch: false /* envoi synchrone : l'API Batch n'est pas encore branchée → plein tarif */), fallbacks: max(0, p.chain.firstIndex(where: { $0.id == specId }) ?? 0))
        alertIfNeeded(reg, led, now: now)
    }

    /// Échec : la réservation n'est libérée que si le fournisseur a refusé AVANT traitement (clé, crédit, modèle) et que rien n'a été produit.
    static func failed(_ resId: String, kind: ErrKind?, produced: Bool) {
        guard let led = ledger() else { return }
        if let k = kind, !produced, k == .auth || k == .credit || k == .model { led.release(resId, reason: "refus du fournisseur avant traitement : \(k.rawValue)") }
        else { led.settle(resId, usage: nil, cost: nil) }
    }

    static func alertIfNeeded(_ reg: BrainRegistry, _ led: CostLedger, now: Date) {
        let crossed: [Int] = led.newlyCrossedAlerts(thresholdsPct: reg.alertThresholdsPct, cap: reg.monthlyHardCap, now: now)
        guard let p = crossed.last else { return }
        let spent: Micros = led.committed(month: PeakWindows.monthKey(now))
        let txt: String = "\(p) % du plafond du mois engagé (\(Money.format(spent)) sur \(Money.format(reg.monthlyHardCap)), réservations comprises)."
        _ = BlackBox.record(["tool": "depense_v2", "actor": "Nova", "ok": true, "effect": "config", "why": txt, "result": "alerte_\(p)"])
        NovaNotifier.send(source: "depense-v2", title: "Nova — budget des cerveaux", body: txt, target: ["module": "reglages"], sound: false)
    }

    /// État servi au diagnostic (aucun contenu, aucune clé).
    public static func status(now: Date = Date()) -> [String: Any] {
        guard let reg = registry() else { return ["enabled": enabled, "config": "illisible"] }
        let led = ledger()
        let mk: String = PeakWindows.monthKey(now)
        return ["enabled": enabled, "config": "ok",
                "month_committed_usd": Money.usd(led?.committed(month: mk) ?? 0), "monthly_hard_cap_usd": Money.usd(reg.monthlyHardCap),
                "personal_eligible": DataPolicy.eligible(.personal, reg: reg, ctx: PolicyContext(now: now)),
                "public_eligible": DataPolicy.eligible(.publicData, reg: reg, ctx: PolicyContext(now: now)),
                "stale_prices_over_30_days": reg.stalePrices(now: now), "peak_now": reg.peakWindows.isPeak(now)]
    }
}
