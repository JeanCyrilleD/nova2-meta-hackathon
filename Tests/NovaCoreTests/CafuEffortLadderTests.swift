import XCTest
@testable import NovaCore

/// 31/10 (test réel CAFU 20:58 : « Spark 1.3 a échoué (reasoning_effort = max) : réponse vide ») — échelle de raisonnement.
/// SIMULÉ : fournisseur factice (fermeture), aucun réseau, aucune dépense.
final class CafuEffortLadderTests: XCTestCase {
    /// Fournisseur simulé : au niveau « max », le raisonnement mange tout max_tokens → le flux finit sans texte
    /// (BrainFailure « réponse vide » comme Brains.swift) ; à « xhigh », il rend du texte.
    func simulatedProvider(_ eff: String, calls: inout [String], emptyAs: String = "réponse vide") -> CafuMode.EffortAttempt {
        calls.append(eff)
        let out: String = eff == "max" ? "" : "Note CAFU rédigée au niveau " + eff
        if out.isEmpty, let why = CafuMode.emptyReason(out: out, failure: emptyAs) {
            return .descend(warning: why, error: "Spark 1.3 a échoué (reasoning_effort = " + eff + ") : " + emptyAs)
        }
        return .text(out)
    }

    func testEmptyAtMaxDescendsToXhighWithVisibleWarning() {
        var calls: [String] = [], warnings: [String] = []
        let r = CafuMode.runLadder(["max", "xhigh", "high"], from: 0, warn: { warnings.append($0) }) { simulatedProvider($0, calls: &calls) }
        XCTAssertEqual(r.err, "")
        XCTAssertEqual(r.level, "xhigh")
        XCTAssertEqual(r.text, "Note CAFU rédigée au niveau xhigh")
        XCTAssertEqual(calls, ["max", "xhigh"], "un seul cran, même cerveau, pas de repli silencieux")
        XCTAssertEqual(warnings, ["Running at xhigh, max unavailable (réponse vide)"])
    }

    func testReasoningWithoutTextAlsoDescends() {
        var calls: [String] = [], warnings: [String] = []
        let r = CafuMode.runLadder(["max", "xhigh"], from: 0, warn: { warnings.append($0) }) {
            simulatedProvider($0, calls: &calls, emptyAs: "raisonnement sans texte (plafond de sortie atteint pendant la réflexion)")
        }
        XCTAssertEqual(r.level, "xhigh")
        XCTAssertEqual(warnings, ["Running at xhigh, max unavailable (raisonnement sans texte)"])
    }

    func testEmptyAtLastLevelIsVisibleFailureAndOtherErrorsDoNotDescend() {
        var warnings: [String] = []
        let r = CafuMode.runLadder(["max"], from: 0, warn: { warnings.append($0) }) { _ in .descend(warning: "réponse vide", error: "Spark 1.3 a échoué (reasoning_effort = max) : réponse vide") }
        XCTAssertEqual(r.text, ""); XCTAssertTrue(r.err.contains("réponse vide")); XCTAssertTrue(warnings.isEmpty)
        var calls: [String] = []
        let r2 = CafuMode.runLadder(["max", "xhigh"], from: 0, warn: { warnings.append($0) }) { calls.append($0); return .fail("HTTP 500") }
        XCTAssertEqual(calls, ["max"], "un échec autre que refus/vide ne descend pas"); XCTAssertEqual(r2.err, "HTTP 500")
        // Texte visible = pas « vide » ; espaces seulement = vide ; autre échec = pas vide.
        XCTAssertNil(CafuMode.emptyReason(out: "texte", failure: "réponse vide"))
        XCTAssertEqual(CafuMode.emptyReason(out: " \n ", failure: nil), "réponse vide")
        XCTAssertNil(CafuMode.emptyReason(out: "", failure: "HTTP 429 trop de requêtes"))
    }

    func testMaxLevelGetsRoomForVisibleText() {
        XCTAssertEqual(CafuMode.maxTokens(effort: "max", base: 32000, atMax: 48000), 48000)
        XCTAssertEqual(CafuMode.maxTokens(effort: "xhigh", base: 32000, atMax: 48000), 32000)
        XCTAssertEqual(CafuMode.maxTokens(effort: "max", base: 64000, atMax: 48000), 64000, "jamais moins que la base")
        XCTAssertEqual(CafuMode.firstTokenTimeout(maxTokens: 32000), 320)
        XCTAssertEqual(CafuMode.firstTokenTimeout(maxTokens: 48000), 480)
        XCTAssertEqual(CafuMode.firstTokenTimeout(maxTokens: 16000), 300)
    }
}
