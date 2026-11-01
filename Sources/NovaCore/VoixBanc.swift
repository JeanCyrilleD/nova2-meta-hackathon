import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// 01/11 (voix-test, hackathon Meta) — BANC DE LA CHAÎNE VOIX « 100 % Meta », SANS MICRO NI HUMAIN.
///
/// Déclencheur : dormant/VOIX_TEST_REQUEST (ou .json, contenu facultatif {"repetitions": 1, "limite": 12, "barge_in": [2, 5, 8]} ;
/// sans « repetitions », la série est rejouée jusqu'à ≥ 60 s de parole simulée, au plus 3 fois),
/// sur le modèle de CAFU_TEST_REQUEST. La demande est renommée dormant/VOIX_TEST_REQUEST.done.json.
/// Entrée : dormant/voix_test/*.wav (WAV PCM16 mono 16 kHz, phrases synthétiques SANS donnée personnelle) + manifest.json
/// ({"items": [{"fichier", "langue", "texte"}], "barge_in": [indices 1..n]}).
///
/// Pour chaque fichier, dans l'ordre d'un tour de conversation :
///  (a) Muse Voice Transcribe (Voice.transcribeMeta, POST https://api.meta.ai/v1/asr/transcribe) : latence, texte, WER approximatif ;
///  (b) Spark 1.3 en mode « voice » (reasoning_effort « none », réponse courte, flux) : premier jeton, première phrase, durée totale ;
///  (c) AVSpeechSynthesizer (LocalVoice.renderDetailed) des 1 à 2 premières phrases, EN CONTINU phrase par phrase dès qu'elles
///      sortent du flux, vers un fichier WAV (aucun son joué) : premier tampon audio ;
///  (d) barge-in simulé sur les tours de « barge_in » : arrêt pendant la génération ou pendant la synthèse, puis tour suivant
///      enchaîné : temps d'arrêt et temps de reprise (jusqu'au premier audio du tour suivant).
/// « premier_audio_ms » = du début de la dictée (fin de parole simulée) au premier tampon audio de la réponse. Il n'inclut NI la
/// détection de fin de parole (VAD) NI la latence du haut-parleur : ce banc ne les voit pas.
///
/// Budget : plafond de 0,50 $ par passage, vérifié AVANT tout envoi (estimation pire cas) et avant chaque tour ; chaque appel Spark
/// est réservé par SpendPolicy (LLMSpend.preflight, voie « banc ») avant la dictée du même tour : un refus arrête le passage
/// (échec fermé, rien n'est envoyé). Coûts réels : Voice Transcribe 0,18 $/h d'audio, Spark 1,25 $ / 4,25 $ par M de jetons.
/// Journal : chaque appel réseau est écrit dans releves/diag/meta_only_journal.jsonl (spécialité « dictee » ou « voix »).
/// La synthèse est locale (aucun modèle, aucun réseau) : elle n'est PAS écrite dans ce journal de preuve (qui ne liste que des
/// appels de modèles Meta) ; ses mesures sont dans voix_test.json.
/// (Fichier hors Feat_* : cliquet de verify.sh, ≤ 89 fichiers Feat_.)
/// Résultats : releves/diag/voix_test.json ; audio produit : releves/diag/voix_test/NN_reponse.wav ;
/// traces au format demo/traces : releves/diag/voix_test_traces/{dictation,voice_chain}.json.
public struct VoixTestItem {
    public let fichier: String
    public let langue: String
    public let texte: String
    public init(fichier: String, langue: String, texte: String) { self.fichier = fichier; self.langue = langue; self.texte = texte }
}

public enum VoixTest {
    public static let requestName: String = "VOIX_TEST_REQUEST"
    public static let plafondUSD: Double = 0.50
    public static let sttUSDParHeure: Double = 0.18
    public static let sparkTarif: (input: Double, output: Double) = (1.25, 4.25)   // $ par M (MetaSpecialites, dev.meta.ai/docs/pricing-rate-limits)
    public static let sparkMaxOut: Int = 320   // plancher de sortie de BrainRunner au premier essai (raisonnement « none » : réponse courte)
    public static let phrasesMax: Int = 2
    public static let system: String = """
    You are Nova, the voice assistant of a humanitarian analyst. This is a live spoken conversation: answer in the language of the question \
    (English or French), in one or two short sentences, the first one short and complete. Plain spoken text only: no markdown, no lists, \
    no URLs. If you are not sure of a fact, say so in a few words; never invent figures.
    """

    final class Running: @unchecked Sendable { let lock = NSLock(); var on = false }
    static let running = Running()

    // MARK: - Mesures pures (testées)

