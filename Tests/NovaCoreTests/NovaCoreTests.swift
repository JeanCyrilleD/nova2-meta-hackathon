import XCTest
@testable import NovaCore

/// Tests de fumée Nova 2 — la cible existe et le catalogue de cerveaux est sain.
/// (Nova 1 : la cible de test ne se résolvait même pas, écart de casse Tests/ vs tests/.)
final class NovaCoreTests: XCTestCase {

    /// NOVA2-CATALOGUE : les modèles prouvés morts (404) ne doivent jamais revenir au catalogue.
    func testCatalogHasNoProvenDeadModels() {
        let ids = Set(Catalog.defaults().map { $0.id })
        XCTAssertFalse(ids.contains("spark-1.4"), "muse-spark-1.4 est mort (404) — ne pas réintroduire")
        XCTAssertTrue(Catalog.defaults().allSatisfy { MetaOnly.isMeta($0) }, "version hackathon : catalogue 100 % Meta")
        XCTAssertTrue(ids.contains("spark-1.3"), "le cerveau Meta vivant doit rester au catalogue")
    }

    /// NOVA2-PLAFOND : les listes d'ordre ne référencent que des cerveaux du catalogue, sans doublon.
    func testOrdersReferenceCatalogWithoutDuplicates() {
        let ids = Set(Catalog.defaults().map { $0.id })
        for order in [Catalog.fastOrder, Catalog.bulkOrder, Catalog.deepOrder] {
            XCTAssertEqual(order.count, Set(order).count, "doublon dans une liste d'ordre")
            for id in order { XCTAssertTrue(ids.contains(id), "ordre référence un cerveau absent : \(id)") }
        }
    }

    /// META-MUSE (26/10) : la famille Meta Model API est au catalogue, aux IDs officiels
    /// (dev.meta.ai/docs/models) : Wonder, Spark 1.3/1.2, Image/Voice/SAM sont des capacités, pas des cerveaux chat.
    func testMetaCatalogHasOfficialIDs() {
        let ids = Set(Catalog.defaults().map { $0.id })
        XCTAssertTrue(ids.contains("wonder-1.0"), "muse-wonder-1.0 doit être au catalogue")
        XCTAssertTrue(ids.contains("spark-1.3"), "muse-spark-1.3 doit rester au catalogue")
        XCTAssertTrue(ids.contains("spark-1.2"), "muse-spark-1.2 (repli, audio mieux servi) doit être au catalogue")
        let byId = Dictionary(uniqueKeysWithValues: Catalog.defaults().map { ($0.id, $0) })
        XCTAssertEqual(byId["wonder-1.0"]?.model, "muse-wonder-1.0")
        XCTAssertEqual(byId["spark-1.2"]?.model, "muse-spark-1.2")
        XCTAssertTrue(byId["wonder-1.0"]?.baseURL.hasPrefix("https://api.meta.ai/v1/") ?? false)
    }

    /// MISSION 26/10 (regle 7, CONFIDENTIALITE) : Contributor est EXCLU des chaines
    /// automatiques et des defauts. Contributor reste au catalogue, en choix explicite pour contenus non personnels.
    /// Version hackathon Meta : têtes de chaîne Spark 1.3 (Brains.swift fastOrder/bulkOrder/deepOrder).
    /// La règle testée n'est pas affaiblie : elle est élargie à TOUT palier Contributor (suffixe) et à Muse Code,
    /// et chaque tête de chaîne doit être un cerveau Standard réel, visible, au catalogue.
    func testContributorExplicitOnlyNeverAutomatic() {
        XCTAssertTrue(Catalog.defaults().contains { $0.id == "spark-1.3-contributor" })
        let ids = Set(Catalog.defaults().map { $0.id })
        for order in [Catalog.fastOrder, Catalog.bulkOrder, Catalog.deepOrder] {
            XCTAssertFalse(order.contains("spark-1.3-contributor"), "Contributor ne doit jamais servir en chaine automatique")
            XCTAssertFalse(order.contains("spark-1.2-contributor"))
            XCTAssertFalse(order.contains { $0.hasSuffix("-contributor") || $0 == "muse-code" }, "aucun palier Contributor (ni Muse Code) en chaine automatique")
            let head = order.first ?? ""
            XCTAssertTrue(ids.contains(head) && !Catalog.isHidden(head) && !head.contains("contributor"), "tête de chaîne Standard, visible, au catalogue : \(head)")
        }
        XCTAssertEqual(Catalog.fastOrder.first, "spark-1.3")   // version Meta : Spark d'abord
        XCTAssertEqual(Catalog.bulkOrder.first, "spark-1.3")
        XCTAssertEqual(Catalog.deepOrder.first, "spark-1.3")
        let label = Catalog.defaults().first { $0.id == "spark-1.3-contributor" }?.label ?? ""
        XCTAssertTrue(label.contains("réutilisable"), "le libellé doit annoncer la réutilisation du contenu par Meta")
    }

