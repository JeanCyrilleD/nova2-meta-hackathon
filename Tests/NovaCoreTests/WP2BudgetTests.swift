import XCTest
@testable import NovaCore

/// WP2 — budget en échec fermé sur le chemin EN SERVICE (v1, routage_v2 = false) : décision explicite, facturation explicite,
/// réservations atomiques dans le grand livre de la phase 2, dérogations. Tout est simulé : aucun réseau, aucune clé, aucun appel
/// payant ; prix lus dans le registre fictif Tests/NovaCoreTests/Fixtures/routage_v2 ; grand livre = base SQLite temporaire (jamais celle de Nova) ; aucun fichier de
/// Nova n'est lu ni écrit (les fonctions testées sont celles de SpendPolicy / CostLedger, pas les enveloppes LLMSpend).
final class WP2BudgetTests: XCTestCase {

    // MARK: - Outils

    /// Version hackathon Meta : la politique de dépense (générique) est exercée sur un registre et un catalogue FICTIFS
    /// (fournisseurs « vendor-* », Tests/NovaCoreTests/Fixtures/routage_v2/) en plus du catalogue réel 100 % Meta.
    static var configDir: String {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .appendingPathComponent("Fixtures").appendingPathComponent("routage_v2").path
    }
    /// Catalogue FICTIF (fournisseurs « vendor-* ») pour exercer la politique de dépense sans aucun modèle réel non Meta.
    static let fictionalBrains: [BrainSpec] = [
        BrainSpec(id: "alpha-mini-direct", label: "alpha-mini-direct", kind: .chat, baseURL: "https://api.vendoralpha.example/v1/messages", model: "alpha-mini-5", keys: KeyChain([], fallback: "x"), tags: ["rapide"]),
        BrainSpec(id: "alpha-main-direct", label: "alpha-main-direct", kind: .chat, baseURL: "https://api.vendoralpha.example/v1/messages", model: "alpha-main-5", keys: KeyChain([], fallback: "x"), tags: ["rapide", "puissant"]),
        BrainSpec(id: "alpha-max-direct", label: "alpha-max-direct", kind: .chat, baseURL: "https://api.vendoralpha.example/v1/messages", model: "alpha-max-5", keys: KeyChain([], fallback: "x"), tags: ["puissant"]),
        BrainSpec(id: "alpha-fable-direct", label: "alpha-fable-direct", kind: .chat, baseURL: "https://api.vendoralpha.example/v1/messages", model: "alpha-fable-5", keys: KeyChain([], fallback: "x"), tags: ["puissant"]),
        BrainSpec(id: "beta-sol", label: "beta-sol", kind: .chat, baseURL: "https://api.vendorbeta.example/v1/chat/completions", model: "beta-sol-6", keys: KeyChain([], fallback: "x"), tags: ["rapide", "puissant"]),
        BrainSpec(id: "zeta-flash", label: "zeta-flash", kind: .chat, baseURL: "https://api.vendorzeta.example/v1beta/chat/completions", model: "zeta-flash-3", keys: KeyChain([], fallback: "x"), tags: ["rapide"]),
        BrainSpec(id: "zeta-argon", label: "zeta-argon", kind: .chat, baseURL: "https://api.vendorzeta.example/v1beta/chat/completions", model: "zeta-argon-4", keys: KeyChain([], fallback: "x"), tags: ["puissant"]),
        BrainSpec(id: "epsilon-flash", label: "epsilon-flash", kind: .chat, baseURL: "https://api.vendorepsilon.example/api/paas/v4/chat/completions", model: "epsilon-flash-5", keys: KeyChain([], fallback: "x"), tags: ["rapide"]),
        BrainSpec(id: "epsilon-5", label: "epsilon-5", kind: .chat, baseURL: "https://api.vendorepsilon.example/api/paas/v4/chat/completions", model: "epsilon-5", keys: KeyChain([], fallback: "x"), tags: ["puissant"]),
        BrainSpec(id: "gamma-direct", label: "gamma-direct", kind: .chat, baseURL: "https://api.vendorgamma.example/v1/chat/completions", model: "gamma-k3", keys: KeyChain([], fallback: "x"), tags: ["puissant"]),
        BrainSpec(id: "delta-direct", label: "delta-direct", kind: .chat, baseURL: "https://api.vendordelta.example/chat/completions", model: "delta-chat", keys: KeyChain([], fallback: "x"), tags: ["rapide"]),
        BrainSpec(id: "lambda-direct", label: "lambda-direct", kind: .chat, baseURL: "https://api.vendorlambda.example/v1/chat/completions", model: "lambda-4", keys: KeyChain([], fallback: "x"), tags: ["puissant"]),
        BrainSpec(id: "mu-flash-cloud", label: "mu-flash-cloud", kind: .chat, baseURL: "http://127.0.0.1:8089/v1/chat/completions", model: "mu-m3-flash", keys: KeyChain([], fallback: "x"), tags: ["rapide"]),
        BrainSpec(id: "eta-dawn", label: "eta-dawn", kind: .chat, baseURL: "https://api.vendoreta.example/v1/chat/completions", model: "eta-dawn", keys: KeyChain([], fallback: "x"), tags: ["puissant"]),
        BrainSpec(id: "eta-sage", label: "eta-sage", kind: .chat, baseURL: "https://api.vendoreta.example/v1/chat/completions", model: "eta-sage", keys: KeyChain([], fallback: "x"), tags: ["puissant"]),
        BrainSpec(id: "kappa-free", label: "kappa-free", kind: .chat, baseURL: "https://api.vendorkappa.example/v1/chat/completions", model: "kappa-small", keys: KeyChain([], fallback: "x"), tags: ["rapide"]),
        BrainSpec(id: "nu-free", label: "nu-free", kind: .chat, baseURL: "http://127.0.0.1:8090/v1/chat/completions", model: "auto/best-free", keys: KeyChain([], fallback: "x"), tags: ["rapide", "puissant"]),
        BrainSpec(id: "nu-local", label: "nu-local", kind: .chat, baseURL: "http://127.0.0.1:8090/v1/chat/completions", model: "auto", keys: KeyChain([], fallback: "x"), tags: ["rapide", "puissant"]),
        BrainSpec(id: "nu1-repi", label: "nu1-repi", kind: .chat, baseURL: "https://api.vendornu1.example/v1/chat/completions", model: "vendor-repi-70b", keys: KeyChain([], fallback: "x"), tags: ["repi"]),
        BrainSpec(id: "nu2-repi", label: "nu2-repi", kind: .chat, baseURL: "https://api.vendornu2.example/v1/chat/completions", model: "vendor-repi-70b-b", keys: KeyChain([], fallback: "x"), tags: ["repi"]),
    ]
    /// Grille historique FICTIVE (mêmes tarifs que la grille v1 d'origine, fournisseurs renommés).
    static let fictionalLegacy: [PriceVersion] = {
        let an: String = "api.vendoralpha.example", g: String = "api.vendorzeta.example"
        let tierLong = LongContext(thresholdInputTokens: 100_000, inMilli: 5000, outMilli: 5000, cacheMilli: 5000)
        return [
            PriceBook.v1("alpha-main-direct", "vendoralpha", an, "alpha-main-5", PriceBook.usd(2.0, 10.0, cr: 0.20, cw: 2.5), verified: "2026-10-31", note: "fictif"),
            PriceBook.v1("alpha-max-direct", "vendoralpha", an, "alpha-max-5", PriceBook.usd(4.0, 20.0, cr: 0.20, cw: 5.0), verified: "2026-10-30", note: "fictif"),
            PriceBook.v1("alpha-mini-direct", "vendoralpha", an, "alpha-mini-5", PriceBook.usd(0.10, 0.50, cr: 0.01, cw: 0.125), verified: "2026-10-31", note: "fictif", lc: tierLong),
            PriceBook.v1("alpha-fable-direct", "vendoralpha", an, "alpha-fable-5", PriceBook.usd(10.0, 50.0, cr: 0.25, cw: 12.5), verified: "2026-10-31", note: "fictif"),
            PriceBook.v1("gamma-direct", "vendorgamma", "api.vendorgamma.example", "gamma-k3", PriceBook.usd(3.0, 15.0, cr: 0.30), verified: "2026-10-31", note: "fictif"),
            PriceBook.v1("zeta-argon", "vendorzeta", g, "zeta-argon-4", PriceBook.usd(2.0, 10.0, cr: 0.10), verified: nil, note: "fictif"),
            PriceBook.v1("zeta-flash", "vendorzeta", g, "zeta-flash-3", PriceBook.usd(0.75, 3.75, cr: 0.075), verified: nil, note: "fictif"),
            PriceBook.v1("beta-sol", "vendorbeta", "api.vendorbeta.example", "beta-sol-6", PriceBook.usd(2.5, 15.0, cr: 0.25), verified: nil, note: "fictif"),
            PriceBook.v1("delta-direct", "vendordelta", "api.vendordelta.example", "delta-chat", PriceBook.usd(0.28, 0.42, cr: 0.028), verified: nil, note: "fictif"),
            PriceBook.v1("epsilon-5", "vendorepsilon", "api.vendorepsilon.example", "epsilon-5", PriceBook.usd(1.0, 3.2, cr: 0.2), verified: nil, note: "fictif"),
            PriceBook.v1("mu-flash-cloud", "vendormu", "127.0.0.1", "mu-m3-flash", PriceBook.usd(0.15, 0.60), verified: nil, note: "fictif"),
        ]
    }()
    static let fictionalHosts: [String: String] = ["meta": "api.meta.ai", "baseten": "inference.baseten.co", "vendoralpha": "api.vendoralpha.example", "vendorbeta": "api.vendorbeta.example", "vendorgamma": "api.vendorgamma.example", "vendordelta": "api.vendordelta.example", "vendorepsilon": "api.vendorepsilon.example", "vendorzeta": "api.vendorzeta.example", "vendoreta": "api.vendoreta.example"]
    static let fictionalCredits: [String: String] = ["nu1-repi": "crédits fournisseur (repi) : consommés, pas gratuits — aucun prix versionné"]
    static let fictionalPremium: Set<String> = ["alpha-main-direct", "alpha-max-direct", "alpha-fable-direct", "wonder-1.0", "zeta-argon", "beta-sol", "epsilon-5"]
    func book() throws -> PriceBook {
        PriceBook(registry: try XCTUnwrap(BrainRegistry.load(configDir: WP2BudgetTests.configDir), "Fixtures/routage_v2/brains.json illisible"),
                  legacy: PriceBook.legacyV1 + WP2BudgetTests.fictionalLegacy, hosts: WP2BudgetTests.fictionalHosts,
                  credits: WP2BudgetTests.fictionalCredits, premium: WP2BudgetTests.fictionalPremium)
    }
    let catalog: [BrainSpec] = Catalog.defaults() + WP2BudgetTests.fictionalBrains
    func spec(_ id: String) throws -> BrainSpec { try XCTUnwrap(catalog.first { $0.id == id }, "\(id) absent du catalogue") }
    var localEngine: BrainSpec {
        BrainSpec(id: "local", label: "Local", kind: .local, baseURL: "http://127.0.0.1:8089/v1/chat/completions", model: "m", keys: KeyChain([], fallback: "x"), tags: ["local"])
    }
    func tmpLedger() throws -> (CostLedger, String) {
        let p = NSTemporaryDirectory() + "nova-wp2-" + UUID().uuidString + ".sqlite"
        return (try XCTUnwrap(CostLedger(path: p)), p)
    }
    func cleanup(_ p: String) { for s in ["", "-wal", "-shm"] { try? FileManager.default.removeItem(atPath: p + s) } }
    let now: Date = ISO8601DateFormatter().date(from: "2026-11-04T07:30:00Z")!
    let big: Micros = 1_000_000_000
    func caps(month: Micros = 1_000_000_000, bg: Micros = 1_000_000_000, bench: Micros = 1_000_000_000) -> CostLedger.Caps {
        CostLedger.Caps(monthHard: month, dayForeground: month, dayBackground: bg, perTask: Int64.max / 4, dayBench: bench)
    }
    func decide(_ chain: [BrainSpec], lane: SpendLane, pinned: String? = nil, state: SpendState, freeFallback: Bool = false) throws -> ChainDecision {
        let bk = try book()
        return SpendPolicy.decide(chain: chain, all: catalog, usable: { _ in true }, lane: lane, pinned: pinned, state: state, book: bk, freeFallback: freeFallback,
                                  estimate: { s, b in SpendPolicy.estimate(book: bk, billing: b, estIn: 1000, maxOut: 1000) })
    }
    func ids(_ d: ChainDecision) -> [String] { d.chain.map { $0.id } }
    /// Grand livre déjà à `amount` engagés ce mois (voie premier plan), sans passer par les plafonds testés.
    func seed(_ led: CostLedger, _ amount: Micros, lane: Lane = .foreground) throws {
        let id = try XCTUnwrap(led.reserve(task: "seed-\(UUID().uuidString)", lane: lane, brain: "x", profile: "seed", dataClass: .personal, estimate: amount,
                                           caps: caps(), now: now).id)
        led.settle(id, usage: Usage(input: 1, output: 1), cost: amount, now: now)
    }

