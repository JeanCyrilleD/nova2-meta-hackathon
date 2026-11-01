import XCTest
@testable import NovaCore

/// 01/11 — correctifs après les tests réels CAFU du 31/10 (23:00 et 23:07). SIMULÉ : fermetures factices, aucun réseau, aucune dépense.
///  1) test d'acceptation : « aucune réponse après 60 s » (délai de 60 s codé en dur dans le client du test) ;
///  2a) un HTTP 0 Tavily isolé tuait le run après 3 recherches réussies ; Algolia « nova-cafu : HTTP 0 » masqué par ok = true ;
///  2b) « max_tokens: 32000 » journalisé alors que le niveau max reçoit cafu_max_tokens_niveau_max (48 000).
final class CafuRealRunFixTests: XCTestCase {

    // MARK: 1) délais du chemin réellement emprunté

    func testAcceptanceClientWaitsForMaxLevelReasoning() {
        let t = CafuMode.testClientTimeouts(maxTokensAtMax: 48000)
        XCTAssertEqual(t.firstByte, 780, "premier mot au niveau max (480 s) + 300 s de préparation")
        XCTAssertGreaterThanOrEqual(t.idle, 600)
        XCTAssertGreaterThan(t.idle, CafuMode.firstTokenTimeout(maxTokens: 48000), "un raisonnement muet ne doit pas couper le client")
        XCTAssertGreaterThanOrEqual(t.total, 3600)
        XCTAssertGreaterThanOrEqual(CafuMode.testClientTimeouts(maxTokensAtMax: 16000).firstByte, 600, "jamais sous max(300, …) + 300")
        XCTAssertGreaterThanOrEqual(CafuMode.planFirstTokenTimeout, 120)
    }

    func testNoHardcoded60sTimeoutLeftOnCafuPath() throws {
        let root: URL = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let src: String = try String(contentsOf: root.appendingPathComponent("Sources/NovaCore/Feat_CafuMode.swift"), encoding: .utf8)
        XCTAssertFalse(src.contains("firstByteTimeout: 60"), "client du test d'acceptation : plus de 60 s en dur")
        XCTAssertFalse(src.contains("firstTokenTimeout: 60"), "plan de recherche : plus de 60 s en dur")
        XCTAssertTrue(src.contains("CafuMode.testClientTimeouts(maxTokensAtMax:"), "le client du test tire ses délais du niveau max")
    }

    // MARK: 2a) Tavily : reprises, puis recherche sautée ; arrêt seulement sous le minimum

    func simulate(_ seq: [Int]) -> (r: (st: Int, o: [String: Any]?, err: String, tries: Int), sleeps: [TimeInterval]) {
        var i: Int = 0
        var sleeps: [TimeInterval] = []
        let r = CafuMode.withRetry(sleep: { sleeps.append($0) }) { () -> (Int, [String: Any]?, String) in
            let st: Int = seq[min(i, seq.count - 1)]; i += 1
            return (st, st == 200 ? ["results": [[String: Any]]()] : nil, st == 200 ? "" : "HTTP " + String(st) + " (simulé)")
        }
        return (r, sleeps)
    }

    func testIsolatedHttp0IsRetriedTwiceWithShortDelay() {
        let a = simulate([0, 0, 200])
        XCTAssertEqual(a.r.st, 200); XCTAssertEqual(a.r.tries, 3); XCTAssertEqual(a.sleeps, [2, 5])
        let b = simulate([0, 200])
        XCTAssertEqual(b.r.st, 200); XCTAssertEqual(b.r.tries, 2); XCTAssertEqual(b.sleeps, [2])
        let c = simulate([503, 429, 200])
        XCTAssertEqual(c.r.st, 200); XCTAssertEqual(c.r.tries, 3, "5xx et 429 sont passagers")
    }

    func testPersistentHttp0IsSkippedNotFatal() {
        let a = simulate([0, 0, 0, 200])
        XCTAssertEqual(a.r.st, 0); XCTAssertEqual(a.r.tries, 3, "1 essai + 2 reprises, pas plus")
        XCTAssertTrue(CafuMode.tavilyTransient(a.r.st), "échec passager → recherche sautée avec avertissement, pas d'arrêt")
        // Scénario du run réel de 23:07 : 3 recherches Mali réussies, la 4e (Niger, actualité) sans réponse, les suivantes réussissent.
        XCTAssertNil(CafuMode.searchPhaseVerdict(okSearches: 5, totalResults: 50, skipped: ["news, last 12 months — Niger : HTTP 0"]))
        XCTAssertNil(CafuMode.searchPhaseVerdict(okSearches: 3, totalResults: 30, skipped: ["x : HTTP 0"]), "le minimum (3) suffit")
    }

    func testStopOnlyBelowMinimumOrOnDurableError() {
        let v = CafuMode.searchPhaseVerdict(okSearches: 2, totalResults: 20, skipped: ["news — Niger : HTTP 0", "official — Niger : HTTP 0"])
        XCTAssertNotNil(v)
        XCTAssertTrue(v?.contains("moins de 3") == true && v?.contains("Niger") == true, "l'arrêt dit quelles recherches ont été sautées")
        XCTAssertNotNil(CafuMode.searchPhaseVerdict(okSearches: 4, totalResults: 0, skipped: []))
        let k = simulate([401, 200])
        XCTAssertEqual(k.r.tries, 1, "clé refusée : pas de reprise"); XCTAssertFalse(CafuMode.tavilyTransient(401))
        XCTAssertFalse(CafuMode.tavilyTransient(432)); XCTAssertFalse(CafuMode.tavilyTransient(402))
    }

