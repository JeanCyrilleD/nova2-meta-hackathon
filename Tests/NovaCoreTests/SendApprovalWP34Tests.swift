import XCTest
@testable import NovaCore

/// WP3 + WP4 — approbation unique liée à l'action exacte, état d'envoi durable et idempotent.
/// TOUT EST SIMULÉ : transports factices (aucun Mail.app, aucun volet Teams, aucun réseau), brouillons en mémoire,
/// registre SQLite dans un dossier temporaire (jamais le dossier de l'app), aucun journal BlackBox écrit.
final class WP34SendApprovalTests: XCTestCase {

    // MARK: doubles

    final class DraftBox: @unchecked Sendable {
        let lock = NSLock()
        var items: [[String: Any]] = []
        func read() -> [[String: Any]] { lock.lock(); defer { lock.unlock() }; return items }
        func update(_ id: String, _ f: [String: Any]) {
            lock.lock(); defer { lock.unlock() }
            guard let k = items.firstIndex(where: { ($0["id"] as? String) == id }) else { return }
            for (a, b) in f { items[k][a] = b }
        }
        func set(_ id: String, _ key: String, _ v: Any) { update(id, [key: v]) }
        func get(_ id: String) -> [String: Any]? { read().first { ($0["id"] as? String) == id } }
    }

    final class MockTransport: SendTransport, @unchecked Sendable {
        let lock = NSLock()
        var outcomes: [TransportOutcome] = []
        var submits: [SendSnapshot] = []
        var delay: TimeInterval = 0
        var during: (() -> Void)? = nil
        func submit(_ s: SendSnapshot, idempotencyKey: String) -> TransportOutcome {
            lock.lock(); submits.append(s); let o = outcomes.isEmpty ? nil : outcomes.removeFirst(); let d = delay; let h = during; lock.unlock()
            if d > 0 { Thread.sleep(forTimeInterval: d) }
            h?()
            return o ?? .submitted(SubmissionEvidence(kind: "mock_send", strength: .transportAccepted, providerMessageId: nil, at: Date()))
        }
        var count: Int { lock.lock(); defer { lock.unlock() }; return submits.count }
    }

    final class MockVerifier: SendVerifier {
        var outcome: VerifyOutcome
        init(_ o: VerifyOutcome) { outcome = o }
        func verify(_ record: SendRecord) -> VerifyOutcome { outcome }
    }

    final class Clock: @unchecked Sendable {
        let lock = NSLock()
        var offset: TimeInterval = 0
        func now() -> Date { lock.lock(); defer { lock.unlock() }; return Date().addingTimeInterval(offset) }
        func advance(_ s: TimeInterval) { lock.lock(); offset += s; lock.unlock() }
    }

    var tmpDirs: [URL] = []
    override func tearDown() {
        for d in tmpDirs { try? FileManager.default.removeItem(at: d) }
        tmpDirs = []
        super.tearDown()
    }

    func tmpDB() -> String {
        let d = FileManager.default.temporaryDirectory.appendingPathComponent("wp34-" + UUID().uuidString)
        try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        tmpDirs.append(d)
        return d.appendingPathComponent("send_ledger.sqlite").path
    }

    func sqliteStore(_ path: String) -> SendRecordStore {
        #if canImport(SQLite3)
        if let s = SQLiteSendStore(path: path) { return s }
        XCTFail("SQLite indisponible")
        #endif
        return MemorySendStore()
    }

    static let mailDraft: [String: Any] = ["id": "d1", "channel": "mail", "to": "awa@example.org", "subject": "Point budget",
                                           "body": "Bonjour Awa,\nVoici le point budget.\nBien à toi", "ts": nowISO(), "status": "à valider"]
    static let teamsDraft: [String: Any] = ["id": "t1", "channel": "teams", "target": "Equipe CAFU", "subject": "",
                                            "body": "Bonjour à tous, la note de cadrage est prête.", "ts": nowISO(), "status": "à valider"]

    struct Rig {
        let svc: SendApprovals
        let box: DraftBox
        let tr: MockTransport
        let clock: Clock
        let hashes: DraftBox
    }

    /// `hashes` : empreintes simulées des pièces jointes (chemin → sha), modifiables pour simuler un fichier changé.
    func rig(store: SendRecordStore? = nil, drafts: [[String: Any]] = [WP34SendApprovalTests.mailDraft], transitions: ((SendRecord, SendState, SendState, String) -> Void)? = nil) -> Rig {
        let box = DraftBox(); box.items = drafts
        let clock = Clock()
        let hashes = DraftBox(); hashes.items = [["id": "/tmp/pj.pdf", "sha": "aaa"]]
        let svc = SendApprovals(store: store ?? MemorySendStore(), now: { clock.now() }, drafts: { box.read() },
                                updateDraft: { id, f in box.update(id, f) },
                                hashFile: { p in
                                    guard let h = hashes.get(p), let sha = h["sha"] as? String else { return nil }
                                    return SendAttachment(name: (p as NSString).lastPathComponent, sha256: sha, bytes: 10)
                                }, onTransition: transitions)
        return Rig(svc: svc, box: box, tr: MockTransport(), clock: clock, hashes: hashes)
    }

