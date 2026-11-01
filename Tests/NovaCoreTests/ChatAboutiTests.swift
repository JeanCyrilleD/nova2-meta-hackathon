import XCTest
@testable import NovaCore

/// 01/11 (chat abouti) — trois plaintes d'Ahadi, prouvées dans releves/diag (cerveaux_journal_fin.jsonl, depenses.json du 01/11) :
/// 1) « il s'arrête en quelques phrases pour dire budget atteint » ; 2) silence après « Approuver » ou après « je vais le faire » ;
/// 3) vitesse. Tout est simulé : aucun réseau, aucune clé, grand livre SQLite temporaire, prix lus dans Config/*.json du dépôt.
final class ChatAboutiTests: XCTestCase {

    static var configDir: String {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Config").path
    }
    static var sourcesDir: String {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Sources/NovaCore").path
    }
    func book() throws -> PriceBook { PriceBook(registry: try XCTUnwrap(BrainRegistry.load(configDir: ChatAboutiTests.configDir))) }
    func spec(_ id: String) throws -> BrainSpec { try XCTUnwrap(Catalog.defaults().first { $0.id == id }, id) }
    let now: Date = ISO8601DateFormatter().date(from: "2026-11-04T07:30:00Z")!
    func caps(month: Micros) -> CostLedger.Caps { CostLedger.Caps(monthHard: month, dayForeground: month, dayBackground: month, perTask: Int64.max / 4, dayBench: month) }
    func tmpLedger() throws -> (CostLedger, String) {
        let p = NSTemporaryDirectory() + "nova-chat-abouti-" + UUID().uuidString + ".sqlite"
        return (try XCTUnwrap(CostLedger(path: p)), p)
    }
    func cleanup(_ p: String) { for s in ["", "-wal", "-shm"] { try? FileManager.default.removeItem(atPath: p + s) } }
    func seed(_ led: CostLedger, _ amount: Micros) throws {
        let id = try XCTUnwrap(led.reserve(task: "seed-\(UUID().uuidString)", lane: .foreground, brain: "x", profile: "seed", dataClass: .personal,
                                           estimate: amount, caps: caps(month: 1_000_000_000), now: now).id)
        led.settle(id, usage: Usage(input: 1, output: 1), cost: amount, now: now)
    }

    // MARK: 1) Budget

    /// Cause racine n° 1 : cache lu de Spark 1.3 facturé au prix plein (grille historique sans tarif cache + « le plus cher des deux »).
    func testSparkCacheReadPricedAtPublishedRate() throws {
        let bk = try book()
        let b = bk.billing(try spec("spark-1.3"))
        XCTAssertEqual(bk.cost(b, usage: Usage(cacheRead: 1_000_000)), 150_000, "cache lu Spark 1.3 : 0,15 $ par M (registre), pas 1,25 $")
        XCTAssertEqual(bk.cost(b, usage: Usage(input: 1_000_000, output: 1_000_000)), 5_500_000, "entrée / sortie inchangées : 1,25 + 4,25 $")
        XCTAssertEqual(bk.cost(bk.billing(try spec("wonder-1.0")), usage: Usage(cacheRead: 1_000_000)), 200_000)
        // Rejeu du 01/11 (depenses.json) : 1 391 220 jetons de cache lus par Spark 1.3 → 1,74 $ comptés avant, 0,21 $ maintenant.
        let c = bk.cost(b, usage: Usage(cacheRead: 1_391_220))
        XCTAssertEqual(Double(c) / 1e6, 0.2087, accuracy: 0.001)
    }

