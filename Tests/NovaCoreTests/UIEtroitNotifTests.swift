import XCTest
@testable import NovaCore

/// 01/11/2026 — (1) fenêtre étroite : la liste des conversations devient un tiroir opaque sur un voile ;
/// (2) notifications « une conversation t'attend » / « travail long fini » + pastille du Dock.
/// TOUT EST SIMULÉ : livraison capturée (aucune notification réelle), horloge et état « fenêtre active » injectés,
/// fournisseurs de compte factices ; aucun réglage réel n'est lu ni écrit.
final class UIEtroitNotifTests: XCTestCase {
    typealias Outcome = AttentionNotif.Outcome

    final class Box: @unchecked Sendable {
        let lock = NSLock()
        var sent: [(source: String, title: String, body: String, target: [String: String], sound: Bool, urgent: Bool)] = []
        var scheduled: [(TimeInterval, () -> Void)] = []
        var badges: [Int] = []
        func add(_ e: (String, String, String, [String: String], Bool, Bool)) { lock.lock(); sent.append((e.0, e.1, e.2, e.3, e.4, e.5)); lock.unlock() }
    }
    var box = Box()
    var savedSink: ((String, String, String, [String: String], Bool, Bool, Bool) -> Void)!
    var savedSchedule: ((TimeInterval, @escaping () -> Void) -> Void)!
    var savedEnabled: (() -> Bool)? = nil
    var savedQuiet: (() -> Bool)? = nil
    var savedActive: (() -> Bool)? = nil

    override func setUp() {
        super.setUp()
        box = Box()
        savedSink = AttentionNotif.sink
        savedSchedule = AttentionNotif.schedule
        savedEnabled = NovaNotifier.isEnabled; savedQuiet = NovaNotifier.isQuiet; savedActive = NovaNotifier.appActive
        NovaNotifier.isEnabled = nil; NovaNotifier.isQuiet = nil; NovaNotifier.appActive = nil
        let b = box
        AttentionNotif.sink = { src, t, body, tg, snd, urg, _ in b.add((src, t, body, tg, snd, urg)) }
        AttentionNotif.schedule = { after, work in b.lock.lock(); b.scheduled.append((after, work)); b.lock.unlock() }
        AttentionNotif.titleFor = { key in key == "c1" ? "Comet et Nova" : (key.hasPrefix("dot:") ? "Veille" : "") }
        AttentionNotif.isOn = nil
        AttentionNotif.resetForTests()
    }
    override func tearDown() {
        AttentionNotif.sink = savedSink
        AttentionNotif.schedule = savedSchedule
        NovaNotifier.isEnabled = savedEnabled; NovaNotifier.isQuiet = savedQuiet; NovaNotifier.appActive = savedActive
        AttentionNotif.titleFor = nil
        AttentionNotif.isOn = nil
        AttentionNotif.sendPending = nil
        AttentionNotif.goPending = nil
        AttentionNotif.authPending = { Tools.pendingAuthorizationCount() }
        AttentionNotif.badge = nil
        AttentionNotif.resetForTests()
        super.tearDown()
    }
    let t0 = Date(timeIntervalSince1970: 1_793_500_000)

    // MARK: visibilité

    func testVisibleConversationInActiveWindowIsSilent() {
        AttentionNotif.setVisible(module: "conversations", cid: "c1")
        let o: Outcome = AttentionNotif.responseDone(cid: "c1", ask: "Que penses-tu de Comet ?", excerpt: "Voici", durationS: 30, now: t0, active: true, enabled: true, quiet: false)
        XCTAssertEqual(o, Outcome.visible)
        XCTAssertTrue(box.sent.isEmpty, "rien si la conversation est affichée et la fenêtre active")
        AttentionNotif.setVisible(module: "agent", cid: "c1")   // alias d'écran du module
        XCTAssertEqual(AttentionNotif.responseDone(cid: "c1", ask: "x", excerpt: "y", durationS: 30, now: t0, active: true, enabled: true, quiet: false), Outcome.visible)
    }

