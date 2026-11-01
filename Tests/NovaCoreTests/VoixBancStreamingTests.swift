import XCTest
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
@testable import NovaCore

/// 01/11 (voix-rapide) — banc voix : mode streaming simulé (partie pure) et plafond de sortie. SIMULÉ : aucun appel, aucun micro.
final class VoixBancStreamingTests: XCTestCase {
    // MARK: 9. Banc streaming (pur)

    func testPaquetsDe100ms() {
        let p = VoixTest.paquets(dataBytes: 16000 * 2 + 100, rate: 16000)
        XCTAssertEqual(p.count, 11)
        XCTAssertEqual(p.first, 0..<3200)
        XCTAssertEqual(p.last, 32000..<32100)
        XCTAssertEqual(VoixTest.localeStreaming("en"), "en-US")
        XCTAssertEqual(VoixTest.localeStreaming("fr"), "fr-FR")
    }

    func testPlafondDeSortieDuBancReleve() {
        XCTAssertGreaterThanOrEqual(VoixTest.sparkMaxOut, 1024, "banc : plafond de sortie relevé (raisonnement non diffusé de Spark)")
        XCTAssertLessThan(VoixTest.pireCasPassage(durations: Array(repeating: 5000, count: 36), estIn: 170), VoixTest.plafondUSD, "fichier (24) + streaming (12) sous le plafond")
    }
}
