import Foundation
import NovaFoundation

// 29/10 (Ahadi : « je veux voir chaque matin si la qualité de Nova progresse ») — BANC QUALITÉ DE NUIT.
// Chaque nuit à 03:10 (heure du Mac), 10 tâches FIXES et FICTIVES, représentatives du travail d'Ahadi, sont soumises
// au cerveau principal des Réglages (comme une vraie demande d'Ahadi : drapeau interactif posé sur ce fil, sinon la
// politique de dépense retirerait [tiers] de la chaîne). [tiers] note ensuite chaque réponse (exactitude, complétude,
// forme CAFU, concision) d'après un « attendu » court. Aucun outil, aucun envoi, aucune donnée réelle d'Ahadi.
// Déclenchement manuel immédiat : fichier ~/spark-local/Nova2/dormant/QUALITE_REQUEST (supprimé avant le banc).
// Résultats : releves/diag/qualite_nuit.json (dernier banc complet) + une ligne par banc dans releves/diag/qualite_nuit.jsonl.
// Coût : ≤ 20 appels de cerveau par banc (10 réponses + 10 notations) ; il est compté automatiquement par LLMSpend
// (releves/diag/depenses.json). Banc sauté si le budget du mois est atteint.
public enum QualiteNuit {
    nonisolated(unsafe) static var started: Bool = false   // PHASE 1 (relu, protégé) : sous lock (démarrage unique)
    static let lock: NSLock = NSLock()
    static let etat: JSONFile = JSONFile("qualite_nuit_etat.json")

    struct Tache: Sendable {
        let id: String
        let prompt: String
        let attendu: String
    }

    static var root: String { NSHomeDirectory() + "/spark-local/Nova2" }
    static var outPath: String { root + "/releves/diag/qualite_nuit.json" }
    static var logPath: String { root + "/releves/diag/qualite_nuit.jsonl" }
    static var reqPath: String { root + "/dormant/QUALITE_REQUEST" }

    public static func start(router: Router) {
        lock.lock(); if started { lock.unlock(); return }; started = true; lock.unlock()
        Thread.detachNewThread {
            Thread.sleep(forTimeInterval: 60)
            while true {
                QualiteNuit.tick(router: router)
                Thread.sleep(forTimeInterval: 60)
            }
        }
    }

    static func dayKey(_ d: Date) -> String {
        let f: DateFormatter = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd"
        return f.string(from: d)
    }

    static func tick(router: Router) {
        // 1) Demande manuelle (essai du soir) : le fichier est supprimé AVANT le banc, pour ne jamais boucler.
        if FileManager.default.fileExists(atPath: reqPath) {
            // 31/10 (Ahadi : « test d'abord ») — banc COMPARATIF : « cerveaux=a,b » (chacun en solo, sans relais) et
            // « correcteurs=x,y,z » (notes moyennées entre correcteurs de familles différentes, pour éviter qu'un modèle note
            // sa propre famille). Un fichier vide garde le banc habituel.
            let txt: String = (try? String(contentsOfFile: reqPath, encoding: .utf8)) ?? ""
            try? FileManager.default.removeItem(atPath: reqPath)
            var brains: [String] = [], judges: [String] = []
            for l in txt.components(separatedBy: .newlines) {
                let p = l.split(separator: "=", maxSplits: 1).map { $0.trimmingCharacters(in: .whitespaces) }
                guard p.count == 2 else { continue }
                let v: [String] = p[1].split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
                if p[0] == "cerveaux" { brains = v } else if p[0] == "correcteurs" { judges = v }
            }
            if brains.isEmpty && !txt.contains("taches=eval") { run(router: router, declencheur: "manuel"); return }   // Phase 6 : eval_recalcul sans cerveau
            comparatif(router: router, brains: brains, judges: judges, cfg: txt)
            return
        }
        // 2) Banc de nuit : une fois par jour, entre 03:10 et 06:00 (rattrapage si le Mac dormait à 03:10).
        let now: Date = Date()
        let comps: DateComponents = Calendar.current.dateComponents([.hour, .minute], from: now)
        let h: Int = comps.hour ?? 0
        let m: Int = comps.minute ?? 0
        let minutes: Int = h * 60 + m
        guard minutes >= 3 * 60 + 10, minutes < 6 * 60 else { return }
        // 30/10 (GO 1, dépense) : HEBDOMADAIRE — la nuit du samedi au dimanche seulement (≈ 0,40 $ par passage).
        guard Calendar.current.component(.weekday, from: now) == 1 else { return }
        guard Settings().get("banc_hebdo", false) else { return }   // 31/10 04:11 : banc automatique coupé (dépense) — réactivable par le réglage banc_hebdo
        let today: String = dayKey(now)
        let st: [String: String] = etat.read(default: [String: String]())
        if (st["dernier_jour"] ?? "") == today { return }
        // Jour marqué AVANT le banc : un échec ne relance pas le banc toutes les minutes.
        var st2: [String: String] = st
        st2["dernier_jour"] = today
        st2["dernier_depart"] = nowISO()
        etat.write(st2)
        run(router: router, declencheur: "nuit")
    }

