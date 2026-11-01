import XCTest
@testable import NovaCore

/// PHASE 3 — agents à états explicites (AgentsV2.swift). Tous SIMULÉS : exécuteur et garde de coûts factices,
/// stockage en mémoire, aucun réseau, aucun fichier de l'app touché.
final class AgentsV2Tests: XCTestCase {

    final class MockExec: AgentToolExecutor {
        var calls: [String] = []
        var effects: [String: AgentToolResult] = [:]   // état « réel » simulé, par clé d'idempotence
        var interruptOnce: Set<String> = []            // outils qui produisent l'effet PUIS s'interrompent
        var failTools: Set<String> = []
        var withReceipts = true
        var cost: Int64? = nil
        func execute(tool: String, arg: String, idempotencyKey: String) throws -> AgentToolResult {
            calls.append(tool)
            if failTools.contains(tool) { return AgentToolResult(ok: false, output: "échec simulé", receipt: nil, costMicros: cost) }
            let r = AgentToolResult(ok: true, output: "ok \(tool)", receipt: withReceipts ? "rcpt-\(tool)-\(calls.count)" : nil, costMicros: cost)
            effects[idempotencyKey] = r
            if interruptOnce.remove(tool) != nil { throw AgentInterrupted() }
            return r
        }
        func lookup(idempotencyKey: String) -> AgentToolResult? { effects[idempotencyKey] }
        func count(_ tool: String) -> Int { calls.filter { $0 == tool }.count }
    }

    final class OpenGate: AgentCostGate {
        var reserved: Int64 = 0
        var settledUnknown = 0
        func reserve(taskId: String, profile: AgentRoutingProfile, dataClass: AgentDataClass, estimateMicros: Int64) -> AgentReservation? {
            reserved += estimateMicros
            return AgentReservation(id: UUID().uuidString, micros: estimateMicros)
        }
        func settle(_ reservation: AgentReservation, actualMicros: Int64?) { if actualMicros == nil { settledUnknown += 1 } }
    }

    final class Clock { var t = Date(timeIntervalSince1970: 1_800_000_000) }

    func engine(_ x: MockExec, store: AgentTaskStore = MemoryAgentTaskStore(), gate: AgentCostGate = OpenGate(), clock: Clock? = nil) -> AgentEngine {
        if let c = clock { return AgentEngine(store: store, costGate: gate, executor: x, now: { c.t }) }
        return AgentEngine(store: store, costGate: gate, executor: x)
    }

    func testSha256KnownVector() {
        XCTAssertEqual(AgentsV2.sha256("abc"), "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad")
        XCTAssertEqual(AgentsV2.sha256(""), "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855")
    }

    func testForbiddenTransitionsRefused() throws {
        for s in [AgentState.done, .failed, .cancelled] {
            XCTAssertTrue(s.isTerminal)
            for n in AgentState.allCases { XCTAssertFalse(s.canMove(to: n), "\(s) → \(n) doit être refusé") }
        }
        XCTAssertFalse(AgentState.draft.canMove(to: .done))
        XCTAssertFalse(AgentState.draft.canMove(to: .verifying))
        XCTAssertFalse(AgentState.awaitingApproval.canMove(to: .done))
        XCTAssertFalse(AgentState.running.canMove(to: .done), "done passe obligatoirement par verifying")
        let x = MockExec(); let e = engine(x)
        let t = try e.create(agent: "research", inputClasses: [.publicData], content: "q", steps: [("web_search", "q", 0)])
        XCTAssertThrowsError(try e.move(t.id, to: .done, why: "test")) { err in
            XCTAssertEqual(err as? AgentError, .forbiddenTransition("draft", "done"))
        }
        try e.cancel(t.id)
        XCTAssertThrowsError(try e.move(t.id, to: .running, why: "test"))
        XCTAssertThrowsError(try e.run(t.id))
        XCTAssertEqual(x.calls.count, 0)
        XCTAssertEqual(e.task(t.id)?.state, .cancelled)
    }

