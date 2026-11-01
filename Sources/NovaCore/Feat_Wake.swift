import Foundation
#if canImport(Speech) && canImport(AVFoundation) && os(macOS)
import Speech
import AVFoundation
#endif

// MOT DE RÉVEIL « Nova » — reconnaissance LOCALE (SFSpeechRecognizer, sur l'appareil, fr-FR, gratuite).
// Désactivé par défaut ; démarré uniquement par l'utilisateur (POST /api/wake/start). Publie bus "wake" quand « Nova » est entendu.
// 25/10 : réglage durable « wake_word » (posé par /api/wake/start|stop, relancé au démarrage) ; « Nova » entendu = carillon + Live.
// Le texte reconnu n'est ni journalisé ni stocké.
public final class WakeListener {
    public static let shared: WakeListener = WakeListener()
    let lock: NSLock = NSLock()
    public private(set) var running: Bool = false
    public private(set) var lastError: String = ""
    public private(set) var hits: Int = 0
    var lastHit: Date = Date.distantPast
    var onWake: ((String) -> Void)? = nil
    #if canImport(Speech) && canImport(AVFoundation) && os(macOS)
    var engine: AVAudioEngine? = nil
    var request: SFSpeechAudioBufferRecognitionRequest? = nil
    var task: SFSpeechRecognitionTask? = nil
    var recognizer: SFSpeechRecognizer? = nil
    var generation: Int = 0
    #endif

    public func available() -> Bool {
        #if canImport(Speech) && canImport(AVFoundation) && os(macOS)
        guard let r: SFSpeechRecognizer = SFSpeechRecognizer(locale: Locale(identifier: "fr-FR")) else { return false }
        return r.supportsOnDeviceRecognition
        #else
        return false
        #endif
    }

    public func start(onWake: @escaping (String) -> Void, done: @escaping (Bool, String) -> Void) {
        #if canImport(Speech) && canImport(AVFoundation) && os(macOS)
        self.onWake = onWake
        SFSpeechRecognizer.requestAuthorization { (status: SFSpeechRecognizerAuthorizationStatus) in
            DispatchQueue.main.async {
                if status != .authorized {
                    self.lastError = "Reconnaissance vocale non autorisée (Réglages Système › Confidentialité › Reconnaissance vocale)."
                    done(false, self.lastError); return
                }
                let ok: Bool = self.begin()
                done(ok, self.lastError)
            }
        }
        #else
        done(false, "Indisponible sur ce système")
        #endif
    }

    public func stop() {
        #if canImport(Speech) && canImport(AVFoundation) && os(macOS)
        let work: () -> Void = {
            self.generation += 1
            self.teardown()
            self.running = false
        }
        if Thread.isMainThread { work() } else { DispatchQueue.main.sync(execute: work) }
        #endif
    }

    #if canImport(Speech) && canImport(AVFoundation) && os(macOS)
    func teardown() {
        task?.cancel(); task = nil
        request?.endAudio(); request = nil
        if let e: AVAudioEngine = engine {
            e.inputNode.removeTap(onBus: 0)
            e.stop()
        }
        engine = nil
    }