    // MARK: - Tâches fixes (contenu FICTIF, d'exercice)

    static let taches: [Tache] = [
        Tache(id: "note_cafu_securite",
              prompt: """
              Exercice (données fictives). Rédige une note CAFU courte pour la direction pays à partir de ces éléments :
              - 24/10/2026 : attaque d'un groupe armé non étatique contre le marché de Kouri-Sud (commune fictive, région du Centre-Nord) ; 9 civils tués selon la mairie (communiqué du 25/10).
              - 26/10/2026 : 1 840 personnes arrivées à Kaya selon le registre du service de l'action sociale (fiche du 27/10).
              - 27/10/2026 : l'axe Kaya–Kouri-Sud est fermé aux ONG par les autorités (message radio du gouvernorat, non publié).
              - Rumeur non confirmée (WhatsApp, 28/10) : d'autres villages menacés.
              Nos équipes prévoyaient une distribution de kits d'hygiène à Kouri-Sud le 05/11.
              """,
              attendu: "BLUF en 1-2 phrases en tête ; faits datés avec leur source ; distinction confirmé / rumeur ; implications pour la distribution du 05/11 et pour l'accueil à Kaya ; points à vérifier ; pas d'invention de chiffres."),
        Tache(id: "analyse_deplacements",
              prompt: """
              Exercice (données fictives). Voici des chiffres de personnes déplacées internes (PDI) pour trois communes du Sahel burkinabè, d'après un tableau de suivi fictif du CONASUR :
              - Commune A : 12 400 PDI au 30/06/2026, 15 900 au 30/09/2026.
              - Commune B : 8 100 au 30/06/2026, 7 600 au 30/09/2026.
              - Commune C : 3 050 au 30/06/2026, 5 490 au 30/09/2026.
              Analyse l'évolution en format CAFU (BLUF, faits, implications pour la programmation éducation et protection de l'enfance, points à vérifier).
              """,
              attendu: "Variations correctes : A +3 500 (+28 %), B −500 (−6 %), C +2 440 (+80 %) ; total 23 550 → 28 990 (+5 440, +23 %) ; BLUF en tête ; implications concrètes éducation/protection ; points à vérifier (méthode de comptage, retours, doubles comptes)."),
        Tache(id: "brvm_portefeuille",
              prompt: """
              Exercice (titres et cours FICTIFS). Un portefeuille d'exemple :
              - TITRE A (fictif) : 10 actions achetées à 10 000 FCFA, cours actuel 12 000 FCFA.
              - TITRE B (fictif) : 10 actions achetées à 5 000 FCFA, cours actuel 4 500 FCFA.
              - TITRE C (fictif) : 20 actions achetées à 2 000 FCFA, cours actuel 2 500 FCFA.
              Calcule la valeur actuelle de chaque ligne et du total, la plus-value ou moins-value par ligne et totale (en FCFA et en %), le poids de chaque ligne, et donne un point d'attention.
              """,
              attendu: "Valeurs 120 000 / 45 000 / 50 000 = 215 000 FCFA ; coût 190 000 ; +20 000 (+20 %), −5 000 (−10 %), +10 000 (+25 %) ; total +25 000 (+13,2 %) ; poids ≈ 55,8 % / 20,9 % / 23,3 % ; un point d'attention pertinent (concentration sur le titre A) sans conseil péremptoire."),
        Tache(id: "tri_mails",
              prompt: """
              Exercice (mails fictifs). Trie ces mails reçus ce matin par priorité (urgent / aujourd'hui / cette semaine / à archiver) et propose l'action pour chacun en une ligne :
              1. Coordinateur sécurité : « Couvre-feu avancé à 19 h à Dori dès ce soir, confirmez les mouvements d'équipe avant 14 h. »
              2. Newsletter d'un think tank sur le Sahel.
              3. Bailleur : « Pouvez-vous envoyer le rapport intermédiaire révisé d'ici vendredi ? »
              4. RH : rappel de la formation obligatoire en ligne, échéance le 30/11.
              5. Collègue : « On décale notre point de 15 h à demain même heure ? »
              6. Finance : « Il manque 3 justificatifs sur ta note de frais d'octobre, sinon le remboursement est bloqué à la clôture de jeudi. »
              """,
              attendu: "Mail 1 urgent (action avant 14 h) ; 6 aujourd'hui ou avant jeudi ; 3 cette semaine (vendredi) ; 5 réponse rapide aujourd'hui ; 4 cette semaine ou plus tard ; 2 à archiver ; une action concrète par mail ; format compact."),
        Tache(id: "prep_reunion",
              prompt: """
              Exercice (contexte fictif). Prépare-moi en 10 minutes pour une réunion demain à 9 h avec le cluster Protection (Ouagadougou) : ordre du jour = (1) hausse des incidents de protection de l'enfance signalés à Djibo (+35 % entre août et septembre selon notre base interne), (2) partage des zones de couverture entre ONG, (3) prochain rapport mensuel. Je représente notre organisation.
              """,
              attendu: "Objectif de la réunion ; 3 messages clés à porter ; questions à poser par point ; données à apporter et limites du +35 % (base interne, sous-déclaration) ; risques/points sensibles ; suivi après réunion ; format court et actionnable."),
        Tache(id: "calcul_couts",
              prompt: """
              Exercice (chiffres fictifs). Calcule le coût total d'une distribution : 1 250 kits d'hygiène à 8 750 FCFA l'unité, 4 camions de transport à 185 000 FCFA chacun, et des frais de distribution de 6 % appliqués sur le total kits + transport. Donne le total en FCFA, l'équivalent en USD à 1 USD = 600 FCFA, et le coût complet par kit.
              """,
              attendu: "Kits 10 937 500 ; transport 740 000 ; sous-total 11 677 500 ; frais 6 % = 700 650 ; total 12 378 150 FCFA ; ≈ 20 630 USD ; ≈ 9 903 FCFA par kit ; calcul détaillé et lisible."),
        Tache(id: "reecriture_bailleur",
              prompt: """
              Exercice (texte fictif). Réécris ce paragraphe pour un rapport au bailleur, ton professionnel, factuel, 90 mots maximum :
              « Bon, on a pas mal galéré ce trimestre à cause de l'insécurité, plein d'activités ont sauté, mais on a quand même fait des trucs bien, genre 2 300 enfants qui ont eu des kits scolaires et les espaces amis des enfants qui tournent à Kaya et Dori, même si à Djibo c'est toujours fermé depuis août. »
              """,
              attendu: "Ton professionnel et factuel ; ≤ 90 mots ; conserve 2 300 enfants, kits scolaires, espaces amis des enfants à Kaya et Dori, Djibo fermé depuis août, cause sécuritaire ; aucun chiffre ajouté ; pas de familiarités."),
        Tache(id: "question_factuelle",
              prompt: "Quelle est la capitale du Burkina Faso, quelle monnaie y circule et quelle est sa parité fixe avec l'euro ? Réponds brièvement.",
              attendu: "Ouagadougou ; franc CFA (XOF, UEMOA / BCEAO) ; 1 euro = 655,957 FCFA ; réponse brève (2-3 lignes)."),
        Tache(id: "email_anglais",
              prompt: """
              Exercise (fictional). Write a short reply in English to this email from a donor programme officer: "Dear team, could you confirm whether the school kit distribution in Dori will still take place on 12 November, given the new curfew? We would also appreciate an updated beneficiary figure." Facts: the distribution is moved to 14 November (daytime only), updated figure is 1 150 children (previously 1 300) because one site is inaccessible.
              """,
              attendu: "En anglais ; court (≤ 120 mots) ; confirme le report au 14 novembre (journée) ; donne 1 150 enfants (contre 1 300) et la raison (un site inaccessible) ; ton courtois et professionnel ; formule de clôture."),
        Tache(id: "plan_semaine",
              prompt: """
              Exercice (agenda fictif). Fais-moi un plan de semaine (lundi à vendredi) réaliste avec ces contraintes : rapport intermédiaire au bailleur à rendre vendredi 12 h ; réunion cluster Protection mardi 9 h ; mission terrain à Kaya mercredi (départ 6 h, retour 18 h) ; 3 notes CAFU hebdomadaires à produire (une par jour ouvré hors mercredi suffit) ; suivi de mon portefeuille BRVM 15 minutes par semaine.
              """,
              attendu: "Plan jour par jour lundi→vendredi ; rapport avancé avant vendredi avec relecture jeudi ; mardi 9 h cluster ; mercredi bloqué terrain ; 3 notes CAFU placées hors mercredi ; 15 min BRVM placées ; marges pour imprévus ; format lisible.")
    ]