    /// Mots normalisés : minuscules, apostrophes et ponctuation = séparateurs (accents conservés).
    public static func mots(_ s: String) -> [String] {
        let low: String = s.lowercased()
        var out: String = ""
        out.reserveCapacity(low.count)
        for u in low.unicodeScalars {
            if CharacterSet.letters.contains(u) || CharacterSet.decimalDigits.contains(u) { out.unicodeScalars.append(u) } else { out += " " }
        }
        return out.split(separator: " ").map { String($0) }
    }

    /// WER approximatif : distance d'édition en mots / nombre de mots de la référence. nil si la référence est vide.
    public static func wer(reference: String, hypothese: String) -> Double? {
        let r: [String] = mots(reference), h: [String] = mots(hypothese)
        if r.isEmpty { return nil }
        if h.isEmpty { return 1.0 }
        var prev: [Int] = Array(0...h.count)
        var cur: [Int] = Array(repeating: 0, count: h.count + 1)
        for i in 1...r.count {
            cur[0] = i
            for j in 1...h.count {
                let sub: Int = prev[j - 1] + (r[i - 1] == h[j - 1] ? 0 : 1)
                cur[j] = min(sub, prev[j] + 1, cur[j - 1] + 1)
            }
            swap(&prev, &cur)
        }
        return Double(prev[h.count]) / Double(r.count)
    }

    /// Centile par interpolation linéaire (p dans [0, 1]). nil si vide.
    public static func centile(_ xs: [Double], _ p: Double) -> Double? {
        if xs.isEmpty { return nil }
        let s: [Double] = xs.sorted()
        let rank: Double = max(0, min(1, p)) * Double(s.count - 1)
        let lo: Int = Int(rank.rounded(.down)), hi: Int = Int(rank.rounded(.up))
        return s[lo] + (s[hi] - s[lo]) * (rank - Double(lo))
    }

    /// Résumé d'une étape : n, médiane, p90, min, max (ms entières). Valeurs négatives (non mesurées) écartées.
    public static func resume(_ xs0: [Double]) -> [String: Any] {
        let xs: [Double] = xs0.filter { $0 >= 0 }
        var o: [String: Any] = ["n": xs.count]
        if let m = centile(xs, 0.5) { o["mediane_ms"] = Int(m.rounded()) }
        if let p = centile(xs, 0.9) { o["p90_ms"] = Int(p.rounded()) }
        if let a = xs.min() { o["min_ms"] = Int(a.rounded()) }
        if let b = xs.max() { o["max_ms"] = Int(b.rounded()) }
        return o
    }

    public static func coutSTT(durationMs: Int) -> Double { Double(max(0, durationMs)) / 3_600_000.0 * sttUSDParHeure }
    public static func coutSpark(inTok: Int, outTok: Int) -> Double {
        (Double(max(0, inTok)) * sparkTarif.input + Double(max(0, outTok)) * sparkTarif.output) / 1_000_000.0
    }
    static func arrondi(_ x: Double) -> Double { (x * 1_000_000).rounded() / 1_000_000 }

    /// Pire cas d'un tour : dictée de `durationMs` + un appel Spark (entrée estimée, sortie au plafond).
    public static func pireCasTour(durationMs: Int, estIn: Int, maxOut: Int = sparkMaxOut) -> Double {
        coutSTT(durationMs: durationMs) + coutSpark(inTok: estIn, outTok: maxOut)
    }
    /// Pire cas d'un passage complet (refusé AVANT tout envoi s'il dépasse le plafond).
    public static func pireCasPassage(durations: [Int], estIn: Int, maxOut: Int = sparkMaxOut) -> Double {
        durations.reduce(0.0) { $0 + pireCasTour(durationMs: $1, estIn: estIn, maxOut: maxOut) }
    }

    /// Sans « repetitions » dans la demande : assez de tours pour ≥ 60 s de parole simulée (avec les réponses, ≈ 2 min de conversation).
    public static func repetitionsParDefaut(inputMs: Int) -> Int {
        if inputMs <= 0 { return 1 }
        return min(3, max(1, Int((60_000.0 / Double(inputMs)).rounded(.up))))
    }

    /// Barge-in prévus (indices 1..n) → type : alternance génération / synthèse / génération…
    public static func planBargeIn(_ indices: [Int], count: Int) -> [Int: String] {
        var out: [Int: String] = [:]
        var k: Int = 0
        for i in indices.sorted() where i >= 1 && i < count {   // jamais le dernier tour : il faut un tour suivant pour la reprise
            out[i] = k % 2 == 0 ? "generation" : "synthese"
            k += 1
        }
        return out
    }

    /// Découpe en continu : phrases prêtes du tampon (même règle que la voix live, VLSentences).
    public static func phrasesPretes(_ buf: String) -> (ready: [String], rest: String) { VLSentences.extract(buf) }

