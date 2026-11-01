// ============================================================================
// NOVA XXII — DotsMeshAndSelfHealingForge.swift
// 3. Maillage Epistemique des DOTS (Faits Verts / Hypotheses Jaunes / Alertes Rouges)
//    + Journal d'Audit Cryptographique en Chaine de Merkle (SHA-256)
// 4. Boucle d'Auto-Guerison Sandboxed (Self-Healing Forge Actor)
// ============================================================================

import Foundation

public struct EpistemicDotAlert: Codable, Sendable {
    public let id: String
    public let dotName: String
    public let domain: String // "HUMANITAIRE_CAFU" | "BOURSE_BRVM" | "COURRIER_VIP" | "ENERGIE_BEVE" | "MEDIA_LIVE"
    public let epistemicStatus: String // "VERT_FAIT_VERIFIE" | "JAUNE_HYPOTHESE" | "ROUGE_INCONNUE_CRITIQUE"
    public let confidenceScore: Double
    public let headline: String
    public let article32Connectivity: String
    public let recommendedAction: String
    public let merkleHash: String
    public let createdAt: Date
}

public actor EpistemicDotsMesh {
    public static let shared = EpistemicDotsMesh()

    private var alertChain: [EpistemicDotAlert] = []
    private var lastMerkleHash: String = "0000000000000000000000000000000000000000000000000000000000000000"

    /// Enregistre et corrèle une alerte issue d'un Dot avec scellement cryptographique SHA-256 (Audit Enterprise M&A)
    public func publishSignal(
        dotName: String,
        domain: String,
        headline: String,
        corroboratingSourcesCount: Int,
        isCriticalGap: Bool,
        article32Connectivity: String,
        recommendedAction: String
    ) -> EpistemicDotAlert {
        let status: String
        let confidence: Double
        if isCriticalGap {
            status = "ROUGE_INCONNUE_CRITIQUE"
            confidence = 0.95
        } else if corroboratingSourcesCount >= 2 {
            status = "VERT_FAIT_VERIFIE"
            confidence = min(0.99, 0.70 + Double(corroboratingSourcesCount) * 0.10)
        } else {
            status = "JAUNE_HYPOTHESE"
            confidence = 0.55
        }

        let now = Date()
        let payload = "\(lastMerkleHash)|\(dotName)|\(domain)|\(status)|\(headline)|\(now.timeIntervalSince1970)"
        let newHash = Sha.hash(payload)   // SHA-256 maison (BlackBox.swift), identique sur Mac et Linux
        lastMerkleHash = newHash

        let alert = EpistemicDotAlert(
            id: UUID().uuidString,
            dotName: dotName,
            domain: domain,
            epistemicStatus: status,
            confidenceScore: confidence,
            headline: headline,
            article32Connectivity: article32Connectivity,
            recommendedAction: recommendedAction,
            merkleHash: newHash,
            createdAt: now
        )
        alertChain.append(alert)
        return alert
    }

    public func latestConsolidatedBrief(limit: Int = 15) -> [EpistemicDotAlert] {
        return Array(alertChain.suffix(limit).reversed())
    }
}