    func testOtherConversationOrInactiveWindowNotifiesWithConversationTarget() {
        AttentionNotif.setVisible(module: "conversations", cid: "c2")
        XCTAssertEqual(AttentionNotif.responseDone(cid: "c1", ask: "Que penses-tu de Comet ?", excerpt: "Voici\nma réponse", durationS: 30, now: t0, active: true, enabled: true, quiet: false), Outcome.sent)
        AttentionNotif.setVisible(module: "conversations", cid: "c1")
        XCTAssertEqual(AttentionNotif.responseDone(cid: "c1", ask: "Encore", excerpt: "Suite", durationS: 30, now: t0.addingTimeInterval(1), active: false, enabled: true, quiet: false), Outcome.sent, "fenêtre en arrière-plan")
        XCTAssertEqual(box.sent.count, 2)
        let n = box.sent[0]
        XCTAssertEqual(n.title, "Nova — réponse prête")
        XCTAssertTrue(n.body.contains("« Comet et Nova »"), n.body)
        XCTAssertFalse(n.body.contains("\n"))
        XCTAssertEqual(n.target["module"], "conversations")
        XCTAssertEqual(n.target["id"], "c1", "le clic ouvre LA conversation")
        XCTAssertEqual(n.target["attn"], "1")
        XCTAssertEqual(n.target["thread"], "conv:c1", "regroupées par conversation")
        XCTAssertEqual(n.source, "attn:conv:c1")
        XCTAssertFalse(n.urgent)
    }

    func testShortTurnAndDisabledSettingDoNotNotify() {
        XCTAssertEqual(AttentionNotif.responseDone(cid: "c1", ask: "Salut", excerpt: "Bonjour", durationS: 3, now: t0, active: false, enabled: true, quiet: false), Outcome.tooShort)
        XCTAssertEqual(AttentionNotif.responseDone(cid: "c1", ask: "x", excerpt: "y", durationS: 60, now: t0, active: false, enabled: false, quiet: false), Outcome.disabled)
        AttentionNotif.isOn = { false }   // réglage « notif_conversations » coupé
        XCTAssertEqual(AttentionNotif.notify(.responseDone, module: "conversations", id: "c1", title: "t", body: "b", durationS: 60, now: t0, active: false, quiet: false), Outcome.disabled)
        XCTAssertTrue(box.sent.isEmpty)
    }

    func testCafuNoteReadyTitle() {
        let o: Outcome = AttentionNotif.responseDone(cid: "c3", ask: "Fais la note", excerpt: "Livrable : cafu-note-20261101-034800.docx", durationS: 400, now: t0, active: false, enabled: true, quiet: false)
        XCTAssertEqual(o, Outcome.sent)
        XCTAssertEqual(box.sent.last?.title, "Nova — note CAFU prête")
    }

    // MARK: heures calmes et autorisation bloquante

    func testQuietHoursHoldNonBlockingButAuthorizationPassesSilently() {
        XCTAssertEqual(AttentionNotif.responseDone(cid: "c1", ask: "x", excerpt: "y", durationS: 60, now: t0, active: false, enabled: true, quiet: true), Outcome.quiet)
        let s: Outcome? = AttentionNotif.sendTransition(conversationId: "c1", channel: "mail", recipients: 2, to: "awaitingApproval", now: t0, active: false, enabled: true, quiet: true)
        XCTAssertEqual(s, Outcome.quiet)
        let e: [String: Any] = ["id": "ab12cd", "cmd": "rm -rf ~/Projets/secret", "kind": "commande shell", "ts": "2026-11-01T03:48:00Z", "scope": "conv:c1"]
        XCTAssertEqual(AttentionNotif.authorizationRequested(e, now: t0, active: false, enabled: true, quiet: true), Outcome.sent)
        XCTAssertEqual(box.sent.count, 1)
        let n = box.sent[0]
        XCTAssertTrue(n.urgent, "une autorisation bloque Nova : elle passe les heures calmes")
        XCTAssertFalse(n.sound, "… mais sans son pendant les heures calmes")
        XCTAssertEqual(n.title, "Nova — autorisation demandée")
        XCTAssertFalse(n.body.contains("rm -rf"), "jamais le texte de la commande (écran verrouillé)")
        XCTAssertTrue(n.body.contains("commande shell"))
        XCTAssertEqual(n.target["id"], "c1")
        NovaNotifier.lock.lock(); let marked = NovaNotifier.goNotified.contains("ab12cd"); NovaNotifier.goNotified.remove("ab12cd"); NovaNotifier.lock.unlock()
        XCTAssertTrue(marked, "pas de second rappel « GO t'attend » à 2 min")
    }

