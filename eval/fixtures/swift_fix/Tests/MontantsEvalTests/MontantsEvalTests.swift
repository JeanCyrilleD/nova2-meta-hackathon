import XCTest
@testable import MontantsEval

final class MontantsEvalTests: XCTestCase {
    func testCasExacts() {
        XCTAssertEqual(coutMicroDollars(jetons: 1_000_000, prixMicroParMillion: 2_000_000), 2_000_000)
        XCTAssertEqual(coutMicroDollars(jetons: 333, prixMicroParMillion: 10_000_000), 3_330)
        XCTAssertEqual(coutMicroDollars(jetons: 0, prixMicroParMillion: 10_000_000), 0)
    }

    func testArrondiAuDessus() {
        // 1 jeton à 0,10 $ / M = 0,1 µ$ → 1 µ$ (jamais 0 : un appel n'est jamais gratuit par arrondi).
        XCTAssertEqual(coutMicroDollars(jetons: 1, prixMicroParMillion: 100_000), 1)
        // 999 999 jetons à 0,50 $ / M = 499 999,5 µ$ → 500 000 µ$.
        XCTAssertEqual(coutMicroDollars(jetons: 999_999, prixMicroParMillion: 500_000), 500_000)
    }

    func testGrandsVolumesSansPerte() {
        // 600 003 000 000 jetons à 1 000 001 µ$ / M = 600 003 600 003 µ$ exactement (entier).
        // Un calcul en Double (même arrondi au-dessus) donne 600 003 600 004 : l'argent ne passe jamais par un flottant.
        XCTAssertEqual(coutMicroDollars(jetons: 600_003_000_000, prixMicroParMillion: 1_000_001), 600_003_600_003)
    }

    func testTotal() {
        XCTAssertEqual(coutTotalMicroDollars([(1, 100_000), (1, 100_000), (1_000_000, 2_000_000)]), 2_000_002)
    }
}