    // MARK: - Facturation explicite

    func testUnknownBillingIsNeverFree() throws {
        let bk = try book()
        for id in ["lambda-direct", "kappa-free", "spark-open-hf", "nu-free", "nu-local", "eta-dawn", "eta-sage", "nu1-repi"] {   // 01/11 : spark-open-baseten a désormais un tarif versionné (page Baseten du compte)
            let b = bk.billing(try spec(id))
            XCTAssertTrue(b.isUnknown, "\(id) : facturation inconnue attendue, obtenu \(b.label)")
            XCTAssertGreaterThan(bk.cost(b, usage: Usage(input: 1000, output: 1000)), 0, "\(id) : inconnu ≠ gratuit")
        }
        // Crédits fournisseur ≠ endpoint gratuit.
        if case .unknownBilling(let why) = bk.billing(try spec("nu1-repi")) { XCTAssertTrue(why.contains("crédits")) } else { XCTFail() }
        // 01/11 : Muse Spark Open sur Baseten — 1,25 $ / 4,25 $ par M (page Baseten du compte, 01/11/2026) : compté, jamais gratuit, jamais inconnu.
        let bt = bk.billing(try spec("spark-open-baseten"))
        XCTAssertEqual(bt.label, "metered")
        XCTAssertEqual(bk.cost(bt, usage: Usage(input: 1_000_000, output: 1_000_000)), 5_500_000)
        // Paliers payants publiés : comptés, jamais gratuits.
        for id in ["mu-flash-cloud", "epsilon-flash"] {
            let b = bk.billing(try spec(id))
            XCTAssertEqual(b.label, "metered", id)
            XCTAssertGreaterThan(bk.cost(b, usage: Usage(input: 1_000_000)), 0, id)
        }
        // Le prix suit le triplet endpoint / modèle, pas l'id amical.
        var moved = try spec("alpha-main-direct"); moved.baseURL = "https://proxy.example.com/v1/messages"
        XCTAssertTrue(bk.billing(moved).isUnknown, "même id, autre endpoint : pas de prix hérité")
        var renamed = try spec("alpha-main-direct"); renamed.model = "alpha-main-9"
        XCTAssertTrue(bk.billing(renamed).isUnknown, "même id, autre modèle : pas de prix hérité")
        // Tarif plafond = le plus cher connu (Fable 10 / 50 $).
        XCTAssertEqual(bk.ceiling.inp, 10_000_000); XCTAssertEqual(bk.ceiling.out, 50_000_000)
        XCTAssertEqual(bk.cost(bk.billing(try spec("lambda-direct")), usage: Usage(input: 1_000_000, output: 100_000)), 15_000_000)
    }