    func testDoneWithoutReceiptRefused() throws {
        let x = MockExec(); x.withReceipts = false
        let e = engine(x)
        let t = try e.create(agent: "research", inputClasses: [.publicData], content: "q", steps: [("web_search", "sahel", 0)])
        let r = try e.run(t.id)
        XCTAssertEqual(r.state, .unknown, "sans reçu d'outil, jamais done")
        XCTAssertEqual(x.calls, ["web_search"])
        try e.move(t.id, to: .verifying, why: "test")
        XCTAssertThrowsError(try e.move(t.id, to: .done, why: "test")) { err in XCTAssertEqual(err as? AgentError, .receiptMissing) }
        // Avec reçu : done.
        let x2 = MockExec(); let e2 = engine(x2)
        let t2 = try e2.create(agent: "research", inputClasses: [.publicData], content: "q", steps: [("web_search", "sahel", 0)])
        XCTAssertEqual(try e2.run(t2.id).state, .done)
        XCTAssertEqual(e2.task(t2.id)?.steps.first?.receipt?.isEmpty, false)
    }

    func testMailNeverSendsWithoutApproval() throws {
        let x = MockExec(); let e = engine(x)
        let t = try e.create(agent: "mail", inputClasses: [.personal], content: "À: awa@example.org\nBonjour Awa,\nmerci.",
                             steps: [("mail_brouillon", "d1", 0), ("mail_envoyer", "d1", 0)])
        XCTAssertEqual(try e.run(t.id).state, .awaitingApproval)
        XCTAssertThrowsError(try e.run(t.id)) { err in XCTAssertEqual(err as? AgentError, .approvalMismatch) }
        XCTAssertEqual(x.count("mail_envoyer"), 0)
    }

    func testApprovalVoidedWhenContentChangesByOneByte() throws {
        let x = MockExec(); let e = engine(x)
        let original = "À: awa@example.org\nBonjour Awa,\nmerci."
        let t = try e.create(agent: "mail", inputClasses: [.personal], content: original,
                             steps: [("mail_brouillon", "d1", 0), ("mail_envoyer", "d1", 0)])
        _ = try e.run(t.id)
        let shown = e.task(t.id)!.contentSha
        try e.approve(t.id, shownSha: shown)
        XCTAssertTrue(e.task(t.id)!.approvalValid)
        try e.updateContent(t.id, "À: awa@example.org\nBonjour Awa,\nmerci!")   // un seul octet change ('.' → '!')
        XCTAssertFalse(e.task(t.id)!.approvalValid, "un octet changé annule l'approbation")
        XCTAssertNil(e.task(t.id)!.approvalSha)
        XCTAssertThrowsError(try e.run(t.id))
        XCTAssertThrowsError(try e.approve(t.id, shownSha: shown)) { err in XCTAssertEqual(err as? AgentError, .approvalMismatch) }
        XCTAssertEqual(x.count("mail_envoyer"), 0)
        try e.approve(t.id, shownSha: e.task(t.id)!.contentSha)
        XCTAssertEqual(try e.run(t.id).state, .done)
        XCTAssertEqual(x.count("mail_envoyer"), 1)
    }

