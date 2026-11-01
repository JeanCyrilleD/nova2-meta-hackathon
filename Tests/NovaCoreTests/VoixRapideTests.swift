import XCTest
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
@testable import NovaCore

/// 01/11 (voix-rapide) — premier son plus tôt, langue de la voix, barge-in, réponses vides, vocabulaire, sélecteur meta_only.
/// SIMULÉ : aucun appel à Meta, aucune clé réelle, aucun micro, aucun son joué ; le flux Spark est simulé par un serveur local
/// (127.0.0.1, port éphémère). Fichiers sous NOVA_HOME temporaire.
final class VoixRapideTests: XCTestCase {
    static var previousHome: String? = nil

    override class func setUp() {
        super.setUp()
        previousHome = ProcessInfo.processInfo.environment["NOVA_HOME"]
        let d = FileManager.default.temporaryDirectory.appendingPathComponent("nova-voixrapide-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        setenv("NOVA_HOME", d.path, 1)
        unsetenv("NOVA_DIAG_DIR")
    }
    override class func tearDown() {
        if let p = previousHome { setenv("NOVA_HOME", p, 1) } else { unsetenv("NOVA_HOME") }
        super.tearDown()
    }
    // Version hackathon : meta_only est vrai en dur (MetaOnly.enabled), aucun interrupteur à surcharger.

    // MARK: 1. Première clause

    func testPremiereClauseALaVirgule() {
        let r = VoixRapide.premiereClause("D'accord, je regarde la note de")
        XCTAssertEqual(r?.clause, "D'accord,")
        XCTAssertEqual(r?.rest, "je regarde la note de")
    }
    func testPremiereClauseASixMots() {
        XCTAssertNil(VoixRapide.premiereClause("Je ne suis pas sûre"), "5 mots : on attend")
        XCTAssertNil(VoixRapide.premiereClause("Je ne suis pas sûre de"), "6e mot pas encore fini (aucun blanc derrière)")
        let r = VoixRapide.premiereClause("Je ne suis pas sûre de la source")
        XCTAssertEqual(r?.clause, "Je ne suis pas sûre de")
        XCTAssertEqual(r?.rest, "la source")
    }
    func testVirguleDecimaleNestPasUneClause() {
        XCTAssertNil(VoixRapide.premiereClause("Environ 2,5 millions"))
        XCTAssertNil(VoixRapide.premiereClause("Oui,"), "virgule en fin de tampon : la suite n'est pas encore là")
    }
    func testDecoupePremierMorceauPuisPhrases() {
        let a = VoixRapide.decoupe("Bonne question, l'IPC", premier: true)
        XCTAssertEqual(a.ready, ["Bonne question,"])
        let b = VoixRapide.decoupe("l'IPC classe la zone en phase 3, crise", premier: false)
        XCTAssertTrue(b.ready.isEmpty, "après le premier morceau : on attend la fin de phrase")
        let c = VoixRapide.decoupe("Je ne sais pas. Vérifie OCHA ", premier: true)
        XCTAssertEqual(c.ready, ["Je ne sais pas."], "une fin de phrase arrivée avant la clause passe d'abord")
    }

    // MARK: 2. Langue de la voix

    func testLangueDetecteeSurLaReponse() {
        XCTAssertEqual(VoixRapide.langue("I don't know. Which country and which NGO do you mean?"), "en")
        XCTAssertEqual(VoixRapide.langue("The outlook remains fragile."), "en")
        XCTAssertEqual(VoixRapide.langue("Je ne sais pas avec certitude. Vérifie les chiffres de l'OIM."), "fr")
        XCTAssertEqual(VoixRapide.langue("L'alerte précoce signale un danger imminent."), "fr")
        XCTAssertEqual(VoixRapide.langue("OCHA, GHO.", defaut: "en"), "en", "sigles seuls : le départage décide")
        XCTAssertEqual(VoixRapide.langue("OCHA, GHO."), "fr")
        XCTAssertEqual(VoixRapide.langueVoix("en"), "en")
        XCTAssertNil(VoixRapide.langueVoix("fr"), "français = comportement historique de LocalVoice")
    }
    func testVoixForceeGardeeSeulementDansSaLangue() {
        XCTAssertTrue(LocalVoice.voixDeLaLangue("fr-FR", want: nil))
        XCTAssertTrue(LocalVoice.voixDeLaLangue("en-GB", want: nil), "sans langue demandée : règle d'avant (voix forcée toujours)")
        XCTAssertFalse(LocalVoice.voixDeLaLangue("fr-FR", want: "en"), "réponse anglaise : la voix française forcée est écartée")
        XCTAssertTrue(LocalVoice.voixDeLaLangue("en-US", want: "en"))
    }

    // MARK: 3. Accusé de réception

    func testAccuseApres700msJamaisDeuxFoisDeSuite() {
        XCTAssertFalse(VoixRapide.doitAccuser(reglage: true, ecouleMs: 650, dejaDuSon: false, tourClos: false, accuseAuTourPrecedent: false))
        XCTAssertTrue(VoixRapide.doitAccuser(reglage: true, ecouleMs: 700, dejaDuSon: false, tourClos: false, accuseAuTourPrecedent: false))
        XCTAssertFalse(VoixRapide.doitAccuser(reglage: true, ecouleMs: 900, dejaDuSon: true, tourClos: false, accuseAuTourPrecedent: false), "la réponse sonne déjà")
        XCTAssertFalse(VoixRapide.doitAccuser(reglage: true, ecouleMs: 900, dejaDuSon: false, tourClos: false, accuseAuTourPrecedent: true), "jamais deux tours de suite")
        XCTAssertFalse(VoixRapide.doitAccuser(reglage: false, ecouleMs: 900, dejaDuSon: false, tourClos: false, accuseAuTourPrecedent: false), "voix_accuse = false")
        XCTAssertFalse(VoixRapide.doitAccuser(reglage: true, ecouleMs: 900, dejaDuSon: false, tourClos: true, accuseAuTourPrecedent: false))
        let p1 = VoixRapide.phraseAccuse(langue: "fr", precedente: "")
        let p2 = VoixRapide.phraseAccuse(langue: "fr", precedente: p1)
        XCTAssertNotEqual(p1, p2, "jamais la même phrase deux fois d'affilée")
        XCTAssertEqual(Set([p1, p2]), Set(["Mm.", "D'accord,"]))
        XCTAssertTrue(VoixRapide.accuses(langue: "en").contains("Okay,"))
    }

    // MARK: 4. Départ anticipé et reprise de parole

    func testPartielStableOuAttentePlafonnee() {
        XCTAssertFalse(VoixRapide.partielStable(depuisDernierPartielMs: 100, depuisFinParoleMs: 100))
        XCTAssertTrue(VoixRapide.partielStable(depuisDernierPartielMs: 260, depuisFinParoleMs: 50))
        XCTAssertTrue(VoixRapide.partielStable(depuisDernierPartielMs: 10, depuisFinParoleMs: 520), "plafond : jamais plus de 500 ms d'attente")
    }
    func testRepriseDeParoleEtFusion() {
        XCTAssertTrue(VoixRapide.repriseDeParole("et aussi au Niger", dejaDit: "D'accord,"))
        XCTAssertFalse(VoixRapide.repriseDeParole("d'accord", dejaDit: "D'accord,"), "l'écho de l'accusé n'est pas une reprise")
        XCTAssertFalse(VoixRapide.repriseDeParole("mm", dejaDit: ""), "un bruit court n'annule rien")
        XCTAssertEqual(VoixRapide.fusion("Quels risques au Burkina.", "et au Niger ce mois-ci"), "Quels risques au Burkina et au Niger ce mois-ci")
        XCTAssertEqual(VoixRapide.fusion("Quels risques", "Quels risques au Mali"), "Quels risques au Mali", "recouvrement non doublé")
        XCTAssertEqual(VoixRapide.fusion("", "Bonjour"), "Bonjour")
    }

    // MARK: 5. Réponses vides

    func testMotifVideNommeEtRelanceUneFois() {
        XCTAssertTrue(VoixRapide.motifVide(finish: "length", raisonnementVu: false).contains("finish_reason length"))
        XCTAssertTrue(VoixRapide.motifVide(finish: "content_filter", raisonnementVu: false).contains("content_filter"))
        XCTAssertEqual(VoixRapide.motifVide(finish: "", raisonnementVu: false), "réponse vide")
        XCTAssertTrue(VoixRapide.motifVide(finish: "", raisonnementVu: true).hasPrefix("raisonnement sans texte"))
        XCTAssertTrue(VoixRapide.relancerSiVide("Tous les cerveaux ont échoué. Dernier : Spark 1.3 : réponse vide (finish_reason length …)"))
        XCTAssertFalse(VoixRapide.relancerSiVide("HTTP 401 — clé refusée"))
        XCTAssertTrue(VoixRapide.phraseSansReponse(langue: "en").contains("rephrase"))
    }

    /// Version hackathon (meta_only vrai en dur) : un flux Spark SIMULÉ en local n'est pas un hôte Meta — la barrière réseau
    /// le bloque AVANT l'envoi (aucune requête ne part). On vérifie donc le plafond voix et le motif nommé sans réseau,
    /// et que le serveur local ne reçoit rien. (Le parcours SSE finish_reason/refusal est testé dans la version principale.)
    func testFluxSimuleBloqueEnMetaOnlyEtPlancherVoix() throws {
        XCTAssertTrue(MetaOnly.enabled)
        XCTAssertEqual(VoixRapide.plancherSortieVoixMeta, 1024, "mode voice vers Meta : plafond de sortie relevé à 1024")
        let tok = "jeton-voixrapide-0123456789abcdef"
        let s = HTTPServer(token: tok)
        let seen = LockedBox<Int>(0)
        s.on("POST", "/api/meta-sim/api.meta.ai") { req, res in
            seen.set(seen.get() + 1)
            res.head(200, "text/event-stream")
            _ = res.chunk(Data("data: [DONE]\n\n".utf8))
        }
        let port = try s.start(port: 0)
        defer { s.stop() }
        let spec = BrainSpec(id: "spark-sim", label: "Spark simulé", kind: .chat, baseURL: "http://127.0.0.1:\(port)/api/meta-sim/api.meta.ai",
                             model: "muse-spark-1.3", keys: KeyChain([KnownKeys.sparkNova]), tags: [],
                             extraHeaders: ["x-nova-token": tok, "Host": "127.0.0.1:\(port)"])
        let runner = BrainRunner(keys: MemoryKeyStore([KnownKeys.sparkNova.service: "x"]))
        XCTAssertThrowsError(try runner.stream(spec, messages: [ChatMsg("user", "Quels risques au Burkina Faso ?")], system: nil, maxTokens: 320, mode: "voice",
                                               firstTokenTimeout: 5, cancel: { false }, onDelta: { _ in XCTFail("aucun texte attendu") }, onUsage: { _, _ in })) { e in
            let m: String = (e as? BrainFailure)?.message ?? ""
            XCTAssertTrue(m.contains("meta_only"), m)
            XCTAssertFalse(VoixRapide.relancerSiVide(m), "un blocage meta_only n'est pas une réponse vide : pas de relance")
        }
        XCTAssertEqual(seen.get(), 0, "rien n'est parti vers l'hôte non Meta")
    }

    // MARK: 6. Vocabulaire

    func testVocabulairePrioritaireEnTeteEtMotsClesMeta() {
        let eff = VoixVocab.effectif()
        for t in ["Mali", "Burkina Faso", "Niger", "Tchad", "CAFU", "OCHA", "GHO", "UNICEF", "SCI", "ONG"] {
            XCTAssertTrue(eff.prefix(VoixRapide.vocabulairePrioritaire.count + 5).contains(t), t + " en tête des contextualStrings")
        }
        XCTAssertLessThanOrEqual(eff.count, VoixVocab.limite)
        let kw = VoixRapide.motsClesMeta()
        XCTAssertTrue(kw.contains("Mali") && kw.contains("GHO") && kw.contains("Ouagadougou"))
        XCTAssertFalse(kw.contains("Ahadi"), "aucune donnée personnelle dans les mots-clés envoyés")
        XCTAssertLessThanOrEqual(kw.count, 60)
        let r = Voice.metaASRRequest(language: "fra", vocabulaire: true)
        XCTAssertEqual(r["model"] as? String, "muse-voice-transcribe-1.0")
        XCTAssertEqual(r["audioEncoding"] as? String, "WAV")
        XCTAssertEqual(r["languageBias"] as? [String], ["French"])
        XCTAssertEqual((r["keywords"] as? [String])?.first, "Mali")
        XCTAssertEqual(Voice.metaASRRequest(language: "en", vocabulaire: true)["languageBias"] as? [String], ["English"])
        XCTAssertNil(Voice.metaASRRequest(language: "auto", vocabulaire: true)["languageBias"], "auto : détection par le modèle")
        XCTAssertNil(Voice.metaASRRequest(language: "fra", vocabulaire: false)["keywords"], "relance sans vocabulaire après un 400")
    }

    // MARK: 7. Préchauffage HTTP

    func testPrechauffageAuPlusUnParIntervalle() throws {
        let s = HTTPServer(token: "jeton-voixrapide-prechauffage-01234")
        let port = try s.start(port: 0)
        defer { s.stop() }
        let saved = VoixRapide.prechauffageMeta
        VoixRapide.prechauffageMeta = URL(string: "http://127.0.0.1:\(port)/v1/models")!
        defer { VoixRapide.prechauffageMeta = saved; VoixRapide.resetPrechauffage() }
        VoixRapide.resetPrechauffage()
        XCTAssertTrue(VoixRapide.prechaufferMeta(intervalle: 20, attendre: true))
        XCTAssertFalse(VoixRapide.prechaufferMeta(intervalle: 20, attendre: true), "micro rouvert aussitôt : pas de seconde sonde")
        XCTAssertEqual(VoixRapide.prechauffages(), 1)
    }

    // MARK: 8. Barge-in : une phrase périmée ne coûte plus rien

    func testPhraseAnnuleeNeSynthetisePas() {
        let done = DispatchSemaphore(value: 0)
        var r = LocalVoiceRender()
        var ms: Double = 0
        DispatchQueue.global().async {
            let t0 = Date()
            r = LocalVoice.shared.renderDetailed(text: "Phrase d'un tour interrompu.", cancel: { true }) { _ in XCTFail("aucun son"); return false }
            ms = Date().timeIntervalSince(t0) * 1000
            done.signal()
        }
        XCTAssertEqual(done.wait(timeout: .now() + 5), .success)
        XCTAssertEqual(r.bytes, 0)
        XCTAssertFalse(r.ok)
        XCTAssertNil(r.error, "annulation : pas une panne de la voix")
        XCTAssertLessThan(ms, 50, "rendu immédiat (avant : jusqu'à 250 ms par phrase en file)")
    }

}