    func testVersionedPricesWithProvenance() throws {
        let bk = try book()
        guard case .metered(let p) = bk.billing(try spec("alpha-main-direct")) else { return XCTFail("alpha-main facturé") }
        XCTAssertEqual(p.provider, "vendoralpha"); XCTAssertEqual(p.endpoint, "api.vendoralpha.example"); XCTAssertEqual(p.model, "alpha-main-5")
        XCTAssertTrue(p.version.hasPrefix("brains.json#alpha-main-5@2026-10-31"), p.version)
        XCTAssertEqual(p.verified, "2026-10-31")
        XCTAssertNotNil(p.conflict, "grille v1 (cache lu 0,20) ≠ registre (0,10) : signalé")
        // Conflit → le coût le plus élevé : 1 M jetons de cache lu = 0,20 $ (pas 0,10).
        XCTAssertEqual(bk.cost(.metered(p), usage: Usage(cacheRead: 1_000_000)), 200_000)
        // T3 du brief inchangé : 1 M + 100 K sortie = 3,00 $.
        XCTAssertEqual(bk.cost(.metered(p), usage: Usage(input: 1_000_000, output: 100_000)), 3_000_000)
        // Modèle absent du registre (gamma-k3, delta-chat) : grille historique, versionnée, provenance écrite.
        guard case .metered(let k) = bk.billing(try spec("gamma-direct")) else { return XCTFail("gamma facturé") }
        XCTAssertTrue(k.version.hasPrefix("feat_depense-v1#gamma-direct"), k.version)
        XCTAssertTrue(k.source.contains("Feat_Depense"))
        // alpha-mini : ×5 au-delà de 100 000 jetons d'entrée (les deux grilles).
        let h = bk.billing(try spec("alpha-mini-direct"))
        XCTAssertEqual(bk.cost(h, usage: Usage(input: 100_000)), 10_000)
        XCTAssertEqual(bk.cost(h, usage: Usage(input: 100_001)), 50_001)
    }