    // MARK: - Notation ([tiers])

    static let graderSys: String = """
    Tu es le correcteur du banc qualité de Nova, l'assistant d'Ahadi (analyste humanitaire au Burkina Faso, standards de note CAFU).
    On te donne une TÂCHE, l'ATTENDU (ce qu'une bonne réponse doit contenir) et la RÉPONSE de Nova.
    Note de 1 à 5, avec sévérité :
    - exactitude : chiffres, calculs, faits justes ; aucune invention ;
    - completude : tous les éléments de l'ATTENDU sont présents ;
    - forme : format adapté à la tâche ; pour une note ou une analyse, règles CAFU : BLUF en tête, faits datés et sourcés, implications, points à vérifier ;
    - concision : pas de remplissage, longueur adaptée.
    Réponds UNIQUEMENT par un objet JSON, sans texte autour :
    {"exactitude":n,"completude":n,"forme":n,"concision":n,"commentaire":"20 mots maximum"}
    """

    static func clamp(_ v: Int) -> Int { max(1, min(5, v)) }

    static func grade(router: Router, t: Tache, answer: String, judge: String = "wonder-1.0") -> [String: Any]? {
        var user: String = "TÂCHE :\n" + t.prompt
        user += "\n\nATTENDU :\n" + t.attendu
        user += "\n\nRÉPONSE :\n" + String(answer.prefix(12000))
        let det: (result: (text: String, brain: String)?, error: String?) = router.completeDetailed(
            messages: [ChatMsg("user", user)], system: graderSys, mode: "bulk",
            preferred: judge, maxTokens: 3000, deadline: 90, solo: true)   // 31/10 : Argon/[tiers] réfléchissent avant de répondre — 400 jetons n'y suffisaient pas (notes vides)
        guard let txt: String = det.result?.text, let a = txt.firstIndex(of: "{"), let b = txt.lastIndex(of: "}"), a < b,
              let o: [String: Any] = parseJSON(Data(String(txt[a...b]).utf8)) else { return nil }
        func n(_ k: String) -> Int {
            if let i = o[k] as? Int { return clamp(i) }
            if let d = o[k] as? Double { return clamp(Int(d.rounded())) }
            if let s = o[k] as? String, let i = Int(s) { return clamp(i) }
            return 1
        }
        let com: String = String(((o["commentaire"] as? String) ?? "").prefix(200))
        let g: [String: Any] = ["exactitude": n("exactitude"), "completude": n("completude"), "forme": n("forme"),
                                "concision": n("concision"), "commentaire": com, "correcteur": det.result?.brain ?? ""]
        return g
    }

