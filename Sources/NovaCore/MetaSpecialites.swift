import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// 01/11 (Meta AI Developer Hackathon) — ROUTAGE PAR SPÉCIALITÉ.
/// Chaque aspect de Nova (chat rapide, raisonnement profond / CAFU, code, agents et outils, Éclats de fond, correcteurs,
/// veille publique en poids ouverts, image, vision, segmentation, dictée, synthèse vocale) est servi par le modèle Meta
/// le plus pertinent, choisi sur mesure réelle ou sur la doc officielle (justification : docs/ROUTAGE_META.md).
///
/// Actif quand `meta_only` est vrai, ET par défaut hors de ce mode (réglage « routage_specialites », défaut VRAI).
/// `routage_specialites = false` rend exactement l'ancien comportement (ordres Catalog.fastOrder/bulkOrder/deepOrder,
/// cerveau actif en tête, aucune exclusion) : c'est l'interrupteur de retour arrière, sans recompiler.
///
/// VOIX LIVE : le mode « voice » n'est pas re-routé ici — voix classique (STT/TTS système macOS) + cerveau Meta (Spark, effort « none »).
///
/// Journal : chaque routage par spécialité écrit une ligne avec le champ « specialite » dans
/// releves/diag/meta_only_journal.jsonl quand meta_only est vrai (journal de preuve du hackathon), sinon dans
/// specialites_journal.jsonl (données de Nova) — le journal meta_only reste vide hors du mode (règle du 01/11).
public enum Specialite: String, CaseIterable {
    case chatRapide = "chat_rapide"
    case raisonnementProfond = "raisonnement_profond"
    case code = "code"
    case agentsOutils = "agents_outils"
    case eclatsFond = "eclats_fond"
    case juges = "correcteurs_juges"
    case veillePublique = "veille_publique_poids_ouverts"
    case image = "image"
    case vision = "vision"
    case segmentation = "segmentation"
    case dictee = "dictee"
    case syntheseVocale = "synthese_vocale"
    case voixLive = "voix_live"
    case relectureOpenWeight = "relecture_open_weight"
}

public struct AffectationSpecialite {
    public let specialite: Specialite
    /// « cerveau » (chaîne du routeur), « capacite » (API Meta hors chat), « local » (rien de Meta : moteur macOS),
    /// « inchange » (voix live : exception absolue).
    public let nature: String
    /// Cerveaux (ids du catalogue) dans l'ordre, pour nature == « cerveau ». Vide sinon.
    public let chaine: [String]
    /// Modèle d'API Meta (ou moteur) servi en tête.
    public let modele: String
    public let endpoint: String
    /// reasoning_effort envoyé à l'API Meta (nil = sans objet).
    public let effort: String?
    public let prix: String
    public let preuve: String
    public let sources: [String]
}

public enum MetaSpecialites {
    public static let settingKey: String = "routage_specialites"
    public static let journalName: String = "specialites_journal.jsonl"

    final class State: @unchecked Sendable {
        let lock = NSLock()
        var override: Bool? = nil
        var exclusOverride: Set<String>? = nil
    }
    static let state = State()
    /// Tests seulement : impose l'état du routage par spécialité (nil = relire le réglage).
    static func setOverride(_ v: Bool?) { state.lock.lock(); state.override = v; state.lock.unlock() }
    /// Tests seulement : impose la liste d'exclusion des chaînes automatiques (nil = défaut / réglage).
    static func setExclusOverride(_ v: Set<String>?) { state.lock.lock(); state.exclusOverride = v; state.lock.unlock() }

    /// Routage par spécialité actif ? Toujours en meta_only ; sinon réglage « routage_specialites » (défaut vrai).
    public static var actif: Bool {
        if MetaOnly.enabled { return true }
        state.lock.lock(); let o: Bool? = state.override; state.lock.unlock()
        if let o = o { return o }
        return Settings().get(settingKey, true)
    }

    // MARK: - Secours Meta (hors api.meta.ai)

