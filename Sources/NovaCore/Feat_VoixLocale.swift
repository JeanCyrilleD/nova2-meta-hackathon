import Foundation
#if canImport(AVFoundation) && os(macOS)
import AVFoundation
#endif

// 25/10 : VOIX LOCALE de Nova — AVSpeechSynthesizer (meilleure voix française INSTALLÉE sur le Mac :
// Premium > Améliorée > standard, fr-FR d'abord), rendue en PCM 16 bits LE mono 24 kHz par
// write(_:toBufferCallback:). Elle sert le flux /api/tts (navigateur) et le lecteur natif du Live (VLLivePlayer).
// Version hackathon Meta : SEUL moteur de synthèse vocale (Meta ne publie aucun modèle de synthèse vocale).
// C'est la voix système du Mac, pas un modèle génératif appelé par Nova. Réglage optionnel « voix_locale_id ».
// Rien ne quitte le Mac : la synthèse est entièrement locale.
public final class LocalVoice {
    public static let shared: LocalVoice = LocalVoice()
    private let lock: NSLock = NSLock()
    #if canImport(AVFoundation) && os(macOS)
    private var synths: [AVSpeechSynthesizer] = []   // retenus le temps du rendu (sinon libérés en plein write)
    // 01/11 (voix-test) : synthétiseurs CHAUDS au repos, réutilisés d'une phrase à l'autre (avant : un AVSpeechSynthesizer neuf
    // par phrase = voix rechargée à froid à chaque phrase) ; voix choisie gardée en cache (avant : speechVoices() énuméré
    // deux fois par phrase, par voiceInfo puis par render).
    private var idle: [AVSpeechSynthesizer] = []
    private var voiceCache: [String: (voice: AVSpeechSynthesisVoice, at: Date)] = [:]
    #endif
    private var warmedAt: Date? = nil
    private var lastWarmMs: Int = -1
    /// Réglage de la réutilisation (tests, retour arrière) : faux = un synthétiseur neuf par phrase, comme avant.
    public static var reuseSynth: Bool = true

    /// Moteur de synthèse vocale : toujours « local » (voix système macOS) dans la version hackathon Meta.
    public static func mode(_ settings: Settings) -> String { "local" }

    /// Voix retenue : id, nom, qualité, langue — nil si aucune voix française n'est installée.
    public func voiceInfo(preferred: String = "") -> [String: String]? {
        #if canImport(AVFoundation) && os(macOS)
        guard let v: AVSpeechSynthesisVoice = cachedVoice(preferred: preferred, language: nil) else { return nil }
        let out: [String: String] = ["id": v.identifier, "nom": v.name, "qualite": LocalVoice.qualityName(v), "langue": v.language]
        return out
        #else
        return nil
        #endif
    }

    /// Nom sûr pour un en-tête HTTP (sans diacritiques ni retour ligne).
    public static func headerSafe(_ s: String) -> String {
        let folded: String = s.folding(options: [.diacriticInsensitive], locale: Locale(identifier: "fr_FR"))
        let ascii: String = String(folded.unicodeScalars.filter { (u: Unicode.Scalar) -> Bool in u.isASCII && u.value >= 32 }.map { (u: Unicode.Scalar) -> Character in Character(u) })
        return String(ascii.prefix(120))
    }

    /// En-tête WAV (PCM 16 bits mono) autour d'un tampon PCM brut — pour un client qui n'annonce pas audio/pcm.
    public static func wav(pcm16: Data, rate: Int = 24000) -> Data {
        var d: Data = Data()
        func u32(_ v: UInt32) { var x: UInt32 = v.littleEndian; withUnsafeBytes(of: &x) { (b: UnsafeRawBufferPointer) in d.append(contentsOf: b) } }
        func u16(_ v: UInt16) { var x: UInt16 = v.littleEndian; withUnsafeBytes(of: &x) { (b: UnsafeRawBufferPointer) in d.append(contentsOf: b) } }
        let dataLen: UInt32 = UInt32(pcm16.count)
        d.append(Data("RIFF".utf8)); u32(36 + dataLen); d.append(Data("WAVE".utf8))
        d.append(Data("fmt ".utf8)); u32(16); u16(1); u16(1); u32(UInt32(rate)); u32(UInt32(rate * 2)); u16(2); u16(16)
        d.append(Data("data".utf8)); u32(dataLen)
        d.append(pcm16)
        return d
    }