    /// Tour 1 : la demande d'envoi est affichée (carte moteur). Tour 2 : Ahadi confirme. Renvoie le contexte du tour 2.
    @discardableResult
    func showAndConfirm(_ r: Rig, draft: String = "d1", cid: String = "conv-A", source: ExecSource = .chat, confirm: String = "envoie") -> ExecContext {
        let t1 = ExecContext(conversationId: cid, source: source)
        XCTAssertEqual(r.svc.noteUserTurn(ctx: t1, text: "prépare le mail pour Awa"), .none)
        let first = r.svc.execute(draftId: draft, ctx: t1, transport: r.tr)
        XCTAssertEqual(first.code, .needsApproval, "un verbe d'envoi DEMANDE l'approbation, il n'autorise rien")
        let card = r.svc.cardsToDisplay(ctx: t1)
        XCTAssertTrue(card.contains("Envoi à approuver"), "la carte exacte est affichée par le moteur")
        let t2 = ExecContext(conversationId: cid, source: source)
        let m = r.svc.noteUserTurn(ctx: t2, text: confirm)
        if case .minted = m {} else { XCTFail("confirmation explicite attendue → approbation, obtenu \(m)") }
        return t2
    }

    // MARK: WP3 — approbation

    func testWP34ExplicitConfirmationSendsWithoutSecondConfirmation() {
        let r = rig()
        let t2 = showAndConfirm(r)
        let res = r.svc.execute(draftId: "d1", ctx: t2, transport: r.tr)
        XCTAssertEqual(res.code, .submitted)
        XCTAssertEqual(r.tr.count, 1)
        XCTAssertEqual(r.tr.submits.first?.recipients, ["awa@example.org"])
        XCTAssertEqual(res.record?.approval?.source, .chat)
        XCTAssertNotNil(res.record?.approval?.consumedAt, "nonce consommé")
        XCTAssertEqual(r.box.get("d1")?["status"] as? String, "envoyé")
        XCTAssertEqual(res.record?.state, .submitted, "soumis ≠ vérifié")
    }

    func testWP34ApprovalInConversationACannotAuthorizeB() {
        let r = rig()
        let t2A = showAndConfirm(r, cid: "conv-A")
        let tB = ExecContext(conversationId: "conv-B", source: .chat)
        XCTAssertEqual(r.svc.noteUserTurn(ctx: tB, text: "envoie"), .none, "aucune carte affichée dans B")
        let resB = r.svc.execute(draftId: "d1", ctx: tB, transport: r.tr)
        XCTAssertEqual(resB.code, .wrongScope)
        XCTAssertEqual(r.tr.count, 0)
        // Un autre tour de la MÊME conversation non plus (approbation liée au tour).
        let t3A = ExecContext(conversationId: "conv-A", source: .chat)
        XCTAssertEqual(r.svc.execute(draftId: "d1", ctx: t3A, transport: r.tr).code, .wrongScope)
        XCTAssertEqual(r.svc.execute(draftId: "d1", ctx: t2A, transport: r.tr).code, .submitted)
        XCTAssertEqual(r.tr.count, 1)
    }

    func testWP34MaterialChangesRequireFreshApproval() {
        let changes: [(String, (DraftBox, DraftBox) -> Void)] = [
            ("destinataire", { b, _ in b.set("d1", "to", "awa@example.org, autre@example.org") }),
            ("corps", { b, _ in b.set("d1", "body", "Bonjour Awa,\nVoici le point budget RÉVISÉ.\nBien à toi") }),
            ("objet", { b, _ in b.set("d1", "subject", "Point budget v2") }),
            ("compte", { b, _ in b.set("d1", "from", "ahadi@autre-compte.org") }),
            ("pièce jointe ajoutée", { b, _ in b.set("d1", "attachments", ["/tmp/pj.pdf"]) }),
        ]
        for (label, mutate) in changes {
            let r = rig()
            let t2 = showAndConfirm(r)
            mutate(r.box, r.hashes)
            let res = r.svc.execute(draftId: "d1", ctx: t2, transport: r.tr)
            XCTAssertEqual(res.code, .needsApproval, "changement de \(label) : nouvelle approbation exigée")
            XCTAssertEqual(r.tr.count, 0, "changement de \(label) : rien n'est parti")
            let states = r.svc.records(draftId: "d1").map { $0.state }
            XCTAssertTrue(states.contains(.cancelled), "\(label) : l'ancienne approbation est annulée")
        }
        // Pièce jointe dont le CONTENU change (même nom) : empreinte différente → nouvelle approbation.
        var d = WP34SendApprovalTests.mailDraft; d["attachments"] = ["/tmp/pj.pdf"]
        let r = rig(drafts: [d])
        let t2 = showAndConfirm(r)
        r.hashes.set("/tmp/pj.pdf", "sha", "bbb")
        XCTAssertEqual(r.svc.execute(draftId: "d1", ctx: t2, transport: r.tr).code, .needsApproval)
        XCTAssertEqual(r.tr.count, 0)
    }