    /// META-MUSE : les charges utiles Image / SAM suivent la doc officielle (modèles + formes),
    /// construites par des fonctions pures — aucun réseau dans ce test.
    func testMetaPayloadBuilders() {
        let img = MetaCapabilities.imagePayload(prompt: "Un panda roux en céramique, lumière douce")
        XCTAssertEqual(img["model"] as? String, "muse-image-1.0")
        XCTAssertEqual(img["prompt"] as? String, "Un panda roux en céramique, lumière douce")
        let seg = MetaCapabilities.segmentPayload(prompt: "glasses", imageURL: "https://example.com/photo.png")
        XCTAssertEqual(seg["model"] as? String, "sam-3.1")
        let input = seg["input"] as? [[String: Any]]
        let content = input?.first?["content"] as? [[String: Any]]
        XCTAssertEqual(content?.first?["text"] as? String, "glasses")
        XCTAssertEqual(content?.last?["image_url"] as? String, "https://example.com/photo.png")
        XCTAssertEqual(MetaCapabilities.voiceModel, "muse-voice-transcribe-1.0")
        XCTAssertTrue(MetaCapabilities.voiceRealtimeURL.hasPrefix("wss://api.meta.ai/"))
    }

    /// NOUVEAUTÉS 26/10 : estimateur de coût Meta (fonction pure, grille publiée).
    func testMetaEstimate() {
        XCTAssertEqual(MetaCapabilities.estimateUSD(brain: "spark-1.3-contributor", inputTokens: 1_000_000, outputTokens: 1_000_000) ?? -1, 0.30, accuracy: 0.0001)
        XCTAssertEqual(MetaCapabilities.estimateUSD(brain: "wonder-1.0", inputTokens: 1_000_000, outputTokens: 0) ?? -1, 4.0, accuracy: 0.0001)
        XCTAssertNil(MetaCapabilities.estimateUSD(brain: "vendor-x", inputTokens: 10, outputTokens: 10))
    }

    /// NOUVEAUTÉS 26/10 : pré-vol d'envoi — les écarts classiques sont bloquants, jamais silencieux.
    func testPreflight() {
        let blocked = MetaCapabilities.preflightChecks(to: "", subject: "", body: "Voir la pièce jointe.", attachments: [])
        XCTAssertTrue(blocked.contains { $0["level"] == "block" })
        let ok = MetaCapabilities.preflightChecks(to: "awa@example.org", subject: "Visa", body: "Bonjour, voici le formulaire approuvé pour le paiement du visa de mission.", attachments: ["form.pdf"])
        XCTAssertFalse(ok.contains { $0["level"] == "block" })
    }

    // MARK: Initiatives proactives (26/10) — cas fictifs, fonctions pures, aucun réseau.

    private func isoDaysAgo(_ now: Date, _ days: Double) -> String {
        ISO8601DateFormatter().string(from: now.addingTimeInterval(-days * 86400))
    }

    /// Cas fictif mémoire : le fait ancien éligible ressort ; récent, sensible ou déjà ressorti sont exclus.
    func testProactivitePickMemory() {
        let now = Date()
        let facts: [[String: Any]] = [
            ["id": "vieux", "text": "Le partenaire régional préfère les rapports au format court avec annexes séparées.", "ts": isoDaysAgo(now, 80)],
            ["id": "recent", "text": "Un fait tout frais qui ne doit pas encore resurgir dans le fil de Nova.", "ts": isoDaysAgo(now, 3)],
            ["id": "sensible", "text": "Le solde du compte bancaire personnel doit rester hors de toute initiative affichée.", "ts": isoDaysAgo(now, 90)],
            ["id": "deja", "text": "Un souvenir déjà ressorti récemment ne doit pas revenir une seconde fois de suite.", "ts": isoDaysAgo(now, 70)],
        ]
        let shown: [String: String] = ["memoire|deja": isoDaysAgo(now, 2)]
        XCTAssertEqual(Proactivite.pickMemory(facts: facts, now: now, shown: shown)?["id"] as? String, "vieux")
        XCTAssertNil(Proactivite.pickMemory(facts: [facts[1]], now: now, shown: [:]))
        XCTAssertNil(Proactivite.pickMemory(facts: [facts[2]], now: now, shown: [:]))
    }