    #if canImport(AVFoundation) && os(macOS)
    static func qualityRank(_ v: AVSpeechSynthesisVoice) -> Int {
        switch v.quality {
        case .premium: return 3
        case .enhanced: return 2
        default: return 1
        }
    }

    static func qualityName(_ v: AVSpeechSynthesisVoice) -> String {
        let r: Int = qualityRank(v)
        if r == 3 { return "premium" }
        if r == 2 { return "amelioree" }
        return "standard"
    }

    /// fr-FR avant toute autre variante française ; à langue égale, la meilleure qualité ;
    /// à qualité égale, Amélie ou Thomas (voix françaises de référence d'Apple).
    /// 01/11 (voix-test) : `language` = « en » choisit une voix anglaise (en-GB d'abord) ; nil = français, comme avant.
    static func pickVoice(preferred: String, language: String? = nil) -> AVSpeechSynthesisVoice? {
        if !preferred.isEmpty {
            if let p: AVSpeechSynthesisVoice = AVSpeechSynthesisVoice(identifier: preferred) { return p }
        }
        let all: [AVSpeechSynthesisVoice] = AVSpeechSynthesisVoice.speechVoices()
        var best: AVSpeechSynthesisVoice? = nil
        var bestScore: Int = -1
        for v in all {
            let score: Int = LocalVoice.voiceScore(language: v.language, qualityRank: qualityRank(v), name: v.name, want: language)
            if score > bestScore { bestScore = score; best = v }
        }
        return best
    }

    /// Voix choisie, gardée 5 min en cache (l'énumération des voix du système coûte à chaque phrase).
    func cachedVoice(preferred: String, language: String?) -> AVSpeechSynthesisVoice? {
        let k: String = preferred + "|" + (language ?? "fr")
        lock.lock()
        if let c = voiceCache[k], Date().timeIntervalSince(c.at) < 300 { lock.unlock(); return c.voice }
        lock.unlock()
        // Aucune voix de la langue demandée : voix française (comportement d'avant) plutôt que le silence.
        guard let v: AVSpeechSynthesisVoice = LocalVoice.pickVoice(preferred: preferred, language: language) ?? (language == nil ? nil : LocalVoice.pickVoice(preferred: preferred, language: nil)) else { return nil }
        lock.lock(); voiceCache[k] = (v, Date()); lock.unlock()
        return v
    }
    #endif

    /// Score d'une voix (pur, testé) : -1 = langue écartée. Français par défaut (règle d'avant, inchangée) ;
    /// want = « en » : en-GB 100, autre anglais 50 ; qualité × 10 ; voix de référence + 3.
    static func voiceScore(language lang: String, qualityRank: Int, name: String, want: String?) -> Int {
        var score: Int = 0
        let w: String = (want ?? "fr").lowercased()
        if w.hasPrefix("en") {
            if lang == "en-GB" { score = 100 } else if lang.hasPrefix("en") { score = 50 } else { return -1 }
        } else {
            if lang == "fr-FR" { score = 100 } else if lang.hasPrefix("fr") { score = 50 } else { return -1 }
        }
        score += qualityRank * 10
        let n: String = name.lowercased()
        if w.hasPrefix("en") {
            if n.contains("daniel") || n.contains("serena") || n.contains("kate") { score += 3 }
        } else if n.contains("amélie") || n.contains("amelie") || n.contains("thomas") { score += 3 }
        return score
    }
    #if canImport(AVFoundation) && os(macOS)

