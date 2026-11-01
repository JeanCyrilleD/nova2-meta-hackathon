import XCTest
@testable import NovaCore

/// PHASE 2 (brief Nova 2, §2.6) — T1 à T25 + garde-fous du registre, de la politique de données et du grand livre.
/// Tout est simulé : aucun réseau, aucune clé, aucun appel payant. Les fichiers lus sont Config/*.json du dépôt ;
/// le grand livre est une base SQLite temporaire (jamais celle de Nova).
final class Phase2Tests: XCTestCase {

    // MARK: - Outils

    /// Version hackathon Meta : le moteur de routage v2 est testé sur un registre FICTIF (fournisseurs « vendor-* »),
    /// Tests/NovaCoreTests/Fixtures/routage_v2/ — aucun modèle non Meta n'existe dans la configuration réelle (Config/).
    static var configDir: String {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .appendingPathComponent("Fixtures").appendingPathComponent("routage_v2").path
    }
    func json(_ name: String) throws -> [String: Any] {
        let d = try XCTUnwrap(FileManager.default.contents(atPath: Phase2Tests.configDir + "/" + name), "Config/\(name) absent")
        return try XCTUnwrap((try JSONSerialization.jsonObject(with: d)) as? [String: Any])
    }
    func reg() throws -> BrainRegistry { try XCTUnwrap(BrainRegistry.load(configDir: Phase2Tests.configDir), "Config/brains.json illisible") }
    func date(_ s: String) -> Date { ISO8601DateFormatter().date(from: s)! }
    func usd(_ m: Micros?) -> Double { Money.usd(m ?? -1_000_000_000) }
    func tmpLedger() throws -> (CostLedger, String) {
        let p = NSTemporaryDirectory() + "nova-phase2-" + UUID().uuidString + ".sqlite"
        return (try XCTUnwrap(CostLedger(path: p)), p)
    }
    /// Envoi simulé, même logique que Router.chat en v2 : réserver PUIS appeler ; renvoie le nombre d'appels « réseau ».
    func simulateSend(_ plan: RoutePlan, ledger: CostLedger, reg: BrainRegistry, task: String, now: Date) -> Int {
        var calls = 0
        for c in plan.candidates {
            guard case .reserved(let id) = ledger.reserve(task: task, lane: .foreground, brain: c.brainId, profile: "t", dataClass: plan.dataClass,
                                                         estimate: c.estimate, caps: CostLedger.Caps(reg), now: now) else { continue }
            calls += 1
            ledger.settle(id, usage: Usage(input: 10, output: 10), cost: 1, now: now)
            break
        }
        return calls
    }
    let wed0730: String = "2026-11-04T07:30:00Z"
    let tol: Double = 0.0001

    // MARK: - Registre et budget

    func testRegistryLoadsBudgetInMicros() throws {
        let r = try reg()
        XCTAssertEqual(r.monthlyHardCap, 125_000_000)
        XCTAssertEqual(r.monthlyPlanned, 110_000_000)
        XCTAssertEqual(r.dayCapBackground, 1_200_000)
        XCTAssertEqual(r.dayCapForeground, 2_800_000)
        XCTAssertEqual(r.perTaskCap, 750_000)
        XCTAssertEqual(r.alertThresholdsPct, [50, 80, 95])
        for id in ["alpha-main-5", "alpha-max-5", "alpha-mini-5", "beta-sol-6", "gamma-pro-3", "delta-flash", "delta-pro-4", "epsilon-flash-5", "epsilon-5", "celeris-1"] {
            XCTAssertNotNil(r.brains[id], "cerveau du brief absent : \(id)")
        }
        XCTAssertNil(r.brains["epsilon-flash-5-high"]); XCTAssertNil(r.brains["vendordelta-v4-flash"]); XCTAssertNil(r.brains["gamma-pro-3-highspeed"])
        for p in ["reflex", "triage", "main", "deep", "bulk_public", "analysis_public", "long_public", "visual_public", "verify"] {
            XCTAssertNotNil(r.profiles[p], "profil absent : \(p)")
        }
    }

    /// T24 : allocations = 110 ≤ 125.
    func testT24AllocationsMatchPlanned() throws {
        let r = try reg()
        XCTAssertEqual(r.allocationTotal, 110_000_000)
        XCTAssertEqual(r.allocationTotal, r.monthlyPlanned)
        XCTAssertLessThanOrEqual(r.allocationTotal, r.monthlyHardCap)
    }

    func testMoneyIsIntegerAndRoundsUp() {
        XCTAssertEqual(Money.micros(usd: 0.006), 6_000)
        XCTAssertEqual(Money.micros(usd: 0.125), 125_000)
        XCTAssertEqual(Money.mulDivCeil(1, 1, 3), 1, "arrondi au supérieur : jamais sous-compté")
        XCTAssertEqual(Money.mulDivCeil(3, 1, 3), 1)
        XCTAssertEqual(Money.mulDivCeil(10_000_000, 50_000_000_000_000, 1_000_000_000_000), 500_000_000)
    }

    // MARK: - T1–T7 : coûts (±0,0001 USD)

