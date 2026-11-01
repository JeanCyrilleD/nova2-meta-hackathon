// ============================================================================
// NOVA XXII — NovaXXIIBridge.swift
// Pont d'intégration additive Zéro-Casse pour Server.swift & App.swift
// Connecte les 4 moteurs autonomes (BroadcastSentinel, ExecutiveMailEngine,
// EpistemicDotsMesh, AlphaQuantEngine) sans altérer les routes existantes.
// ============================================================================

import Foundation

// VAGUE 2 FIABILITÉ (24/10/2026) — MOTEURS XXII DÉSACTIVÉS (code conservé).
// Constat : bootAutonomousEngines() armait 3 minuteurs (07:30, 13:00, 18:30) qui produisaient une « note de
// briefing » à partir de ZÉRO signal (aucune transcription radio/TV n'est branchée : capturedSignals reste vide),
// avec un « 3_ANALYSE_ARTICLE_32 » et des « 6_RECOMMANDATIONS » écrits en dur ; /api/xxii/status annonçait des
// « briefings quotidiens » qui n'existent pas. EpistemicDotsMesh, ExecutiveMailEngine et AlphaQuantEngine n'ont
// aucun appelant réel. Règle « aucun état simulé » : tant qu'`enabled` est faux (défaut, non exposé dans les
// réglages), rien ne démarre et toutes les routes /api/xxii/* répondent 503 avec le motif. Aucun appelant web.
// Réactiver = brancher d'abord une source réelle (transcription, cours), puis passer `enabled` à vrai.
public enum NovaXXIIBridge {
    // PHASE 1 : constante (aucune écriture dans le code) — plus de nonisolated(unsafe). Réactiver = changer cette ligne.
    public static let enabled: Bool = false
    private static var initialized = false
    private static let lock = NSLock()

    /// Démarre en tâche de fond la veille Radio/TV 24/7 et les 3 briefings quotidiens (07h30, 13h00, 18h30)
    /// VAGUE 2 FIABILITÉ : sans effet tant que `enabled` est faux (aucun minuteur, aucune note produite).
    public static func bootAutonomousEngines() {
        lock.lock()
        defer { lock.unlock() }
        guard enabled else { return }
        guard !initialized else { return }
        initialized = true

        Task {
            await BroadcastSentinel.shared.startContinuousMonitoring()
        }
    }

    /// Routeur additif pour Server.swift : retourne nil si la route appartient au noyau Nova existant (Zéro régression)
    public static func handleRoute(method: String, path: String, body: Data) async -> (status: Int, mime: String, data: Data)? {
        guard path.hasPrefix("/api/xxii/") else { return nil }
        if !enabled {   // VAGUE 2 FIABILITÉ : moteurs factices coupés — réponse honnête, aucun état inventé
            let off: [String: Any] = ["ok": false, "enabled": false,
                                      "error": "moteurs XXII désactivés : aucune source réelle (écoute radio/TV, cours BRVM) n'est branchée — aucun état n'est simulé"]
            return (503, "application/json", jsonData(off))
        }

        switch (method, path) {
        case ("GET", "/api/xxii/status"):
            let alerts = await EpistemicDotsMesh.shared.latestConsolidatedBrief(limit: 10)
            let options: [InvestmentOptionCard] = []   // aucune source de cours branchée : pas de chiffres inventés
            let payload: [String: Any] = [
                "ok": true,
                "engine": "NOVA_XXII_SOVEREIGN_OS",
                "triDailyBriefings": ["07:30", "13:00", "18:30"],
                "dotsAlertsCount": alerts.count,
                "quantOptionsCount": options.count,
                "quantSource": "non connectée (aucun cours réel : le moteur quantitatif ne renvoie rien tant qu'une source BRVM n'est pas branchée)",
                "ecouteRadioTV": "planification des 3 briefings seulement ; aucune transcription audio n'est branchée"
            ]
            let json = (try? JSONSerialization.data(withJSONObject: payload, options: [.prettyPrinted])) ?? Data("{}".utf8)
            return (200, "application/json", json)

        case ("POST", "/api/xxii/briefing/generate"):
            let note = await BroadcastSentinel.shared.generateScheduledBriefing(edition: "SUR_DEMANDE")
            let json = (try? JSONSerialization.data(withJSONObject: note, options: [.prettyPrinted])) ?? Data("{}".utf8)
            return (200, "application/json", json)

        case ("GET", "/api/xxii/quant/options"):
            // [tiers] avait codé en dur SNTS/CBIBF/BOABF/ONTBF avec des cours inventés ; on n'émet jamais de recommandation sur des chiffres fictifs.
            let msg = jsonData(["ok": false, "error": "source de cours BRVM non connectée", "options": []] as [String: Any])
            return (503, "application/json", msg)

        case ("GET", "/api/xxii/dots/mesh"):
            let alerts = await EpistemicDotsMesh.shared.latestConsolidatedBrief(limit: 20)
            let data = (try? JSONEncoder().encode(alerts)) ?? Data("[]".utf8)
            return (200, "application/json", data)

        default:
            return nil
        }
    }
}