    /// Réservation au coût réaliste (Meta) MAIS pire cas exigé sous le plafond dur : la protection ne recule pas d'un micro-dollar.
    func testRealisticReservationKeepsWorstCaseUnderHardCap() throws {
        let (led, p) = try tmpLedger(); defer { cleanup(p) }
        let bk = try book(); let sp = try spec("spark-1.3")
        XCTAssertTrue(Router.reservesRealistic(sp))
        XCTAssertFalse(Router.reservesRealistic(try spec("spark-open-baseten")), "usage non garanti hors api.meta.ai : pire cas réservé comme avant")
        XCTAssertFalse(Router.reservesRealistic(BrainSpec(id: "tiers-test", label: "Tiers (fictif)", kind: .chat, baseURL: "https://llm.example.org/v1/chat/completions", model: "tiers-model-1", keys: KeyChain([]), tags: [])), "cerveau tiers fictif : pire cas réservé")
        let realistic: Micros = SpendPolicy.estimate(book: bk, billing: bk.billing(sp), estIn: 30_000, maxOut: 4000)
        let worst: Micros = SpendPolicy.estimate(book: bk, billing: bk.billing(sp), estIn: 30_000, maxOut: 16_000, calls: 4)
        XCTAssertLessThan(realistic, 60_000, "~0,055 $ réservés pour un appel de chat de 30 000 jetons")
        XCTAssertGreaterThan(worst, 500_000, "ancien pire cas engagé : ~0,54 $")
        // Plafond 1 $, 0,40 $ déjà engagés : le pire cas (0,54 $) tient → envoi, seul le réaliste est immobilisé.
        try seed(led, 400_000)
        let ok = SpendPolicy.preflight(ledger: led, book: bk, spec: sp, estIn: 30_000, maxOut: 4000, calls: 1, lane: .interactive, caps: caps(month: 1_000_000),
                                       worstMaxOut: 16_000, worstCalls: 4, now: now)
        let tk = try XCTUnwrap(ok.ticket)
        XCTAssertEqual(tk.estimate, realistic)
        XCTAssertEqual(led.row(try XCTUnwrap(tk.id))?.reserved, realistic)
        led.settle(tk.id!, usage: Usage(input: 30_000, output: 300), cost: bk.cost(tk.billing, usage: Usage(input: 30_000, output: 300)), now: now)
        // 0,50 $ engagés : le réaliste tiendrait (0,55 $) mais le pire cas non (1,04 $) → REFUS, rien n'est envoyé (échec fermé intact).
        try seed(led, 60_000)
        let r = SpendPolicy.preflight(ledger: led, book: bk, spec: sp, estIn: 30_000, maxOut: 4000, calls: 1, lane: .interactive, caps: caps(month: 1_000_000),
                                      worstMaxOut: 16_000, worstCalls: 4, now: now)
        if case .refused(let why) = r { XCTAssertTrue(why.contains("plafond du mois"), why) } else { XCTFail("le pire cas doit rester sous le plafond dur") }
    }

    /// Plafonds par demande : relevés pour Meta, inchangés ailleurs, « 0 = sans plafond » respecté.
    func testPerTurnCapsForMetaBrains() throws {
        XCTAssertTrue(ChatCaps.isMeta(try spec("spark-1.3")))
        XCTAssertFalse(ChatCaps.isMeta(BrainSpec(id: "tiers-test", label: "Tiers (fictif)", kind: .chat, baseURL: "https://llm.example.org/v1/chat/completions", model: "tiers-model-1", keys: KeyChain([]), tags: [])))
        XCTAssertEqual(ChatCaps.perTurnUSD(base: 0.40, metaSetting: nil, meta: true), 1.50)
        XCTAssertEqual(ChatCaps.perTurnUSD(base: 0.40, metaSetting: nil, meta: false), 0.40)
        XCTAssertEqual(ChatCaps.perTurnUSD(base: 0, metaSetting: nil, meta: true), 0, "sans plafond choisi : inchangé")
        XCTAssertEqual(ChatCaps.perTurnUSD(base: 0.40, metaSetting: 0.80, meta: true), 0.80)
        XCTAssertEqual(ChatCaps.perTurnUSD(base: 2.0, metaSetting: nil, meta: true), 2.0, "jamais plus bas que le réglage général")
        // Rejeu des séquences du 01/11 (03:55:48 : 16 appels ; 03:57:38 : 23 appels de Spark 1.3) : avant 0,64 $ et 0,92 $ comptés > 0,40 $ → coupure ;
        // maintenant 0,34 $ et 0,45 $ (cache au bon tarif) < 1,50 $ → réponse complète.
        let bk = try book(); let b = bk.billing(try spec("spark-1.3"))
        let seq23: Micros = (0..<23).reduce(0) { acc, k in acc + bk.cost(b, usage: k % 2 == 0 ? Usage(input: 30_000, output: 300) : Usage(input: 1_500, cacheRead: 28_500, output: 300)) }
        XCTAssertLessThan(Double(seq23) / 1e6, ChatCaps.perTurnUSD(base: 0.40, metaSetting: nil, meta: true))
        XCTAssertTrue(ChatCaps.finishAllowed(spent: 1.52, cap: 1.50)); XCTAssertFalse(ChatCaps.finishAllowed(spent: 2.30, cap: 1.50))
        XCTAssertTrue(ChatCaps.finishNote(tools: ["web_search"]).contains("plus aucun outil"))
    }