    func testVerifiedFreeAndFallback() throws {
        let bk = try book()
        XCTAssertTrue(bk.billing(localEngine).isVerifiedFree)
        XCTAssertTrue(bk.billing(try spec("muse-code")).isVerifiedFree)
        let over = SpendState(monthCommitted: 90_000_000, monthCap: 90_000_000, dayCap: 90_000_000)
        let d = try decide([try spec("alpha-main-direct"), try spec("muse-code"), try spec("alpha-mini-direct")], lane: .interactive, state: over)
        XCTAssertEqual(ids(d), ["muse-code"], "budget atteint : seul le gratuit vérifié reste")
        // Gratuit vérifié : rien n'est réservé, rien n'est compté.
        let (led, path) = try tmpLedger(); defer { cleanup(path) }
        guard case .go(let t) = SpendPolicy.preflight(ledger: led, book: bk, spec: localEngine, estIn: 1_000, maxOut: 1_000, lane: .background, caps: caps(month: 0, bg: 0), now: now)
        else { return XCTFail("gratuit vérifié refusé") }
        XCTAssertNil(t.id); XCTAssertEqual(t.estimate, 0)
        XCTAssertEqual(led.committed(month: "2026-11"), 0)
        // Moteur local ajouté ensuite par le routeur : chaîne vide rendue telle quelle (pas la chaîne d'origine).
        let ff = try decide([try spec("alpha-main-direct")], lane: .background, state: over, freeFallback: true)
        if case .eligibleChain(let c, _) = ff { XCTAssertTrue(c.isEmpty) } else { XCTFail("repli gratuit vérifié attendu") }
    }

    // MARK: - Décision explicite (plus jamais la chaîne d'origine)

