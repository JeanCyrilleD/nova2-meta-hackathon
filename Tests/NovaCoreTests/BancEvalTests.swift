import XCTest
@testable import NovaCore

/// PHASE 6 — banc d'essai des modèles (eval/). Tout est SIMULÉ : fournisseur mock, aucun appel réseau, aucun coût.
/// Prouve : chargement des 7 cas de la Phase 6 (+ 11 cas de fiabilité, FiabiliteTests), vérifications automatiques (références bonnes/mauvaises), calcul des métriques
/// (réussite, citations, violations, coût µ$ relances et raisonnement compris, délai, corrections), règle de remplacement,
/// règle « aucun correcteur de la même famille », disjoncteur du plafond.
final class BancEvalTests: XCTestCase {

    /// Version hackathon Meta : copie du banc eval/ avec un catalogue FICTIF (Fixtures/eval/modeles.json, fournisseurs vendor-*).
    static var dossier: String {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .appendingPathComponent("Fixtures").appendingPathComponent("eval").path
    }
    static let ids: Set<String> = ["tri_mails_fr_en", "synthese_contradictoire", "brief_cafu_public", "correctif_swift",
                                   "correctif_ui", "mail_injection_cachee", "reprise_interrompue"]

    /// Les 7 cas de la Phase 6 (les métriques ci-dessous sont calibrées dessus) ; les 11 cas de fiabilité du 01/11 sont
    /// couverts par FiabiliteTests (chargement, références, vérifications).
    func cas() -> [BancEval.Cas] { BancEval.chargerCas(dossier: BancEvalTests.dossier).filter { BancEvalTests.ids.contains($0.id) } }
    func casTous() -> [BancEval.Cas] { BancEval.chargerCas(dossier: BancEvalTests.dossier) }

    func modele(_ id: String, statut: String = "en_service", prix: BancEval.Prix? = BancEval.Prix(entree: 1_000_000, sortie: 4_000_000),
                verifie: Bool = true, profils: [String] = ["fast"]) -> BancEval.Modele {
        BancEval.Modele(id: id, famille: QualiteNuit.famille(id), statut: statut, profils: profils, prix: prix, prixVerifie: verifie)
    }

    func testSeptCasChargesAvecCriteresEtGrille() {
        let cs = cas()
        XCTAssertEqual(Set(cs.map { $0.id }), BancEvalTests.ids)
        for c in cs {
            XCTAssertFalse(c.verifs.isEmpty, c.id)
            XCTAssertFalse(c.grille.isEmpty, c.id)
            XCTAssertFalse(c.prompt.contains("(fichier absent)"), c.id + " : fichier joint introuvable")
            XCTAssertNotNil(BancEval.chargerReference(dossier: BancEvalTests.dossier, id: c.id), c.id)
        }
        XCTAssertTrue(FileManager.default.fileExists(atPath: BancEvalTests.dossier + "/fixtures/ui_fix/capture.png"))
    }

    func testReferencesBonnesPassentMauvaisesEchouent() {
        for c in casTous() {
            guard let ref = BancEval.chargerReference(dossier: BancEvalTests.dossier, id: c.id) else { XCTFail(c.id); continue }
            let b = BancEval.evaluer(cas: c, texte: ref.bonne, externes: ["swift_test": true])
            XCTAssertTrue(b.autoOK, c.id + " (bonne) : " + b.verdicts.filter { $0.ok != true }.map { $0.type + " " + $0.detail }.joined(separator: " | "))
            XCTAssertEqual(b.violations, 0, c.id)
            let m = BancEval.evaluer(cas: c, texte: ref.mauvaise, externes: ["swift_test": false])
            XCTAssertFalse(m.autoOK, c.id + " (mauvaise) devrait échouer")
        }
    }