    func testWP34ExpiredOrReusedApprovalFails() {
        // Expirée.
        let r = rig()
        let t2 = showAndConfirm(r)
        r.clock.advance(SendApprovals.approvalTTL + 1)
        XCTAssertEqual(r.svc.execute(draftId: "d1", ctx: t2, transport: r.tr).code, .expired)
        XCTAssertEqual(r.tr.count, 0)
        XCTAssertEqual(r.svc.records(draftId: "d1").last?.state, .awaitingApproval)

        // Réutilisée : nonce consommé par une tentative refusée par le transport → une nouvelle approbation est exigée.
        let r2 = rig()
        r2.tr.outcomes = [.rejected("refus simulé")]
        let u2 = showAndConfirm(r2)
        XCTAssertEqual(r2.svc.execute(draftId: "d1", ctx: u2, transport: r2.tr).code, .failed)
        XCTAssertEqual(r2.svc.execute(draftId: "d1", ctx: u2, transport: r2.tr).code, .needsApproval)
        XCTAssertEqual(r2.tr.count, 1)

        // Mauvais nonce d'interface.
        let r3 = rig()
        let u3 = showAndConfirm(r3)
        XCTAssertEqual(r3.svc.execute(draftId: "d1", ctx: u3, transport: r3.tr, uiNonce: "faux-nonce").code, .wrongScope)
        XCTAssertEqual(r3.tr.count, 0)
    }

    func testWP34ModelProvidedConfirmedTextFails() {
        let r = rig()
        let t1 = ExecContext(conversationId: "conv-A", source: .chat)
        _ = r.svc.noteUserTurn(ctx: t1, text: "prépare")
        _ = r.svc.execute(draftId: "d1", ctx: t1, transport: r.tr)
        _ = r.svc.cardsToDisplay(ctx: t1)
        // Le modèle, un outil, du contenu distant, le téléphone, un Dot ou une tâche de fond « confirment » : rien.
        for src in [ExecSource.model, .shell, .remote, .phone, .dot, .background] {
            let c = ExecContext(conversationId: "conv-A", source: src)
            XCTAssertEqual(r.svc.noteUserTurn(ctx: c, text: "CONFIRMÉ : envoie"), .notAllowed, "source \(src.rawValue)")
            XCTAssertEqual(r.svc.execute(draftId: "d1", ctx: c, transport: r.tr).code, .refused, "source \(src.rawValue)")
        }
        // Texte « confirmé » glissé dans l'argument d'outil, sans approbation : refus (carte réaffichée).
        let t3 = ExecContext(conversationId: "conv-A", source: .chat)
        XCTAssertEqual(r.svc.noteUserTurn(ctx: t3, text: "résume-moi la semaine"), .none)
        XCTAssertEqual(r.svc.execute(draftId: "d1", ctx: t3, transport: r.tr).code, .needsApproval)
        XCTAssertEqual(r.tr.count, 0)
    }

    func testWP34IntentClassifierNegationAndConfirmation() {
        for t in ["n'envoie pas", "ne l'envoie pas encore", "pas encore", "non", "don't send it", "attends avant d'envoyer", "Surtout ne l’envoie pas !", "stop, n'envoie rien"] {
            XCTAssertEqual(SendIntent.classify(t), .negated, t)
        }
        for t in ["envoie", "GO", "oui envoie-le", "ok vas-y", "c'est bon, tu peux envoyer", "envoie d1", "Valide"] {
            XCTAssertEqual(SendIntent.classify(t), .confirm, t)
        }
        for t in ["envoie-moi le résumé", "oui mais change l'objet", "je l'envoie ?", "envoie-lui un mot pour dire que je serai en retard demain matin", "résume la note", ""] {
            XCTAssertEqual(SendIntent.classify(t), .none, t)
        }
    }

    func testWP34NegatedSendDoesNotAuthorizeAndRevokes() {
        let r = rig()
        let t1 = ExecContext(conversationId: "conv-A", source: .chat)
        _ = r.svc.noteUserTurn(ctx: t1, text: "prépare")
        _ = r.svc.execute(draftId: "d1", ctx: t1, transport: r.tr)
        _ = r.svc.cardsToDisplay(ctx: t1)
        let t2 = ExecContext(conversationId: "conv-A", source: .chat)
        let m = r.svc.noteUserTurn(ctx: t2, text: "n'envoie pas")
        if case .negated(let n) = m { XCTAssertGreaterThanOrEqual(n, 1) } else { XCTFail("négation attendue, obtenu \(m)") }
        XCTAssertEqual(r.svc.execute(draftId: "d1", ctx: t2, transport: r.tr).code, .needsApproval)
        // Contre-ordre après approbation : l'approbation tombe.
        let r2 = rig()
        let u2 = showAndConfirm(r2)
        XCTAssertGreaterThanOrEqual(r2.svc.revoke(conversationId: "conv-A", code: "contre-ordre"), 1)
        XCTAssertNotEqual(r2.svc.execute(draftId: "d1", ctx: u2, transport: r2.tr).code, .submitted)
        XCTAssertEqual(r.tr.count + r2.tr.count, 0)
    }

