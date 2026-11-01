import XCTest
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
@testable import NovaCore

/// 01/11 (voix-test) — banc de la chaîne voix « 100 % Meta » et correctifs de latence. SIMULÉ : aucun appel à Meta, aucune clé,
/// aucun son joué. Le chemin HTTP partagé est exercé contre un serveur local (127.0.0.1, port éphémère). Fichiers sous NOVA_HOME temporaire.
final class VoixTestTests: XCTestCase {
    static var sandbox: URL = FileManager.default.temporaryDirectory
    static var previousHome: String? = nil

    override class func setUp() {
        super.setUp()
        previousHome = ProcessInfo.processInfo.environment["NOVA_HOME"]
        let d = FileManager.default.temporaryDirectory.appendingPathComponent("nova-voixtest-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        setenv("NOVA_HOME", d.path, 1)
        unsetenv("NOVA_DIAG_DIR")
        sandbox = d
    }
    override class func tearDown() {
        if let p = previousHome { setenv("NOVA_HOME", p, 1) } else { unsetenv("NOVA_HOME") }
        super.tearDown()
    }
    // Version hackathon : meta_only est vrai en dur (MetaOnly.enabled), aucun interrupteur à surcharger.

    // MARK: - WAV

    /// WAV PCM16 de `ms` millisecondes, avec un bloc LIST avant « data » (comme ffmpeg/piper).
    static func wav(rate: Int = 16000, channels: Int = 1, ms: Int = 500, list: Bool = true) -> Data {
        var d = Data()
        func u32(_ v: Int) { var x = UInt32(v).littleEndian; withUnsafeBytes(of: &x) { d.append(contentsOf: $0) } }
        func u16(_ v: Int) { var x = UInt16(v).littleEndian; withUnsafeBytes(of: &x) { d.append(contentsOf: $0) } }
        let frames: Int = rate * ms / 1000
        var pcm = Data(count: frames * channels * 2)
        pcm[0] = 7; pcm[1] = 1
        let listBody: Data = Data("INFOISFT\u{0E}\u{00}\u{00}\u{00}Lavf61.7.100\u{00}\u{00}".utf8)
        let total: Int = 4 + 24 + (list ? 8 + listBody.count : 0) + 8 + pcm.count
        d.append(Data("RIFF".utf8)); u32(total); d.append(Data("WAVE".utf8))
        d.append(Data("fmt ".utf8)); u32(16); u16(1); u16(channels); u32(rate); u32(rate * channels * 2); u16(channels * 2); u16(16)
        if list { d.append(Data("LIST".utf8)); u32(listBody.count); d.append(listBody) }
        d.append(Data("data".utf8)); u32(pcm.count); d.append(pcm)
        return d
    }

    func testWavInfoSauteLeBlocLISTEtReconnaitLeFormatAdmis() {
        let w = Self.wav(ms: 1500)
        let i = Voice.wavInfo(w)
        XCTAssertEqual(i?.format, 1); XCTAssertEqual(i?.channels, 1); XCTAssertEqual(i?.rate, 16000); XCTAssertEqual(i?.bits, 16)
        XCTAssertEqual(i?.durationMs, 1500)
        XCTAssertTrue(Voice.isEndpointWAV(w), "WAV 16 kHz mono 16 bits : envoyé tel quel, sans afconvert")
        XCTAssertFalse(Voice.isEndpointWAV(Self.wav(rate: 24000)), "24 kHz : conversion requise")
        XCTAssertFalse(Voice.isEndpointWAV(Self.wav(channels: 2)), "stéréo : conversion requise")
        XCTAssertFalse(Voice.isEndpointWAV(Data("not a wav at all".utf8)))
        XCTAssertNil(Voice.wavInfo(Data([0x1A, 0x45, 0xDF, 0xA3])), "webm : pas un WAV")
    }

    func testWavCanoniqueRetireLeBlocLISTSansToucherAuxEchantillons() {
        let w = Self.wav(ms: 200)
        let c = Voice.canonicalWAV(w)
        let i = Voice.wavInfo(c)
        XCTAssertEqual(i?.dataOffset, 44, "en-tête canonique de 44 octets")
        XCTAssertEqual(i?.dataBytes, 16000 * 200 / 1000 * 2)
        XCTAssertEqual(c[44], 7); XCTAssertEqual(c[45], 1)
        XCTAssertTrue(Voice.isEndpointWAV(c))
        let plain = Self.wav(ms: 200, list: false)
        XCTAssertEqual(Voice.canonicalWAV(plain), plain, "déjà canonique : inchangé")
    }

    // MARK: - Mesures

    func testWERIdentiqueCasseEtPonctuation() {
        XCTAssertEqual(VoixTest.wer(reference: "What changed in Mali's NGO rules this year?", hypothese: "what changed in mali's ngo rules this year"), 0)
        XCTAssertEqual(VoixTest.wer(reference: "Le décret s'applique-t-il ?", hypothese: "le décret s applique t il"), 0)
    }

    func testWERSubstitutionsEtSuppressions() throws {
        let w = try XCTUnwrap(VoixTest.wer(reference: "What changed in Mali's NGO rules this year?", hypothese: "What changed in Mali NGO rules this year"))
        XCTAssertEqual(w, 1.0 / 9.0, accuracy: 1e-9, "« Mali's » = 2 mots, un supprimé")
        let w2 = try XCTUnwrap(VoixTest.wer(reference: "a b c d", hypothese: "a x c d e"))
        XCTAssertEqual(w2, 0.5, accuracy: 1e-9, "1 substitution + 1 insertion sur 4 mots")
        XCTAssertNil(VoixTest.wer(reference: "", hypothese: "x"), "référence inconnue : WER non calculé")
        XCTAssertEqual(VoixTest.wer(reference: "a b", hypothese: ""), 1.0)
    }

    func testCentilesMedianeEtP90() throws {
        let xs: [Double] = (1...10).map { Double($0) }
        XCTAssertEqual(try XCTUnwrap(VoixTest.centile(xs, 0.5)), 5.5, accuracy: 1e-9)
        XCTAssertEqual(try XCTUnwrap(VoixTest.centile(xs, 0.9)), 9.1, accuracy: 1e-9)
        XCTAssertNil(VoixTest.centile([], 0.5))
        let r = VoixTest.resume([-1, 100, 200])
        XCTAssertEqual(r["n"] as? Int, 2, "-1 = non mesuré, écarté")
        XCTAssertEqual(r["mediane_ms"] as? Int, 150)
        XCTAssertEqual(r["p90_ms"] as? Int, 190)
    }

    func testCoutsAuxTarifsConnus() {
        XCTAssertEqual(VoixTest.coutSTT(durationMs: 3_600_000), 0.18, accuracy: 1e-12)
        XCTAssertEqual(VoixTest.coutSTT(durationMs: 10_000), 0.0005, accuracy: 1e-12)
        XCTAssertEqual(VoixTest.coutSpark(inTok: 1_000_000, outTok: 0), 1.25, accuracy: 1e-12)
        XCTAssertEqual(VoixTest.coutSpark(inTok: 0, outTok: 1_000_000), 4.25, accuracy: 1e-12)
    }

    func testPlafondDuPassageEchecFerme() {
        let durs: [Int] = Array(repeating: 5_000, count: 12)
        let pire = VoixTest.pireCasPassage(durations: durs, estIn: 200)
        XCTAssertLessThan(pire, VoixTest.plafondUSD, "12 tours courts : bien sous 0,50 $")
        XCTAssertLessThan(pire, 0.07, "01/11 (voix-rapide) : plafond de sortie Spark 1024 (était 320) — pire cas 12 tours ≈ 0,058 $")
        XCTAssertGreaterThan(VoixTest.pireCasPassage(durations: durs, estIn: 200, maxOut: 20_000), VoixTest.plafondUSD, "sortie énorme : refusé avant tout envoi")
    }

    func testRepetitionsParDefautPourDeuxMinutes() {
        XCTAssertEqual(VoixTest.repetitionsParDefaut(inputMs: 56_000), 2, "12 phrases ≈ 56 s : série jouée deux fois")
        XCTAssertEqual(VoixTest.repetitionsParDefaut(inputMs: 61_000), 1)
        XCTAssertEqual(VoixTest.repetitionsParDefaut(inputMs: 5_000), 3, "plafonné à 3")
        XCTAssertEqual(VoixTest.repetitionsParDefaut(inputMs: 0), 1)
    }

    func testPlanDesTroisBargeIn() {
        let p = VoixTest.planBargeIn([2, 5, 8], count: 12)
        XCTAssertEqual(p, [2: "generation", 5: "synthese", 8: "generation"])
        XCTAssertTrue(VoixTest.planBargeIn([12], count: 12).isEmpty, "jamais le dernier tour : il faut un tour suivant pour mesurer la reprise")
        XCTAssertTrue(VoixTest.planBargeIn([0, -3], count: 12).isEmpty)
    }

    func testDecoupeEnContinuPhraseParPhrase() {
        let a = VoixTest.phrasesPretes("The new decree took effect in March. It requires")
        XCTAssertEqual(a.ready, ["The new decree took effect in March."], "la 1re phrase part en synthèse avant la fin du flux")
        XCTAssertEqual(a.rest, "It requires")
        XCTAssertEqual(VoixTest.phrasesPretes("Version 2.5 est").ready, [], "« 2.5 » n'est pas une fin de phrase")
        XCTAssertEqual(VoixTest.reliquat("It requires prior approval"), "It requires prior approval")
        XCTAssertNil(VoixTest.reliquat(" "))
    }

    func testCriteresDuDossier() {
        let tours: [[String: Any]] = [
            ["premier_audio_ms": 800], ["premier_audio_ms": 900, "barge_in": ["arret_ok": true]], ["premier_audio_ms": 1200],
            ["premier_audio_ms": 700, "barge_in": ["arret_ok": true]], ["premier_audio_ms": -1, "barge_in": ["arret_ok": true]],
        ]
        let c = VoixTest.criteres(tours: tours, conversationMs: 125_000)
        XCTAssertEqual(c["conversation_2_min"] as? Bool, true)
        XCTAssertEqual(c["barge_in_reussis"] as? Int, 3)
        XCTAssertEqual(c["barge_in_3"] as? Bool, true)
        XCTAssertEqual(c["premier_audio_mediane_ms"] as? Int, 850)
        XCTAssertEqual(c["premier_audio_sous_1s_mediane"] as? Bool, true)
        XCTAssertEqual(c["premier_audio_sous_1s_tours"] as? Int, 3)
        XCTAssertEqual(VoixTest.criteres(tours: [], conversationMs: 0)["premier_audio_sous_1s_mediane"] as? Bool, false, "rien mesuré : critère non atteint")
    }

    func testTraceDicteeAuFormatDemoSansTexte() {
        let ev: [[String: Any]] = [["ts": "t", "fournisseur": "meta", "modele": "muse-voice-transcribe-1.0", "meta": true, "statut": "ok",
                                    "specialite": "dictee", "ms": 640, "cout_usd": 0.0002, "transcription": "texte privé", "texte_source": "x"]]
        let t = VoixTest.traceDictee(events: ev)
        XCTAssertEqual(t["id"] as? String, "dictation")
        XCTAssertEqual(t["recorded"] as? Bool, true)
        XCTAssertEqual(t["model"] as? String, "muse-voice-transcribe-1.0")
        let e = (t["events"] as? [[String: Any]])?.first ?? [:]
        XCTAssertNil(e["transcription"], "aucun texte transcrit dans la trace publique")
        XCTAssertNil(e["texte_source"])
        XCTAssertEqual(e["ms"] as? Int, 640)
        XCTAssertEqual(VoixTest.traceDictee(events: [["statut": "echec"]])["recorded"] as? Bool, false, "jamais inventée")
    }

    // MARK: - Déclencheur et entrées

    func testDeclencheurPrisUneFoisEtRenomme() throws {
        let root = Self.sandbox.appendingPathComponent("root-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root.appendingPathComponent("dormant"), withIntermediateDirectories: true)
        XCTAssertNil(VoixTest.takeRequest(root: root.path))
        try Data(#"{"limite": 3}"#.utf8).write(to: root.appendingPathComponent("dormant/VOIX_TEST_REQUEST"))
        let cfg = try XCTUnwrap(VoixTest.takeRequest(root: root.path))
        XCTAssertEqual((cfg["limite"] as? NSNumber)?.intValue, 3)
        XCTAssertTrue(FileManager.default.fileExists(atPath: root.appendingPathComponent("dormant/VOIX_TEST_REQUEST.done.json").path))
        XCTAssertNil(VoixTest.takeRequest(root: root.path), "une seule exécution par demande")
        try Data().write(to: root.appendingPathComponent("dormant/VOIX_TEST_REQUEST"))   // `touch` : fichier vide accepté
        XCTAssertEqual(VoixTest.takeRequest(root: root.path)?.count, 0)
    }

    func testEntreesManifestPuisRepliSurLesWAV() throws {
        let dir = Self.sandbox.appendingPathComponent("vt-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        XCTAssertNotNil(VoixTest.chargerItems(dir: dir.path).erreur)
        try Self.wav().write(to: dir.appendingPathComponent("01_en.wav"))
        try Self.wav().write(to: dir.appendingPathComponent("02_fr.wav"))
        var r = VoixTest.chargerItems(dir: dir.path)
        XCTAssertEqual(r.items.map { $0.langue }, ["en", "fr"], "sans manifeste : langue tirée du nom")
        let man: [String: Any] = ["items": [["fichier": "02_fr.wav", "langue": "fr", "texte": "Bonjour"], ["fichier": "absent.wav", "langue": "en", "texte": "x"],
                                            ["fichier": "../evil.wav", "langue": "en", "texte": "x"]], "barge_in": [1]]
        try jsonData(man).write(to: dir.appendingPathComponent("manifest.json"))
        r = VoixTest.chargerItems(dir: dir.path)
        XCTAssertEqual(r.items.count, 1, "fichier absent et chemin hors dossier ignorés")
        XCTAssertEqual(r.items.first?.texte, "Bonjour")
        XCTAssertEqual(r.bargeIn, [1])
    }

    // MARK: - Voix locale

    func testChoixDeVoixParLangue() {
        XCTAssertGreaterThan(LocalVoice.voiceScore(language: "en-GB", qualityRank: 1, name: "Daniel", want: "en"),
                             LocalVoice.voiceScore(language: "en-US", qualityRank: 1, name: "Samantha", want: "en"))
        XCTAssertGreaterThan(LocalVoice.voiceScore(language: "en-GB", qualityRank: 1, name: "Daniel", want: "en"),
                             LocalVoice.voiceScore(language: "en-US", qualityRank: 3, name: "Zoe", want: "en"), "variante d'abord (en-GB), comme fr-FR pour le français")
        XCTAssertGreaterThan(LocalVoice.voiceScore(language: "en-GB", qualityRank: 3, name: "x", want: "en"),
                             LocalVoice.voiceScore(language: "en-GB", qualityRank: 1, name: "Daniel", want: "en"), "à variante égale, la meilleure qualité")
        XCTAssertEqual(LocalVoice.voiceScore(language: "fr-FR", qualityRank: 1, name: "Thomas", want: "en"), -1)
        XCTAssertEqual(LocalVoice.voiceScore(language: "en-GB", qualityRank: 1, name: "Daniel", want: nil), -1, "par défaut : français, comme avant")
        XCTAssertEqual(LocalVoice.voiceScore(language: "fr-FR", qualityRank: 2, name: "Amélie", want: nil), 100 + 20 + 3)
        XCTAssertGreaterThan(LocalVoice.voiceScore(language: "fr-FR", qualityRank: 1, name: "x", want: "fr"),
                             LocalVoice.voiceScore(language: "fr-CA", qualityRank: 1, name: "x", want: "fr"))
    }

    func testRenduMesureDuréeAudio() {
        var r = LocalVoiceRender()
        r.bytes = 48_000
        XCTAssertEqual(r.audioMs, 1000, "PCM16 mono 24 kHz : 48 octets par ms")
        XCTAssertEqual(r.firstBufferMs, -1)
        XCTAssertFalse(r.warmSynth)
    }

    // MARK: - Connexion HTTP réutilisée

    func testHotesDeLaSessionPartagee() {
        XCTAssertTrue(HTTPStream.usesPool(URL(string: "https://api.meta.ai/v1/asr/transcribe")))
        XCTAssertTrue(HTTPStream.usesPool(URL(string: "https://API.META.AI/v1/chat/completions")))
        XCTAssertFalse(HTTPStream.usesPool(URL(string: "https://llm.example.org/v1/messages")))
        XCTAssertFalse(HTTPStream.usesPool(URL(string: "wss://api.meta.ai/v1/asr/realtime")))
        XCTAssertFalse(HTTPStream.usesPool(nil))
        HTTPStream.poolEnabled = false
        defer { HTTPStream.poolEnabled = true }
        XCTAssertFalse(HTTPStream.usesPool(URL(string: "https://api.meta.ai/v1/asr/transcribe")), "interrupteur de retour arrière")
    }

    /// Chemin partagé exercé de bout en bout contre un serveur local : réponses correctes, requêtes enchaînées, erreurs HTTP,
    /// annulation, et aucune tâche orpheline dans l'aiguillage.
    func testSessionPartageeContreUnServeurLocal() throws {
        let tok = "jeton-voixtest-0123456789abcdef"
        let s = HTTPServer(token: tok)
        s.on("POST", "/api/echo") { req, res in res.json(["n": req.body.count]) }
        s.on("GET", "/api/lent") { _, res in Thread.sleep(forTimeInterval: 3); res.json(["ok": true]) }
        let port = try s.start(port: 0)
        defer { s.stop() }
        let saved = HTTPStream.pooledHosts
        HTTPStream.pooledHosts = ["127.0.0.1"]
        defer { HTTPStream.pooledHosts = saved }
        let before = HTTPPool.shared.servedCount()
        for k in 1...3 {
            var r = URLRequest(url: URL(string: "http://127.0.0.1:\(port)/api/echo")!)
            r.httpMethod = "POST"; r.httpBody = Data(count: k * 10)
            r.setValue(tok, forHTTPHeaderField: "x-nova-token"); r.setValue("127.0.0.1:\(port)", forHTTPHeaderField: "Host")
            var body = Data()
            let res = HTTPStream.run(r, firstByteTimeout: 5, idleTimeout: 5, totalTimeout: 10) { body.append($0); return true }
            XCTAssertNil(res.error, "requête \(k) : \(res.error ?? "")")
            XCTAssertEqual(res.status, 200)
            XCTAssertEqual((parseJSON(body)?["n"] as? NSNumber)?.intValue, k * 10)
        }
        XCTAssertEqual(HTTPPool.shared.servedCount() - before, 3, "les trois requêtes passent par la session partagée")
        // Erreur HTTP : sans jeton → statut ≥ 400 classé, corps d'erreur rendu
        var bad = URLRequest(url: URL(string: "http://127.0.0.1:\(port)/api/echo")!)
        bad.httpMethod = "POST"; bad.httpBody = Data("x".utf8)
        let rb = HTTPStream.run(bad, firstByteTimeout: 5, idleTimeout: 5, totalTimeout: 10) { _ in true }
        XCTAssertGreaterThanOrEqual(rb.status, 400)
        XCTAssertNotNil(rb.error)
        // Annulation (barge-in) : rendu en moins d'une seconde, tâche retirée de l'aiguillage
        var slow = URLRequest(url: URL(string: "http://127.0.0.1:\(port)/api/lent")!)
        slow.setValue(tok, forHTTPHeaderField: "x-nova-token")
        let t0 = Date()
        let rc = HTTPStream.run(slow, firstByteTimeout: 10, idleTimeout: 10, totalTimeout: 20, cancel: { Date().timeIntervalSince(t0) > 0.2 }) { _ in true }
        XCTAssertEqual(rc.kind, .canceled)
        XCTAssertLessThan(Date().timeIntervalSince(t0), 1.0, "arrêt immédiat, sans attendre la réponse")
        XCTAssertEqual(HTTPPool.shared.pendingCount(), 0, "aucune tâche orpheline")
    }
}