    func testResumeIsIdempotentNoDoubleSend() throws {
        let store = MemoryAgentTaskStore(); let gate = OpenGate()
        let x = MockExec(); x.interruptOnce = ["mail_envoyer"]; x.cost = 0   // usage rapporté pour les étapes normales
        let e = engine(x, store: store, gate: gate)
        let t = try e.create(agent: "mail", inputClasses: [.personal], content: "corps",
                             steps: [("mail_brouillon", "d1", 0), ("mail_envoyer", "d1", 0)])
        _ = try e.run(t.id)
        try e.approve(t.id, shownSha: e.task(t.id)!.contentSha)
        let r1 = try e.run(t.id)
        XCTAssertEqual(r1.state, .unknown, "interruption pendant l'envoi : état non déterminé")
        XCTAssertEqual(x.count("mail_envoyer"), 1)
        XCTAssertEqual(gate.settledUnknown, 1, "usage absent : réservation gardée")
        // « Redémarrage » : nouveau moteur relu depuis le stockage.
        let e2 = engine(x, store: store, gate: gate)
        XCTAssertEqual(e2.task(t.id)?.steps[1].status, .started)
        let r2 = try e2.run(t.id)
        XCTAssertEqual(r2.state, .done)
        XCTAssertEqual(x.count("mail_envoyer"), 1, "reprise : rapprochement de l'état réel, aucun double envoi")
        XCTAssertEqual(x.count("mail_brouillon"), 1)
        XCTAssertEqual(r2.steps[1].receipt, "rcpt-mail_envoyer-2")
        // Une étape « started » SANS effet réel est, elle, rejouée une fois.
        let x3 = MockExec(); let s3 = MemoryAgentTaskStore()
        let e3 = engine(x3, store: s3)
        let t3 = try e3.create(agent: "research", inputClasses: [.publicData], content: "q", steps: [("web_fetch", "u", 0)])
        var tt = e3.task(t3.id)!; tt.state = .running; tt.steps[0].status = .started
        s3.save([t3.id: tt])
        let e4 = engine(x3, store: s3)
        XCTAssertEqual(try e4.run(t3.id).state, .done)
        XCTAssertEqual(x3.count("web_fetch"), 1)
    }

    func testAgentCapRespected() throws {
        for s in AgentsV2.specs.values { XCTAssertLessThanOrEqual(s.capMicros, AgentsV2.maxCapMicros, s.id) }
        XCTAssertEqual(AgentsV2.specs.count, 8)
        let x = MockExec(); let e = engine(x)
        XCTAssertThrowsError(try e.create(agent: "mail", inputClasses: [.personal], content: "c",
                                          steps: [("mail_brouillon", "a", 200_000), ("mail_envoyer", "a", 200_000)])) { err in
            XCTAssertEqual(err as? AgentError, .capExceeded(400_000))
        }
        // Coût réel supérieur à l'estimation : le moteur s'arrête avant de dépasser le plafond (research = 0,50 $).
        x.cost = 250_000
        let t = try e.create(agent: "research", inputClasses: [.publicData], content: "q",
                             steps: [("web_search", "a", 150_000), ("web_search", "b", 150_000), ("web_search", "c", 150_000)])
        let r = try e.run(t.id)
        XCTAssertEqual(r.state, .failed)
        XCTAssertEqual(x.calls.count, 2)
        XCTAssertEqual(r.spentMicros, 500_000)
        XCTAssertTrue(r.reason.contains("plafond"))
    }

    func testCostGateFailsClosedByDefault() throws {
        let x = MockExec(); let e = engine(x, gate: DenyAllCostGate())
        let t = try e.create(agent: "research", inputClasses: [.publicData], content: "q", steps: [("web_search", "a", 1)])
        let r = try e.run(t.id)
        XCTAssertEqual(r.state, .failed)
        XCTAssertEqual(x.calls.count, 0)
    }

    func testWhitelistScopeDeadlineAndRetries() throws {
        let x = MockExec(); let c = Clock(); let e = engine(x, clock: c)
        XCTAssertThrowsError(try e.create(agent: "research", inputClasses: [.publicData], content: "q", steps: [("mail_envoyer", "a", 0)])) { err in
            XCTAssertEqual(err as? AgentError, .toolNotAllowed("mail_envoyer"))
        }
        XCTAssertThrowsError(try e.create(agent: "coder", inputClasses: [.publicData, .personal], content: "q", steps: [])) { err in
            XCTAssertEqual(err as? AgentError, .dataClassOutOfScope("personal"))
        }
        XCTAssertThrowsError(try e.create(agent: "triage", inputClasses: [.vault], content: "q", steps: []))
        XCTAssertEqual(AgentDataClass.strictest([nil]), .personal)
        XCTAssertEqual(AgentDataClass.strictest([.publicData, .sciInternal, .personal]), .sciInternal)
        // Échéance.
        let t = try e.create(agent: "voice", inputClasses: [.publicData], content: "Bonjour", steps: [("audio_cache", "k", 0)])
        c.t = c.t.addingTimeInterval(301)
        XCTAssertEqual(try e.run(t.id).state, .failed)
        XCTAssertEqual(x.calls.count, 0)
        // Relances bornées (research : 2 relances → 3 tentatives).
        x.failTools = ["web_fetch"]
        let t2 = try e.create(agent: "research", inputClasses: [.publicData], content: "q", steps: [("web_fetch", "u", 0)])
        XCTAssertEqual(try e.run(t2.id).state, .failed)
        XCTAssertEqual(x.count("web_fetch"), 3)
    }

