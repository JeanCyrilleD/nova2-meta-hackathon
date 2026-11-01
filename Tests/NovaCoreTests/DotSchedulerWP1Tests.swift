import XCTest
@testable import NovaCore

/// WP1 — ordonnancement des Éclats (DotScheduler). Horloge, fuseau, exécuteur et liste d'Éclats INJECTÉS : aucun cerveau,
/// aucun réseau, aucun thread réel sauf dans les tests de concurrence. Données dans un bac à sable (NOVA_HOME), relevés de
/// diagnostic dans NOVA_HOME/diag (Paths.diagDir) — rien n'est écrit dans les données ni les relevés de l'app en service.
final class DotSchedulerWP1Tests: XCTestCase {
    static var sandbox: URL = FileManager.default.temporaryDirectory
    static var previousHome: String? = nil

    override class func setUp() {
        super.setUp()
        previousHome = ProcessInfo.processInfo.environment["NOVA_HOME"]
        let d = FileManager.default.temporaryDirectory.appendingPathComponent("nova-wp1-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        setenv("NOVA_HOME", d.path, 1)
        sandbox = d
    }
    override class func tearDown() {
        if let p = previousHome { setenv("NOVA_HOME", p, 1) } else { unsetenv("NOVA_HOME") }
        super.tearDown()
    }

    // MARK: doubles de test

    /// Horloge réglable (lue depuis plusieurs threads).
    final class TestClock: @unchecked Sendable {
        private let lock = NSLock()
        private var t: Date
        init(_ t: Date) { self.t = t }
        func now() -> Date { lock.lock(); defer { lock.unlock() }; return t }
        func set(_ d: Date) { lock.lock(); t = d; lock.unlock() }
        func advance(min: Double) { lock.lock(); t = t.addingTimeInterval(min * 60); lock.unlock() }
    }
    /// Fuseau réglable (changement de fuseau en cours de journée).
    final class TZBox: @unchecked Sendable {
        private let lock = NSLock()
        private var tz: TimeZone
        init(_ id: String) { tz = TimeZone(identifier: id)! }
        func get() -> TimeZone { lock.lock(); defer { lock.unlock() }; return tz }
        func set(_ id: String) { lock.lock(); tz = TimeZone(identifier: id)!; lock.unlock() }
    }
    /// Exécuteur factice : compte les runs, peut refuser le départ, perdre le travail (arrêt de Nova), bloquer certains
    /// Éclats jusqu'à libération, respecter ou ignorer l'annulation.
    final class FakeExec: @unchecked Sendable {
        private let lock = NSLock()
        private(set) var runsList: [String] = []
        private(set) var journals: [String] = []
        private var inFlight: Int = 0
        private(set) var maxInFlight: Int = 0
        var refuse: Bool { get { lock.lock(); defer { lock.unlock() }; return _refuse } set { lock.lock(); _refuse = newValue; lock.unlock() } }
        private var _refuse = false
        var drop: Bool { get { lock.lock(); defer { lock.unlock() }; return _drop } set { lock.lock(); _drop = newValue; lock.unlock() } }
        private var _drop = false
        let async: Bool
        private var blocked: Set<String> = []
        private var honorCancel: Bool = true
        private var cancelSeen: Set<String> = []
        init(async: Bool = false) { self.async = async }
        func block(_ dot: String, honorCancel: Bool = true) { lock.lock(); blocked.insert(dot); self.honorCancel = honorCancel; lock.unlock() }
        func release(_ dot: String) { lock.lock(); blocked.remove(dot); lock.unlock() }
        func runs() -> [String] { lock.lock(); defer { lock.unlock() }; return runsList }
        func journalCount() -> Int { lock.lock(); defer { lock.unlock() }; return journals.count }
        func maxConcurrent() -> Int { lock.lock(); defer { lock.unlock() }; return maxInFlight }
        func sawCancel(_ dot: String) -> Bool { lock.lock(); defer { lock.unlock() }; return cancelSeen.contains(dot) }
        func executor() -> DotExecutor {
            return DotExecutor(
                dispatch: { [self] work in
                    if refuse { return false }
                    if drop { return true }   // accepté puis perdu : Nova s'arrête avant le départ du thread
                    if async { Thread.detachNewThread(work) } else { work() }
                    return true
                },
                run: { [self] dot, _, _, cancel in
                    lock.lock(); runsList.append(dot); inFlight += 1; maxInFlight = max(maxInFlight, inFlight); lock.unlock()
                    defer { lock.lock(); inFlight -= 1; lock.unlock() }
                    while true {
                        lock.lock(); let isBlocked = blocked.contains(dot); let honor = honorCancel; lock.unlock()
                        if !isBlocked { break }
                        if cancel() {
                            lock.lock(); cancelSeen.insert(dot); lock.unlock()
                            if honor { return ["result": "", "arrete": true, "id": "h-" + dot] }
                        }
                        usleep(2000)
                    }
                    return ["result": "STATUT : OK — compte rendu de test", "id": "h-" + dot]
                },
                openJournal: { [self] origine in lock.lock(); journals.append(origine); lock.unlock() })
        }
    }
    final class Events: @unchecked Sendable {
        private let lock = NSLock()
        private var items: [[String: Any]] = []
        func add(_ o: Any) { lock.lock(); if let d = o as? [String: Any] { items.append(d) }; lock.unlock() }
        func ready(_ dot: String) -> Int { lock.lock(); defer { lock.unlock() }; return items.filter { ($0["phase"] as? String) == "ready" && ($0["dot"] as? String) == dot }.count }
    }

    struct Harness {
        let sched: DotScheduler
        let clock: TestClock
        let exec: FakeExec
        let tz: TZBox
        let events: Events
        let prefix: String
    }

    func baseSettings(_ extra: [String: Any] = [:]) -> Settings {
        let s = Settings()
        var p: [String: Any] = ["dots_espacement_s": 0, "dots_cpu_max": 1_000_000, "quiet_from": "00:00", "quiet_to": "00:00", "focus_until": 0.0,
                                "dots_auto": true, "dots_retard_prioritaire_min": 60, "dots_rattrapage_min": 180, "dots_run_max_min": 20,
                                "dots_alerte_max_min": 6, "dots_arret_grace_min": 3, "dots_fuseau": ""]
        for (k, v) in extra { p[k] = v }
        s.set(p)
        return s
    }

    func make(_ list: [[String: Any]], at: Date, tz: String = "Europe/Paris", async: Bool = false, settings extra: [String: Any] = [:],
              prefix: String? = nil, exec: FakeExec? = nil) -> Harness {
        let settings = baseSettings(extra)
        let router = Router(keys: MemoryKeyStore())
        let tools = Tools(memory: Memory())
        let dots = Dots(router: router, tools: tools, settings: settings)
        let briefs = Briefs(router: router, tools: tools, settings: settings)
        let clock = TestClock(at)
        let ex = exec ?? FakeExec(async: async)
        let box = TZBox(tz)
        let events = Events()
        let pf = prefix ?? "wp1-\(UUID().uuidString.prefix(8))-"
        let sched = DotScheduler(dots: dots, settings: settings, briefs: briefs, publish: { _, o in events.add(o) },
                                 clock: { clock.now() }, executor: ex.executor(), timeZone: { box.get() },
                                 dotList: { list }, storePrefix: pf)
        return Harness(sched: sched, clock: clock, exec: ex, tz: box, events: events, prefix: pf)
    }

    /// Instant « jour à HH:MM » dans un fuseau.
    func date(_ day: String, _ hm: String, _ tz: String = "Europe/Paris") -> Date {
        let f = DateFormatter(); f.locale = Locale(identifier: "en_US_POSIX"); f.timeZone = TimeZone(identifier: tz)
        f.dateFormat = "yyyy-MM-dd HH:mm"
        return f.date(from: day + " " + hm)!
    }
    func dot(_ id: String, _ schedule: String) -> [String: Any] { return ["id": id, "name": id, "schedule": schedule] }
    func consumed(_ h: Harness, _ id: String) -> [String] {
        let st: [String: Any] = h.sched.state.read(default: [String: Any]())
        return ((st[id] as? [String: Any])?["last"] as? [String]) ?? []
    }
    func expired(_ h: Harness, _ id: String) -> [String] {
        let st: [String: Any] = h.sched.state.read(default: [String: Any]())
        return ((st[id] as? [String: Any])?["expired"] as? [String]) ?? []
    }
    func recents(_ h: Harness) -> [[String: Any]] {
        let o: [String: Any] = h.sched.ledger.read(default: [String: Any]())
        return (o["recents"] as? [[String: Any]]) ?? []
    }
    func waitIdle(_ h: Harness, _ id: String, file: StaticString = #filePath, line: UInt = #line) {
        let deadline = Date().addingTimeInterval(5)
        while h.sched.isRunning(id) && Date() < deadline { usleep(2000) }
        XCTAssertFalse(h.sched.isRunning(id), "le run de \(id) ne s'est pas terminé", file: file, line: line)
    }

    func waitStarted(_ h: Harness, _ id: String, file: StaticString = #filePath, line: UInt = #line) {
        let deadline = Date().addingTimeInterval(5)
        while !h.exec.runs().contains(id) && Date() < deadline { usleep(1000) }
        XCTAssertTrue(h.exec.runs().contains(id), "le run de \(id) n'a pas démarré", file: file, line: line)
    }

    // MARK: 1. exactement une fois

    func testDueScheduledDotRunsExactlyOnce() {
        let h = make([dot("veille", "07:30")], at: date("2026-10-28", "07:31"))
        h.sched.tick()
        XCTAssertEqual(h.exec.runs(), ["veille"])
        XCTAssertEqual(consumed(h, "veille"), ["2026-10-28T07:30"])
        XCTAssertEqual(recents(h).last?["etat"] as? String, DotRunPhase.completed.rawValue)
        XCTAssertEqual(recents(h).last?["creneau"] as? String, "2026-10-28T07:30")
        XCTAssertEqual(h.events.ready("veille"), 1)
        for _ in 0..<5 { h.clock.advance(min: 1); h.sched.tick() }
        XCTAssertEqual(h.exec.runs(), ["veille"], "un créneau tenu ne repart pas")
        XCTAssertFalse(h.sched.isRunning("veille"))
    }

    // MARK: 2. ticks répétés pendant un run

    func testRepeatedTicksDoNotDuplicateRun() {
        let h = make([dot("veille", "07:30")], at: date("2026-10-28", "07:31"), async: true)
        h.exec.block("veille")
        h.sched.tick()
        let deadline = Date().addingTimeInterval(5)
        while h.exec.runs().isEmpty && Date() < deadline { usleep(1000) }
        XCTAssertTrue(h.sched.isRunning("veille"))
        let rid = h.sched.activeRunID("veille")
        XCTAssertNotNil(rid)
        for _ in 0..<20 { h.sched.tick() }
        XCTAssertEqual(h.sched.activeRunID("veille"), rid, "le run en vol garde sa propriété")
        h.exec.release("veille")
        waitIdle(h, "veille")
        for _ in 0..<5 { h.clock.advance(min: 1); h.sched.tick() }
        XCTAssertEqual(h.exec.runs(), ["veille"])
        XCTAssertEqual(h.sched.runPhase(rid ?? ""), .completed)
    }

    // MARK: 3. manuel et planifié concurrents

    func testConcurrentManualAndScheduledCannotBothClaim() {
        let d = dot("veille", "07:30")
        let h = make([d], at: date("2026-10-28", "07:31"), async: true)
        h.exec.block("veille")
        let results = Results()
        DispatchQueue.concurrentPerform(iterations: 16) { i in
            if i % 4 == 0 { h.sched.tick() } else { results.add(h.sched.launch(d, task: "", manual: true)) }
        }
        let deadline = Date().addingTimeInterval(5)
        while h.exec.runs().isEmpty && Date() < deadline { usleep(1000) }
        XCTAssertLessThanOrEqual(results.started(), 1, "deux lancements ont réservé le même Éclat")
        XCTAssertTrue(h.sched.isRunning("veille"))
        usleep(20_000)
        XCTAssertEqual(h.exec.runs().count, 1, "un seul run en vol")
        h.exec.release("veille")
        waitIdle(h, "veille")
        XCTAssertEqual(h.exec.maxConcurrent(), 1)
    }
    final class Results: @unchecked Sendable {
        private let lock = NSLock(); private var l: [LaunchResult] = []
        func add(_ r: LaunchResult) { lock.lock(); l.append(r); lock.unlock() }
        func started() -> Int { lock.lock(); defer { lock.unlock() }; return l.filter { $0.isStarted }.count }
    }

    // MARK: 4. échec du départ

    func testFailedDispatchDoesNotConsumeSlot() {
        let h = make([dot("veille", "07:30")], at: date("2026-10-28", "07:31"))
        h.exec.refuse = true
        h.sched.tick()
        XCTAssertTrue(h.exec.runs().isEmpty)
        XCTAssertTrue(consumed(h, "veille").isEmpty, "un départ refusé ne consomme pas le créneau")
        XCTAssertFalse(h.sched.isRunning("veille"), "la réservation est rendue")
        XCTAssertEqual(recents(h).last?["etat"] as? String, DotRunPhase.failed.rawValue)
        let manual = h.sched.launch(dot("veille", "07:30"), task: "", manual: true)
        XCTAssertEqual(manual, .failedToStart(reason: "départ refusé par l'exécuteur"))
        h.exec.refuse = false
        h.clock.advance(min: 1)
        h.sched.tick()
        XCTAssertEqual(h.exec.runs(), ["veille"], "le créneau resté ouvert part au passage suivant")
        XCTAssertEqual(consumed(h, "veille"), ["2026-10-28T07:30"])
    }

    // MARK: 5. arrêt et chien de garde

    func testWatchdogRequestsCancellationAndKeepsOwnership() {
        // Run qui IGNORE l'annulation : le chien de garde demande l'arrêt, garde la file, puis le déclare orphelin.
        let a = dot("a", ""), b = dot("b", "07:40")
        let h = make([a, b], at: date("2026-10-28", "07:20"), async: true)
        h.exec.block("a", honorCancel: false)
        let r = h.sched.launch(a, task: "", manual: true)
        guard let rid = r.runID else { return XCTFail("lancement manuel refusé : \(r)") }
        waitStarted(h, "a")   // l'heure de départ est lue par le thread du run
        h.clock.set(date("2026-10-28", "07:41"))   // 21 min > dots_run_max_min (20)
        h.sched.tick()
        XCTAssertTrue(h.sched.isCancelRequested(rid), "arrêt demandé par le chien de garde")
        XCTAssertEqual(h.sched.activeRunID("a"), rid, "la propriété n'est pas libérée en silence")
        XCTAssertFalse(h.exec.runs().contains("b"), "la file reste tenue tant que le run n'a pas rendu la main")
        h.clock.advance(min: 3)   // délai de grâce (3 min) écoulé : orphelin
        h.sched.tick()
        XCTAssertTrue(h.sched.isOrphaned(rid))
        let deadline = Date().addingTimeInterval(5)
        while !h.exec.runs().contains("b") && Date() < deadline { usleep(1000) }
        XCTAssertTrue(h.exec.runs().contains("b"), "file rendue aux autres Éclats")
        XCTAssertEqual(h.sched.launch(a, task: "", manual: true), .alreadyRunning, "l'Éclat orphelin reste bloqué")
        h.exec.release("a")
        waitIdle(h, "a")
        waitIdle(h, "b")
        XCTAssertEqual(h.events.ready("a"), 0, "la fin tardive d'un orphelin ne livre rien")
        let until = Date().addingTimeInterval(5)
        while h.events.ready("b") == 0 && Date() < until { usleep(1000) }   // la livraison suit la fin du run (même thread)
        XCTAssertEqual(h.events.ready("b"), 1)
        XCTAssertTrue(h.sched.launch(a, task: "", manual: true).isStarted, "après la fin réelle, l'Éclat se relance")
        waitIdle(h, "a")
    }

    func testWatchdogCancelsCooperativeRun() {
        let a = dot("a", "")
        let h = make([a], at: date("2026-10-28", "08:00"), async: true)
        h.exec.block("a", honorCancel: true)
        guard let rid = h.sched.launch(a, task: "", manual: true).runID else { return XCTFail("refusé") }
        waitStarted(h, "a")
        h.clock.advance(min: 25)
        h.sched.tick()
        waitIdle(h, "a")
        XCTAssertTrue(h.exec.sawCancel("a"))
        XCTAssertEqual(h.sched.runPhase(rid), .cancelled)
        XCTAssertFalse(h.sched.isOrphaned(rid))
    }

    func testAlertRunHasShortWatchdog() {
        let a = dot("courrier", "")
        let h = make([a], at: date("2026-10-28", "08:00"), async: true)
        h.exec.block("courrier", honorCancel: true)
        guard let rid = h.sched.launch(a, task: "ALERTE", manual: true, alerte: true).runID else { return XCTFail("refusé") }
        waitStarted(h, "courrier")
        h.clock.advance(min: 7)   // > dots_alerte_max_min (6), < dots_run_max_min (20)
        h.sched.tick()
        waitIdle(h, "courrier")
        XCTAssertEqual(h.sched.runPhase(rid), .cancelled)
    }

    func testUserStopCancelsOwnRun() {
        let a = dot("a", "")
        let h = make([a], at: date("2026-10-28", "08:00"), async: true)
        h.exec.block("a", honorCancel: true)
        guard let rid = h.sched.launch(a, task: "", manual: true).runID else { return XCTFail("refusé") }
        XCTAssertEqual(h.sched.stop("a"), [rid])
        waitIdle(h, "a")
        XCTAssertEqual(h.sched.runPhase(rid), .cancelled)
        XCTAssertEqual(h.events.ready("a"), 0, "un run arrêté ne livre rien")
    }

    // MARK: 6. fin périmée

    func testStaleCompletionCannotRemoveNewerRun() {
        let h = make([], at: date("2026-10-28", "08:00"))
        guard let r1 = h.sched.claimExternal("x").runID else { return XCTFail("refusé") }
        XCTAssertEqual(h.sched.claimExternal("x"), .alreadyRunning, "écran + écran : un seul run")
        XCTAssertEqual(h.sched.launch(dot("x", ""), task: "", manual: true), .alreadyRunning, "écran + manuel : un seul run")
        h.sched.finishExternal(r1, result: ["result": "STATUT : OK"])
        guard let r2 = h.sched.claimExternal("x").runID else { return XCTFail("refusé") }
        XCTAssertNotEqual(r1, r2)
        h.sched.finishExternal(r1, result: ["result": "STATUT : OK"])   // fin tardive / en double de l'ancien run
        h.sched.finishExternal("r-inconnu", result: nil)
        XCTAssertTrue(h.sched.isRunning("x"))
        XCTAssertEqual(h.sched.activeRunID("x"), r2, "une fin périmée n'efface pas un run plus récent")
        h.sched.finishExternal(r2, result: ["result": "STATUT : OK"])
        XCTAssertFalse(h.sched.isRunning("x"))
    }

    // MARK: 7. veille / réveil

    func testSleepWakeCatchUpAndAbandon() {
        let h = make([dot("veille", "07:30")], at: date("2026-10-28", "07:00"))
        h.sched.tick()
        XCTAssertTrue(h.exec.runs().isEmpty)
        h.clock.set(date("2026-10-28", "09:45"))   // réveil 2 h 15 après : dans la fenêtre (180 min)
        h.sched.tick()
        XCTAssertEqual(h.exec.runs(), ["veille"])
        // Lendemain : Mac en veille jusqu'à 11:00 — 210 min de retard > fenêtre : abandon tracé, rien ne part.
        h.clock.set(date("2026-10-29", "11:00"))
        h.sched.tick()
        XCTAssertEqual(h.exec.runs(), ["veille"])
        XCTAssertEqual(expired(h, "veille"), ["2026-10-29T07:30"])
    }

    func testCatchUpAcrossMidnight() {
        let h = make([dot("nuit", "23:50")], at: date("2026-10-28", "23:40"))
        h.sched.tick()
        XCTAssertTrue(h.exec.runs().isEmpty)
        h.clock.set(date("2026-10-29", "00:20"))   // le Mac dormait à 23:50
        h.sched.tick()
        XCTAssertEqual(h.exec.runs(), ["nuit"], "le créneau de la veille est rattrapé après minuit")
        XCTAssertEqual(consumed(h, "nuit"), ["2026-10-28T23:50"])
        h.clock.advance(min: 5); h.sched.tick()
        XCTAssertEqual(h.exec.runs().count, 1)
        h.clock.set(date("2026-10-29", "23:51"))
        h.sched.tick()
        XCTAssertEqual(h.exec.runs().count, 2, "le créneau du jour suivant part normalement")
    }

    // MARK: 8. fuseau

    func testSlotKeyUsesScheduleTimeZone() {
        // 23:30 UTC le 28 = 08:30 le 29 à Tokyo : la clé du créneau porte le jour de Tokyo (avant : jour UTC).
        let h = make([dot("matin", "08:00")], at: date("2026-10-28", "23:30", "UTC"), tz: "Asia/Tokyo")
        h.sched.tick()
        XCTAssertEqual(h.exec.runs(), ["matin"])
        XCTAssertEqual(consumed(h, "matin"), ["2026-10-29T08:00"])
    }

    func testTimeZoneChangeDoesNotDuplicate() {
        let h = make([dot("veille", "07:30")], at: date("2026-10-28", "07:31", "Europe/Paris"), tz: "Europe/Paris")
        h.sched.tick()
        XCTAssertEqual(h.exec.runs().count, 1)
        h.tz.set("America/New_York")   // voyage vers l'ouest : il est 02:31 du même jour à New York
        h.sched.tick()
        h.clock.set(date("2026-10-28", "07:31", "America/New_York"))
        h.sched.tick()
        XCTAssertEqual(h.exec.runs().count, 1, "le créneau du jour, déjà tenu, ne repart pas après le changement de fuseau")
        h.clock.set(date("2026-10-29", "07:31", "America/New_York"))
        h.sched.tick()
        XCTAssertEqual(h.exec.runs().count, 2)
        XCTAssertEqual(consumed(h, "veille").last, "2026-10-29T07:30")
    }

    func testExplicitTimeZoneSetting() {
        let s = baseSettings(["dots_fuseau": "Africa/Ouagadougou"])
        XCTAssertEqual(DotScheduler.configuredTimeZone(s).identifier, "Africa/Ouagadougou")
        _ = baseSettings(["dots_fuseau": "Pas/UnFuseau"])
        XCTAssertNotEqual(DotScheduler.configuredTimeZone(Settings()).identifier, "Pas/UnFuseau")
        _ = baseSettings()
    }

    // MARK: 9. horaires invalides

    func testScheduleValidation() {
        XCTAssertTrue(DotScheduler.scheduleErrors("07:30").isEmpty)
        XCTAssertTrue(DotScheduler.scheduleErrors("lun-ven 07:30,12:00").isEmpty)
        XCTAssertTrue(DotScheduler.scheduleErrors("we 10:00").isEmpty)
        XCTAssertFalse(DotScheduler.scheduleErrors("25:00").isEmpty)
        XCTAssertFalse(DotScheduler.scheduleErrors("07:60").isEmpty)
        XCTAssertFalse(DotScheduler.scheduleErrors("7h30").isEmpty)
        XCTAssertFalse(DotScheduler.scheduleErrors("lu 07:30").isEmpty, "préfixe de jours inconnu")
        let cal = DotScheduler.calendar(TimeZone(identifier: "Europe/Paris")!)
        let samedi = date("2026-10-31", "09:00"), lundi = date("2026-11-02", "09:00")
        XCTAssertEqual(DotScheduler.slots("lun-ven 07:30", now: samedi, calendar: cal), [])
        XCTAssertEqual(DotScheduler.slots("lun-ven 07:30", now: lundi, calendar: cal), ["07:30"])
        XCTAssertEqual(DotScheduler.slots("ven-lun 08:00", now: samedi, calendar: cal), ["08:00"], "plage qui passe par le week-end")
        XCTAssertEqual(DotScheduler.slots("lu 07:30", now: lundi, calendar: cal), [], "un préfixe inconnu n'est plus lu comme « tous les jours »")
        XCTAssertEqual(DotScheduler.slots("25:00, 07:30 ,99:99", now: lundi, calendar: cal), ["07:30"])
    }

    func testInvalidScheduleIsReportedAndValidPartStillRuns() {
        let h = make([dot("mixte", "25:00,07:30")], at: date("2026-10-28", "07:31"))
        h.sched.tick()
        XCTAssertEqual(h.exec.runs(), ["mixte"])
        let diag = Paths.diagFile("eclats_ordonnanceur.jsonl")
        XCTAssertTrue(diag.path.hasPrefix(DotSchedulerWP1Tests.sandbox.path), "relevés de test dans le bac à sable : \(diag.path)")
        let txt = (try? String(contentsOf: diag, encoding: .utf8)) ?? ""
        XCTAssertTrue(txt.contains("horaire invalide"), "horaire invalide tracé au miroir")
    }

    // MARK: 10. portes préservées (heures calmes, concentration, espacement, interrupteur)

    func testGatesStillHold() {
        let h = make([dot("a", "07:30"), dot("b", "07:31")], at: date("2026-10-28", "07:32"), settings: ["focus_until": Date().addingTimeInterval(3600).timeIntervalSince1970])
        h.sched.tick()
        XCTAssertTrue(h.exec.runs().isEmpty, "mode concentration : rien ne part")
        _ = baseSettings(["dots_auto": false])
        h.sched.tick()
        XCTAssertTrue(h.exec.runs().isEmpty, "dots_auto coupé : rien ne part")
        _ = baseSettings(["dots_espacement_s": 600])
        h.sched.tick()
        XCTAssertTrue(h.exec.runs().isEmpty, "espacement depuis le démarrage : pas de rafale au lancement")
        h.clock.advance(min: 11)
        h.sched.tick()
        XCTAssertEqual(h.exec.runs(), ["a"])
        h.clock.advance(min: 1)
        h.sched.tick()
        XCTAssertEqual(h.exec.runs(), ["a"], "espacement de 10 min entre deux passages planifiés")
        h.clock.advance(min: 10)
        h.sched.tick()
        XCTAssertEqual(h.exec.runs(), ["a", "b"])
        _ = baseSettings()
    }

    // MARK: 11. Journal du soir

    func testEveningJournalSpecialPath() {
        let j = dot(JournalSoir.dotId, "21:00"), a = dot("a", "")
        let h = make([j, a], at: date("2026-10-28", "21:01"), async: true)
        h.exec.block("a")
        XCTAssertTrue(h.sched.launch(a, task: "", manual: true).isStarted)
        h.sched.tick()
        XCTAssertEqual(h.exec.journalCount(), 0, "la carte attend qu'aucun Éclat ne tienne la file")
        XCTAssertTrue(consumed(h, JournalSoir.dotId).isEmpty)
        h.exec.release("a")
        waitIdle(h, "a")
        h.clock.advance(min: 1)
        h.sched.tick()
        XCTAssertEqual(h.exec.journalCount(), 1, "la carte du soir s'ouvre")
        XCTAssertFalse(h.exec.runs().contains(JournalSoir.dotId), "pas de run de cerveau pour le Journal du soir")
        XCTAssertEqual(consumed(h, JournalSoir.dotId), ["2026-10-28T21:00"])
        h.clock.advance(min: 1)
        h.sched.tick()
        XCTAssertEqual(h.exec.journalCount(), 1, "une seule carte par créneau")
        XCTAssertFalse(h.sched.isRunning(JournalSoir.dotId))
    }

    // MARK: 12. reprise après arrêt de Nova

    func testRecoveryReopensSlotOfRunThatNeverStarted() {
        let list = [dot("veille", "07:30")]
        let exec1 = FakeExec(); exec1.drop = true   // départ accepté puis perdu : Nova s'arrête
        let h1 = make(list, at: date("2026-10-28", "07:31"), exec: exec1)
        h1.sched.tick()
        XCTAssertTrue(h1.sched.isRunning("veille"))
        XCTAssertEqual(consumed(h1, "veille"), ["2026-10-28T07:30"])
        // « Redémarrage » : un nouveau planificateur relit le même registre.
        let h2 = make(list, at: date("2026-10-28", "07:40"), prefix: h1.prefix)
        XCTAssertFalse(h2.sched.isRunning("veille"))
        XCTAssertEqual(recents(h2).last?["etat"] as? String, DotRunPhase.interrupted.rawValue)
        XCTAssertTrue(consumed(h2, "veille").isEmpty, "le créneau d'un run jamais démarré est rouvert")
        h2.sched.tick()
        XCTAssertEqual(h2.exec.runs(), ["veille"])
    }

    func testRecoveryDoesNotReplayStartedRun() {
        let list = [dot("veille", "07:30")]
        let h1 = make(list, at: date("2026-10-28", "07:31"), async: true)
        h1.exec.block("veille", honorCancel: false)
        h1.sched.tick()
        let deadline = Date().addingTimeInterval(5)
        while h1.sched.runPhase(h1.sched.activeRunID("veille") ?? "") != .started && Date() < deadline { usleep(1000) }
        let h2 = make(list, at: date("2026-10-28", "07:40"), prefix: h1.prefix)
        XCTAssertEqual(recents(h2).last?["etat_avant"] as? String, DotRunPhase.started.rawValue)
        XCTAssertEqual(consumed(h2, "veille"), ["2026-10-28T07:30"], "un run démarré n'est pas rejoué")
        h2.sched.tick()
        XCTAssertTrue(h2.exec.runs().isEmpty)
        h1.exec.release("veille")
        waitIdle(h1, "veille")
    }
}