    /// Le chat conclut proprement au plafond et le plafond ne coupe jamais une attente d'approbation (lecture du source de la route).
    func testRouteFinishesCleanlyAndNeverCutsAnApproval() throws {
        let src = try String(contentsOfFile: ChatAboutiTests.sourcesDir + "/App+RoutesChat.swift", encoding: .utf8)
        XCTAssertTrue(src.contains("if Tools.awaitingApproval() { return false }"))
        XCTAssertTrue(src.contains("ChatCaps.finishAllowed(spent: LLMSpend.turnSpent(), cap: capTurn)"))
        XCTAssertTrue(src.contains("useTools: false, maxSteps: 0, ordered: true, cancel: userStop"), "passe de conclusion sans outil, seul Stop l'interrompt")
        XCTAssertTrue(src.contains("ChatCaps.steps(settings: settings, meta: metaTurn)"))
        let router = try String(contentsOfFile: ChatAboutiTests.sourcesDir + "/Router.swift", encoding: .utf8)
        XCTAssertTrue(router.contains("worstMaxOut: realistic ? brainMaxFor(s) : nil, worstCalls: realistic ? calls : nil"))
    }

    // MARK: 2) Silence

    func testConfirmationsAreActionRequests() {
        for q in ["oui", "Ok", "ok vas-y", "D'accord", "Approuvé", "go", "envoie", "Oui, fais-le", "c'est bon", "Valide"] {
            XCTAssertTrue(DeliveryGate.isConfirmation(q), q)
        }
        for q in ["oui mais change l'objet du mail pour mettre la date de vendredi", "bonjour", "merci", "quel temps fait-il ?"] {
            XCTAssertFalse(DeliveryGate.isConfirmation(q), q)
        }
    }

    func testPromiseOnlyAnswerTriggersOneContinuation() {
        // Cas réels de silence : un accord, puis une promesse sans appel d'outil.
        XCTAssertTrue(DeliveryGate.needsContinuation(answer: "Parfait, je m'en occupe.", ask: "oui"))
        XCTAssertTrue(DeliveryGate.needsContinuation(answer: "Je te reviens.", ask: "ok"))
        XCTAssertTrue(DeliveryGate.needsContinuation(answer: "C'est noté.\n\nJe lance maintenant la création du fichier.", ask: "Approuvé"))
        // Après de vrais outils, une fin sur la promesse n'est pas un résultat.
        XCTAssertTrue(DeliveryGate.needsContinuation(answer: "J'ai lu les trois mails.\n\nJe prépare maintenant le brouillon de réponse.", ask: "réponds au mail de Fatou", toolCount: 2))
        // Rien à continuer : livraison réelle, simple accusé, attente explicite d'Ahadi, question.
        XCTAssertFalse(DeliveryGate.needsContinuation(answer: "Voici le résumé : trois mails, dont un urgent de Fatou (rapport GHO).", ask: "résume mes mails", toolCount: 1))
        XCTAssertFalse(DeliveryGate.needsContinuation(answer: "Noté.", ask: "ok"))
        XCTAssertFalse(DeliveryGate.needsContinuation(answer: "Le brouillon est prêt. Je l'envoie dès que tu confirmes.", ask: "prépare la réponse à Fatou", toolCount: 1))
        XCTAssertFalse(DeliveryGate.endsOnPromise("Je t'envoie le mail ?"))
        XCTAssertFalse(DeliveryGate.endsOnPromise("Fait : fichier créé et vérifié."))
        XCTAssertTrue(DeliveryGate.endsOnPromise("Fichier lu. Je corrige la section 2."))
        XCTAssertTrue(DeliveryGate.unfinishedNote.contains("pas encore été faite"))
    }