    /// Cas fictifs engagements : dérive (moi, ancien, sans échéance), attente (eux, ancienne),
    /// échéance (retard ou < 48 h) ; les statuts fermés et les dates lointaines ne tirent jamais.
    func testProactivitePicksEngagements() {
        let now = Date()
        let items: [[String: Any]] = [
            ["id": "derive", "status": "ouvert", "dir": "moi", "echeance": "", "created": isoDaysAgo(now, 20), "seen": isoDaysAgo(now, 15), "quoi": "Envoyer la synthèse au partenaire"],
            ["id": "attente", "status": "ouvert", "dir": "eux", "echeance": "", "created": isoDaysAgo(now, 9), "quoi": "Validation du budget par le bailleur"],
            ["id": "ferme", "status": "fait", "dir": "moi", "echeance": "", "created": isoDaysAgo(now, 30), "quoi": "Point déjà clos"],
        ]
        XCTAssertEqual(Proactivite.pickDrift(items: items, now: now, shown: [:])?["id"] as? String, "derive")
        XCTAssertEqual(Proactivite.pickWaiting(items: items, now: now, shown: [:])?["id"] as? String, "attente")
        let df = DateFormatter(); df.locale = Locale(identifier: "en_US_POSIX"); df.dateFormat = "yyyy-MM-dd"
        let dues: [[String: Any]] = [
            ["id": "loin", "status": "ouvert", "dir": "moi", "echeance": df.string(from: now.addingTimeInterval(10 * 86400)), "created": isoDaysAgo(now, 1), "quoi": "Échéance lointaine"],
            ["id": "retard", "status": "ouvert", "dir": "moi", "echeance": df.string(from: now.addingTimeInterval(-2 * 86400)), "created": isoDaysAgo(now, 12), "quoi": "Rapport financier à déposer"],
        ]
        XCTAssertEqual(Proactivite.pickDue(items: dues, now: now, shown: [:])?["id"] as? String, "retard")
    }

    /// Anticipation (27/10) : les trois réflexes préparent sans jamais exécuter — signal de feed
    /// avec demande datée, rapprochement signal neuf × fait ancien, réunion proche fichée.
    func testPreparationsAnticipation() {
        let now = Date()
        let units: [[String: Any]] = [
            ["id": "u1", "title": "Rapport à valider avant le 30/11", "standfirst": "Merci de valider le rapport régional avant le 30/11, action requise.", "ts": isoDaysAgo(now, 0)],
            ["id": "u2", "title": "Newsletter hebdomadaire", "standfirst": "Les nouvelles de la semaine, bonne lecture.", "ts": isoDaysAgo(now, 0)],
        ]
        let prep = Preparations.pickFeedAction(units: units, now: now, cles: [])
        XCTAssertEqual(prep?["genre"] as? String, "tache")
        XCTAssertEqual((prep?["engagement"] as? [String: Any])?["echeance"] as? String, "2026-11-30")
        XCTAssertNil(Preparations.pickFeedAction(units: [units[1]], now: now, cles: []))
        XCTAssertNil(Preparations.pickFeedAction(units: units, now: now, cles: ["feed|u1", "feed|u2"]))

        let facts: [[String: Any]] = [
            ["id": "f1", "text": "Analyse des déplacements transfrontaliers entre Éthiopie et Kenya, corridor de Moyale suivi depuis le printemps.", "ts": isoDaysAgo(now, 90)],
        ]
        let neuf: [[String: Any]] = [
            ["id": "u9", "title": "Déplacements transfrontaliers Éthiopie Kenya", "standfirst": "Nouvelle escalade à Moyale, déplacements signalés.", "ts": isoDaysAgo(now, 0)],
        ]
        let rap = Preparations.pickRapprochement(units: neuf, facts: facts, now: now, cles: [])
        XCTAssertEqual(rap?["genre"] as? String, "rapprochement")
        XCTAssertNil(Preparations.pickRapprochement(units: neuf, facts: facts, now: now, cles: ["rapproche|u9|f1"]))

        let iso = ISO8601DateFormatter()
        let events: [[String: Any]] = [
            ["titre": "Revue déplacements Moyale", "debut": iso.string(from: now.addingTimeInterval(5 * 3600)), "participants": ["Yvonne Sarchi"]],
            ["titre": "Point lointain", "debut": iso.string(from: now.addingTimeInterval(90 * 3600)), "participants": []],
        ]
        let commits: [[String: Any]] = [
            ["id": "c1", "status": "ouvert", "quoi": "Préparer la revue des déplacements à Moyale", "echeance": "", "created": isoDaysAgo(now, 4)],
        ]
        let fiche = Preparations.pickReunion(events: events, commitments: commits, facts: facts, now: now, cles: [])
        XCTAssertEqual(fiche?["genre"] as? String, "reunion")
        XCTAssertTrue(((fiche?["prepare"] as? String) ?? "").contains("Engagements ouverts liés"))
    }

