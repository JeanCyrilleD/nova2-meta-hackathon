import Foundation
// MUSE-PARTOUT (26/10, ordre d'Ahadi) : defauts de ce fichier sur Muse (voir ordres dans Brains.swift).
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
#if canImport(AVFoundation) && os(macOS)
import AVFoundation
import CoreAudio
import AudioToolbox
#endif
#if canImport(Speech) && os(macOS)
import Speech
#endif

// VL · CONVERSATION VOCALE LIVE — version hackathon Meta (100 % Meta pour les modèles).
// Pipeline 100 % natif (aucun aller-retour WebView) :
//   micro → AVAudioEngine (entrée + sortie sur le MÊME moteur : condition de l'AEC système)
//         → conversion PCM16 mono 16 kHz → VAD énergie (barge-in + bornes de parole)
//         → reconnaissance vocale SYSTÈME macOS (SFSpeechRecognizer, fr-FR, partiels — patron Feat_Dictee/Wake)
//   cerveau → Router.chat épinglé (solo) sur un cerveau Meta (Spark, reasoning_effort « none »),
//             prompt oral dédié, historique en mémoire de session, deltas découpés en phrases
//   voix → synthèse vocale SYSTÈME macOS (AVSpeechSynthesizer, LocalVoice) phrase par phrase
//   lecture → AVAudioPlayerNode sur le même moteur ; stop() = silence en < 50 ms.
// Meta ne publie aucun modèle de synthèse vocale : la voix système n'est pas un modèle génératif appelé par Nova.
// États publiés sur le bus « voix_live » (ecoute/reflexion/parole/repos) → panda synchronisé.
// Journal dédié voix_live_journal.jsonl : latences MESURÉES par tour, interruptions, replis nommés — jamais de contenu.
// Interrupteur « voix_live_enabled » (défaut FALSE).

// MARK: - VAD énergie (trames de 20 ms sur le flux 16 kHz converti)

final class VLvad {
    var baseThreshold: Float = 0.02
    /// Multiplicateur de seuil posé par le moteur pendant la parole de Nova (écho) :
    /// 1 hors parole · 1,4 avec AEC système · 2,5 sans AEC.
    var boost: Float = 1.0
    private(set) var inSpeech = false
    private(set) var speechStart: Date? = nil
    private(set) var lastVoiceAt: Date? = nil
    private var silenceFrames = 0
    var onSpeechStart: (() -> Void)? = nil
    var onSpeechEnd: (() -> Void)? = nil
    /// V4-B · écoute active : appelé UNE fois par pause dès 360 ms de silence (18 trames de 20 ms)
    /// au milieu de la parole — la fin de phrase acoustique, avant la fin de tour (600 ms).
    var onPause: (() -> Void)? = nil

    func feed(rms: Float, at now: Date) {
        if rms >= baseThreshold * boost {
            if !inSpeech { inSpeech = true; speechStart = now; onSpeechStart?() }
            lastVoiceAt = now
            silenceFrames = 0
        } else if inSpeech {
            silenceFrames += 1
            if silenceFrames == 18 { onPause?() }
            if silenceFrames >= 30 {   // 600 ms de silence = fin de parole acoustique
                inSpeech = false
                onSpeechEnd?()
            }
        }
    }
    /// Durée de la parole en cours (0 hors parole) — le barge-in exige ≥ 280 ms soutenus.
    func sustainedMs(at now: Date) -> Int {
        guard inSpeech, let s = speechStart else { return 0 }
        return Int(now.timeIntervalSince(s) * 1000)
    }
    func reset() { inSpeech = false; speechStart = nil; silenceFrames = 0 }
}

// MARK: - STT repli de session : SFSpeechRecognizer sur l'appareil (patron Feat_Wake/Dictee)
//
// Alimenté par les MÊMES buffers du tap (format natif) ; résultats partiels en continu.
// Fin de tour : résultat final du recognizer, ou silence (le moteur appelle forceEnd()
// après 800 ms de silence VAD suivant le dernier partiel). Le texte dicté n'est ni
// journalisé ni stocké : seuls les événements de latence le sont (moteur).

#if canImport(Speech) && canImport(AVFoundation) && os(macOS)
final class VLLocalSpeech {
    var onPartial: ((String) -> Void)? = nil
    var onFinal: ((String) -> Void)? = nil
    var onError: ((String) -> Void)? = nil
    private var rec: SFSpeechRecognizer? = nil
    private var req: SFSpeechAudioBufferRecognitionRequest? = nil
    private var task: SFSpeechRecognitionTask? = nil
    private(set) var lastText = ""
    private(set) var running = false
    private var generation = 0
    var contextual: [String] = []

    func start() -> Bool {
        stop()
        // VAGUE 2 : langue des réglages voix (auto → fr-FR), vocabulaire personnel.
        guard let r = SFSpeechRecognizer(locale: Locale(identifier: VoixReglages.localePrincipale())), r.isAvailable else { return false }
        rec = r
        contextual = VoixVocab.effectif()
        return beginTask()
    }

    /// VAGUE 2 : jette la tâche en cours SANS rien émettre (elle a entendu la voix de Nova) et repart.
    func discard() {
        lastText = ""
        generation += 1
        task?.cancel(); task = nil
        req?.endAudio(); req = nil
        if running { _ = beginTask() }
    }

    private func beginTask() -> Bool {
        guard let r = rec else { return false }
        let q = SFSpeechAudioBufferRecognitionRequest()
        q.shouldReportPartialResults = true
        q.taskHint = .dictation
        q.addsPunctuation = true
        q.contextualStrings = contextual
        if r.supportsOnDeviceRecognition && VoixReglages.surAppareil() { q.requiresOnDeviceRecognition = true }
        req = q
        generation += 1
        let gen = generation
        task = r.recognitionTask(with: q) { [weak self] result, err in
            guard let self = self, gen == self.generation else { return }
            if let res = result {
                let t = res.bestTranscription.formattedString
                self.lastText = t
                if res.isFinal {
                    let fin = t.trimmingCharacters(in: .whitespacesAndNewlines)
                    self.lastText = ""
                    if !fin.isEmpty { self.onFinal?(fin) }
                    // Tâche neuve pour le tour suivant (limite ~1 min par tâche).
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { [weak self] in
                        guard let self = self, self.running else { return }
                        if !self.beginTask() { self.onError?("reconnaissance locale : reprise de tâche impossible") }
                    }
                } else if !t.isEmpty {
                    self.onPartial?(t)
                }
            } else if err != nil {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) { [weak self] in
                    guard let self = self, self.running else { return }
                    if !self.beginTask() { self.onError?("reconnaissance locale en échec répété") }
                }
            }
        }
        running = true
        return true
    }

    func append(_ buf: AVAudioPCMBuffer) { req?.append(buf) }

    /// Clôt le tour courant : le dernier partiel devient le final (silence constaté par le VAD).
    func forceEnd() {
        let t = lastText.trimmingCharacters(in: .whitespacesAndNewlines)
        lastText = ""
        generation += 1   // le rappel de la tâche annulée sera ignoré
        task?.cancel(); task = nil
        req?.endAudio(); req = nil
        if !t.isEmpty { onFinal?(t) }
        if running { _ = beginTask() }
    }

    func stop() {
        running = false
        generation += 1
        task?.cancel(); task = nil
        req?.endAudio(); req = nil
        lastText = ""
    }
}
#endif

// MARK: - Lecture native : AVAudioPlayerNode sur le moteur audio partagé

#if canImport(AVFoundation) && os(macOS)
final class VLLivePlayer {
    let node = AVAudioPlayerNode()
    let format: AVAudioFormat
    private var pending = 0
    private var generation = 0
    private let lock = NSLock()
    var onDrained: (() -> Void)? = nil
    var onLevel: ((Float) -> Void)? = nil

