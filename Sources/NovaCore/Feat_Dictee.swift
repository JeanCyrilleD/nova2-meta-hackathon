import Foundation
#if os(macOS)
import AppKit
import ApplicationServices
import CoreGraphics
#endif
#if canImport(Speech) && canImport(AVFoundation) && os(macOS)
import Speech
import AVFoundation
#endif

// DICTÉE PARTOUT — raccourci global ⌃⌥D (enregistré dans NovaMac/main.swift › registerHotkey, id 2).
// 1er appui : reconnaissance vocale fr-FR (même pipeline que Feat_Wake : SFSpeechRecognizer + AVAudioEngine, sur l'appareil si possible)
// et le texte reconnu est TAPÉ dans l'app au premier plan (CGEvent unicode ; secours : presse-papiers + ⌘V). 2e appui : stop.
// Droits requis : Accessibilité (envoi de frappes) + Reconnaissance vocale + Micro. Aucune invite au démarrage de Nova :
// vérification au premier appui seulement ; en cas de refus, notification Nova (jamais d'alerte bloquante).
// Le texte dicté n'est ni journalisé ni stocké.

#if os(macOS)
/// Indicateur minuscule « Dictée… » : jamais clé, jamais principal, transparent à la souris, n'active pas Nova.
final class DicteePanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}
#endif

public final class Dictee {
    public static let shared: Dictee = Dictee()
    public private(set) var running: Bool = false
    public private(set) var lastError: String = ""
    var axAsked: Bool = false
    var wakeWasRunning: Bool = false
    #if canImport(Speech) && canImport(AVFoundation) && os(macOS)
    var engine: AVAudioEngine? = nil
    var request: SFSpeechAudioBufferRecognitionRequest? = nil
    var task: SFSpeechRecognitionTask? = nil
    var generation: Int = 0
    var failStreak: Int = 0
    var committed: String = ""   // segments finalisés (une tâche de reconnaissance dure ~1 min, on enchaîne)
    var current: String = ""     // transcription du segment en cours
    var typed: String = ""       // ce qui a réellement été tapé (manipulé uniquement sur typeQueue)
    var indicator: DicteePanel? = nil
    let typeQueue: DispatchQueue = DispatchQueue(label: "nova.dictee.frappe", qos: .userInitiated)
    #endif

    /// Appelé sur le fil principal par le raccourci ⌃⌥D.
    public func toggle() {
        #if canImport(Speech) && canImport(AVFoundation) && os(macOS)
        if running { stop(); return }
        if (VoixDictee.shared.snapshot()["en_cours"] as? Bool) == true {
            Dictee.notify("Dictée : une dictée est déjà en cours dans Nova (micro du champ) — termine-la d'abord.")
            return
        }
        // 1) Accessibilité (frappes envoyées à l'app au premier plan). L'invite système n'est proposée qu'une fois, au premier appui.
        if !AXIsProcessTrusted() {
            if !axAsked {
                axAsked = true
                let opts: NSDictionary = ["AXTrustedCheckOptionPrompt": true]
                _ = AXIsProcessTrustedWithOptions(opts as CFDictionary)
            }
            Dictee.notify("Dictée : autorise Nova dans Réglages Système › Confidentialité et sécurité › Accessibilité, puis réappuie sur ⌃⌥D.")
            return
        }
        // 2) Micro
        let mic: AVAuthorizationStatus = AVCaptureDevice.authorizationStatus(for: .audio)
        if mic == .denied || mic == .restricted {
            Dictee.notify("Dictée : autorise Nova dans Réglages Système › Confidentialité et sécurité › Micro.")
            return
        }
        // 3) Reconnaissance vocale
        let speechMsg: String = "Dictée : autorise Nova dans Réglages Système › Confidentialité et sécurité › Reconnaissance vocale."
        let st: SFSpeechRecognizerAuthorizationStatus = SFSpeechRecognizer.authorizationStatus()
        if st == .authorized {
            startNow()
        } else if st == .notDetermined {
            SFSpeechRecognizer.requestAuthorization { (s: SFSpeechRecognizerAuthorizationStatus) in
                DispatchQueue.main.async {
                    if s == .authorized { self.startNow() } else { Dictee.notify(speechMsg) }
                }
            }
        } else {
            Dictee.notify(speechMsg)
        }
        #else
        Dictee.notify("Dictée indisponible sur ce système.")
        #endif
    }

    /// Arrêt (2e appui) : tape ce qui reste du segment en cours, coupe le micro, masque l'indicateur.
    public func stop() {
        #if canImport(Speech) && canImport(AVFoundation) && os(macOS)
        guard running else { return }
        commitCurrent()
        pushTyping(full: true)
        running = false
        generation += 1
        teardown()
        indicator?.orderOut(nil)
        restoreWake()
        #endif
    }

    static func notify(_ msg: String) {
        let clean: String = msg.replacingOccurrences(of: "\\", with: " ").replacingOccurrences(of: "\"", with: "'")
        let script: String = "display notification \"" + clean + "\" with title \"Nova — Dictée\""
        DispatchQueue.global(qos: .utility).async {
            _ = Tools.osa(script, timeout: 5)
        }
    }