    func testBriefClaimsSourcedOrUnavailable() {
        var b = AgentBrief()
        b.facts = [AgentClaim("Crue au Niger", source: "https://reliefweb.int/x"), AgentClaim("Rumeur", source: nil)]
        b.hypotheses = [AgentClaim("Déplacements possibles", source: "  ")]
        let out = b.render()
        XCTAssertTrue(out.contains("Crue au Niger [source : https://reliefweb.int/x]"))
        XCTAssertFalse(out.contains("Rumeur"))
        XCTAssertFalse(out.contains("Déplacements possibles"))
        XCTAssertTrue(out.contains("## Scénarios\n- non disponible"))
        XCTAssertEqual(b.unsourced.count, 2)
        for h in ["## Faits", "## Hypothèses", "## Scénarios", "## Recommandations"] { XCTAssertTrue(out.contains(h)) }
    }

    func testCoderWorkspaceIsolated() {
        XCTAssertTrue(AgentsV2.coderWorkspaceAllowed("/Users/x/spark-local/Nova2-wt/coder1/Sources/A.swift"))
        XCTAssertFalse(AgentsV2.coderWorkspaceAllowed("/Users/x/spark-local/Nova2/Sources/A.swift"))
        XCTAssertFalse(AgentsV2.coderWorkspaceAllowed("/Users/x/spark-local/Nova2-wt/../Nova2/Sources/A.swift"))
        XCTAssertFalse(AgentsV2.coderWorkspaceAllowed("/Users/x/spark-local/Nova2-wt/"))
        XCTAssertFalse(AgentsV2.coderWorkspaceAllowed("relative/Nova2-wt/a"))
    }

    // INTÉGRATION 31/10 : LedgerCostGate réserve dans le grand livre Phase 2 (fichier temporaire, aucun réseau).
    func testLedgerCostGateReservesAgainstPhase2CapsAndKeepsOnSettle() throws {
        let p = NSTemporaryDirectory() + "agents_gate_" + UUID().uuidString + ".sqlite"
        defer { try? FileManager.default.removeItem(atPath: p) }
        let led = try XCTUnwrap(CostLedger(path: p))
        let caps = CostLedger.Caps(monthHard: 1_000_000, dayForeground: 1_000_000, dayBackground: 500_000, perTask: 300_000)
        let gate = LedgerCostGate(ledger: { led }, caps: { caps })
        let r1 = try XCTUnwrap(gate.reserve(taskId: "t1", profile: .main, dataClass: .personal, estimateMicros: 200_000))
        XCTAssertNil(gate.reserve(taskId: "t1", profile: .main, dataClass: .personal, estimateMicros: 200_000), "plafond par tâche")
        XCTAssertEqual(led.committed(task: "agent:t1"), 200_000)
        gate.settle(r1, actualMicros: 10_000)
        XCTAssertEqual(led.state(r1.id), "kept", "sans jetons rapportés, la réservation reste comptée")
        XCTAssertEqual(led.committed(task: "agent:t1"), 200_000)
        XCTAssertNil(LedgerCostGate(ledger: { nil }, caps: { caps }).reserve(taskId: "t2", profile: .main, dataClass: .publicData, estimateMicros: 1), "grand livre absent : échec fermé")
    }
}