    init() {
        format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 24000, channels: 1, interleaved: false)!
    }

    func attach(to engine: AVAudioEngine) {
        engine.attach(node)
        engine.connect(node, to: engine.mainMixerNode, format: format)
    }

    /// Planifie un paquet PCM16 24 kHz (voix système). Niveau RMS réel → panda.
    func schedule(pcm16: Data) {
        let n = pcm16.count / 2
        guard n > 0, let buf = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(n)),
              let dst = buf.floatChannelData?[0] else { return }
        buf.frameLength = AVAudioFrameCount(n)
        var peak: Float = 0
        pcm16.withUnsafeBytes { raw in
            let src = raw.bindMemory(to: Int16.self)
            for i in 0..<n {
                let v = Float(src[i]) / 32768.0
                dst[i] = v
                let a = abs(v); if a > peak { peak = a }
            }
        }
        lock.lock(); pending += 1; let gen = generation; lock.unlock()
        node.scheduleBuffer(buf, completionCallbackType: .dataPlayedBack) { [weak self] _ in
            guard let self = self else { return }
            self.lock.lock()
            if gen == self.generation {
                self.pending -= 1
                let drained = self.pending <= 0
                self.lock.unlock()
                if drained { self.onDrained?() }
            } else { self.lock.unlock() }
        }
        onLevel?(min(1, peak * 1.6))
    }

    var isPlaying: Bool { lock.lock(); defer { lock.unlock() }; return pending > 0 }

    /// Barge-in : le son cesse dans le buffer courant (< 50 ms), les fins de buffers
    /// déjà planifiées sont invalidées par génération.
    func stopNow() {
        lock.lock(); generation += 1; pending = 0; lock.unlock()
        node.stop()
        node.reset()
    }
}
#endif

// MARK: - Découpe du flux cerveau en phrases disibles

enum VLSentences {
    /// Extrait les phrases complètes du tampon (une ponctuation forte SUIVIE d'un blanc,
    /// pour ne jamais couper un fragment en vol) ; le reliquat reste en tampon.
    static func extract(_ buf: String) -> (ready: [String], rest: String) {
        var ready: [String] = []
        var rest = buf
        while let (s, r) = firstSentence(in: rest) { ready.append(s); rest = r }
        if rest.count >= 170, let idx = rest.lastIndex(of: " ") {
            let s = String(rest[..<idx]).trimmingCharacters(in: .whitespacesAndNewlines)
            if s.count >= 40 { ready.append(clean(s)); rest = String(rest[rest.index(after: idx)...]) }
        }
        return (ready, rest)
    }

    static func firstSentence(in s: String) -> (String, String)? {
        var i = s.startIndex
        var seen = 0
        while i < s.endIndex {
            let c = s[i]
            seen += 1
            let next = s.index(after: i)
            if c == "\n" {
                let sent = String(s[..<i]).trimmingCharacters(in: .whitespacesAndNewlines)
                if sent.count >= 4 { return (clean(sent), dropLeadingBlanks(String(s[next...]))) }
            } else if (c == "." || c == "!" || c == "?" || c == "…") && next < s.endIndex {
                let after = s[next]
                // « 2.5 » n'est pas une fin de phrase ; une ponctuation doit être suivie d'un blanc.
                if !(c == "." && after.isNumber) && (after == " " || after == "\n") && seen >= 8 {
                    let sent = String(s[..<next]).trimmingCharacters(in: .whitespacesAndNewlines)
                    if sent.count >= 4 { return (clean(sent), dropLeadingBlanks(String(s[next...]))) }
                }
            }
            i = next
        }
        return nil
    }

    static func dropLeadingBlanks(_ s: String) -> String {
        var t = s
        while t.first == " " || t.first == "\n" { t.removeFirst() }
        return t
    }

    /// Même nettoyage que Voice.speak (le markdown ne se lit pas), plus les balises éventuelles.
    static func clean(_ s: String) -> String {
        var t = s.replacingOccurrences(of: "\\*|#|_|`", with: "", options: .regularExpression)
        t = t.replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression)
        return t.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

// MARK: - Moteur de session

public final class VoiceLiveEngine {
    public static let shared = VoiceLiveEngine()
    private init() {}

    static let systemPrompt = """
    Tu es Nova, l'alter ego numérique d'Ahadi Jean Cyrille Dahani — son copilote, qui le connaît et pense comme lui. Vous êtes en CONVERSATION VOCALE en temps réel : il te parle, tu réponds à voix haute, avec ta voix. Tu le tutoies ; l'essentiel d'abord, sobre, précis, chaleureux, sans remplissage ni formule d'assistant. Tu n'inventes rien : ce que tu ne sais pas, tu le dis en une phrase. Rien n'est envoyé, payé ou supprimé sans son GO explicite.
    Règles de parole : français naturel et chaleureux ; phrases courtes ; une à trois phrases par réponse sauf s'il demande un développement ; commence toujours par une première phrase courte et complète. Aucun markdown, aucune liste, aucune balise, aucun émoji, aucune adresse web lue à voix haute : uniquement du texte à dire. Épelle les sigles peu courants. Ahadi peut t'interrompre à tout moment : ce qu'il a déjà entendu fait foi — ne le répète pas si la conversation a tourné. Réponds à SA dernière question, rien d'autre : pas d'annonce de ce que tu vas faire (« je regarde », « je lance »), pas de reprise d'une phrase déjà dite dans ce tour ou le précédent, pas de sujet qu'il n'a pas abordé.
    Tu n'as pas d'outils toi-même dans ce mode, mais l'agent de Nova les a et travaille pour toi en arrière-plan : si la demande exige une action ou un accès (mails, agenda, fichiers, web, Éclats, brouillon, document, recherche), commence ta réponse EXACTEMENT par la balise <mission> (elle n'est jamais dite), puis dis en une seule phrase courte que tu lances la tâche et que tu lui diras le résultat. N'invente jamais un résultat, ne prétends jamais l'avoir déjà fait. Sans action requise, réponds normalement, sans balise.
    Variété (26/10) : ne redis jamais une phrase déjà prononcée dans cette séance, change de tournure à chaque réponse. Écoute : Ahadi parle français avec l'accent burkinabè, la transcription peut être imparfaite — devine le sens raisonnable ; si c'est vraiment incompréhensible ou que ça ressemble à du bruit, demande-lui en quelques mots de répéter, sans deviner un sujet. Si sa phrase contient des morceaux de ce que TU viens de dire, c'est l'écho de ta voix : ignore-les. Dis les nombres, dates et heures en toutes lettres naturelles.
    """

    /// BRAIN-B (24/10) : prompt du tour — identité vocale + PROFIL D'AHADI (stable, avant cacheMark)
    /// puis faits mémorisés pertinents pour ce que vient de dire Ahadi + date (dynamique).
    func turnSystem(_ userText: String) -> String {
        var s: String = VoiceLiveEngine.systemPrompt + "\n\n" + NovaSoul.profileBlock(memory: memory)
        s += Persona.cacheMark
        let df = DateFormatter(); df.locale = Locale(identifier: "fr_FR"); df.dateFormat = "EEEE d MMMM yyyy 'à' HH:mm"
        s += "DATE ET HEURE (horloge du Mac) : " + df.string(from: Date()) + "."
        if let m = memory {
            let mb: String = m.promptBlock(max: 4, query: userText)
            if !mb.isEmpty { s += "\n" + mb }
        }
        return s
    }

    /// BRAIN-B : les échanges vocaux rejoignent le magasin normal des conversations (une
    /// conversation par session live), donc le chat écrit, le rappel et la mémoire les voient.
    private var voiceConvId: String? = nil
    private func recordVoice(role: String, text: String) {
        guard let c = convs else { return }
        let t: String = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if t.isEmpty { return }
        if voiceConvId == nil || c.get(voiceConvId ?? "") == nil {
            let df = DateFormatter(); df.locale = Locale(identifier: "fr_FR"); df.dateFormat = "dd/MM HH:mm"
            voiceConvId = c.create(title: "Voix live — " + df.string(from: Date()))
        }
        if let id = voiceConvId { _ = c.append(id, role: role, content: t, brain: role == "assistant" ? "voix live" : nil) }
    }

    // Configuration posée une seule fois par voiceLiveRoutes() (patron WakeListener.shared).
    private var keys: KeyStore? = nil
    private var settings: Settings? = nil
    private var router: Router? = nil
    private var publishFn: ((String, [String: Any]) -> Void)? = nil
    private var configured = false
    private var memory: Memory? = nil
    private var convs: Conversations? = nil

    public func configure(keys: KeyStore, settings: Settings, router: Router, memory: Memory? = nil, convs: Conversations? = nil, publish: @escaping (String, [String: Any]) -> Void) {
        guard !configured else { return }
        configured = true
        self.keys = keys; self.settings = settings; self.router = router; self.publishFn = publish
        self.memory = memory; self.convs = convs
    }

    let journal = Journal("voix_live_journal.jsonl")
    private let q = DispatchQueue(label: "nova.voixlive.etat", qos: .userInitiated)
    private let brainQ = DispatchQueue(label: "nova.voixlive.cerveau", qos: .userInitiated)
    private let ttsQ = DispatchQueue(label: "nova.voixlive.tts", qos: .userInitiated)