    func testMonthlyCapWithOnlyPaidModels() throws {
        let paid = [try spec("alpha-main-direct"), try spec("alpha-mini-direct"), try spec("zeta-flash"), try spec("delta-direct")]
        let over = SpendState(monthCommitted: 90_000_000, monthCap: 90_000_000, dayCap: 90_000_000)
        let fg = try decide(paid, lane: .interactive, state: over)
        guard case .overrideRequired(let why, let est) = fg else { return XCTFail("premier plan : dérogation requise, obtenu \(ids(fg))") }
        XCTAssertTrue(why.contains("budget du mois")); XCTAssertGreaterThan(est, 0)
        XCTAssertTrue(ids(fg).isEmpty, "aucune chaîne rétablie")
        let bg = try decide(paid, lane: .background, state: SpendState(monthCommitted: 90_000_000, monthCap: 90_000_000, dayCap: 750_000))
        if case .blocked(let w) = bg { XCTAssertTrue(w.contains("fond")) } else { XCTFail("fond : bloqué") }
        // Budget à 0 $ : échec fermé (aucun payant), pas « illimité ».
        if case .overrideRequired = try decide(paid, lane: .interactive, state: SpendState(monthCap: 0, dayCap: 0)) {} else { XCTFail("budget 0 = aucun payant") }
        // Sous le plafond : chaîne inchangée.
        XCTAssertEqual(ids(try decide(paid, lane: .interactive, state: SpendState(monthCommitted: 1, monthCap: 90_000_000, dayCap: 90_000_000))), paid.map { $0.id })
        // Grand livre : 89,90 $ engagés (plancher JSON), 0,30 $ demandés contre 90 $ → refus « mois ».
        let (led, path) = try tmpLedger(); defer { cleanup(path) }
        let r = SpendPolicy.preflight(ledger: led, book: try book(), spec: try spec("alpha-mini-direct"), estIn: 0, maxOut: 600_000, lane: .interactive,
                                      caps: caps(month: 90_000_000), floorMonth: 89_900_000, now: now)
        if case .refused(let w) = r { XCTAssertTrue(w.contains("mois"), w) } else { XCTFail("plancher JSON respecté") }
    }

    func testBackgroundCap() throws {
        let chain = [try spec("alpha-main-direct"), try spec("zeta-flash"), try spec("alpha-mini-direct")]
        let under = try decide(chain, lane: .background, state: SpendState(monthCap: 90_000_000, dayCap: 750_000))
        XCTAssertEqual(ids(under), ["zeta-flash", "alpha-mini-direct"], "fond : jamais premium, ordre de la chaîne conservé (version Meta : plus de cerveau tiers réinséré)")
        let over = try decide(chain, lane: .background, state: SpendState(monthCap: 90_000_000, dayCommitted: 750_000, dayCap: 750_000))
        if case .blocked(let w) = over { XCTAssertTrue(w.contains("plafond du jour des tâches de fond")) } else { XCTFail("fond plafonné : bloqué") }
        // Dérogation : jamais pour le fond.
        let ov = try decide(chain, lane: .background, state: SpendState(monthCap: 90_000_000, dayCommitted: 750_000, dayCap: 750_000, overrideRemaining: big))
        if case .blocked = ov {} else { XCTFail("aucune dérogation pour le fond") }
        // Grand livre : plafond du jour du fond 0,50 $ → une seule réservation de 0,30 $.
        let (led, path) = try tmpLedger(); defer { cleanup(path) }
        let bk = try book(); let h = try spec("alpha-mini-direct")
        XCTAssertNotNil(SpendPolicy.preflight(ledger: led, book: bk, spec: h, estIn: 0, maxOut: 600_000, lane: .background, caps: caps(bg: 500_000), now: now).ticket?.id)
        if case .refused(let w) = SpendPolicy.preflight(ledger: led, book: bk, spec: h, estIn: 0, maxOut: 600_000, lane: .background, caps: caps(bg: 500_000), now: now) {
            XCTAssertTrue(w.contains("background"), w)
        } else { XCTFail("plafond du fond") }
        XCTAssertEqual(led.committed(day: "2026-11-04", lane: .background), 300_000)
    }