    /// Fin du flux : le reliquat devient la dernière phrase s'il reste de la place.
    public static func reliquat(_ rest: String) -> String? {
        let t: String = VLSentences.clean(rest).trimmingCharacters(in: .whitespacesAndNewlines)
        return t.count >= 2 ? t : nil
    }

    // MARK: - Entrées

    /// Prend la demande (renommée .done.json) ; nil si aucune. Contenu JSON facultatif.
    public static func takeRequest(root: String) -> [String: Any]? {
        let fm: FileManager = FileManager.default
        var req: String = ""
        for n in [requestName, requestName + ".json"] where fm.fileExists(atPath: root + "/dormant/" + n) { req = root + "/dormant/" + n; break }
        if req.isEmpty { return nil }
        let cfg: [String: Any] = (try? Data(contentsOf: URL(fileURLWithPath: req))).flatMap { parseJSON($0) } ?? [:]
        let done: String = root + "/dormant/" + requestName + ".done.json"
        try? fm.removeItem(atPath: done)
        try? fm.moveItem(atPath: req, toPath: done)
        return cfg
    }

    /// manifest.json d'abord ; sinon tous les .wav du dossier (langue tirée du suffixe _en/_fr, texte inconnu → WER non calculé).
    public static func chargerItems(dir: String) -> (items: [VoixTestItem], bargeIn: [Int], erreur: String?) {
        let fm: FileManager = FileManager.default
        var items: [VoixTestItem] = []
        var barge: [Int] = []
        if let d = try? Data(contentsOf: URL(fileURLWithPath: dir + "/manifest.json")), let o = parseJSON(d) {
            for e in (o["items"] as? [[String: Any]]) ?? [] {
                let f: String = (e["fichier"] as? String) ?? ""
                if f.isEmpty || f.contains("/") || !fm.fileExists(atPath: dir + "/" + f) { continue }
                items.append(VoixTestItem(fichier: f, langue: (e["langue"] as? String) ?? "fr", texte: (e["texte"] as? String) ?? ""))
            }
            barge = ((o["barge_in"] as? [Any]) ?? []).compactMap { ($0 as? NSNumber)?.intValue }
        }
        if items.isEmpty {
            let names: [String] = ((try? fm.contentsOfDirectory(atPath: dir)) ?? []).filter { $0.lowercased().hasSuffix(".wav") }.sorted()
            for n in names { items.append(VoixTestItem(fichier: n, langue: n.lowercased().contains("_en") ? "en" : "fr", texte: "")) }
        }
        if items.isEmpty { return ([], [], "aucun WAV dans " + dir) }
        return (items, barge, nil)
    }

    // MARK: - Synthèse des résultats

    /// Critères du dossier (2 min de conversation, 3 barge-in, premier audio < 1 s) à partir des tours.
    public static func criteres(tours: [[String: Any]], conversationMs: Int) -> [String: Any] {
        func ints(_ k: String) -> [Double] { tours.compactMap { ($0[k] as? Int).map { Double($0) } }.filter { $0 >= 0 } }
        let firsts: [Double] = ints("premier_audio_ms")
        let barges: [[String: Any]] = tours.compactMap { $0["barge_in"] as? [String: Any] }
        let bargeOK: Int = barges.filter { ($0["arret_ok"] as? Bool) == true }.count
        let med: Double? = centile(firsts, 0.5)
        var c: [String: Any] = [
            "conversation_ms": conversationMs, "conversation_2_min": conversationMs >= 120_000,
            "barge_in_reussis": bargeOK, "barge_in_3": bargeOK >= 3,
            "premier_audio_sous_1s_mediane": med.map { $0 < 1000 } ?? false,
            "premier_audio_sous_1s_tours": firsts.filter { $0 < 1000 }.count, "tours_mesures": firsts.count,
        ]
        if let m = med { c["premier_audio_mediane_ms"] = Int(m.rounded()) }
        return c
    }

    /// Trace « dictation » au format demo/traces (tools/demo/build_traces.py) : lignes de journal nettoyées, AUCUN texte transcrit.
    public static func traceDictee(events: [[String: Any]]) -> [String: Any] {
        let keep: Set<String> = ["ts", "fournisseur", "hote", "modele", "meta", "statut", "source", "specialite", "mode", "cout_usd", "ms", "duree_audio_ms", "raison"]
        let ev: [[String: Any]] = events.map { e in e.filter { keep.contains($0.key) } }
        let ok: Bool = ev.contains { ($0["statut"] as? String) == "ok" }
        return ["id": "dictation", "recorded": ok,
                "source": "real Nova run (dormant/VOIX_TEST_REQUEST, synthetic public test phrases), sanitised: no transcript text",
                "title": "Dictation — Muse Voice Transcribe (muse-voice-transcribe-1.0), POST /v1/asr/transcribe",
                "model": "muse-voice-transcribe-1.0", "events": ev,
                "note": ok ? "" : "No successful dictation in this run: see releves/diag/voix_test.json for the error. Transcript text is never copied."]
    }
}

