import XCTest
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
@testable import NovaCore

/// 01/11 — routage par spécialité (MetaSpecialites). SIMULÉ : clés factices en mémoire, AUCUN appel réseau
/// (seuls plan(), les tables, la facturation et le journal sont exercés). Réglages et journaux sous NOVA_HOME temporaire.
final class MetaSpecialitesTests: XCTestCase {
    static var sandbox: URL = FileManager.default.temporaryDirectory
    static var previousHome: String? = nil

    override class func setUp() {
        super.setUp()
        previousHome = ProcessInfo.processInfo.environment["NOVA_HOME"]
        let d = FileManager.default.temporaryDirectory.appendingPathComponent("nova-metaspec-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        setenv("NOVA_HOME", d.path, 1)
        unsetenv("NOVA_DIAG_DIR")
        sandbox = d
    }
    override class func tearDown() {
        MetaSpecialites.setOverride(nil); MetaSpecialites.setExclusOverride(nil)
        if let p = previousHome { setenv("NOVA_HOME", p, 1) } else { unsetenv("NOVA_HOME") }
        super.tearDown()
    }
    override func setUp() {
        super.setUp()
        MetaSpecialites.setOverride(true); MetaSpecialites.setExclusOverride(nil)
        try? FileManager.default.removeItem(at: MetaOnly.journalURL)
    }
    override func tearDown() {
        MetaSpecialites.setOverride(nil); MetaSpecialites.setExclusOverride(nil)
        super.tearDown()
    }

    static let fakeSecret: String = "secret-factice-0123456789"
    func keys(baseten: Bool = true, hf: Bool = false) -> MemoryKeyStore {
        var d: [String: String] = [KnownKeys.sparkNova.service: Self.fakeSecret]
        if hf { d[KnownKeys.hfNova.service] = Self.fakeSecret }
        if baseten { d[KnownKeys.basetenNova.service] = Self.fakeSecret }
        return MemoryKeyStore(d)
    }
    func ids(_ r: Router, _ mode: String, preferred: String? = nil, outils: Bool = false) -> [String] {
        r.plan(mode: mode, preferred: preferred, outils: outils).map { $0.id }
    }
    func spec(_ id: String) -> BrainSpec { Catalog.defaults().first { $0.id == id }! }

    // MARK: table

    func testTableCoversEverySpecialtyWithOfficialModelIds() {
        for s in Specialite.allCases { XCTAssertNotNil(MetaSpecialites.affectation(s), s.rawValue) }
        let catalog = Set(Catalog.defaults().map { $0.id })
        for a in MetaSpecialites.table where a.nature == "cerveau" {
            XCTAssertFalse(a.chaine.isEmpty, a.specialite.rawValue)
            for id in a.chaine {
                XCTAssertTrue(catalog.contains(id), "\(id) absent du catalogue")
                XCTAssertTrue(MetaOnly.isMeta(spec(id)), "\(id) : la chaîne d'une spécialité est 100 % Meta")
                XCTAssertFalse(id.hasSuffix("-contributor") || id == "muse-code", "jamais Contributor ni Muse Code en automatique")
            }
            XCTAssertFalse(a.sources.isEmpty, "chaque choix est sourcé : " + a.specialite.rawValue)
        }
        for g in MetaSpecialites.secoursMeta { XCTAssertTrue(catalog.contains(g), g); XCTAssertTrue(MetaOnly.isMeta(spec(g)), g) }
        XCTAssertEqual(MetaSpecialites.secoursMeta, ["spark-open-baseten"], "seul secours : Spark Open (poids ouverts Meta)")
        XCTAssertEqual(MetaSpecialites.affectation(.image)?.modele, "muse-image-1.0")
        XCTAssertEqual(MetaSpecialites.affectation(.segmentation)?.modele, "sam-3.1")
        XCTAssertEqual(MetaSpecialites.affectation(.dictee)?.modele, "muse-voice-transcribe-1.0")
        XCTAssertEqual(MetaSpecialites.affectation(.syntheseVocale)?.nature, "local", "Meta ne publie aucun TTS : AVSpeech local")
        XCTAssertEqual(MetaSpecialites.affectation(.voixLive)?.modele.contains("muse-spark-1.3"), true)
        XCTAssertEqual(MetaCapabilities.imagePayload(prompt: "p")["model"] as? String, "muse-image-1.0")
        XCTAssertEqual(MetaCapabilities.segmentPayload(prompt: "glasses", imageURL: "https://example.com/a.png")["model"] as? String, "sam-3.1")
    }

    // MARK: chaque spécialité (simulé)

    func testChatRapide() {
        let c = ids(Router(keys: keys()), "fast")
        XCTAssertEqual(c.first, "spark-1.3")
        XCTAssertEqual(Array(c.prefix(3)), ["spark-1.3", "spark-1.2", "wonder-1.0"])
        XCTAssertEqual(c.last, "spark-open-baseten", "Spark Open APRÈS les cerveaux de l'API Meta")
        XCTAssertTrue(c.allSatisfy { MetaOnly.isMeta(self.spec($0)) }, c.joined(separator: ","))
    }
    func testRaisonnementProfond() {
        let c = ids(Router(keys: keys()), "deep")
        XCTAssertEqual(Array(c.prefix(3)), ["spark-1.3", "wonder-1.0", "spark-1.2"])
        XCTAssertEqual(MetaSpecialites.effort(mode: "deep"), "high")
    }
    func testCode() {
        let c = ids(Router(keys: keys()), "code")
        XCTAssertEqual(c.first, "wonder-1.0", "code : Wonder en tête (pas le cerveau actif)")
        XCTAssertEqual(c.dropFirst().first, "spark-1.3")
        XCTAssertEqual(MetaSpecialites.effort(mode: "code"), "high")
    }
    func testAgentsOutils() {
        let r = Router(keys: keys())
        XCTAssertEqual(Array(ids(r, "fast", outils: true).prefix(2)), ["spark-1.3", "wonder-1.0"])
        XCTAssertEqual(MetaSpecialites.specialite(mode: "fast", outils: true), .agentsOutils)
        XCTAssertEqual(MetaSpecialites.specialite(mode: "fast", outils: false), .chatRapide)
    }
    func testEclatsFond() {
        let c = ids(Router(keys: keys()), "bulk")
        XCTAssertEqual(Array(c.prefix(2)), ["spark-1.3", "spark-1.2"])
        XCTAssertFalse(c.contains("wonder-1.0"), "Wonder (premium) hors chaîne de fond")
        XCTAssertEqual(MetaSpecialites.effort(mode: "bulk"), "low")
    }
    func testJuges() {
        let r = Router(keys: keys())
        XCTAssertEqual(ids(r, "juge").first, "wonder-1.0", "le juge est un autre modèle que le rédacteur Spark")
        XCTAssertEqual(MetaSpecialites.premierUtilisable(.juges, router: r), "wonder-1.0")
        XCTAssertEqual(MetaSpecialites.effort(mode: "juge"), "medium")
    }
    func testVeillePubliqueOpenWeight() {
        let with = Router(keys: keys(baseten: true))
        XCTAssertEqual(ids(with, "public").first, "spark-open-baseten")
        let v = MetaSpecialites.cerveauVeille(router: with)
        XCTAssertEqual(v.id, "spark-open-baseten"); XCTAssertTrue(v.ouvert)
        // Sans clé nova-baseten : échec propre, repli nommé sur un cerveau Meta, rien n'est demandé ni créé.
        let without = Router(keys: keys(baseten: false))
        XCTAssertFalse(ids(without, "public").contains("spark-open-baseten"))
        let w = MetaSpecialites.cerveauVeille(router: without)
        XCTAssertEqual(w.id, "spark-1.3"); XCTAssertFalse(w.ouvert)
        XCTAssertTrue(w.raison.contains("clé"), w.raison)
        let snap = MetaSpecialites.snapshot(router: without, keys: keys(baseten: false))
        XCTAssertEqual((snap["cles"] as? [String: String])?["nova-baseten"], "non")
        XCTAssertEqual((MetaSpecialites.snapshot(router: with, keys: keys(baseten: true))["cles"] as? [String: String])?["nova-baseten"], "oui")
    }
    func testVisionImageSegmentationDicteeTTS() {
        let r = Router(keys: keys())
        XCTAssertEqual(ids(r, "vision").first, "spark-1.3")
        for s in [Specialite.image, .segmentation, .dictee] { XCTAssertEqual(MetaSpecialites.affectation(s)?.nature, "capacite", s.rawValue) }
        XCTAssertTrue(MetaSpecialites.affectation(.dictee)?.endpoint.contains("api.meta.ai") ?? false)
    }

    // MARK: voix live (version Meta)

    func testVoiceLiveChainIsMetaAndNotRerouted() {
        let r = Router(keys: keys())
        let on = ids(r, "voice")
        XCTAssertFalse(on.isEmpty)
        XCTAssertTrue(on.allSatisfy { MetaOnly.isMeta(self.spec($0)) }, on.joined(separator: ","))
        XCTAssertNil(MetaSpecialites.ordre(mode: "voice", outils: false))
        XCTAssertEqual(MetaSpecialites.effort(mode: "voice"), "minimal")
    }

    // MARK: exclusions (réversibles) et retour arrière

    func testRoutingAlwaysOnInMetaVersion() {
        MetaSpecialites.setOverride(false)
        XCTAssertTrue(MetaSpecialites.actif, "meta_only vrai en dur : routage par spécialité toujours actif")
        XCTAssertEqual(Array(ids(Router(keys: keys()), "fast").prefix(3)), ["spark-1.3", "spark-1.2", "wonder-1.0"])
    }
    func testExcludedBrainsLeaveAutoChainsButStayPinnable() {
        let r = Router(keys: keys(hf: true))
        for mode in ["fast", "deep", "bulk", "code", "juge"] {
            XCTAssertFalse(ids(r, mode).contains("spark-open-hf"), "\(mode) : Spark Open (Hugging Face) hors chaînes automatiques")
        }
        XCTAssertEqual(ids(r, "fast", preferred: "spark-open-hf").first, "spark-open-hf", "choix à la main : toujours épinglé")
        // Réversible sans code : liste vide = aucune exclusion.
        MetaSpecialites.setExclusOverride([])
        XCTAssertFalse(MetaSpecialites.exclu("spark-open-hf"))
    }

    // MARK: meta_only + journal « specialite »

    func testMetaOnlyChainsAndJournalHaveSpecialite() {
        MetaSpecialites.setOverride(false)
        XCTAssertTrue(MetaSpecialites.actif, "meta_only active toujours le routage par spécialité")
        let r = Router(keys: keys())
        for mode in ["fast", "deep", "bulk", "code", "juge", "public"] {
            let c = r.plan(mode: mode, preferred: nil)
            XCTAssertFalse(c.isEmpty, mode)
            XCTAssertTrue(c.allSatisfy { MetaOnly.isMeta($0) }, mode + " : " + c.map { $0.id }.joined(separator: ","))
        }
        MetaSpecialites.noterRoutage(mode: "code", outils: false, chain: r.plan(mode: "code", preferred: nil))
        MetaSpecialites.noter(specialite: .dictee, modele: "muse-voice-transcribe-1.0", cerveau: "", chaine: [], statut: "ok", source: "test")
        let j = MetaOnly.journalTail()
        XCTAssertTrue(j.contains { ($0["specialite"] as? String) == "code" && ($0["cerveau"] as? String) == "wonder-1.0" && ($0["meta"] as? Bool) == true })
        XCTAssertTrue(j.contains { ($0["specialite"] as? String) == "dictee" })
    }
    func testJournalAlwaysTheProofJournal() {
        MetaSpecialites.noter(specialite: .chatRapide, modele: "muse-spark-1.3", cerveau: "spark-1.3", chaine: ["spark-1.3"], statut: "route", source: "test")
        let j = MetaOnly.journalTail()
        XCTAssertTrue(j.contains { ($0["specialite"] as? String) == "chat_rapide" && ($0["modele"] as? String) == "muse-spark-1.3" && ($0["meta"] as? Bool) == true },
                      "meta_only vrai en dur : chaque routage est écrit dans le journal de preuve")
    }

    // MARK: facturation et conditions

    func testBillingIsMetaAndBaseten() {
        XCTAssertTrue(PriceBook.vendorFreeTier.isEmpty, "aucun palier gratuit tiers")
        XCTAssertNil(PriceBook.creditFunded["spark-open-baseten"], "Baseten a désormais un tarif versionné (registre)")
        XCTAssertEqual(PriceBook.providerHosts["meta"], "api.meta.ai")
        XCTAssertEqual(PriceBook.providerHosts["baseten"], "inference.baseten.co")
    }

    // MARK: bonus open-weight : secours Meta et relecture CAFU (simulé)

    func testSparkOpenIsTheMetaFallback() {
        let r = Router(keys: keys())
        for mode in ["fast", "deep", "bulk", "code", "juge"] {
            let c = ids(r, mode)
            XCTAssertTrue(c.contains("spark-open-baseten"), mode)
            let i = c.firstIndex(of: "spark-open-baseten") ?? -1
            XCTAssertTrue(c.prefix(i).allSatisfy { (id: String) -> Bool in r.brains.first(where: { $0.id == id })?.baseURL.contains("api.meta.ai") ?? false },
                          "\(mode) : Spark Open juste APRÈS les cerveaux de l'API Meta : " + c.joined(separator: ","))
        }
        // Sans clé Baseten : la chaîne reste Meta, sans lui, sans erreur.
        XCTAssertFalse(ids(Router(keys: keys(baseten: false)), "fast").contains("spark-open-baseten"))
    }
    func testBasetenCostAndReviewPrompt() {
        XCTAssertEqual(MetaSpecialites.coutBasetenUSD(inTok: 1_000_000, outTok: 1_000_000), 5.50, accuracy: 1e-9)
        XCTAssertEqual(MetaSpecialites.coutBasetenUSD(inTok: 1_000_000, outTok: 0, cacheTok: 1_000_000), 0.15, accuracy: 1e-9)
        let u = MetaSpecialites.relectureUser(note: "## BLUF\nMali 10%")
        XCTAssertTrue(u.contains("Mali 10%"))
        XCTAssertTrue(MetaSpecialites.relectureSys.contains("Facts") && MetaSpecialites.relectureSys.contains("Tags") && MetaSpecialites.relectureSys.contains("Score"))
        XCTAssertEqual(MetaSpecialites.affectation(.relectureOpenWeight)?.chaine, ["spark-open-baseten"])
    }
    func testReviewWithoutBasetenKeyIsSkippedAndJournaled() {
        let r = Router(keys: keys(baseten: false))
        let rv = MetaSpecialites.relireNoteCafu(router: r, note: "note", cancel: { false })
        XCTAssertNil(rv.text); XCTAssertEqual(rv.statut, "saute"); XCTAssertEqual(rv.cost, 0)
        let j = MetaOnly.journalTail()
        XCTAssertTrue(j.contains { ($0["specialite"] as? String) == "relecture_open_weight" && ($0["statut"] as? String) == "saute" && ($0["fournisseur"] as? String) == "baseten" })
    }
    func testBasetenJournalLineCarriesCost() {
        MetaSpecialites.noterBaseten(statut: "ok", source: "test", specialite: "relecture_open_weight", mode: "juge", inTok: 2000, outTok: 1000, ms: 1234)
        let e = MetaOnly.journalTail().last { ($0["source"] as? String) == "test" }
        XCTAssertEqual(e?["specialite"] as? String, "relecture_open_weight")
        XCTAssertEqual((e?["cout_usd"] as? Double) ?? -1, 0.00675, accuracy: 1e-9)
        XCTAssertEqual(e?["cerveau"] as? String, "spark-open-baseten")
    }

    // MARK: aucune fuite de clé

    func testSnapshotNeverLeaksKeyValues() {
        let r = Router(keys: keys())
        let snap = MetaSpecialites.snapshot(router: r, keys: keys())
        let s = String(data: jsonData(snap), encoding: .utf8) ?? ""
        XCTAssertFalse(s.contains(Self.fakeSecret))
        for v in ((snap["cles"] as? [String: String]) ?? [:]).values { XCTAssertTrue(v == "oui" || v == "non") }
        XCTAssertEqual((snap["specialites"] as? [[String: Any]])?.count, Specialite.allCases.count)
    }
}
