import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// Voix de Nova — version hackathon Meta :
///  - synthèse vocale : voix SYSTÈME macOS (AVSpeechSynthesizer, LocalVoice) — Meta ne publie aucun modèle de synthèse vocale ;
///  - transcription : Muse Voice Transcribe (muse-voice-transcribe-1.0, API Meta Model) seul, aucun repli non Meta.
public final class Voice {
    let keys: KeyStore
    let settings: Settings
    let journal = Journal("voix_journal.jsonl")
    public init(keys: KeyStore, settings: Settings) { self.keys = keys; self.settings = settings }

    /// Diffuse l'audio vers le navigateur : voix système macOS (PCM 24 kHz si le client l'annonce, sinon WAV).
    public func speak(text: String, res: Response, accept: String? = nil) {
        let clean = text.replacingOccurrences(of: "\\*|#|_|`", with: "", options: .regularExpression).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clean.isEmpty else { res.json(["error": "texte vide"], status: 400); return }
        let t0 = Date()
        let wantsPCM = (accept ?? "").lowercased().contains("audio/pcm")
        if speakLocal(clean, res: res, wantsPCM: wantsPCM, why: "voix système macOS (version Meta)", t0: t0) { return }
        res.json(["error": "voix locale indisponible"], status: 503, extra: ["X-Nova-Voice": "aucune"])
    }

    /// 25/10 : voix LOCALE (AVSpeechSynthesizer, Feat_VoixLocale.swift) servie par le même contrat que
    /// [tiers] : flux PCM 24 kHz si le client l'annonce, sinon WAV complet. En-tête honnête
    /// X-Nova-Voice: local (+ X-Nova-Voice-Name). false = aucun son produit (rien n'a été envoyé).
    func speakLocal(_ clean: String, res: Response, wantsPCM: Bool, why: String, t0: Date) -> Bool {
        let vid: String = settings.get("voix_locale_id", "")
        let info: [String: String]? = LocalVoice.shared.voiceInfo(preferred: vid)
        let name: String = info?["nom"] ?? ""
        let qual: String = info?["qualite"] ?? ""
        var hdr: [String: String] = ["X-Nova-Voice": "local"]
        hdr["X-Nova-Voice-Name"] = LocalVoice.headerSafe(name + (qual.isEmpty ? "" : " (" + qual + ")"))
        hdr["X-Nova-Voice-Reason"] = LocalVoice.headerSafe(why)
        var first: Int? = nil
        var pcm: Data = Data()
        let r = LocalVoice.shared.render(text: clean, voiceId: vid, cancel: { () -> Bool in res.clientGone }) { (d: Data) -> Bool in
            if wantsPCM {
                if first == nil {
                    first = Int(Date().timeIntervalSince(t0) * 1000)
                    res.head(200, "audio/pcm; rate=24000", extra: hdr)
                }
                return res.chunk(d)
            }
            pcm.append(d)
            return true
        }
        if !wantsPCM && r.ok && !pcm.isEmpty {
            first = Int(Date().timeIntervalSince(t0) * 1000)
            res.data(LocalVoice.wav(pcm16: pcm), type: "audio/wav", extra: hdr)
        }
        let ms: Int = Int(Date().timeIntervalSince(t0) * 1000)
        journal.add(["moteur": "local", "voix": name, "ok": first != nil, "premier_octet_ms": first ?? -1, "total_ms": ms,
                     "chars": clean.count, "pourquoi": shortError(why, 100), "raison": shortError(r.error ?? "", 120)])
        return first != nil
    }