    /// Audit conversations (27/10) : fenêtre 24 h, rôles user/assistant seulement, fils
    /// incognito et cartes event exclus, secrets redactés, cerveau et latence par tour.
    func testAuditConversations() {
        let now = Date()
        let iso = ISO8601DateFormatter()
        func ts(_ agoH: Double) -> String { iso.string(from: now.addingTimeInterval(-agoH * 3600)) }
        let convs: [[String: Any]] = [
            ["id": "c1", "title": "Sujet fictif", "created": ts(30), "messages": [
                ["role": "user", "content": "Question fictive ?", "ts": ts(2)],
                ["role": "assistant", "content": "Réponse fictive, clé " + "sk" + "-ant-" + String(repeating: "a", count: 24) + " jamais en clair.", "ts": ts(2) + "", "brain": "spark-1.3"],
                ["role": "event", "content": "Carte Direct fictive", "ts": ts(1)],
                ["role": "user", "content": "Hors fenêtre", "ts": ts(49)],
            ]],
            ["id": "c2", "title": "Incognito fictif", "incognito": true, "messages": [
                ["role": "user", "content": "Ne doit pas sortir", "ts": ts(1)],
            ]],
        ]
        // horodatage assistant décalé de 90 s pour une latence dérivée lisible
        var convs2 = convs
        var msgs = (convs2[0]["messages"] as? [[String: Any]]) ?? []
        msgs[1]["ts"] = iso.string(from: now.addingTimeInterval(-2 * 3600 + 90))
        convs2[0]["messages"] = msgs
        let out = AuditConversations.buildExport(conversations: convs2, now: now, hours: 24)
        let list = (out["conversations"] as? [[String: Any]]) ?? []
        XCTAssertEqual(list.count, 1)
        let ech = (list.first?["echanges"] as? [[String: Any]]) ?? []
        XCTAssertEqual(ech.count, 2)
        XCTAssertEqual(ech.first?["tour"] as? Int, 1)
        XCTAssertEqual(ech.last?["cerveau"] as? String, "spark-1.3")
        XCTAssertEqual(ech.last?["ecart_horodatages_s"] as? Int, 90)
        XCTAssertEqual(out["redactions_secrets"] as? Int, 1)
        XCTAssertFalse(((ech.last?["contenu"] as? String) ?? "").contains("sk-ant-"))
    }

    // MARK: Chantier 2 (a) — Boucle d'evaluation, cas fictifs, fonctions pures.

    func testEvalScoreDeterministe() {
        let ok = EvalCore.score(response: "La capitale est Brume-sur-Lac (source : fiche fictive, 2026-01-15).",
                                expectedFacts: ["Brume-sur-Lac"], requireDatedSource: true)
        XCTAssertEqual(ok.score, 1.0, accuracy: 0.001)
        XCTAssertTrue(ok.dated)
        let partiel = EvalCore.score(response: "La capitale est Brume-sur-Lac.",
                                     expectedFacts: ["Brume-sur-Lac"], requireDatedSource: true)
        XCTAssertEqual(partiel.score, 0.8, accuracy: 0.001)
        let faux = EvalCore.score(response: "La capitale est Ailleurs.", expectedFacts: ["Brume-sur-Lac"], requireDatedSource: false)
        XCTAssertEqual(faux.score, 0.0, accuracy: 0.001)
        XCTAssertEqual(faux.missing, ["Brume-sur-Lac"])
        XCTAssertFalse(EvalCore.hasDatedSource("reponse sans aucune date ni source"))
    }

    func testEvalTendanceEtRegression() {
        let h: [[String: Any]] = [
            ["prompt_version": "v2", "score": 0.4], ["prompt_version": "v2", "score": 0.6],
            ["prompt_version": "v1", "score": 0.9], ["prompt_version": "v1", "score": 0.9],
        ]
        XCTAssertTrue(EvalCore.regressionDetected(history: h))
        XCTAssertFalse(EvalCore.regressionDetected(history: [["prompt_version": "v1", "score": 0.9]]))
        XCTAssertEqual(EvalCore.defaultTasks().count, 3)
    }

    // MARK: Chantier 2 (b) — Memoire temporelle, cas fictifs.

    func testMemoireTemporelleSupersession() {
        var facts: [[String: Any]] = []
        facts = TemporalMemory.assertFact(facts: facts, sujet: "ville fictive de Kerga", predicat: "maire", valeur: "A. Exemple",
                                          debut: "2025-01-01", source: "fiche fictive", id: "f1", ts: "2025-01-01T00:00:00Z")
        facts = TemporalMemory.assertFact(facts: facts, sujet: "ville fictive de Kerga", predicat: "maire", valeur: "B. Exemple",
                                          debut: "2026-03-01", source: "fiche fictive 2", id: "f2", ts: "2026-03-01T00:00:00Z")
        XCTAssertEqual(facts.count, 2, "l'ancien fait est clos, jamais efface")
        XCTAssertEqual(facts[0]["fin"] as? String, "2026-03-01")
        XCTAssertEqual(TemporalMemory.valueAt(facts: facts, sujet: "ville fictive de Kerga", predicat: "maire", date: "2025-06-01")?["valeur"] as? String, "A. Exemple")
        XCTAssertEqual(TemporalMemory.valueAt(facts: facts, sujet: "ville fictive de Kerga", predicat: "maire", date: "2026-06-01")?["valeur"] as? String, "B. Exemple")
        XCTAssertNil(TemporalMemory.valueAt(facts: facts, sujet: "ville fictive de Kerga", predicat: "maire", date: "2024-06-01"))
        XCTAssertFalse(TemporalMemory.isValidDay("2026-13-40"))
        let legacy = TemporalMemory.legacyAsTemporal([["id": "x1", "text": "Fait classique fictif.", "ts": "2026-01-01T10:00:00Z", "source": "utilisateur"]])
        XCTAssertEqual(legacy.first?["valeur"] as? String, "Fait classique fictif.")
    }