/// Drapeau d'annulation partagé (flux Spark, synthèse, barge-in).
final class VoixTestFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var v: Bool = false
    private var at: Date? = nil
    func set() { lock.lock(); if !v { v = true; at = Date() }; lock.unlock() }
    func get() -> Bool { lock.lock(); defer { lock.unlock() }; return v }
    func when() -> Date? { lock.lock(); defer { lock.unlock() }; return at }
}

/// Mesures d'un tour, écrites par le fil du flux, la file de synthèse et le fil du banc.
final class VoixTestTurnState: @unchecked Sendable {
    let lock = NSLock()
    var text: String = ""
    var buf: String = ""
    var firstToken: Date? = nil
    var firstSentence: Date? = nil
    var firstAudio: Date? = nil
    var phrases: [String] = []
    var pcm: Data = Data()
    var renders: [LocalVoiceRender] = []
    var ttsStoppedAt: Date? = nil
}

extension NovaApp {
    /// Appelé par la boucle de fond (Feat_BancAgent, toutes les 30 s).
    func voixTestPoll(root: String) {
        guard let cfg = VoixTest.takeRequest(root: root) else { return }
        VoixTest.running.lock.lock()
        if VoixTest.running.on { VoixTest.running.lock.unlock(); return }
        VoixTest.running.on = true
        VoixTest.running.lock.unlock()
        Thread.detachNewThread { [weak self] in
            defer { VoixTest.running.lock.lock(); VoixTest.running.on = false; VoixTest.running.lock.unlock() }
            self?.voixTestRun(cfg, root: root)
        }
    }