    /// Version hackathon Meta : le SEUL secours après les cerveaux de l'API Meta est Muse Spark Open (poids ouverts Meta), servi par Baseten.
    /// Aucun modèle non Meta n'existe dans le catalogue (Brains.swift).
    public static let secoursMeta: [String] = ["spark-open-baseten"]

    // MARK: - Table spécialité → modèle

    static let srcModels: String = "https://dev.meta.ai/docs/models"
    static let srcPrix: String = "https://dev.meta.ai/docs/pricing-rate-limits"
    static let srcBanc: String = "releves/diag/qualite_eval_*.json (banc réel du 01/11/2026)"

    public static let table: [AffectationSpecialite] = [
        AffectationSpecialite(specialite: .chatRapide, nature: "cerveau", chaine: ["spark-1.3", "spark-1.2", "wonder-1.0"],
            modele: "muse-spark-1.3", endpoint: "https://api.meta.ai/v1/chat/completions", effort: "low",
            prix: "1,25 $ / 4,25 $ par M de jetons (Standard)",
            preuve: "banc 01/11 : Spark 1.3 6/7 réussis, 0,144 $ au total, 1re réponse utile médiane 5,6 s (Wonder 6/7, 0,493 $, 7,4 s) ; journal de fin : 23/23 appels réussis, 5,0 s en moyenne",
            sources: [srcBanc, "releves/diag/cerveaux_journal_fin.jsonl", srcPrix]),
        AffectationSpecialite(specialite: .raisonnementProfond, nature: "cerveau", chaine: ["spark-1.3", "wonder-1.0", "spark-1.2"],
            modele: "muse-spark-1.3", endpoint: "https://api.meta.ai/v1/chat/completions", effort: "high (CAFU : max → xhigh → high)",
            prix: "1,25 $ / 4,25 $ par M ; Wonder en relais 4 $ / 20 $ par M",
            preuve: "cafu_test.json du 01/11 : note CAFU Spark 1.3 effort max 8,0/10, 0,225 $ ; banc : Wonder ne fait pas mieux (6/7) pour 3,4 × le coût par résultat accepté → Wonder en relais",
            sources: ["releves/diag/cafu_test.json", srcBanc, srcPrix]),
        AffectationSpecialite(specialite: .code, nature: "cerveau", chaine: ["wonder-1.0", "spark-1.3"],
            modele: "muse-wonder-1.0", endpoint: "https://api.meta.ai/v1/chat/completions", effort: "high",
            prix: "4 $ / 20 $ par M",
            preuve: "doc Meta : Wonder = « agentic work, coding, reasoning », variante la plus capable de l'API ; banc 01/11 : correctif_swift et correctif_ui réussis par Wonder ET Spark (égalité) → Spark en relais",
            sources: [srcModels, srcBanc]),
        AffectationSpecialite(specialite: .agentsOutils, nature: "cerveau", chaine: ["spark-1.3", "wonder-1.0"],
            modele: "muse-spark-1.3", endpoint: "https://api.meta.ai/v1/chat/completions", effort: "low",
            prix: "1,25 $ / 4,25 $ par M",
            preuve: "doc Meta : Spark 1.3 « agentic workflows », recommandé pour les nouveaux travaux ; appels de fonctions (y compris parallèles) documentés ; banc : reprise_interrompue et mail_injection_cachee réussis",
            sources: [srcModels, "https://docs.litellm.ai/docs/providers/meta", srcBanc]),
        AffectationSpecialite(specialite: .eclatsFond, nature: "cerveau", chaine: ["spark-1.3", "spark-1.2"],
            modele: "muse-spark-1.3", endpoint: "https://api.meta.ai/v1/chat/completions", effort: "low",
            prix: "1,25 $ / 4,25 $ par M (jamais Contributor : contenu personnel)",
            preuve: "même mesure que le chat rapide ; Contributor exclu (Meta entraîne sur ce palier, conditions 6.1)",
            sources: [srcBanc, "https://dev.meta.ai/legal/terms-of-service"]),
        AffectationSpecialite(specialite: .juges, nature: "cerveau", chaine: ["wonder-1.0", "spark-1.3"],
            modele: "muse-wonder-1.0", endpoint: "https://api.meta.ai/v1/chat/completions", effort: "medium",
            prix: "4 $ / 20 $ par M (≈ 400 jetons de sortie par note)",
            preuve: "le rédacteur est Spark 1.3 : le juge est un AUTRE modèle (Wonder). La règle du banc « jamais un correcteur de la même famille » ne peut pas être tenue avec Meta seul (Spark et Wonder sont tous deux Muse) : le banc garde son correcteur actuel, inchangé",
            sources: [srcModels, "releves/diag/qualite_eval.json (regle_correcteurs)"]),
        AffectationSpecialite(specialite: .veillePublique, nature: "cerveau", chaine: ["spark-open-baseten", "spark-open-hf", "spark-1.3"],
            modele: "meta-models/muse-spark-open (Baseten)", endpoint: "https://inference.baseten.co/v1/chat/completions", effort: nil,
            prix: "crédits hackathon Baseten (aucun prix versionné) ; repli Spark 1.3",
            preuve: "tâche réelle visible : POST /api/feed/synthese-ouverte (titres RSS PUBLICS seulement). Spark Open = poids ouverts Meta, servi par Baseten (partenaire nommé par Meta). Sans clé « nova-baseten » : repli nommé sur Spark 1.3",
            sources: ["https://dev.meta.ai/docs/muse-spark-open"]),
        AffectationSpecialite(specialite: .image, nature: "capacite", chaine: [],
            modele: "muse-image-1.0", endpoint: "POST https://api.meta.ai/v1/images/generations", effort: nil,
            prix: "0,01 $ par image générée",
            preuve: "seul modèle d'image de l'API Meta ; studio de design (IMAGE_GEN.json) : Muse Image",
            sources: [srcModels, srcPrix, "https://dev.meta.ai/docs/image-generation"]),
        AffectationSpecialite(specialite: .vision, nature: "cerveau", chaine: ["spark-1.3", "wonder-1.0"],
            modele: "muse-spark-1.3", endpoint: "https://api.meta.ai/v1/chat/completions", effort: "low",
            prix: "1,25 $ / 4,25 $ par M",
            preuve: "entrée image, vidéo et PDF documentée pour Muse Spark (1 M de contexte)",
            sources: ["https://docs.litellm.ai/docs/providers/meta"]),
        AffectationSpecialite(specialite: .segmentation, nature: "capacite", chaine: [],
            modele: "sam-3.1", endpoint: "POST https://api.meta.ai/v1/responses", effort: nil,
            prix: "2,50 $ / 1 000 images ; 0,20 $ / 1 000 images de vidéo (minimum 50)",
            preuve: "SAM 3.1 = segmentation image et vidéo de l'API Meta (POST /api/meta/segment, confirm_cloud requis)",
            sources: [srcModels, srcPrix, "https://dev.meta.ai/docs/media-segmentation"]),
        AffectationSpecialite(specialite: .dictee, nature: "capacite", chaine: [],
            modele: "muse-voice-transcribe-1.0", endpoint: "POST https://api.meta.ai/v1/asr/transcribe (temps réel : wss://api.meta.ai/v1/asr/realtime)", effort: nil,
            prix: "0,18 $ par heure d'audio",
            preuve: "seul modèle de transcription de l'API Meta ; déjà premier de Voice.transcribe (stt_meta, défaut vrai)",
            sources: [srcModels, srcPrix, "https://dev.meta.ai/docs/speech-to-text"]),
        AffectationSpecialite(specialite: .syntheseVocale, nature: "local", chaine: [],
            modele: "AVSpeechSynthesizer (macOS)", endpoint: "sur le Mac", effort: nil,
            prix: "gratuit (sur l'appareil)",
            preuve: "Meta ne propose AUCUN modèle de synthèse vocale : la doc dit que Muse Voice Transcribe « does not synthesize speech ». Voix système macOS (AVSpeechSynthesizer), pas un modèle génératif appelé par Nova",
            sources: [srcModels]),
        AffectationSpecialite(specialite: .voixLive, nature: "inchange", chaine: [],
            modele: "voix classique : SFSpeechRecognizer + AVSpeechSynthesizer (macOS) + muse-spark-1.3", endpoint: "https://api.meta.ai/v1/chat/completions", effort: "minimal",
            prix: "1,25 $ / 4,25 $ par M (Spark) ; reconnaissance et synthèse vocales système gratuites",
            preuve: "version hackathon : aucun moteur de voix non Meta ; le cerveau de la voix est Spark (Meta), effort « none » pour la latence",
            sources: []),
        AffectationSpecialite(specialite: .relectureOpenWeight, nature: "cerveau", chaine: ["spark-open-baseten"],
            modele: "meta-models/muse-spark-open (Baseten)", endpoint: "https://inference.baseten.co/v1/chat/completions", effort: nil,
            prix: "1,25 $ entrée / 0,15 $ cache / 4,25 $ sortie par M (page Baseten du compte, 01/11/2026)",
            preuve: "mode CAFU : après la rédaction par Spark 1.3, Spark Open relit la note (faits, étiquettes, score) — étape visible, journalisée, coût au tarif Baseten vérifié. Réglage cafu_relecture_open_weight (défaut vrai)",
            sources: ["page Baseten du compte, 01/11/2026", "https://dev.meta.ai/docs/muse-spark-open"]),
    ]