    func testAuthorizationVisibleInActiveWindowIsNotDoubled() {
        AttentionNotif.setVisible(module: "conversations", cid: "c1")
        let e: [String: Any] = ["id": "zz99", "kind": "écriture", "ts": "2026-11-01T03:48:00Z", "scope": "conv:c1"]
        XCTAssertEqual(AttentionNotif.authorizationRequested(e, now: t0, active: true, enabled: true, quiet: false), Outcome.visible)
        NovaNotifier.lock.lock(); let marked = NovaNotifier.goNotified.contains("zz99"); NovaNotifier.lock.unlock()
        XCTAssertFalse(marked, "carte sous les yeux : le rappel à 2 min reste possible si Ahadi part")
    }

    func testScopeTargets() {
        XCTAssertEqual(AttentionNotif.target(forScope: "conv:abc").module, "conversations")
        XCTAssertEqual(AttentionNotif.target(forScope: "conv:abc").id, "abc")
        XCTAssertEqual(AttentionNotif.target(forScope: "dot:veille").module, "dots")
        XCTAssertEqual(AttentionNotif.target(forScope: "dot:veille").id, "veille")
        XCTAssertEqual(AttentionNotif.target(forScope: "hors-run").id, "")
    }

    // MARK: envois, GO, Éclats

    func testSendApprovalOnlyOnAwaitingState() {
        XCTAssertNil(AttentionNotif.sendTransition(conversationId: "c1", channel: "mail", recipients: 1, to: "approved", now: t0, active: false, enabled: true, quiet: false))
        let s: Outcome? = AttentionNotif.sendTransition(conversationId: "c1", channel: "teams", recipients: 3, to: "awaitingApproval", now: t0, active: false, enabled: true, quiet: false)
        XCTAssertEqual(s, Outcome.sent)
        XCTAssertEqual(box.sent.last?.title, "Nova — envoi à approuver")
        XCTAssertTrue(box.sent.last?.body.contains("3 destinataires") ?? false)
        XCTAssertTrue(box.sent.last?.sound ?? false)
    }

    func testEclatGoAndEclatDone() {
        XCTAssertEqual(AttentionNotif.eclatReady(dotId: "veille", name: "Veille", summary: "Deux appels à projets", decision: true, now: t0, active: false, enabled: true, quiet: false), Outcome.sent)
        XCTAssertEqual(box.sent.last?.title, "Nova — Veille attend ton GO")
        XCTAssertEqual(box.sent.last?.source, "dot:veille")
        XCTAssertEqual(box.sent.last?.target["module"], "dots")
        XCTAssertEqual(AttentionNotif.eclatReady(dotId: "brvm", name: "BRVM", summary: "RAS", decision: false, now: t0.addingTimeInterval(2), active: false, enabled: true, quiet: false), Outcome.sent)
        XCTAssertEqual(box.sent.last?.source, "dot:fin", "fins d'Éclats regroupées sous une seule source")
        XCTAssertFalse(box.sent.last?.sound ?? true, "un Éclat fini ne sonne pas")
        AttentionNotif.setVisible(module: "dots", cid: "")
        XCTAssertEqual(AttentionNotif.eclatReady(dotId: "brvm", name: "BRVM", summary: "RAS", decision: false, now: t0.addingTimeInterval(3), active: true, enabled: true, quiet: false), Outcome.visible)
    }

    // MARK: débit

