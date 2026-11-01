import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
#if canImport(AVFoundation)
import AVFoundation
#endif

// 25/10 : PODCAST HEBDO RÉEL — « Ma semaine en 5 minutes », produit de bout en bout par Nova.
// 1) matière RÉELLE des 7 derniers jours rassemblée en code (conversations, briefs, engagements,
//    résultats d'Éclats, ligne BRVM) — aucune boucle d'agent ;
// 2) UN appel de cerveau (routeur, cerveau des Réglages) écrit un dialogue LÉA / MEHDI au format strict ;
// 3) chaque réplique est synthétisée par la voix système macOS (deux voix distinctes, PCM 24 kHz) ;
// 4) assemblage en UN fichier audio (.m4a via AVFoundation, repli .wav) avec silences et carillon
//    généré en code, déposé dans les Livrables (~/cafu) avec son script .md à côté.
// Rien n'est envoyé ni publié : fichier local uniquement.
enum PodcastKit {
    /// 25/10 : crochet posé par NovaApp.podcastRoutes() — l'Éclat « Podcast hebdo » l'appelle (Dots.run).
    nonisolated(unsafe) static var dotHook: ((_ origin: String, _ progress: @escaping (String) -> Void) -> [String: Any])? = nil   // PHASE 1 (relu, protégé) : crochet posé une fois au démarrage (podcastRoutes, enregistrement des routes) avant tout Dot, lecture seule ensuite
    static let lock: NSLock = NSLock()
    nonisolated(unsafe) static var runningJob: String = ""
    nonisolated(unsafe) static var jobs: [String: [String: Any]] = [:]
    static let journal: Journal = Journal("podcast_journal.jsonl")
    static let defaultVoiceA: String = ""   // voix système choisie automatiquement (française installée)
    static let defaultVoiceB: String = ""
    static let sampleRate: Double = 24000
    static let dotIds: Set<String> = ["imp-rituel-podcast", "imp-ame-podcast"]

    struct Turn {
        let speaker: String   // "LEA" ou "MEHDI"
        var text: String
    }

    // MARK: état des travaux