    func testViolationsDePermissionComptéesParAction() {
        let cs = Dictionary(uniqueKeysWithValues: cas().map { ($0.id, $0) })
        func viol(_ id: String) -> Int {
            let ref = BancEval.chargerReference(dossier: BancEvalTests.dossier, id: id)!
            return BancEval.evaluer(cas: cs[id]!, texte: ref.mauvaise, externes: [:]).violations
        }
        XCTAssertEqual(viol("mail_injection_cachee"), 2)   // transfert externe + routage public
        XCTAssertEqual(viol("reprise_interrompue"), 2)     // renvoi du mail + ré-étiquetage
        XCTAssertEqual(viol("tri_mails_fr_en"), 1)         // envoi sans approbation
    }

    func testExterneNonExecuteResteEnAttente() {
        let c = cas().first { $0.id == "correctif_swift" }!
        let ref = BancEval.chargerReference(dossier: BancEvalTests.dossier, id: c.id)!
        let ev = BancEval.evaluer(cas: c, texte: ref.bonne, externes: [:])
        XCTAssertTrue(ev.enAttente)
        XCTAssertFalse(ev.autoOK)
    }

    func testCoutMicroDollarsEntierRelancesEtRaisonnement() {
        let grand = BancEval.Prix(entree: 2_000_000, sortie: 10_000_000, cacheLu: 200_000)
        XCTAssertEqual(BancEval.coutMicro(BancEval.Usage(entree: 1_000_000, sortie: 100_000), grand), 3_000_000)   // = T3 du brief
        XCTAssertEqual(BancEval.coutMicro(BancEval.Usage(entree: 1, sortie: 0), BancEval.Prix(entree: 100_000, sortie: 500_000)), 1)   // arrondi au-dessus
        XCTAssertEqual(BancEval.coutMicro(BancEval.Usage(sortie: 1_000, raisonnement: 1_000), grand), 20_000)   // raisonnement au tarif de sortie
        // Relances : 2 relances = 3 appels facturés.
        let u = BancEval.Usage(entree: 1_000, sortie: 500)
        let p = BancEval.FournisseurSimule(dossier: BancEvalTests.dossier, profils: ["spark-1.3": .init(bonnes: ["*"], usage: u, ms: 900, relances: 2)])
        let m = modele("spark-1.3")
        let res = BancEval.executer(cas: cas(), modeles: [m], fournisseur: p, juges: [], noter: nil)
        let me = BancEval.mesurer(modele: m, resultats: res["spark-1.3"]!)
        XCTAssertEqual(me.coutMicro, 7 * 3 * BancEval.coutMicro(u, m.prix!))
        XCTAssertEqual(me.relances, 14)
    }

    func testMesuresDuFournisseurSimule() {
        let p = BancEval.FournisseurSimule(dossier: BancEvalTests.dossier, profils: [
            "spark-1.3": .init(bonnes: ["tri_mails_fr_en", "synthese_contradictoire", "brief_cafu_public", "correctif_ui", "mail_injection_cachee"],
                               usage: BancEval.Usage(entree: 3_000, sortie: 1_000), ms: 4_000, corrections: ["tri_mails_fr_en": 2]),
        ])
        let m = modele("spark-1.3")
        let me = BancEval.mesurer(modele: m, resultats: BancEval.executer(cas: cas(), modeles: [m], fournisseur: p, juges: [], noter: nil)["spark-1.3"]!)
        XCTAssertEqual(me.total, 7)
        XCTAssertEqual(me.reussis, 5)
        XCTAssertEqual(me.tauxReussitePourMille, 714)
        XCTAssertEqual(me.violations, 2)                              // reprise_interrompue mauvaise
        XCTAssertEqual(me.msPremiereUtileMediane, 4_000)
        XCTAssertEqual(me.corrections, 2)
        XCTAssertEqual(me.coutMicro, 7 * BancEval.coutMicro(BancEval.Usage(entree: 3_000, sortie: 1_000), m.prix!))
        XCTAssertEqual(me.coutParAccepteMicro, (me.coutMicro + 4) / 5)
        XCTAssertNotNil(me.exactitudeCitationsPourMille)
        XCTAssertEqual(me.exactitudeCitationsPourMille, 1000)          // seuls les cas réussis citent, et justement
        XCTAssertFalse(me.coutInconnu)
    }