    public static func affectation(_ s: Specialite) -> AffectationSpecialite? { table.first { $0.specialite == s } }

    // MARK: - Mode → spécialité

    /// Spécialité d'un appel du routeur. nil = pas de re-routage (voix live, mode inconnu).
    public static func specialite(mode: String, outils: Bool) -> Specialite? {
        switch mode {
        case "fast": return outils ? .agentsOutils : .chatRapide
        case "deep": return .raisonnementProfond
        case "bulk": return .eclatsFond
        case "code": return .code
        case "agent", "outils": return .agentsOutils
        case "juge", "verify": return .juges
        case "public": return .veillePublique
        case "vision": return .vision
        default: return nil   // « voice » : exception absolue
        }
    }

    /// Ordre de la chaîne automatique pour ce mode (Meta d'abord, puis les 2 secours gratuits). nil = ancien ordre.
    public static func ordre(mode: String, outils: Bool) -> [String]? {
        guard actif, let s = specialite(mode: mode, outils: outils), let a = affectation(s), a.nature == "cerveau" else { return nil }
        var out: [String] = a.chaine
        // 01/11 (bonus open-weight) : en meta_only, Spark Open (Baseten) est le SEUL secours Meta hors api.meta.ai — il passe juste
        // après les cerveaux de l'API Meta : une panne Meta (5xx, 429, délai, crédit) bascule sur lui. Hors meta_only : jamais en
        // chaîne automatique (aucun contenu personnel ne part chez Baseten sans choix explicite), sauf la veille publique.
        for g in secoursMeta where !out.contains(g) { out.append(g) }
        return out
    }