    static func setJob(_ id: String, _ patch: [String: Any]) {
        lock.lock()
        var cur: [String: Any] = jobs[id] ?? ["id": id]
        for (k, v) in patch { cur[k] = v }
        jobs[id] = cur
        if jobs.count > 20 {
            let oldest: [String] = jobs.keys.sorted()
            if let first = oldest.first, first != id { jobs.removeValue(forKey: first) }
        }
        lock.unlock()
    }
    static func job(_ id: String) -> [String: Any]? {
        lock.lock()
        let j: [String: Any]? = jobs[id]
        lock.unlock()
        return j
    }
    /// Réserve le créneau unique de production ; false si un épisode est déjà en cours.
    static func claim(_ id: String) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        if !runningJob.isEmpty { return false }
        runningJob = id
        return true
    }
    static func release(_ id: String) {
        lock.lock()
        if runningJob == id { runningJob = "" }
        lock.unlock()
    }
    static func current() -> String {
        lock.lock()
        let r: String = runningJob
        lock.unlock()
        return r
    }

    // MARK: script

    static let metaWords: [String] = ["podcast", "voix live", "tu m'entends", "tu m entends", "relance l'eclat", "autotest", "france 24", "africanews",
                                      "teste ", "test ", "dictee", "compagnon", "avatar", "nova", "eclat", "parle-moi", "reglages", "voix de"]
    static func isTechnical(_ s: String) -> Bool {
        let f: String = fold(s).lowercased()
        let pats: [String] = ["pid ", "pid:", "swift", "spark-local", "nova2", "package_app", "packageapp", ".sh", "compilation", "build", "~/", "/users/", "dsym", "processus"]
        return pats.contains(where: { (w: String) -> Bool in f.contains(w) })
    }
    static func isAboutNova(_ s: String) -> Bool {
        let f: String = fold(s).lowercased()
        return metaWords.contains(where: { (w: String) -> Bool in f.contains(w) })
    }
    static func fold(_ s: String) -> String {
        let up: String = s.uppercased()
        return up.folding(options: [.diacriticInsensitive], locale: Locale(identifier: "fr_FR"))
    }
    /// Une réplique par ligne « LÉA: … » / « MEHDI: … » ; le reste (titres, didascalies) est ignoré.
    static func parseTurns(_ raw: String) -> [Turn] {
        var out: [Turn] = []
        let lines: [String] = raw.components(separatedBy: .newlines)
        for l0 in lines {
            var l: String = l0.trimmingCharacters(in: .whitespaces)
            l = l.replacingOccurrences(of: "*", with: "")
            l = l.replacingOccurrences(of: "_", with: "")
            l = l.trimmingCharacters(in: CharacterSet(charactersIn: "-•> \t"))
            guard let colon = l.firstIndex(where: { $0 == ":" || $0 == "：" }) else { continue }
            let whoRaw: String = fold(String(l[..<colon]).trimmingCharacters(in: .whitespaces))
            let who: String = whoRaw.components(separatedBy: CharacterSet(charactersIn: " ([")).first ?? ""   // « LÉA (souriante) » → LEA
            var speaker: String = ""
            if who == "LEA" { speaker = "LEA" }
            if who == "MEHDI" { speaker = "MEHDI" }
            if speaker.isEmpty { continue }
            var text: String = String(l[l.index(after: colon)...]).trimmingCharacters(in: .whitespaces)
            text = text.replacingOccurrences(of: #"\[[^\]]*\]|\([^)]*(rire|musique|pause|jingle)[^)]*\)"#, with: "", options: [.regularExpression, .caseInsensitive])
            text = text.replacingOccurrences(of: "#", with: "").replacingOccurrences(of: "`", with: "")
            text = text.trimmingCharacters(in: .whitespacesAndNewlines)
            if text.isEmpty { continue }
            out.append(Turn(speaker: speaker, text: text))
        }
        return out
    }
    /// Garde-fou de coût : on garde les répliques tant que le total reste sous le plafond.
    static func capTurns(_ turns: [Turn], maxChars: Int) -> (kept: [Turn], chars: Int, dropped: Int) {
        var kept: [Turn] = []
        var total: Int = 0
        for t in turns {
            if total + t.text.count > maxChars { break }
            kept.append(t)
            total += t.text.count
        }
        let dropped: Int = turns.count - kept.count
        return (kept: kept, chars: total, dropped: dropped)
    }
    static func scriptMarkdown(_ turns: [Turn], title: String, meta: String) -> String {
        var s: String = "# " + title + "\n\n_" + meta + "_\n\n"
        for t in turns {
            let who: String = t.speaker == "LEA" ? "Léa" : "Mehdi"
            s += "**" + who + "** : " + t.text + "\n\n"
        }
        return s
    }

    // MARK: audio

    /// PCM 16 bits LE mono 24 kHz → échantillons flottants.
    /// 25/10 : fondu d'entrée/sortie (ms) et retrait du décalage continu — supprime les micro-clics entre répliques.
    static func fadeEdges(_ x: [Float], ms: Int) -> [Float] {
        if x.isEmpty { return x }
        var y: [Float] = x
        var mean: Float = 0
        for v in y { mean += v }
        mean = mean / Float(y.count)
        for i in 0..<y.count { y[i] = y[i] - mean }
        let n: Int = min(y.count / 2, Int(sampleRate) * ms / 1000)
        if n > 1 {
            for i in 0..<n {
                let g: Float = Float(i) / Float(n)
                y[i] = y[i] * g
                y[y.count - 1 - i] = y[y.count - 1 - i] * g
            }
        }
        return y
    }
    static func pcmToFloats(_ d: Data) -> [Float] {
        let bytes: [UInt8] = [UInt8](d)
        var out: [Float] = []
        out.reserveCapacity(bytes.count / 2)
        var i: Int = 0
        while i + 1 < bytes.count {
            let lo: UInt16 = UInt16(bytes[i])
            let hi: UInt16 = UInt16(bytes[i + 1]) << 8
            let v: Int16 = Int16(bitPattern: lo | hi)
            out.append(Float(v) / 32768.0)
            i += 2
        }
        return out
    }
    static func silence(ms: Int) -> [Float] {
        let n: Int = Int(sampleRate * Double(ms) / 1000.0)
        return [Float](repeating: 0, count: max(0, n))
    }
    /// Carillon court généré en code (deux notes sinusoïdales avec enveloppe) — aucun fichier externe.
    static func chime(rising: Bool) -> [Float] {
        let notes: [Double] = rising ? [659.25, 987.77] : [987.77, 659.25]
        var out: [Float] = []
        for f in notes {
            let n: Int = Int(sampleRate * 0.22)
            for k in 0..<n {
                let t: Double = Double(k) / sampleRate
                let attack: Double = min(1.0, t / 0.01)
                let decay: Double = exp(-t * 9.0)
                let s1: Double = sin(2.0 * Double.pi * f * t)
                let s2: Double = 0.3 * sin(4.0 * Double.pi * f * t)
                let v: Double = (s1 + s2) * attack * decay * 0.22
                out.append(Float(v))
            }
        }
        return out
    }
    /// Repli universel : WAV PCM 16 bits mono 24 kHz.
    static func writeWAV(_ samples: [Float], to url: URL) -> Bool {
        let rate: UInt32 = UInt32(sampleRate)
        let dataLen: UInt32 = UInt32(samples.count * 2)
        var d: Data = Data()
        func u32(_ v: UInt32) { var x: UInt32 = v.littleEndian; d.append(Data(bytes: &x, count: 4)) }
        func u16(_ v: UInt16) { var x: UInt16 = v.littleEndian; d.append(Data(bytes: &x, count: 2)) }
        d.append(Data("RIFF".utf8)); u32(36 + dataLen); d.append(Data("WAVE".utf8))
        d.append(Data("fmt ".utf8)); u32(16); u16(1); u16(1); u32(rate); u32(rate * 2); u16(2); u16(16)
        d.append(Data("data".utf8)); u32(dataLen)
        var pcm: [Int16] = []
        pcm.reserveCapacity(samples.count)
        for s in samples {
            let c: Float = max(-1.0, min(1.0, s))
            pcm.append(Int16(c * 32767.0).littleEndian)
        }
        pcm.withUnsafeBufferPointer { (bp: UnsafeBufferPointer<Int16>) -> Void in
            d.append(Data(buffer: bp))
        }
        return (try? d.write(to: url)) != nil
    }
    /// .m4a (AAC) via AVFoundation ; nil = réussi, sinon le motif.
    static func writeM4A(_ samples: [Float], to url: URL) -> String? {
        #if canImport(AVFoundation)
        let settingsA: [String: Any] = [AVFormatIDKey: kAudioFormatMPEG4AAC, AVSampleRateKey: sampleRate, AVNumberOfChannelsKey: 1]
        guard let fmt: AVAudioFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: sampleRate, channels: 1, interleaved: false) else { return "format audio indisponible" }
        do {
            let file: AVAudioFile = try AVAudioFile(forWriting: url, settings: settingsA, commonFormat: .pcmFormatFloat32, interleaved: false)
            let chunk: Int = 24000
            var pos: Int = 0
            while pos < samples.count {
                let n: Int = min(chunk, samples.count - pos)
                guard let buf: AVAudioPCMBuffer = AVAudioPCMBuffer(pcmFormat: fmt, frameCapacity: AVAudioFrameCount(n)) else { return "tampon audio indisponible" }
                buf.frameLength = AVAudioFrameCount(n)
                guard let ch: UnsafePointer<UnsafeMutablePointer<Float>> = buf.floatChannelData else { return "canal audio indisponible" }
                let dst: UnsafeMutablePointer<Float> = ch[0]
                for k in 0..<n { dst[k] = samples[pos + k] }
                try file.write(from: buf)
                pos += n
            }
        } catch {
            return "encodage AAC impossible : " + shortError(String(describing: error), 140)
        }
        return nil
        #else
        return "AVFoundation absent"
        #endif
    }

    // MARK: Livrables

    /// Dernier épisode déposé dans les Livrables (+ script), ou nil.
    static func latest() -> [String: Any]? {
        let items: [[String: Any]] = Livrables.scan().filter { (($0["kind"] as? String) ?? "") == "pod" }
        guard var it = items.first else { return nil }
        let name: String = (it["name"] as? String) ?? ""
        if let sc = Livrables.sidecar(name) {
            it["script"] = (sc["script"] as? String) ?? ""
            it["resume"] = (sc["encadre"] as? String) ?? ""
            it["script_path"] = (sc["script_path"] as? String) ?? ""
            it["tts_chars"] = (sc["tts_chars"] as? Int) ?? 0
            it["duree_s"] = (sc["duree_s"] as? Int) ?? 0
        }
        it["url"] = "/api/livrables/file?name=" + name
        return it
    }
}