    #if canImport(Speech) && canImport(AVFoundation) && os(macOS)
    func startNow() {
        guard !running else { return }
        // Le mot de réveil partage le micro : on le met en pause pendant la dictée, puis on le relance.
        let wake: WakeListener = WakeListener.shared
        wakeWasRunning = wake.running
        if wakeWasRunning { wake.stop() }
        committed = ""
        current = ""
        failStreak = 0
        typeQueue.async { self.typed = "" }
        running = true
        if !begin() {
            running = false
            restoreWake()
            Dictee.notify("Dictée impossible : " + lastError)
            return
        }
        showIndicator()
    }

    func restoreWake() {
        if wakeWasRunning {
            wakeWasRunning = false
            _ = WakeListener.shared.begin()
        }
    }

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
        // VAGUE 2 (voix fiable) : langue des réglages voix (auto → fr-FR ici), vocabulaire personnel
        // (contacts, sigles, villes, Éclats) et choix « sur l'appareil » du réglage.
        let loc: String = VoixReglages.localePrincipale()
        guard let rec: SFSpeechRecognizer = SFSpeechRecognizer(locale: Locale(identifier: loc)), rec.isAvailable else {
            lastError = "reconnaissance " + loc + " indisponible"; return false
        }
        let req: SFSpeechAudioBufferRecognitionRequest = SFSpeechAudioBufferRecognitionRequest()
        req.shouldReportPartialResults = true
        req.taskHint = .dictation
        req.addsPunctuation = true
        req.contextualStrings = VoixVocab.effectif()
        if rec.supportsOnDeviceRecognition && VoixReglages.surAppareil() { req.requiresOnDeviceRecognition = true }
        request = req
        let e: AVAudioEngine = AVAudioEngine()
        let input: AVAudioInputNode = e.inputNode
        let fmt: AVAudioFormat = input.outputFormat(forBus: 0)
        input.installTap(onBus: 0, bufferSize: 2048, format: fmt) { (buf: AVAudioPCMBuffer, _: AVAudioTime) in
            req.append(buf)
        }
        e.prepare()
        do { try e.start() } catch {
            lastError = "micro : " + error.localizedDescription
            input.removeTap(onBus: 0)
            request = nil
            return false
        }
        engine = e
        generation += 1
        let gen: Int = generation
        task = rec.recognitionTask(with: req) { [weak self] (result: SFSpeechRecognitionResult?, err: Error?) in
            guard let self = self else { return }
            var text: String = ""
            var isFinal: Bool = false
            let hasResult: Bool = (result != nil)
            if let r: SFSpeechRecognitionResult = result {
                text = r.bestTranscription.formattedString
                isFinal = r.isFinal
            }
            let failed: Bool = (err != nil)
            DispatchQueue.main.async {
                self.handle(gen: gen, text: text, isFinal: isFinal, failed: failed, hasResult: hasResult)
            }
        }
        lastError = ""
        return true
    }

    /// Fil principal.
    func handle(gen: Int, text: String, isFinal: Bool, failed: Bool, hasResult: Bool) {
        guard gen == generation, running else { return }
        if hasResult { current = text; failStreak = 0 }
        if isFinal || failed {
            // Segment clos : on tape tout, puis nouvelle tâche (limite ~1 min par tâche), sans boucle serrée.
            commitCurrent()
            pushTyping(full: true)
            generation += 1   // le rappel d'annulation de cette tâche sera ignoré (pas de double redémarrage)
            teardown()
            if failed && !hasResult { failStreak += 1 }
            if failStreak >= 6 {
                stop()
                Dictee.notify("Dictée arrêtée : la reconnaissance vocale ne répond pas.")
                return
            }
            let delay: Double = (failed && !hasResult) ? 1.0 : 0.15
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
                guard self.running else { return }
                if !self.begin() {
                    let why: String = self.lastError
                    self.stop()
                    Dictee.notify("Dictée arrêtée : " + why)
                }
            }
            return
        }
        pushTyping(full: false)
    }

    func commitCurrent() {
        // VAGUE 2 : segment clos → correction du vocabulaire (noms, sigles, montants) ; la frappe
        // s'aligne ensuite par effacement minimal (sync), comme pour une révision de la reconnaissance.
        let c: String = VoixPost.corriger(current.trimmingCharacters(in: .whitespacesAndNewlines), majusculeInitiale: committed.isEmpty)
        current = ""
        if c.isEmpty { return }
        if committed.isEmpty { committed = c } else { committed = committed + " " + c }
    }

    /// Texte visé. En cours de phrase, on retient les 2 derniers mots (encore souvent corrigés par la reconnaissance).
    func target(full: Bool) -> String {
        var cur: String = current.trimmingCharacters(in: .whitespacesAndNewlines)
        if !full {
            var words: [Substring] = cur.split(separator: " ")
            if words.count <= 2 {
                cur = ""
            } else {
                words.removeLast(2)
                cur = words.joined(separator: " ")
            }
        }
        if committed.isEmpty { return cur }
        if cur.isEmpty { return committed }
        return committed + " " + cur
    }

    func pushTyping(full: Bool) {
        let t: String = target(full: full)
        typeQueue.async { self.sync(to: t) }
    }

    /// typeQueue : aligne ce qui est tapé sur le texte visé (effacement minimal des caractères révisés, puis ajout).
    func sync(to target: String) {
        let a: [Character] = Array(typed)
        let b: [Character] = Array(target)
        var i: Int = 0
        while i < a.count && i < b.count && a[i] == b[i] { i += 1 }
        var toDelete: Int = a.count - i
        if toDelete > 0 && b.count <= a.count && typed.hasPrefix(target) { return }   // simple recul : on garde ce qui est tapé
        var start: Int = i
        if toDelete > 80 {
            // Révision trop large (l'utilisateur a peut-être cliqué ailleurs) : on n'efface rien, on ajoute seulement la suite.
            toDelete = 0
            start = min(a.count, b.count)
        }
        if toDelete > 0 { Dictee.backspaces(toDelete) }
        let add: String = String(b[start...])
        if !add.isEmpty {
            if add.count > 300 || !Dictee.typeText(add) { Dictee.paste(add) }
        }
        typed = target
    }

    func showIndicator() {
        let w: CGFloat = 120
        let hgt: CGFloat = 24
        let scr: NSRect = NSScreen.main?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        let r: NSRect = NSRect(x: scr.maxX - w - 12, y: scr.maxY - hgt - 8, width: w, height: hgt)
        if indicator == nil {
            let p: DicteePanel = DicteePanel(contentRect: r, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
            p.isOpaque = false
            p.backgroundColor = .clear
            p.hasShadow = true
            p.level = .statusBar
            p.ignoresMouseEvents = true
            p.hidesOnDeactivate = false
            p.isReleasedWhenClosed = false
            p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
            let box: NSView = NSView(frame: NSRect(x: 0, y: 0, width: w, height: hgt))
            box.wantsLayer = true
            box.layer?.backgroundColor = NSColor.black.withAlphaComponent(0.72).cgColor
            box.layer?.cornerRadius = 8
            let lab: NSTextField = NSTextField(labelWithString: "Dictée…")
            lab.textColor = .white
            lab.font = NSFont.systemFont(ofSize: 12, weight: .medium)
            lab.alignment = .center
            lab.frame = NSRect(x: 6, y: 4, width: w - 12, height: 16)
            box.addSubview(lab)
            p.contentView = box
            indicator = p
        }
        indicator?.setFrame(r, display: true)
        indicator?.orderFrontRegardless()
    }

    // MARK: frappes (CGEvent)
    static func typeText(_ s: String) -> Bool {
        guard let src: CGEventSource = CGEventSource(stateID: .hidSystemState) else { return false }
        guard CGEvent(keyboardEventSource: src, virtualKey: 0, keyDown: true) != nil else { return false }
        for ch in s {
            var units: [UniChar] = Array(String(ch).utf16)
            guard let down: CGEvent = CGEvent(keyboardEventSource: src, virtualKey: 0, keyDown: true),
                  let up: CGEvent = CGEvent(keyboardEventSource: src, virtualKey: 0, keyDown: false) else { continue }
            down.flags = []
            up.flags = []
            down.keyboardSetUnicodeString(stringLength: units.count, unicodeString: &units)
            up.keyboardSetUnicodeString(stringLength: units.count, unicodeString: &units)
            down.post(tap: .cghidEventTap)
            up.post(tap: .cghidEventTap)
            usleep(3000)
        }
        return true
    }

    static func backspaces(_ n: Int) {
        guard n > 0, let src: CGEventSource = CGEventSource(stateID: .hidSystemState) else { return }
        for _ in 0..<n {
            guard let down: CGEvent = CGEvent(keyboardEventSource: src, virtualKey: 51, keyDown: true),
                  let up: CGEvent = CGEvent(keyboardEventSource: src, virtualKey: 51, keyDown: false) else { return }
            down.flags = []
            up.flags = []
            down.post(tap: .cghidEventTap)
            up.post(tap: .cghidEventTap)
            usleep(3000)
        }
    }

    /// Secours : presse-papiers + ⌘V, puis restauration du texte précédent du presse-papiers.
    static func paste(_ s: String) {
        let pb: NSPasteboard = NSPasteboard.general
        let old: String? = pb.string(forType: .string)
        pb.clearContents()
        pb.setString(s, forType: .string)
        guard let src: CGEventSource = CGEventSource(stateID: .hidSystemState),
              let down: CGEvent = CGEvent(keyboardEventSource: src, virtualKey: 9, keyDown: true),
              let up: CGEvent = CGEvent(keyboardEventSource: src, virtualKey: 9, keyDown: false) else { return }
        down.flags = .maskCommand
        up.flags = .maskCommand
        down.post(tap: .cghidEventTap)
        up.post(tap: .cghidEventTap)
        usleep(400_000)
        if let o: String = old {
            pb.clearContents()
            pb.setString(o, forType: .string)
        }
    }
    #endif
}