    /// Les modes « historiques » gardent le cerveau ACTIF des Réglages en tête (choix d'Ahadi, jamais verrouillé) ;
    /// les modes de spécialité (code, juge, veille publique…) mettent la spécialité en tête.
    public static func gardeCerveauActifEnTete(mode: String) -> Bool { ["fast", "deep", "bulk", "voice"].contains(mode) }

    /// reasoning_effort envoyé à l'API Meta. Valeurs historiques à l'identique pour fast/bulk (low), deep (high), voice (none).
    public static func effort(mode: String) -> String {
        switch mode {
        case "deep", "code": return "high"
        case "voice": return "minimal"   // 01/11 : « none » refusé (HTTP 400) par l API Meta pour Spark 1.3
        case "juge", "verify": return "medium"
        default: return "low"
        }
    }

    // MARK: - Exclusion des chaînes automatiques (réversible)

    /// Cerveaux sortis des chaînes AUTOMATIQUES (01/11, ordre d'Ahadi) : sans clé ou sans crédit, ou conditions de données non
    /// conformes. Rien n'est supprimé du code ; ils restent sélectionnables à la main s'ils ont une clé (choix épinglé),
    /// la voix live n'est pas concernée. Retour arrière : réglage « chaines_auto_exclus » (liste d'ids, [] = aucune exclusion)
    /// ou « routage_specialites » = false. Preuves par id : docs/ROUTAGE_META.md §5.
    public static let horsChainesParDefaut: [String: String] = [
        "spark-open-hf": "Spark Open via Hugging Face : sélectionnable à la main (jeton HF requis), hors chaînes automatiques",
    ]