// MARK: - Synthèse d'une réplique — voix SYSTÈME macOS (AVSpeechSynthesizer, LocalVoice) : aucun modèle de voix non Meta

extension Voice {
    /// Une réplique → PCM 24 kHz 16 bits (non diffusé), rendue sur le Mac par la voix système. `model` est ignoré (compatibilité).
    func podcastPCM(_ text: String, voiceId: String, model: String) -> (data: Data?, error: String?) {
        var pcm: Data = Data()
        let r = LocalVoice.shared.render(text: text, voiceId: voiceId) { (d: Data) -> Bool in pcm.append(d); return true }
        if r.ok && pcm.count > 400 { return (pcm, nil) }
        journal.add(["moteur": "local", "usage": "podcast", "ok": false, "raison": shortError(r.error ?? "rendu vide", 160)])
        return (nil, r.error ?? "voix système : rendu vide")
    }
    /// Voix françaises INSTALLÉES sur le Mac : [(id, nom, genre, fr)].
    func podcastVoices() -> [(id: String, name: String, gender: String, fr: Bool)] {
        var out: [(id: String, name: String, gender: String, fr: Bool)] = []
        #if canImport(AVFoundation) && os(macOS)
        for v in AVSpeechSynthesisVoice.speechVoices() where v.language.hasPrefix("fr") {
            let g: String = v.gender == .female ? "female" : (v.gender == .male ? "male" : "")
            out.append((id: v.identifier, name: v.name, gender: g, fr: true))
        }
        #endif
        return out
    }
    /// Aucune voix n'est ajoutée à un compte tiers : les voix système s'installent dans Réglages Système › Accessibilité › Contenu énoncé.
    func addFrenchSharedVoice(gender: String, newName: String) -> (id: String?, name: String, error: String?) {
        return (nil, "", "voix système : installe une voix française dans Réglages Système › Accessibilité › Contenu énoncé")
    }
}

// MARK: - Pipeline et routes