    func testWP34AmbiguousConfirmationApprovesNothing() {
        var d2 = WP34SendApprovalTests.mailDraft; d2["id"] = "d2"; d2["to"] = "moussa@example.org"
        let r = rig(drafts: [WP34SendApprovalTests.mailDraft, d2])
        let t1 = ExecContext(conversationId: "conv-A", source: .chat)
        _ = r.svc.noteUserTurn(ctx: t1, text: "prépare les deux")
        _ = r.svc.execute(draftId: "d1", ctx: t1, transport: r.tr)
        _ = r.svc.execute(draftId: "d2", ctx: t1, transport: r.tr)
        _ = r.svc.cardsToDisplay(ctx: t1)
        let t2 = ExecContext(conversationId: "conv-A", source: .chat)
        if case .ambiguous(let ids) = r.svc.noteUserTurn(ctx: t2, text: "envoie") { XCTAssertEqual(Set(ids), ["d1", "d2"]) } else { XCTFail("ambiguïté attendue") }
        XCTAssertEqual(r.svc.execute(draftId: "d1", ctx: t2, transport: r.tr).code, .needsApproval)
        // Ahadi nomme l'envoi : seul celui-là est approuvé.
        _ = r.svc.cardsToDisplay(ctx: t2)
        let t3 = ExecContext(conversationId: "conv-A", source: .chat)
        XCTAssertEqual(r.svc.noteUserTurn(ctx: t3, text: "envoie d2"), .minted(actionId: r.svc.records(draftId: "d2").last?.actionId ?? "", draftId: "d2"))
        XCTAssertEqual(r.svc.execute(draftId: "d1", ctx: t3, transport: r.tr).code, .needsApproval)
        XCTAssertEqual(r.svc.execute(draftId: "d2", ctx: t3, transport: r.tr).code, .submitted)
        XCTAssertEqual(r.tr.submits.map { $0.draftId }, ["d2"])
    }

    func testWP34DotCannotInheritInteractiveApproval() {
        let r = rig()
        let t2 = showAndConfirm(r)
        let prev = ExecContext.enter(t2)
        defer { ExecContext.restore(prev) }
        // Un Dot lancé depuis le thread de la conversation (Orchestre « dot-run ») a son propre contexte.
        let dotRes: SendResult = ExecContext.with(ExecContext.dot("veille")) {
            r.svc.execute(draftId: "d1", ctx: ExecContext.current, transport: r.tr)
        }
        XCTAssertEqual(dotRes.code, .refused)
        XCTAssertEqual(r.svc.noteUserTurn(ctx: ExecContext.dot("veille"), text: "envoie"), .notAllowed)
        XCTAssertTrue(ExecContext.current === t2, "le contexte de la conversation est rendu après le Dot")
        // Sans contexte (thread de fond) : refus.
        XCTAssertEqual(r.svc.execute(draftId: "d1", ctx: nil, transport: r.tr).code, .refused)
        XCTAssertEqual(r.tr.count, 0)
        XCTAssertEqual(r.svc.execute(draftId: "d1", ctx: ExecContext.current, transport: r.tr).code, .submitted)
    }

    func testWP34FrontWindowIsRunScopedNotGlobal() {
        let outside = Thread.current.threadDictionary["nova.execctx"]
        Thread.current.threadDictionary.removeObject(forKey: "nova.execctx")
        defer { if let o = outside { Thread.current.threadDictionary["nova.execctx"] = o } }
        XCTAssertFalse(Tools.frontAllowed)
        Tools.frontAllowed = true   // sans contexte : sans effet
        XCTAssertFalse(Tools.frontAllowed)
        let chat = ExecContext(conversationId: "conv-A", source: .chat)
        ExecContext.with(chat) {
            Tools.frontAllowed = true
            XCTAssertTrue(Tools.frontAllowed)
            ExecContext.with(ExecContext.dot("veille")) { XCTAssertFalse(Tools.frontAllowed, "un Dot n'hérite pas du « devant moi »") }
            XCTAssertTrue(Tools.frontAllowed)
            XCTAssertEqual(Tools.confirmScope(), "conv:conv-A")
        }
        ExecContext.with(ExecContext(conversationId: "conv-B", source: .chat)) { XCTAssertFalse(Tools.frontAllowed, "autre run : rien hérité") }
        XCTAssertFalse(Tools.frontAllowed)
        XCTAssertEqual(ExecContext.with(ExecContext.dot("veille")) { Tools.confirmScope() }, "dot:veille")
    }