    // État (mutations sur q ; lectures d'instantané sous verrou).
    private let stateLock = NSLock()
    private var _state = "off"
    public var stateName: String { stateLock.lock(); defer { stateLock.unlock() }; return _state }
    private var running = false
    private var generation = 0
    private var sessionStartedAt: Date? = nil
    private var turnCounter = 0
    private var history: [ChatMsg] = []

    // Audio (moteur unique entrée + sortie).
    #if canImport(AVFoundation) && os(macOS)
    private var audioEngine: AVAudioEngine? = nil
    private var converter: AVAudioConverter? = nil
    /// 30/10 nuit (Ahadi : « répare le problème des 7 canaux du micro ») : micro multicanal (réseau de 7 capsules du Mac).
    /// Avant : la conversion 7 → 1 canal prenait un canal fixe, parfois muet → « il ne répond pas ». Désormais le canal le
    /// plus fort est choisi à chaque paquet (avec inertie), puis converti en 16 kHz mono.
    private var monoFormat: AVAudioFormat? = nil
    private var bestChannel: Int = 0
    private var player: VLLivePlayer? = nil
    #endif
    private var aecActive = false
    private let vad = VLvad()
    private var vadAccum: [Int16] = []
    private var sendAccum: [Int16] = []
    private var bargeSignalled = false
    private var lastSpeechEndAt: Date? = nil
    /// 31/10 (voix/mémoire/Live) : borne basse de la fin de parole du tour suivant (final du tour précédent).
    /// Journal du 25/10 et du 27/10 : 3 des 5 tours à 16–46 s portaient une « fin de parole » ANTÉRIEURE à la fin
    /// du tour précédent (lastSpeechEndAt jamais remis à zéro) — délai fictif, pas une attente réelle.
    private var lastTurnFinalAt: Date? = nil
    /// 31/10 : un partiel attend sa fin de tour (remis à faux à chaque final).
    private var partialPending = false
    private var forcedEndPending = false

    // STT.
    private enum STTMode { case none, local }
    private var startCompletion: ((Bool, String?) -> Void)? = nil
    private var sttMode: STTMode = .none
    private var sttEngineName = ""
    #if canImport(Speech) && canImport(AVFoundation) && os(macOS)
    private let localSpeech = VLLocalSpeech()
    #endif
    private var lastPartial = ""
    private var lastPartialAt = Date.distantPast
    private var lastPartialPublishAt = Date.distantPast

    // Tour courant.
    private final class VLTurn {
        let id: Int
        let userText: String
        let userFinalAt: Date
        let speechEndAt: Date?
        let sttEngine: String
        var firstFragmentAt: Date? = nil
        var firstAudioAt: Date? = nil
        var responseText = ""
        var spokenText = ""
        var brainDone = false
        var brainError: String? = nil
        var brainUsed: String? = nil
        var interrupted = false
        var wsFinal = false
        var wsFailed = false
        var httpUsed = false
        var httpPending = 0
        var finished = false
        var fillerSaid = false   // VAGUE 2 : phrase d'attente déjà dite pour ce tour
        // 31/10 (voix/mémoire/Live) : instrumentation par étape + relance du cerveau muet.
        var speechEndSource = "inconnue"     // vad_fin · vad_voix · inconnue (horodatage d'un tour précédent écarté)
        var ctxMs: Int = -1                  // assemblage du prompt du tour (profil + mémoire pertinente)
        var brainCallAt: Date? = nil         // envoi de l'appel au cerveau (après le contexte)
        var brainAttempt: Int = 0            // tentative courante (une relance invalide la précédente)
        var triedBrains: [String] = []
        var forcedEnd = false                // tour clos par ForceEndpoint (bruit de fond qui gardait le tour ouvert)
        init(id: Int, userText: String, userFinalAt: Date, speechEndAt: Date?, sttEngine: String) {
            self.id = id; self.userText = userText; self.userFinalAt = userFinalAt
            self.speechEndAt = speechEndAt; self.sttEngine = sttEngine
        }
    }
    private var currentTurn: VLTurn? = nil
    private var lastSpokenText = ""
    private var lastDrainAt: Date? = nil
    /// 26/10 : fin de la surdité du micro (secondes epoch) — semi-duplex quand l'AEC système manque.
    private var micMutedUntil: Double = 0
    private var elFailStreak: Int = 0
    /// 26/10 : motif réel de l'échec de l'AEC système (journalisé à stt_pret).
    private var aecError: String = ""
    /// Vrai si le micro doit être ignoré (Nova parle ou vient de parler, sans annulation d'écho).
    private func micGated() -> Bool {
        if aecActive { return false }
        stateLock.lock(); defer { stateLock.unlock() }
        return _state == "parole" || Date().timeIntervalSince1970 < micMutedUntil
    }
    private var lastLevelPublishAt = Date.distantPast

    // TTS.
    // Voix système macOS (Feat_VoixLocale.swift) — seul moteur de synthèse vocale de la version Meta.
    private var ttsLocal = true

    private var wakeWasRunning = false

    // MARK: démarrage / arrêt

    /// Démarre la session (asynchrone : permission micro, moteur audio, STT).
    /// completion(false, motif) = refus NOMMÉ — jamais de démarrage simulé.
    public func start(completion: @escaping (Bool, String?) -> Void) {
        q.async { [weak self] in
            guard let self = self else { completion(false, "moteur absent"); return }
            guard self.configured, let settings = self.settings, let keys = self.keys else {
                completion(false, "moteur non configuré"); return
            }
            guard settings.get("voix_live_enabled", false) else {
                completion(false, "interrupteur fermé : active « voix_live_enabled » dans les réglages pour autoriser la conversation live"); return
            }
            guard !self.running else { completion(true, nil); return }
            _ = keys
            #if canImport(AVFoundation) && canImport(Speech) && os(macOS)
            if Dictee.shared.running {
                completion(false, "dictée système en cours (⌃⌥D) — termine-la avant de lancer la conversation live"); return
            }
            let mic = AVCaptureDevice.authorizationStatus(for: .audio)
            if mic == .denied || mic == .restricted {
                completion(false, "micro refusé : autorise Nova dans Réglages Système › Confidentialité et sécurité › Micro"); return
            }
            if mic == .notDetermined {
                AVCaptureDevice.requestAccess(for: .audio) { [weak self] granted in
                    guard let self = self else { completion(false, "moteur absent"); return }
                    if granted { self.start(completion: completion) }
                    else { completion(false, "micro refusé par l'utilisateur") }
                }
                return
            }
            self.beginAudio(completion: completion)
            #else
            completion(false, "conversation live indisponible sur ce système")
            #endif
        }
    }

    #if canImport(AVFoundation) && canImport(Speech) && os(macOS)
    /// Sur q. Construit le moteur audio (fil principal), puis branche le STT.
    private func beginAudio(completion: @escaping (Bool, String?) -> Void) {
        guard let settings = self.settings else { completion(false, "réglages absents"); return }
        if WakeListener.shared.running {
            wakeWasRunning = true
            WakeListener.shared.stop()
        }
        let seuil: Double = settings.get("voix_live_vad_seuil", 0.02)
        vad.baseThreshold = Float(seuil)
        DispatchQueue.main.async { [weak self] in
            guard let self = self else { completion(false, "moteur absent"); return }
            // 25/10 : 1er essai avec l'AEC système ; s'il échoue (ex. -10875 : micro tenu ailleurs, Bluetooth),
            // 2e essai SANS traitement vocal sur un moteur neuf — au lieu d'un refus brut.
            var built: (AVAudioEngine, VLLivePlayer)? = self.buildEngine(wantAEC: true)
            if built == nil { built = self.buildEngine(wantAEC: true, outputVP: false) }   // 26/10 : AEC posé sur l'entrée seule (variante acceptée par certains Mac)
            // 29/10 (journal : AEC refusé, entrée 48 kHz à 7 canaux) : l'entrée par défaut est un périphérique multicanal
            // (agrégat ou carte virtuelle) que l'annulation d'écho refuse — nouvel essai sur le micro intégré du Mac.
            if built == nil, let mic = VLAudioDevices.builtInMic() { built = self.buildEngine(wantAEC: true, outputVP: true, device: mic) }
            if built == nil, let mic = VLAudioDevices.builtInMic() { built = self.buildEngine(wantAEC: true, outputVP: false, device: mic) }
            if built == nil { built = self.buildEngine(wantAEC: false) }
            guard let pair = built else {
                self.q.async { [weak self] in
                    self?.teardownAudio()
                    completion(false, "micro indisponible : il est peut-être utilisé par une autre app (dictée, visio, Muse) ou un casque Bluetooth — ferme-la puis réessaie")
                }
                return
            }
            let engine: AVAudioEngine = pair.0
            let player: VLLivePlayer = pair.1
            player.node.play()
            self.audioEngine = engine
            self.q.async { [weak self] in
                guard let self = self else { completion(false, "moteur absent"); return }
                self.running = true
                self.sessionStartedAt = Date()
                self.connectSTT(completion: completion)
            }
        }
    }