    // MARK: - Banc

    static func ensureDirs() {
        try? FileManager.default.createDirectory(atPath: root + "/releves/diag", withIntermediateDirectories: true)
    }

    static func appendLog(_ row: [String: Any]) {
        ensureDirs()
        let d: Data = jsonData(row)
        guard let line = String(data: d, encoding: .utf8) else { return }
        if let h = FileHandle(forWritingAtPath: logPath) { h.seekToEndOfFile(); h.write(Data((line + "\n").utf8)); h.closeFile() }
        else { try? Data((line + "\n").utf8).write(to: URL(fileURLWithPath: logPath)) }
    }

    static func r2(_ x: Double) -> Double { (x * 100).rounded() / 100 }

    /// 31/10 (Ahadi : « même éval sur d'autres cerveaux, tests couvrant tout ce que Nova fait, avec contre-corrections »).
    /// BANC COMPARATIF : chaque cerveau dans son propre fil (en parallèle), chacun en solo (sans relais), noté par tous les
    /// correcteurs SAUF ceux de sa famille. Disjoncteur : le banc s'arrête si sa dépense du jour dépasse « plafond_usd »
    /// (6 $ par défaut). Synthèse côte à côte : releves/diag/qualite_comparatif.json.
    static func comparatif(router: Router, brains: [String], judges: [String], cfg: String) {
        var etendu: Bool = false
        var cap: Double = 6
        var evalCas: String = ""      // Phase 6 : « taches=eval » (banc eval/) ou « taches=eval_recalcul » (zéro appel)
        var simule: Bool = false      // Phase 6 : « simule=1 » = fournisseur simulé, aucun appel de modèle
        for l in cfg.components(separatedBy: .newlines) {
            let p = l.split(separator: "=", maxSplits: 1).map { $0.trimmingCharacters(in: .whitespaces) }
            guard p.count == 2 else { continue }
            if p[0] == "taches" { etendu = p[1] == "etendues"; if p[1].hasPrefix("eval") { evalCas = p[1] } }
            if p[0] == "plafond_usd", let v = Double(p[1].replacingOccurrences(of: ",", with: ".")) { cap = v }
            if p[0] == "simule" { simule = p[1] == "1" || p[1] == "oui" }
        }
        if evalCas == "eval_recalcul" { BancEval.recalculer(); return }
        if evalCas == "eval" { BancEval.lancer(router: router, brains: brains, judges: judges, plafondUSD: cap, simule: simule); return }
        let tasks: [Tache] = etendu ? taches + tachesEtendues : taches
        let js: [String] = judges.isEmpty ? ["wonder-1.0"] : judges
        let started0: String = nowISO()
        let b0 = LLMSpend.benchToday()
        let stop: Double = b0.usd + cap
        let group: DispatchGroup = DispatchGroup()
        for b in brains {
            let own: [String] = js.filter { famille($0) != famille(b) }
            group.enter()
            Thread.detachNewThread {
                QualiteNuit.run(router: router, declencheur: "comparatif", brain: b, judges: own.isEmpty ? js : own,
                                out: QualiteNuit.root + "/releves/diag/qualite_" + b + ".json", tasks: tasks, stopAt: stop)
                group.leave()
            }
        }
        group.wait()
        let b1 = LLMSpend.benchToday()
        var lignes: [[String: Any]] = []
        var matrice: [String: [String: Double]] = [:]   // correcteur → cerveau → moyenne
        for b in brains {
            let path: String = root + "/releves/diag/qualite_" + b + ".json"
            guard let d = try? Data(contentsOf: URL(fileURLWithPath: path)), let o = parseJSON(d) else { continue }
            var l: [String: Any] = ["cerveau": b, "famille": famille(b)]
            l["moyennes"] = o["moyennes"] ?? NSNull()
            l["ok"] = o["ok"] ?? 0; l["echecs"] = o["echecs"] ?? 0; l["total"] = o["total"] ?? 0
            l["arret"] = o["arret"] ?? NSNull()
            l["cerveaux_servis"] = o["cerveaux_servis"] ?? []
            l["usd_jour_modele"] = r2((b1.perBrain[b] ?? 0) - (b0.perBrain[b] ?? 0))
            var parTache: [String: Double] = [:]
            for t in (o["taches"] as? [[String: Any]]) ?? [] {
                if let id = t["id"] as? String, let n = num(t["note"]) { parTache[id] = n }
                for g in (t["notes_par_correcteur"] as? [[String: Any]]) ?? [] {
                    let j: String = (g["correcteur"] as? String) ?? "?"
                    let v: Double = Double(((g["exactitude"] as? Int) ?? 1) + ((g["completude"] as? Int) ?? 1) + ((g["forme"] as? Int) ?? 1) + ((g["concision"] as? Int) ?? 1)) / 4
                    var m: [String: Double] = matrice[j] ?? [:]
                    m[b + "#n"] = (m[b + "#n"] ?? 0) + 1
                    m[b] = (m[b] ?? 0) + v
                    matrice[j] = m
                }
            }
            l["notes_par_tache"] = parTache
            lignes.append(l)
        }
        var mat: [String: [String: Double]] = [:]
        for (j, m) in matrice {
            var r: [String: Double] = [:]
            for (k, v) in m where !k.hasSuffix("#n") { r[k] = r2(v / max(1, m[k + "#n"] ?? 1)) }
            mat[j] = r
        }
        let doc: [String: Any] = ["started": started0, "updated": nowISO(), "taches": tasks.map { $0.id },
                                  "correcteurs": js, "regle": "aucun cerveau n'est noté par un correcteur de sa propre famille",
                                  "cerveaux": lignes, "matrice_correcteurs": mat,
                                  "cout_banc_usd": r2(b1.usd - b0.usd), "plafond_usd": cap]
        try? jsonData(doc).write(to: URL(fileURLWithPath: root + "/releves/diag/qualite_comparatif.json"))
    }