    func testT1VendordeltaFlashOffpeak() throws {
        let r = try reg()
        XCTAssertEqual(usd(r.cost("delta-flash", usage: Usage(input: 1_000_000, output: 1_000_000), peak: false)), 0.75, accuracy: tol)
    }
    func testT2VendordeltaFlashPeak() throws {
        let r = try reg()
        XCTAssertEqual(usd(r.cost("delta-flash", usage: Usage(input: 1_000_000, output: 1_000_000), peak: true)), 1.50, accuracy: tol)
        XCTAssertEqual(usd(r.cost("delta-flash", usage: Usage(input: 1_000_000, output: 1_000_000), at: date(wed0730))), 1.50, accuracy: tol, "07:30 un mercredi = pointe")
    }
    func testT3Alphamain() throws {
        let r = try reg()
        XCTAssertEqual(usd(r.cost("alpha-main-5", usage: Usage(input: 1_000_000, output: 100_000))), 3.00, accuracy: tol)
    }
    func testT4GptSolLongContext() throws {
        let r = try reg()
        XCTAssertEqual(usd(r.cost("beta-sol-6", usage: Usage(input: 300_000, output: 10_000))), 1.35, accuracy: tol)
        XCTAssertEqual(usd(r.cost("beta-sol-6", usage: Usage(input: 272_000, output: 10_000))), 0.644, accuracy: tol, "au seuil exact : tarif normal")
    }
    func testT5GammaBatch() throws {
        let r = try reg()
        XCTAssertEqual(usd(r.cost("gamma-pro-3", usage: Usage(input: 1_000_000, output: 1_000_000), batch: true)), 7.20, accuracy: tol)
    }
    func testT6AlphamaxBatch() throws {
        let r = try reg()
        XCTAssertEqual(usd(r.cost("alpha-max-5", usage: Usage(input: 1_000_000, output: 1_000_000), batch: true)), 12.00, accuracy: tol)
    }
    func testT7EpsilonFlash() throws {
        let r = try reg()
        XCTAssertEqual(usd(r.cost("epsilon-flash-5", usage: Usage(input: 10_000_000, output: 2_000_000))), 2.50, accuracy: tol)
    }
    /// Doc officielle (écart signalé au brief) : Alphamini ×5 sur toute la requête au-delà de 100 000 jetons d'entrée, cache compris.
    func testAlphaminiLongPromptAndCache() throws {
        let r = try reg()
        XCTAssertEqual(usd(r.cost("alpha-mini-5", usage: Usage(input: 100_000, output: 1_000))), 0.0105, accuracy: tol)
        XCTAssertEqual(usd(r.cost("alpha-mini-5", usage: Usage(input: 90_000, cacheRead: 20_000, output: 1_000))), 0.045 + 0.001 + 0.0025, accuracy: tol)
    }
    /// Grille datée (prix = données) : Argon passe à 4 / 20 le 01/12/2026.
    func testScheduledPriceChange() throws {
        let r = try reg()
        let u = Usage(input: 1_000_000, output: 0)
        XCTAssertEqual(usd(r.cost("zeta-argon-4", usage: u, at: date("2026-11-30T12:00:00Z"))), 2.0, accuracy: tol)
        XCTAssertEqual(usd(r.cost("zeta-argon-4", usage: u, at: date("2026-12-01T00:00:00Z"))), 4.0, accuracy: tol)
    }

    // MARK: - T8–T12 : heures de pointe Vendordelta (UTC, début inclus, fin exclue)