    /// Conversion d'un tampon de synthèse (format quelconque) vers PCM16 mono 24 kHz.
    static func convert(_ inBuf: AVAudioPCMBuffer, state: LocalVoiceRenderState, outFmt: AVAudioFormat, endOfStream: Bool) -> Data? {
        if state.converter == nil {
            state.converter = AVAudioConverter(from: inBuf.format, to: outFmt)
            state.inRate = inBuf.format.sampleRate
        }
        guard let conv: AVAudioConverter = state.converter else { return nil }
        let inRate: Double = state.inRate > 0 ? state.inRate : 22050
        let ratio: Double = outFmt.sampleRate / inRate
        let frames: Double = Double(inBuf.frameLength) * ratio
        let cap: AVAudioFrameCount = AVAudioFrameCount(frames) + 1024
        guard let outBuf: AVAudioPCMBuffer = AVAudioPCMBuffer(pcmFormat: outFmt, frameCapacity: cap) else { return nil }
        var fed: Bool = false
        var err: NSError? = nil
        let status: AVAudioConverterOutputStatus = conv.convert(to: outBuf, error: &err) { (_: AVAudioPacketCount, outStatus: UnsafeMutablePointer<AVAudioConverterInputStatus>) -> AVAudioBuffer? in
            if fed || inBuf.frameLength == 0 {
                outStatus.pointee = endOfStream ? .endOfStream : .noDataNow
                return nil
            }
            fed = true
            outStatus.pointee = .haveData
            return inBuf
        }
        if status == .error { return nil }
        let n: Int = Int(outBuf.frameLength)
        if n <= 0 { return Data() }
        guard let ch: UnsafePointer<UnsafeMutablePointer<Int16>> = outBuf.int16ChannelData else { return Data() }
        return Data(bytes: ch[0], count: n * 2)
    }
    #endif

    /// Rend `text` en PCM16 LE mono 24 kHz, livré par morceaux à `onPCM` (retour false = arrêter).
    /// BLOQUANT : à appeler hors du fil principal (la synthèse y est lancée, l'appelant attend).
    public func render(text: String, voiceId: String = "", cancel: @escaping () -> Bool = { () -> Bool in false },
                       onPCM: @escaping (Data) -> Bool) -> (ok: Bool, bytes: Int, voice: String, error: String?) {
        let r: LocalVoiceRender = renderDetailed(text: text, voiceId: voiceId, language: nil, cancel: cancel, onPCM: onPCM)
        return (r.ok, r.bytes, r.voice, r.error)
    }

    /// 01/11 (voix-test) : PRÉCHAUFFAGE — une courte phrase rendue (aucun son joué, sortie jetée) pour charger la voix et
    /// laisser un synthétiseur chaud au repos. Rend la durée (ms) ; -1 si indisponible. BLOQUANT, hors fil principal.
    @discardableResult
    public func prewarm(language: String? = nil, voiceId: String = "") -> Int {
        let t0: Date = Date()
        let r: LocalVoiceRender = renderDetailed(text: (language ?? "fr").hasPrefix("en") ? "Ready." : "Prête.", voiceId: voiceId, language: language,
                                                 cancel: { () -> Bool in false }, onPCM: { (_: Data) -> Bool in true })
        let ms: Int = r.ok ? Int(Date().timeIntervalSince(t0) * 1000) : -1
        lock.lock(); if r.ok { warmedAt = Date() }; lastWarmMs = ms; lock.unlock()
        return ms
    }
    public func warmState() -> (warm: Bool, ms: Int) {
        lock.lock(); defer { lock.unlock() }
        return (warmedAt != nil, lastWarmMs)
    }

