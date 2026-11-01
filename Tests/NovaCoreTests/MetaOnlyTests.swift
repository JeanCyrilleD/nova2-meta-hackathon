import XCTest
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
@testable import NovaCore

/// 01/11 — mode « meta_only », VRAI EN DUR dans la version hackathon Meta. SIMULÉ : clés factices en mémoire, aucun appel réseau réel
/// (tout appel non Meta est bloqué avant l'envoi ; les tests n'émettent aucun appel Meta). Données et journal sous NOVA_HOME
/// temporaire (Paths.diagDir suit NOVA_HOME/diag) — rien n'est écrit dans les réglages ni les relevés de l'app en service.
final class MetaOnlyTests: XCTestCase {
    static var sandbox: URL = FileManager.default.temporaryDirectory
    static var previousHome: String? = nil
    static var previousDiag: String? = nil

    override class func setUp() {
        super.setUp()
        previousHome = ProcessInfo.processInfo.environment["NOVA_HOME"]
        previousDiag = ProcessInfo.processInfo.environment["NOVA_DIAG_DIR"]
        let d = FileManager.default.temporaryDirectory.appendingPathComponent("nova-metaonly-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        setenv("NOVA_HOME", d.path, 1)
        unsetenv("NOVA_DIAG_DIR")
        sandbox = d
    }
    override class func tearDown() {
        if let p = previousHome { setenv("NOVA_HOME", p, 1) } else { unsetenv("NOVA_HOME") }
        if let p = previousDiag { setenv("NOVA_DIAG_DIR", p, 1) }
        super.tearDown()
    }
    override func setUp() {
        super.setUp()
        try? FileManager.default.removeItem(at: MetaOnly.journalURL)
    }
    override func tearDown() {
        super.tearDown()
    }

    /// Clés factices : Meta, Baseten, Hugging Face (rien n'est jamais envoyé).
    func allKeys() -> MemoryKeyStore {
        MemoryKeyStore([KnownKeys.sparkNova.service: "x", KnownKeys.basetenNova.service: "x", KnownKeys.hfNova.service: "x"])
    }
    func spec(_ id: String) -> BrainSpec { Catalog.defaults().first { $0.id == id }! }
    /// Cerveau FICTIF hors Meta (hôte et modèle inventés) : sert à prouver le blocage sans nommer aucun fournisseur réel.
    var foreign: BrainSpec {
        BrainSpec(id: "vendor-x", label: "Vendor X", kind: .chat, baseURL: "https://api.vendor.example/v1/chat/completions",
                  model: "vendor-large", keys: KeyChain([], fallback: "x"), tags: [])
    }
    func post(_ url: String, model: String?) -> URLRequest {
        var r = URLRequest(url: URL(string: url)!); r.httpMethod = "POST"
        if let m = model { r.httpBody = jsonData(["model": m, "messages": [[String: Any]]()]) }
        return r
    }

    // MARK: famille et catalogue

    func testCatalogIsMetaOnlyAndFamilyFromProviderAndModel() {
        let ids: [String] = Catalog.defaults().map { $0.id }
        XCTAssertFalse(ids.isEmpty)
        for s in Catalog.defaults() { XCTAssertTrue(MetaOnly.isMeta(s), s.id + " : le catalogue ne contient que des modèles Meta") }
        for id in ["spark-1.3", "spark-1.2", "wonder-1.0", "spark-open-baseten", "spark-open-hf", "muse-code"] { XCTAssertTrue(ids.contains(id), id) }
        XCTAssertFalse(MetaOnly.isMeta(foreign))
        // Un cerveau Meta futur (ex. Glimmer) est reconnu par sa famille, sans toucher au code.
        let glimmer = BrainSpec(id: "glimmer-test", label: "Glimmer", kind: .chat, baseURL: "https://api.meta.ai/v1/chat/completions",
                                model: "muse-glimmer-1.0", keys: KeyChain([]), tags: [])
        XCTAssertTrue(MetaOnly.isMeta(glimmer))
        for o in [Catalog.fastOrder, Catalog.bulkOrder, Catalog.deepOrder] { XCTAssertTrue(o.allSatisfy { ids.contains($0) }) }
    }

    // MARK: vrai en dur

    func testAlwaysOnAndSettingCannotDisable() {
        XCTAssertTrue(MetaOnly.enabled)
        Settings().set(["meta_only": false])
        MetaOnly.invalidate()
        XCTAssertTrue(MetaOnly.enabled, "aucun réglage ne coupe le mode Meta seulement")
        XCTAssertTrue(MetaSpecialites.actif, "routage par spécialité toujours actif")
        XCTAssertEqual(LocalVoice.mode(Settings()), "local")
    }

    // MARK: routeur filtré

    func testRouterChainsAreMetaOnly() {
        let r = Router(keys: allKeys())
        for mode in ["fast", "bulk", "deep", "voice"] {
            let c = r.plan(mode: mode, preferred: nil)
            XCTAssertFalse(c.isEmpty, mode)
            XCTAssertTrue(c.allSatisfy { MetaOnly.isMeta($0) }, mode + " : " + c.map { $0.id }.joined(separator: ","))
        }
        let pinned = r.plan(mode: "fast", preferred: "vendor-x")
        XCTAssertFalse(pinned.contains { $0.id == "vendor-x" }, "un id hors catalogue n'entre pas dans la chaîne")
        XCTAssertTrue(pinned.allSatisfy { MetaOnly.isMeta($0) })
        XCTAssertFalse(r.usable("local"))
        XCTAssertNil(r.localSpec())
        XCTAssertTrue(r.engines(force: true).isEmpty, "aucun moteur local détecté")
        XCTAssertTrue(r.usable("spark-1.3"))
        XCTAssertEqual(r.whyUnusable("vendor-x"), "inconnu du catalogue")
        XCTAssertEqual(r.firstUsableMeta(preferring: "spark-1.3"), "spark-1.3")
        // Spark Open (Baseten) est le secours Meta juste après les cerveaux de l'API Meta.
        XCTAssertTrue(r.plan(mode: "fast", preferred: nil).contains { $0.id == "spark-open-baseten" })
    }

    // MARK: aucun repli non Meta

    func testNoMetaBrainFailsVisiblyWithoutFallback() {
        let r = Router(keys: MemoryKeyStore([:]))
        XCTAssertNil(r.firstUsableMeta())
        var errors: [String] = []
        var started: [String] = []
        let out = r.chat(messages: [ChatMsg("user", "bonjour")], system: nil, mode: "fast", preferred: "spark-1.3") { ev in
            switch ev {
            case .error(let e): errors.append(e)
            case .start(let id, _): started.append(id)
            default: break
            }
        }
        XCTAssertNil(out)
        XCTAssertTrue(started.isEmpty, "aucun cerveau n'a démarré")
        XCTAssertFalse(errors.isEmpty, "échec visible, jamais silencieux")
        XCTAssertFalse(MetaOnly.journalTail().contains { ($0["statut"] as? String) == "envoye" && ($0["meta"] as? Bool) == false })
    }

    func testBrainRunnerBlocksNonMetaBeforeSending() {
        let runner = BrainRunner(keys: allKeys())
        XCTAssertThrowsError(try runner.stream(foreign, messages: [ChatMsg("user", "x")], system: nil, maxTokens: 10, mode: "fast",
                                               firstTokenTimeout: 1, cancel: { false }, onDelta: { _ in }, onUsage: { _, _ in })) { e in
            XCTAssertTrue(((e as? BrainFailure)?.message ?? "").contains("meta_only"))
        }
        XCTAssertTrue(MetaOnly.journalTail().contains { ($0["source"] as? String) == "brainrunner" && ($0["statut"] as? String) == "bloque" })
    }

    // MARK: barrière réseau + journal

    func testNetworkGateAndJournal() {
        // Bloqués : tout envoi qui nomme un modèle non Meta (hôte inconnu, passerelle avec un modèle non Meta, boucle locale).
        XCTAssertNotNil(MetaOnly.gate(post("https://api.vendor.example/v1/chat/completions", model: "vendor-large"), source: "test"))
        XCTAssertNotNil(MetaOnly.gate(post("https://router.huggingface.co/v1/chat/completions", model: "vendor/other-235B"), source: "test"))
        XCTAssertNotNil(MetaOnly.gate(post("http://127.0.0.1:8089/v1/chat/completions", model: "local-model"), source: "test"))
        // Autorisés : Meta (API Meta, Spark Open via Baseten et Hugging Face).
        XCTAssertNil(MetaOnly.gate(post("https://api.meta.ai/v1/chat/completions", model: "muse-spark-1.3"), source: "test"))
        XCTAssertNil(MetaOnly.gate(post("https://inference.baseten.co/v1/chat/completions", model: "meta-models/muse-spark-open"), source: "test"))
        XCTAssertNil(MetaOnly.gate(post("https://router.huggingface.co/v1/chat/completions", model: "meta-models/Muse-Spark-Open-816B-A42B:fastest"), source: "test"))
        // Services non-IA et lectures de métadonnées : pas des appels de modèle — ni bloqués, ni journalisés.
        XCTAssertNil(MetaOnly.gate(post("https://api.tavily.com/search", model: nil), source: "test"))
        XCTAssertNil(MetaOnly.gate(post("https://abc-dsn.algolia.net/1/indexes/x/query", model: nil), source: "test"))
        XCTAssertNil(MetaOnly.gate(URLRequest(url: URL(string: "https://api.meta.ai/v1/models")!), source: "test"))
        // HTTPStream : rien ne part, retour immédiat.
        let t0 = Date()
        let res = HTTPStream.run(post("https://api.vendor.example/v1/chat/completions", model: "vendor-large"), firstByteTimeout: 30) { _ in true }
        XCTAssertEqual(res.status, 0)
        XCTAssertTrue((res.error ?? "").contains("meta_only"))
        XCTAssertLessThan(Date().timeIntervalSince(t0), 1.0)

        let j = MetaOnly.journalTail()
        XCTAssertEqual(j.filter { ($0["statut"] as? String) == "bloque" }.count, 4)
        XCTAssertEqual(j.filter { ($0["statut"] as? String) == "envoye" }.count, 3)
        for e in j {
            XCTAssertNotNil(e["fournisseur"] as? String); XCTAssertNotNil(e["modele"] as? String); XCTAssertNotNil(e["meta"] as? Bool)
            XCTAssertEqual(e["meta"] as? Bool, (e["statut"] as? String) == "envoye")
        }
        XCTAssertTrue(j.contains { ($0["fournisseur"] as? String) == "api.vendor.example" && ($0["modele"] as? String) == "vendor-large" })
        XCTAssertTrue(j.contains { ($0["fournisseur"] as? String) == "baseten" && ($0["meta"] as? Bool) == true })
        XCTAssertFalse(j.contains { ($0["hote"] as? String ?? "").contains("tavily") || ($0["hote"] as? String ?? "").contains("algolia") })
        XCTAssertTrue(MetaOnly.journalURL.path.hasPrefix(MetaOnlyTests.sandbox.path), "journal sous le bac à sable (Paths.diagFile)")
    }

    // MARK: voix

    func testVoiceUsesNoNonMetaEngine() {
        XCTAssertEqual(LocalVoice.mode(Settings()), "local", "TTS : voix système macOS")
        XCTAssertNotNil(MetaOnly.gate(url: URL(string: "wss://stt.vendor.example/v3/ws")!, method: "WS", source: "test"), "WebSocket hors Meta bloquée")
        XCTAssertNil(MetaOnly.gate(url: URL(string: "wss://api.meta.ai/v1/asr/realtime")!, method: "WS", source: "test"))
        XCTAssertEqual(VoixReglages.moteur(), "apple")
        XCTAssertTrue(VoixReglages.surAppareil(), "reconnaissance sur l'appareil exigée")
        let r = Router(keys: allKeys())
        XCTAssertEqual(r.firstUsableMeta(preferring: "spark-1.3"), "spark-1.3")
        XCTAssertEqual(MetaSpecialites.affectation(.syntheseVocale)?.nature, "local")
    }
}
