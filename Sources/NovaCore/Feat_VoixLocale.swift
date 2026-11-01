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
    #endif

    /// Moteur de synthèse vocale : toujours « local » (voix système macOS) dans la version hackathon Meta.
    public static func mode(_ settings: Settings) -> String { "local" }

    /// Voix retenue : id, nom, qualité, langue — nil si aucune voix française n'est installée.
    public func voiceInfo(preferred: String = "") -> [String: String]? {
        #if canImport(AVFoundation) && os(macOS)
        guard let v: AVSpeechSynthesisVoice = LocalVoice.pickVoice(preferred: preferred) else { return nil }
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
    static func pickVoice(preferred: String) -> AVSpeechSynthesisVoice? {
        if !preferred.isEmpty {
            if let p: AVSpeechSynthesisVoice = AVSpeechSynthesisVoice(identifier: preferred) { return p }
        }
        let all: [AVSpeechSynthesisVoice] = AVSpeechSynthesisVoice.speechVoices()
        var best: AVSpeechSynthesisVoice? = nil
        var bestScore: Int = -1
        for v in all {
            let lang: String = v.language
            var score: Int = 0
            if lang == "fr-FR" {
                score = 100
            } else if lang.hasPrefix("fr") {
                score = 50
            } else {
                continue
            }
            score += qualityRank(v) * 10
            let n: String = v.name.lowercased()
            if n.contains("amélie") || n.contains("amelie") || n.contains("thomas") { score += 3 }
            if score > bestScore { bestScore = score; best = v }
        }
        return best
    }

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
        #if canImport(AVFoundation) && os(macOS)
        if Thread.isMainThread { return (false, 0, "", "voix locale appelée sur le fil principal (refusé)") }
        guard let voice: AVSpeechSynthesisVoice = LocalVoice.pickVoice(preferred: voiceId) else {
            return (false, 0, "", "aucune voix française installée (Réglages Système › Accessibilité › Contenu énoncé › Voix du système)")
        }
        guard let outFmt: AVAudioFormat = AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: 24000, channels: 1, interleaved: true) else {
            return (false, 0, voice.name, "format PCM 24 kHz non construit")
        }
        let utt: AVSpeechUtterance = AVSpeechUtterance(string: text)
        utt.voice = voice
        let synth: AVSpeechSynthesizer = AVSpeechSynthesizer()
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
                state.add(c.count)
                if !onPCM(c) { state.stop() }
            }
            if fin { break }
            if cancel() || state.isStopped() {
                state.stop()
                DispatchQueue.main.async { _ = synth.stopSpeaking(at: .immediate) }
                break
            }
            // Filet : certains systèmes ne livrent pas le tampon final vide — après du son, 2 s de silence = fin.
            let produced: Bool = state.total() > 0
            let idleLimit: Double = produced ? 2.0 : 10.0
            if Date().timeIntervalSince(state.lastActivity()) > idleLimit {
                if !produced { error = "voix locale muette depuis 10 s (synthèse bloquée)" }
                state.stop()
                DispatchQueue.main.async { _ = synth.stopSpeaking(at: .immediate) }
                break
            }
        }
        // Libéré un peu plus tard : un dernier rappel peut encore arriver après stopSpeaking.
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { [weak self] in
            guard let self = self else { return }
            self.lock.lock()
            self.synths.removeAll { (s: AVSpeechSynthesizer) -> Bool in s === synth }
            self.lock.unlock()
        }
        let total: Int = state.total()
        if error == nil && total == 0 && !cancel() { error = "voix locale : aucun son produit" }
        return (error == nil && total > 0, total, voice.name, error)
        #else
        return (false, 0, "", "voix locale indisponible sur ce système")
        #endif
    }
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
        // État de la voix locale (voix retenue, moteur choisi) — pour l'écran Réglages › Voix.
        s.on("GET", "/api/voix/locale") { [self] _, res in
            let vid: String = settings.get("voix_locale_id", "")
            let info: [String: String]? = LocalVoice.shared.voiceInfo(preferred: vid)
            var out: [String: Any] = ["moteur": LocalVoice.mode(settings), "disponible": info != nil, "nature": "voix système macOS (AVSpeechSynthesizer), pas un modèle génératif"]
            if let i: [String: String] = info { out["voix"] = i }
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
