import XCTest
@testable import NovaCore

/// PHASE 4 — coffre derrière Touch ID : contrat du pont NovaCore ↔ NovaMac (simulé : aucun Trousseau réel, aucune invite).
final class Phase4InterfaceTests: XCTestCase {
    /// Faux magasin : enregistre les appels, ne touche jamais au vrai Trousseau.
    final class FakeStore: BiometricSecretStore {
        var items: [String: Data] = [:]
        var nextReadStatus: Int32 = 0
        var reasons: [String] = []
        func availability() -> (ok: Bool, kind: String, message: String) { (true, "touchid", "") }
        func exists(service: String, account: String) -> Bool { items[service + "|" + account] != nil }
        func store(service: String, account: String, data: Data) -> Int32 {
            if items[service + "|" + account] != nil { return -25299 }   // errSecDuplicateItem
            items[service + "|" + account] = data; return 0
        }
        func read(service: String, account: String, reason: String) -> (status: Int32, data: Data?) {
            reasons.append(reason)
            if nextReadStatus != 0 { return (nextReadStatus, nil) }
            return (0, items[service + "|" + account])
        }
    }

    func testBiometricReadKeyGoesThroughStoreWithReason() {
        let f = FakeStore()
        VaultBiometric.register(f)
        let key = Data(repeating: 7, count: 32)
        XCTAssertEqual(f.store(service: VaultBiometric.service, account: VaultBiometric.account, data: key), 0)
        let r = VaultBiometric.readKey(reason: "ouvrir le coffre de Nova")
        XCTAssertEqual(r.data, key)
        XCTAssertNil(r.error)
        XCTAssertEqual(f.reasons, ["ouvrir le coffre de Nova"], "chaque lecture passe par l'invite, avec sa raison")
    }

    func testBiometricCancelAndRefusalNeverReturnData() {
        let f = FakeStore()
        VaultBiometric.register(f)
        _ = f.store(service: VaultBiometric.service, account: VaultBiometric.account, data: Data(repeating: 1, count: 32))
        f.nextReadStatus = -128   // errSecUserCanceled
        let c = VaultBiometric.readKey(reason: "x")
        XCTAssertNil(c.data); XCTAssertEqual(c.error, "ouverture annulée")
        f.nextReadStatus = -25293  // errSecAuthFailed
        let d = VaultBiometric.readKey(reason: "x")
        XCTAssertNil(d.data); XCTAssertTrue((d.error ?? "").contains("-25293"))
    }
}