    /// Fil principal. Construit et démarre un moteur ; nil si le démarrage échoue (moteur nettoyé).
    private func buildEngine(wantAEC: Bool, outputVP: Bool = true, device: AudioDeviceID? = nil) -> (AVAudioEngine, VLLivePlayer)? {
        let engine: AVAudioEngine = AVAudioEngine()
        let input: AVAudioInputNode = engine.inputNode
        if let dev = device, let au = input.audioUnit {
            var d: AudioDeviceID = dev
            let st: OSStatus = AudioUnitSetProperty(au, kAudioOutputUnitProperty_CurrentDevice, kAudioUnitScope_Global, 0, &d, UInt32(MemoryLayout<AudioDeviceID>.size))
            if st != noErr { aecError = "micro intégré non sélectionnable (" + String(st) + ")"; return nil }
        }
        var aec: Bool = false
        if wantAEC {
            do { try input.setVoiceProcessingEnabled(true); aec = input.isVoiceProcessingEnabled } catch { aec = false; aecError = "traitement vocal refusé : " + error.localizedDescription }
            if aec && outputVP { do { try engine.outputNode.setVoiceProcessingEnabled(true) } catch { } }
        }
        let inFmt: AVAudioFormat = input.outputFormat(forBus: 0)
        if inFmt.sampleRate <= 0 || inFmt.channelCount == 0 { return nil }
        let player: VLLivePlayer = VLLivePlayer()
        player.attach(to: engine)
        guard let outFmt = AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: 16000, channels: 1, interleaved: true) else { return nil }
        // 30/10 nuit : entrée multicanal → la conversion part d'un format MONO (le canal choisi dans ingest).
        let mono: AVAudioFormat? = inFmt.channelCount > 1 ? AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: inFmt.sampleRate, channels: 1, interleaved: false) : nil
        let conv: AVAudioConverter? = AVAudioConverter(from: mono ?? inFmt, to: outFmt)
        input.installTap(onBus: 0, bufferSize: 4096, format: inFmt) { [weak self] buf, _ in
            self?.ingest(buf)
        }
        engine.prepare()
        do { try engine.start() } catch {
            if wantAEC {
                var m: String = "moteur avec AEC non démarré : " + error.localizedDescription
                m += " (entrée " + String(Int(inFmt.sampleRate)) + " Hz, " + String(inFmt.channelCount) + " canaux"
                m += device != nil ? ", micro intégré)" : ")"
                aecError = m
            }
            input.removeTap(onBus: 0)
            engine.stop()
            return nil
        }
        self.aecActive = aec
        self.converter = conv
        self.monoFormat = mono
        self.bestChannel = 0
        self.player = player
        return (engine, player)
    }

    private func teardownAudio() {
        if let e = audioEngine {
            e.inputNode.removeTap(onBus: 0)
            e.stop()
        }
        audioEngine = nil
        converter = nil
        player = nil
    }
    #endif

    /// Arrêt complet de la session (routes + sécurité). Restauré : le mot de réveil.
    public func stop() {
        q.async { [weak self] in
            guard let self = self, self.running else { return }
            self.generation += 1
            #if canImport(Speech) && canImport(AVFoundation) && os(macOS)
            self.localSpeech.stop()
            self.player?.stopNow()
            DispatchQueue.main.async { [weak self] in self?.teardownAudio() }
            #endif
            let duree = self.sessionStartedAt.map { Int(Date().timeIntervalSince($0)) } ?? 0
            self.journal.add(["type": "session", "evenement": "stop", "duree_s": duree, "tours": self.turnCounter])
            self.running = false
            self.currentTurn = nil
            self.voiceConvId = nil   // BRAIN-B : la session suivante ouvre sa propre conversation
            self.history = []        // 26/10 : une nouvelle séance ne traîne plus l'historique oral de la précédente
            self.sttMode = .none
            self.ttsLocal = true
            self.setState("off")
            if self.wakeWasRunning {
                self.wakeWasRunning = false
                #if canImport(Speech) && canImport(AVFoundation) && os(macOS)
                // 25/10 : begin() se joue sur le fil principal (contrat de WakeListener) — ici on est sur q.
                DispatchQueue.main.async { _ = WakeListener.shared.begin() }
                #endif
            }
        }
    }

    /// Instantané pour GET /api/voix-live/status.
    public func snapshot() -> [String: Any] {
        var out: [String: Any] = ["actif": running, "etat": stateName, "aec": aecActive,
                                  "stt_moteur": sttEngineName, "tours": turnCounter]
        if let settings = settings { out["interrupteur"] = settings.get("voix_live_enabled", false) }
        if let t0 = sessionStartedAt { out["depuis_s"] = Int(Date().timeIntervalSince(t0)) }
        return out
    }

    // MARK: état + publication

    private func setState(_ s: String, label: String? = nil) {
        stateLock.lock()
        let was: String = _state
        _state = s
        // 26/10 : semi-duplex sans AEC — le micro reste sourd 0,8 s après la fin de la parole de Nova (traîne d'écho de la pièce).
        if was == "parole" && s != "parole" { micMutedUntil = Date().timeIntervalSince1970 + 0.8 }
        stateLock.unlock()
        vad.boost = (s == "parole") ? (aecActive ? 1.4 : 2.5) : 1.0
        let labels = ["ecoute": "Nova · écoute", "reflexion": "Nova · réfléchit", "parole": "Nova · parle", "off": "Nova · au repos"]
        publishFn?("voix_live", ["etat": s, "label": label ?? labels[s] ?? "", "tour": turnCounter])
    }

    // MARK: ingestion micro (fil temps réel du tap — travail minimal, aucun blocage)

    #if canImport(AVFoundation) && os(macOS)
    private func ingest(_ buf: AVAudioPCMBuffer) {
        // 26/10 (diagnostic des séances : aec=false, la voix de Nova finissait DANS la phrase d'Ahadi) :
        // sans AEC, pendant que Nova parle, le STT reçoit du silence et le VAD ne voit rien — plus d'écho transcrit.
        let gated: Bool = micGated()
        if sttMode == .local && !gated {
            #if canImport(Speech) && canImport(AVFoundation) && os(macOS)
            localSpeech.append(buf)
            #endif
        }
        guard let conv = converter else { return }
        // 30/10 nuit : micro multicanal — on garde le canal le plus fort (inertie : changer seulement s'il est 1,5 × plus fort).
        var src: AVAudioPCMBuffer = buf
        if let mf = monoFormat, buf.format.channelCount > 1, !buf.format.isInterleaved, let fch = buf.floatChannelData, let m = AVAudioPCMBuffer(pcmFormat: mf, frameCapacity: buf.frameLength), let dst = m.floatChannelData?[0] {
            let n: Int = Int(buf.frameLength), cc: Int = Int(buf.format.channelCount)
            var best: Int = min(bestChannel, cc - 1), bestE: Float = -1, curE: Float = 0
            for c in 0..<cc {
                var e: Float = 0; let p = fch[c]
                var i: Int = 0; while i < n { let v = p[i]; e += v * v; i += 4 }
                if c == bestChannel { curE = e }
                if e > bestE { bestE = e; best = c }
            }
            if best != bestChannel && bestE > curE * 1.5 { bestChannel = best }
            let p = fch[min(bestChannel, cc - 1)]
            for i in 0..<n { dst[i] = p[i] }
            m.frameLength = buf.frameLength
            src = m
        }
        let outFmt = AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: 16000, channels: 1, interleaved: true)!
        let cap = AVAudioFrameCount(Double(src.frameLength) * 16000.0 / src.format.sampleRate) + 32
        guard let out = AVAudioPCMBuffer(pcmFormat: outFmt, frameCapacity: cap) else { return }
        var consumed = false
        let status = conv.convert(to: out, error: nil) { _, st in
            if consumed { st.pointee = .noDataNow; return nil }
            consumed = true; st.pointee = .haveData; return src
        }
        guard status != .error, out.frameLength > 0, let ch = out.int16ChannelData?[0] else { return }
        let samples: [Int16] = gated ? [Int16](repeating: 0, count: Int(out.frameLength)) : [Int16](UnsafeBufferPointer(start: ch, count: Int(out.frameLength)))
        // VAD par trames de 320 échantillons (20 ms).
        vadAccum += samples
        while vadAccum.count >= 320 {
            let frame = Array(vadAccum.prefix(320))
            vadAccum.removeFirst(320)
            var sum: Float = 0
            for s in frame { let v = Float(s) / 32768.0; sum += v * v }
            let rms = (sum / 320.0).squareRoot()
            let now = Date()
            vad.feed(rms: rms, at: now)
            let st = stateName
            // 25/10 : sans AEC (haut-parleurs, traitement vocal refusé par macOS), le VAD entend la voix de Nova elle-même :
            // il ne coupe plus. L'interruption passe alors par un vrai partiel/final transcrit (≥ 4 mots, pas l'écho) ou le bouton.
            if aecActive && st == "parole" && vad.sustainedMs(at: now) >= 300 && !bargeSignalled {   // 26/10 : jamais pendant « reflexion » (une toux annulait la réponse)
                bargeSignalled = true
                q.async { [weak self] in self?.bargeIn(manuelle: false) }
            }
            if !vad.inSpeech { bargeSignalled = false }
        }
    }
    #endif
}

