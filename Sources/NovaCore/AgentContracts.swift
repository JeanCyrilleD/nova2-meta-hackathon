import Foundation

// PHASE 3 (31/10) — CONTRATS NEUTRES entre le moteur d'agents v2 (AgentsV2.swift) et la Phase 2
// (profils de routage, classes de données, grand livre de coûts — branche phase-2, développée en parallèle).
// Ce fichier ne réimplémente NI le budget NI le routage : il déclare seulement ce dont les agents ont besoin.
//
// ÉTAT DU BRANCHEMENT (intégration du 31/10, branche integration/2026-10-31) :
//   1. `AgentDataClass` = typealias de `DataClass` (Phase 2, BrainRegistry.swift ; + `strictest` ci-dessous).
//      `AgentRoutingProfile` reste une énumération ici : la Phase 2 n'expose pas d'énumération de profils (ses profils
//      sont des chaînes lues dans Config/brains.json) ; les valeurs brutes sont celles du brief, donc
//      `AgentRoutingProfile.rawValue` est directement le nom de profil Phase 2.
//   2. `LedgerCostGate` (en bas de ce fichier) : adaptateur vers le grand livre Phase 2 (CostLedger, couts_v2.sqlite) —
//      réservation atomique BEGIN IMMEDIATE contre mois / jour (voie « fond ») / tâche, plafonds de Config/brains.json.
//      Solde : le moteur ne rapporte qu'un coût, sans jetons ; la réservation est donc GARDÉE (état kept, montant
//      estimé), jamais remplacée par un montant non justifié par un usage — règle la plus stricte (usage absent ≠ gratuit).
//      Il n'est PAS installé par défaut : à l'activation d'agents_v2, appeler
//      `AgentsV2.installCostGate(LedgerCostGate())`.
//   3. Tant que rien n'est installé, `DenyAllCostGate` refuse toute dépense : aucun agent v2 ne peut appeler un
//      modèle payant (échec fermé), en plus du réglage `agents_v2` (défaut false).
// Le plafond PAR AGENT (≤ 0,75 $) est appliqué par le moteur lui-même, en plus de la garde Phase 2.

/// Classe de données (brief 2.3) : INTÉGRATION 31/10 — c'est désormais la `DataClass` de la Phase 2 (BrainRegistry.swift,
/// mêmes valeurs brutes). Absente → `personal` ; une tâche prend la classe la plus sensible de son entrée.
public typealias AgentDataClass = DataClass

extension DataClass {
    /// Classe d'une tâche = l'élément le plus sensible de son entrée ; entrée vide ou inconnue (nil) → personal.
    /// (Variante typée de `DataClass.resolve(_:)`, qui lit des étiquettes texte et envoie l'inconnu vers vault.)
    public static func strictest(_ items: [DataClass?]) -> DataClass {
        let known = items.map { $0 ?? .personal }
        return known.max(by: { $0.rank < $1.rank }) ?? .personal
    }
}

/// Profils de routage (brief 2.4). La chaîne de modèles de chaque profil appartient à la Phase 2.
public enum AgentRoutingProfile: String, Codable, CaseIterable, Sendable {
    case reflex, triage, main, deep, verify
    case bulkPublic = "bulk_public"
    case analysisPublic = "analysis_public"
    case longPublic = "long_public"
    case visualPublic = "visual_public"
}

/// Réservation accordée par la garde de coûts (montants en micro-dollars entiers, 1 USD = 1 000 000).
public struct AgentReservation: Codable, Equatable, Sendable {
    public let id: String
    public let micros: Int64
    public init(id: String, micros: Int64) { self.id = id; self.micros = micros }
}

/// Garde de coûts globale (jour / mois / tâche), implémentée par la Phase 2.
public protocol AgentCostGate: AnyObject {
    /// Réserve atomiquement `estimateMicros` ; nil = refusé (plafond, politique de données, aucun fournisseur autorisé).
    func reserve(taskId: String, profile: AgentRoutingProfile, dataClass: AgentDataClass, estimateMicros: Int64) -> AgentReservation?
    /// Solde avec l'usage réel ; `actualMicros == nil` (usage absent) → la réservation reste comptée.
    func settle(_ reservation: AgentReservation, actualMicros: Int64?)
}

/// Garde par défaut tant que la Phase 2 n'est pas branchée : refuse tout ce qui coûte (> 0).
public final class DenyAllCostGate: AgentCostGate {
    public init() {}
    public func reserve(taskId: String, profile: AgentRoutingProfile, dataClass: AgentDataClass, estimateMicros: Int64) -> AgentReservation? {
        estimateMicros <= 0 ? AgentReservation(id: "zero-" + taskId, micros: 0) : nil
    }
    public func settle(_ reservation: AgentReservation, actualMicros: Int64?) {}
}

/// Adaptateur Phase 3 → Phase 2 : la garde de coûts des agents v2 réserve dans le grand livre commun (voir l'en-tête).
public final class LedgerCostGate: AgentCostGate {
    private let ledger: () -> CostLedger?
    private let caps: () -> CostLedger.Caps?
    private let lane: Lane
    public init(ledger: @escaping () -> CostLedger? = { RoutingV2.ledger() },
                caps: @escaping () -> CostLedger.Caps? = { RoutingV2.registry().map { CostLedger.Caps($0) } },
                lane: Lane = .background) {
        self.ledger = ledger; self.caps = caps; self.lane = lane
    }
    public func reserve(taskId: String, profile: AgentRoutingProfile, dataClass: AgentDataClass, estimateMicros: Int64) -> AgentReservation? {
        guard let led = ledger(), let c = caps() else { return nil }   // grand livre ou registre illisible : échec fermé
        let r = led.reserve(task: "agent:" + taskId, lane: lane, brain: "agents_v2", profile: profile.rawValue,
                            dataClass: dataClass, estimate: max(0, estimateMicros), caps: c)
        guard let id = r.id else { return nil }
        return AgentReservation(id: id, micros: max(0, estimateMicros))
    }
    public func settle(_ reservation: AgentReservation, actualMicros: Int64?) {
        // Sans jetons rapportés, CostLedger garde la réservation (kept) : le montant engagé reste l'estimation.
        ledger()?.settle(reservation.id, usage: nil, cost: nil)
    }
}