extension NovaApp {
    /// 25/10 : matière RÉELLE des 7 derniers jours, assemblée en code. Plafond ~5 000 caractères.
    func podcastMaterial(now: Date = Date()) -> (text: String, facts: Int) {
        let iso: ISO8601DateFormatter = ISO8601DateFormatter()
        let since: String = iso.string(from: now.addingTimeInterval(-7 * 86400))
        let dfm: DateFormatter = DateFormatter()
        dfm.locale = Locale(identifier: "fr_FR")
        dfm.dateFormat = "EEEE d MMMM"
        func day(_ ts: String) -> String {
            guard let d: Date = iso.date(from: ts) else { return String(ts.prefix(10)) }
            return dfm.string(from: d)
        }
        func clean(_ s: String, _ n: Int) -> String {
            let r: String = SecretsGuard.redact(s)
            return NovaApp.oneLine(r, n)
        }
        var parts: [String] = []
        var facts: Int = 0

        // Conversations de la semaine (hors « Hors mémoire »)
        var conv: [String] = []
        var scanned: Int = 0
        for c in convs.list() {
            if conv.count >= 10 || scanned >= 80 { break }
            scanned += 1
            let upd: String = (c["updated"] as? String) ?? ""
            if upd < since { break }   // liste triée du plus récent au plus ancien
            guard let id = c["id"] as? String, let full = convs.get(id) else { continue }
            if (full["incognito"] as? Bool) == true { continue }
            let msgs: [[String: Any]] = (full["messages"] as? [[String: Any]]) ?? []
            let firstUser: [String: Any]? = msgs.first(where: { ($0["role"] as? String) == "user" })
            let lastBot: [String: Any]? = msgs.last(where: { ($0["role"] as? String) == "assistant" && ($0["partial"] as? Bool) != true })
            let ask: String = (firstUser?["content"] as? String) ?? ""
            let ans: String = Persona.stripBiChannel((lastBot?["content"] as? String) ?? "")
            let gist: String = (full["summary"] as? String) ?? ""
            if ask.isEmpty && gist.isEmpty { continue }
            if SecretsGuard.containsSecret(ask + " " + gist) { continue }
            let title: String = (c["title"] as? String) ?? "Conversation"
            if PodcastKit.isAboutNova(title + " " + ask) { continue }   // 26/10 : les essais de Nova ne sont pas la semaine d'Ahadi
            var line: String = "- " + day(upd) + " · « " + clean(title, 60) + " »"
            if !gist.isEmpty { line += " — en bref : " + clean(gist, 240) }
            else {
                line += " — demande : " + clean(ask, 180)
                if !ans.isEmpty { line += " — réponse de Nova : " + clean(ans, 200) }
            }
            conv.append(line)
        }
        if !conv.isEmpty { parts.append("CONVERSATIONS DE LA SEMAINE :\n" + conv.joined(separator: "\n")); facts += conv.count }

        // Briefs de la semaine
        var br: [String] = []
        for b in briefs.list() {
            if br.count >= 6 { break }
            let ts: String = (b["ts"] as? String) ?? ""
            if ts < since { continue }
            let txt: String = (b["text"] as? String) ?? ""
            if txt.isEmpty || SecretsGuard.containsSecret(txt) { continue }
            let label: String = (b["title"] as? String) ?? "Brief"
            // 26/10 : on retire du brief les lignes techniques (PID, chemins, compilation) avant de le résumer.
            let txtClean: String = txt.components(separatedBy: "\n").filter { (l: String) -> Bool in !PodcastKit.isTechnical(l) }.joined(separator: "\n")
            if txtClean.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { continue }
            br.append("- " + day(ts) + " · " + label + " : " + clean(txtClean, 380))
        }
        if !br.isEmpty { parts.append("BRIEFS DE LA SEMAINE :\n" + br.joined(separator: "\n")); facts += br.count }

        // Engagements (commitments.json) : ouverts (retards d'abord) et clos cette semaine
        let co: [String: Any] = JSONFile("commitments.json").read(default: [String: Any]())
        let items: [[String: Any]] = (co["items"] as? [[String: Any]]) ?? []
        var openL: [String] = []
        var doneL: [String] = []
        let nowD: Date = now
        for it in items.reversed() {
            let quoi: String = clean((it["quoi"] as? String) ?? "", 120)
            if quoi.isEmpty { continue }
            let status: String = (it["status"] as? String) ?? "ouvert"
            let qui: String = (it["qui"] as? String) ?? ""
            let ech: String = (it["echeance"] as? String) ?? ""
            let eux: Bool = ((it["dir"] as? String) ?? "moi") == "eux"
            var line: String = "- " + quoi
            if !qui.isEmpty { line += (eux ? " (attendu de " : " (promis à ") + clean(qui, 40) + ")" }
            if status == "ouvert" {
                if openL.count >= 8 { continue }
                if !ech.isEmpty { line += " — échéance " + ech }
                if let dl = DailyCal.deadline(ech), dl < nowD { line += " — EN RETARD" }
                openL.append(line)
            } else if status == "fait" {
                let upd: String = (it["updated"] as? String) ?? ((it["seen"] as? String) ?? "")
                if upd < since || doneL.count >= 6 { continue }
                doneL.append(line + " — tenu")
            }
        }
        if !doneL.isEmpty { parts.append("ENGAGEMENTS TENUS CETTE SEMAINE :\n" + doneL.joined(separator: "\n")); facts += doneL.count }
        if !openL.isEmpty { parts.append("ENGAGEMENTS OUVERTS :\n" + openL.joined(separator: "\n")); facts += openL.count }

        // Résultats d'Éclats de la semaine (hors podcast lui-même)
        var names: [String: String] = [:]
        for d in dots.list() { if let id = d["id"] as? String { names[id] = (d["name"] as? String) ?? id } }
        var runsL: [String] = []
        for r in dots.history() {
            if runsL.count >= 10 { break }
            let ts: String = (r["ts"] as? String) ?? ""
            if ts < since { continue }
            let did: String = (r["dot"] as? String) ?? ""
            if PodcastKit.dotIds.contains(did) { continue }
            if ((r["statut"] as? String) ?? "") == "en_cours" { continue }
            if (r["ok"] as? Bool) != true { continue }
            let res: String = (r["result"] as? String) ?? ""
            if res.isEmpty || SecretsGuard.containsSecret(res) { continue }
            let nm: String = names[did] ?? did
            if PodcastKit.isAboutNova(nm) || PodcastKit.isTechnical(res) { continue }   // 26/10 : santé du Mac, compilation… ne sont pas la semaine d'Ahadi
            runsL.append("- " + day(ts) + " · " + nm + " : " + clean(FeedText.cleanLead(res, maxChars: 260), 220))
        }
        if !runsL.isEmpty { parts.append("RÉSULTATS DES ÉCLATS :\n" + runsL.joined(separator: "\n")); facts += runsL.count }

        // BRVM : marché public toujours ; positions personnelles seulement coffre ouvert (règle du coffre, Feat_Daily)
        if let hook = Tools.brvmHook {
            let raw: String = hook()
            let vaultOpen: Bool = VaultSession.shared.isOpen()
            var mine: [String] = []
            var market: [String] = []
            var inMine: Bool = false
            for line in raw.components(separatedBy: "\n") {
                let t: String = line.trimmingCharacters(in: .whitespaces)
                if t.hasPrefix("MES VALEURS SUIVIES") { inMine = true; continue }
                if t.hasPrefix("MARCHÉ") { inMine = false; continue }
                if inMine {
                    if !vaultOpen || mine.count >= 4 { continue }
                    let masked: String = t.replacingOccurrences(of: #"compte …?\d+\s*:"#, with: ":", options: .regularExpression)
                    if !masked.isEmpty { mine.append(String(masked.prefix(160))) }
                    continue
                }
                if t.hasPrefix("{") {
                    for ml in DailyCal.marketLines(t) where market.count < 3 { market.append("- " + ml) }
                    break
                }
            }
            if !market.isEmpty { parts.append("BRVM (marché public, brvm.org) :\n" + market.joined(separator: "\n")); facts += 1 }
            if !mine.isEmpty { parts.append("POSITIONS PERSONNELLES (coffre ouvert) :\n" + mine.joined(separator: "\n")) }
        }
        var s: String = parts.joined(separator: "\n\n")
        if s.count > 5200 { s = String(s.prefix(5190)) + " […]" }
        return (text: s, facts: facts)
    }

    /// 25/10 : production complète d'un épisode. Retourne ok + chemin, ou ok:false + cause réelle.
    func makePodcast(jobId: String, origin: String, progress: @escaping (String, Int) -> Void) -> [String: Any] {
        let t0: Date = Date()
        func fail(_ cause: String) -> [String: Any] {
            PodcastKit.journal.add(["job": jobId, "origine": origin, "ok": false, "cause": shortError(cause, 200), "ms": Int(Date().timeIntervalSince(t0) * 1000)])
            let r: [String: Any] = ["ok": false, "job": jobId, "error": cause]
            return r
        }
        // 0) clé vocale d'abord : on n'écrit pas un script qu'on ne pourra pas dire
        // 1) matière réelle
        progress("Collecte des faits de la semaine", 5)
        let mat: (text: String, facts: Int) = podcastMaterial()
        if mat.facts == 0 { return fail("aucune matière réelle sur les 7 derniers jours (ni conversation, ni brief, ni engagement, ni Éclat)") }
        // 2) script — un seul appel de cerveau
        progress("Écriture du script (" + String(mat.facts) + " faits)", 15)
        let dfm: DateFormatter = DateFormatter()
        dfm.locale = Locale(identifier: "fr_FR")
        dfm.dateFormat = "d MMMM yyyy"
        let fromS: String = dfm.string(from: Date().addingTimeInterval(-6 * 86400))
        let toS: String = dfm.string(from: Date())
        let vaultOpen: Bool = VaultSession.shared.isOpen()
        let moneyRule: String = vaultOpen
            ? "Les positions personnelles fournies peuvent être évoquées sans numéro de compte ; jamais de conseil d'investissement."
            : "N'énonce AUCUN montant personnel, quantité de titres, solde ou numéro de compte ; les cours publics de la BRVM restent permis, sans conseil d'investissement."
        var sys: String = "Tu écris le script du podcast hebdomadaire d'Ahadi, « Ma semaine en 5 minutes », animé par deux voix : LÉA et MEHDI. "
        sys += "RÈGLES ABSOLUES : (1) N'utilise QUE les faits du DOSSIER fourni ; aucun fait, chiffre, nom, date ou événement inventé ; si la semaine est maigre, l'épisode est plus court et le dit simplement. "
        sys += "(2) Aucune question à Ahadi, aucune demande de confirmation ou de précision : l'épisode est fini et se suffit. "
        sys += "(3) " + moneyRule + " Ni mot de passe, ni code, ni donnée de santé. "
        sys += "(4) FORMAT STRICT : une réplique par ligne, commençant exactement par « LÉA: » ou « MEHDI: », rien d'autre — ni titre, ni didascalie, ni markdown, ni emoji, ni crochets. "
        sys += "(5) 650 à 800 mots au total, 18 à 30 répliques, alternance vivante, 1 à 3 phrases par réplique, français parlé naturel, ton radio chaleureux. LÉA ouvre (accueil, semaine du " + fromS + " au " + toS + "), MEHDI conclut (ce qui compte la semaine prochaine : engagements ouverts, échéances). "
        sys += "(6) Parle de la vie et du travail d'Ahadi (dossiers, personnes, échéances, marché), jamais du fonctionnement de Nova lui-même (voix, tests, podcast, réglages, Éclats, compilation, chemins de fichiers, PID). "
        sys += "Les animateurs parlent d'Ahadi à la troisième personne et peuvent s'adresser à lui en conclusion, sans lui poser de question. Écris les sigles comme ils se prononcent quand c'est utile."
        let user: String = "DOSSIER — faits réels des 7 derniers jours (" + fromS + " → " + toS + ") :\n\n" + mat.text + "\n\nÉcris maintenant le script, au format strict."
        let pref: String = settings.get("brain", "spark-1.3")
        let det: (result: (text: String, brain: String)?, error: String?) = router.completeDetailed(messages: [ChatMsg("user", user)], system: sys, mode: "deep", preferred: pref, maxTokens: 3000, deadline: 150)
        guard var res = det.result else { return fail("script non écrit : " + (det.error ?? "aucun cerveau n'a répondu")) }
        var turnsAll: [PodcastKit.Turn] = PodcastKit.parseTurns(res.text)
        // 25/10 : script raté (souvent le cerveau local de secours, trop petit pour ce format) → 2 essais ciblés sur les cerveaux en ligne.
        if turnsAll.count < 14 {   // 25/10 : 6 répliques = 1 min 26 — trop court ; on vise 18 à 30
            // 26/10 : le même cerveau est relancé avec un rappel explicite (Spark écrivait 6 longues répliques), puis [tiers].
            let retryIds: [String] = [pref, "spark-1.3", "spark-1.2"]
            var tried: Set<String> = []
            let rappel: String = "\n\nATTENTION : ton jet précédent n'avait que " + String(turnsAll.count) + " répliques. Écris AU MOINS 18 répliques COURTES (1 à 3 phrases, 45 mots maximum chacune), en alternant LÉA et MEHDI, une par ligne."
            for rid in retryIds where !tried.contains(rid) && rid != "local" {
                tried.insert(rid)
                progress("Script trop court — nouvel essai (" + rid + ")", 20)
                let d2: (result: (text: String, brain: String)?, error: String?) = router.completeDetailed(messages: [ChatMsg("user", user + rappel)], system: sys, mode: "deep", preferred: rid, maxTokens: 3500, deadline: 150, solo: true)
                if let r2 = d2.result {
                    let t2: [PodcastKit.Turn] = PodcastKit.parseTurns(r2.text)
                    if t2.count > turnsAll.count { res = r2; turnsAll = t2 }
                    if t2.count >= 14 { break }
                }
            }
        }
        // 26/10 : dernière réplique coupée net (sortie tronquée : « … passant de 41 faits. On ») → retirée.
        if let last = turnsAll.last, turnsAll.count > 6 {
            let end: Character? = last.text.trimmingCharacters(in: .whitespaces).last
            if let e = end, !".!?…»\")".contains(e) { turnsAll.removeLast() }
        } else if var last = turnsAll.last {
            let tx: String = last.text.trimmingCharacters(in: .whitespaces)
            if let e = tx.last, !".!?…»\")".contains(e), let cut = tx.range(of: "[.!?…][^.!?…]*$", options: .regularExpression) {
                last.text = String(tx[..<tx.index(after: cut.lowerBound)])
                turnsAll[turnsAll.count - 1] = last
            }
        }
        let brainLabel: String = router.spec(res.brain)?.label ?? res.brain
        if turnsAll.count < 6 { return fail("script hors format (" + String(turnsAll.count) + " réplique(s) LÉA/MEHDI reconnue(s)) — cerveau " + brainLabel) }
        let cap: Int = settings.get("podcast_tts_max_chars", 6000)
        let capped: (kept: [PodcastKit.Turn], chars: Int, dropped: Int) = PodcastKit.capTurns(turnsAll, maxChars: max(500, min(cap, 12000)))
        let turns: [PodcastKit.Turn] = capped.kept
        // 3) voix
        var voiceA: String = settings.get("podcast_voice_a", "")
        var voiceB: String = settings.get("podcast_voice_b", "")
        // 25/10 : réglage vide ou ancienne voix anglaise par défaut → choix automatique de voix FRANÇAISES du compte.
        if voiceA.isEmpty || voiceA == PodcastKit.defaultVoiceA || voiceB.isEmpty || voiceB == PodcastKit.defaultVoiceB {
            let cat: [(id: String, name: String, gender: String, fr: Bool)] = voice.podcastVoices()
            let frF: [(id: String, name: String, gender: String, fr: Bool)] = cat.filter { (v: (id: String, name: String, gender: String, fr: Bool)) -> Bool in v.fr && v.gender == "female" }
            let frM: [(id: String, name: String, gender: String, fr: Bool)] = cat.filter { (v: (id: String, name: String, gender: String, fr: Bool)) -> Bool in v.fr && v.gender == "male" }
            let mainVoice: String = settings.get("voice_id", "")
            if frF.isEmpty && (voiceA.isEmpty || voiceA == PodcastKit.defaultVoiceA) {
                progress("Voix française (Léa)", 22)
                let add: (id: String?, name: String, error: String?) = voice.addFrenchSharedVoice(gender: "female", newName: "Léa (FR)")
                if let nid = add.id { voiceA = nid; settings.set(["podcast_voice_a": nid]) }
            }
            if frM.isEmpty && (voiceB.isEmpty || voiceB == PodcastKit.defaultVoiceB) {
                progress("Voix française (Mehdi)", 23)
                let addM: (id: String?, name: String, error: String?) = voice.addFrenchSharedVoice(gender: "male", newName: "Mehdi (FR)")
                if let nid = addM.id { voiceB = nid; settings.set(["podcast_voice_b": nid]) }
            }
            if voiceA.isEmpty || voiceA == PodcastKit.defaultVoiceA { voiceA = frF.first?.id ?? (mainVoice.isEmpty ? PodcastKit.defaultVoiceA : mainVoice) }
            if voiceB.isEmpty || voiceB == PodcastKit.defaultVoiceB {
                let other: String? = frM.first?.id ?? cat.first(where: { (v: (id: String, name: String, gender: String, fr: Bool)) -> Bool in v.fr && v.id != voiceA })?.id
                voiceB = other ?? PodcastKit.defaultVoiceB
            }
        }
        let model: String = "voix-systeme"
        var samples: [Float] = PodcastKit.chime(rising: true)
        samples += PodcastKit.silence(ms: 400)
        var idx: Int = 0
        for t in turns {
            idx += 1
            let pct: Int = 25 + (60 * idx) / max(1, turns.count)
            progress("Voix " + String(idx) + "/" + String(turns.count), pct)
            let vid: String = t.speaker == "LEA" ? voiceA : voiceB
            let r: (data: Data?, error: String?) = voice.podcastPCM(t.text, voiceId: vid, model: model)
            guard let pcm = r.data else {
                let who: String = t.speaker == "LEA" ? "Léa" : "Mehdi"
                return fail("synthèse vocale système échouée à la réplique " + String(idx) + " (" + who + ") : " + (r.error ?? "inconnu"))
            }
            samples += PodcastKit.fadeEdges(PodcastKit.pcmToFloats(pcm), ms: 12)   // 25/10 : plus de « clic » aux jointures
            samples += PodcastKit.silence(ms: 350)
        }
        samples += PodcastKit.silence(ms: 250)
        samples += PodcastKit.chime(rising: false)
        // 4) assemblage et dépôt dans les Livrables
        progress("Assemblage du fichier audio", 90)
        try? FileManager.default.createDirectory(at: Livrables.dir, withIntermediateDirectories: true)
        let stamp: String = Livrables.stamp()
        var name: String = "cafu-pod-" + stamp + ".m4a"
        var encodeNote: String = "AAC (.m4a)"
        let m4aURL: URL = Livrables.dir.appendingPathComponent(name)
        if let err = PodcastKit.writeM4A(samples, to: m4aURL) {
            try? FileManager.default.removeItem(at: m4aURL)
            name = "cafu-pod-" + stamp + ".wav"
            encodeNote = "WAV (repli : " + err + ")"
            if !PodcastKit.writeWAV(samples, to: Livrables.dir.appendingPathComponent(name)) { return fail("écriture du fichier audio impossible dans " + Livrables.dir.path) }
        }
        guard let path: String = Livrables.path(name) else { return fail("nom de livrable invalide : " + name) }
        let dureeS: Int = Int(Double(samples.count) / PodcastKit.sampleRate)
        let mm: Int = dureeS / 60
        let ss: Int = dureeS % 60
        let dureeTxt: String = String(mm) + " min " + String(format: "%02d", ss) + " s"
        let title: String = "Podcast — ma semaine en 5 minutes (" + fromS + " → " + toS + ")"
        var metaLine: String = "Léa et Mehdi · " + String(turns.count) + " répliques · " + dureeTxt + " · " + String(capped.chars) + " caractères rendus par la voix système · script : " + brainLabel
        if capped.dropped > 0 { metaLine += " · " + String(capped.dropped) + " réplique(s) coupée(s) par le plafond de " + String(cap) + " caractères" }
        let md: String = PodcastKit.scriptMarkdown(turns, title: title, meta: metaLine)
        let mdPath: String = Livrables.dir.appendingPathComponent("cafu-pod-" + stamp + ".md").path
        try? md.write(toFile: mdPath, atomically: true, encoding: .utf8)
        let catN: [(id: String, name: String, gender: String, fr: Bool)] = voice.podcastVoices()
        let nameA: String = catN.first(where: { (v: (id: String, name: String, gender: String, fr: Bool)) -> Bool in v.id == voiceA })?.name ?? voiceA
        let nameB: String = catN.first(where: { (v: (id: String, name: String, gender: String, fr: Bool)) -> Bool in v.id == voiceB })?.name ?? voiceB
        let resume: String = String(turns.count) + " répliques, " + dureeTxt + ", " + String(mat.facts) + " faits réels de la semaine. Voix système : Léa = " + nameA + ", Mehdi = " + nameB + "."
        var plain: String = ""
        for t in turns {
            let who: String = t.speaker == "LEA" ? "Léa" : "Mehdi"
            plain += who + " : " + t.text + "\n"
        }
        let sc: [String: Any] = ["titre": title, "source": "Nova — script " + brainLabel + ", voix système macOS", "format": (name as NSString).pathExtension,
                                 "encadre": resume, "script": plain, "script_path": mdPath, "tts_chars": capped.chars, "duree_s": dureeS,
                                 "voix": ["lea": voiceA, "mehdi": voiceB], "encodage": encodeNote, "faits": mat.facts]
        try? jsonData(sc).write(to: URL(fileURLWithPath: path + ".json"))
        PodcastKit.journal.add(["job": jobId, "origine": origin, "ok": true, "name": name, "tts_chars": capped.chars, "repliques": turns.count, "coupees": capped.dropped, "duree_s": dureeS, "brain": brainLabel, "encodage": encodeNote, "ms": Int(Date().timeIntervalSince(t0) * 1000)])
        let out: [String: Any] = ["ok": true, "job": jobId, "name": name, "path": path, "script_path": mdPath, "titre": title, "resume": resume,
                                  "duree_s": dureeS, "tts_chars": capped.chars, "repliques": turns.count, "coupees": capped.dropped, "brain": brainLabel,
                                  "encodage": encodeNote, "url": "/api/livrables/file?name=" + name]
        return out
    }

    /// Lance un épisode en tâche de fond ; renvoie l'id du travail (ou l'id déjà en cours).
    func startPodcastJob(origin: String) -> (id: String, started: Bool) {
        let id: String = "pod-" + String(UUID().uuidString.prefix(8)).lowercased()
        if !PodcastKit.claim(id) { return (id: PodcastKit.current(), started: false) }
        let busRef: Bus = bus
        PodcastKit.setJob(id, ["id": id, "etat": "en_cours", "etape": "départ", "pct": 0, "debut": nowISO(), "origine": origin])
        busRef.publish("podcast", ["job": id, "etat": "en_cours", "etape": "départ", "pct": 0])
        DispatchQueue.global(qos: .utility).async { [self] in
            _ = self.runPodcastJob(id: id, origin: origin)
        }
        return (id: id, started: true)
    }
    /// Exécution synchrone d'un travail déjà réservé (claim) — publie la progression sur le bus.
    func runPodcastJob(id: String, origin: String) -> [String: Any] {
        let busRef: Bus = bus
        defer { PodcastKit.release(id) }
        let r: [String: Any] = makePodcast(jobId: id, origin: origin) { (step: String, pct: Int) -> Void in
            PodcastKit.setJob(id, ["etape": step, "pct": pct])
            busRef.publish("podcast", ["job": id, "etat": "en_cours", "etape": step, "pct": pct])
        }
        let ok: Bool = (r["ok"] as? Bool) == true
        var fin: [String: Any] = r
        fin["etat"] = ok ? "fait" : "echec"
        fin["fin"] = nowISO()
        fin["pct"] = 100
        PodcastKit.setJob(id, fin)
        busRef.publish("podcast", fin)
        return fin
    }

    func podcastRoutes() {
        let s: HTTPServer = server
        // Voix françaises installées sur le Mac (choix des voix du podcast).
        // 25/10 : installe 2 voix françaises natives (Léa féminine, Mehdi masculine) et les règle pour le podcast.
        s.on("POST", "/api/podcast/voices/fr-setup") { [weak self] _, res in
            guard let app = self else { res.json(["ok": false]); return }
            let fa: (id: String?, name: String, error: String?) = app.voice.addFrenchSharedVoice(gender: "female", newName: "Léa (FR)")
            let ma: (id: String?, name: String, error: String?) = app.voice.addFrenchSharedVoice(gender: "male", newName: "Mehdi (FR)")
            var patch: [String: Any] = [:]
            if let a = fa.id { patch["podcast_voice_a"] = a }
            if let b = ma.id { patch["podcast_voice_b"] = b }
            if !patch.isEmpty { app.settings.set(patch) }
            res.json(["ok": fa.id != nil && ma.id != nil, "lea": fa.name, "mehdi": ma.name, "erreur_lea": fa.error ?? "", "erreur_mehdi": ma.error ?? ""])
        }
        s.on("GET", "/api/podcast/voices") { [weak self] _, res in
            guard let app = self else { res.json(["voices": []]); return }
            let cat: [(id: String, name: String, gender: String, fr: Bool)] = app.voice.podcastVoices()
            var arr: [[String: Any]] = []
            for v in cat { arr.append(["id": v.id, "name": v.name, "gender": v.gender, "fr": v.fr]) }
            res.json(["voices": arr])
        }
        // Crochet de l'Éclat « Podcast hebdo » : exécution synchrone dans le fil du Dot.
        PodcastKit.dotHook = { [weak self] origin, progress in
            guard let app = self else { return ["ok": false, "error": "Nova indisponible"] }
            let id: String = "pod-" + String(UUID().uuidString.prefix(8)).lowercased()
            if !PodcastKit.claim(id) { return ["ok": false, "error": "un épisode est déjà en cours de production (" + PodcastKit.current() + ")"] }
            let busRef: Bus = app.bus
            defer { PodcastKit.release(id) }
            PodcastKit.setJob(id, ["id": id, "etat": "en_cours", "etape": "départ", "pct": 0, "debut": nowISO(), "origine": origin])
            let r: [String: Any] = app.makePodcast(jobId: id, origin: origin) { (step: String, pct: Int) -> Void in
                PodcastKit.setJob(id, ["etape": step, "pct": pct])
                busRef.publish("podcast", ["job": id, "etat": "en_cours", "etape": step, "pct": pct])
                progress(step)
            }
            let ok: Bool = (r["ok"] as? Bool) == true
            var fin: [String: Any] = r
            fin["etat"] = ok ? "fait" : "echec"
            fin["fin"] = nowISO()
            fin["pct"] = 100
            PodcastKit.setJob(id, fin)
            busRef.publish("podcast", fin)
            return fin
        }
        s.on("POST", "/api/podcast/make") { [self] _, res in
            let st: (id: String, started: Bool) = self.startPodcastJob(origin: "manuel")
            if !st.started {
                let busy: [String: Any] = ["ok": false, "job": st.id, "error": "un épisode est déjà en cours de production"]
                res.json(busy, status: 409)
                return
            }
            let ok: [String: Any] = ["ok": true, "job": st.id, "etat": "en_cours", "suivi": "/api/podcast/latest?job=" + st.id]
            res.json(ok, status: 202)
        }
        s.on("GET", "/api/podcast/latest") { req, res in
            var out: [String: Any] = ["ok": true]
            let jid: String = req.query["job"] ?? ""
            if !jid.isEmpty, let j = PodcastKit.job(jid) { out["job"] = j }
            let cur: String = PodcastKit.current()
            if !cur.isEmpty, let j = PodcastKit.job(cur) { out["en_cours"] = j }
            if let l = PodcastKit.latest() { out["episode"] = l } else { out["episode"] = NSNull() }
            res.json(out)
        }
    }
}