    public static var exclus: Set<String> {
        state.lock.lock(); let o: Set<String>? = state.exclusOverride; state.lock.unlock()
        if let o = o { return o }
        if let l = Settings().all()["chaines_auto_exclus"] as? [String] { return Set(l) }
        return Set(horsChainesParDefaut.keys)
    }
    /// Cet id est-il sorti des chaînes automatiques ? Faux quand le routage par spécialité est coupé.
    public static func exclu(_ id: String) -> Bool { actif && exclus.contains(id) }

    // MARK: - Journal

    static let journal = Journal(journalName)

    /// Une ligne par routage (spécialité, tête de chaîne, chaîne). Aucun contenu, aucune clé.
    public static func noter(specialite s: Specialite, modele: String, cerveau: String, chaine: [String], statut: String, source: String) {
        if MetaOnly.enabled {
            MetaOnly.record(provider: cerveau.hasPrefix("spark-open-baseten") ? "baseten" : "meta", model: modele, meta: true, status: statut,
                            source: source, host: "", brain: cerveau, specialite: s.rawValue, chain: chaine)
        } else {
            journal.add(["specialite": s.rawValue, "modele": modele, "cerveau": cerveau, "chaine": chaine.joined(separator: ">"), "statut": statut, "source": source])
        }
    }
    /// Appelé par Router.chat juste avant l'envoi.
    static func noterRoutage(mode: String, outils: Bool, chain: [BrainSpec]) {
        guard actif, let s = specialite(mode: mode, outils: outils), let first = chain.first else { return }
        noter(specialite: s, modele: first.model, cerveau: first.id, chaine: chain.map { $0.id }, statut: "route", source: "router.chat")
    }

    // MARK: - Baseten (Spark Open) : chaque appel réel est journalisé

    /// Tarif Muse Spark Open sur Baseten (page Baseten du compte, 01/11/2026) : $ par M de jetons.
    public static let basetenTarif: (input: Double, cache: Double, output: Double) = (1.25, 0.15, 4.25)
    public static func coutBasetenUSD(inTok: Int, outTok: Int, cacheTok: Int = 0) -> Double {
        let i: Double = Double(max(0, inTok - cacheTok)) * basetenTarif.input
        let c: Double = Double(max(0, cacheTok)) * basetenTarif.cache
        let o: Double = Double(max(0, outTok)) * basetenTarif.output
        return (i + c + o) / 1_000_000.0
    }
    /// Preuve (vidéo, README) : TOUJOURS écrit dans releves/diag/meta_only_journal.jsonl, quel que soit le mode.
    public static func noterBaseten(statut: String, source: String, specialite s: String, mode: String = "", inTok: Int = 0, outTok: Int = 0, ms: Int = 0, raison: String = "") {
        var extra: [String: Any] = ["mode": mode]
        if inTok > 0 || outTok > 0 {
            extra["jetons_entree"] = inTok; extra["jetons_sortie"] = outTok
            extra["cout_usd"] = (coutBasetenUSD(inTok: inTok, outTok: outTok) * 1_000_000).rounded() / 1_000_000
            extra["tarif"] = "1,25 $ / 4,25 $ par M (page Baseten du compte, 01/11/2026)"
        }
        if ms > 0 { extra["ms"] = ms }
        MetaOnly.record(provider: "baseten", model: "meta-models/muse-spark-open", meta: true, status: statut, source: source, host: "inference.baseten.co",
                        reason: raison, brain: "spark-open-baseten", specialite: s, extra: extra)
    }