    /// À appeler sur le fil principal.
    func begin() -> Bool {
        teardown()
        guard let rec: SFSpeechRecognizer = SFSpeechRecognizer(locale: Locale(identifier: "fr-FR")) else {
            lastError = "Reconnaissance fr-FR indisponible"; running = false; return false
        }
        if !rec.supportsOnDeviceRecognition {
            lastError = "Reconnaissance sur l'appareil indisponible (télécharge la dictée française dans Réglages › Clavier › Dictée)."; running = false; return false
        }
        recognizer = rec
        let req: SFSpeechAudioBufferRecognitionRequest = SFSpeechAudioBufferRecognitionRequest()
        req.requiresOnDeviceRecognition = true
        req.shouldReportPartialResults = true
        req.taskHint = .search
        req.contextualStrings = ["Nova"]
        request = req
        let e: AVAudioEngine = AVAudioEngine()
        let input: AVAudioInputNode = e.inputNode
        let fmt: AVAudioFormat = input.outputFormat(forBus: 0)
        input.installTap(onBus: 0, bufferSize: 2048, format: fmt) { (buf: AVAudioPCMBuffer, _: AVAudioTime) in
            req.append(buf)
        }
        e.prepare()
        do { try e.start() } catch {
            lastError = "Micro : " + error.localizedDescription; input.removeTap(onBus: 0); running = false; return false
        }
        engine = e
        generation += 1
        let gen: Int = generation
        task = rec.recognitionTask(with: req) { [weak self] (result: SFSpeechRecognitionResult?, err: Error?) in
            guard let self = self else { return }
            var heard: Bool = false
            var isFinal: Bool = false
            if let r: SFSpeechRecognitionResult = result {
                let txt: String = r.bestTranscription.formattedString.lowercased()
                heard = WakeListener.containsWake(txt)
                isFinal = r.isFinal
            }
            if heard || isFinal || err != nil {
                DispatchQueue.main.async {
                    guard gen == self.generation, self.running else { return }
                    if heard && Date().timeIntervalSince(self.lastHit) > 3.0 {
                        self.lastHit = Date(); self.hits += 1
                        if let cb: (String) -> Void = self.onWake { cb(nowISO()) }
                    }
                    // Repart sur une tâche neuve (transcript remis à zéro, limite ~1 min des tâches), sans boucle serrée.
                    let delay: Double = (err != nil && !heard) ? 1.5 : 0.2
                    self.teardown()
                    DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
                        if self.running { _ = self.begin() }
                    }
                }
            }
        }
        running = true; lastError = ""
        return true
    }
    #endif

    static func containsWake(_ t: String) -> Bool {
        let words: [String] = t.components(separatedBy: CharacterSet.alphanumerics.inverted)
        for w in words where w == "nova" || w == "novà" || w == "nowa" { return true }
        return false
    }
}

extension NovaApp {
    /// 25/10 : « Nova » entendu → petit carillon + session Live (même chemin que le bouton Live).
    /// Le Live coupe lui-même l'écoute du mot de réveil et la restaure à son arrêt.
    static func wakeTriggered(ts: String, bus busRef: Bus) {
        busRef.publish("wake", ["word": "nova", "ts": ts])
        let live: VoiceLiveEngine = VoiceLiveEngine.shared
        let actif: Bool = (live.snapshot()["actif"] as? Bool) ?? false
        if actif { return }
        DispatchQueue.global(qos: .userInitiated).async {
            _ = runProcess("/usr/bin/afplay", ["-v", "0.5", "/System/Library/Sounds/Tink.aiff"], timeout: 3)
        }
        live.start { (ok: Bool, err: String?) in
            busRef.publish("wake_live", ["ok": ok, "erreur": err ?? ""])
        }
    }

    func wakeRoutes() {
        let s = server
        let w: WakeListener = WakeListener.shared
        let busRef: Bus = bus
        let onWake: (String) -> Void = { (ts: String) in NovaApp.wakeTriggered(ts: ts, bus: busRef) }
        s.on("GET", "/api/wake/status") { [self] _, res in
            res.json(["running": w.running, "available": w.available(), "error": w.lastError, "hits": w.hits,
                      "wake_word": settings.get("wake_word", false)])
        }
        s.on("POST", "/api/wake/start") { [self] _, res in
            // 25/10 : le Live tient le micro — on n'ouvre pas une 2e écoute par-dessus.
            let liveOn: Bool = (VoiceLiveEngine.shared.snapshot()["actif"] as? Bool) ?? false
            if liveOn {
                res.json(["ok": false, "running": false, "error": "conversation Live en cours — réessaie après l'avoir terminée"], status: 409); return
            }
            let sem: DispatchSemaphore = DispatchSemaphore(value: 0)
            var ok: Bool = false
            var msg: String = ""
            w.start(onWake: onWake, done: { (o: Bool, m: String) in ok = o; msg = m; sem.signal() })
            _ = sem.wait(timeout: .now() + 20)
            if ok {
                settings.set(["wake_word": true])   // 25/10 : réglage durable, relancé au démarrage de Nova
                busRef.publish("wake_state", ["running": true])
            }
            res.json(["ok": ok, "running": w.running, "error": msg], status: ok ? 200 : 500)
        }
        s.on("POST", "/api/wake/stop") { [self] _, res in
            w.stop()
            settings.set(["wake_word": false])
            bus.publish("wake_state", ["running": false])
            res.json(["ok": true, "running": false])
        }
        // 25/10 : « wake_word » (défaut false) — si activé, l'écoute locale reprend au lancement (après 4 s).
        if settings.get("wake_word", false) {
            DispatchQueue.main.asyncAfter(deadline: .now() + 4.0) {
                if w.running { return }
                w.start(onWake: onWake, done: { (o: Bool, _: String) in
                    if o { busRef.publish("wake_state", ["running": true]) }
                })
            }
        }
    }
}