    func testRateLimitGroupsSurplusIntoOneSummary() {
        var outs: [Outcome] = []
        for i in 0..<6 {
            outs.append(AttentionNotif.responseDone(cid: "r\(i)", ask: "x", excerpt: "fin \(i)", durationS: 60, now: t0.addingTimeInterval(Double(i) * 10), active: false, enabled: true, quiet: false))
        }
        XCTAssertEqual(outs.filter { $0 == .sent }.count, 4, "au plus 4 notifications non bloquantes par 5 min")
        XCTAssertEqual(outs.filter { $0 == .held }.count, 2)
        let planned = box.scheduled.filter { $0.0 > 1 }   // (les recalculs de pastille sont planifiés à 0,05 s)
        XCTAssertEqual(planned.count, 1, "un seul résumé planifié")
        XCTAssertGreaterThan(planned.first?.0 ?? 0, 200)
        // l'autorisation bloquante n'est jamais retenue par le débit
        let e: [String: Any] = ["id": "rl1", "kind": "commande", "ts": "2026-11-01T03:48:00Z", "scope": "conv:r9"]
        XCTAssertEqual(AttentionNotif.authorizationRequested(e, now: t0.addingTimeInterval(70), active: false, enabled: true, quiet: false), Outcome.sent)
        NovaNotifier.lock.lock(); NovaNotifier.goNotified.remove("rl1"); NovaNotifier.lock.unlock()
        let before = box.sent.count
        planned.first?.1()   // fin de fenêtre
        XCTAssertEqual(box.sent.count, before + 1)
        XCTAssertTrue(box.sent.last?.body.hasPrefix("2 autres notifications regroupées") ?? false, box.sent.last?.body ?? "")
        XCTAssertEqual(box.sent.last?.target["module"], "attente")
        // la fenêtre glisse : 5 min plus tard, ça repart
        XCTAssertEqual(AttentionNotif.responseDone(cid: "r7", ask: "x", excerpt: "y", durationS: 60, now: t0.addingTimeInterval(400), active: false, enabled: true, quiet: false), Outcome.sent)
    }

    // MARK: pastille du Dock

    func testDockBadgeCountsAllPendingKindsAndOnlyRepaintsOnChange() {
        var auth = 2, send = 1, go = 3
        AttentionNotif.authPending = { auth }
        AttentionNotif.sendPending = { send }
        AttentionNotif.goPending = { go }
        let b = box
        AttentionNotif.badge = { n in b.lock.lock(); b.badges.append(n); b.lock.unlock() }
        XCTAssertEqual(AttentionNotif.refreshBadge(), 6)
        XCTAssertEqual(AttentionNotif.refreshBadge(), 6)
        auth = 0; send = 0; go = 0
        XCTAssertEqual(AttentionNotif.refreshBadge(), 0)
        XCTAssertEqual(box.badges, [6, 0], "repeinte seulement quand le compte change ; 0 = pastille retirée")
    }

    func testPendingAuthorizationCountIgnoresStaleRequests() {
        let iso = ISO8601DateFormatter()
        Tools.apLock.lock()
        let saved = Tools.pendingConfirm
        Tools.pendingConfirm = ["a1": ["ts": iso.string(from: t0.addingTimeInterval(-60))], "a2": ["ts": iso.string(from: t0.addingTimeInterval(-7 * 3600))]]
        Tools.apLock.unlock()
        XCTAssertEqual(Tools.pendingAuthorizationCount(now: t0), 1)
        Tools.apLock.lock(); Tools.pendingConfirm = saved; Tools.apLock.unlock()
    }

    // MARK: branchements (lecture des sources)

    private func src(_ rel: String) throws -> String {
        let root: URL = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        return try String(contentsOf: root.appendingPathComponent(rel), encoding: .utf8)
    }