    static func run(router: Router, declencheur: String, brain brainArg: String? = nil, judges judgesArg: [String] = [],
                    out outArg: String? = nil, tasks: [Tache] = taches, stopAt: Double = .infinity) {
        ensureDirs()
        let started0: String = nowISO()
        let brain: String = brainArg ?? Settings().get("brain", "spark-1.3")
        let outPath: String = outArg ?? QualiteNuit.outPath
        let judges: [String] = judgesArg.isEmpty ? ["wonder-1.0"] : judgesArg
        let soloRun: Bool = brainArg != nil
        var arret: String? = nil
        // Garde-fou budget : banc sauté si le budget du mois est atteint.
        let sp: [String: Any] = LLMSpend.summary()
        let mois: Double = (sp["mois_usd"] as? Double) ?? 0
        let budget: Double = (sp["budget_mois_usd"] as? Double) ?? 90
        if budget > 0 && mois >= budget {
            let why: String = String(format: "budget du mois atteint (%.2f $ sur %.0f $)", mois, budget)
            let doc: [String: Any] = ["started": started0, "updated": nowISO(), "done": true, "declencheur": declencheur, "saute": why]
            try? jsonData(doc).write(to: URL(fileURLWithPath: outPath))
            appendLog(["ts": nowISO(), "date": dayKey(Date()), "declencheur": declencheur, "saute": why])
            var recSkip: [String: Any] = [:]
            recSkip["tool"] = "qualite_nuit"; recSkip["actor"] = "Nova"; recSkip["ok"] = false; recSkip["effect"] = "lecture"
            recSkip["why"] = "banc qualité de nuit sauté"
            recSkip["result"] = why
            _ = BlackBox.record(recSkip)
            return
        }
        var whyStart: String = "banc qualité (" + declencheur + ")"
        whyStart += " : " + String(tasks.count) + " tâches fictives, cerveau " + brain
        var recStart: [String: Any] = [:]
        recStart["tool"] = "qualite_nuit"; recStart["actor"] = "Nova"; recStart["ok"] = true; recStart["effect"] = "lecture"
        recStart["why"] = whyStart
        recStart["result"] = "début"
        _ = BlackBox.record(recStart)
        let sys: String = Persona.system(title: "Ahadi", memory: "", voice: false, tools: false)
        var rows: [[String: Any]] = []
        var calls: Int = 0
        let maxCalls: Int = tasks.count * (1 + judges.count)
        var nOk: Int = 0
        var nFail: Int = 0
        var msTotal: Int = 0
        var sumEx: Int = 0, sumCo: Int = 0, sumFo: Int = 0, sumCc: Int = 0
        var nGraded: Int = 0
        var served: [String] = []
        for t in tasks {
            if calls >= maxCalls { break }
            if LLMSpend.benchToday().usd >= stopAt { arret = "plafond du banc atteint"; break }
            var row: [String: Any] = ["id": t.id]
            // Réponse principale : comme une demande d'Ahadi (drapeau interactif sur CE fil seulement).
            let t0: Date = Date()
            LLMSpend.setInteractive(true); LLMSpend.setBench(true)
            let det: (result: (text: String, brain: String)?, error: String?) = router.completeDetailed(
                messages: [ChatMsg("user", t.prompt)], system: sys, mode: "fast",
                preferred: brain, maxTokens: 4000, deadline: 150, solo: soloRun)   // 31/10 : Argon, [tiers] raisonnent avant de répondre
            LLMSpend.setInteractive(false); LLMSpend.setBench(false)
            calls += 1
            let ms: Int = Int(Date().timeIntervalSince(t0) * 1000)
            row["ms"] = ms
            if soloRun, let r = det.result, r.brain != brain {
                // 31/10 : garde-fou — une réponse servie par un AUTRE cerveau n'est jamais notée sous le nom de celui-ci.
                nFail += 1
                row["erreur"] = "servi par " + r.brain + " au lieu de " + brain + " : ignoré"
            } else if let r = det.result {
                nOk += 1
                msTotal += ms
                row["cerveau"] = r.brain
                row["chars"] = r.text.count
                row["extrait"] = String(SecretsGuard.redact(r.text).prefix(600))
                if soloRun { row["reponse"] = String(SecretsGuard.redact(r.text).prefix(12000)) }   // 31/10 : réponse complète gardée (re-notation sans rappeler le cerveau)
                if !served.contains(r.brain) { served.append(r.brain) }
                // Notation (fond : jamais de drapeau interactif ici).
                var gs: [[String: Any]] = []
                for jd in judges where calls < maxCalls {
                    calls += 1
                    // 31/10 : correcteur PREMIUM ([tiers], [tiers]) — sans le drapeau interactif, la politique de fond le
                    // remplaçait par [tiers] (toutes les notes venaient de [tiers]). Compté « banc », jamais chez Ahadi.
                    LLMSpend.setInteractive(true); LLMSpend.setBench(true)
                    if let g = grade(router: router, t: t, answer: r.text, judge: jd), (g["correcteur"] as? String) == jd { gs.append(g) }
                    LLMSpend.setInteractive(false); LLMSpend.setBench(false)
                }
                row["notes_par_correcteur"] = gs
                if !gs.isEmpty {
                    func avg(_ k: String) -> Int { Int((Double(gs.reduce(0) { $0 + (($1[k] as? Int) ?? 1) }) / Double(gs.count)).rounded()) }
                    do {
                        let g: [String: Any] = ["commentaire": (gs.first?["commentaire"] as? String) ?? "", "correcteur": gs.compactMap { $0["correcteur"] as? String }.joined(separator: ",")]
                        let ex: Int = avg("exactitude")
                        let co: Int = avg("completude")
                        let fo: Int = avg("forme")
                        let cc: Int = avg("concision")
                        sumEx += ex; sumCo += co; sumFo += fo; sumCc += cc
                        nGraded += 1
                        row["exactitude"] = ex
                        row["completude"] = co
                        row["forme"] = fo
                        row["concision"] = cc
                        row["note"] = r2(Double(ex + co + fo + cc) / 4.0)
                        row["commentaire"] = (g["commentaire"] as? String) ?? ""
                        row["correcteur"] = (g["correcteur"] as? String) ?? ""
                    }
                } else {
                    row["notation_erreur"] = "notation illisible ou indisponible"
                }
            } else {
                nFail += 1
                row["erreur"] = String((det.error ?? "aucune réponse").prefix(300))
            }
            rows.append(row)
            let snap: [String: Any] = ["started": started0, "updated": nowISO(), "done": false, "declencheur": declencheur,
                                       "cerveau_configure": brain, "taches": rows]
            try? jsonData(snap).write(to: URL(fileURLWithPath: outPath))
        }
        let den: Double = nGraded > 0 ? Double(nGraded) : 1.0
        let avgEx: Double = r2(Double(sumEx) / den)
        let avgCo: Double = r2(Double(sumCo) / den)
        let avgFo: Double = r2(Double(sumFo) / den)
        let avgCc: Double = r2(Double(sumCc) / den)
        let sumAll: Int = sumEx + sumCo + sumFo + sumCc
        let avgAll: Double = r2(Double(sumAll) / (4.0 * den))
        let avgMs: Int = nOk > 0 ? msTotal / nOk : 0
        var moyennes: [String: Any] = ["exactitude": avgEx, "completude": avgCo, "forme": avgFo, "concision": avgCc,
                                       "moyenne": avgAll, "ms_moyen": avgMs, "notees": nGraded]
        if nGraded == 0 { moyennes["moyenne"] = NSNull() }
        let fin: [String: Any] = ["started": started0, "updated": nowISO(), "done": true, "declencheur": declencheur,
                                  "cerveau_configure": brain, "cerveaux_servis": served, "appels": calls,
                                  "ok": nOk, "echecs": nFail, "total": tasks.count, "moyennes": moyennes, "taches": rows,
                                  "correcteurs": judges, "arret": arret.map { $0 as Any } ?? NSNull(),
                                  "cout": "compté automatiquement par LLMSpend : voir releves/diag/depenses.json"]
        try? jsonData(fin).write(to: URL(fileURLWithPath: outPath))
        var line: [String: Any] = ["ts": nowISO(), "date": dayKey(Date()), "declencheur": declencheur, "cerveau_configure": brain,
                                   "cerveaux": served, "ok": nOk, "echecs": nFail, "total": tasks.count, "notees": nGraded,
                                   "ms_moyen": avgMs]
        if nGraded > 0 {
            line["exactitude"] = avgEx
            line["completude"] = avgCo
            line["forme"] = avgFo
            line["concision"] = avgCc
            line["moyenne"] = avgAll
        }
        if declencheur != "comparatif" { appendLog(line) }   // 31/10 : le brief du matin ne suit que le cerveau d'Ahadi
        var res: String = String(nOk) + "/" + String(tasks.count) + " réponses"
        res += ", " + String(nGraded) + " notées"
        if nGraded > 0 { res += ", moyenne " + fr1(avgAll) + "/5" }
        res += ", " + fr1(Double(avgMs) / 1000.0) + " s en moyenne"
        var recEnd: [String: Any] = [:]
        recEnd["tool"] = "qualite_nuit"; recEnd["actor"] = "Nova"; recEnd["ok"] = nOk > 0; recEnd["effect"] = "lecture"
        recEnd["why"] = "banc qualité (" + declencheur + ") terminé"
        recEnd["result"] = res
        _ = BlackBox.record(recEnd)
    }