// MARK: - Moteur (suite) : STT, tours, cerveau, TTS, barge-in

extension VoiceLiveEngine {

    // MARK: STT — reconnaissance vocale système macOS

    private func fireStart(_ ok: Bool, _ err: String?) {
        let c = startCompletion
        startCompletion = nil
        c?(ok, err)
    }

    private func connectSTT(completion: @escaping (Bool, String?) -> Void) {
        startCompletion = completion
        vad.onSpeechEnd = { [weak self] in self?.q.async { self?.handleSpeechEnd() } }
        vad.onPause = { [weak self] in self?.q.async { self?.handlePause() } }
        #if canImport(AVFoundation) && os(macOS)
        player?.onDrained = { [weak self] in
            self?.q.async { guard let self = self else { return }
                self.lastDrainAt = Date()
                self.stateLock.lock(); self.micMutedUntil = Date().timeIntervalSince1970 + 0.8; self.stateLock.unlock()
                if let t = self.currentTurn { self.maybeFinishTurn(t) }
            }
        }
        player?.onLevel = { [weak self] v in
            guard let self = self, self.stateName == "parole" else { return }
            let now = Date()
            if now.timeIntervalSince(self.lastLevelPublishAt) > 0.07 {   // 25/10 : ~12/s (avant ~6/s) — lip-sync du compagnon
                self.lastLevelPublishAt = now
                self.publishFn?("voix_live", ["niveau": Double(v)])
            }
        }
        #endif
        fallbackToLocal(reason: "version Meta : reconnaissance vocale système macOS")
    }

    /// STT de session : reconnaissance vocale système (SFSpeechRecognizer).
    private func fallbackToLocal(reason: String) {
        journal.add(["type": "session", "evenement": "stt_repli", "moteur": "local-sfspeech", "raison": shortError(reason, 140)])
        #if canImport(Speech) && canImport(AVFoundation) && os(macOS)
        let auth = SFSpeechRecognizer.authorizationStatus()
        if auth == .authorized {
            startLocalSpeech()
        } else if auth == .notDetermined {
            SFSpeechRecognizer.requestAuthorization { [weak self] s in
                self?.q.async { guard let self = self else { return }
                    if s == .authorized { self.startLocalSpeech() }
                    else { self.fireStart(false, "reconnaissance vocale refusée"); self.stop() }
                }
            }
        } else {
            fireStart(false, "reconnaissance vocale non autorisée : " + reason)
            stop()
        }
        #else
        fireStart(false, "aucun moteur de transcription disponible : " + reason)
        stop()
        #endif
    }

    #if canImport(Speech) && canImport(AVFoundation) && os(macOS)
    private func startLocalSpeech() {
        localSpeech.onPartial = { [weak self] t in self?.q.async { self?.handlePartial(t) } }
        localSpeech.onFinal = { [weak self] t in self?.q.async { self?.handleUserFinal(t, moteur: "local-sfspeech") } }
        localSpeech.onError = { [weak self] e in
            self?.q.async { guard let self = self, self.running else { return }
                self.journal.add(["type": "session", "evenement": "stt_erreur_locale", "raison": shortError(e, 120)])
                self.publishFn?("voix_live", ["etat": "erreur", "label": "Nova · écoute en panne"])
                self.stop()
            }
        }
        if localSpeech.start() {
            sttMode = .local
            sttEngineName = "local-sfspeech"
            journal.add(["type": "session", "evenement": "stt_pret", "moteur": "local-sfspeech", "aec": aecActive])
            setState("ecoute")
            fireStart(true, nil)
        } else {
            fireStart(false, "reconnaissance locale indisponible (fr-FR)")
            stop()
        }
    }
    #endif

    // MARK: événements de parole

    /// V4-B · écoute active : une pause de ~350 ms dans la voix d'Ahadi pendant qu'il parle à Nova
    /// est publiée sur le bus (« voix_live » · evenement « fin_phrase ») — le compagnon hoche la tête.
    /// Aucun contenu de conversation : seulement le fait et le numéro de tour.
    private func handlePause() {
        guard running, stateName == "ecoute" else { return }
        let tour: Int = turnCounter
        publishFn?("voix_live", ["evenement": "fin_phrase", "tour": tour])
    }

    private func handleSpeechEnd() {
        lastSpeechEndAt = vad.lastVoiceAt
        // Repli local : la fin de tour se décide ici (silence après le dernier partiel).
        #if canImport(Speech) && canImport(AVFoundation) && os(macOS)
        guard sttMode == .local, stateName == "ecoute", running else { return }
        let partialAt = lastPartialAt
        let txt = localSpeech.lastText
        guard !txt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        // VAGUE 2 : pause tolérée = réglage voix (600 ms de VAD déjà écoulées), 1,4 s par défaut.
        let extra: Double = max(0.3, Double(VoixReglages.pauseMs() - 600) / 1000.0)
        q.asyncAfter(deadline: .now() + extra) { [weak self] in
            guard let self = self, self.running, self.sttMode == .local, self.stateName == "ecoute" else { return }
            if self.lastPartialAt == partialAt { self.localSpeech.forceEnd() }
        }
        #endif
    }

    private func handlePartial(_ t: String) {
        guard running else { return }
        // VAGUE 2 · écho : pendant que Nova réfléchit/parle, un partiel n'est montré que s'il n'est
        // PAS sa propre voix — et s'il est franchement autre chose (≥ 3 mots, ≥ 4 sans AEC), c'est
        // une interruption volontaire : barge-in, même si le VAD n'a pas franchi son seuil.
        let st = stateName
        if st == "parole" || st == "reflexion" {
            guard let cur = currentTurn else { return }
            let nWords: Int = t.lowercased().components(separatedBy: CharacterSet.alphanumerics.inverted).filter { $0.count >= 3 }.count
            let echo: Double = echoContainment(t, cur.spokenText)
            if nWords >= (aecActive ? 3 : 4) && echo < 0.3 && st == "parole" {
                bargeIn(manuelle: false)
            } else {
                return
            }
        }
        lastPartial = t
        lastPartialAt = Date()
        partialPending = true   // 31/10 (voix/mémoire/Live)
        let now = Date()
        if now.timeIntervalSince(lastPartialPublishAt) > 0.15 {
            lastPartialPublishAt = now
            publishFn?("voix_live", ["partiel": t])
        }
    }