    /// Transcription : Muse Voice Transcribe (Meta) SEUL — aucun repli non Meta.
    public func transcribe(audio: Data, mime: String, language: String = "fra") -> (text: String?, error: String?, via: String?) {
        // FIX-STT : garde 0 octet pour TOUT appelant — un audio vide n'atteint jamais le moteur.
        guard !audio.isEmpty else {
            journal.add(["stt": "garde-vide", "bytes": 0, "via": "transcribe"])
            return (nil, "enregistrement vide (0 octet) — le son n'est pas parvenu à Nova", nil)
        }
        // DIAG-VOIX (21/10) : le type déclaré par la WebView peut contredire le conteneur réellement produit : on renifle les octets magiques.
        var mime0 = mime
        if let sniffed = Voice.sniffAudioMime(audio), !mime0.hasPrefix(sniffed) {
            journal.add(["stt": "conteneur", "declare": mime, "reel": sniffed, "bytes": audio.count])
            mime0 = sniffed
        }
        let m = transcribeMeta(audio: audio, mime: mime0, language: language)
        if let t = m.text { MetaSpecialites.noter(specialite: .dictee, modele: "muse-voice-transcribe-1.0", cerveau: "", chaine: [], statut: "ok", source: "voice.transcribe"); return (t, nil, "muse-voice-transcribe-1.0") }
        MetaSpecialites.noter(specialite: .dictee, modele: "muse-voice-transcribe-1.0", cerveau: "", chaine: [], statut: "echec", source: "voice.transcribe")
        return (nil, "Muse Voice Transcribe (Meta) a échoué — " + shortError(m.error ?? "sans réponse", 120) + ".", nil)
    }
    /// Conteneur audio d'après les octets magiques (WebM/Matroska, MP4, WAV, Ogg) —
    /// nil si non reconnu (on garde alors le type déclaré).
    public static func sniffAudioMime(_ d: Data) -> String? {
        guard d.count >= 4 else { return nil }
        let b = [UInt8](d.prefix(12))
        if b.count >= 4, b[0] == 0x1A, b[1] == 0x45, b[2] == 0xDF, b[3] == 0xA3 { return "audio/webm" }
        if b.count >= 8, String(bytes: b[4..<8], encoding: .ascii) == "ftyp" { return "audio/mp4" }
        if b.count >= 4, String(bytes: b[0..<4], encoding: .ascii) == "RIFF" { return "audio/wav" }
        if b.count >= 4, String(bytes: b[0..<4], encoding: .ascii) == "OggS" { return "audio/ogg" }
        return nil
    }
    /// Transcrit un FICHIER audio (m4a, mp3, wav, mp4…) du dossier personnel par Muse Voice Transcribe ; écrit « <nom> - transcription.txt » à côté.
    public func transcribeFile(_ rawPath: String) -> String {
        let fm = FileManager.default; let home = fm.homeDirectoryForCurrentUser.path
        var p: String = rawPath.trimmingCharacters(in: CharacterSet(charactersIn: " \n\"'"))
        let known: [String] = ["Desktop", "Downloads", "Documents"]
        if p.hasPrefix("~") { p = (p as NSString).expandingTildeInPath }
        else if !p.hasPrefix("/") {
            let top: String = p.components(separatedBy: "/").first ?? ""
            p = home + "/" + (known.contains(top) ? "" : "Desktop/") + p
        } else if !p.hasPrefix(home) {
            for k in known { if let r = p.range(of: "/" + k + "/") { p = home + String(p[r.lowerBound...]); break } }
        }
        let blocked: [String] = ["/.ssh", "/.aws", "/.gnupg", "Keychains"]
        guard p.hasPrefix(home), !blocked.contains(where: { p.contains($0) }) else { return "Chemin refusé (hors dossier personnel)." }
        guard let d = fm.contents(atPath: p) else { return "Fichier introuvable : \(p). Liste le dossier avec shell (ls) pour trouver le nom exact." }
        let ext = (p as NSString).pathExtension.lowercased()
        let mimes: [String: String] = ["wav": "audio/wav", "mp3": "audio/mpeg", "m4a": "audio/mp4", "mp4": "video/mp4", "ogg": "audio/ogg", "webm": "audio/webm", "aac": "audio/aac", "flac": "audio/flac"]
        let mime: String = mimes[ext] ?? "audio/mp4"
        var text: String? = nil; var via = "muse-voice-transcribe-1.0"; var err: String? = nil; var emptyVia: String? = nil   // APPLY-BRIEFS H5 : moteur ayant répondu SANS texte
        let head = transcribe(audio: d, mime: mime, language: "fra")
        if let t = head.text { text = t; via = head.via ?? via; if t.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { emptyVia = via } }
        if text == nil { err = head.error }
        guard let t = text, !t.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            // APPLY-BRIEFS H5 : deux cas distincts, nommés — réponse sans parole, ou échec du moteur (motif réel dans err).
            if let ev = emptyVia { return "Transcription vide (aucune parole détectée) : le moteur \(ev) a répondu sans texte — l'audio ne contient probablement aucune parole. Ne prétends pas avoir transcrit." }
            return "Transcription impossible : \(err ?? "aucun moteur n'a répondu"). Ne prétends pas avoir transcrit."
        }
        let outPath = (p as NSString).deletingPathExtension + " - transcription.txt"
        try? t.write(toFile: outPath, atomically: true, encoding: .utf8)
        journal.add(["stt_fichier": (p as NSString).lastPathComponent, "via": via, "car": t.count])
        return "TRANSCRIPTION COMPLÈTE (\(t.count) caractères, via \(via)) — enregistrée dans « \((outPath as NSString).lastPathComponent) » à côté de l'audio.\n\n" + String(t.prefix(7000)) + (t.count > 7000 ? "\n[…suite dans le fichier ; lis-la avec read_file par tranches]" : "")
    }
    /// MN2-1 : transcription par Muse Voice Transcribe (Meta Model API). Même patron que les
    /// autres appels Meta du moteur : clé Trousseau « nova-spark » (grant OAuth JSON déballé
    /// comme dans BrainRunner), POST borné syncPost, preuve journalisée des DEUX côtés
    /// (journal voix + boîte noire, nom du modèle inclus). Échec → (nil, cause), nommé.
    /// Forme d'appel FERMÉE le 23/10/2026 par sondes mesurées en session de travail
    /// (journal : conseil-design/lotb-staging/preuves/sondes_lotb_journal.log) :
    /// POST /v1/asr/transcribe, multipart = part « request » (JSON : model, language,
    /// audioEncoding « WAV ») + part « audio » (WAV PCM mono 16 bits, 16 kHz — l'endpoint
    /// n'accepte que ce format : conversion systématique par afconvert, patron de la voie
    /// fichier ci-dessous). Réponse 200 : {sessionId, transcript, audioDurationMs, turns}.
    /// L'ancienne route /v1/audio/transcriptions rendait 404 en permanence (21–23/10/2026,
    /// boîte noire seq 10048 et 11113). Mémoire de session (jamais persistée) : si
    /// l'endpoint répond 404/405, la jambe est coupée pour la session — on ne retaque pas
    /// une route morte à chaque dictée ; au prochain lancement, elle est retestée.
    private var metaRouteDead = false

    func transcribeMeta(audio: Data, mime: String, language: String) -> (text: String?, error: String?) {
        var key = KeyChain([KnownKeys.sparkNova, KnownKeys.metaModelAPI, KnownKeys.spark]).resolve(keys) ?? ""
        if let d = key.data(using: .utf8), d.first == UInt8(ascii: "{"), let o = parseJSON(d) { key = (o["api_key"] as? String) ?? (o["access_token"] as? String) ?? key }
        guard !key.isEmpty else { return (nil, "clé Meta absente du Trousseau (nova-spark)") }
        // Conversion au SEUL format admis par l'endpoint : WAV PCM mono 16 bits, 16 kHz.
        // afconvert lit wav/mp4/m4a/aiff/caf/mp3 (il renifle le contenu, pas l'extension) ;
        // un conteneur illisible (webm) rend une erreur nommée, journalisée — jamais de plantage, jamais d'appel bancal.
        let tmp = NSTemporaryDirectory()
        let inExt = mime.contains("wav") ? "wav" : (mime.contains("mp4") ? "m4a" : (mime.contains("ogg") ? "ogg" : (mime.contains("mpeg") ? "mp3" : "webm")))
        let inPath = tmp + "nova-stt-meta-in-\(UUID().uuidString).\(inExt)"
        let outPath = tmp + "nova-stt-meta-out-\(UUID().uuidString).wav"
        defer { try? FileManager.default.removeItem(atPath: inPath); try? FileManager.default.removeItem(atPath: outPath) }
        do { try audio.write(to: URL(fileURLWithPath: inPath)) } catch {
            let err = "Muse Voice Transcribe : écriture temporaire impossible (\(error.localizedDescription))"
            journal.add(["stt": "meta", "model": "muse-voice-transcribe-1.0", "ok": false, "err": shortError(err, 160)])
            _ = BlackBox.record(["tool": "stt", "actor": "Nova", "why": "échec muse-voice-transcribe-1.0 : " + shortError(err, 120), "ok": false, "effect": "aucun"])
            return (nil, err)
        }
        let conv = runProcess("/usr/bin/afconvert", ["-f", "WAVE", "-d", "LEI16@16000", "-c", "1", inPath, outPath], timeout: 60)
        guard conv.0 == 0, let wav = try? Data(contentsOf: URL(fileURLWithPath: outPath)), !wav.isEmpty else {
            let err = "Muse Voice Transcribe : conversion WAV PCM 16 kHz impossible (afconvert \(conv.0)) — conteneur \(mime) non convertible"
            journal.add(["stt": "meta", "model": "muse-voice-transcribe-1.0", "ok": false, "err": shortError(err, 160)])
            _ = BlackBox.record(["tool": "stt", "actor": "Nova", "why": "échec muse-voice-transcribe-1.0 : " + shortError(err, 120), "ok": false, "effect": "aucun"])
            return (nil, err)
        }
        let reqObj: [String: Any] = ["model": "muse-voice-transcribe-1.0", "language": (language == "fra" || language == "auto") ? "fr" : language, "audioEncoding": "WAV"]
        guard let reqData = try? JSONSerialization.data(withJSONObject: reqObj) else { return (nil, "Muse Voice Transcribe : requête JSON non construite") }
        let b = "----nova" + UUID().uuidString
        var body = Data()
        body.append(Data("--\(b)\r\nContent-Disposition: form-data; name=\"request\"\r\nContent-Type: application/json\r\n\r\n".utf8))
        body.append(reqData); body.append(Data("\r\n".utf8))
        body.append(Data("--\(b)\r\nContent-Disposition: form-data; name=\"audio\"; filename=\"voix.wav\"\r\nContent-Type: audio/wav\r\n\r\n".utf8))
        body.append(wav); body.append(Data("\r\n--\(b)--\r\n".utf8))
        var req = URLRequest(url: URL(string: "https://api.meta.ai/v1/asr/transcribe")!)
        req.httpMethod = "POST"; req.httpBody = body
        req.setValue("Bearer " + key, forHTTPHeaderField: "Authorization"); req.setValue("multipart/form-data; boundary=\(b)", forHTTPHeaderField: "Content-Type")
        let (st, data) = syncPost(req, timeout: 60)
        let respObj = parseJSON(data)
        let txt = (respObj?["transcript"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
        if st == 200, let t = txt, !t.isEmpty {
            let durMs = (respObj?["audioDurationMs"] as? NSNumber)?.intValue ?? -1
            journal.add(["stt": "meta", "model": "muse-voice-transcribe-1.0", "ok": true, "bytes": wav.count, "duree_audio_ms": durMs])
            _ = BlackBox.record(["tool": "stt", "actor": "Nova", "why": "transcription par muse-voice-transcribe-1.0 (Meta Model API, /asr/transcribe)", "ok": true, "effect": "lu"])
            return (t, nil)
        }
        let metaErrMsg = (respObj?["error"] as? [String: Any])?["message"] as? String
        if st == 404 || st == 405 { metaRouteDead = true }   // route absente sous cette forme : inutile de la retaquer à chaque dictée (session seulement)
        let bodyPeek = metaErrMsg == nil ? shortError((String(data: data, encoding: .utf8) ?? "").trimmingCharacters(in: .whitespacesAndNewlines), 120) : ""
        let err = "Muse Voice Transcribe : HTTP \(st)" + (metaErrMsg.map { " — \($0)" } ?? (bodyPeek.isEmpty ? "" : " — corps : \(bodyPeek)"))
        journal.add(["stt": "meta", "model": "muse-voice-transcribe-1.0", "ok": false, "err": shortError(err, 160)])
        _ = BlackBox.record(["tool": "stt", "actor": "Nova", "why": "échec muse-voice-transcribe-1.0 : " + shortError(err, 120), "ok": false, "effect": "aucun"])
        return (nil, err)
    }
}