    /// Un « Approuver » cliqué avant l'inscription de l'attente n'est plus perdu (avant : attente jusqu'au délai, puis « refusé »).
    func testEarlyApprovalIsNotLost() {
        let id = "t-" + UUID().uuidString.prefix(6).lowercased()
        Tools.signalConfirm(id, ok: true)
        let t0 = Date()
        let r = Tools.waitConfirmDetailed(id, cancel: { false }, announce: {})
        XCTAssertTrue(r.answered); XCTAssertTrue(r.ok)
        XCTAssertLessThan(Date().timeIntervalSince(t0), 0.5)
    }

    /// Pendant l'attente d'une carte, un plafond franchi ne coupe pas : l'approbation arrive et l'action reprend. « Stop » coupe toujours.
    func testApprovalWaitIgnoresTurnCapButNotStop() {
        var userStopped = false
        let capReached = true
        let stopCheck: () -> Bool = { if userStopped { return true }; if Tools.awaitingApproval() { return false }; return capReached }
        let id = "t-" + UUID().uuidString.prefix(6).lowercased()
        DispatchQueue.global().asyncAfter(deadline: .now() + 0.7) { Tools.signalConfirm(id, ok: true) }
        let r = Tools.waitConfirmDetailed(id, cancel: stopCheck, announce: {})
        XCTAssertTrue(r.answered, "le plafond franchi ne doit pas abandonner l'attente"); XCTAssertTrue(r.ok)
        XCTAssertFalse(Tools.awaitingApproval(), "marqueur retiré après l'attente")
        XCTAssertTrue(stopCheck(), "hors attente, le plafond reprend ses droits")
        userStopped = true
        let id2 = "t-" + UUID().uuidString.prefix(6).lowercased()
        let t0 = Date()
        let r2 = Tools.waitConfirmDetailed(id2, cancel: stopCheck, announce: {})
        XCTAssertFalse(r2.answered); XCTAssertLessThan(Date().timeIntervalSince(t0), 1.5, "Stop interrompt l'attente")
    }

    /// Envoi approuvé : exécuté par le moteur seulement sous les mêmes gardes, et son résultat est toujours dit.
    func testEngineSendGuardsAndReport() {
        XCTAssertTrue(EngineSend.directAllowed(policy: "auto", verdict: "run"))
        XCTAssertFalse(EngineSend.directAllowed(policy: "ask", verdict: "run"), "politique « demander » : la carte reste")
        XCTAssertFalse(EngineSend.directAllowed(policy: "block", verdict: "run"))
        XCTAssertFalse(EngineSend.directAllowed(policy: "auto", verdict: "ask"))
        XCTAssertFalse(EngineSend.directAllowed(policy: "auto", verdict: "refuse"))
        XCTAssertNotNil(EngineSend.missingReport(answer: "Je l'envoie.", result: "Envoyé à fatou@example.org (Mail)."))
        XCTAssertNotNil(EngineSend.missingReport(answer: "", result: "Échec : aucun destinataire valide."))
        XCTAssertNil(EngineSend.missingReport(answer: "C'est envoyé à Fatou.", result: "Envoyé à fatou@example.org (Mail)."))
        XCTAssertTrue(EngineSend.reportNote(result: "Envoyé.").contains("N'appelle PAS mail_envoyer"))
        let src = (try? String(contentsOfFile: ChatAboutiTests.sourcesDir + "/App+RoutesChat.swift", encoding: .utf8)) ?? ""
        XCTAssertTrue(src.contains("EngineSend.directAllowed(policy: Tools.policy(for: \"mail_envoyer\")"))
    }

    // MARK: 3) Vitesse

    /// Protocole texte (Spark) : plusieurs lectures pures d'une même génération partent ensemble ; une écriture garde le chemin unitaire.
    func testParallelTextToolCalls() {
        let two = "<tool name=\"web_search\">cours BRVM TITRE A (fictif)</tool><tool name=\"know\">dividende TITRE A (fictif)</tool>"
        XCTAssertEqual(Agent.parallelTextCalls(two)?.map { $0.name }, ["web_search", "know"])
        XCTAssertNil(Agent.parallelTextCalls("<tool name=\"web_search\">x</tool>"))
        XCTAssertNil(Agent.parallelTextCalls("<tool name=\"web_search\">x</tool><tool name=\"write_file\">{}</tool>"), "écriture : jamais en parallèle")
        XCTAssertNil(Agent.parallelTextCalls("<tool name=\"know\">a</tool><tool name=\"know\">a</tool>"), "doublon : un seul appel")
    }
}
