import Foundation
#if canImport(Speech) && canImport(AVFoundation) && os(macOS)
import Speech
import AVFoundation
#endif

/// 01/11 (voix-rapide) — BANC VOIX, MODE « STREAMING SIMULÉ » : le chemin RÉEL de la voix classique, sans micro ni humain.
/// Chaque WAV est découpé en paquets de 100 ms poussés EN TEMPS RÉEL dans SFSpeechRecognizer (comme le tap du micro) ; à la fin
/// de l'audio (= fin de parole), le PARTIEL est envoyé à Spark dès qu'il est stable (≤ 250 ms sans nouveau partiel, plafond 600 ms),
/// sans attendre de finalisation ; la première clause (virgule ou ≥ 6 mots) part en synthèse ; un accusé « Mm. » / « D'accord, »
/// pré-rendu est ajouté si rien n'a sonné 700 ms après la fin de parole ; la connexion api.meta.ai est préchauffée à l'ouverture
/// du « micro » (début de chaque tour). Mesures depuis la FIN DE L'AUDIO : premier son (accusé ou réponse), premier son de la
/// réponse, partiel stable, premier jeton. Hors mesure : VAD (600 ms de silence dans la vraie voix), haut-parleur.
/// Aucune dictée Meta dans ce mode (la voix classique transcrit sur le Mac) : seul Spark est facturé.
/// SFSpeech doit être DÉJÀ autorisé pour Nova : le banc ne demande jamais l'autorisation (aucune fenêtre système en son absence).
/// (Fichier hors Feat_* : cliquet de verify.sh, ≤ 89 fichiers Feat_.)
extension VoixTest {
    /// Paquets de `ms` millisecondes sur des échantillons PCM16 (octets). Pur, testé.
    public static func paquets(dataBytes: Int, rate: Int, ms: Int = 100) -> [Range<Int>] {
        let step: Int = max(2, (rate * ms / 1000) * 2)
        var out: [Range<Int>] = []
        var o: Int = 0
        while o < dataBytes { out.append(o..<min(dataBytes, o + step)); o += step }
        return out
    }
    /// Locale SFSpeech d'un tour du banc (langue de l'élément).
    public static func localeStreaming(_ langue: String) -> String { langue.hasPrefix("en") ? "en-US" : "fr-FR" }
}

/// Partiel SFSpeech partagé (rappel du recognizer ↔ fil du banc).
final class VoixBancPartiel: @unchecked Sendable {
    let lock = NSLock()
    var text: String = ""
    var lastAt: Date? = nil
    var updates: Int = 0
    var error: String? = nil
    func set(_ t: String) { lock.lock(); if t != text { text = t; lastAt = Date(); updates += 1 }; lock.unlock() }
    func snap() -> (String, Date?, Int, String?) { lock.lock(); defer { lock.unlock() }; return (text, lastAt, updates, error) }
    func fail(_ e: String) { lock.lock(); if error == nil { error = e }; lock.unlock() }
}