    // MARK: 2a) Algolia : état honnête index par index

    func fakeAlgolia(_ plan: [String: [Int]]) -> (request: (String, TimeInterval) -> (Int, Data), timeouts: () -> [String: [TimeInterval]]) {
        var seen: [String: Int] = [:]
        var timeouts: [String: [TimeInterval]] = [:]
        let f: (String, TimeInterval) -> (Int, Data) = { (idx: String, t: TimeInterval) -> (Int, Data) in
            let n: Int = seen[idx, default: 0]; seen[idx] = n + 1
            timeouts[idx, default: []].append(t)
            let seq: [Int] = plan[idx] ?? [200]
            let st: Int = seq[min(n, seq.count - 1)]
            return (st, st == 200 ? Data(#"{"hits":[{"title":"h1","text":"t"},{"title":"h2","text":"t"}]}"#.utf8) : Data())
        }
        return (f, { timeouts })
    }

    func testAlgoliaHttp0OnCafuIndexIsRetriedThenReportedHonestly() {
        let idx: [String] = ["nova-cafu", "nova-bibliotheque", "nova-memoire"]
        let a = fakeAlgolia(["nova-cafu": [0, 200]])
        var r = CafuMode.algoliaSearchIndexes(idx, q: "Niger NGO", request: a.request)
        XCTAssertTrue(r.ok); XCTAssertEqual(r.calls, 4); XCTAssertEqual(r.hits.count, 6)
        XCTAssertEqual(a.timeouts()["nova-cafu"], [8, 15], "reprise unique, délai plus long (connexion à froid)")
        XCTAssertTrue(r.states["nova-cafu"]?.hasPrefix("ok") == true)
        XCTAssertTrue(r.errs.isEmpty)

        r = CafuMode.algoliaSearchIndexes(idx, q: "Niger NGO", request: fakeAlgolia(["nova-cafu": [0, 0]]).request)
        XCTAssertTrue(r.ok, "les deux autres index ont répondu")
        XCTAssertEqual(r.states["nova-cafu"], "échec : aucune réponse (2 essais)", "l'index des notes CAFU muet n'est pas masqué")
        XCTAssertTrue(r.states["nova-bibliotheque"]?.hasPrefix("ok") == true)
        XCTAssertTrue(r.errs.contains(where: { $0.hasPrefix("nova-cafu : HTTP 0") }))

        r = CafuMode.algoliaSearchIndexes(idx, q: "x", request: fakeAlgolia(["nova-cafu": [404], "nova-bibliotheque": [0, 0], "nova-memoire": [0, 0]]).request)
        XCTAssertFalse(r.ok, "aucun index n'a répondu → bibliothèque indisponible (arrêt si cafu_algolia_obligatoire)")
        XCTAssertEqual(r.states["nova-cafu"], "absent (404 : rien encore versé)")
    }

    // MARK: 2b) max_tokens du niveau max envoyé ET journalisé

    func testMaxLevelTokenCapIsLoggedEvenWhenRunStopsBeforeDrafting() {
        let j = CafuMode.journalMaxTokens(level: "", ladder: ["max", "xhigh", "high"], base: 32000, atMax: 48000, sent: 0)
        XCTAssertEqual(j["max_tokens"] as? Int, 48000, "run arrêté avant rédaction : plafond PRÉVU du niveau de départ (max), pas la base")
        XCTAssertEqual(j["max_tokens_niveau"] as? String, "max")
        XCTAssertEqual(j["max_tokens_envoye"] as? Int, 0, "rien n'a été envoyé à Spark")
        XCTAssertEqual((j["max_tokens_par_niveau"] as? [String: Int]) ?? [:], ["max": 48000, "xhigh": 32000, "high": 32000])
        XCTAssertEqual(j["premier_mot_s"] as? Int, 480)
        let x = CafuMode.journalMaxTokens(level: "xhigh", ladder: ["max", "xhigh", "high"], base: 32000, atMax: 48000, sent: 32000)
        XCTAssertEqual(x["max_tokens"] as? Int, 32000); XCTAssertEqual(x["max_tokens_envoye"] as? Int, 32000)
        let m = CafuMode.journalMaxTokens(level: "max", ladder: ["max", "xhigh", "high"], base: 32000, atMax: 48000, sent: 48000)
        XCTAssertEqual(m["max_tokens"] as? Int, 48000); XCTAssertEqual(m["max_tokens_envoye"] as? Int, 48000)
    }

    func testDraftingSendsTheMaxLevelCap() throws {
        // Le plafond envoyé à Spark vient de CafuMode.maxTokens(effort:base:atMax:) avec cafu_max_tokens_niveau_max — vérifié dans la source.
        let root: URL = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let src: String = try String(contentsOf: root.appendingPathComponent("Sources/NovaCore/Feat_CafuMode.swift"), encoding: .utf8)
        XCTAssertTrue(src.contains(#"settings.get("cafu_max_tokens_niveau_max", 48000)"#))
        XCTAssertTrue(src.contains("let tok: Int = CafuMode.maxTokens(effort: eff, base: maxTok, atMax: maxTokAtMax)"))
        XCTAssertTrue(src.contains("maxTokens: tok, mode: \"deep\", firstTokenTimeout: ftt"), "le plafond calculé est celui passé au flux")
        XCTAssertTrue(src.contains("sentTok = tok"), "le plafond envoyé est journalisé")
    }
}