    // MARK: - Relecture CAFU par Spark Open (open-weight)

    public static let relectureSys: String = """
    You are the QA reviewer of a CAFU (Context Analysis and Foresight Unit) humanitarian note. You did NOT write it.
    Check ONLY the note text given. Report, in British English, three short sections:
    1) Facts: any figure, date or claim that looks inconsistent inside the note (contradiction, impossible date, arithmetic error). Max 5 bullets.
    2) Tags: any bullet whose tag [SOLID]/[REPORTED]/[JUDGEMENT]/[TO CHECK] does not match its own sourcing description. Max 5 bullets.
    3) Score: your own score out of 10 with one sentence of justification, then « Agree » or « Disagree » with the note's self-score.
    Never invent sources. If nothing is wrong in a section, write « None found ».
    """
    /// Seul le TEXTE de la note (déjà construit sur des sources publiques citées) est envoyé, masqué par SecretsGuard.
    public static func relectureUser(note: String) -> String {
        "CAFU NOTE TO REVIEW:\n\n" + String(SecretsGuard.redact(note).prefix(24000))
    }

    /// Passe de relecture : (texte de relecture, coût USD, statut). Sans clé Baseten / indisponible : statut « saute », rien n'est envoyé.
    static func relireNoteCafu(router: Router, note: String, cancel: @escaping () -> Bool) -> (text: String?, cost: Double, statut: String, detail: String) {
        guard router.usable("spark-open-baseten"), let spec = router.brains.first(where: { $0.id == "spark-open-baseten" }) else {
            let why: String = router.whyUnusable("spark-open-baseten")
            noterBaseten(statut: "saute", source: "cafu.relecture", specialite: Specialite.relectureOpenWeight.rawValue, mode: "juge", raison: why)
            return (nil, 0, "saute", why.isEmpty ? "indisponible" : why)
        }
        let user: String = relectureUser(note: note)
        let maxOut: Int = 4096
        let pf: Preflight = LLMSpend.preflight(spec: spec, estIn: TokenEst.of(relectureSys) + TokenEst.of(user), maxOut: maxOut, lane: LLMSpend.currentLane(background: false))
        guard let tk = pf.ticket else {
            var why: String = "réservation impossible"
            if case .refused(let w) = pf { why = w }
            noterBaseten(statut: "bloque", source: "cafu.relecture", specialite: Specialite.relectureOpenWeight.rawValue, mode: "juge", raison: "budget : " + why)
            return (nil, 0, "bloque", "budget : " + why)
        }
        var out: String = ""; var uin: Int = 0; var uout: Int = 0
        let t0: Date = Date()
        do {
            try router.runner.stream(spec, messages: [ChatMsg("user", user)], system: relectureSys, maxTokens: maxOut, mode: "juge", firstTokenTimeout: 120, cancel: cancel,
                                     onDelta: { out += $0 }, onUsage: { uin = $0; uout = $1 })
        } catch let f as BrainFailure {
            LLMSpend.abandon(tk, kind: f.kind, produced: !out.isEmpty)
            noterBaseten(statut: "echec", source: "cafu.relecture", specialite: Specialite.relectureOpenWeight.rawValue, mode: "juge",
                         ms: Int(Date().timeIntervalSince(t0) * 1000), raison: f.message)
            return (nil, 0, "echec", f.message)
        } catch {
            LLMSpend.abandon(tk, kind: nil, produced: !out.isEmpty)
            return (nil, 0, "echec", error.localizedDescription)
        }
        let inT: Int = uin > 0 ? uin : TokenEst.of(relectureSys) + TokenEst.of(user)
        let outT: Int = uout > 0 ? uout : TokenEst.of(out)
        LLMSpend.record(spec.id, inTok: inT, outTok: outT, cacheRead: 0, cacheWrite: 0, background: false, spec: spec, ticket: tk, measured: uin > 0 || uout > 0)
        let cost: Double = coutBasetenUSD(inTok: inT, outTok: outT)
        let txt: String = out.trimmingCharacters(in: .whitespacesAndNewlines)
        noterBaseten(statut: txt.isEmpty ? "vide" : "ok", source: "cafu.relecture", specialite: Specialite.relectureOpenWeight.rawValue, mode: "juge",
                     inTok: inT, outTok: outT, ms: Int(Date().timeIntervalSince(t0) * 1000))
        return (txt.isEmpty ? nil : txt, cost, txt.isEmpty ? "vide" : "ok", "")
    }

