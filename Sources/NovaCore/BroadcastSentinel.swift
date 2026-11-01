// ============================================================================
// NOVA XXII — BroadcastSentinel.swift
// Moteur Autonome d'Ecoute Continue 24/7 (Radios & TV Embarquees)
// & Generation Automatique des 3 Briefings Quotidiens (07h30, 13h00, 18h30)
// Conforme Charte CAFU (Save the Children) — Zero Modification de l'Existant
// ============================================================================

import Foundation

public struct BroadcastChannel: Codable, Sendable {
    public let id: String
    public let name: String
    public let country: String
    public let category: String // "Radio" | "TV"
    public let streamURL: String
    public let priorityKeywords: [String]

    public init(id: String, name: String, country: String, category: String, streamURL: String, priorityKeywords: [String]) {
        self.id = id
        self.name = name
        self.country = country
        self.category = category
        self.streamURL = streamURL
        self.priorityKeywords = priorityKeywords
    }
}

public struct BroadcastSignal: Codable, Sendable {
    public let id: String
    public let channelID: String
    public let channelName: String
    public let country: String
    public let timestamp: Date
    public let transcript: String
    public let epistemicLevel: String // "VERT_FAIT" | "JAUNE_HYPOTHESE" | "ROUGE_CRITIQUE"
    public let matchedEntities: [String]
    public let clipPath: String?
}