    /// Un tour utilisateur est complet : écho filtré, interruption si Nova parlait, sinon tour neuf.
    private func handleUserFinal(_ raw: String, moteur: String) {
        guard running else { return }
        var text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        partialPending = false   // 31/10 (voix/mémoire/Live)
        let wasForced: Bool = forcedEndPending
        forcedEndPending = false
        guard !text.isEmpty else { return }
        let st = stateName
        // 26/10 : séances réelles — « Laisse-moi réfléchir… Oui, je t'entends très bien, je suis là, dis-moi. » : la phrase de Nova
        // était COLLÉE dans celle d'Ahadi. On retire, phrase par phrase, ce qui reprend ce que Nova vient de dire.
        let spokenRecent: String = (currentTurn?.spokenText ?? "") + " " + lastSpokenText
        if !spokenRecent.trimmingCharacters(in: .whitespaces).isEmpty {
            let stripped: String = stripEcho(text, spokenRecent)
            if stripped != text {
                journal.add(["type": "tour", "evenement": "echo_retire", "avant": text.count, "apres": stripped.count])
                if stripped.isEmpty { return }
                text = stripped
            }
        }
        if (st == "parole" || st == "reflexion"), let cur = currentTurn,
           echoContainment(text, cur.spokenText) >= 0.7 {
            // Nova s'entend elle-même (haut-parleurs) : ce « final » est son écho, pas une interruption.
            journal.add(["type": "tour", "evenement": "echo_ignore", "chars": text.count, "pendant": st])
            return
        }
        if (st == "parole" || st == "reflexion") && !aecActive {
            // 25/10 : sans AEC, un final court ou proche de ce que Nova vient de dire est son propre écho, pas Ahadi.
            let nW: Int = text.lowercased().components(separatedBy: CharacterSet.alphanumerics.inverted).filter { (w: String) -> Bool in w.count >= 3 }.count
            let spokenAll: String = (currentTurn?.spokenText ?? "") + " " + lastSpokenText
            if nW < 4 || echoContainment(text, spokenAll) >= 0.4 {
                journal.add(["type": "tour", "evenement": "echo_ignore_sans_aec", "chars": text.count, "pendant": st])
                return
            }
        }
        if st == "parole" || st == "reflexion" {
            bargeIn(manuelle: false)   // le VAD n'a pas déclenché (voix basse) : ce final EST l'interruption
        } else if let d = lastDrainAt, Date().timeIntervalSince(d) < (aecActive ? 0.6 : 2.0), !lastSpokenText.isEmpty,
                  echoContainment(text, lastSpokenText) >= 0.8 {
            // 25/10 : sans AEC, la queue de la phrase de Nova revient par le micro jusqu'à plusieurs secondes après —
            // elle était prise pour une demande d'Ahadi (« Une seconde, je prépare ta journée… » devenu mission).
            journal.add(["type": "tour", "evenement": "echo_ignore", "chars": text.count])
            lastSpokenText = ""
            return
        }
        turnCounter += 1
        // 31/10 (voix/mémoire/Live) : la fin de parole n'est retenue que si elle suit le tour précédent (et le début
        // de la séance) ; sinon « inconnue » (-1 au journal) plutôt qu'un délai fictif de 16 à 46 s.
        let nowFinal: Date = Date()
        var floorAt: Date = Date.distantPast
        if let a = lastTurnFinalAt, a > floorAt { floorAt = a }
        if let b = sessionStartedAt, b > floorAt { floorAt = b }
        var endAt: Date? = nil
        var endSrc: String = "inconnue"
        if let e = lastSpeechEndAt, e > floorAt { endAt = e; endSrc = "vad_fin" }
        else if let v = vad.lastVoiceAt, v > floorAt { endAt = v; endSrc = "vad_voix" }
        lastTurnFinalAt = nowFinal
        let turn = VLTurn(id: turnCounter, userText: text, userFinalAt: nowFinal,
                          speechEndAt: endAt, sttEngine: moteur)
        turn.speechEndSource = endSrc
        turn.forcedEnd = wasForced
        currentTurn = turn
        history.append(ChatMsg("user", text))
        trimHistory()
        recordVoice(role: "user", text: text)   // BRAIN-B : magasin normal des conversations
        publishFn?("voix_live", ["etat": "reflexion", "final": text, "tour": turn.id])
        setState("reflexion")
        runBrain(turn)
    }