    func voixTestRun(_ cfg: [String: Any], root: String) {
        LLMSpend.setInteractive(false)
        LLMSpend.setBench(true)   // voie « banc » : comptée à part, plafond du jour des bancs (SpendPolicy)
        defer { LLMSpend.setBench(false) }
        let out: URL = Paths.diagFile("voix_test.json")
        let audioOut: URL = Paths.diagFile("voix_test")
        try? FileManager.default.createDirectory(at: audioOut, withIntermediateDirectories: true)
        let started: String = nowISO()
        let t0Run: Date = Date()
        var doc: [String: Any] = ["started": started, "etat": "en cours", "plafond_usd": VoixTest.plafondUSD, "meta_only": MetaOnly.enabled]
        func save() { try? jsonData(doc).write(to: out) }
        save()
        func fin(_ statut: String, _ why: String) { doc["etat"] = "terminé"; doc["statut"] = statut; doc["raison"] = why; doc["finished"] = nowISO(); save() }

        // Entrées
        let dir: String = root + "/dormant/voix_test"
        let ld = VoixTest.chargerItems(dir: dir)
        if let e = ld.erreur { fin("entree_absente", e); return }
        var items: [VoixTestItem] = ld.items
        let lim: Int = (cfg["limite"] as? NSNumber)?.intValue ?? items.count
        items = Array(items.prefix(max(1, min(lim, 40))))
        let baseMs: Int = items.reduce(0) { (acc: Int, it: VoixTestItem) -> Int in
            acc + (Voice.wavInfo((try? Data(contentsOf: URL(fileURLWithPath: dir + "/" + it.fichier))) ?? Data())?.durationMs ?? 0)
        }
        let reps: Int = max(1, min(3, (cfg["repetitions"] as? NSNumber)?.intValue ?? VoixTest.repetitionsParDefaut(inputMs: baseMs)))
        if reps > 1 { let base: [VoixTestItem] = items; items = (0..<reps).flatMap { _ in base } }
        let bargeIdx: [Int] = ((cfg["barge_in"] as? [Any])?.compactMap { ($0 as? NSNumber)?.intValue }) ?? (ld.bargeIn.isEmpty ? [2, 5, 8] : ld.bargeIn)
        let plan: [Int: String] = VoixTest.planBargeIn(bargeIdx, count: items.count)
        var audios: [Data] = []
        var durs: [Int] = []
        for it in items {
            let d: Data = (try? Data(contentsOf: URL(fileURLWithPath: dir + "/" + it.fichier))) ?? Data()
            audios.append(d)
            durs.append(Voice.wavInfo(d)?.durationMs ?? 0)
        }
        doc["entrees"] = ["dossier": "dormant/voix_test", "fichiers": items.count, "duree_audio_ms": durs.reduce(0, +), "barge_in_prevus": plan.keys.sorted()] as [String: Any]

        // Cerveau et budget (échec fermé, AVANT tout envoi)
        guard router.usable("spark-1.3"), let spec = router.brains.first(where: { $0.id == "spark-1.3" }) else {
            fin("spark_indisponible", "Spark 1.3 inutilisable : " + router.whyUnusable("spark-1.3")); return
        }
        let estIn: Int = TokenEst.of(VoixTest.system) + 60
        let pire: Double = VoixTest.pireCasPassage(durations: durs, estIn: estIn)
        doc["budget"] = ["pire_cas_usd": VoixTest.arrondi(pire), "plafond_usd": VoixTest.plafondUSD] as [String: Any]
        if pire > VoixTest.plafondUSD {
            fin("budget_refuse", String(format: "pire cas %.4f $ > plafond %.2f $ : rien n'est envoyé", pire, VoixTest.plafondUSD)); return
        }

        // Préchauffage de la voix locale (mesuré : c'est le coût à froid que la première phrase payait avant)
        let warm0 = LocalVoice.shared.warmState()
        var warmDoc: [String: Any] = ["deja_chaude": warm0.warm, "prechauffage_demarrage_ms": warm0.ms]
        let langs: [String] = Array(Set(items.map { $0.langue.hasPrefix("en") ? "en" : "fr" })).sorted()
        for l in langs { warmDoc["prechauffage_" + l + "_ms"] = LocalVoice.shared.prewarm(language: l) }
        doc["synthese_prechauffage"] = warmDoc
        let poolBefore: Int = HTTPPool.shared.servedCount()

        var tours: [[String: Any]] = []
        var dicteeEvents: [[String: Any]] = []
        var cumul: Double = 0, coutSTT: Double = 0, coutSpark: Double = 0
        var statut: String = "ok", raison: String = ""
        var prevCancelAt: Date? = nil
        var conversationMs: Int = 0
        let journalLock = NSLock()
        let runId: String = "voix-test-" + String(UUID().uuidString.prefix(8)).lowercased()

        for (idx, it) in items.enumerated() {
            let n: Int = idx + 1
            let lang: String = it.langue.hasPrefix("en") ? "en" : "fr"
            var tour: [String: Any] = ["n": n, "fichier": it.fichier, "langue": lang, "duree_audio_ms": durs[idx]]
            if VoixTest.arrondi(cumul + VoixTest.pireCasTour(durationMs: durs[idx], estIn: estIn)) > VoixTest.plafondUSD {
                statut = "plafond_passage"; raison = "plafond de 0,50 $ atteint avant le tour \(n)"; break
            }
            // Réservation Spark AVANT la dictée du tour : un refus arrête tout, rien n'est envoyé (ni dictée ni Spark).
            let pf: Preflight = LLMSpend.preflight(spec: spec, estIn: estIn, maxOut: VoixTest.sparkMaxOut, lane: LLMSpend.currentLane(background: false), task: runId + "-\(n)")
            guard let tk = pf.ticket else {
                var why: String = "réservation impossible"
                if case .refused(let w) = pf { why = w }
                MetaOnly.record(provider: "meta", model: spec.model, meta: true, status: "bloque", source: "voix_test", host: "api.meta.ai", reason: "budget : " + why, brain: spec.id, specialite: "voix")
                statut = "budget_refuse"; raison = why; break
            }
            let tTurn: Date = Date()
            // (a) Dictée
            let stt = voice.transcribeMeta(audio: audios[idx], mime: "audio/wav", language: lang)
            let sttMs: Int = Int(Date().timeIntervalSince(tTurn) * 1000)
            let cSTT: Double = stt.text != nil ? VoixTest.coutSTT(durationMs: durs[idx]) : 0
            coutSTT += cSTT; cumul += cSTT
            var ev: [String: Any] = ["ms": sttMs, "duree_audio_ms": durs[idx], "mode": "voix_test", "cout_usd": VoixTest.arrondi(cSTT), "tarif": "0,18 $ par heure d'audio"]
            if idx == 0 { ev["connexion"] = "froide (premier appel du passage)" }
            journalLock.lock()
            MetaOnly.record(provider: "meta", model: "muse-voice-transcribe-1.0", meta: true, status: stt.text != nil ? "ok" : "echec", source: "voix_test",
                            host: "api.meta.ai", reason: stt.error ?? "", specialite: "dictee", extra: ev)
            journalLock.unlock()
            var dev: [String: Any] = ev
            dev["ts"] = nowISO(); dev["fournisseur"] = "meta"; dev["hote"] = "api.meta.ai"; dev["modele"] = "muse-voice-transcribe-1.0"; dev["meta"] = true
            dev["statut"] = stt.text != nil ? "ok" : "echec"; dev["source"] = "voix_test"; dev["specialite"] = "dictee"
            if let e = stt.error { dev["raison"] = String(e.prefix(200)) }
            dicteeEvents.append(dev)
            tour["stt_ms"] = sttMs
            guard let heard = stt.text else {
                if let id = tk.id { LLMSpend.ledger()?.release(id, reason: "voix_test : dictée en échec, rien envoyé à Spark") }
                tour["statut"] = "echec_dictee"; tour["erreur"] = String((stt.error ?? "").prefix(300))
                tours.append(tour); doc["tours"] = tours; save()
                statut = "echec_dictee"; raison = stt.error ?? "dictée sans texte"
                if n == 1 { break }   // premier tour en échec : clé ou route absente, inutile d'insister
                continue
            }
            tour["transcription"] = heard
            tour["texte_source"] = it.texte
            if let w = VoixTest.wer(reference: it.texte, hypothese: heard) { tour["wer"] = (w * 1000).rounded() / 1000 }

            // (b) Spark en flux + (c) synthèse en continu phrase par phrase
            let barge: String? = plan[n]
            let flag: VoixTestFlag = VoixTestFlag()
            let st: VoixTestTurnState = VoixTestTurnState()
            let ttsQ: DispatchQueue = DispatchQueue(label: "nova.voixtest.tts.\(n)")
            let group: DispatchGroup = DispatchGroup()
            let vid: String = settings.get("voix_locale_id", "")
            func enqueue(_ phrase: String) {
                group.enter()
                ttsQ.async {
                    defer { group.leave() }
                    if flag.get() { return }
                    let r: LocalVoiceRender = LocalVoice.shared.renderDetailed(text: phrase, voiceId: vid, language: lang, cancel: { flag.get() }) { (d: Data) -> Bool in
                        st.lock.lock()
                        if st.firstAudio == nil { st.firstAudio = Date() }
                        st.pcm.append(d)
                        st.lock.unlock()
                        if barge == "synthese" { flag.set() }   // barge-in : interrompre dès le premier son
                        return !flag.get()
                    }
                    st.lock.lock(); st.renders.append(r); if flag.get() && st.ttsStoppedAt == nil { st.ttsStoppedAt = Date() }; st.lock.unlock()
                }
            }
            var uin: Int = 0, uout: Int = 0
            var failure: BrainFailure? = nil
            let tSpark: Date = Date()
            do {
                try router.runner.stream(spec, messages: [ChatMsg("user", heard)], system: VoixTest.system, maxTokens: VoixTest.sparkMaxOut, mode: "voice",
                                         firstTokenTimeout: 15, cancel: { flag.get() },
                                         onDelta: { (d: String) in
                                             var ready: [String] = []
                                             st.lock.lock()
                                             if st.firstToken == nil { st.firstToken = Date() }
                                             st.text += d
                                             st.buf += d
                                             let ex = VoixTest.phrasesPretes(st.buf)
                                             st.buf = ex.rest
                                             for s in ex.ready where st.phrases.count < VoixTest.phrasesMax {
                                                 st.phrases.append(s); ready.append(s)
                                                 if st.firstSentence == nil { st.firstSentence = Date() }
                                             }
                                             st.lock.unlock()
                                             for s in ready { enqueue(s) }
                                             if barge == "generation" { flag.set() }   // barge-in : interrompre dès le premier jeton
                                         },
                                         onUsage: { uin = $0; uout = $1 })
            } catch let f as BrainFailure {
                failure = f
            } catch {
                failure = BrainFailure(kind: .other, message: error.localizedDescription)
            }
            let tSparkEnd: Date = Date()
            st.lock.lock()
            if !flag.get(), st.phrases.count < VoixTest.phrasesMax, let r = VoixTest.reliquat(st.buf) {
                st.phrases.append(r); if st.firstSentence == nil { st.firstSentence = Date() }
                st.lock.unlock(); enqueue(r)
            } else { st.lock.unlock() }
            _ = group.wait(timeout: .now() + 40)
            let canceled: Bool = flag.get()
            st.lock.lock()
            let answer: String = st.text
            let firstTok: Date? = st.firstToken, firstSent: Date? = st.firstSentence, firstAud: Date? = st.firstAudio
            let renders: [LocalVoiceRender] = st.renders
            let pcm: Data = st.pcm
            let ttsStop: Date? = st.ttsStoppedAt
            let phrases: [String] = st.phrases
            st.lock.unlock()

            // Coût Spark : rapproché de l'usage rapporté (mesuré), sinon estimé (jamais sous-compté)
            let produced: Bool = !answer.isEmpty
            var cSpark: Double = 0
            var sparkStatut: String = "ok"
            if let f = failure, !(canceled && f.kind == .canceled) {
                LLMSpend.abandon(tk, kind: f.kind, produced: produced)
                sparkStatut = "echec"
                tour["erreur_spark"] = String(f.message.prefix(300))
                if produced { cSpark = VoixTest.coutSpark(inTok: estIn, outTok: VoixTest.sparkMaxOut) }
            } else {
                let inT: Int = uin > 0 ? uin : estIn
                let outT: Int = uout > 0 ? uout : max(TokenEst.of(answer), canceled ? VoixTest.sparkMaxOut : 1)
                LLMSpend.record(spec.id, inTok: inT, outTok: outT, cacheRead: 0, cacheWrite: 0, background: false, spec: spec, ticket: tk, measured: uin > 0 || uout > 0)
                cSpark = VoixTest.coutSpark(inTok: inT, outTok: outT)
                tour["jetons_entree"] = inT; tour["jetons_sortie"] = outT; tour["jetons_mesures"] = uin > 0 || uout > 0
                if canceled { sparkStatut = "interrompu" }
            }
            coutSpark += cSpark; cumul += cSpark
            let sparkMs: Int = Int(tSparkEnd.timeIntervalSince(tSpark) * 1000)
            let ftMs: Int = firstTok.map { Int($0.timeIntervalSince(tSpark) * 1000) } ?? -1
            journalLock.lock()
            MetaOnly.record(provider: "meta", model: spec.model, meta: true, status: sparkStatut, source: "voix_test", host: "api.meta.ai",
                            reason: failure?.message ?? "", brain: spec.id, specialite: "voix",
                            extra: ["mode": "voice", "reasoning_effort": "minimal", "ms": sparkMs, "premier_jeton_ms": ftMs,
                                    "jetons_entree": (tour["jetons_entree"] as? Int) ?? 0, "jetons_sortie": (tour["jetons_sortie"] as? Int) ?? 0,
                                    "cout_usd": VoixTest.arrondi(cSpark)])
            journalLock.unlock()
            tour["spark_premier_jeton_ms"] = ftMs
            tour["spark_premiere_phrase_ms"] = firstSent.map { Int($0.timeIntervalSince(tSpark) * 1000) } ?? -1
            tour["spark_total_ms"] = sparkMs
            tour["spark_statut"] = sparkStatut
            tour["reponse"] = String(answer.prefix(600))
            tour["phrases_dites"] = phrases.count
            tour["tts"] = renders.map { (r: LocalVoiceRender) -> [String: Any] in
                ["premier_tampon_ms": r.firstBufferMs, "total_ms": r.totalMs, "audio_ms": r.audioMs, "voix": r.voice, "fin_naturelle": r.finishedNaturally,
                 "fin_par_filet_2s": r.endedByIdleNet, "synthetiseur_chaud": r.warmSynth, "ok": r.ok, "erreur": r.error ?? ""]
            }
            tour["tts_premier_tampon_ms"] = renders.first?.firstBufferMs ?? -1
            tour["premier_audio_ms"] = firstAud.map { Int($0.timeIntervalSince(tTurn) * 1000) } ?? -1
            tour["audio_sortie_ms"] = pcm.count / 48
            tour["cout_usd"] = VoixTest.arrondi(cSTT + cSpark)
            if !pcm.isEmpty {
                let name: String = String(format: "%02d_reponse.wav", n)
                try? LocalVoice.wav(pcm16: pcm, rate: 24000).write(to: audioOut.appendingPathComponent(name))
                tour["fichier_audio"] = "releves/diag/voix_test/" + name
            }
            conversationMs += durs[idx] + pcm.count / 48
            // Reprise après le barge-in du tour précédent : de l'arrêt au premier audio de CE tour
            if let pc = prevCancelAt {
                tour["reprise_apres_barge_in_ms"] = firstAud.map { Int($0.timeIntervalSince(pc) * 1000) } ?? -1
                if var last = tours.last, var b = last["barge_in"] as? [String: Any] {
                    b["reprise_ms"] = tour["reprise_apres_barge_in_ms"]
                    b["reprise_ok"] = firstAud != nil
                    last["barge_in"] = b
                    tours[tours.count - 1] = last
                }
                prevCancelAt = nil
            }
            if let b = barge {
                let at: Date? = flag.when()
                var bi: [String: Any] = ["type": b, "declenche": at != nil]
                if let a = at {
                    let stopEnd: Date = b == "generation" ? tSparkEnd : (ttsStop ?? tSparkEnd)
                    let arret: Int = max(0, Int(stopEnd.timeIntervalSince(a) * 1000))
                    bi["arret_ms"] = arret
                    bi["arret_spark_ms"] = max(0, Int(tSparkEnd.timeIntervalSince(a) * 1000))
                    if let t = ttsStop { bi["arret_synthese_ms"] = max(0, Int(t.timeIntervalSince(a) * 1000)) }
                    bi["arret_ok"] = arret < 1500
                    prevCancelAt = a
                } else { bi["arret_ok"] = false }
                tour["barge_in"] = bi
            }
            tour["statut"] = sparkStatut == "echec" ? "echec_spark" : (firstAud == nil && !canceled ? "sans_audio" : "ok")
            tours.append(tour)
            doc["tours"] = tours
            doc["cout_usd"] = ["total": VoixTest.arrondi(cumul), "voice_transcribe": VoixTest.arrondi(coutSTT), "spark": VoixTest.arrondi(coutSpark)] as [String: Any]
            save()
        }

        // Agrégats par étape
        func col(_ k: String, _ only: (([String: Any]) -> Bool)? = nil) -> [Double] {
            tours.filter { only?($0) ?? true }.compactMap { ($0[k] as? Int).map { Double($0) } }
        }
        let normal: ([String: Any]) -> Bool = { $0["barge_in"] == nil }
        var etapes: [String: Any] = [:]
        etapes["dictee_voice_transcribe"] = VoixTest.resume(col("stt_ms"))
        etapes["spark_premier_jeton"] = VoixTest.resume(col("spark_premier_jeton_ms"))
        etapes["spark_premiere_phrase"] = VoixTest.resume(col("spark_premiere_phrase_ms", normal))
        etapes["spark_total"] = VoixTest.resume(col("spark_total_ms", normal))
        etapes["synthese_premier_tampon"] = VoixTest.resume(col("tts_premier_tampon_ms"))
        etapes["premier_audio_bout_en_bout"] = VoixTest.resume(col("premier_audio_ms"))
        let bis: [[String: Any]] = tours.compactMap { $0["barge_in"] as? [String: Any] }
        etapes["barge_in_arret"] = VoixTest.resume(bis.compactMap { ($0["arret_ms"] as? Int).map { Double($0) } })
        etapes["barge_in_reprise"] = VoixTest.resume(bis.compactMap { ($0["reprise_ms"] as? Int).map { Double($0) } })
        doc["etapes"] = etapes
        let wers: [Double] = tours.compactMap { $0["wer"] as? Double }
        if !wers.isEmpty {
            doc["wer"] = ["moyen": (wers.reduce(0, +) / Double(wers.count) * 1000).rounded() / 1000, "median": ((VoixTest.centile(wers, 0.5) ?? 0) * 1000).rounded() / 1000,
                          "n": wers.count, "note": "approximatif : mots en minuscules, ponctuation retirée, accents conservés ; « 3 » ≠ « three »"] as [String: Any]
        }
        let pooled: Int = HTTPPool.shared.servedCount() - poolBefore
        doc["connexion_http"] = ["requetes_session_partagee": pooled, "hote": "api.meta.ai",
                                 "note": "dictée et Spark passent par la même session HTTP (connexion réutilisée) ; le 1er appel du passage paie la poignée de main"] as [String: Any]
        let crit: [String: Any] = VoixTest.criteres(tours: tours, conversationMs: conversationMs)
        doc["criteres"] = crit
        doc["cout_usd"] = ["total": VoixTest.arrondi(cumul), "voice_transcribe": VoixTest.arrondi(coutSTT), "spark": VoixTest.arrondi(coutSpark),
                           "tarifs": "Voice Transcribe 0,18 $/h d'audio ; Spark 1.3 1,25 $ / 4,25 $ par M de jetons ; synthèse locale gratuite"] as [String: Any]
        doc["ms"] = Int(Date().timeIntervalSince(t0Run) * 1000)
        doc["hors_mesure"] = ["détection de fin de parole (VAD) et micro réel", "latence du haut-parleur et lecture", "qualité perçue de la voix et de la réponse"]
        // Traces au format demo/traces
        let traces: URL = Paths.diagFile("voix_test_traces")
        try? FileManager.default.createDirectory(at: traces, withIntermediateDirectories: true)
        try? jsonData(VoixTest.traceDictee(events: dicteeEvents)).write(to: traces.appendingPathComponent("dictation.json"))
        let chainOK: Bool = tours.contains { ($0["statut"] as? String) == "ok" && (($0["premier_audio_ms"] as? Int) ?? -1) >= 0 }
        let chain: [String: Any] = ["id": "voice_chain", "recorded": chainOK,
                                    "source": "real Nova run (dormant/VOIX_TEST_REQUEST, synthetic public test phrases), sanitised",
                                    "title": "Voice chain — Muse Voice Transcribe → Muse Spark 1.3 (reasoning_effort none) → on-device AVSpeechSynthesizer",
                                    "started": started, "finished": nowISO(), "stages": etapes, "criteria": crit,
                                    "cost_usd": VoixTest.arrondi(cumul)]
        try? jsonData(chain).write(to: traces.appendingPathComponent("voice_chain.json"))
        if statut == "ok" && tours.isEmpty { statut = "aucun_tour" }
        fin(statut, raison)
    }
}