    // MARK: Chantier 2 (c) — Sous-agents isoles, cas fictifs.

    func testSousAgentsReglesFermees() {
        XCTAssertEqual(SousAgents.brainFor(role: "lecture", requested: nil), "local")
        XCTAssertEqual(SousAgents.brainFor(role: "recherche", requested: nil), "spark-1.3")
        XCTAssertNil(SousAgents.brainFor(role: "lecture", requested: "spark-1.3-contributor"), "Contributor interdit")
        XCTAssertNil(SousAgents.brainFor(role: "lecture", requested: "wonder-1.0"), "hors local/Standard : refuse")
        XCTAssertNil(SousAgents.allowedTools(role: "inconnu"))
        XCTAssertTrue(SousAgents.allowedTools(role: "lecture")?.contains("recall") == true)
        XCTAssertFalse(SousAgents.allowedTools(role: "lecture")?.contains("shell") == true)
        XCTAssertEqual(SousAgents.clampSteps(99), SousAgents.maxStepsCap)
        XCTAssertEqual(SousAgents.clampSteps(0), 1)
        let sum = SousAgents.summary(role: "lecture", brain: "local", text: "Resume fictif.", ledger: [["tool": "recall"]], stepsCap: 3)
        XCTAssertEqual(sum["outils_utilises"] as? [String], ["recall"])
    }

    // MARK: Chantier 2 (d) — Client MCP liste blanche, cas fictifs, aucun reseau.

    func testMCPListeBlanche() {
        XCTAssertTrue(MCPClient.parseServers(nil).isEmpty, "reglage vide = aucun serveur actif")
        XCTAssertTrue(MCPClient.parseServers([["nom": "  ", "commande": "x"]]).isEmpty)
        let servers = MCPClient.parseServers([["nom": "demo", "commande": "/usr/bin/env python3 demo.py",
                                               "outils_autorises": ["meteo_fictive"], "plafond": 2]])
        XCTAssertEqual(servers.count, 1)
        XCTAssertTrue(MCPClient.isToolAllowed(servers[0], "meteo_fictive"))
        XCTAssertFalse(MCPClient.isToolAllowed(servers[0], "shell_libre"))
        let req = MCPClient.request(id: 7, method: "tools/call", params: ["name": "meteo_fictive"])
        XCTAssertEqual(req["method"] as? String, "tools/call")
        MCPClient.resetSessionCounts()
        XCTAssertTrue(MCPClient.consumeQuota(server: servers[0]))
        XCTAssertTrue(MCPClient.consumeQuota(server: servers[0]))
        XCTAssertFalse(MCPClient.consumeQuota(server: servers[0]), "plafond de session borne")
        MCPClient.resetSessionCounts()
    }

    /// Intervalles irréguliers : bornés par le couloir de chaque type, jamais d'heure fixe ;
    /// plafond quotidien et heures calmes sont des gardes bloquantes.
    func testProactiviteIntervallesEtGardes() {
        for (type, r) in Proactivite.ranges {
            XCTAssertEqual(Proactivite.intervalMinutes(type, roll: 0), r.0)
            XCTAssertEqual(Proactivite.intervalMinutes(type, roll: 1), r.1)
            XCTAssertTrue(Proactivite.intervalMinutes(type, roll: 0.5) > r.0 && Proactivite.intervalMinutes(type, roll: 0.5) < r.1)
        }
        XCTAssertTrue(Proactivite.canFire(countToday: 0, quiet: false, master: true))
        XCTAssertFalse(Proactivite.canFire(countToday: Proactivite.dailyCap, quiet: false, master: true))
        XCTAssertFalse(Proactivite.canFire(countToday: 0, quiet: true, master: true))
        XCTAssertFalse(Proactivite.canFire(countToday: 0, quiet: false, master: false))
    }

