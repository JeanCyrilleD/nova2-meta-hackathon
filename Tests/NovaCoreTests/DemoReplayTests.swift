import XCTest
@testable import NovaCore

/// 01/11 — mode démo sans clé (DemoReplay) et garanties « 100 % Meta » de la version hackathon. Aucun réseau, aucune clé.
final class DemoReplayTests: XCTestCase {
    static var repo: URL { URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent() }
    static var traces: String { repo.appendingPathComponent("demo/traces").path }

    func testAllTracesPresentAndListed() {
        let l = DemoReplay.list(dir: Self.traces)
        XCTAssertEqual(l.map { $0["id"] as? String ?? "" }, DemoReplay.ids)
        for r in l { XCTAssertNotNil(r["recorded"] as? Bool, "chaque trace dit si elle vient d'une exécution réelle réussie") }
    }

    func testCafuTraceIsARealMetaRun() throws {
        let t = try XCTUnwrap(DemoReplay.trace("cafu_note", dir: Self.traces))
        XCTAssertEqual(t["model"] as? String, "muse-spark-1.3")
        XCTAssertEqual(t["recorded"] as? Bool, true)
        XCTAssertTrue((t["endpoint"] as? String ?? "").hasPrefix("https://api.meta.ai/"))
        XCTAssertFalse((t["steps"] as? [String] ?? []).isEmpty)
        XCTAssertFalse((t["note"] as? String ?? "").isEmpty)
    }

    func testIdWhitelistRejectsPaths() {
        XCTAssertNil(DemoReplay.trace("../../Package", dir: Self.traces))
        XCTAssertNil(DemoReplay.trace("inconnu", dir: Self.traces))
    }

    func testReplayEventsShowModelIdsAndAreMarkedReplay() throws {
        let t = try XCTUnwrap(DemoReplay.trace("meta_routing", dir: Self.traces))
        let ev = DemoReplay.events(t)
        XCTAssertEqual(ev.first?["type"] as? String, "start"); XCTAssertEqual(ev.first?["replay"] as? Bool, true)
        XCTAssertEqual(ev.last?["type"] as? String, "done")
        let calls = ev.filter { ($0["type"] as? String) == "model_call" }
        XCTAssertFalse(calls.isEmpty)
        for c in calls {
            XCTAssertEqual(c["meta"] as? Bool, true, "le journal de preuve ne contient que des appels Meta")
            XCTAssertFalse((c["modele"] as? String ?? "").isEmpty)
        }
    }

    func testTracesCarryNoPersonalDataOrSecrets() throws {
        let fm = FileManager.default
        for id in DemoReplay.ids {
            let s = try XCTUnwrap(String(data: try XCTUnwrap(fm.contents(atPath: Self.traces + "/" + id + ".json")), encoding: .utf8))
            XCTAssertNil(s.range(of: #"[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[a-z]{2,}"#, options: .regularExpression), id + " : adresse mail")
            XCTAssertFalse(s.contains("/Users/"), id + " : chemin local")
            XCTAssertFalse(SecretsGuard.containsSecret(s), id + " : secret")
        }
    }

    func testEnabledByEnvironment() {
        setenv(DemoReplay.envKey, "1", 1); defer { unsetenv(DemoReplay.envKey) }
        XCTAssertTrue(DemoReplay.enabled)
    }

    /// Garde de la version soumise : aucun hôte d'API de modèle non Meta dans les sources, le web et la configuration.
    func testNoNonMetaModelHostInShippedCode() throws {
        let forbidden: [String] = ["api.anthropic.com", "api.openai.com", "generativelanguage.googleapis.com", "api.deepseek.com",
                                   "api.moonshot.ai", "api.z.ai", "api.x.ai", "api.mistral.ai", "api.groq.com", "openrouter.ai",
                                   "api.elevenlabs.io", "assemblyai.com", "api.perplexity.ai", "127.0.0.1:11434"]
        let fm = FileManager.default
        for sub in ["Sources", "web/js", "Config"] {
            let root = Self.repo.appendingPathComponent(sub)
            guard let en = fm.enumerator(at: root, includingPropertiesForKeys: nil) else { continue }
            for case let u as URL in en where ["swift", "js", "json", "html"].contains(u.pathExtension) {
                guard let s = try? String(contentsOf: u, encoding: .utf8) else { continue }
                for h in forbidden { XCTAssertFalse(s.contains(h), u.lastPathComponent + " contient " + h) }
            }
        }
    }
}
