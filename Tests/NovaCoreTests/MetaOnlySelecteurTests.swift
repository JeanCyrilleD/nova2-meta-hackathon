import XCTest
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
@testable import NovaCore

/// 01/11 (voix-rapide) — défaut d'interface : en meta_only, le sélecteur de cerveaux (/api/state « brains ») ne liste que les
/// cerveaux Meta. SIMULÉ : clés factices en mémoire, aucun appel réseau. Réglages sous NOVA_HOME temporaire.
final class MetaOnlySelecteurTests: XCTestCase {
    static var previousHome: String? = nil
    override class func setUp() {
        super.setUp()
        previousHome = ProcessInfo.processInfo.environment["NOVA_HOME"]
        let d = FileManager.default.temporaryDirectory.appendingPathComponent("nova-selecteur-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        setenv("NOVA_HOME", d.path, 1)
        unsetenv("NOVA_DIAG_DIR")
    }
    override class func tearDown() {
        if let p = previousHome { setenv("NOVA_HOME", p, 1) } else { unsetenv("NOVA_HOME") }
        super.tearDown()
    }
    // Version hackathon : meta_only est vrai en dur (MetaOnly.enabled), aucun interrupteur à surcharger.

    // MARK: 10. Sélecteur de cerveaux en meta_only

    func testSelecteurMetaOnlySeulementMeta() {
        let keys = MemoryKeyStore([KnownKeys.sparkNova.service: "x", KnownKeys.metaModelAPI.service: "x"])
        XCTAssertTrue(MetaOnly.enabled)
        let r = Router(keys: keys)
        let rows = r.healthSnapshot()
        let ids: [String] = rows.compactMap { $0["id"] as? String }
        XCTAssertFalse(rows.isEmpty)
        XCTAssertFalse(ids.contains("local"), "ni la ligne « Local (aucun moteur détecté) »")
        XCTAssertTrue(ids.contains("spark-1.3"), ids.joined(separator: ","))
        XCTAssertTrue(rows.allSatisfy { ($0["meta"] as? Bool) == true })
    }
}