    // MARK: - Choix utilisable

    /// Premier cerveau utilisable de la spécialité (Meta d'abord, puis secours gratuits). nil si rien.
    public static func premierUtilisable(_ s: Specialite, router: Router) -> String? {
        guard let a = affectation(s), a.nature == "cerveau" else { return nil }
        for id in a.chaine + secoursMeta where router.usable(id) { return id }
        return nil
    }

    // MARK: - État servi (GET /api/meta-only/specialites)

    /// Spécialité → modèle, et présence des clés (oui/non seulement, jamais une valeur).
    public static func snapshot(router: Router, keys: KeyStore) -> [String: Any] {
        let meta: Bool = MetaCapabilities.keyChain.resolve(keys) != nil
        let baseten: Bool = KeyChain([KnownKeys.basetenNova]).resolve(keys) != nil
        func ouiNon(_ b: Bool) -> String { b ? "oui" : "non" }
        var rows: [[String: Any]] = []
        for a in table {
            var r: [String: Any] = ["specialite": a.specialite.rawValue, "nature": a.nature, "modele": a.modele, "endpoint": a.endpoint,
                                    "prix": a.prix, "preuve": a.preuve, "sources": a.sources]
            if let e = a.effort { r["effort"] = e }
            if a.nature == "cerveau" {
                let full: [String] = a.chaine + secoursMeta.filter { !a.chaine.contains($0) }
                r["chaine"] = full
                r["premier_utilisable"] = premierUtilisable(a.specialite, router: router) ?? NSNull()
            }
            switch a.specialite {
            case .veillePublique: r["cle_presente"] = ouiNon(baseten); r["cle"] = "nova-baseten"
                if !baseten { r["repli"] = "clé nova-baseten absente : Spark 1.3 (Meta) sert la synthèse — rien n'est demandé ni créé" }
            case .relectureOpenWeight: r["cle_presente"] = ouiNon(baseten); r["cle"] = "nova-baseten"
                if !baseten { r["repli"] = "clé nova-baseten absente : relecture sautée (étape « saute » visible), rien n'est demandé ni créé" }
            case .syntheseVocale, .voixLive: break
            default: r["cle_presente"] = ouiNon(meta); r["cle"] = "nova-spark / nova-meta"
            }
            rows.append(r)
        }
        return ["ok": true, "meta_only": MetaOnly.enabled, "routage_specialites": actif, "specialites": rows,
                "cles": ["meta": ouiNon(meta), "nova-baseten": ouiNon(baseten)],
                "secours_meta": secoursMeta, "hors_chaines_auto": exclus.sorted(),
                "secours_meta_only": "spark-open-baseten (seul secours Meta hors api.meta.ai, ajouté après les cerveaux Meta quand meta_only est vrai)",
                "tts_meta": "aucun modèle Meta de synthèse vocale (dev.meta.ai/docs/models) : AVSpeechSynthesizer (voix système macOS)",
                "journal": MetaOnly.enabled ? MetaOnly.journalURL.path : journal.url.path]
    }

    // MARK: - Veille publique en poids ouverts (tâche réelle)