public actor BroadcastSentinel {
    public static let shared = BroadcastSentinel()

    // Bouquet souverain Afrique de l'Ouest, Sahel, Grands Lacs & International
    public private(set) var channels: [BroadcastChannel] = [
        BroadcastChannel(
            id: "rfi_afrique",
            name: "RFI Afrique",
            country: "Régional (Sahel & Afrique)",
            category: "Radio",
            streamURL: "https://rfiafrique64k.ice.infomaniak.ch/rfiafrique-64.mp3",
            priorityKeywords: ["Burkina", "Ouagadougou", "Sahel", "AES", "Mali", "Niger", "humanitaire", "sécurité", "UEMOA", "CEDEAO"]
        ),
        BroadcastChannel(
            id: "rtb_burkina",
            name: "RTB Radio / Télé Burkina",
            country: "Burkina Faso",
            category: "TV",
            streamURL: "https://edge.rtb.bf/live/rtb.m3u8",
            priorityKeywords: ["Conseil des ministres", "Ouagadougou", "Saaba", "SONABEL", "DGI", "Kaya", "Dori", "Fada", "Bobo-Dioulasso", "décret"]
        ),
        BroadcastChannel(
            id: "france24_fr",
            name: "France 24 Direct",
            country: "International / Afrique",
            category: "TV",
            streamURL: "https://static.france24.com/live/F24_FR_HI_HLS/live_web.m3u8",
            priorityKeywords: ["Afrique de l'Ouest", "Soudan", "RDC", "Goma", "Tchad", "ONU", "OCHA", "Save the Children", "financement"]
        ),
        BroadcastChannel(
            id: "ortm_mali",
            name: "ORTM Mali",
            country: "Mali",
            category: "TV",
            streamURL: "https://live.ortm.ml/hls/ortm.m3u8",
            priorityKeywords: ["Bamako", "Mopti", "Gao", "Tombouctou", "Kidal", "corridor", "transition"]
        ),
        BroadcastChannel(
            id: "tele_sahel",
            name: "Télé Sahel Niger",
            country: "Niger",
            category: "TV",
            streamURL: "https://live.telesahel.ne/hls/sahel.m3u8",
            priorityKeywords: ["Niamey", "Tillabéri", "Diffa", "Maradi", "Agadez", "frontière", "convoi"]
        ),
        BroadcastChannel(
            id: "bbc_afrique",
            name: "BBC Afrique",
            country: "Régional",
            category: "Radio",
            streamURL: "https://stream.live.vc.bbcmedia.co.uk/bbc_afrique_radio",
            priorityKeywords: ["Sahel", "Côte d'Ivoire", "Sénégal", "BRVM", "BCEAO", "inflation", "cacao", "or"]
        )
    ]

    private var capturedSignals: [BroadcastSignal] = []
    private var isMonitoring: Bool = false
    private var briefingTimers: [DispatchSourceTimer] = []

    // Dictionnaire d'ancrage lexical souverain pour corriger la transcription phonétique
    private let lexicalAnchors: [(String, String)] = [
        ("(?i)\\bkafu\\b", "CAFU"),
        ("(?i)\\bbrvm\\b", "BRVM"),
        ("(?i)\\bsbif\\b", "SBIF"),
        ("(?i)\\bocha\\b", "OCHA"),
        ("(?i)\\baes\\b", "Confédération AES"),
        ("(?i)\\bouaga\\b", "Ouagadougou")
    ]

    public func startContinuousMonitoring() {
        guard !isMonitoring else { return }
        isMonitoring = true
        scheduleTriDailyBriefings()
    }

    /// Planifie les 3 Briefings Exécutifs Automatiques : 07h30, 13h00 et 18h30
    private func scheduleTriDailyBriefings() {
        let slots = [(7, 30, "MATINAL"), (13, 0, "MI_JOURNEE"), (18, 30, "CLOTURE_SOIR")]
        for (hour, minute, label) in slots {
            let timer = DispatchSource.makeTimerSource(queue: DispatchQueue.global(qos: .utility))
            let delay = secondsUntil(hour: hour, minute: minute)
            timer.schedule(deadline: .now() + delay, repeating: 86_400)
            timer.setEventHandler { [weak self] in
                guard let self = self else { return }
                Task {
                    _ = await self.generateScheduledBriefing(edition: label)
                }
            }
            timer.resume()
            briefingTimers.append(timer)
        }
    }

    private func secondsUntil(hour: Int, minute: Int) -> TimeInterval {
        let cal = Calendar.current
        let now = Date()
        var comps = cal.dateComponents([.year, .month, .day], from: now)
        comps.hour = hour
        comps.minute = minute
        comps.second = 0
        if let target = cal.date(from: comps), target > now {
            return target.timeIntervalSince(now)
        }
        return cal.date(from: comps)!.addingTimeInterval(86_400).timeIntervalSince(now)
    }

    /// Ingère un segment transcrit depuis le démultiplexeur audio ANE / MLX-[tiers]
    public func ingestTranscriptChunk(channelID: String, rawText: String, clipPath: String? = nil) -> BroadcastSignal? {
        guard let ch = channels.first(where: { $0.id == channelID }) else { return nil }
        let normalized = normalizeLexicon(rawText)
        let matched = ch.priorityKeywords.filter { normalized.localizedCaseInsensitiveContains($0) }
        guard !matched.isEmpty else { return nil }

        // Qualification épistémique automatique DOTS
        let corroborateCount = capturedSignals.filter {
            $0.channelID != channelID &&
            Date().timeIntervalSince($0.timestamp) < 7200 &&
            !Set($0.matchedEntities).isDisjoint(with: Set(matched))
        }.count

        let level: String
        if matched.contains(where: { ["sécurité", "alerte", "attaque", "fermeture", "décret"].contains($0.lowercased()) }) {
            level = "ROUGE_CRITIQUE"
        } else if corroborateCount >= 1 {
            level = "VERT_FAIT"
        } else {
            level = "JAUNE_HYPOTHESE"
        }

        let signal = BroadcastSignal(
            id: UUID().uuidString,
            channelID: ch.id,
            channelName: ch.name,
            country: ch.country,
            timestamp: Date(),
            transcript: normalized,
            epistemicLevel: level,
            matchedEntities: matched,
            clipPath: clipPath
        )
        capturedSignals.append(signal)
        return signal
    }

    private func normalizeLexicon(_ input: String) -> String {
        var out = input
        for (pattern, replacement) in lexicalAnchors {
            if let rx = try? NSRegularExpression(pattern: pattern) {
                out = rx.stringByReplacingMatches(in: out, range: NSRange(out.startIndex..., in: out), withTemplate: replacement)
            }
        }
        return out
    }

    /// Produit la Note de Briefing Exécutif (Gabarit CAFU 6 Blocs + Protocole Bi-Canal PARLE/DÉTAIL)
    public func generateScheduledBriefing(edition: String) -> [String: Any] {
        let cutoff = Date().addingTimeInterval(-28_800) // 8 dernières heures d'écoute
        let recent = capturedSignals.filter { $0.timestamp >= cutoff }
        let facts = recent.filter { $0.epistemicLevel == "VERT_FAIT" }
        let alerts = recent.filter { $0.epistemicLevel == "ROUGE_CRITIQUE" }
        let hypotheses = recent.filter { $0.epistemicLevel == "JAUNE_HYPOTHESE" }

        let spokenSummary = "<PARLE>Jean Cyrille, voici ton briefing \(edition.lowercased()) : \(recent.count) signaux captés sur les radios et télévisions régionales, dont \(alerts.count) alertes critiques et \(facts.count) faits recoupés. La note CAFU complète est prête à l'écran.</PARLE>"

        let structuredNote: [String: Any] = [
            "edition": edition,
            "generatedAt": ISO8601DateFormatter().string(from: Date()),
            "spokenChannel": spokenSummary,
            "cafuStandard": [
                "backgroundHex": "#ECE9E3",
                "titleHex": "#C00000",
                "footerHex": "#AD1F23",
                "fontFamily": "Aptos"
            ],
            "blocks": [
                "1_BLUF": "Synthèse consolidée des écoutes radio/TV 24/7 (\(recent.count) séquences retenues sur \(channels.count) flux surveillés).",
                "2_FAITS_VERIFIES_VERT": facts.map { "[\($0.channelName) — \($0.country)] \($0.transcript)" },
                "3_ANALYSE_ARTICLE_32": "Connectivité inter-blocs : corrélation entre les annonces institutionnelles régionales, la continuité des corridors logistiques et la stabilité macroéconomique UEMOA.",
                "4_HYPOTHESES_JAUNE": hypotheses.map { "[\($0.channelName)] \($0.transcript)" },
                "5_INCONNUES_CRITIQUES_ROUGE": alerts.map { "[\($0.channelName) — ALERTE] \($0.transcript)" },
                "6_RECOMMANDATIONS": [
                    "Valider l'envoi de la note de synthèse aux points focaux régionaux.",
                    "Ajuster le niveau de veille DOTS sur les corridors signalés en alerte rouge."
                ]
            ]
        ]
        return structuredNote
    }
}