    // MARK: - Ligne du brief du matin

    static func fr1(_ x: Double) -> String {
        String(format: "%.1f", x).replacingOccurrences(of: ".", with: ",")
    }

    static func signed1(_ x: Double) -> String {
        if abs(x) < 0.05 { return "±0,0" }
        return x > 0 ? "+" + fr1(x) : "−" + fr1(-x)
    }

    static func num(_ v: Any?) -> Double? {
        if let d = v as? Double { return d }
        if let i = v as? Int { return Double(i) }
        return nil
    }

    /// Une ligne en français pour le brief du matin (dernier banc comparé au précédent), "" si aucune donnée.
    public static func briefLine() -> String {
        guard let s = try? String(contentsOfFile: logPath, encoding: .utf8) else { return "" }
        let all: [[String: Any]] = s.split(separator: "\n").compactMap { (l: Substring) -> [String: Any]? in parseJSON(Data(String(l).utf8)) }
        guard let last = all.last else { return "" }
        let ts: String = (last["ts"] as? String) ?? ""
        var recent: Bool = false
        if let d = ISO8601DateFormatter().date(from: ts) { recent = Date().timeIntervalSince(d) < 30 * 3600 }
        let lastDate: String = (last["date"] as? String) ?? "?"
        var quand: String = "cette nuit"
        if !recent { quand = "au dernier banc (" + lastDate + ")" }
        if let why = last["saute"] as? String {
            if !recent { return "" }
            let skipLine: String = "Banc qualité de Nova sauté cette nuit : " + why + "."
            return skipLine
        }
        let valid: [[String: Any]] = all.filter { (r: [String: Any]) -> Bool in r["saute"] == nil }
        guard let cur = valid.last else { return "" }
        let prev: [String: Any]? = valid.count >= 2 ? valid[valid.count - 2] : nil
        let ok: Int = (cur["ok"] as? Int) ?? 0
        let total: Int = (cur["total"] as? Int) ?? 10
        var out: String = "Qualité de Nova " + quand + " : "
        if let m = num(cur["moyenne"]) {
            out += fr1(m) + "/5"
            if let p = prev, let pm = num(p["moyenne"]) { out += " (" + signed1(m - pm) + ")" }
        } else {
            out += "non notée"
        }
        let ms: Double = num(cur["ms_moyen"]) ?? 0
        if ms > 0 {
            out += ", réponse moyenne " + fr1(ms / 1000.0) + " s"
            if let p = prev, let pms = num(p["ms_moyen"]), pms > 0 { out += " (" + signed1((ms - pms) / 1000.0) + " s)" }
        }
        out += ", " + String(ok) + "/" + String(total) + " tâches."
        return out
    }
}
