import XCTest
@testable import NovaCore

/// PILOTAGE (01/11) — tests SIMULÉS des outils de pilotage de Nova : réglages vérifiés, refus de sécurité,
/// conversations de Nova, rendu des constats de navigation et capacités ToolPolicy des nouveaux verbes.
/// Données dans un bac à sable (NOVA_HOME temporaire) ; aucune fenêtre (refresh: false), aucun réseau.
final class PilotageTests: XCTestCase {
    static var previousHome: String? = nil
    static var previousDiag: String? = nil

    override class func setUp() {
        super.setUp()
        previousHome = ProcessInfo.processInfo.environment["NOVA_HOME"]
        previousDiag = ProcessInfo.processInfo.environment["NOVA_DIAG_DIR"]
        let d = FileManager.default.temporaryDirectory.appendingPathComponent("nova-pilotage-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        setenv("NOVA_HOME", d.path, 1)
        unsetenv("NOVA_DIAG_DIR")
    }
    override class func tearDown() {
        if let p = previousHome { setenv("NOVA_HOME", p, 1) } else { unsetenv("NOVA_HOME") }
        if let p = previousDiag { setenv("NOVA_DIAG_DIR", p, 1) }
        super.tearDown()
    }

    // MARK: types et coercition

    func testKindDistingueBooleensEtNombresMemeApresJSON() throws {
        let d = try JSONSerialization.jsonObject(with: Data(#"{"a":true,"b":1,"c":2.5,"d":"x","e":[1]}"#.utf8)) as! [String: Any]
        XCTAssertEqual(NovaPilot.kind(d["a"]), "booléen")
        XCTAssertEqual(NovaPilot.kind(d["b"]), "entier")
        XCTAssertEqual(NovaPilot.kind(d["c"]), "décimal")
        XCTAssertEqual(NovaPilot.kind(d["d"]), "texte")
        XCTAssertEqual(NovaPilot.kind(d["e"]), "structure")
        XCTAssertEqual(NovaPilot.kind(true), "booléen")
        XCTAssertEqual(NovaPilot.kind(6), "entier")
        XCTAssertEqual(NovaPilot.kind(nil), "absent")
    }

    func testCoercitionAuTypeReel() {
        XCTAssertEqual(NovaPilot.coerce("oui", like: false).0 as? Bool, true)
        XCTAssertEqual(NovaPilot.coerce("Désactivé", like: true).0 as? Bool, false)
        XCTAssertNil(NovaPilot.coerce("peut-être", like: true).0, "une bascule n'accepte jamais du texte libre")
        XCTAssertEqual(NovaPilot.coerce("8", like: 6).0 as? Int, 8)
        XCTAssertNil(NovaPilot.coerce("huit", like: 6).0)
        XCTAssertEqual(NovaPilot.coerce("2,5", like: 1.0).0 as? Double, 2.5)
        XCTAssertNil(NovaPilot.coerce("x", like: ["a"]).0, "réglage structuré : refusé")
        XCTAssertEqual(NovaPilot.coerce(" saphir ", like: "aurore").0 as? String, "saphir")
    }

    func testSuggestionsDeCles() {
        let keys = ["text_size", "read_width", "notify", "theme", "dots_plafond"]
        XCTAssertTrue(NovaPilot.suggest("text_siz", among: keys).contains("text_size"))
        XCTAssertTrue(NovaPilot.suggest("plafond", among: keys).contains("dots_plafond"))
        XCTAssertEqual(NovaPilot.suggest("zzzzzzzz", among: keys), [])
    }

    // MARK: écriture vérifiée et refus

    func testSetEcritPuisRelitSurDisque() {
        let r = NovaPilot.setSetting("notify", "non", refresh: false)
        XCTAssertTrue(r.hasPrefix("RÉGLAGE VÉRIFIÉ"), r)
        XCTAssertTrue(r.contains("true → false"), r)
        XCTAssertEqual(NovaPilot.show(Settings().all()["notify"]), "false", "valeur réellement écrite en booléen, pas en texte")
        let again = NovaPilot.setSetting("notify", "off", refresh: false)
        XCTAssertTrue(again.hasPrefix("RÉGLAGE DÉJÀ EN PLACE"), again)
        let n = NovaPilot.setSetting("dots_plafond", "9", refresh: false)
        XCTAssertTrue(n.hasPrefix("RÉGLAGE VÉRIFIÉ"), n)
        XCTAssertEqual(Settings().all()["dots_plafond"] as? Int, 9)
    }

    func testSetValeurInvalideNEcritRien() {
        let before = NovaPilot.show(Settings().all()["dots_auto"])
        let r = NovaPilot.setSetting("dots_auto", "peut-être", refresh: false)
        XCTAssertTrue(r.hasPrefix("ÉCHEC PRÉCIS"), r)
        XCTAssertTrue(r.contains("Rien n'a été écrit"), r)
        XCTAssertEqual(NovaPilot.show(Settings().all()["dots_auto"]), before)
    }

    func testCleInconnueProposeDesVoisines() {
        let r = NovaPilot.setSetting("dots_plafon", "3", refresh: false)
        XCTAssertTrue(r.contains("inconnu"), r)
        XCTAssertTrue(r.contains("dots_plafond"), r)
        XCTAssertNil(Settings().all()["dots_plafon"], "aucune clé inventée n'est créée")
    }

    func testReservesAAhadiRefusesAvecCheminExactSansEcriture() {
        for k in NovaApp.ownerOnlySettings {
            let before = NovaPilot.show(Settings().all()[k])
            let r = NovaPilot.setSetting(k, "true", refresh: false)
            XCTAssertTrue(r.hasPrefix("REFUSÉ"), k + " : " + r)
            XCTAssertEqual(NovaPilot.show(Settings().all()[k]), before, "réservé non modifié : " + k)
        }
        let b = NovaPilot.setSetting("brain", "wonder-1.0", refresh: false)
        XCTAssertTrue(b.contains("Assistant › « Cerveau par défaut »"), b)
        XCTAssertTrue(b.contains("nova_ui ouvrir|reglages|Cerveau par défaut"), b)
        XCTAssertEqual(Settings().all()["brain"] as? String, "spark-1.3")
    }

    func testSecretsRefuses() {
        for k in ["vendor_api_key", "api_token", "bridge_enabled_x", "knowledge_roots"] {
            XCTAssertTrue(NovaPilot.setSetting(k, "x", refresh: false).hasPrefix("REFUSÉ"), k)
        }
    }

    func testListeBlancheDeNovaSelfConservee() {
        let r = NovaPilot.setSetting("dots_plafond", "4", tool: "nova_self", allowed: ["theme", "notify"], refresh: false)
        XCTAssertTrue(r.contains("n'est pas modifiable par nova_self"), r)
        XCTAssertTrue(r.contains("app set dots_plafond"), r)
    }

    // MARK: conversations de Nova

    let convs: [[String: Any]] = [
        ["id": "c1", "title": "Approfondissons la transcription", "pinned": true, "count": 12, "updated": "2026-10-28T17:45:00Z"],
        ["id": "c2", "title": "Budget images (exemple)", "pinned": false, "count": 3, "updated": "2026-10-28T17:40:00Z"],
        ["id": "c3", "title": "Transcription CAFU meeting", "pinned": false, "count": 5, "updated": "2026-10-28T17:30:00Z"],
    ]

    func testResolutionDesConversations() {
        XCTAssertEqual(NovaPilot.resolveConv("c2", in: convs).id, "c2")
        XCTAssertEqual(NovaPilot.resolveConv("chat épinglé", in: convs).id, "c1", "cas réel du 28/10 17:42")
        XCTAssertEqual(NovaPilot.resolveConv("budget images", in: convs).id, "c2")
        XCTAssertEqual(NovaPilot.resolveConv("transcription", in: convs).id, "c1", "à égalité, l'unique épinglée l'emporte")
        let none = NovaPilot.resolveConv("inexistant", in: convs)
        XCTAssertNil(none.id)
        XCTAssertFalse(none.candidats.isEmpty, "un échec propose des candidats")
        var two = convs; two[1]["pinned"] = true
        let amb = NovaPilot.resolveConv("épinglée", in: two)
        XCTAssertNil(amb.id); XCTAssertEqual(amb.candidats.count, 2)
    }

    func testListeEtLectureDesConversations() {
        let l = NovaPilot.convList(convs, filter: "épinglées")
        XCTAssertTrue(l.contains("[c1]")); XCTAssertFalse(l.contains("[c2]"))
        let c: [String: Any] = ["title": "T", "messages": [["role": "user", "content": "bonjour", "ts": "2026-10-28T17:00:00Z"],
                                                            ["role": "assistant", "content": "salut", "ts": "2026-10-28T17:00:05Z"]]]
        let r = NovaPilot.convRead(c, id: "c9", last: 1)
        XCTAssertTrue(r.contains("Nova") && r.contains("salut")); XCTAssertFalse(r.contains("bonjour"))
    }

    // MARK: rendu des constats

    func testRenduNavigationVerifieeEtEchecPrecis() {
        let ok: [String: Any] = ["ok": true, "ecran": "settings", "label": "Réglages", "section": ["trouvee": true, "via": "onglet", "label": "Assistant"],
                                 "etat": ["ecran": "settings", "label": "Réglages", "section_active": "Assistant",
                                          "controles": [["ligne": "Cerveau par défaut", "valeur": "Spark 1.3"]]]]
        let s = NovaPilot.renderNav(ok)
        XCTAssertTrue(s.hasPrefix("VÉRIFIÉ"), s)
        XCTAssertTrue(s.contains("Section « Assistant » ouverte"), s)
        XCTAssertTrue(s.contains("Cerveau par défaut = Spark 1.3"), s)
        let ko: [String: Any] = ["ok": false, "erreur": "écran ambigu : « f »", "candidats": [["id": "finance", "label": "Finance"], ["id": "fundings", "label": "Fundings"]]]
        let e = NovaPilot.renderNav(ko)
        XCTAssertTrue(e.hasPrefix("ÉCHEC PRÉCIS"), e)
        XCTAssertTrue(e.contains("Finance [finance]") && e.contains("Ne contourne pas"), e)
        XCTAssertTrue(NovaPilot.renderNav(nil).hasPrefix("INJOIGNABLE"))
        let st = NovaPilot.renderState(["ok": true, "ecran": "conversations", "label": "Conversations", "conversation": "c1", "boutons": 4, "champs": 1])
        XCTAssertTrue(st.contains("Conversation affichée : [c1]"), st)
    }

    // MARK: ToolPolicy (capacités WP5) des nouveaux verbes — fermé par défaut pour les runs sans surveillance

    func testCapacitesDesVerbesDePilotage() {
        XCTAssertEqual(ToolCapabilities.required(tool: "app", arg: "conv-lire c1"), [.fileRead])
        XCTAssertEqual(ToolCapabilities.required(tool: "app", arg: "conv-liste"), [.fileRead])
        XCTAssertEqual(ToolCapabilities.required(tool: "app", arg: "conv-ouvrir c1"), [.screen])
        XCTAssertEqual(ToolCapabilities.required(tool: "nova_ui", arg: "conversation|c1"), [.screen])
        XCTAssertEqual(ToolCapabilities.required(tool: "nova_ui", arg: "etat"), [])
        XCTAssertFalse(ToolCapabilities.required(tool: "app", arg: "conv-ouvrir c1").isSubset(of: ToolCapabilities.unattended), "un Éclat planifié ne change jamais l'écran")
        XCTAssertTrue(ToolCapabilities.required(tool: "app", arg: "ui-clic Notifications > off").isSubset(of: [.screen]))
        XCTAssertTrue(NovaApp.pilotVerbs.isSuperset(of: ["conv-liste", "conv-lire", "conv-ouvrir"]))
    }
}