    /// CHANTIER 3-A : réglage fermé → refus nommé, file vide ; aucun tour exécutable avant validation.
    func testVoixConversationPorteEtRelecture() {
        let vc = VoixConversation()
        let refuse = vc.demarrerTour(actif: false)
        XCTAssertFalse(refuse.ok)
        XCTAssertTrue(refuse.raison.contains("voix_conversation"))
        XCTAssertTrue(vc.file().isEmpty)
        let dem = vc.demarrerTour(actif: true)
        XCTAssertTrue(dem.ok)
        let id = dem.id!
        vc.majPartiel(id: id, texte: "ouvre le rap")
        XCTAssertEqual(vc.file().first?.texteIntermediaire, "ouvre le rap")
        XCTAssertNil(vc.texteExecutable(id: id), "jamais exécutable pendant l'écoute")
        vc.cloreTourUtilisateur(id: id, texteFinal: "ouvre le rapport fictif")
        XCTAssertEqual(vc.file().first?.etat, .enAttenteRelecture)
        XCTAssertNil(vc.texteExecutable(id: id), "jamais exécutable avant relecture explicite")
        XCTAssertTrue(vc.validerTour(id: id))
        XCTAssertEqual(vc.texteExecutable(id: id), "ouvre le rapport fictif")
        XCTAssertTrue(vc.marquerExecute(id: id))
    }

    /// CHANTIER 3-A : barge-in par mot-clé et par bouton = même fonction.
    func testVoixConversationBargeIn() {
        XCTAssertEqual(VoixConversation.motDeclencheur("Nova stop, attends"), "stop")
        XCTAssertNil(VoixConversation.motDeclencheur("continue s'il te plaît"))
        let vc = VoixConversation()
        XCTAssertNil(vc.interrompre())
        let nid = vc.demarrerTourNova(texte: "Je commence une longue réponse…")
        XCTAssertEqual(vc.interrompre(), nid)
        XCTAssertEqual(vc.file().first?.etat, .interrompu)
    }

    /// 27/10 : porte de relecture voix — validation/annulation reconnues, correction libre,
    /// et le tour en attente se rattache à son fil (jamais d'exécution sans validation).
    func testVoixConversationPorteChat() {
        XCTAssertTrue(VoixConversation.estValidation("valide"))
        XCTAssertTrue(VoixConversation.estValidation("Go !"))
        XCTAssertFalse(VoixConversation.estValidation("valide mon rapport et envoie-le à Fatou"))
        XCTAssertTrue(VoixConversation.estAnnulation("annule"))
        XCTAssertTrue(VoixConversation.estAnnulation("laisse tomber"))
        XCTAssertFalse(VoixConversation.estAnnulation("annule le vol de demain et réserve le suivant"))
        let vc = VoixConversation()
        let d = vc.demarrerTour(actif: true)
        XCTAssertNotNil(d.id)
        vc.cloreTourUtilisateur(id: d.id!, texteFinal: "envoie le rapport à Fatou")
        vc.lierConversation(id: d.id!, cid: "fil-test")
        XCTAssertNil(vc.texteExecutable(id: d.id!))
        XCTAssertEqual(vc.tourEnAttente(cid: "fil-test")?.texteFinal, "envoie le rapport à Fatou")
        XCTAssertTrue(vc.validerTour(id: d.id!))
        XCTAssertEqual(vc.texteExecutable(id: d.id!), "envoie le rapport à Fatou")
    }

    /// 27/10 (retour d'Ahadi) : le flux ne répète jamais deux fois de suite la même
    /// phrase de reprise ; le texte différent et la fin de phrase passent toujours.
    func testStreamDedupAntiRepetition() {
        let d = StreamDedup()
        var out = ""
        out += d.push("Je m'en occupe, je lance la recherche maintenant. ")
        out += d.push("Je m'en occupe, je lance la recherche maintenant. ")
        out += d.push("Voici le résultat concret de la recherche menée. ")
        out += d.push("Je m'en occupe, je lance la recherche maintenant. ")
        out += d.flush()
        XCTAssertEqual(out.components(separatedBy: "Je m'en occupe").count - 1, 2)
        XCTAssertTrue(out.contains("Voici le résultat concret"))
        // Frein anti-boucle : les variantes « Je corrige… » sont plafonnées à 2 par amorce.
        let d3 = StreamDedup()
        var out3 = ""
        for p in ["Je corrige. ", "Je corrige ça. ", "Je corrige. ", "Je corrige ça — je vérifie. ", "Voici le résultat final de l'action demandée. "] { out3 += d3.push(p) }
        out3 += d3.flush()
        XCTAssertEqual(out3.components(separatedBy: "Je corrige").count - 1, 2)
        XCTAssertTrue(out3.contains("Voici le résultat final"))
        // Morceaux token par token : la phrase ne se reconstitue qu'une fois.
        let d2 = StreamDedup()
        var out2 = ""
        for chunk in ["Je véri", "fie les chiffres un par un. ", "Je véri", "fie les chiffres un par un. "] { out2 += d2.push(chunk) }
        out2 += d2.flush()
        XCTAssertEqual(out2.components(separatedBy: "Je vérifie").count - 1, 1)
    }