    func testBenchCapAndNoSilentSubstitution() throws {
        let chain = [try spec("alpha-main-direct"), try spec("beta-sol"), try spec("muse-code")]
        // Banc strict : le cerveau épinglé seul, même sous le plafond.
        XCTAssertEqual(ids(try decide(chain, lane: .bench, pinned: "beta-sol", state: SpendState(monthCap: big, dayCap: 2_000_000))), ["beta-sol"])
        // Épinglé absent de la chaîne (sans clé, en panne) : bloqué — jamais un cerveau sous l'étiquette d'un autre.
        let absent = try decide(chain, lane: .bench, pinned: "gamma-direct", state: SpendState(monthCap: big, dayCap: 2_000_000))
        if case .blocked(let w) = absent { XCTAssertTrue(w.contains("aucune substitution")) } else { XCTFail("banc : pas de substitution, obtenu \(ids(absent))") }
        // Plafond du banc atteint : dérogation requise, PAS de repli sur le gratuit (muse-code) ni sur un autre cerveau.
        let capped = try decide(chain, lane: .bench, pinned: "beta-sol", state: SpendState(monthCap: big, dayCommitted: 2_000_000, dayCap: 2_000_000))
        if case .overrideRequired(let w, _) = capped { XCTAssertTrue(w.contains("bancs")) } else { XCTFail("banc plafonné : dérogation, obtenu \(ids(capped))") }
        // Dérogation active (voie banc) : le cerveau épinglé, toujours seul.
        XCTAssertEqual(ids(try decide(chain, lane: .bench, pinned: "beta-sol", state: SpendState(monthCap: big, dayCommitted: 2_000_000, dayCap: 2_000_000, overrideRemaining: 1_000_000))), ["beta-sol"])
        // Grand livre : voie « bench » contre son propre plafond du jour.
        let (led, path) = try tmpLedger(); defer { cleanup(path) }
        let bk = try book(); let h = try spec("alpha-mini-direct")
        if case .refused(let w) = SpendPolicy.preflight(ledger: led, book: bk, spec: h, estIn: 0, maxOut: 600_000, lane: .bench, caps: caps(bench: 200_000), now: now) {
            XCTAssertTrue(w.contains("bench"), w)
        } else { XCTFail("plafond du banc") }
        XCTAssertNotNil(SpendPolicy.preflight(ledger: led, book: bk, spec: h, estIn: 0, maxOut: 600_000, lane: .interactive, caps: caps(bench: 200_000), now: now).ticket?.id,
                        "le plafond du banc ne bride pas le premier plan")
    }

    func testUnknownBillingInChains() throws {
        let state = SpendState(monthCap: big, dayCap: big)
        let chain = [try spec("lambda-direct"), try spec("alpha-mini-direct"), try spec("kappa-free")]
        XCTAssertEqual(ids(try decide(chain, lane: .interactive, state: state)), ["alpha-mini-direct"], "inconnu jamais choisi automatiquement")
        XCTAssertEqual(ids(try decide(chain, lane: .interactive, pinned: "lambda-direct", state: state)), ["lambda-direct", "alpha-mini-direct"], "épinglé au premier plan : admis")
        XCTAssertFalse(ids(try decide(chain, lane: .background, pinned: "lambda-direct", state: state)).contains("lambda-direct"), "jamais en fond")
        let onlyUnknown = try decide([try spec("lambda-direct"), try spec("nu-free")], lane: .interactive, state: state)
        if case .blocked(let w) = onlyUnknown { XCTAssertTrue(w.contains("n'est pas rétablie")) } else { XCTFail("chaîne d'inconnus : bloquée, obtenu \(ids(onlyUnknown))") }
        // Inconnu épinglé : réservé ET soldé au tarif plafond (jamais 0).
        let (led, path) = try tmpLedger(); defer { cleanup(path) }
        let bk = try book()
        if case .refused(let w) = SpendPolicy.preflight(ledger: led, book: bk, spec: try spec("lambda-direct"), estIn: 1_000, maxOut: 1_000, lane: .background, caps: caps(), now: now) {
            XCTAssertTrue(w.contains("jamais en tâche de fond"), w)
        } else { XCTFail("chemin direct : facturation inconnue jamais en fond") }
        guard case .go(let t) = SpendPolicy.preflight(ledger: led, book: bk, spec: try spec("lambda-direct"), estIn: 1_000, maxOut: 1_000, lane: .interactive, caps: caps(), now: now)
        else { return XCTFail("réservation prudente attendue") }
        XCTAssertEqual(t.estimate, 60_000, "1 000 × 10 $ + 1 000 × 50 $ par M")
        XCTAssertEqual(led.row(try XCTUnwrap(t.id))?.billing, "unknown")
        XCTAssertEqual(SpendPolicy.settle(ledger: led, book: bk, ticket: t, usage: Usage(input: 500, output: 100), measured: true, now: now), 10_000)
        XCTAssertEqual(led.committed(month: "2026-11"), 10_000)
    }

    // MARK: - Réservations : concurrence, annulation, rapprochement

    func testConcurrentReservations() throws {
        let bk = try book(); let h = try spec("alpha-mini-direct")
        for round in 0..<5 {
            let (a, path) = try tmpLedger(); defer { cleanup(path) }
            let b = try XCTUnwrap(CostLedger(path: path), "seconde connexion (autre processus simulé)")
            final class Counter: @unchecked Sendable { let lock = NSLock(); var n = 0 }
            let ok = Counter()
            let c = caps(month: 1_000_000)
            DispatchQueue.concurrentPerform(iterations: 8) { i in
                let r = SpendPolicy.preflight(ledger: i % 2 == 0 ? a : b, book: bk, spec: h, estIn: 0, maxOut: 600_000, lane: .interactive, caps: c, now: self.now)
                if r.ticket?.id != nil { ok.lock.lock(); ok.n += 1; ok.lock.unlock() }
            }
            XCTAssertEqual(ok.n, 3, "huit appels parallèles à 0,30 $ contre 1,00 $ : trois réservés (tour \(round))")
            XCTAssertEqual(a.committed(month: "2026-11"), 900_000)
        }
    }