    /// Comme render, avec la mesure : premier tampon (ms), fin naturelle (tampon final reçu) ou par le filet de 2 s,
    /// synthétiseur chaud réutilisé ou neuf. `language` « en » = voix anglaise ; nil = français (comportement d'avant).
    public func renderDetailed(text: String, voiceId: String = "", language: String? = nil, cancel: @escaping () -> Bool = { () -> Bool in false },
                               onPCM: @escaping (Data) -> Bool) -> LocalVoiceRender {
        let t0: Date = Date()
        var out: LocalVoiceRender = LocalVoiceRender()
        #if canImport(AVFoundation) && os(macOS)
        if Thread.isMainThread { out.error = "voix locale appelée sur le fil principal (refusé)"; return out }
        guard let voice: AVSpeechSynthesisVoice = cachedVoice(preferred: voiceId, language: language) else {
            out.error = (language ?? "fr").hasPrefix("en") ? "aucune voix anglaise installée" : "aucune voix française installée (Réglages Système › Accessibilité › Contenu énoncé › Voix du système)"
            return out
        }
        out.voice = voice.name
        guard let outFmt: AVAudioFormat = AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: 24000, channels: 1, interleaved: true) else {
            out.error = "format PCM 24 kHz non construit"; return out
        }
        let utt: AVSpeechUtterance = AVSpeechUtterance(string: text)
        utt.voice = voice
        var synth0: AVSpeechSynthesizer? = nil
        lock.lock()
        if LocalVoice.reuseSynth, !idle.isEmpty { synth0 = idle.removeLast() }
        lock.unlock()
        out.warmSynth = synth0 != nil
        let synth: AVSpeechSynthesizer = synth0 ?? AVSpeechSynthesizer()
        let wake: DispatchSemaphore = DispatchSemaphore(value: 0)
        let state: LocalVoiceRenderState = LocalVoiceRenderState()
        // Le rappel de synthèse ne fait que convertir et empiler : onPCM (écriture réseau, lecteur natif)
        // tourne sur le fil APPELANT — jamais sur le fil principal où la synthèse peut rappeler.
        let cb: (AVAudioBuffer) -> Void = { (buffer: AVAudioBuffer) in
            guard let pcm: AVAudioPCMBuffer = buffer as? AVAudioPCMBuffer else { return }
            let last: Bool = pcm.frameLength == 0
            if !state.isStopped() {
                if let d: Data = LocalVoice.convert(pcm, state: state, outFmt: outFmt, endOfStream: last) {
                    state.touch()
                    if !d.isEmpty { state.push(d) }
                }
            }
            if last { state.markFinished() }
            wake.signal()
        }
        lock.lock(); synths.append(synth); lock.unlock()
        DispatchQueue.main.async { synth.write(utt, toBufferCallback: cb) }
        var error: String? = nil
        while true {
            _ = wake.wait(timeout: .now() + 0.25)
            let fin: Bool = state.isFinished()   // lu AVANT la vidange : rien d'empilé ensuite n'est perdu
            let chunks: [Data] = state.drain()
            for c in chunks {
                if state.isStopped() { break }
                if out.firstBufferMs < 0 { out.firstBufferMs = Int(Date().timeIntervalSince(t0) * 1000) }
                state.add(c.count)
                if !onPCM(c) { state.stop() }
            }
            if fin { out.finishedNaturally = true; break }
            if cancel() || state.isStopped() {
                state.stop()
                DispatchQueue.main.async { _ = synth.stopSpeaking(at: .immediate) }
                break
            }
            // Filet : certains systèmes ne livrent pas le tampon final vide — après du son, 2 s de silence = fin.
            let produced: Bool = state.total() > 0
            let idleLimit: Double = produced ? 2.0 : (out.warmSynth ? 3.0 : 10.0)   // synthétiseur réutilisé muet : repli rapide sur un neuf (plus bas)
            if Date().timeIntervalSince(state.lastActivity()) > idleLimit {
                if !produced { error = "voix locale muette depuis 10 s (synthèse bloquée)" }
                out.endedByIdleNet = produced
                state.stop()
                DispatchQueue.main.async { _ = synth.stopSpeaking(at: .immediate) }
                break
            }
        }
        // Fin naturelle : le synthétiseur est rendu TOUT DE SUITE au repos (chaud, réutilisé par la phrase suivante).
        // Arrêt (barge-in, filet) : libéré un peu plus tard, jamais réutilisé — un dernier rappel peut encore arriver après stopSpeaking.
        let reusable: Bool = LocalVoice.reuseSynth && out.finishedNaturally && !state.isStopped()
        lock.lock()
        synths.removeAll { (s: AVSpeechSynthesizer) -> Bool in s === synth }
        if reusable && idle.count < 2 { idle.append(synth) }
        lock.unlock()
        if !reusable {
            lock.lock(); synths.append(synth); lock.unlock()
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { [weak self] in
                guard let self = self else { return }
                self.lock.lock()
                self.synths.removeAll { (s: AVSpeechSynthesizer) -> Bool in s === synth }
                self.lock.unlock()
            }
        }
        let total: Int = state.total()
        if error == nil && total == 0 && !cancel() { error = "voix locale : aucun son produit" }
        out.ok = error == nil && total > 0
        out.bytes = total
        out.error = error
        out.totalMs = Int(Date().timeIntervalSince(t0) * 1000)
        if out.warmSynth && total == 0 && !cancel() {
            // Filet : un synthétiseur réutilisé n'a rien rendu — réutilisation coupée pour la session, la phrase est rejouée sur un neuf.
            LocalVoice.reuseSynth = false
            lock.lock(); idle.removeAll(); lock.unlock()
            let again: LocalVoiceRender = renderDetailed(text: text, voiceId: voiceId, language: language, cancel: cancel, onPCM: onPCM)
            return again
        }
        return out
        #else
        out.error = "voix locale indisponible sur ce système"
        return out
        #endif
    }
}