    func testPriseEnMainFormulationsEtContexte() {
        // Les formulations naturelles d'Ahadi autorisent la prise en main (avant : seul « devant moi »).
        XCTAssertTrue(Tools.match(Tools.askFrontRx, "je suis coincé sur cette page, prends la main et continue"))
        XCTAssertTrue(Tools.match(Tools.askFrontRx, "Nova, contrôle l'écran et remplis ce formulaire"))
        XCTAssertTrue(Tools.match(Tools.askFrontRx, "continue à ma place"))
        XCTAssertFalse(Tools.match(Tools.askFrontRx, "que dit l'article sur cette page web ?"))
        XCTAssertFalse(Tools.match(Tools.askFrontRx, "lis mes mails en arrière-plan"))
        // Ordre d'envoi du tour : « envoie » débloque mail_envoyer, pas une demande de rédaction.
        XCTAssertTrue(Tools.match(Tools.askSendRx, "envoie-le maintenant"))
        XCTAssertTrue(Tools.match(Tools.askSendRx, "vas-y, envoie le mail à Fatou"))
        XCTAssertFalse(Tools.match(Tools.askSendRx, "prépare un brouillon pour Fatou"))
        XCTAssertFalse(Tools.match(Tools.askSendRx, "envoie-moi le résumé ici"))
        // Le bloc contexte nomme l'endroit mesuré et la consigne de lecture d'écran.
        let bloc = NovaApp.liveContextBlock(ecran: "Livrables")
        XCTAssertTrue(bloc.contains("CONTEXTE TEMPS RÉEL"))
        XCTAssertTrue(bloc.contains("Livrables"))
        XCTAssertTrue(bloc.contains("prends la main"))
    }

    func testCocheCourrierLibreVsCafu() {
        // 27/10 (cas vécu, plateforme anonymisée) : un mail externe EN validé tel quel ne doit plus être
        // bloqué par le gabarit CAFU (boucle « Action en dernier + opt-out » ×5).
        let libre: [String: Any] = ["channel": "mail", "to": "account-review@example.org",
            "subject": "Request for human review - Case 00000000",
            "body": "Dear Example Review Team, I hope you're well. 01 Account concerned — holder Exemple TITULAIRE, Case 00000000. 02 Action required — Please confirm reactivation. If this does not suit you, please let me know and I will adapt. Best, Ahadi"]
        XCTAssertTrue(DraftLint.hardFailures(libre).isEmpty, "courrier libre bloqué : \(DraftLint.hardFailures(libre).map { $0.label })")
        // Un mail CAFU revendiqué (objet « - CAFU ») reste soumis au gabarit dur complet.
        var cafu = libre
        cafu["subject"] = "[EXEMPLE CASE 00000000] - CAFU - Request human review"
        XCTAssertFalse(DraftLint.hardFailures(cafu).isEmpty, "le gabarit CAFU doit rester bloquant quand il est revendiqué")
        // L'opt-out anglais attesté est reconnu.
        XCTAssertTrue(DraftLint.hasOptOut("If this does not suit you, please let me know and I will adapt."))
    }

    func testFiletSortieAnnonceSansLivraison() {
        // Audit qualité 24 h (G2/G3) : les annonces pures déclenchent la continuation.
        XCTAssertTrue(DeliveryGate.needsContinuation(answer: "Je lance l'analyse BRVM du jour et je te reviens tout de suite.", ask: "analyse mes cours BRVM du jour en détail"))
        XCTAssertTrue(DeliveryGate.needsContinuation(answer: "Je m'en occupe.", ask: "prépare la note de synthèse complète pour Fatou"))
        // Une vraie livraison, même courte et structurée, ne déclenche rien.
        XCTAssertFalse(DeliveryGate.needsContinuation(answer: "Fait :\n- point un\n- point deux", ask: "prépare la note de synthèse complète pour Fatou"))
        XCTAssertFalse(DeliveryGate.needsContinuation(answer: "Voici le résultat complet et détaillé du calcul demandé, avec les trois chiffres vérifiés un par un et leurs sources citées ligne par ligne pour chaque poste du tableau récapitulatif final joint.", ask: "calcule le total du tableau"))
        // Salutation / demande triviale : pas de filet.
        XCTAssertFalse(DeliveryGate.needsContinuation(answer: "Je vais bien, merci.", ask: "bonjour ça va"))
        // 01/11 (chat abouti) : « ok » est un ACCORD, plus une salutation — « Je te reviens. » sans rien faire déclenche la continuation.
        XCTAssertTrue(DeliveryGate.needsContinuation(answer: "Je te reviens.", ask: "ok"))
        // 28/10 (retour Ahadi) : demande d'action d'UN mot — le cas réel qui passait.
        XCTAssertTrue(DeliveryGate.needsContinuation(answer: "Je m'en occupe.\n\nJe m'en occupe — transcription du fichier repéré.", ask: "Transcription"))
        XCTAssertTrue(DeliveryGate.needsContinuation(answer: "Je te l'envoie sur ton téléphone.", ask: "telephone"))
        // Mais un accusé à un mot qui n'est pas une action ne déclenche rien,
        // et une annonce APRÈS de vrais outils non plus (le travail existe).
        XCTAssertFalse(DeliveryGate.needsContinuation(answer: "Noté.", ask: "ok"))
        // 01/11 (chat abouti) : une réponse qui FINIT sur la promesse après des outils n'est pas un livrable — continuation unique.
        XCTAssertTrue(DeliveryGate.needsContinuation(answer: "Je m'en occupe.", ask: "Transcription", toolCount: 3))
        XCTAssertFalse(DeliveryGate.needsContinuation(answer: "Transcription faite : 12 minutes, 3 intervenants, texte joint ci-dessous.", ask: "Transcription", toolCount: 3))
        // Demande courte sans promesse dans la réponse : rien à continuer.
        XCTAssertFalse(DeliveryGate.needsContinuation(answer: "Voici la transcription complète du fichier, relue et ponctuée.", ask: "Transcription"))
    }