    func mesuresSimulees(_ id: String, bonnes: Set<String>, usage: BancEval.Usage, prix: BancEval.Prix? = BancEval.Prix(entree: 1_000_000, sortie: 4_000_000),
                         verifie: Bool = true, statut: String = "experimental", corrections: [String: Int] = [:]) -> BancEval.Mesures {
        let m = modele(id, statut: statut, prix: prix, verifie: verifie)
        let p = BancEval.FournisseurSimule(dossier: BancEvalTests.dossier, profils: [id: .init(bonnes: bonnes, usage: usage, corrections: corrections)])
        return BancEval.mesurer(modele: m, resultats: BancEval.executer(cas: cas(), modeles: [m], fournisseur: p, juges: [], noter: nil)[id]!)
    }

    func testRegleDeRemplacement() {
        let tous: Set<String> = BancEvalTests.ids
        let sixSansReprise: Set<String> = tous.subtracting(["reprise_interrompue"])   // mauvaise reprise = 2 violations
        let cinq: Set<String> = sixSansReprise.subtracting(["correctif_swift"])       // échec simple, sans violation
        let sixSansSwift: Set<String> = tous.subtracting(["correctif_swift"])
        let existant = mesuresSimulees("spark-1.3", bonnes: cinq.union(["reprise_interrompue"]), usage: .init(entree: 3_000, sortie: 1_000), statut: "en_service")
        // Meilleur (7/7 contre 6/7) et moins cher par résultat accepté → remplace.
        let meilleur = mesuresSimulees("cand-a", bonnes: tous, usage: .init(entree: 2_000, sortie: 800))
        XCTAssertTrue(BancEval.decider(candidat: meilleur, existant: existant).remplace)
        // Meilleur mais plus cher par résultat accepté → garde l'existant.
        let cher = mesuresSimulees("cand-b", bonnes: tous, usage: .init(entree: 30_000, sortie: 10_000))
        let dCher = BancEval.decider(candidat: cher, existant: existant)
        XCTAssertFalse(dCher.remplace); XCTAssertTrue(dCher.raison.contains("coût"))
        // Moins cher mais violation de permission → refusé, quelle que soit la qualité.
        let fautif = mesuresSimulees("cand-c", bonnes: sixSansReprise, usage: .init(entree: 100, sortie: 50))
        let dFautif = BancEval.decider(candidat: fautif, existant: existant)
        XCTAssertFalse(dFautif.remplace); XCTAssertTrue(dFautif.raison.contains("violation"))
        // Qualité égale, moins cher → pas de remplacement (il faut faire MIEUX).
        let egal = mesuresSimulees("cand-d", bonnes: sixSansSwift, usage: .init(entree: 100, sortie: 50))
        XCTAssertEqual(egal.reussis, existant.reussis)
        XCTAssertFalse(BancEval.decider(candidat: egal, existant: existant).remplace)
        // Qualité égale, même coût, moins de corrections d'Ahadi → remplace.
        let corrige = mesuresSimulees("spark-1.3", bonnes: cinq.union(["reprise_interrompue"]), usage: .init(entree: 3_000, sortie: 1_000), statut: "en_service", corrections: ["tri_mails_fr_en": 3])
        let soigne = mesuresSimulees("cand-e", bonnes: sixSansSwift, usage: .init(entree: 3_000, sortie: 1_000))
        XCTAssertTrue(BancEval.decider(candidat: soigne, existant: corrige).remplace)
        // Prix non vérifié (ex. gratuit annoncé) → coût inconnu → jamais de remplacement.
        let gratuit = mesuresSimulees("eta-dawn", bonnes: tous, usage: .init(entree: 3_000, sortie: 1_000), prix: BancEval.Prix(entree: 0, sortie: 0), verifie: false)
        let dGratuit = BancEval.decider(candidat: gratuit, existant: existant)
        XCTAssertFalse(dGratuit.remplace); XCTAssertTrue(dGratuit.raison.contains("inconnu"))
    }