    func testCancelledTimedOutAndFailed() throws {
        let (led, path) = try tmpLedger(); defer { cleanup(path) }
        let bk = try book(); let h = try spec("alpha-mini-direct")
        func go() throws -> SpendTicket {
            try XCTUnwrap(SpendPolicy.preflight(ledger: led, book: bk, spec: h, estIn: 0, maxOut: 200_000, lane: .interactive, caps: caps(), now: now).ticket)
        }
        let cancelled = try go(); SpendPolicy.abandon(ledger: led, ticket: cancelled, kind: .canceled, produced: false)
        let timedOut = try go(); SpendPolicy.abandon(ledger: led, ticket: timedOut, kind: .timeout, produced: false)
        let cut = try go(); SpendPolicy.abandon(ledger: led, ticket: cut, kind: .cut, produced: true)
        let creditAfterText = try go(); SpendPolicy.abandon(ledger: led, ticket: creditAfterText, kind: .credit, produced: true)
        let unknownError = try go(); SpendPolicy.abandon(ledger: led, ticket: unknownError, kind: nil, produced: false)
        for t in [cancelled, timedOut, cut, creditAfterText, unknownError] { XCTAssertEqual(led.state(try XCTUnwrap(t.id)), "kept", "annulé/délai/coupé : peut avoir été facturé") }
        let auth = try go(); SpendPolicy.abandon(ledger: led, ticket: auth, kind: .auth, produced: false)
        XCTAssertEqual(led.state(try XCTUnwrap(auth.id)), "released", "refus avant traitement : rien facturé")
        XCTAssertEqual(led.committed(month: "2026-11"), 5 * 100_000)
    }

    func testUsageReconciliation() throws {
        let (led, path) = try tmpLedger(); defer { cleanup(path) }
        let bk = try book(); let h = try spec("alpha-mini-direct")
        func go() throws -> SpendTicket {
            try XCTUnwrap(SpendPolicy.preflight(ledger: led, book: bk, spec: h, estIn: 0, maxOut: 200_000, calls: 1, lane: .interactive, caps: caps(), now: now).ticket)
        }
        let measured = try go()   // réservé 0,10 $
        XCTAssertEqual(SpendPolicy.settle(ledger: led, book: bk, ticket: measured, usage: Usage(input: 1_000, output: 1_000), measured: true, now: now), 600)
        var row = try XCTUnwrap(led.row(try XCTUnwrap(measured.id)))
        XCTAssertEqual(row.state, "settled"); XCTAssertEqual(row.actual, 600); XCTAssertEqual(row.measure, "measured")
        let noUsage = try go()
        SpendPolicy.settle(ledger: led, book: bk, ticket: noUsage, usage: Usage(), measured: true, now: now)
        XCTAssertEqual(led.state(try XCTUnwrap(noUsage.id)), "kept", "usage absent ≠ gratuit")
        let estSmall = try go()
        SpendPolicy.settle(ledger: led, book: bk, ticket: estSmall, usage: Usage(input: 10, output: 10), measured: false, now: now)
        XCTAssertEqual(led.state(try XCTUnwrap(estSmall.id)), "kept", "estimé < réservé : la réservation reste")
        let estBig = try go()
        SpendPolicy.settle(ledger: led, book: bk, ticket: estBig, usage: Usage(output: 400_000), measured: false, now: now)
        row = try XCTUnwrap(led.row(try XCTUnwrap(estBig.id)))
        XCTAssertEqual(row.actual, 200_000); XCTAssertEqual(row.measure, "estimated", "estimé et mesuré restent distincts")
        XCTAssertEqual(led.committed(month: "2026-11"), 600 + 100_000 + 100_000 + 200_000)
        // Suites automatiques : chaque suite relit entrée + sortie (estimation prudente).
        XCTAssertEqual(SpendPolicy.estimate(book: bk, billing: bk.billing(h), estIn: 1_000, maxOut: 1_000, calls: 3), 600 + 700 + 800)
        // Petits coûts : entiers, aucune perte d'arrondi cumulée (avant : arrondi à 4 décimales à chaque ajout).
        var total: Micros = 0
        for _ in 0..<10_000 { total += bk.cost(bk.billing(h), usage: Usage(input: 100)) }   // 0,00001 $ par appel
        XCTAssertEqual(total, 100_000, "10 000 × 0,00001 $ = 0,10 $ exactement")
        XCTAssertEqual(LLMSpend.round4(0.0001 + 0.00001), 0.0001, "l'ancien cumul arrondi perdait ces coûts")
    }

    // MARK: - Dérogations