    // 31/10 (compétences) : sélection des skills joints au suffixe dynamique — score pondéré,
    // posture exclue, skill nommé en tête, budget total respecté (fonctions pures, sans disque).
    func testSkillsRankingAndBudget() {
        let list: [NovaSkills.Entry] = [
            NovaSkills.Entry(name: "analyse-brvm", title: "Analyse BRVM", trigger: "cours BRVM, portefeuille, dividendes, rendement des actions", summary: "Méthode d'analyse des titres de la bourse régionale"),
            NovaSkills.Entry(name: "redaction-mail", title: "Rédaction de mails", trigger: "rédiger un email, courriel professionnel, réponse polie", summary: "Ton, structure et relecture d'un email"),
            NovaSkills.Entry(name: "revue-code", title: "Revue de code", trigger: "relire du code Swift, audit, bug, régression", summary: "Checklist de relecture de code"),
            NovaSkills.Entry(name: "zero-echec", title: "Zéro échec", trigger: "cours BRVM dividendes portefeuille", summary: "posture")
        ]
        // Correspondance par le contenu : le bon skill en tête, la posture jamais jointe.
        let r1 = NovaSkills.rank(message: "Analyse mes cours BRVM et les dividendes du portefeuille", among: list)
        XCTAssertEqual(r1.first?.entry.name, "analyse-brvm")
        XCTAssertFalse(r1.contains { $0.entry.name == "zero-echec" })
        XCTAssertFalse(r1.contains { $0.entry.name == "redaction-mail" })
        // Message banal : aucun skill.
        XCTAssertTrue(NovaSkills.rank(message: "Bonjour, ça va ?", among: list).isEmpty)
        XCTAssertTrue(NovaSkills.rank(message: "merci pour tout, à plus tard", among: list).isEmpty)
        // Skill nommé : toujours premier, même si un autre marque plus de mots.
        let r2 = NovaSkills.rank(message: "Applique revue-code à mes cours BRVM, dividendes et portefeuille", among: list)
        XCTAssertEqual(r2.first?.entry.name, "revue-code")
        XCTAssertEqual(r2.first?.explicit, true)
        // Budget : 3 skills longs tiennent dans 4 000 car., tronqués avec renvoi à l'outil « skill ».
        let body: String = String(repeating: "ligne de méthode assez longue pour remplir le skill\n", count: 150)
        let three: [NovaSkills.Ranked] = [
            NovaSkills.Ranked(entry: list[0], score: 10, explicit: false),
            NovaSkills.Ranked(entry: list[1], score: 8, explicit: false),
            NovaSkills.Ranked(entry: list[2], score: 6, explicit: false)
        ]
        let block = NovaSkills.assemble(three, maxCount: 3, budget: 4000, content: { (_: String) -> String? in body })
        XCTAssertLessThanOrEqual(block.count, 4000)
        XCTAssertEqual(block.components(separatedBy: "SKILL JOINT « ").count - 1, 3)
        XCTAssertTrue(block.contains("suite disponible sur demande"))
        // Plafond de nombre respecté.
        let two = NovaSkills.assemble(three, maxCount: 2, budget: 4000, content: { (_: String) -> String? in body })
        XCTAssertEqual(two.components(separatedBy: "SKILL JOINT « ").count - 1, 2)
        // Skill nommé en tête : joint même au-delà du budget, son en-tête conservé.
        let named = NovaSkills.assemble(r2, maxCount: 3, budget: 4000, content: { (_: String) -> String? in body })
        XCTAssertTrue(named.hasPrefix("SKILL JOINT « revue-code »"))
        XCTAssertTrue(named.contains("ligne de méthode"))
        // Court contenu : rendu intact, sans marque de troncature.
        XCTAssertEqual(NovaSkills.clip("court", cap: 4000, name: "x"), "court")
    }
}