    /// Titres RSS PUBLICS des flux configurés (aucun contenu personnel).
    static func titresPublics(feeds: [String], max: Int = 30) -> [String] {
        var titres: [String] = []
        let lock = NSLock(); let g = DispatchGroup()
        for f in feeds.prefix(8) {
            g.enter()
            Thread.detachNewThread {
                defer { g.leave() }
                let (st, body): (Int, String) = Tools.get(f, timeout: 10)
                guard st == 200, let d = body.data(using: .utf8) else { return }
                let p = RSSParser(); let x = XMLParser(data: d); x.delegate = p; x.parse()
                let host: String = URL(string: f)?.host ?? f
                lock.lock(); for it in p.items.prefix(6) { titres.append("- " + it.0 + " (" + host + ")") }; lock.unlock()
            }
        }
        _ = g.wait(timeout: .now() + 14)
        return Array(titres.prefix(max))
    }

    /// Cerveau de la veille publique : Spark Open (Baseten) si sa clé est là, sinon le premier Meta utilisable.
    /// Épinglé (premier plan) : la facturation « crédits Baseten » n'est jamais engagée par une tâche de fond.
    public static func cerveauVeille(router: Router) -> (id: String?, ouvert: Bool, raison: String) {
        if router.usable("spark-open-baseten") { return ("spark-open-baseten", true, "Muse Spark Open (poids ouverts) servi par Baseten") }
        let why: String = router.whyUnusable("spark-open-baseten")
        let repli: String? = ["spark-open-hf", "spark-1.3", "spark-1.2", "wonder-1.0"].first { router.usable($0) }
        return (repli, repli == "spark-open-hf", "Spark Open (Baseten) indisponible : " + (why.isEmpty ? "?" : why) + (repli.map { " → repli " + $0 } ?? " → aucun cerveau Meta utilisable"))
    }
}

extension NovaApp {
    /// GET /api/meta-only/specialites ; POST /api/feed/synthese-ouverte (veille publique, poids ouverts Meta).
    func metaSpecialitesRoutes() {
        let s = server
        s.on("GET", "/api/meta-only/specialites") { [self] _, res in
            res.json(MetaSpecialites.snapshot(router: router, keys: keys))
        }
        s.on("POST", "/api/feed/synthese-ouverte") { [self] _, res in
            let titres: [String] = MetaSpecialites.titresPublics(feeds: settings.get("feeds", [String]()))
            guard !titres.isEmpty else { res.json(["ok": false, "erreur": "aucun titre RSS lisible (réseau ou flux)"], status: 502); return }
            let choix = MetaSpecialites.cerveauVeille(router: router)
            guard let id = choix.id else {
                MetaSpecialites.noter(specialite: .veillePublique, modele: "", cerveau: "", chaine: [], statut: "echec", source: "feed.synthese-ouverte")
                res.json(["ok": false, "erreur": choix.raison, "open_weight": false], status: 503); return
            }
            let sys: String = "Tu résumes une veille d'actualité PUBLIQUE en français. 5 puces maximum, chacune avec sa source entre parenthèses. N'invente rien : seulement ce que disent les titres."
            let det = router.completeDetailed(messages: [ChatMsg("user", "Titres publics du jour :\n" + titres.joined(separator: "\n"))], system: sys,
                                              mode: "public", preferred: id, maxTokens: 2048, deadline: 90, solo: false)
            let used: String = det.result?.brain ?? ""
            let ouvert: Bool = used.hasPrefix("spark-open")
            MetaSpecialites.noter(specialite: .veillePublique, modele: router.brains.first { $0.id == used }?.model ?? "", cerveau: used,
                                  chaine: [id], statut: det.result == nil ? "echec" : "ok", source: "feed.synthese-ouverte")
            if let r = det.result {
                res.json(["ok": true, "synthese": r.text, "cerveau": r.brain, "open_weight": ouvert, "titres": titres.count,
                          "note": ouvert ? "servi par Muse Spark Open (poids ouverts Meta)" : choix.raison])
            } else {
                res.json(["ok": false, "erreur": det.error ?? "aucune réponse", "open_weight": false, "note": choix.raison], status: 502)
            }
        }
    }
}