/// 01/11 (voix-test) : résultat mesuré d'un rendu de la voix locale.
public struct LocalVoiceRender {
    public var ok: Bool = false
    public var bytes: Int = 0
    public var voice: String = ""
    public var error: String? = nil
    public var firstBufferMs: Int = -1        // premier tampon PCM livré (depuis l'appel)
    public var totalMs: Int = -1
    public var finishedNaturally: Bool = false // tampon final reçu (sinon : arrêt, ou filet de 2 s)
    public var endedByIdleNet: Bool = false    // fin décidée par le filet « 2 s de silence » (attente perdue)
    public var warmSynth: Bool = false         // synthétiseur chaud réutilisé
    /// Durée audio produite (PCM16 mono 24 kHz).
    public var audioMs: Int { bytes / 48 }
    public init() {}
}

/// État partagé d'un rendu (rappels de synthèse ↔ fil qui attend).
final class LocalVoiceRenderState {
    private let lock: NSLock = NSLock()
    private var stopped: Bool = false
    private var finished: Bool = false
    private var bytes: Int = 0
    private var last: Date = Date()
    #if canImport(AVFoundation) && os(macOS)
    var converter: AVAudioConverter? = nil
    var inRate: Double = 0
    #endif

    func isStopped() -> Bool { lock.lock(); defer { lock.unlock() }; return stopped }
    func stop() { lock.lock(); stopped = true; lock.unlock() }
    func touch() { lock.lock(); last = Date(); lock.unlock() }
    func lastActivity() -> Date { lock.lock(); defer { lock.unlock() }; return last }
    func add(_ n: Int) { lock.lock(); bytes += n; lock.unlock() }
    func total() -> Int { lock.lock(); defer { lock.unlock() }; return bytes }
    private var queue: [Data] = []
    func markFinished() { lock.lock(); finished = true; lock.unlock() }
    func isFinished() -> Bool { lock.lock(); defer { lock.unlock() }; return finished }
    func push(_ d: Data) { lock.lock(); queue.append(d); lock.unlock() }
    func drain() -> [Data] {
        lock.lock(); defer { lock.unlock() }
        let out: [Data] = queue
        queue = []
        return out
    }
}

extension NovaApp {
    /// 25/10 : routes de la voix locale + relais du niveau de parole vers le compagnon.
    func voixLocaleRoutes() {
        let s = server
        // 01/11 (voix-test) : voix locale PRÉCHAUFFÉE 8 s après le lancement (voix chargée, synthétiseur chaud au repos) quand elle
        // peut parler (meta_only, « local » ou « auto ») — la première phrase ne paie plus le chargement à froid. Aucun son joué.
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 8) { [settings] in
            if settings.get("voix_locale_prechauffage", true) {
                _ = LocalVoice.shared.prewarm(voiceId: settings.get("voix_locale_id", ""))
            }
        }
        // État de la voix locale (voix retenue, moteur choisi) — pour l'écran Réglages › Voix.
        s.on("GET", "/api/voix/locale") { [self] _, res in
            let vid: String = settings.get("voix_locale_id", "")
            let info: [String: String]? = LocalVoice.shared.voiceInfo(preferred: vid)
            var out: [String: Any] = ["moteur": LocalVoice.mode(settings), "disponible": info != nil, "nature": "voix système macOS (AVSpeechSynthesizer), pas un modèle génératif"]
            if let i: [String: String] = info { out["voix"] = i }
            let w = LocalVoice.shared.warmState()
            out["prechauffee"] = w.warm; out["prechauffage_ms"] = w.ms
            res.json(out)
        }
        // Lip-sync du compagnon : la page principale relaie le niveau de SA lecture TTS (voice.js),
        // le moteur le republie sur le bus pour la WebView séparée du compagnon. Aucune persistance.
        s.on("POST", "/api/voix/niveau") { [self] req, res in
            var v: Double = 0
            if let n: NSNumber = req.json["niveau"] as? NSNumber { v = n.doubleValue }
            if v.isNaN || v < 0 { v = 0 }
            if v > 1 { v = 1 }
            bus.publish("voix_niveau", ["niveau": v, "source": "tts"])
            res.json(["ok": true])
        }
    }
}