    func testWP34UIChatAndVoiceUseTheSamePolicy() {
        // Chat et voix : même chemin (carte → confirmation → consommation atomique).
        for src in [ExecSource.chat, .voice] {
            let r = rig()
            let t2 = showAndConfirm(r, source: src)
            XCTAssertEqual(r.svc.execute(draftId: "d1", ctx: t2, transport: r.tr).code, .submitted, src.rawValue)
            XCTAssertEqual(r.svc.execute(draftId: "d1", ctx: t2, transport: r.tr).code, .alreadySent, src.rawValue)
            let rc = rig()
            let u2 = showAndConfirm(rc, source: src)
            rc.box.set("d1", "body", "corps modifié")
            XCTAssertEqual(rc.svc.execute(draftId: "d1", ctx: u2, transport: rc.tr).code, .needsApproval, src.rawValue)
            XCTAssertEqual(r.tr.count + rc.tr.count, 1, src.rawValue)
        }
        // Interface : le geste ENVOYER lié par empreinte approuve et consomme dans le MÊME service.
        let r = rig()
        let ui = ExecContext(conversationId: "ui", source: .ui, actor: "Ahadi")
        XCTAssertEqual(r.svc.sendFromUI(draftId: "d1", expectFNV: "faux", ctx: ui, transport: r.tr).code, .changed)
        let fnv = DraftLint.hash(r.box.get("d1") ?? [:])
        XCTAssertEqual(r.svc.sendFromUI(draftId: "d1", expectFNV: fnv, ctx: ExecContext(conversationId: "ui", source: .chat), transport: r.tr).code, .refused)
        let ok = r.svc.sendFromUI(draftId: "d1", expectFNV: fnv, ctx: ui, transport: r.tr)
        XCTAssertEqual(ok.code, .submitted)
        XCTAssertEqual(ok.record?.approval?.source, .ui)
        XCTAssertEqual(r.svc.sendFromUI(draftId: "d1", expectFNV: fnv, ctx: ExecContext(conversationId: "ui", source: .ui), transport: r.tr).code, .alreadySent)
        XCTAssertEqual(r.tr.count, 1)
        // Le snapshot APPROUVÉ fait foi : c'est lui qui est remis au transport.
        XCTAssertEqual(r.tr.submits.first?.sha256, ok.record?.snapshotSha)
    }

    // MARK: WP4 — état durable et idempotence

    func testWP34ConcurrentDuplicateRequestsSendOnce() {
        let path = tmpDB()
        let r = rig(store: sqliteStore(path))
        r.tr.delay = 0.05
        let t2 = showAndConfirm(r)
        // Deux « processus » sur le même registre : deux connexions SQLite indépendantes.
        let other = SendApprovals(store: sqliteStore(path), drafts: { r.box.read() }, updateDraft: { id, f in r.box.update(id, f) })
        let lock = NSLock(); var codes: [SendResult.Code] = []
        DispatchQueue.concurrentPerform(iterations: 12) { i in
            let res = (i % 2 == 0 ? r.svc : other).execute(draftId: "d1", ctx: t2, transport: r.tr)
            lock.lock(); codes.append(res.code); lock.unlock()
        }
        XCTAssertEqual(r.tr.count, 1, "un seul envoi malgré 12 demandes concurrentes")
        XCTAssertEqual(codes.filter { $0 == .submitted }.count, 1)
        XCTAssertTrue(codes.allSatisfy { $0 == .submitted || $0 == .inProgress || $0 == .alreadySent || $0 == .needsApproval }, "\(codes)")
    }

    func testWP34DuplicateImmediatelyAfterCompletionIsRefused() {
        let path = tmpDB()
        let r = rig(store: sqliteStore(path))
        let t2 = showAndConfirm(r)
        XCTAssertEqual(r.svc.execute(draftId: "d1", ctx: t2, transport: r.tr).code, .submitted)
        XCTAssertEqual(r.svc.execute(draftId: "d1", ctx: t2, transport: r.tr).code, .alreadySent)
        // Clé d'idempotence PERSISTÉE : une nouvelle instance (redémarrage) refuse aussi.
        let again = SendApprovals(store: sqliteStore(path), drafts: { r.box.read() })
        XCTAssertEqual(again.execute(draftId: "d1", ctx: ExecContext(conversationId: "conv-A", source: .chat), transport: r.tr).code, .alreadySent)
        let fnv = DraftLint.hash(r.box.get("d1") ?? [:])
        XCTAssertEqual(again.sendFromUI(draftId: "d1", expectFNV: fnv, ctx: ExecContext(conversationId: "ui", source: .ui), transport: r.tr).code, .alreadySent)
        XCTAssertEqual(r.tr.count, 1)
    }