extension NovaApp {
    /// Mode streaming simulé. Rend le bloc « streaming » de voix_test.json et le coût Spark dépensé.
    func voixTestStreaming(items: [VoixTestItem], audios: [Data], plan: [Int: String], spec: BrainSpec, estIn: Int,
                           dejaDepense: Double, runId: String, audioOut: URL, vitesse: Double) -> (doc: [String: Any], cout: Double) {
        var doc: [String: Any] = ["mode": "streaming simulé (SFSpeech en temps réel, partiel → Spark)", "tours": [[String: Any]]()]
        #if canImport(Speech) && canImport(AVFoundation) && os(macOS)
        guard SFSpeechRecognizer.authorizationStatus() == .authorized else {
            doc["statut"] = "indisponible"
            doc["raison"] = "reconnaissance vocale (SFSpeech) non autorisée pour Nova — le banc ne la demande pas ; elle s'accorde au premier lancement de la voix live"
            return (doc, 0)
        }
        let surAppareil: Bool = VoixReglages.surAppareil()
        doc["sfspeech_sur_appareil"] = surAppareil
        doc["vitesse"] = vitesse
        let vid: String = settings.get("voix_locale_id", "")
        // Accusés rendus d'avance (comme à l'ouverture du micro de la vraie voix)
        for l in ["fr", "en"] { for p in VoixRapide.accuses(langue: l) { _ = LocalVoice.shared.pcmAccuse(p, language: VoixRapide.langueVoix(l), voiceId: vid) } }
        let contextual: [String] = VoixVocab.effectif()
        var tours: [[String: Any]] = []
        var cumul: Double = 0
        var prevAcked: Bool = false
        var lastAck: String = ""
        var prevCancelAt: Date? = nil
        var bargeCarry: String? = nil
        for (idx, it) in items.enumerated() {
            let n: Int = idx + 1
            let lang: String = it.langue.hasPrefix("en") ? "en" : "fr"
            var tour: [String: Any] = ["n": n, "fichier": it.fichier, "langue": lang]
            if VoixTest.arrondi(dejaDepense + cumul + VoixTest.coutSpark(inTok: estIn, outTok: VoixTest.sparkMaxOut)) > VoixTest.plafondUSD {
                doc["statut"] = "plafond_passage"; break
            }
            guard let w = Voice.wavInfo(audios[idx]), w.format == 1, w.bits == 16, w.channels == 1, w.dataOffset + w.dataBytes <= audios[idx].count,
                  let fmt = AVAudioFormat(standardFormatWithSampleRate: Double(w.rate), channels: 1) else {
                tour["statut"] = "wav_non_pris_en_charge"; tours.append(tour); continue
            }
            guard let rec = SFSpeechRecognizer(locale: Locale(identifier: VoixTest.localeStreaming(lang))), rec.isAvailable else {
                tour["statut"] = "sfspeech_indisponible"; tours.append(tour); continue
            }
            let pf: Preflight = LLMSpend.preflight(spec: spec, estIn: estIn, maxOut: VoixTest.sparkMaxOut, lane: LLMSpend.currentLane(background: false), task: runId + "-s\(n)")
            guard let tk = pf.ticket else {
                var why: String = "réservation impossible"
                if case .refused(let wy) = pf { why = wy }
                doc["statut"] = "budget_refuse"; doc["raison"] = why; break
            }
            // « Micro ouvert » : connexion api.meta.ai préchauffée pendant que l'utilisateur parle
            VoixRapide.prechaufferMeta(intervalle: 5)
            let part: VoixBancPartiel = VoixBancPartiel()
            let req = SFSpeechAudioBufferRecognitionRequest()
            req.shouldReportPartialResults = true
            req.taskHint = .dictation
            req.addsPunctuation = true
            req.contextualStrings = contextual
            if rec.supportsOnDeviceRecognition && surAppareil { req.requiresOnDeviceRecognition = true }
            let task: SFSpeechRecognitionTask = rec.recognitionTask(with: req) { (res: SFSpeechRecognitionResult?, err: Error?) in
                if let r = res { part.set(r.bestTranscription.formattedString) } else if let e = err { part.fail(e.localizedDescription) }
            }
            // Audio poussé au rythme réel (paquets de 100 ms)
            let base: Int = audios[idx].startIndex + w.dataOffset
            audios[idx].withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
                for r in VoixTest.paquets(dataBytes: w.dataBytes, rate: w.rate) {
                    let frames: Int = r.count / 2
                    guard frames > 0, let buf = AVAudioPCMBuffer(pcmFormat: fmt, frameCapacity: AVAudioFrameCount(frames)), let dst = buf.floatChannelData?[0] else { continue }
                    buf.frameLength = AVAudioFrameCount(frames)
                    for i in 0..<frames {
                        let o: Int = base - audios[idx].startIndex + r.lowerBound + i * 2
                        let v: Int16 = Int16(bitPattern: UInt16(raw[o]) | (UInt16(raw[o + 1]) << 8))
                        dst[i] = Float(v) / 32768.0
                    }
                    req.append(buf)
                    Thread.sleep(forTimeInterval: 0.1 / max(0.25, vitesse))
                }
            }
            let tEnd: Date = Date()   // fin de parole simulée
            // Partiel stable (aucun nouveau partiel depuis 250 ms), attente plafonnée à 600 ms (la vraie voix a déjà 600 ms de VAD)
            while true {
                let (_, lastAt, _, _) = part.snap()
                let sinceP: Int = lastAt.map { Int(Date().timeIntervalSince($0) * 1000) } ?? 100_000
                let sinceE: Int = Int(Date().timeIntervalSince(tEnd) * 1000)
                if VoixRapide.partielStable(depuisDernierPartielMs: sinceP, depuisFinParoleMs: sinceE, stableMs: 250, plafondMs: 600) { break }
                Thread.sleep(forTimeInterval: 0.02)
            }
            let (heard0, _, updates, sttErr) = part.snap()
            task.cancel(); req.endAudio()
            let heard: String = heard0.trimmingCharacters(in: .whitespacesAndNewlines)
            let tGo: Date = Date()
            tour["attente_partiel_ms"] = Int(tGo.timeIntervalSince(tEnd) * 1000)
            tour["partiels_recus"] = updates
            tour["transcription_partielle"] = heard
            tour["texte_source"] = it.texte
            if let wr = VoixTest.wer(reference: it.texte, hypothese: heard) { tour["wer"] = (wr * 1000).rounded() / 1000 }
            guard !heard.isEmpty else {
                if let id = tk.id { LLMSpend.ledger()?.release(id, reason: "voix_test streaming : partiel vide, rien envoyé à Spark") }
                tour["statut"] = "partiel_vide"; if let e = sttErr { tour["erreur"] = String(e.prefix(200)) }
                tours.append(tour); continue
            }
            // Spark en flux + première clause + synthèse en continu + accusé
            let barge: String? = plan[n] ?? bargeCarry
            bargeCarry = nil
            let flag: VoixTestFlag = VoixTestFlag()
            let st: VoixTestTurnState = VoixTestTurnState()
            let ttsQ: DispatchQueue = DispatchQueue(label: "nova.voixtest.stream.tts.\(n)")
            let group: DispatchGroup = DispatchGroup()
            var ackAt: Date? = nil, ackPcm: Data = Data(), ackPhrase: String = ""
            let ackLock: NSLock = NSLock()
            let ackGroup: DispatchGroup = DispatchGroup()
            let doAck: Bool = settings.get("voix_accuse", true)
            if doAck && !prevAcked {
                ackGroup.enter()
                let phrase: String = VoixRapide.phraseAccuse(langue: VoixRapide.langue(heard, defaut: lang), precedente: lastAck)
                DispatchQueue.global(qos: .userInitiated).asyncAfter(deadline: .now() + .milliseconds(max(0, VoixRapide.seuilAccuseMs - Int(Date().timeIntervalSince(tEnd) * 1000)))) {
                    defer { ackGroup.leave() }
                    st.lock.lock(); let dejaSon: Bool = st.firstAudio != nil; st.lock.unlock()
                    guard VoixRapide.doitAccuser(reglage: true, ecouleMs: Int(Date().timeIntervalSince(tEnd) * 1000), dejaDuSon: dejaSon,
                                                 tourClos: flag.get(), accuseAuTourPrecedent: false),
                          let pcm = LocalVoice.shared.pcmAccusePret(phrase, language: VoixRapide.langueVoix(VoixRapide.langue(heard, defaut: lang)), voiceId: vid) else { return }
                    ackLock.lock(); ackAt = Date(); ackPcm = pcm; ackPhrase = phrase; ackLock.unlock()
                }
            }
            func enqueue(_ phrase: String) {
                group.enter()
                ttsQ.async {
                    defer { group.leave() }
                    if flag.get() { return }
                    let lv: String? = VoixRapide.langueVoix(VoixRapide.langue(phrase, defaut: lang))
                    let r: LocalVoiceRender = LocalVoice.shared.renderDetailed(text: phrase, voiceId: vid, language: lv, cancel: { flag.get() }) { (d: Data) -> Bool in
                        st.lock.lock()
                        if st.firstAudio == nil { st.firstAudio = Date() }
                        st.pcm.append(d)
                        st.lock.unlock()
                        if barge == "synthese" { flag.set() }
                        return !flag.get()
                    }
                    st.lock.lock(); st.renders.append(r); if flag.get() && st.ttsStoppedAt == nil { st.ttsStoppedAt = Date() }; st.lock.unlock()
                }
            }
            var uin: Int = 0, uout: Int = 0
            var failure: BrainFailure? = nil
            var essais: Int = 0
            let maxChunks: Int = VoixTest.phrasesMax + 1   // la première clause compte pour un morceau
            repeat {
                essais += 1
                failure = nil
                var tin: Int = 0, tout: Int = 0
                do {
                    try router.runner.stream(spec, messages: [ChatMsg("user", heard)], system: VoixTest.system, maxTokens: VoixTest.sparkMaxOut, mode: "voice",
                                             firstTokenTimeout: 15, cancel: { flag.get() },
                                             onDelta: { (d: String) in
                                                 var ready: [String] = []
                                                 st.lock.lock()
                                                 if st.firstToken == nil { st.firstToken = Date() }
                                                 st.text += d
                                                 st.buf += d
                                                 let ex = VoixRapide.decoupe(st.buf, premier: st.phrases.isEmpty)
                                                 st.buf = ex.rest
                                                 for s in ex.ready where st.phrases.count < maxChunks {
                                                     st.phrases.append(s); ready.append(s)
                                                     if st.firstSentence == nil { st.firstSentence = Date() }
                                                 }
                                                 st.lock.unlock()
                                                 for s in ready { enqueue(s) }
                                                 if barge == "generation" { flag.set() }
                                             },
                                             onUsage: { tin = $0; tout = $1 })
                } catch let f as BrainFailure { failure = f } catch { failure = BrainFailure(kind: .other, message: error.localizedDescription) }
                uin += tin; uout += tout
                st.lock.lock(); let rien: Bool = st.text.isEmpty; st.lock.unlock()
                if !(essais < 2 && rien && !flag.get() && failure.map({ VoixRapide.relancerSiVide($0.message) }) == true) { break }
            } while true
            if essais > 1 { tour["relance_vide"] = true }
            let tSparkEnd: Date = Date()
            st.lock.lock()
            if !flag.get(), st.phrases.count < maxChunks, let r = VoixTest.reliquat(st.buf) {
                st.phrases.append(r); if st.firstSentence == nil { st.firstSentence = Date() }
                st.lock.unlock(); enqueue(r)
            } else { st.lock.unlock() }
            _ = group.wait(timeout: .now() + 40)
            _ = ackGroup.wait(timeout: .now() + 2)
            let canceled: Bool = flag.get()
            st.lock.lock()
            let answer: String = st.text
            let firstTok: Date? = st.firstToken, firstSent: Date? = st.firstSentence, firstAud: Date? = st.firstAudio
            let pcm: Data = st.pcm
            let phrases: [String] = st.phrases
            let renders: [LocalVoiceRender] = st.renders
            st.lock.unlock()
            ackLock.lock(); let aAt: Date? = ackAt; let aPcm: Data = ackPcm; let aPhrase: String = ackPhrase; ackLock.unlock()
            prevAcked = aAt != nil
            if aAt != nil { lastAck = aPhrase }
            // Coût (mesuré si l'usage est rapporté)
            let produced: Bool = !answer.isEmpty
            var cSpark: Double = 0
            var sparkStatut: String = "ok"
            if let f = failure, !(canceled && f.kind == .canceled) {
                LLMSpend.abandon(tk, kind: f.kind, produced: produced)
                sparkStatut = "echec"; tour["erreur_spark"] = String(f.message.prefix(300))
                if produced || uout > 0 { cSpark = VoixTest.coutSpark(inTok: uin > 0 ? uin : estIn, outTok: uout > 0 ? uout : VoixTest.sparkMaxOut) }
            } else {
                let inT: Int = uin > 0 ? uin : estIn
                let outT: Int = uout > 0 ? uout : max(TokenEst.of(answer), canceled ? VoixTest.sparkMaxOut : 1)
                LLMSpend.record(spec.id, inTok: inT, outTok: outT, cacheRead: 0, cacheWrite: 0, background: false, spec: spec, ticket: tk, measured: uin > 0 || uout > 0)
                cSpark = VoixTest.coutSpark(inTok: inT, outTok: outT)
                if canceled { sparkStatut = "interrompu" }
            }
            tour["jetons_entree"] = uin; tour["jetons_sortie"] = uout
            cumul += cSpark
            let ftMs: Int = firstTok.map { Int($0.timeIntervalSince(tGo) * 1000) } ?? -1
            MetaOnly.record(provider: "meta", model: spec.model, meta: true, status: sparkStatut, source: "voix_test_streaming", host: "api.meta.ai",
                            reason: failure?.message ?? "", brain: spec.id, specialite: "voix",
                            extra: ["mode": "voice", "reasoning_effort": "minimal", "ms": Int(tSparkEnd.timeIntervalSince(tGo) * 1000), "premier_jeton_ms": ftMs,
                                    "jetons_entree": uin, "jetons_sortie": uout, "cout_usd": VoixTest.arrondi(cSpark)])
            func since(_ d: Date?) -> Int { d.map { Int($0.timeIntervalSince(tEnd) * 1000) } ?? -1 }
            let firstSound: Date? = [aAt, firstAud].compactMap { $0 }.min()
            tour["spark_premier_jeton_ms"] = ftMs
            tour["fin_parole_a_premier_jeton_ms"] = since(firstTok)
            tour["fin_parole_a_premiere_clause_ms"] = since(firstSent)
            tour["premier_audio_reponse_ms"] = since(firstAud)
            tour["accuse_ms"] = since(aAt)
            if aAt != nil { tour["accuse"] = aPhrase }
            tour["premier_son_ms"] = since(firstSound)
            tour["premier_morceau"] = phrases.first ?? ""
            tour["reponse"] = String(answer.prefix(600))
            tour["spark_statut"] = sparkStatut
            tour["tts"] = renders.map { (r: LocalVoiceRender) -> [String: Any] in ["premier_tampon_ms": r.firstBufferMs, "voix": r.voice, "ok": r.ok] }
            let all: Data = aPcm + pcm
            if !all.isEmpty {
                let name: String = String(format: "s%02d_reponse.wav", n)
                try? LocalVoice.wav(pcm16: all, rate: 24000).write(to: audioOut.appendingPathComponent(name))
                tour["fichier_audio"] = "releves/diag/voix_test/" + name
            }
            if let pc = prevCancelAt {
                // Reprise : Ahadi a parlé pendant ce tour (c'est l'interruption) ; mesurée de la fin de sa phrase au premier son.
                tour["reprise_apres_barge_in_ms"] = since(firstSound)
                if var last = tours.last, var b = last["barge_in"] as? [String: Any] {
                    b["reprise_ms"] = since(firstSound); b["reprise_ok"] = firstSound != nil
                    b["reprise_depuis_arret_ms"] = firstSound.map { Int($0.timeIntervalSince(pc) * 1000) } ?? -1
                    last["barge_in"] = b; tours[tours.count - 1] = last
                }
                prevCancelAt = nil
            }
            if let b = barge {
                var bi: [String: Any] = ["type": b, "declenche": flag.when() != nil]
                if let a = flag.when() {
                    let stopEnd: Date = b == "generation" ? tSparkEnd : (st.ttsStoppedAt ?? tSparkEnd)
                    bi["arret_ms"] = max(0, Int(stopEnd.timeIntervalSince(a) * 1000)); bi["arret_ok"] = stopEnd.timeIntervalSince(a) < 1.5
                    prevCancelAt = a
                } else { bi["arret_ok"] = false; if n < items.count { bargeCarry = b } }
                tour["barge_in"] = bi
            }
            tour["statut"] = sparkStatut == "echec" ? "echec_spark" : (firstSound == nil && !canceled ? "sans_audio" : "ok")
            tours.append(tour)
            doc["tours"] = tours
        }
        func col(_ k: String, normalOnly: Bool = false) -> [Double] {
            tours.filter { !normalOnly || $0["barge_in"] == nil }.compactMap { ($0[k] as? Int).map { Double($0) } }
        }
        let bis: [[String: Any]] = tours.compactMap { $0["barge_in"] as? [String: Any] }
        let firsts: [Double] = col("premier_son_ms").filter { $0 >= 0 }
        doc["etapes"] = [
            "attente_partiel_stable": VoixTest.resume(col("attente_partiel_ms")),
            "fin_parole_a_premier_jeton": VoixTest.resume(col("fin_parole_a_premier_jeton_ms")),
            "fin_parole_a_premiere_clause": VoixTest.resume(col("fin_parole_a_premiere_clause_ms", normalOnly: true)),
            "premier_audio_reponse": VoixTest.resume(col("premier_audio_reponse_ms")),
            "accuse": VoixTest.resume(col("accuse_ms")),
            "premier_son": VoixTest.resume(col("premier_son_ms")),
            "barge_in_arret": VoixTest.resume(bis.compactMap { ($0["arret_ms"] as? Int).map { Double($0) } }),
            "barge_in_reprise": VoixTest.resume(bis.compactMap { ($0["reprise_ms"] as? Int).map { Double($0) } }),
        ] as [String: Any]
        doc["criteres"] = ["premier_son_sous_1s_mediane": (VoixTest.centile(firsts, 0.5) ?? 99_999) < 1000,
                           "premier_son_sous_1s_tours": firsts.filter { $0 < 1000 }.count, "tours_mesures": firsts.count,
                           "barge_in_reussis": bis.filter { ($0["arret_ok"] as? Bool) == true }.count,
                           "reponses_vides": tours.filter { ($0["statut"] as? String) == "echec_spark" }.count] as [String: Any]
        let wers: [Double] = tours.compactMap { $0["wer"] as? Double }
        if !wers.isEmpty { doc["wer_partiel_moyen"] = (wers.reduce(0, +) / Double(wers.count) * 1000).rounded() / 1000 }
        doc["cout_usd"] = VoixTest.arrondi(cumul)
        doc["hors_mesure"] = ["VAD (600 ms de silence avant la fin de parole dans la vraie voix)", "haut-parleur", "latence réelle du micro"]
        if doc["statut"] == nil { doc["statut"] = tours.isEmpty ? "aucun_tour" : "ok" }
        return (doc, cumul)
        #else
        doc["statut"] = "indisponible"; doc["raison"] = "SFSpeech/AVFoundation absents de ce système"
        return (doc, 0)
        #endif
    }
}