    func testProducersAreWired() throws {
        let app = try src("Sources/NovaCore/App.swift")
        XCTAssertTrue(app.contains("AttentionNotif.authorizationRequested(e)"), "carte de confirmation → notification immédiate")
        XCTAssertTrue(app.contains("AttentionNotif.eclatReady("), "fin d'Éclat / GO")
        XCTAssertTrue(app.contains("attentionRoutes(s)"))
        XCTAssertTrue(try src("Sources/NovaCore/SendApproval.swift").contains("AttentionNotif.sendTransition("), "envoi à approuver")
        XCTAssertTrue(try src("Sources/NovaCore/App+RoutesChat.swift").contains("AttentionNotif.responseDone("), "réponse finie, côté moteur")
        let nn = try src("Sources/NovaCore/NovaNotifier.swift")
        XCTAssertFalse(nn.contains("\"confirm:\" + id"), "le rappel GO ouvre la conversation, plus une cible « confirm: » morte")
        XCTAssertTrue(nn.contains("AttentionNotif.target(forScope: scope)"))
        let mac = try src("Sources/NovaMac/NovaNotify.swift")
        XCTAssertTrue(mac.contains("dockTile.badgeLabel"), "pastille du Dock")
        XCTAssertTrue(mac.contains("target[\"attn\"] == \"1\""), "une cible hors de vue s'affiche même Nova active")
        XCTAssertTrue(mac.contains("target[\"thread\"]"), "regroupement par conversation")
    }

    func testWebSideReportsVisibilityOpensConversationAndHasSetting() throws {
        let shell = try src("web/js/shell.js")
        XCTAssertTrue(shell.contains("/api/notify/visible"))
        XCTAssertTrue(shell.contains("bus.on(\"nova:notif-open\""), "le clic ouvre la bonne conversation")
        XCTAssertTrue(shell.contains("nova:nav-open-conv"))
        XCTAssertFalse(try src("web/js/modules/agent.js").contains("api.post(\"/api/notify/taskdone\""), "la fin de tour est notifiée par le moteur")
        let st = try src("web/js/modules/settings.js")
        XCTAssertTrue(st.contains("\"Notifications des conversations\""))
        XCTAssertTrue(st.contains("notif_conversations"))
    }

    // MARK: (1) fenêtre étroite — règles CSS

    func testNarrowConversationListIsAnOpaqueDrawerOverAScrim() throws {
        let css = try src("web/css/layouts.css")
        guard let r = css.range(of: "@container cs (max-width: 760px) {\n  .cs-layout.side-peek > .cs-scrim") else { return XCTFail("bloc tiroir absent") }
        let block = String(css[r.lowerBound...].prefix(900))
        XCTAssertTrue(block.contains("html[data-identite] .cs-layout.side-peek > .cs-side"), "doit battre la règle d'identité (fond translucide)")
        XCTAssertTrue(block.contains("background: var(--pane-solid)"), "fond opaque")
        XCTAssertTrue(block.contains("z-index: 35"))
        XCTAssertTrue(block.contains("z-index: 34"), "voile sous le tiroir")
        XCTAssertTrue(css.contains(".cs-scrim { display: none; }"), "aucun voile en pleine largeur")
        let agent = try src("web/js/modules/agent.js")
        XCTAssertTrue(agent.contains("class: \"cs-scrim\""))
        XCTAssertTrue(agent.contains("layout.append(side, scrim, main)"))
        XCTAssertTrue(agent.contains("listEl.addEventListener(\"click\", () => { try { layout.classList.remove(\"side-peek\")"), "le tiroir se referme au choix d'une conversation")
    }

    func testOtherNarrowPanesFixes() throws {
        let css = try src("web/css/layouts.css")
        XCTAssertTrue(css.contains(".ms-tools:has(> .browser-bars[hidden]) { z-index: calc(var(--z-float, 40) + 1); }"), "« Côte à côte » cliquable au-dessus de la barre du volet")
        XCTAssertTrue(css.contains(".mod[data-mod=\"messages\"] .pane-host.is-split { flex-shrink: 0; }"), "volets empilés : plus de débordement sur la note")
        XCTAssertTrue(css.contains("@container cs (max-width: 400px)"), "champ de saisie sur sa ligne en très étroit")
    }
}