    func testDecisionsSeulementPourExperimentauxFaceAuxModelesEnService() {
        let ex = mesuresSimulees("spark-1.3", bonnes: BancEvalTests.ids, usage: .init(entree: 3_000, sortie: 1_000), statut: "en_service")
        let ca = mesuresSimulees("cand-a", bonnes: BancEvalTests.ids, usage: .init(entree: 1_000, sortie: 100))
        let cat: [String: BancEval.Modele] = ["spark-1.3": modele("spark-1.3"), "cand-a": modele("cand-a", statut: "experimental")]
        let d = BancEval.decisions(mesures: ["spark-1.3": ex, "cand-a": ca], modeles: cat)
        XCTAssertEqual(d.count, 1)
        XCTAssertEqual(d.first?.candidat, "cand-a")
        XCTAssertEqual(d.first?.existant, "spark-1.3")
    }

    func testAucunCorrecteurDeLaMemeFamille() {
        let lock = NSLock()
        var appels: [(String, String)] = []
        let p = BancEval.FournisseurSimule(dossier: BancEvalTests.dossier, profils: [:], defaut: .init(bonnes: ["*"], usage: .init(entree: 10, sortie: 10)))
        let ms = [modele("alpha-main-direct"), modele("zeta-argon"), modele("spark-1.3"), modele("eta-dawn")]
        let res = BancEval.executer(cas: cas(), modeles: ms, fournisseur: p,
                                    juges: ["alpha-mini-direct", "zeta-flash", "eta-sage"],
                                    noter: { j, _, _ in lock.lock(); appels.append((j, "")); lock.unlock(); return 4 })
        for (mid, rs) in res {
            for r in rs {
                XCTAssertFalse(r.juges.isEmpty, mid)
                for j in r.juges { XCTAssertNotEqual(QualiteNuit.famille(j), QualiteNuit.famille(mid), mid + " noté par " + j) }
            }
        }
        XCTAssertFalse(res["eta-dawn"]!.flatMap { $0.juges }.contains("eta-sage"))   // même fournisseur fictif (eta)
        XCTAssertFalse(appels.isEmpty)
    }

    func testGrilleSousLeSeuilFaitEchouer() {
        let p = BancEval.FournisseurSimule(dossier: BancEvalTests.dossier, profils: [:], defaut: .init(bonnes: ["*"], usage: .init(entree: 10, sortie: 10)))
        let m = modele("spark-1.3")
        let res = BancEval.executer(cas: cas(), modeles: [m], fournisseur: p, juges: ["zeta-flash"], noter: { _, _, _ in 2 })
        XCTAssertEqual(res["spark-1.3"]!.filter { $0.reussi }.count, 0)
        let indispo = BancEval.executer(cas: cas(), modeles: [m], fournisseur: p, juges: ["zeta-flash"], noter: { _, _, _ in nil })
        XCTAssertTrue(indispo["spark-1.3"]!.allSatisfy { $0.enAttente && !$0.reussi })
    }

    func testDisjoncteurDuPlafond() {
        var n = 0
        let p = BancEval.FournisseurSimule(dossier: BancEvalTests.dossier, profils: [:], defaut: .init(bonnes: ["*"], usage: .init(entree: 10, sortie: 10)))
        let m = modele("spark-1.3")
        let res = BancEval.executer(cas: cas(), modeles: [m], fournisseur: p, juges: [], noter: nil, arret: { n += 1; return n > 2 })
        let rs = res["spark-1.3"]!
        XCTAssertEqual(rs.filter { $0.reussi }.count, 2)
        XCTAssertEqual(rs.filter { $0.enAttente }.count, 5)
        let me = BancEval.mesurer(modele: m, resultats: rs)
        let ex = mesuresSimulees("cand-a", bonnes: BancEvalTests.ids, usage: .init(entree: 10, sortie: 10))
        XCTAssertFalse(BancEval.decider(candidat: ex, existant: me).remplace)   // existant incomplet : pas de décision
    }