    func testWP34CrashBeforeTransportSubmission() {
        let path = tmpDB()
        let r = rig(store: sqliteStore(path))
        let t2 = showAndConfirm(r)
        guard let aid = r.svc.records(draftId: "d1").last?.actionId else { return XCTFail("action attendue") }
        // Réservation faite (approved → sending), transport JAMAIS lancé, puis plantage.
        r.svc.transition(aid) { rec in
            var a = rec.approval; a?.consumedAt = Date(); rec.approval = a
            return rec.move(.sending, at: Date(), code: "réservé pour envoi")
        }
        let reboot = SendApprovals(store: sqliteStore(path), drafts: { r.box.read() }, updateDraft: { id, f in r.box.update(id, f) })
        let rec = reboot.recoverAtStartup()
        XCTAssertEqual(rec.failed, 1)
        XCTAssertEqual(reboot.records(draftId: "d1").last?.state, .failed)
        // Aucune relance : il faut une NOUVELLE approbation.
        XCTAssertEqual(reboot.execute(draftId: "d1", ctx: t2, transport: r.tr).code, .needsApproval)
        XCTAssertEqual(r.tr.count, 0)
    }

    func testWP34CrashAfterTransportSubmission() {
        let path = tmpDB()
        let r = rig(store: sqliteStore(path))
        let t2 = showAndConfirm(r)
        // L'effet externe a lieu, puis le processus « meurt » avant d'écrire le résultat : la reprise (autre instance,
        // autre connexion) voit « sending » avec transport lancé → deliveryUnknown.
        var recovered: (failed: Int, unknown: Int, dropped: Int) = (0, 0, 0)
        r.tr.during = {
            let reboot = SendApprovals(store: self.sqliteStore(path), drafts: { r.box.read() }, updateDraft: { id, f in r.box.update(id, f) })
            recovered = reboot.recoverAtStartup()
        }
        let res = r.svc.execute(draftId: "d1", ctx: t2, transport: r.tr)
        XCTAssertEqual(recovered.unknown, 1)
        XCTAssertEqual(res.code, .deliveryUnknown, "le résultat suit l'état persisté")
        XCTAssertEqual(r.box.get("d1")?["status"] as? String, "envoi incertain — à vérifier")
        // Jamais de relance automatique d'un envoi incertain.
        XCTAssertEqual(r.svc.execute(draftId: "d1", ctx: t2, transport: r.tr).code, .uncertain)
        let t3 = ExecContext(conversationId: "conv-A", source: .chat)
        XCTAssertEqual(r.svc.noteUserTurn(ctx: t3, text: "envoie"), .none)
        XCTAssertEqual(r.svc.execute(draftId: "d1", ctx: t3, transport: r.tr).code, .uncertain)
        XCTAssertEqual(r.tr.count, 1)
        // Seule Ahadi, depuis l'interface, peut trancher « pas parti » ; un renvoi exige alors une nouvelle approbation.
        guard let aid = res.record?.actionId else { return XCTFail("action attendue") }
        XCTAssertEqual(r.svc.resolveUnknown(actionId: aid, notSent: true, ctx: t3).code, .refused)
        XCTAssertEqual(r.svc.resolveUnknown(actionId: aid, notSent: true, ctx: ExecContext(conversationId: "ui", source: .ui)).code, .failed)
        XCTAssertEqual(r.svc.execute(draftId: "d1", ctx: t3, transport: r.tr).code, .needsApproval)
    }

    func testWP34TimeoutWithPossibleDeliveryStaysUnknown() {
        let r = rig()
        r.tr.outcomes = [.ambiguous("délai dépassé pendant l'envoi par Mail")]
        let t2 = showAndConfirm(r)
        XCTAssertEqual(r.svc.execute(draftId: "d1", ctx: t2, transport: r.tr).code, .deliveryUnknown)
        XCTAssertEqual(r.svc.execute(draftId: "d1", ctx: t2, transport: r.tr).code, .uncertain)
        XCTAssertEqual(r.tr.count, 1)
        // Classement des erreurs de Mail.app : délai = ambigu, refus d'autorisation = certain.
        if case .ambiguous = MailAppTransport.classify("délai dépassé (40 s) — l'app n'a pas répondu") {} else { XCTFail("délai → ambigu") }
        if case .ambiguous = MailAppTransport.classify("osascript a échoué (code 1) : erreur inconnue") {} else { XCTFail("erreur après lancement → ambigu") }
        if case .rejected = MailAppTransport.classify("Not authorized to send Apple events (-1743)") {} else { XCTFail("-1743 → refus certain") }
        // Vérification ultérieure par identifiant du fournisseur : incertain → vérifié.
        let v = r.svc.verify(draftId: "d1", verifier: MockVerifier(.confirmed(providerMessageId: "<abc@mail>", method: "mock_sent_mailbox")))
        XCTAssertEqual(v.code, .verified)
        XCTAssertEqual(v.record?.verification?.providerMessageId, "<abc@mail>")
    }