    /// 26/10 : retire du texte entendu les phrases (ou fragments ≥ 3 mots) qui reprennent ce que Nova a dit.
    private func stripEcho(_ heard: String, _ spoken: String) -> String {
        let parts: [String] = heard.components(separatedBy: CharacterSet(charactersIn: ".!?…")).map { (x: String) -> String in x.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { (x: String) -> Bool in !x.isEmpty }
        if parts.count == 0 { return heard }
        var kept: [String] = []
        for p in parts {
            let nW: Int = p.components(separatedBy: CharacterSet.alphanumerics.inverted).filter { (w: String) -> Bool in w.count >= 2 }.count
            if nW >= 4 && echoContainment(p, spoken) >= 0.85 { continue }
            kept.append(p)
        }
        if kept.count == parts.count { return heard }
        return kept.map { (x: String) -> String in x + "." }.joined(separator: " ").trimmingCharacters(in: .whitespaces)
    }

    private func echoContainment(_ final: String, _ spoken: String) -> Double {
        func words(_ s: String) -> [String] {
            s.lowercased().components(separatedBy: CharacterSet.alphanumerics.inverted).filter { $0.count >= 3 }
        }
        let fw = words(final)
        guard !fw.isEmpty else { return 0 }
        let sw = Set(words(spoken))
        return Double(fw.filter { sw.contains($0) }.count) / Double(fw.count)
    }

    private func trimHistory() {
        if history.count > 24 { history.removeFirst(history.count - 24) }
    }

    // MARK: cerveau en flux + découpe en phrases

    private func runBrain(_ turn: VLTurn) {
        guard let router = router, let settings = settings else { return }
        let gen = generation
        let prefSetting: String = settings.get("voix_live_cerveau", "")
        var brainId: String = prefSetting.isEmpty ? settings.get("brain", "spark-1.3") : prefSetting
        // 26/10 : journal des séances — 3 à 8 s entre la fin de la phrase et le 1er fragment du cerveau. En Live, sans
        // choix explicite (« voix_live_cerveau »), le cerveau RAPIDE disponible passe d'abord (« voix_live_rapide », défaut oui).
        // Version Meta : cerveau de la voix = Meta (Spark…) ; aucun relais non Meta.
        if !router.usable(brainId), let m = router.firstUsableMeta(preferring: settings.get("brain", "spark-1.3")) { brainId = m }
        startTTS(turn, gen: gen)
        // VAGUE 2 · pas de silence mort : si le premier fragment tarde (≥ 1,4 s), une courte phrase
        // d'attente neutre est dite ; si un outil est réellement lancé, une phrase qui le nomme.
        if VoixReglages.phrasesAttente() {
            q.asyncAfter(deadline: .now() + 1.4) { [weak self] in
                guard let self = self, self.generation == gen, self.currentTurn === turn, !turn.finished,
                      turn.firstFragmentAt == nil, !turn.fillerSaid else { return }
                self.sayFiller(turn, gen: gen, outil: nil)
            }
        }
        launchBrain(turn, gen: gen, brainId: brainId)
    }

    /// 31/10 (voix/mémoire/Live) : relais quand le cerveau reste MUET (aucun fragment) — cerveaux rapides pas encore essayés.
    private func nextVoiceBrain(excluding tried: [String]) -> String? {
        guard let router = router, let settings = settings else { return nil }
        let cands: [String] = [settings.get("brain", "spark-1.3"), "spark-1.3", "spark-1.2", "wonder-1.0", "spark-open-baseten"]
        for c in cands where !tried.contains(c) && router.usable(c) { return c }
        return nil
    }

    /// Un essai du cerveau pour ce tour (sur q). Une relance incrémente turn.brainAttempt : l'essai précédent est annulé
    /// par son « cancel » et tous ses événements tardifs sont ignorés.
    private func launchBrain(_ turn: VLTurn, gen: Int, brainId: String) {
        guard let router = router, let settings = settings else { return }
        let attempt: Int = turn.brainAttempt
        turn.triedBrains.append(brainId)
        // 31/10 (voix/mémoire/Live) : chien de garde — aucun fragment après « voix_live_cerveau_delai_s » (12 s ; 0 = coupé ;
        // journal : 1er fragment en 1,2 à 7,9 s) → relance sur le cerveau rapide suivant au lieu d'attendre jusqu'à 90 s.
        let wd: Double = settings.get("voix_live_cerveau_delai_s", 12.0)
        if wd > 0 {
            q.asyncAfter(deadline: .now() + wd) { [weak self] in
                guard let self = self, self.generation == gen, self.currentTurn === turn, !turn.finished, !turn.brainDone,
                      turn.firstFragmentAt == nil, turn.brainAttempt == attempt else { return }
                guard let next = self.nextVoiceBrain(excluding: turn.triedBrains) else {
                    self.journal.add(["type": "tour", "evenement": "cerveau_lent", "tour": turn.id, "cerveau": brainId, "apres_ms": Int(wd * 1000)])
                    return
                }
                turn.brainAttempt += 1
                self.journal.add(["type": "tour", "evenement": "cerveau_relance", "tour": turn.id, "lent": brainId, "relais": next, "apres_ms": Int(wd * 1000)])
                self.launchBrain(turn, gen: gen, brainId: next)
            }
        }
        let msgs = history
        let userText: String = turn.userText
        // Relance : file à part — l'essai muet peut encore occuper brainQ (file sérielle) jusqu'à son annulation effective.
        let runQ: DispatchQueue = attempt == 0 ? brainQ : DispatchQueue.global(qos: .userInitiated)
        runQ.async { [weak self] in
            guard let self = self else { return }
            var sentenceBuf = ""
            let ctxT0: Date = Date()
            let sysTurn: String = self.turnSystem(userText)   // BRAIN-B : identité + profil + mémoire pertinente (sur brainQ, hors file d'état)
            let ctxMs: Int = Int(Date().timeIntervalSince(ctxT0) * 1000)
            let callAt: Date = Date()
            self.q.async { if turn.brainAttempt == attempt { turn.ctxMs = ctxMs; turn.brainCallAt = callAt } }   // 31/10 : instrumentation
            let used = router.chat(messages: msgs, system: sysTurn, mode: "voice",   // 29/10 : « voice » = chaîne rapide + Spark sans réflexion (Brains.swift)
                                   preferred: brainId, maxTokens: 420,
                                   cancel: { [weak self] in (self?.generation ?? -1) != gen || turn.brainAttempt != attempt },
                                   deadline: 90, solo: true) { ev in
                switch ev {
                case .delta(let d):
                    self.q.async { [weak self] in
                        guard let self = self, self.generation == gen, self.currentTurn === turn, !turn.finished, turn.brainAttempt == attempt else { return }
                        if turn.firstFragmentAt == nil { turn.firstFragmentAt = Date() }
                        turn.responseText += d
                        sentenceBuf += d
                        let (ready, rest) = VLSentences.extract(sentenceBuf)
                        sentenceBuf = rest
                        for s in ready { self.dispatchSentence(s, turn: turn, gen: gen) }
                    }
                case .draftReset:
                    self.q.async { [weak self] in
                        guard let self = self, self.generation == gen, self.currentTurn === turn, !turn.finished, turn.brainAttempt == attempt else { return }
                        // VÉRITÉ-3 en voix : la régénération REMPLACE — tampon jeté, lecture
                        // coupée, TTS rouvert ; ce qui a déjà été ENTENDU reste dans spokenText.
                        sentenceBuf = ""
                        turn.responseText = ""
                        self.journal.add(["type": "tour", "evenement": "reprise_cerveau", "tour": turn.id])
                        #if canImport(AVFoundation) && os(macOS)
                        self.player?.stopNow()
                        #endif
                        self.startTTS(turn, gen: gen)
                    }
                case .error(let e):
                    self.q.async { [weak self] in
                        guard let self = self, self.currentTurn === turn, turn.brainAttempt == attempt else { return }
                        turn.brainError = e
                    }
                case .tool(let name, _, _):
                    self.q.async { [weak self] in
                        guard let self = self, self.generation == gen, self.currentTurn === turn, !turn.finished, turn.brainAttempt == attempt,
                              !turn.fillerSaid, VoixReglages.phrasesAttente() else { return }
                        self.sayFiller(turn, gen: gen, outil: name)
                    }
                default:
                    break
                }
            }
            self.q.async { [weak self] in
                guard let self = self, self.generation == gen, self.currentTurn === turn, !turn.finished, turn.brainAttempt == attempt else { return }
                turn.brainDone = true
                turn.brainUsed = used
                if !sentenceBuf.isEmpty { self.dispatchSentence(sentenceBuf, turn: turn, gen: gen); sentenceBuf = "" }
                self.maybeFinishTurn(turn)
            }
        }
    }

    /// V6-COMPAGNON (25/10) : résumé du résultat d'une mission (agent écrit, avec outils) dit par la voix
    /// live comme un tour de Nova — seulement si la session tourne et que personne ne parle (aucun tour en
    /// cours) ; sinon rien n'est dit et le résultat reste dans le fil écrit. completion(true) = annoncé.
    public func announce(_ text: String, completion: @escaping (Bool) -> Void) {
        q.async { [weak self] in
            guard let self = self else { completion(false); return }
            let said: String = VLSentences.clean(String(text.prefix(600)))
            guard self.running, self.currentTurn == nil, !said.isEmpty else { completion(false); return }
            self.turnCounter += 1
            let turn = VLTurn(id: self.turnCounter, userText: "", userFinalAt: Date(), speechEndAt: nil, sttEngine: "mission")
            self.currentTurn = turn
            let gen: Int = self.generation
            self.setState("reflexion")
            self.startTTS(turn, gen: gen)
            turn.firstFragmentAt = Date()
            turn.responseText = said
            self.dispatchSentence(said, turn: turn, gen: gen)
            turn.brainDone = true
            self.maybeFinishTurn(turn)
            completion(true)
        }
    }

    // MARK: TTS — voix système macOS phrase par phrase

    private func startTTS(_ turn: VLTurn, gen: Int) {
        ttsLocal = true
    }

    /// VAGUE 2 : phrase d'attente (jamais la même deux fois de suite), dite tout de suite par la même voix.
    private func sayFiller(_ turn: VLTurn, gen: Int, outil: String?) {
        turn.fillerSaid = true
        let p: String = VoixAttente.phrase(outil: outil)
        journal.add(["type": "tour", "evenement": "phrase_attente", "tour": turn.id, "outil": outil ?? ""])
        dispatchSentence(p, turn: turn, gen: gen)
    }

    private func dispatchSentence(_ s: String, turn: VLTurn, gen: Int) {
        let clean: String = VLSentences.clean(s)   // V6-COMPAGNON : la balise <mission> (et tout markdown) n'est jamais dite, même dans le reliquat final
        guard !clean.isEmpty else { return }
        turn.spokenText += (turn.spokenText.isEmpty ? "" : " ") + clean
        turn.httpUsed = true
        turn.httpPending += 1
        ttsQ.async { [weak self] in
            guard let self = self else { return }
            self.localSentence(clean, gen: gen, turn: turn)
            self.q.async { [weak self] in
                guard let self = self else { return }
                turn.httpPending -= 1
                self.maybeFinishTurn(turn)
            }
        }
    }

    /// 25/10 : phrase dite par la voix LOCALE (AVSpeechSynthesizer → PCM16 24 kHz) sur le même lecteur natif.
    /// Bloquant : appelé sur ttsQ.
    private func localSentence(_ s: String, gen: Int, turn: VLTurn) {
        let vid: String = settings?.get("voix_locale_id", "") ?? ""
        let r = LocalVoice.shared.render(text: s, voiceId: vid, cancel: { [weak self] () -> Bool in (self?.generation ?? -1) != gen }) { [weak self] (d: Data) -> Bool in
            guard let self = self else { return false }
            if self.generation != gen { return false }
            #if canImport(AVFoundation) && os(macOS)
            self.player?.schedule(pcm16: d)
            #endif
            self.q.async { self.markFirstAudio(turn) }
            return true
        }
        if !r.ok {
            let why: String = r.error ?? "voix locale sans son"
            q.async { [weak self] in
                self?.journal.add(["type": "tour", "evenement": "tts_local_echec", "tour": turn.id, "raison": shortError(why, 120)])
            }
        }
    }

    private func markFirstAudio(_ turn: VLTurn) {
        guard currentTurn === turn, turn.firstAudioAt == nil else { return }
        turn.firstAudioAt = Date()
        if stateName == "reflexion" { setState("parole") }
    }

    // MARK: fin de tour + journal des latences

    private func ttsSettled(_ turn: VLTurn) -> Bool {
        if turn.wsFinal { return true }
        if turn.httpPending > 0 { return false }
        if turn.wsFailed { return true }
        return turn.httpUsed               // phrases rendues une par une par la voix système
    }

    private func maybeFinishTurn(_ turn: VLTurn) {
        guard currentTurn === turn, !turn.finished, turn.brainDone else { return }
        guard turn.responseText.isEmpty || ttsSettled(turn) else { return }
        #if canImport(AVFoundation) && os(macOS)
        if player?.isPlaying == true { return }   // onDrained rappellera
        #endif
        finishTurn(turn)
    }

    private func finishTurn(_ turn: VLTurn) {
        turn.finished = true
        lastSpokenText = turn.spokenText
        if !turn.spokenText.isEmpty { lastDrainAt = Date() }
        // V6-COMPAGNON (25/10) : <mission> = le cerveau du Live demande l'agent avec outils. La balise est
        // retirée du fil ; la page qui tient la session lance la demande par /api/chat (tools) et fait dire
        // le résumé par /api/voix-live/annoncer. Un tour interrompu ne lance rien.
        let missionAsked: Bool = turn.responseText.contains("<mission>")
        let said: String = turn.responseText.replacingOccurrences(of: "<mission>", with: "").trimmingCharacters(in: .whitespacesAndNewlines)
        if !said.isEmpty {
            history.append(ChatMsg("assistant", said))
            trimHistory()
            recordVoice(role: "assistant", text: said)   // BRAIN-B
            if let r = router, let m = memory, !turn.userText.isEmpty {
                MemoryDistiller.schedule(router: r, memory: m, user: turn.userText, assistant: said, title: "Voix live")   // arrière-plan, jamais bloquant
            }
        }
        if missionAsked && !turn.interrupted && !turn.userText.isEmpty {
            publishFn?("voix_live", ["evenement": "mission", "tour": turn.id, "texte": String(turn.userText.prefix(4000))])
        }
        journal.add(tourEntry(turn))
        if turn.brainError != nil && turn.responseText.isEmpty {
            publishFn?("voix_live", ["etat": "erreur", "label": "Nova · cerveau en échec"])
        }
        currentTurn = nil
        #if canImport(Speech) && canImport(AVFoundation) && os(macOS)
        if sttMode == .local { localSpeech.discard() }   // VAGUE 2 : la tâche locale a entendu Nova — on repart à blanc
        #endif
        if running { setState("ecoute") }
    }

    private func tourEntry(_ turn: VLTurn) -> [String: Any] {
        func ms(_ a: Date?, _ b: Date?) -> Int {
            guard let a = a, let b = b else { return -1 }
            return Int(b.timeIntervalSince(a) * 1000)
        }
        return ["type": "tour", "n": turn.id, "stt_moteur": turn.sttEngine,
                "cerveau": turn.brainUsed ?? "",
                "fin_parole_a_final_ms": ms(turn.speechEndAt, turn.userFinalAt),
                "final_a_fragment_ms": ms(turn.userFinalAt, turn.firstFragmentAt),
                "fragment_a_audio_ms": ms(turn.firstFragmentAt, turn.firstAudioAt),
                "fin_parole_a_audio_ms": ms(turn.speechEndAt, turn.firstAudioAt),
                "interruption": turn.interrupted,
                // 31/10 (voix/mémoire/Live) : répartition fine — contexte (profil + mémoire), réseau + cerveau jusqu'au 1er fragment,
                // origine de la fin de parole, relances, fin forcée, voie TTS.
                "fin_parole_source": turn.speechEndSource,
                "contexte_ms": turn.ctxMs,
                "appel_a_fragment_ms": ms(turn.brainCallAt, turn.firstFragmentAt),
                "cerveau_essais": turn.triedBrains.count,
                "fin_forcee": turn.forcedEnd,
                "phrase_attente": turn.fillerSaid,
                "tts_voie": ttsLocal ? "locale" : (turn.httpUsed ? "http" : "ws"),
                "user_chars": turn.userText.count,
                "reponse_chars": turn.responseText.count,
                "entendu_chars": turn.spokenText.count]
    }

    // MARK: barge-in bilatéral

    /// Interruption (VAD ≥ 280 ms de parole soutenue, final STT pendant la parole, ou bouton).
    /// Le son cesse immédiatement, le flux TTS et le cerveau sont annulés par génération,
    /// le texte RÉELLEMENT entendu entre dans l'historique — et le flux STT, jamais coupé,
    /// fait de l'interruption le tour suivant.
    private func bargeIn(manuelle: Bool) {
        let st = stateName
        guard running, st == "parole" || st == "reflexion", let turn = currentTurn, !turn.finished else { return }
        let t0 = Date()
        generation += 1
        turn.interrupted = true
        #if canImport(AVFoundation) && os(macOS)
        player?.stopNow()
        #endif
        // V4-B : le compagnon réagit à l'interruption à l'instant même (yeux écarquillés, silence)
        let tourId: Int = turn.id
        publishFn?("voix_live", ["evenement": "barge_in", "manuelle": manuelle, "tour": tourId])
        let silenceMs = Int(Date().timeIntervalSince(t0) * 1000)
        if !turn.spokenText.isEmpty {
            history.append(ChatMsg("assistant", turn.spokenText))
            trimHistory()
            recordVoice(role: "assistant", text: turn.spokenText + " [interrompue par Ahadi]")   // BRAIN-B : ce qui a été réellement entendu
        }
        journal.add(["type": "interruption", "tour": turn.id, "manuelle": manuelle,
                     "silence_ms": silenceMs, "entendu_chars": turn.spokenText.count])
        journal.add(tourEntry(turn))
        turn.finished = true
        currentTurn = nil
        lastSpokenText = ""   // jamais de filtre d'écho après une vraie interruption
        #if canImport(Speech) && canImport(AVFoundation) && os(macOS)
        if sttMode == .local { localSpeech.discard() }   // VAGUE 2 : sans cela, la voix de Nova se mêlait à la phrase d'Ahadi
        #endif
        setState("ecoute")
    }

    /// Coupe-parole manuel (bouton / route) : même mécanique que le barge-in VAD.
    public func interrupt() {
        q.async { [weak self] in self?.bargeIn(manuelle: true) }
    }
}

// MARK: - Routes (patron Feat_Wake : extension NovaApp, moteur singleton)

extension NovaApp {
    /// VL · conversation vocale live — routes seulement ; le moteur vit derrière
    /// l'interrupteur « voix_live_enabled » (défaut fermé) et refuse nommément sinon.
    func voiceLiveRoutes() {
        let engine = VoiceLiveEngine.shared
        let busRef = bus
        engine.configure(keys: keys, settings: settings, router: router, memory: memory, convs: convs) { ev, payload in
            busRef.publish(ev, payload)
        }
        let s = server
        s.on("POST", "/api/voix-live/start") { _, res in
            let sem = DispatchSemaphore(value: 0)
            var ok = false
            var err: String? = nil
            engine.start { o, e in ok = o; err = e; sem.signal() }
            _ = sem.wait(timeout: .now() + 25)
            res.json(["ok": ok, "etat": engine.stateName, "erreur": err ?? ""], status: ok ? 200 : 403)
        }
        s.on("POST", "/api/voix-live/stop") { _, res in
            engine.stop()
            res.json(["ok": true, "etat": "off"])
        }
        s.on("POST", "/api/voix-live/interrompre") { _, res in
            engine.interrupt()
            res.json(["ok": true])
        }
        // V6-COMPAGNON : résumé d'une mission lancée depuis le Live, dit par la voix live (voir announce).
        s.on("POST", "/api/voix-live/annoncer") { req, res in
            let t: String = (req.json["text"] as? String) ?? ""
            let sem: DispatchSemaphore = DispatchSemaphore(value: 0)
            var said: Bool = false
            engine.announce(t) { (ok: Bool) in said = ok; sem.signal() }
            _ = sem.wait(timeout: .now() + 5)
            res.json(["ok": said])
        }
        s.on("GET", "/api/voix-live/status") { _, res in
            res.json(engine.snapshot())
        }
    }
}


#if canImport(AVFoundation) && os(macOS)
/// 29/10 : repérage du micro intégré du Mac (transport « built-in », au moins un canal d'entrée).
enum VLAudioDevices {
    static func builtInMic() -> AudioDeviceID? {
        var addr: AudioObjectPropertyAddress = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDevices, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size) == noErr, size > 0 else { return nil }
        let n: Int = Int(size) / MemoryLayout<AudioDeviceID>.size
        var ids: [AudioDeviceID] = [AudioDeviceID](repeating: 0, count: n)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size, &ids) == noErr else { return nil }
        for id in ids {
            var tAddr: AudioObjectPropertyAddress = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyTransportType, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
            var transport: UInt32 = 0
            var tSize: UInt32 = UInt32(MemoryLayout<UInt32>.size)
            guard AudioObjectGetPropertyData(id, &tAddr, 0, nil, &tSize, &transport) == noErr, transport == kAudioDeviceTransportTypeBuiltIn else { continue }
            var sAddr: AudioObjectPropertyAddress = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyStreams, mScope: kAudioDevicePropertyScopeInput, mElement: kAudioObjectPropertyElementMain)
            var sSize: UInt32 = 0
            if AudioObjectGetPropertyDataSize(id, &sAddr, 0, nil, &sSize) == noErr, sSize > 0 { return id }
        }
        return nil
    }
}
#endif