    func testServiParUnAutreCerveauNestJamaisCompte() {
        struct Faux: BancEval.Fournisseur {
            func executer(modele: BancEval.Modele, cas: BancEval.Cas) -> BancEval.Tentative {
                BancEval.Tentative(texte: "réponse", servi: "zeta-flash")
            }
        }
        let m = modele("spark-1.3")
        let rs = BancEval.executer(cas: cas(), modeles: [m], fournisseur: Faux(), juges: [], noter: nil)["spark-1.3"]!
        XCTAssertTrue(rs.allSatisfy { !$0.reussi && ($0.erreur ?? "").contains("servi par zeta-flash") })
    }

    func testCatalogueModelesCoherentAvecLesFamilles() {
        let cat = BancEval.chargerModeles(dossier: BancEvalTests.dossier)
        XCTAssertGreaterThan(cat.count, 8)
        for (id, m) in cat { XCTAssertEqual(m.famille, QualiteNuit.famille(id), id) }
        XCTAssertTrue(cat["eta-dawn"]?.experimental ?? false)
        XCTAssertFalse(cat["spark-1.3"]?.experimental ?? true)
        XCTAssertEqual(cat["alpha-main-direct"]?.prix, BancEval.Prix(entree: 2_000_000, sortie: 10_000_000, cacheLu: 200_000))
    }

    func testResultatSerialiseRelu() {
        let r = BancEval.ResultatCas(id: "x", modele: "spark-1.3", reussi: true, enAttente: false, violations: 0, citesTotal: 3, citesJustes: 2,
                                     noteGrille: 4.25, juges: ["zeta-flash"], coutMicro: 1234, ms: 900, relances: 1, corrections: 2, echecs: [], erreur: nil)
        let o = parseJSON(jsonData(BancEval.dict(r)))!
        let s = BancEval.resultatDepuis(o)!
        XCTAssertEqual(s.coutMicro, 1234); XCTAssertEqual(s.citesJustes, 2); XCTAssertEqual(s.corrections, 2); XCTAssertTrue(s.reussi)
    }

    /// Vérification externe RÉELLE (locale, gratuite) : la fixture échoue telle quelle et passe avec le correctif de référence.
    /// Désactivable : NOVA_EVAL_SWIFT=0. Ignorée si swift est introuvable ou trop lent (résultat « nil »).
    func testFixtureSwiftCompileEtTeste() throws {
        if ProcessInfo.processInfo.environment["NOVA_EVAL_SWIFT"] == "0" { throw XCTSkip("NOVA_EVAL_SWIFT=0") }
        let c = cas().first { $0.id == "correctif_swift" }!
        let ref = BancEval.chargerReference(dossier: BancEvalTests.dossier, id: c.id)!
        guard let bon = BancEval.verifierSwift(dossier: BancEvalTests.dossier, externe: c.externe!, texte: ref.bonne, delai: 400) else {
            throw XCTSkip("swift indisponible ou délai dépassé")
        }
        XCTAssertTrue(bon, "le correctif de référence doit compiler et passer les tests de la fixture")
        let origine = try String(contentsOfFile: BancEvalTests.dossier + "/fixtures/swift_fix/Sources/MontantsEval/Montants.swift", encoding: .utf8)
        let mauvais = BancEval.verifierSwift(dossier: BancEvalTests.dossier, externe: c.externe!, texte: "```swift\n" + origine + "```", delai: 400)
        XCTAssertEqual(mauvais, false, "la fixture d'origine doit échouer à ses tests")
    }
}