    func testOverrideExpiryAndExhaustion() throws {
        let (led, path) = try tmpLedger(); defer { cleanup(path) }
        let bk = try book(); let h = try spec("alpha-mini-direct")
        try seed(led, 1_000_000)
        let c = caps(month: 1_000_000)
        func pf(_ lane: SpendLane = .interactive, at: Date? = nil, oid: String?) -> Preflight {
            SpendPolicy.preflight(ledger: led, book: bk, spec: h, estIn: 0, maxOut: 600_000, lane: lane, caps: c, overrideId: oid, now: at ?? now)
        }
        XCTAssertNil(pf(oid: nil).ticket, "plafond atteint, sans dérogation : refus")
        XCTAssertNil(led.grantOverride(max: 0, until: now.addingTimeInterval(60), lanes: [.foreground], reason: "x", actor: "t", now: now), "montant nul refusé")
        XCTAssertNil(led.grantOverride(max: 500_000, until: now, lanes: [.foreground], reason: "x", actor: "t", now: now), "déjà expirée refusée")
        XCTAssertNil(led.grantOverride(max: 500_000, until: now.addingTimeInterval(60), lanes: [.foreground], reason: "  ", actor: "t", now: now), "motif obligatoire")
        let oid = try XCTUnwrap(led.grantOverride(max: 500_000, until: now.addingTimeInterval(60), lanes: [.foreground], reason: "rapport urgent", actor: "Ahadi", now: now))
        XCTAssertEqual(led.activeOverride(lane: .foreground, now: now)?.id, oid)
        let first = try XCTUnwrap(pf(oid: oid).ticket)
        XCTAssertEqual(led.row(try XCTUnwrap(first.id))?.overrideId, oid, "réservation rattachée à sa dérogation (audit)")
        if case .refused(let w) = pf(oid: oid) { XCTAssertTrue(w.contains("épuisée"), w) } else { XCTFail("0,30 + 0,30 > 0,50 : épuisée") }
        SpendPolicy.abandon(ledger: led, ticket: first, kind: .auth, produced: false)   // rien facturé : la part revient à la dérogation
        XCTAssertEqual(led.overrideInfo(oid)?.used, 0)
        XCTAssertNotNil(pf(oid: oid).ticket)
        XCTAssertNil(pf(at: now.addingTimeInterval(61), oid: oid).ticket, "expirée")
        XCTAssertNil(led.activeOverride(lane: .foreground, now: now.addingTimeInterval(61)))
        XCTAssertNil(pf(.background, oid: oid).ticket, "jamais pour le fond")
        XCTAssertNil(pf(.bench, oid: oid).ticket, "hors voie (banc non accordé)")
        let o2 = try XCTUnwrap(led.grantOverride(max: 5_000_000, until: now.addingTimeInterval(600), lanes: [.foreground], reason: "second", actor: "Ahadi", now: now))
        XCTAssertTrue(led.revokeOverride(o2))
        XCTAssertNil(pf(oid: o2).ticket, "révoquée")
        // Le plafond par tâche n'est jamais levé.
        let strict = CostLedger.Caps(monthHard: 1_000_000, dayForeground: 1_000_000, dayBackground: 1_000_000, perTask: 100_000)
        let o3 = try XCTUnwrap(led.grantOverride(max: 5_000_000, until: now.addingTimeInterval(600), lanes: [.foreground], reason: "troisième", actor: "Ahadi", now: now))
        XCTAssertNil(SpendPolicy.preflight(ledger: led, book: bk, spec: h, estIn: 0, maxOut: 600_000, lane: .interactive, caps: strict, overrideId: o3, now: now).ticket)
        XCTAssertGreaterThanOrEqual(led.overrides(limit: 10).count, 3, "journal des dérogations")
    }

    // MARK: - Reprise du compteur JSON, orphelines, migration

    func testOpeningSeedOnceAndStaleSweep() throws {
        let path = NSTemporaryDirectory() + "nova-wp2-" + UUID().uuidString + ".sqlite"
        defer { cleanup(path) }
        do {
            let led = try XCTUnwrap(CostLedger(path: path))
            XCTAssertTrue(led.seedOpeningOnce(monthOther: 80_000_000, dayBackground: 500_000, dayBench: 1_000_000, now: now))
            XCTAssertFalse(led.seedOpeningOnce(monthOther: 80_000_000, dayBackground: 500_000, dayBench: 1_000_000, now: now), "une seule fois")
            XCTAssertEqual(led.committed(month: "2026-11"), 81_500_000)
            XCTAssertEqual(led.committed(day: "2026-11-04", lane: .background), 500_000)
            XCTAssertEqual(led.committed(day: "2026-11-04", lane: .bench), 1_000_000)
            XCTAssertEqual(led.committed(day: "2026-11-04", lane: .foreground), 0, "la ligne « mois » n'entre dans aucun plafond du jour")
            _ = try XCTUnwrap(led.reserve(task: "orpheline", lane: .foreground, brain: "b", profile: "v1-interactive", dataClass: .personal, estimate: 250_000, caps: caps(), now: now).id)
        }   // « plantage » : réservation jamais soldée
        let again = try XCTUnwrap(CostLedger(path: path), "réouverture après migration")
        XCTAssertFalse(again.seedOpeningOnce(monthOther: 1, dayBackground: 1, dayBench: 1, now: now), "survit au redémarrage : pas de seconde reprise")
        XCTAssertEqual(again.sweepStale(olderThan: 7200, now: now.addingTimeInterval(7201)), 1)
        XCTAssertEqual(again.committed(month: "2026-11"), 81_750_000, "orpheline gardée, jamais rendue gratuite")
    }
}