    func testT8T9T10PeakWindows() throws {
        let p = try reg().peakWindows
        XCTAssertTrue(p.isPeak(date("2026-11-04T07:30:00Z")), "T8 mercredi 07:30 → pointe")
        XCTAssertFalse(p.isPeak(date("2026-11-04T05:00:00Z")), "T9 05:00 → hors pointe")
        XCTAssertTrue(p.isPeak(date("2026-11-04T03:59:00Z")), "T10 03:59 → pointe")
        XCTAssertTrue(p.isPeak(date("2026-11-04T03:59:59Z")))
        XCTAssertFalse(p.isPeak(date("2026-11-04T04:00:00Z")), "T10 04:00 → hors pointe")
        XCTAssertTrue(p.isPeak(date("2026-11-04T01:00:00Z")), "début inclus")
        XCTAssertFalse(p.isPeak(date("2026-11-04T10:00:00Z")), "fin exclue")
    }
    func testT11Saturday() throws {
        XCTAssertFalse(try reg().peakWindows.isPeak(date("2026-11-07T07:30:00Z")), "T11 samedi 07:30 → hors pointe")
    }
    func testT12HolidayFileAndAbsentFile() throws {
        let tmp = NSTemporaryDirectory() + "nova-hol-" + UUID().uuidString + ".json"
        try Data(#"{"years_covered":[2026],"holidays":["2026-11-04"]}"#.utf8).write(to: URL(fileURLWithPath: tmp))
        defer { try? FileManager.default.removeItem(atPath: tmp) }
        let withHoliday = try XCTUnwrap(BrainRegistry.load(configDir: Phase2Tests.configDir, holidaysPathOverride: tmp))
        XCTAssertFalse(withHoliday.peakWindows.isPeak(date(wed0730)), "T12 jour férié du fichier 07:30 → hors pointe")
        XCTAssertEqual(usd(withHoliday.cost("delta-flash", usage: Usage(input: 1_000_000, output: 1_000_000), at: date(wed0730))), 0.75, accuracy: tol)
        let absent = try XCTUnwrap(BrainRegistry.load(configDir: Phase2Tests.configDir, holidaysPathOverride: "/nonexistent/cn_public_holidays.json"))
        XCTAssertNil(absent.peakWindows.holidays)
        XCTAssertTrue(absent.peakWindows.isPeak(date(wed0730)), "T12 fichier absent → estimé pointe")
        XCTAssertEqual(usd(absent.cost("delta-flash", usage: Usage(input: 1_000_000, output: 1_000_000), at: date(wed0730))), 1.50, accuracy: tol)
        // Fichier officiel livré : Fête nationale (jeudi 01/10/2026) → hors pointe ; 2027 non couvert → pointe.
        let real = try reg()
        XCTAssertFalse(real.peakWindows.isPeak(date("2026-10-01T07:30:00Z")))
        XCTAssertTrue(real.peakWindows.isPeak(date("2027-01-01T07:30:00Z")), "année non couverte = fichier absent → pointe")
    }

    // MARK: - Classe de données

    func testDataClassMostSensitiveAndDefaultPersonal() {
        XCTAssertEqual(DataClass.resolve([]), .personal)
        XCTAssertEqual(DataClass.resolve([nil]), .personal, "dataClass absent → personal")
        XCTAssertEqual(DataClass.resolve(["public", "public"]), .publicData)
        XCTAssertEqual(DataClass.resolve(["public", nil]), .personal)
        XCTAssertEqual(DataClass.resolve(["public", "personal", "sci_internal"]), .sciInternal)
        XCTAssertEqual(DataClass.resolve(["public", "vault"]), .vault)
        XCTAssertEqual(DataClass.resolve(["public", "bizarre"]), .vault, "étiquette inconnue → la plus stricte")
    }

    // MARK: - T13–T19, T25 : routage et politique de données

    func testT13TriagePersonalAlphamini() throws {
        let r = try reg()
        let p = RoutePlanner.plan(RouteRequest(profile: "triage", items: ["personal"]), reg: r, ctx: PolicyContext(now: date(wed0730)), budget: BudgetView())
        XCTAssertEqual(p.dataClass, .personal)
        XCTAssertEqual(p.candidates.first?.brainId, "alpha-mini-5")
    }
    func testT14BulkPublicVendordeltaFlash() throws {
        let r = try reg()
        let p = RoutePlanner.plan(RouteRequest(profile: "bulk_public", items: ["public", "public"]), reg: r, ctx: PolicyContext(now: date("2026-11-04T05:00:00Z")), budget: BudgetView())
        XCTAssertEqual(p.dataClass, .publicData)
        XCTAssertEqual(p.candidates.first?.brainId, "delta-flash")
        XCTAssertEqual(p.candidates.first?.peak, false)
    }
    /// Le fond n'utilise pas Vendordelta en heure de pointe (2.5.7) : il passe au suivant de la chaîne.
    func testBulkBackgroundSkipsVendordeltaAtPeak() throws {
        let r = try reg()
        let p = RoutePlanner.plan(RouteRequest(profile: "bulk_public", items: ["public"], lane: .background), reg: r, ctx: PolicyContext(now: date(wed0730)), budget: BudgetView())
        XCTAssertEqual(p.candidates.map { $0.brainId }, ["epsilon-flash-5"])
    }
    /// T15 : bulk_public avec un élément personal → classe personal ; Vendordelta, Epsilon, Gamma exclus.
    /// NB (écart signalé) : l'amendement 2.3 autorisait Gamma en personal ; ses conditions ÉCRITES vérifiées le 31/10 ne remplissent
    /// pas la règle (entraînement possible sans accord écrit, conservation non chiffrée) → exclu par la règle, pas par le pays.
    func testT15BulkWithPersonalItemFailsClosed() throws {
        let r = try reg()
        let ctx = PolicyContext(now: date(wed0730))
        let p = RoutePlanner.plan(RouteRequest(profile: "bulk_public", items: ["public", "personal", "public"]), reg: r, ctx: ctx, budget: BudgetView())
        XCTAssertEqual(p.dataClass, .personal, "la classe est celle de l'élément le plus sensible")
        XCTAssertTrue(p.candidates.isEmpty, "aucun cerveau public-seulement ne reçoit de personal")
        if case .blocked(let cls, let why, _) = p { XCTAssertEqual(cls, .personal); XCTAssertTrue(why.contains("échec fermé")) } else { XCTFail("échec fermé attendu") }
        let personal = Set(DataPolicy.eligible(.personal, reg: r, ctx: ctx))
        for id in ["delta-flash", "delta-pro-4", "epsilon-flash-5", "epsilon-5", "gamma-pro-3"] { XCTAssertFalse(personal.contains(id), "\(id) ne doit pas recevoir de personal") }
        XCTAssertTrue(personal.isSuperset(of: ["alpha-main-5", "alpha-mini-5", "alpha-max-5", "beta-sol-6"]))
    }
    /// L'amendement s'applique par les CONDITIONS : si Gamma verse un accord écrit (pas d'entraînement, ≤ 30 j), il devient autorisé en personal.
    func testGammaAllowedOnceWrittenTermsQualify() throws {
        var t = try json("provider_terms.json")
        var prov = try XCTUnwrap(t["providers"] as? [String: Any])
        prov["vendorgamma"] = ["no_training_api": true, "retention_days": 0, "public_allowed": true, "verified": "2026-10-31"]
        t["providers"] = prov
        let r = try XCTUnwrap(BrainRegistry.build(brainsJSON: try json("brains.json"), termsJSON: t, holidays: nil))
        XCTAssertTrue(DataPolicy.check(r.brains["gamma-pro-3"]!, cls: .personal, reg: r, ctx: PolicyContext(now: date(wed0730))).ok)
        XCTAssertFalse(DataPolicy.check(r.brains["gamma-pro-3"]!, cls: .personal, reg: r, ctx: PolicyContext(now: date("2027-03-01T00:00:00Z"))).ok,
                       "conditions vérifiées il y a plus de 90 jours → refus")
    }
    func testT16MainPersonalFallbackThenFailClosed() throws {
        let r = try reg()
        let ctx = PolicyContext(now: date(wed0730))
        let req = RouteRequest(profile: "main", items: ["personal"])
        XCTAssertEqual(RoutePlanner.plan(req, reg: r, ctx: ctx, budget: BudgetView()).candidates.first?.brainId, "alpha-main-5")
        let p1 = RoutePlanner.plan(req, reg: r, ctx: ctx, budget: BudgetView(), isUp: { r.brains[$0]?.provider != "vendoralpha" })
        XCTAssertEqual(p1.candidates.map { $0.brainId }, ["beta-sol-6"])
        XCTAssertEqual(p1.dataClass, .personal, "le repli ne change pas la classe")
        let p2 = RoutePlanner.plan(req, reg: r, ctx: ctx, budget: BudgetView(), isUp: { _ in false })
        XCTAssertTrue(p2.candidates.isEmpty)
        if case .blocked(_, _, let ask) = p2 { XCTAssertFalse(ask) } else { XCTFail("échec fermé attendu") }
    }
    func testT17SciInternalBlockedAndAsks() throws {
        let r = try reg(); let (led, path) = try tmpLedger(); defer { try? FileManager.default.removeItem(atPath: path) }
        let now = date(wed0730)
        let p = RoutePlanner.plan(RouteRequest(profile: "deep", items: ["public", "sci_internal"]), reg: r, ctx: PolicyContext(now: now, sciPolicyConfirmed: false), budget: BudgetView())
        if case .blocked(let cls, let why, let ask) = p { XCTAssertEqual(cls, .sciInternal); XCTAssertTrue(ask, "Ahadi est interrogé"); XCTAssertTrue(why.contains("sciPolicyConfirmed")) }
        else { XCTFail("sci_internal doit être bloqué") }
        XCTAssertEqual(simulateSend(p, ledger: led, reg: r, task: "t17", now: now), 0)
        XCTAssertEqual(led.committed(month: "2026-11"), 0)
        let ok = RoutePlanner.plan(RouteRequest(profile: "deep", items: ["sci_internal"]), reg: r, ctx: PolicyContext(now: now, sciPolicyConfirmed: true), budget: BudgetView())
        XCTAssertEqual(ok.candidates.first?.brainId, "alpha-max-5", "confirmé : mêmes conditions que personal")
    }
    func testT18VaultWithoutTouchIDZeroCalls() throws {
        let r = try reg(); let (led, path) = try tmpLedger(); defer { try? FileManager.default.removeItem(atPath: path) }
        let now = date(wed0730)
        for ctx in [PolicyContext(now: now), PolicyContext(now: now, touchIDConfirmed: false, vaultProvider: "vendoralpha"),
                    PolicyContext(now: now, touchIDConfirmed: true, vaultProvider: nil)] {
            let p = RoutePlanner.plan(RouteRequest(profile: "main", items: ["vault"]), reg: r, ctx: ctx, budget: BudgetView())
            XCTAssertTrue(p.candidates.isEmpty)
            XCTAssertEqual(simulateSend(p, ledger: led, reg: r, task: "t18", now: now), 0, "zéro appel")
        }
        XCTAssertEqual(led.committed(month: "2026-11"), 0)
        XCTAssertTrue(DataPolicy.eligible(.vault, reg: r, ctx: PolicyContext(now: now)).isEmpty, "vault : aucune entreprise par défaut")
        let chosen = RoutePlanner.plan(RouteRequest(profile: "main", items: ["vault"]), reg: r,
                                       ctx: PolicyContext(now: now, touchIDConfirmed: true, vaultProvider: "vendoralpha"), budget: BudgetView())
        XCTAssertEqual(chosen.candidates.map { $0.brainId }, ["alpha-main-5"], "Touch ID + fournisseur choisi : celui-là seulement")
    }
    func testT19CelerisDisabledNeverChosen() throws {
        let r = try reg()
        XCTAssertFalse(DataPolicy.check(r.brains["celeris-1"]!, cls: .publicData, reg: r, ctx: PolicyContext(now: date(wed0730))).ok)
        let p = RoutePlanner.plan(RouteRequest(profile: "reflex", items: ["public"]), reg: r, ctx: PolicyContext(now: date(wed0730)), budget: BudgetView(),
                                  isUp: { $0 != "alpha-mini-5" })
        XCTAssertFalse(p.candidates.contains { $0.brainId == "celeris-1" })
        XCTAssertTrue(p.candidates.isEmpty)
        for name in r.profiles.keys {
            for items in [["public"], ["personal"]] as [[String?]] {
                let q = RoutePlanner.plan(RouteRequest(profile: name, items: items), reg: r, ctx: PolicyContext(now: date(wed0730)), budget: BudgetView())
                XCTAssertFalse(q.candidates.contains { $0.brainId == "celeris-1" }, "celeris-1 choisi par \(name)")
            }
        }
    }
    /// T25 : un service américain qui entraîne sur les données est exclu de personal exactement comme un service chinois.
    func testT25TermsNotCountry() throws {
        var b = try json("brains.json"); var t = try json("provider_terms.json")
        var brains = try XCTUnwrap(b["brains"] as? [String: Any]); var prov = try XCTUnwrap(t["providers"] as? [String: Any])
        let trains: [String: Any] = ["no_training_api": false, "retention_days": 30, "public_allowed": true, "verified": "2026-10-31"]
        let clean: [String: Any] = ["no_training_api": true, "retention_days": 30, "public_allowed": true, "verified": "2026-10-31"]
        prov["us-trains"] = trains.merging(["country": "US"]) { a, _ in a }
        prov["cn-trains"] = trains.merging(["country": "CN"]) { a, _ in a }
        prov["cn-clean"] = clean.merging(["country": "CN"]) { a, _ in a }
        for (id, pv) in [("us-model", "us-trains"), ("cn-model", "cn-trains"), ("cn-clean-model", "cn-clean")] {
            brains[id] = ["provider": pv, "enabled": true, "in": 1.0, "out": 1.0, "caps": [String](), "verified": "2026-10-31"]
        }
        b["brains"] = brains; t["providers"] = prov
        let r = try XCTUnwrap(BrainRegistry.build(brainsJSON: b, termsJSON: t, holidays: nil))
        let ctx = PolicyContext(now: date(wed0730))
        let us = DataPolicy.check(r.brains["us-model"]!, cls: .personal, reg: r, ctx: ctx)
        let cn = DataPolicy.check(r.brains["cn-model"]!, cls: .personal, reg: r, ctx: ctx)
        XCTAssertFalse(us.ok); XCTAssertFalse(cn.ok)
        if case .denied(let a) = us, case .denied(let c) = cn {
            XCTAssertEqual(a.replacingOccurrences(of: "us-trains", with: "X"), c.replacingOccurrences(of: "cn-trains", with: "X"), "même motif, quel que soit le pays")
        }
        XCTAssertTrue(DataPolicy.check(r.brains["us-model"]!, cls: .publicData, reg: r, ctx: ctx).ok)
        XCTAssertTrue(DataPolicy.check(r.brains["cn-model"]!, cls: .publicData, reg: r, ctx: ctx).ok)
        XCTAssertTrue(DataPolicy.check(r.brains["cn-clean-model"]!, cls: .personal, reg: r, ctx: ctx).ok, "un chinois aux conditions conformes passe")
    }

    /// Cerveaux réellement actifs au 31/10 (hors brief) : classés par leurs conditions écrites.
    func testActiveBrainsClassification() throws {
        let r = try reg(); let ctx = PolicyContext(now: date(wed0730))
        for id in ["muse-wonder-1.0", "muse-spark-1.3", "zeta-flash-3", "zeta-argon-4"] {
            XCTAssertTrue(DataPolicy.check(r.brains[id]!, cls: .publicData, reg: r, ctx: ctx).ok, "\(id) : public autorisé")
            XCTAssertFalse(DataPolicy.check(r.brains[id]!, cls: .personal, reg: r, ctx: ctx).ok, "\(id) : conservation non écrite ≤ 30 j → pas de personal")
        }
        for id in ["eta-dawn", "eta-sage", "ondevice-foundation", "muse-spark-1.3-contributor"] {
            for c in DataClass.allCases { XCTAssertFalse(DataPolicy.check(r.brains[id]!, cls: c, reg: r, ctx: PolicyContext(now: date(wed0730), sciPolicyConfirmed: true, touchIDConfirmed: true, vaultProvider: r.brains[id]!.provider)).ok, "\(id) bloqué (\(c.rawValue))") }
        }
        if case .denied(let why) = DataPolicy.check(r.brains["ondevice-foundation"]!, cls: .publicData, reg: r, ctx: ctx) { XCTAssertTrue(why.contains("règle 6")) }
        if case .denied(let why) = DataPolicy.check(r.brains["muse-spark-1.3-contributor"]!, cls: .publicData, reg: r, ctx: ctx) { XCTAssertTrue(why.contains("entraîne")) }
        // Contributor reste interdit même si on l'active par erreur dans brains.json.
        var b = try json("brains.json"); var brains = try XCTUnwrap(b["brains"] as? [String: Any])
        var c = try XCTUnwrap(brains["muse-spark-1.3-contributor"] as? [String: Any]); c["enabled"] = true; c["training_tier"] = false; brains["muse-spark-1.3-contributor"] = c; b["brains"] = brains
        let r2 = try XCTUnwrap(BrainRegistry.build(brainsJSON: b, termsJSON: try json("provider_terms.json"), holidays: nil))
        XCTAssertFalse(DataPolicy.check(r2.brains["muse-spark-1.3-contributor"]!, cls: .publicData, reg: r2, ctx: ctx).ok, "liste training_models du fournisseur")
    }
    func testUnknownProviderBlocked() throws {
        var b = try json("brains.json"); var brains = try XCTUnwrap(b["brains"] as? [String: Any])
        brains["mystery"] = ["provider": "nobody", "enabled": true, "in": 0.0, "out": 0.0]; b["brains"] = brains
        let r = try XCTUnwrap(BrainRegistry.build(brainsJSON: b, termsJSON: try json("provider_terms.json"), holidays: nil))
        XCTAssertFalse(DataPolicy.check(r.brains["mystery"]!, cls: .publicData, reg: r, ctx: PolicyContext()).ok, "inconnu → bloqué")
    }
    func testConstraintOrderAllowlistCapsVerifyReflex() throws {
        let r = try reg(); let ctx = PolicyContext(now: date(wed0730))
        // Liste blanche appliquée après le profil : elle ne peut que retirer, jamais ajouter un cerveau hors profil.
        let a = RoutePlanner.plan(RouteRequest(profile: "main", items: ["personal"], allowlist: ["beta-sol-6", "alpha-max-5"]), reg: r, ctx: ctx, budget: BudgetView())
        XCTAssertEqual(a.candidates.map { $0.brainId }, ["beta-sol-6"])
        // Capacité requise : visual_public exige la vision.
        let v = RoutePlanner.plan(RouteRequest(profile: "visual_public", items: ["public"]), reg: r, ctx: ctx, budget: BudgetView())
        XCTAssertEqual(v.candidates.map { $0.brainId }, ["epsilon-flash-5", "alpha-main-5"])
        let v2 = RoutePlanner.plan(RouteRequest(profile: "visual_public", items: ["personal"]), reg: r, ctx: ctx, budget: BudgetView())
        XCTAssertEqual(v2.candidates.map { $0.brainId }, ["alpha-main-5"], "même profil, données personnelles : Epsilon exclu, classe gardée")
        // verify : autre famille que le rédacteur ; public → epsilon-5, privé → beta-sol-6.
        XCTAssertEqual(RoutePlanner.plan(RouteRequest(profile: "verify", items: ["public"], writerFamily: "alpha"), reg: r, ctx: ctx, budget: BudgetView()).candidates.map { $0.brainId }, ["epsilon-5"])
        XCTAssertEqual(RoutePlanner.plan(RouteRequest(profile: "verify", items: ["personal"], writerFamily: "alpha"), reg: r, ctx: ctx, budget: BudgetView()).candidates.map { $0.brainId }, ["beta-sol-6"])
        XCTAssertTrue(RoutePlanner.plan(RouteRequest(profile: "verify", items: ["personal"], writerFamily: "gpt"), reg: r, ctx: ctx, budget: BudgetView()).candidates.isEmpty)
        // Jamais tous les modèles : une chaîne ne dépasse pas son profil.
        for (name, prof) in r.profiles { XCTAssertLessThanOrEqual(prof.chain.count + prof.chainPublic.count + prof.chainPrivate.count, 3, name) }
        // Batch pour Alphamax non urgent.
        let d = RoutePlanner.plan(RouteRequest(profile: "deep", items: ["personal"], urgent: false), reg: r, ctx: ctx, budget: BudgetView())
        XCTAssertEqual(d.candidates.first?.batch, true)
    }
    func testEpsilonFlashNeverInstant() throws {
        var b = try json("brains.json"); var p = try XCTUnwrap(b["profiles"] as? [String: Any])
        p["reflex"] = ["instant": true, "chain": ["epsilon-flash-5", "alpha-mini-5"]]; b["profiles"] = p
        let r = try XCTUnwrap(BrainRegistry.build(brainsJSON: b, termsJSON: try json("provider_terms.json"), holidays: nil))
        let q = RoutePlanner.plan(RouteRequest(profile: "reflex", items: ["public"]), reg: r, ctx: PolicyContext(now: date(wed0730)), budget: BudgetView())
        XCTAssertEqual(q.candidates.map { $0.brainId }, ["alpha-mini-5"], "epsilon-flash-5 pense toujours : jamais pour l'instantané")
    }
    func testStalePriceVerification() throws {
        let r = try reg()
        XCTAssertFalse(r.stalePrices(now: date("2026-11-15T00:00:00Z")).contains("alpha-main-5"))
        XCTAssertTrue(r.stalePrices(now: date("2026-12-15T00:00:00Z")).contains("alpha-main-5"), "> 30 jours → alerte")
        XCTAssertTrue(r.stalePrices(now: date("2026-11-01T00:00:00Z")).contains("eta-dawn"), "jamais vérifié → alerte")
    }

    // MARK: - T20–T23 : budget et grand livre

    func testT20MonthNearCapNotSentAsIs() throws {
        let r = try reg(); let (led, path) = try tmpLedger(); defer { try? FileManager.default.removeItem(atPath: path) }
        let now = date(wed0730)
        let big = CostLedger.Caps(monthHard: 1_000_000_000, dayForeground: 1_000_000_000, dayBackground: 1_000_000_000, perTask: 1_000_000_000)
        let seed = try XCTUnwrap(led.reserve(task: "seed", lane: .background, brain: "x", profile: "seed", dataClass: .publicData, estimate: 124_500_000, caps: big, now: now).id)
        led.settle(seed, usage: Usage(input: 1, output: 1), cost: 124_500_000, now: now)
        XCTAssertEqual(led.committed(month: "2026-11"), 124_500_000)
        let res = led.reserve(task: "t20", lane: .foreground, brain: "alpha-main-5", profile: "main", dataClass: .personal, estimate: 1_000_000, caps: CostLedger.Caps(r), now: now)
        XCTAssertNil(res.id, "1,00 $ sur 124,50 $ engagés : pas envoyé tel quel")
        if case .refused(let why) = res { XCTAssertTrue(why.contains("mois")) }
        let u = Usage(input: 0, output: 100_000)
        XCTAssertEqual(usd(r.cost("alpha-main-5", usage: u)), 1.0, accuracy: tol)
        let fg = RoutePlanner.plan(RouteRequest(profile: "main", items: ["personal"], estInputTokens: 0, maxOutputTokens: 100_000), reg: r, ctx: PolicyContext(now: now),
                                   budget: led.budgetView(task: "t20", lane: .foreground, now: now))
        if case .blocked(_, _, let ask) = fg { XCTAssertTrue(ask, "premier plan : demander") } else { XCTFail("plafond : pas d'envoi") }
        let bg = RoutePlanner.plan(RouteRequest(profile: "main", items: ["personal"], lane: .background, estInputTokens: 0, maxOutputTokens: 100_000), reg: r, ctx: PolicyContext(now: now),
                                   budget: led.budgetView(task: "t20b", lane: .background, now: now))
        if case .queued = bg {} else { XCTFail("fond : mis en file") }
        // Un modèle autorisé moins cher passe : 1 000 jetons de sortie Alphamain = 0,01 $.
        let cheap = RoutePlanner.plan(RouteRequest(profile: "main", items: ["personal"], estInputTokens: 0, maxOutputTokens: 1_000), reg: r, ctx: PolicyContext(now: now),
                                      budget: led.budgetView(task: "t20c", lane: .foreground, now: now))
        XCTAssertEqual(cheap.candidates.first?.brainId, "alpha-main-5")
    }
    func testT21ParallelReservationsOnlyOne() throws {
        let r = try reg()
        for round in 0..<10 {
            let (a, path) = try tmpLedger(); defer { try? FileManager.default.removeItem(atPath: path) }
            let b = try XCTUnwrap(CostLedger(path: path), "seconde connexion (autre processus simulé)")
            let now = date(wed0730)
            final class Counter: @unchecked Sendable { let lock = NSLock(); var n = 0 }
            let ok = Counter()
            DispatchQueue.concurrentPerform(iterations: 2) { i in
                let led: CostLedger = i == 0 ? a : b
                let res = led.reserve(task: "t21-\(round)-\(i)", lane: .background, brain: "delta-flash", profile: "bulk_public", dataClass: .publicData,
                                      estimate: 700_000, caps: CostLedger.Caps(r), now: now)
                if res.id != nil { ok.lock.lock(); ok.n += 1; ok.lock.unlock() }
            }
            XCTAssertEqual(ok.n, 1, "deux tâches à 0,70 $ contre 1,20 $ de marge du jour : une seule réservée (tour \(round))")
            XCTAssertEqual(a.committed(day: "2026-11-04", lane: .background), 700_000)
        }
    }
    func testT22UnchangedDotFingerprintZeroCalls() throws {
        let (led, path) = try tmpLedger(); defer { try? FileManager.default.removeItem(atPath: path) }
        var calls = 0
        let call: () -> String? = { calls += 1; return "synthèse \(calls)" }
        let r1 = led.reuseIfUnchanged(key: "dot:veille", parts: ["consigne", "flux RSS A"], call: call)
        let r2 = led.reuseIfUnchanged(key: "dot:veille", parts: ["consigne", "flux RSS A"], call: call)
        XCTAssertEqual(calls, 1, "Dot à empreinte inchangée : zéro appel")
        XCTAssertFalse(r1.reused); XCTAssertTrue(r2.reused); XCTAssertEqual(r2.result, "synthèse 1")
        _ = led.reuseIfUnchanged(key: "dot:veille", parts: ["consigne", "flux RSS B"], call: call)
        XCTAssertEqual(calls, 2, "entrée changée : nouvel appel")
        XCTAssertNotEqual(InputFingerprint.of(["ab", "c"]), InputFingerprint.of(["a", "bc"]))
        var failing = 0
        _ = led.reuseIfUnchanged(key: "dot:x", parts: ["p"], call: { failing += 1; return nil })
        _ = led.reuseIfUnchanged(key: "dot:x", parts: ["p"], call: { failing += 1; return nil })
        XCTAssertEqual(failing, 2, "un échec n'est jamais mémorisé")
    }
    func testT23NoUsageKeepsReservation() throws {
        let r = try reg(); let (led, path) = try tmpLedger(); defer { try? FileManager.default.removeItem(atPath: path) }
        let now = date(wed0730)
        let id = try XCTUnwrap(led.reserve(task: "t23", lane: .foreground, brain: "alpha-mini-5", profile: "triage", dataClass: .personal, estimate: 300_000, caps: CostLedger.Caps(r), now: now).id)
        led.settle(id, usage: nil, cost: nil, now: now)
        XCTAssertEqual(led.state(id), "kept")
        XCTAssertEqual(led.committed(month: "2026-11"), 300_000, "usage absent ≠ gratuit")
        let id2 = try XCTUnwrap(led.reserve(task: "t23b", lane: .foreground, brain: "alpha-mini-5", profile: "triage", dataClass: .personal, estimate: 200_000, caps: CostLedger.Caps(r), now: now).id)
        led.settle(id2, usage: Usage(), cost: 0, now: now)
        XCTAssertEqual(led.state(id2), "kept", "usage vide = usage absent")
        let id3 = try XCTUnwrap(led.reserve(task: "t23c", lane: .foreground, brain: "alpha-mini-5", profile: "triage", dataClass: .personal, estimate: 200_000, caps: CostLedger.Caps(r), now: now).id)
        led.settle(id3, usage: Usage(input: 1000, output: 100), cost: 150, now: now)
        XCTAssertEqual(led.state(id3), "settled")
        XCTAssertEqual(led.committed(month: "2026-11"), 300_000 + 200_000 + 150, "soldé au coût réel")
        let id4 = try XCTUnwrap(led.reserve(task: "t23d", lane: .foreground, brain: "alpha-mini-5", profile: "triage", dataClass: .personal, estimate: 100_000, caps: CostLedger.Caps(r), now: now).id)
        led.release(id4, reason: "HTTP 401 avant traitement")
        XCTAssertEqual(led.state(id4), "released")
        XCTAssertEqual(led.committed(month: "2026-11"), 500_150)
    }
    func testLedgerSurvivesRestartAndMonthChange() throws {
        let r = try reg()
        let path = NSTemporaryDirectory() + "nova-phase2-" + UUID().uuidString + ".sqlite"
        defer { for s in ["", "-wal", "-shm"] { try? FileManager.default.removeItem(atPath: path + s) } }
        do {
            let led = try XCTUnwrap(CostLedger(path: path))
            _ = try XCTUnwrap(led.reserve(task: "a", lane: .foreground, brain: "b", profile: "main", dataClass: .personal, estimate: 400_000, caps: CostLedger.Caps(r), now: date("2026-10-31T23:59:00Z")).id)
        }   // « plantage » : la réservation n'a jamais été soldée, l'objet est détruit
        let again = try XCTUnwrap(CostLedger(path: path))
        XCTAssertEqual(again.committed(month: "2026-10"), 400_000, "survit au redémarrage")
        XCTAssertEqual(again.committed(month: "2026-11"), 0, "changement de mois UTC")
        XCTAssertEqual(again.committed(day: "2026-11-01", lane: .foreground), 0)
        XCTAssertNotNil(again.reserve(task: "a", lane: .foreground, brain: "b", profile: "main", dataClass: .personal, estimate: 300_000, caps: CostLedger.Caps(r), now: date("2026-11-01T00:01:00Z")).id)
        XCTAssertNil(again.reserve(task: "a", lane: .foreground, brain: "b", profile: "main", dataClass: .personal, estimate: 100_000, caps: CostLedger.Caps(r), now: date("2026-11-01T00:02:00Z")).id,
                     "plafond par tâche 0,75 $ : 0,40 + 0,30 + 0,10 > 0,75")
    }
    func testAlertThresholdsFireOnce() throws {
        let (led, path) = try tmpLedger(); defer { try? FileManager.default.removeItem(atPath: path) }
        let now = date(wed0730)
        let big = CostLedger.Caps(monthHard: 1_000_000_000, dayForeground: 1_000_000_000, dayBackground: 1_000_000_000, perTask: 1_000_000_000)
        _ = led.reserve(task: "x", lane: .foreground, brain: "b", profile: "p", dataClass: .publicData, estimate: 101_000_000, caps: big, now: now)
        XCTAssertEqual(led.newlyCrossedAlerts(thresholdsPct: [50, 80, 95], cap: 125_000_000, now: now), [50, 80])
        XCTAssertEqual(led.newlyCrossedAlerts(thresholdsPct: [50, 80, 95], cap: 125_000_000, now: now), [], "une seule fois par mois")
    }
}