    func page(_ script: [String: [String: Any]?], reads: [String]) -> (TeamsPaneTransport, () -> [String]) {
        let lock = NSLock(); var calls: [String] = []; var readQueue = reads
        let t = TeamsPaneTransport(page: { a, _ in
            let sub = (a["sub"] as? String) ?? ""
            lock.lock(); calls.append(sub); defer { lock.unlock() }
            if sub == "lire" { return readQueue.isEmpty ? nil : ["ok": true, "texte": readQueue.removeFirst()] }
            if let v = script[sub] { return v }
            return ["ok": true]
        })
        return (t, { lock.lock(); defer { lock.unlock() }; return calls })
    }

    func testWP34TeamsEnterFailureIsNeverVerified() {
        let body = String((WP34SendApprovalTests.teamsDraft["body"] as? String ?? "").prefix(60))
        // Entrée refusée explicitement : rien n'est parti → failed.
        let (refused, _) = page(["touche": ["ok": false]], reads: ["fil vide", "fil vide"])
        let r = rig(drafts: [WP34SendApprovalTests.teamsDraft])
        let t2 = showAndConfirm(r, draft: "t1")
        let res = r.svc.execute(draftId: "t1", ctx: t2, transport: refused)
        XCTAssertEqual(res.code, .failed)
        XCTAssertNotEqual(res.record?.state, .verified)
        // Entrée sans réponse : peut-être parti → deliveryUnknown.
        let (silent, _) = page(["touche": nil], reads: ["fil vide"])
        let r2 = rig(drafts: [WP34SendApprovalTests.teamsDraft])
        let u2 = showAndConfirm(r2, draft: "t1")
        XCTAssertEqual(r2.svc.execute(draftId: "t1", ctx: u2, transport: silent).code, .deliveryUnknown)
        // Entrée acceptée ET message nouveau relu : soumis, preuve FAIBLE, jamais « verified ».
        let (good, calls) = page([:], reads: ["fil vide", "fil vide\n" + body])
        let r3 = rig(drafts: [WP34SendApprovalTests.teamsDraft])
        let u3 = showAndConfirm(r3, draft: "t1")
        let ok = r3.svc.execute(draftId: "t1", ctx: u3, transport: good)
        XCTAssertEqual(ok.code, .submitted)
        XCTAssertEqual(ok.record?.submission?.strength, .weakReadback)
        XCTAssertTrue(calls().contains("touche"))
        XCTAssertEqual(r3.svc.verify(draftId: "t1", verifier: MockVerifier(.notFound)).record?.state, .submitted, "un extrait relu n'est pas un reçu")
        XCTAssertEqual(r3.svc.verify(draftId: "t1", verifier: MockVerifier(.confirmed(providerMessageId: "", method: "x"))).record?.state, .submitted, "pas d'identifiant → pas vérifié")
        if case .ambiguous = MailSentVerifier().verify(ok.record!) {} else { XCTFail("Teams n'est pas vérifiable par Mail") }
    }

    func testWP34ReadBackAmbiguityIsDeliveryUnknown() {
        let body = String((WP34SendApprovalTests.teamsDraft["body"] as? String ?? "").prefix(60))
        // Le même texte figurait déjà dans le fil : la relecture ne distingue pas le nouveau message.
        let (amb, _) = page([:], reads: ["hier : " + body, "hier : " + body])
        let r = rig(drafts: [WP34SendApprovalTests.teamsDraft])
        let t2 = showAndConfirm(r, draft: "t1")
        XCTAssertEqual(r.svc.execute(draftId: "t1", ctx: t2, transport: amb).code, .deliveryUnknown)
        // Relecture impossible après Entrée : incertain aussi.
        let (noRead, _) = page([:], reads: ["fil vide"])
        let r2 = rig(drafts: [WP34SendApprovalTests.teamsDraft])
        let u2 = showAndConfirm(r2, draft: "t1")
        XCTAssertEqual(r2.svc.execute(draftId: "t1", ctx: u2, transport: noRead).code, .deliveryUnknown)
        // Volet injoignable : refus certain, rien saisi.
        let (down, calls) = page(["etat": ["ok": false]], reads: [])
        let r3 = rig(drafts: [WP34SendApprovalTests.teamsDraft])
        let u3 = showAndConfirm(r3, draft: "t1")
        XCTAssertEqual(r3.svc.execute(draftId: "t1", ctx: u3, transport: down).code, .failed)
        XCTAssertFalse(calls().contains("saisir"))
    }

    func testWP34RestartRecoveryIsConservative() {
        let path = tmpDB()
        var d2 = WP34SendApprovalTests.mailDraft; d2["id"] = "d2"
        var d3 = WP34SendApprovalTests.mailDraft; d3["id"] = "d3"
        var d4 = WP34SendApprovalTests.mailDraft; d4["id"] = "d4"
        let r = rig(store: sqliteStore(path), drafts: [WP34SendApprovalTests.mailDraft, d2, d3, d4])
        let c1 = ExecContext(conversationId: "conv-A", source: .chat)
        for id in ["d1", "d2", "d3", "d4"] { _ = r.svc.execute(draftId: id, ctx: c1, transport: r.tr) }
        let ids: [String: String] = Dictionary(uniqueKeysWithValues: ["d1", "d2", "d3", "d4"].map { ($0, r.svc.records(draftId: $0).last?.actionId ?? "") })
        func force(_ id: String, _ states: [SendState], started: Bool) {
            r.svc.transition(ids[id] ?? "") { rec in
                for st in states { guard rec.move(st, at: Date(), code: "test") else { return false } }
                if started { rec.transportStartedAt = Date() }
                return true
            }
        }
        force("d1", [.approved, .sending], started: false)            // réservé, jamais soumis
        force("d2", [.approved, .sending], started: true)             // soumission lancée
        force("d3", [.approved], started: false)                      // approuvé, non consommé
        force("d4", [.approved, .sending, .submitted], started: true) // soumis
        let reboot = SendApprovals(store: sqliteStore(path), drafts: { r.box.read() }, updateDraft: { id, f in r.box.update(id, f) })
        let out = reboot.recoverAtStartup()
        XCTAssertEqual(out.failed, 1); XCTAssertEqual(out.unknown, 1); XCTAssertEqual(out.dropped, 1)
        XCTAssertEqual(reboot.records(draftId: "d1").last?.state, .failed)
        XCTAssertEqual(reboot.records(draftId: "d2").last?.state, .deliveryUnknown)
        XCTAssertEqual(reboot.records(draftId: "d3").last?.state, .awaitingApproval)
        XCTAssertEqual(reboot.records(draftId: "d4").last?.state, .submitted)
        XCTAssertEqual(r.tr.count, 0, "la reprise ne relance rien")
        XCTAssertEqual(reboot.recoverAtStartup().unknown, 0, "reprise idempotente")
    }

    func testWP34OldApprovalCannotSendRevisedDraft() {
        let path = tmpDB()
        let r = rig(store: sqliteStore(path))
        let t2 = showAndConfirm(r)
        let original = r.box.get("d1")?["body"] as? String ?? ""
        r.box.set("d1", "body", original + "\nPS : version révisée")
        XCTAssertEqual(r.svc.execute(draftId: "d1", ctx: t2, transport: r.tr).code, .needsApproval)
        // Revenir au texte d'origine ne ressuscite pas l'ancienne approbation (elle a été annulée).
        r.box.set("d1", "body", original)
        XCTAssertEqual(r.svc.execute(draftId: "d1", ctx: t2, transport: r.tr).code, .needsApproval)
        XCTAssertEqual(r.tr.count, 0)
        XCTAssertTrue(r.svc.records(draftId: "d1").allSatisfy { $0.state != .approved })
    }

    func testWP34DiagnosticsCarryNoSensitiveContent() {
        let lock = NSLock(); var lines: [String] = []
        let r = rig(transitions: { rec, from, to, code in
            let line = String(decoding: jsonData(rec.summary), as: UTF8.self) + " " + from.rawValue + ">" + to.rawValue + " " + code
            lock.lock(); lines.append(line); lock.unlock()
        })
        r.tr.outcomes = [.ambiguous("délai dépassé pendant l'envoi par Mail")]
        let t2 = showAndConfirm(r)
        _ = r.svc.execute(draftId: "d1", ctx: t2, transport: r.tr)
        let all = lines.joined(separator: "\n") + (r.svc.records(draftId: "d1").last?.history.map { $0.code }.joined(separator: " ") ?? "")
        XCTAssertFalse(lines.isEmpty)
        for secret in ["awa@example.org", "Point budget", "Voici le point budget", "Bonjour Awa"] {
            XCTAssertFalse(all.contains(secret), "contenu sensible dans le diagnostic : \(secret)")
        }
    }

    func testWP34SnapshotBindsEveryMaterialField() {
        let base = SendSnapshot.from(draft: WP34SendApprovalTests.mailDraft, hashFile: { _ in nil })!
        XCTAssertEqual(base.recipients, ["awa@example.org"])
        var keys: Set<String> = [base.idempotencyKey]
        for (k, v) in [("to", "x@example.org"), ("subject", "autre"), ("body", "autre"), ("from", "moi@example.org"), ("rev", "2"), ("channel", "teams")] as [(String, String)] {
            var d = WP34SendApprovalTests.mailDraft; d[k] = v
            if k == "channel" { d["target"] = "Equipe" }
            let s = SendSnapshot.from(draft: d, hashFile: { _ in nil })!
            XCTAssertNotEqual(s.sha256, base.sha256, k)
            keys.insert(s.idempotencyKey)
        }
        XCTAssertEqual(keys.count, 7, "chaque champ matériel change la clé d'idempotence")
        // Champs non matériels (statut, horodatage) : même empreinte.
        var d = WP34SendApprovalTests.mailDraft; d["status"] = "envoyé"; d["ts"] = "2020-01-01T00:00:00Z"
        XCTAssertEqual(SendSnapshot.from(draft: d, hashFile: { _ in nil })!.sha256, base.sha256)
        XCTAssertEqual(base.sha256.count, 64, "SHA-256 hexadécimal")
    }
}
