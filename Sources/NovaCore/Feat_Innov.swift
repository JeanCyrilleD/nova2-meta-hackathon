import Foundation

// Nova Plus — INNOVATIONS (4 fonctions, réutilisent l'existant ; rien n'est envoyé, payé ni supprimé sans accord) :
//  1. Jumeau de décision : POST /api/decision/twin {question, options[], memo?} → mémo pour/contre SOURCÉ, factuel (aucun conseil d'investissement).
//     Historique : decisions.json, alimenté par POST /api/decision/log (et par l'import des mémos de la « Salle de décision », côté interface).
//  2. Délégation : POST /api/delegate {sujet, jusqua, consignes, maintenant?} crée un Dot temporaire « deleg-… » (signalements seulement ; brouillon sur demande),
//     mis en pause automatiquement après la date ; GET /api/delegate ; POST /api/delegate/stop {id}.
//  3. Style : POST /api/style/learn (brouillons de Nova vs mails ENVOYÉS, Mail.app en lecture seule) → style_profile.json ; GET /api/style ;
//     POST /api/style/auto {on} ; StyleProfile.promptBlock() (vide sans profil) pour le prompt système.
//  4. Sauvegarde chiffrée : POST /api/backup/run ; GET /api/backup ; POST /api/backup/restore {file} → toujours dans Nova-restaure/ (jamais d'écrasement).
// Minuteurs (références statiques fortes) : sauvegarde (contrôle toutes les heures, une par jour), délégations (toutes les heures),
// style (toutes les 6 h, une fois par semaine, seulement si l'utilisateur a activé « style_auto »).

// MARK: - Contexte partagé

final class InnovCtx: @unchecked Sendable {
    nonisolated(unsafe) static var shared: InnovCtx? = nil
    nonisolated(unsafe) static var backupTimer: DispatchSourceTimer? = nil
    nonisolated(unsafe) static var delegTimer: DispatchSourceTimer? = nil
    nonisolated(unsafe) static var styleTimer: DispatchSourceTimer? = nil

    let router: Router
    let tools: Tools
    let settings: Settings
    let memory: Memory
    let dots: Dots
    let scheduler: DotScheduler
    let publish: (String, Any) -> Void

    init(router: Router, tools: Tools, settings: Settings, memory: Memory, dots: Dots, scheduler: DotScheduler, publish: @escaping (String, Any) -> Void) {
        self.router = router; self.tools = tools; self.settings = settings; self.memory = memory
        self.dots = dots; self.scheduler = scheduler; self.publish = publish
    }
}

// MARK: - Petits outils

private func innovCut(_ s: String, _ n: Int) -> String {
    if s.count <= n { return s }
    return String(s.prefix(n)) + "…"
}

private func innovOneLine(_ s: String) -> String {
    let a: String = s.replacingOccurrences(of: "\r", with: " ")
    return a.replacingOccurrences(of: "\n", with: " ").trimmingCharacters(in: .whitespacesAndNewlines)
}

/// Mots significatifs (≥ 4 lettres, minuscules) pour un rapprochement lexical simple.
private func innovWords(_ s: String) -> Set<String> {
    let low: String = s.lowercased()
    let parts: [String] = low.components(separatedBy: CharacterSet.alphanumerics.inverted)
    var out: Set<String> = []
    for p in parts where p.count >= 4 { out.insert(p) }
    return out
}

/// Premier objet JSON trouvé dans une réponse de modèle (tolère les ``` et le texte autour).
private func innovExtractJSON(_ t: String) -> [String: Any]? {
    guard let a = t.firstIndex(of: "{"), let b = t.lastIndex(of: "}"), a < b else { return nil }
    let sub: String = String(t[a...b])
    return parseJSON(Data(sub.utf8))
}

/// Objet de mail normalisé : sans Re:/TR:/Fwd:…, minuscules.
private func innovNormSubject(_ s: String) -> String {
    var t: String = s.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
    let prefixes: [String] = ["re:", "re :", "tr:", "tr :", "fw:", "fwd:", "fw :", "fwd :", "rép:", "rép :", "ré:", "aw:", "wg:"]
    var changed: Bool = true
    while changed {
        changed = false
        for p in prefixes where t.hasPrefix(p) {
            t = String(t.dropFirst(p.count)).trimmingCharacters(in: .whitespaces)
            changed = true
        }
    }
    return t
}

/// Retire les balises HTML grossièrement (les brouillons de Nova sont souvent en HTML simple).
private func innovStripHTML(_ s: String) -> String {
    let a: String = s.replacingOccurrences(of: "<br\\s*/?>", with: "\n", options: .regularExpression)
    let b: String = a.replacingOccurrences(of: "</(p|li|div|h[1-6])>", with: "\n", options: .regularExpression)
    let c: String = b.replacingOccurrences(of: "<[^>]+>", with: " ", options: .regularExpression)
    let d: String = c.replacingOccurrences(of: "&nbsp;", with: " ").replacingOccurrences(of: "&amp;", with: "&")
    return d.replacingOccurrences(of: "[ \\t]+", with: " ", options: .regularExpression).trimmingCharacters(in: .whitespacesAndNewlines)
}

/// Coupe la partie citée d'une réponse (historique du fil) : seul le texte écrit par l'utilisateur compte.
private func innovStripQuoted(_ body: String) -> String {
    var kept: [String] = []
    for raw in body.components(separatedBy: "\n") {
        let l: String = raw.trimmingCharacters(in: .whitespaces)
        let low: String = l.lowercased()
        if l.hasPrefix(">") { break }
        if low.contains("a écrit :") || low.contains("a écrit:") || low.hasSuffix("wrote:") { break }
        if low.hasPrefix("de :") || low.hasPrefix("de:") || low.hasPrefix("from:") || low.hasPrefix("-----") || low.hasPrefix("________") { break }
        kept.append(raw)
    }
    return kept.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
}

/// Date limite : « AAAA-MM-JJ » (fin de journée locale), « AAAA-MM-JJTHH:MM » ou ISO 8601 complet.
private func innovParseUntil(_ s: String) -> Date? {
    let t: String = s.trimmingCharacters(in: .whitespacesAndNewlines)
    if t.isEmpty { return nil }
    let iso: ISO8601DateFormatter = ISO8601DateFormatter()
    if let d = iso.date(from: t) { return d }
    let isoF: ISO8601DateFormatter = ISO8601DateFormatter()
    isoF.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    if let d = isoF.date(from: t) { return d }
    let f: DateFormatter = DateFormatter()
    f.locale = Locale(identifier: "en_US_POSIX")
    f.timeZone = TimeZone.current
    f.dateFormat = "yyyy-MM-dd'T'HH:mm"
    if let d = f.date(from: String(t.prefix(16))), t.count >= 16 { return d }
    f.dateFormat = "yyyy-MM-dd"
    if let d = f.date(from: String(t.prefix(10))) { return d.addingTimeInterval(86399) }
    return nil
}

private func innovDayText(_ d: Date) -> String {
    let f: DateFormatter = DateFormatter()
    f.locale = Locale(identifier: "fr_FR")
    f.timeZone = TimeZone.current
    f.dateFormat = "dd/MM/yyyy"
    return f.string(from: d)
}

// MARK: - 1. Jumeau de décision

enum InnovDecisions {
    static let file: JSONFile = JSONFile("decisions.json")
    static let lock: NSLock = NSLock()

    static func text(_ d: [String: Any]) -> String {
        let q: String = (d["question"] as? String) ?? ""
        let c: String = (d["choix"] as? String) ?? ""
        let r: String = (d["raisons"] as? String) ?? ""
        let o: [String] = (d["options"] as? [String]) ?? []
        return q + " " + c + " " + r + " " + o.joined(separator: " ")
    }

    static func log(_ j: [String: Any]) -> [String: Any] {
        let q: String = ((j["question"] as? String) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let c: String = ((j["choix"] as? String) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        if q.isEmpty || c.isEmpty { return ["error": "« question » et « choix » sont requis"] }
        let ext: String = ((j["ext_id"] as? String) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        lock.lock(); defer { lock.unlock() }
        var all: [[String: Any]] = file.read(default: [[String: Any]]())
        if !ext.isEmpty, let old = all.first(where: { ($0["ext_id"] as? String) == ext }) {   // import idempotent (Salle de décision)
            return ["ok": true, "item": old, "deja": true]
        }
        var item: [String: Any] = [:]
        item["id"] = String(UUID().uuidString.prefix(8)).lowercased()
        item["ts"] = nowISO()
        item["question"] = innovCut(q, 600)
        item["choix"] = innovCut(c, 600)
        item["raisons"] = innovCut(((j["raisons"] as? String) ?? "").trimmingCharacters(in: .whitespacesAndNewlines), 1500)
        item["options"] = Array(((j["options"] as? [String]) ?? []).prefix(8)).map { innovCut($0, 200) }
        item["source"] = innovCut((j["source"] as? String) ?? "manuel", 40)
        let memo: String = ((j["memo"] as? String) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        if !memo.isEmpty { item["memo"] = innovCut(memo, 2000) }
        if !ext.isEmpty { item["ext_id"] = ext }
        all.append(item)
        file.write(Array(all.suffix(500)))
        return ["ok": true, "item": item]
    }

    static func twin(question: String, options: [String], memo: String) -> [String: Any] {
        guard let c = InnovCtx.shared else { return ["error": "moteur indisponible"] }
        var sources: [[String: String]] = []
        var blocks: [String] = []
        let query: String = question + " " + options.joined(separator: " ")
        let qw: Set<String> = innovWords(query)

        // (a) Décisions passées : les plus proches du sujet, puis les plus récentes.
        let all: [[String: Any]] = file.read(default: [[String: Any]]())
        var scored: [(score: Int, item: [String: Any])] = []
        for d in all {
            let w: Set<String> = innovWords(text(d))
            let sc: Int = w.intersection(qw).count
            if sc > 0 { scored.append((score: sc, item: d)) }
        }
        scored.sort { (a: (score: Int, item: [String: Any]), b: (score: Int, item: [String: Any])) -> Bool in a.score > b.score }
        var picked: [[String: Any]] = []
        for s in scored.prefix(10) { picked.append(s.item) }
        for d in all.suffix(4).reversed() {
            let id: String = (d["id"] as? String) ?? ""
            if !picked.contains(where: { ($0["id"] as? String) == id }) { picked.append(d) }
        }
        var i: Int = 0
        for d in picked {
            i += 1
            let tag: String = "D" + String(i)
            let date: String = String(((d["ts"] as? String) ?? "").prefix(10))
            var line: String = "[" + tag + "] " + date + " — question : " + ((d["question"] as? String) ?? "")
            line += " → choix : " + ((d["choix"] as? String) ?? "")
            let r: String = (d["raisons"] as? String) ?? ""
            if !r.isEmpty { line += " — raisons : " + innovCut(innovOneLine(r), 400) }
            blocks.append(line)
            sources.append(["tag": tag, "type": "décision passée", "text": innovCut(innovOneLine(line), 220)])
        }

        // (b) Mémoire (même recherche que l'outil recall).
        let mem: [[String: Any]] = c.memory.search(query, limit: 8)
        var k: Int = 0
        for m in mem {
            let t: String = (m["text"] as? String) ?? ""
            if t.isEmpty { continue }
            k += 1
            let tag: String = "M" + String(k)
            blocks.append("[" + tag + "] mémoire : " + innovCut(innovOneLine(t), 400))
            sources.append(["tag": tag, "type": "mémoire", "text": innovCut(innovOneLine(t), 220)])
        }

        // (c) Règles de l'utilisateur : consigne générale (chef_consignes) + charte (Constitution).
        let chef: String = c.settings.get("chef_consignes", "")
        if !chef.isEmpty {
            blocks.append("[R1] consigne générale d'Ahadi : " + innovCut(innovOneLine(chef), 1200))
            sources.append(["tag": "R1", "type": "règle", "text": innovCut(innovOneLine(chef), 220)])
        }
        blocks.append("[R2] charte (Constitution " + Constitution.version + ") : " + innovCut(Constitution.text, 2600))
        sources.append(["tag": "R2", "type": "règle", "text": "Charte de Nova (" + Constitution.version + ")"])

        // (d) Documents personnels indexés (outil know, local).
        // promptBlock(query:) = doctrine (extraits de ses chartes/règles) + extraits liés à la question ; vide si rien n'est indexé.
        let know: String = Knowledge.shared.promptBlock(query: query)
        if !know.isEmpty {
            blocks.append("[K] documents personnels et doctrine (base de connaissances) : " + innovCut(know, 2600))
            sources.append(["tag": "K", "type": "documents", "text": innovCut(innovOneLine(know), 220)])
        }
        // (e) Mémo de la Salle de décision (facultatif, transmis par l'interface).
        if !memo.isEmpty {
            blocks.append("[S] mémo de la Salle de décision : " + innovCut(memo, 4000))
            sources.append(["tag": "S", "type": "Salle de décision", "text": innovCut(innovOneLine(memo), 220)])
        }

        let opts: [String] = options.isEmpty ? ["Faire", "Ne pas faire"] : options
        var sys: String = "Tu es le JUMEAU DE DÉCISION d'Ahadi : à partir de SES décisions passées, de SES règles, de SA mémoire et de SES documents, tu rédiges un MÉMO POUR/CONTRE FACTUEL. "
        sys += "INTERDIT : tout conseil d'investissement, toute recommandation d'achat, de vente ou de conservation d'un titre, d'un actif ou d'un placement, toute prévision de cours ; si la question touche un placement (BRVM ou autre), tu restes sur les faits et les précédents et tu écris en tête « Mémo factuel — aucun conseil d'investissement ». "
        sys += "Tu ne décides pas à la place d'Ahadi : pas de « je recommande », pas d'option gagnante, pas de note globale. "
        sys += "Chaque argument porte sa source entre crochets ([D1], [M2], [R1], [R2], [K], [S]) ; un argument sans source est marqué [ÉVALUATION] ou [À vérifier]. N'invente aucun précédent, aucun chiffre, aucune règle. "
        sys += "Français, direct, sans préambule. Titres « ## » dans cet ordre : En bref (2 phrases, sans trancher) · une section « Option : … » par option avec deux listes Pour / Contre · Cohérence avec tes règles · Ce que montrent tes décisions passées (précédents comparables) · Inconnues à vérifier avant de décider."
        var optLines: [String] = []
        for (n, o) in opts.enumerated() { optLines.append(String(n + 1) + ". " + o) }
        var user: String = "QUESTION : " + question + "\nOPTIONS : " + optLines.joined(separator: " | ")
        user += "\n\nÉLÉMENTS SOURCÉS (n'utilise que ceux-ci, plus ta connaissance générale marquée [ÉVALUATION]) :\n"
        user += blocks.isEmpty ? "(aucun élément trouvé : dis-le clairement)" : blocks.joined(separator: "\n")
        guard let r = c.router.complete(messages: [ChatMsg("user", user)], system: sys, mode: "deep", maxTokens: 2200) else {
            return ["error": "Aucun cerveau n'a répondu (voir Routeur & santé).", "sources": sources]
        }
        let label: String = c.router.spec(r.brain)?.label ?? r.brain
        return ["ok": true, "memo": r.text, "brain": label, "sources": sources, "precedents": picked.count]
    }
}

// MARK: - 2. Délégation (Dot temporaire)

enum InnovDeleg {
    static let file: JSONFile = JSONFile("delegations.json")
    static let lock: NSLock = NSLock()
    static let dotTools: [String] = ["mail_week", "mail_unread", "teams_read", "recall", "know", "draft_reply", "cafu_format_email"]

    static func create(_ j: [String: Any]) -> [String: Any] {
        guard let c = InnovCtx.shared else { return ["error": "moteur indisponible"] }
        let sujet: String = ((j["sujet"] as? String) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let jusqua: String = ((j["jusqua"] as? String) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let consignes: String = ((j["consignes"] as? String) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        if sujet.isEmpty { return ["error": "Sujet vide."] }
        guard let until = innovParseUntil(jusqua) else { return ["error": "Date de fin invalide (format AAAA-MM-JJ attendu)."] }
        if until <= Date() { return ["error": "La date de fin est déjà passée."] }
        if until.timeIntervalSinceNow > 92 * 86400 { return ["error": "Délégation limitée à 3 mois : choisis une date plus proche."] }
        let id: String = "deleg-" + String(UUID().uuidString.prefix(6)).lowercased()
        let untilTxt: String = innovDayText(until)
        let sujetCourt: String = innovCut(innovOneLine(sujet), 300)
        var prompt: String = "DÉLÉGATION TEMPORAIRE jusqu'au " + untilTxt + " inclus. SUJET SUIVI : « " + sujetCourt + " »."
        if !consignes.isEmpty { prompt += " CONSIGNES D'AHADI : " + innovCut(innovOneLine(consignes), 800) + "." }
        prompt += " À chaque passage : (1) lis mail_week avec l'argument 2 (reçus et envoyés des 2 derniers jours), puis mail_unread et teams_read ; ne retiens QUE ce qui touche le sujet."
        prompt += " (2) Pour chaque message qui attend une réponse d'Ahadi, signale-le (expéditeur, demande, échéance) — AUCUN brouillon automatique : Signale uniquement : brouillon possible sur demande (Ahadi les demande lui-même)."   // AUDIT-24/10: arrêt des brouillons automatiques
        prompt += " (3) N'ENVOIE JAMAIS RIEN, ne réponds à personne, ne supprime rien : Ahadi valide et envoie lui-même."
        prompt += " (4) Rapport : nouveaux éléments (expéditeur, date, objet), réponses attendues signalées (brouillon possible sur demande), décisions qui reviennent à Ahadi. Si rien de nouveau sur le sujet : réponds uniquement « RAS »."
        prompt += " Si la date du jour est postérieure au " + untilTxt + " : réponds uniquement « RAS — délégation terminée »."
        prompt += StyleProfile.promptBlock()
        var dot: [String: Any] = [:]
        dot["id"] = id
        dot["name"] = "Délégation · " + innovCut(innovOneLine(sujet), 40)
        dot["emoji"] = "🤝"
        dot["color"] = "#0ea5e9"
        dot["role"] = "Suit « " + innovCut(innovOneLine(sujet), 120) + " » jusqu'au " + untilTxt + " (mails, Teams) et signale ce qui attend une réponse (brouillon possible sur demande). N'envoie jamais."
        dot["tools"] = dotTools
        dot["brain"] = "auto"
        dot["schedule"] = "08:40"
        dot["prompt"] = prompt
        dot["quiet_ok"] = true
        dot["paused"] = false
        dot["delegation"] = true
        dot["until"] = ISO8601DateFormatter().string(from: until)
        c.dots.save(dot)
        var item: [String: Any] = [:]
        item["id"] = id
        item["dot"] = id
        item["sujet"] = sujetCourt
        item["consignes"] = innovCut(consignes, 800)
        item["jusqua"] = ISO8601DateFormatter().string(from: until)
        item["jusqua_txt"] = untilTxt
        item["created"] = nowISO()
        item["status"] = "active"
        lock.lock()
        var all: [[String: Any]] = file.read(default: [[String: Any]]())
        all.append(item)
        file.write(Array(all.suffix(100)))
        lock.unlock()
        if (j["maintenant"] as? Bool) == true { c.scheduler.launch(dot, task: "", manual: true) }   // premier passage immédiat, sur demande explicite
        c.publish("delegation", ["id": id, "phase": "active"])
        return ["ok": true, "item": item]
    }

    static func list() -> [[String: Any]] {
        guard let c = InnovCtx.shared else { return [] }
        let all: [[String: Any]] = file.read(default: [[String: Any]]())
        var out: [[String: Any]] = []
        for d in all.reversed() {
            var e: [String: Any] = d
            let dotId: String = (d["dot"] as? String) ?? ""
            if let last = c.dots.history(dotId).first {
                e["last_ts"] = (last["ts"] as? String) ?? ""
                e["last_result"] = innovCut((last["result"] as? String) ?? "", 900)
            }
            if let u = innovParseUntil((d["jusqua"] as? String) ?? "") {
                let days: Int = Int((u.timeIntervalSinceNow / 86400.0).rounded(.up))
                e["jours_restants"] = max(0, days)
            }
            out.append(e)
        }
        return out
    }

    /// Met le Dot en pause (réversible : il n'est jamais supprimé) et marque la délégation.
    static func pauseDot(_ c: InnovCtx, _ dotId: String) {
        guard var d = c.dots.list().first(where: { ($0["id"] as? String) == dotId }) else { return }
        d.removeValue(forKey: "persona")
        d["paused"] = true
        c.dots.save(d)
    }

    static func stop(_ id: String, status: String) -> Bool {
        guard let c = InnovCtx.shared else { return false }
        lock.lock()
        var all: [[String: Any]] = file.read(default: [[String: Any]]())
        guard let i = all.firstIndex(where: { ($0["id"] as? String) == id }) else { lock.unlock(); return false }
        all[i]["status"] = status
        all[i]["ended"] = nowISO()
        let dotId: String = (all[i]["dot"] as? String) ?? id
        file.write(all)
        lock.unlock()
        pauseDot(c, dotId)
        c.publish("delegation", ["id": id, "phase": status])
        return true
    }

    /// Minuteur : délégations arrivées à échéance → Dot en pause, statut « terminee ».
    static func expireDue() {
        let all: [[String: Any]] = file.read(default: [[String: Any]]())
        let now: Date = Date()
        for d in all where ((d["status"] as? String) ?? "") == "active" {
            guard let id = d["id"] as? String, let u = innovParseUntil((d["jusqua"] as? String) ?? "") else { continue }
            if u < now { _ = stop(id, status: "terminee") }
        }
    }
}

// MARK: - 3. Apprentissage du style

struct InnovSentMail {
    let subject: String
    let date: String
    let body: String
}

public enum StyleProfile {
    static let file: JSONFile = JSONFile("style_profile.json")
    static let lock: NSLock = NSLock()
    nonisolated(unsafe) static var running: Bool = false   // PHASE 1 (relu, protégé) : sous lock (startLearn/start, fin de tâche, état)
    nonisolated(unsafe) static var lastError: String = ""   // PHASE 1 (relu, protégé) : sous StyleProfile.lock

    /// Bloc à ajouter au prompt système (vide si aucun profil appris). Lecture en mémoire (JSONFile) : coût négligeable.
    public static func promptBlock() -> String {
        let p: [String: Any] = file.read(default: [String: Any]())
        guard let prof = p["profile"] as? [String: Any], !prof.isEmpty else { return "" }
        var lines: [String] = []
        let date: String = String(((p["ts"] as? String) ?? "").prefix(10))
        lines.append("STYLE D'ÉCRITURE D'AHADI (appris de ses mails réellement envoyés" + (date.isEmpty ? "" : ", " + date) + ") — à appliquer à tout brouillon de mail ou de message :")
        let keys: [(String, String)] = [("Salutation", "salutation"), ("Clôture", "cloture"), ("Registre", "registre"), ("Longueur", "longueur"), ("Structure", "structure")]
        for (label, key) in keys {
            let v: String = (prof[key] as? String) ?? ""
            if !v.isEmpty { lines.append("- " + label + " : " + innovCut(innovOneLine(v), 220)) }
        }
        let f: [String] = (prof["formules"] as? [String]) ?? []
        if !f.isEmpty { lines.append("- Formules habituelles : " + f.prefix(6).joined(separator: " ; ")) }
        let cs: [String] = (prof["consignes"] as? [String]) ?? []
        for x in cs.prefix(8) { lines.append("- " + innovCut(innovOneLine(x), 220)) }
        if lines.count <= 1 { return "" }
        let s: String = lines.joined(separator: "\n")
        return "\n" + innovCut(s, 1600) + "\n"
    }

    static func state() -> [String: Any] {
        var p: [String: Any] = file.read(default: [String: Any]())
        lock.lock(); let r: Bool = running; let e: String = lastError; lock.unlock()
        p["running"] = r
        if !e.isEmpty { p["last_error"] = e }
        p["auto"] = InnovCtx.shared?.settings.get("style_auto", false) ?? false
        p["prompt_block"] = promptBlock()
        return p
    }

    /// Mails ENVOYÉS (Mail.app, boîte « Envoyés » unifiée) : lecture seule, Mail lancé en arrière-plan sans focus.
    static func readSent(max: Int) -> (mails: [InnovSentMail], error: String) {
        #if os(macOS)
        _ = runProcess("/usr/bin/open", ["-g", "-j", "-a", "Mail"], timeout: 10)
        let script: String = """
        tell application "Mail"
          set out to ""
          try
            set mb to sent mailbox
            set n to count of messages of mb
            if n > \(max) then set n to \(max)
            repeat with i from 1 to n
              try
                set m to message i of mb
                set c to content of m
                if (length of c) > 2500 then set c to text 1 thru 2500 of c
                set out to out & "<<<MSG>>>" & (subject of m) & "<<<SEP>>>" & ((date sent of m) as string) & "<<<SEP>>>" & c & linefeed
              end try
            end repeat
          end try
          return out
        end tell
        """
        let (code, out) = runProcess("/usr/bin/osascript", ["-e", script], timeout: 150)
        if code != 0 { return ([], code == 124 ? "Mail.app n'a pas répondu à temps (150 s)." : "Lecture de Mail.app refusée ou impossible (autorisation Automatisation de Nova pour Mail ?).") }
        var mails: [InnovSentMail] = []
        for chunk in out.components(separatedBy: "<<<MSG>>>") {
            let parts: [String] = chunk.components(separatedBy: "<<<SEP>>>")
            if parts.count < 3 { continue }
            let body: String = innovStripQuoted(parts[2...].joined(separator: " "))
            if body.count < 20 { continue }
            mails.append(InnovSentMail(subject: parts[0].trimmingCharacters(in: .whitespacesAndNewlines), date: parts[1].trimmingCharacters(in: .whitespacesAndNewlines), body: body))
        }
        return (mails, mails.isEmpty ? "Aucun mail envoyé lisible dans Mail.app." : "")
        #else
        return ([], "Lecture de Mail.app disponible seulement sur Mac.")
        #endif
    }

    static func startLearn() -> Bool {
        lock.lock()
        if running { lock.unlock(); return false }
        running = true; lastError = ""
        lock.unlock()
        Thread.detachNewThread {
            let r: [String: Any] = StyleProfile.learn()
            StyleProfile.lock.lock()
            StyleProfile.running = false
            StyleProfile.lastError = (r["error"] as? String) ?? ""
            StyleProfile.lock.unlock()
            InnovCtx.shared?.publish("style", ["phase": "done", "ok": r["error"] == nil])
        }
        return true
    }

    static func learn() -> [String: Any] {
        guard let c = InnovCtx.shared else { return ["error": "moteur indisponible"] }
        let drafts: [[String: Any]] = Array(c.tools.drafts.read(default: [[String: Any]]()).suffix(40))
        let got = readSent(max: 30)
        let sent: [InnovSentMail] = got.mails
        if sent.isEmpty { return ["error": got.error] }
        // Paires brouillon de Nova ↔ mail envoyé sur le même sujet (objet identique, inclus, ou ≥ 2 mots communs).
        var pairs: [String] = []
        var used: Set<Int> = []
        for d in drafts.reversed() {
            if pairs.count >= 8 { break }
            let dsub: String = (d["subject"] as? String) ?? ""
            let ns: String = innovNormSubject(dsub)
            if ns.count < 4 { continue }
            let dw: Set<String> = innovWords(ns)
            var match: Int = -1
            for (idx, m) in sent.enumerated() where !used.contains(idx) {
                let ms: String = innovNormSubject(m.subject)
                if ms.count < 4 { continue }
                let same: Bool = ms == ns || ms.contains(ns) || ns.contains(ms)
                let common: Int = innovWords(ms).intersection(dw).count
                if same || common >= 2 { match = idx; break }
            }
            if match < 0 { continue }
            used.insert(match)
            let dbody: String = innovStripHTML((d["body"] as? String) ?? "")
            var block: String = "### PAIRE " + String(pairs.count + 1) + " — objet : " + innovCut(dsub, 120)
            block += "\n— BROUILLON DE NOVA :\n" + innovCut(dbody, 1000)
            block += "\n— MAIL RÉELLEMENT ENVOYÉ PAR AHADI :\n" + innovCut(sent[match].body, 1000)
            pairs.append(block)
        }
        var others: [String] = []
        for (idx, m) in sent.enumerated() where !used.contains(idx) {
            if others.count + pairs.count >= 16 { break }
            others.append("### ENVOYÉ — objet : " + innovCut(m.subject, 120) + "\n" + innovCut(m.body, 900))
        }
        var user: String = ""
        if !pairs.isEmpty { user += "PAIRES (brouillon de Nova → ce qu'Ahadi a réellement envoyé sur le même sujet) :\n\n" + pairs.joined(separator: "\n\n") + "\n\n" }
        user += "AUTRES MAILS ENVOYÉS PAR AHADI (échantillon récent) :\n\n" + others.joined(separator: "\n\n")
        user = innovCut(user, 20000)
        var sys: String = "Tu analyses le STYLE D'ÉCRITURE d'Ahadi à partir de ses mails réellement envoyés, et des écarts entre les brouillons de son assistant Nova et ce qu'il a finalement envoyé. "
        sys += "Décris la salutation, la clôture, la longueur typique, les formules récurrentes, le tutoiement ou vouvoiement (et avec qui, en termes de type de destinataire), et la structure ; vérifie explicitement s'il suit le schéma « salutation, une phrase de contexte, points clés en liste, action demandée en gras, ligne de clôture ». "
        sys += "N'inclus AUCUN nom propre, adresse, numéro ou donnée personnelle des correspondants : seulement des règles de style réutilisables. Ne devine pas : si l'échantillon ne permet pas de conclure, écris « indéterminé ». "
        sys += "Réponds UNIQUEMENT par un objet JSON valide, sans texte autour, de la forme : {\"salutation\":\"…\",\"cloture\":\"…\",\"registre\":\"…\",\"longueur\":\"…\",\"structure\":\"…\",\"formules\":[\"…\"],\"ecarts_nova\":[\"ce que Nova fait et qu'Ahadi corrige\"],\"consignes\":[\"règle impérative pour écrire comme Ahadi (8 au plus)\"],\"confiance\":\"haute|moyenne|basse — raison\"}"
        guard let r = c.router.complete(messages: [ChatMsg("user", user)], system: sys, mode: "deep", maxTokens: 1400) else {
            return ["error": "Aucun cerveau n'a répondu (voir Routeur & santé)."]
        }
        guard let prof = innovExtractJSON(r.text) else { return ["error": "Réponse du cerveau illisible (JSON attendu) : profil inchangé."] }
        var clean: [String: Any] = [:]
        for k in ["salutation", "cloture", "registre", "longueur", "structure", "confiance"] {
            if let v = prof[k] as? String { clean[k] = innovCut(v, 400) }
        }
        for k in ["formules", "ecarts_nova", "consignes"] {
            let arr: [String] = ((prof[k] as? [Any]) ?? []).compactMap { $0 as? String }
            clean[k] = Array(arr.prefix(8)).map { innovCut($0, 300) }
        }
        let label: String = c.router.spec(r.brain)?.label ?? r.brain
        let rec: [String: Any] = ["ts": nowISO(), "profile": clean, "pairs": pairs.count, "sent": sent.count, "drafts": drafts.count, "brain": label,
                                  "source": "Mail.app, boîte Envoyés (lecture seule) + brouillons de Nova"]
        file.write(rec)
        return ["ok": true]
    }

    /// Minuteur : une fois par semaine, seulement si l'utilisateur a activé l'apprentissage automatique (le contenu des mails part vers un cerveau IA).
    static func weeklyTick() {
        guard let c = InnovCtx.shared, c.settings.get("style_auto", false) else { return }
        let p: [String: Any] = file.read(default: [String: Any]())
        let ts: String = (p["ts"] as? String) ?? ""
        if let d = ISO8601DateFormatter().date(from: ts), Date().timeIntervalSince(d) < 7 * 86400 { return }
        _ = startLearn()
    }
}

// MARK: - 4. Sauvegarde chiffrée versionnée

enum InnovBackup {
    static let index: JSONFile = JSONFile("backups.json")   // { "last": iso, "last_error": "", "items": { fichier: {verified, files, bytes, ts} } }
    static let lock: NSLock = NSLock()
    nonisolated(unsafe) static var running: Bool = false   // PHASE 1 (relu, protégé) : sous lock (startLearn/start, fin de tâche, état)
    static let keep: Int = 14
    static let service: String = "nova-backup"
    static let skipExt: Set<String> = ["gguf", "safetensors", "bin", "onnx", "mlmodel", "mlmodelc", "mlpackage", "dmg", "zip", "enc", "part", "key", "pem", "p12", "pfx", "keychain", "keychain-db"]
    static let skipDirs: Set<String> = ["caches", "cache", "models", "modeles", "tmp", "temp", "node_modules"]
    static let maxFile: Int = 200 * 1024 * 1024
    static let maxTotal: Int = 1536 * 1024 * 1024

    static var dir: URL { FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Documents/Nova-Sauvegardes") }
    static var restoreRoot: URL { Paths.home.deletingLastPathComponent().appendingPathComponent("Nova-restaure") }

    static func validName(_ n: String) -> Bool {
        n.range(of: "^nova-[0-9]{8}-[0-9]{4}\\.zip\\.enc$", options: .regularExpression) != nil
    }

    /// Phrase de passe dans le Trousseau (service « nova-backup ») ; générée et enregistrée si absente. Jamais journalisée ni renvoyée à l'interface.
    static func passphrase() -> String? {
        let ref: KeyRef = KeyRef(service: service, accounts: ["$USER"], envVars: [])
        if let v = KeychainStore().value(ref), !v.isEmpty { return v }
        var p: String = runProcess("/usr/bin/openssl", ["rand", "-base64", "36"], timeout: 10).1.trimmingCharacters(in: .whitespacesAndNewlines)
        if p.count < 32 {
            p = (0..<4).map { (_: Int) -> String in UUID().uuidString.replacingOccurrences(of: "-", with: "") }.joined()
        }
        guard KeychainStore.save(service: service, value: p) else { return nil }
        // Relecture par une instance neuve (pas de cache) : on ne chiffre JAMAIS avec une phrase non retrouvable.
        guard let back = KeychainStore().value(ref), back == p else { return nil }
        return p
    }

    static func list() -> [[String: Any]] {
        let fm: FileManager = FileManager.default
        let idx: [String: Any] = index.read(default: [String: Any]())
        let meta: [String: Any] = (idx["items"] as? [String: Any]) ?? [:]
        guard let names = try? fm.contentsOfDirectory(atPath: dir.path) else { return [] }
        var out: [[String: Any]] = []
        for n in names.filter({ validName($0) }).sorted(by: >) {
            let path: String = dir.appendingPathComponent(n).path
            let attrs: [FileAttributeKey: Any] = (try? fm.attributesOfItem(atPath: path)) ?? [:]
            let size: Int = (attrs[.size] as? NSNumber)?.intValue ?? 0
            let mdate: Date = (attrs[.modificationDate] as? Date) ?? Date.distantPast
            var e: [String: Any] = ["file": n, "bytes": size, "ts": ISO8601DateFormatter().string(from: mdate)]
            if let m = meta[n] as? [String: Any] {
                e["verified"] = (m["verified"] as? Bool) ?? false
                e["files"] = (m["files"] as? Int) ?? 0
            }
            out.append(e)
        }
        return out
    }

    static func state() -> [String: Any] {
        let idx: [String: Any] = index.read(default: [String: Any]())
        lock.lock(); let r: Bool = running; lock.unlock()
        var o: [String: Any] = ["items": list(), "running": r, "dir": dir.path, "keep": keep, "restore_dir": restoreRoot.path]
        o["last"] = (idx["last"] as? String) ?? ""
        o["last_error"] = (idx["last_error"] as? String) ?? ""
        o["auto"] = InnovCtx.shared?.settings.get("backup_auto", true) ?? true
        return o
    }

    static func setIndex(_ patch: [String: Any]) {
        var idx: [String: Any] = index.read(default: [String: Any]())
        for (k, v) in patch { idx[k] = v }
        index.write(idx)
    }

    static func start() -> Bool {
        lock.lock()
        if running { lock.unlock(); return false }
        running = true
        lock.unlock()
        Thread.detachNewThread {
            let r: [String: Any] = InnovBackup.run()
            InnovBackup.lock.lock(); InnovBackup.running = false; InnovBackup.lock.unlock()
            InnovCtx.shared?.publish("backup", ["phase": "done", "ok": r["error"] == nil, "file": (r["file"] as? String) ?? ""])
        }
        return true
    }

    /// Copie des fichiers d'état dans un dossier temporaire (exclusions : modèles, caches, archives, fichiers de clés), zip (ditto), chiffrement (openssl), vérification, rotation.
    static func run() -> [String: Any] {
        let fm: FileManager = FileManager.default
        JSONFile.flush()   // écritures différées posées sur le disque avant la copie
        guard let pass = passphrase() else {
            setIndex(["last_error": "Trousseau indisponible : phrase de passe « nova-backup » ni lue ni créée. Aucune sauvegarde."])
            return ["error": "Trousseau indisponible"]
        }
        let f: DateFormatter = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX"); f.timeZone = TimeZone.current; f.dateFormat = "yyyyMMdd-HHmm"
        let name: String = "nova-" + f.string(from: Date()) + ".zip.enc"
        do { try fm.createDirectory(at: dir, withIntermediateDirectories: true) } catch {
            setIndex(["last_error": "Dossier ~/Documents/Nova-Sauvegardes inaccessible (autorisation Documents ?)."])
            return ["error": "dossier de sauvegarde inaccessible"]
        }
        let finalURL: URL = dir.appendingPathComponent(name)
        if fm.fileExists(atPath: finalURL.path) { return ["ok": true, "file": name, "deja": true] }

        let work: URL = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("nova-bk-" + UUID().uuidString)
        let stage: URL = work.appendingPathComponent("Nova")
        defer { try? fm.removeItem(at: work) }   // dossier temporaire créé ici (copie en clair) : toujours effacé
        do { try fm.createDirectory(at: stage, withIntermediateDirectories: true) } catch { return ["error": "dossier temporaire impossible"] }
        try? fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: work.path)

        let src: URL = Paths.home
        let srcPath: String = src.standardizedFileURL.path
        var count: Int = 0
        var total: Int = 0
        var skipped: Int = 0
        let keys: [URLResourceKey] = [.isRegularFileKey, .isDirectoryKey, .fileSizeKey, .isSymbolicLinkKey]
        if let en = fm.enumerator(at: src, includingPropertiesForKeys: keys, options: [], errorHandler: nil) {
            while let obj = en.nextObject() {
                guard let u = obj as? URL else { continue }
                let vals: URLResourceValues? = try? u.resourceValues(forKeys: Set(keys))
                let lname: String = u.lastPathComponent.lowercased()
                if vals?.isDirectory == true {
                    if skipDirs.contains(lname) { en.skipDescendants() }
                    continue
                }
                if vals?.isSymbolicLink == true || vals?.isRegularFile != true { continue }
                if lname == ".ds_store" || skipExt.contains(u.pathExtension.lowercased()) { skipped += 1; continue }
                if lname.contains("secret") || lname.contains("credential") || lname.contains("password") || lname.contains("motdepasse") { skipped += 1; continue }
                let size: Int = vals?.fileSize ?? 0
                if size > maxFile || total + size > maxTotal { skipped += 1; continue }
                let full: String = u.standardizedFileURL.path
                guard full.hasPrefix(srcPath + "/") else { continue }
                let rel: String = String(full.dropFirst(srcPath.count + 1))
                let dest: URL = stage.appendingPathComponent(rel)
                do {
                    try fm.createDirectory(at: dest.deletingLastPathComponent(), withIntermediateDirectories: true)
                    try fm.copyItem(at: u, to: dest)
                    count += 1; total += size
                } catch { skipped += 1 }
            }
        }
        if count == 0 { setIndex(["last_error": "Aucun fichier d'état trouvé dans " + srcPath]); return ["error": "rien à sauvegarder"] }

        let zip: URL = work.appendingPathComponent("nova.zip")
        let z = runProcess("/usr/bin/ditto", ["-c", "-k", "--keepParent", stage.path, zip.path], timeout: 900)
        if z.0 != 0 { setIndex(["last_error": "Compression (ditto) en échec, code " + String(z.0)]); return ["error": "compression en échec"] }
        let part: URL = dir.appendingPathComponent(name + ".part")
        let pin: Data = Data((pass + "\n").utf8)
        let e = runProcess("/usr/bin/openssl", ["enc", "-aes-256-cbc", "-pbkdf2", "-md", "sha256", "-salt", "-in", zip.path, "-out", part.path, "-pass", "stdin"], timeout: 900, stdin: pin)
        let partSize: Int = ((try? fm.attributesOfItem(atPath: part.path))?[.size] as? NSNumber)?.intValue ?? 0
        if e.0 != 0 || partSize == 0 {
            try? fm.removeItem(at: part)   // fichier partiel créé par cette exécution
            setIndex(["last_error": "Chiffrement (openssl) en échec, code " + String(e.0)])
            return ["error": "chiffrement en échec"]
        }
        // Vérification : déchiffrement d'essai et comparaison de taille avec le zip d'origine.
        let check: URL = work.appendingPathComponent("verif.zip")
        let v = runProcess("/usr/bin/openssl", ["enc", "-d", "-aes-256-cbc", "-pbkdf2", "-md", "sha256", "-in", part.path, "-out", check.path, "-pass", "stdin"], timeout: 900, stdin: pin)
        let zipSize: Int = ((try? fm.attributesOfItem(atPath: zip.path))?[.size] as? NSNumber)?.intValue ?? -1
        let chkSize: Int = ((try? fm.attributesOfItem(atPath: check.path))?[.size] as? NSNumber)?.intValue ?? -2
        let verified: Bool = v.0 == 0 && zipSize == chkSize
        do { try fm.moveItem(at: part, to: finalURL) } catch {
            try? fm.removeItem(at: part)
            setIndex(["last_error": "Impossible de finaliser " + name])
            return ["error": "finalisation impossible"]
        }
        try? fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: finalURL.path)
        var idx: [String: Any] = index.read(default: [String: Any]())
        var items: [String: Any] = (idx["items"] as? [String: Any]) ?? [:]
        items[name] = ["verified": verified, "files": count, "bytes": partSize, "skipped": skipped, "ts": nowISO()]
        rotate(&items)
        idx["items"] = items
        idx["last"] = nowISO()
        idx["last_error"] = verified ? "" : "Sauvegarde " + name + " écrite mais la vérification par déchiffrement a échoué."
        index.write(idx)
        return ["ok": true, "file": name, "files": count, "bytes": partSize, "verified": verified, "skipped": skipped]
    }

    /// Garde les `keep` plus récentes ; les plus anciennes vont à la Corbeille (récupérables), jamais effacées directement.
    static func rotate(_ items: inout [String: Any]) {
        let fm: FileManager = FileManager.default
        guard let names = try? fm.contentsOfDirectory(atPath: dir.path) else { return }
        let sorted: [String] = names.filter { validName($0) }.sorted(by: >)
        if sorted.count <= keep { return }
        for n in sorted[keep...] {
            let u: URL = dir.appendingPathComponent(n)
            #if os(macOS)
            do { try fm.trashItem(at: u, resultingItemURL: nil); items.removeValue(forKey: n) } catch {}
            #else
            do { try fm.removeItem(at: u); items.removeValue(forKey: n) } catch {}
            #endif
        }
    }

    /// Restauration dans un dossier SÉPARÉ (Nova-restaure/<nom>[-n]/Nova) : rien n'est écrasé ; l'utilisateur compare puis remplace lui-même.
    static func restore(_ file: String) -> [String: Any] {
        let fm: FileManager = FileManager.default
        let n: String = (file as NSString).lastPathComponent
        guard validName(n) else { return ["error": "nom de sauvegarde invalide"] }
        let src: URL = dir.appendingPathComponent(n)
        guard fm.fileExists(atPath: src.path) else { return ["error": "sauvegarde introuvable"] }
        guard let pass = passphrase() else { return ["error": "phrase de passe introuvable dans le Trousseau (service nova-backup)"] }
        let stem: String = String(n.dropLast(".zip.enc".count))
        var dest: URL = restoreRoot.appendingPathComponent(stem)
        var k: Int = 2
        while fm.fileExists(atPath: dest.path) { dest = restoreRoot.appendingPathComponent(stem + "-" + String(k)); k += 1 }
        let work: URL = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("nova-rs-" + UUID().uuidString)
        defer { try? fm.removeItem(at: work) }
        do {
            try fm.createDirectory(at: work, withIntermediateDirectories: true)
            try fm.createDirectory(at: dest, withIntermediateDirectories: true)
        } catch { return ["error": "dossier de restauration impossible"] }
        try? fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: work.path)
        let zip: URL = work.appendingPathComponent("nova.zip")
        let d = runProcess("/usr/bin/openssl", ["enc", "-d", "-aes-256-cbc", "-pbkdf2", "-md", "sha256", "-in", src.path, "-out", zip.path, "-pass", "stdin"], timeout: 900, stdin: Data((pass + "\n").utf8))
        if d.0 != 0 { return ["error": "déchiffrement impossible (phrase de passe différente ou fichier abîmé)"] }
        let x = runProcess("/usr/bin/ditto", ["-x", "-k", zip.path, dest.path], timeout: 900)
        if x.0 != 0 { return ["error": "décompression impossible"] }
        return ["ok": true, "dest": dest.path, "note": "Restauré à part : compare puis copie toi-même les fichiers voulus vers « Nova » (app fermée). Rien n'a été écrasé."]
    }

    /// Minuteur horaire : une sauvegarde si la dernière date de plus de 22 h.
    static func dailyTick() {
        guard let c = InnovCtx.shared, c.settings.get("backup_auto", true) else { return }
        let idx: [String: Any] = index.read(default: [String: Any]())
        if let d = ISO8601DateFormatter().date(from: (idx["last"] as? String) ?? ""), Date().timeIntervalSince(d) < 22 * 3600 { return }
        _ = start()
    }
}

// MARK: - Routes

extension NovaApp {
    func innovRoutes() {
        let s = server
        let b: Bus = bus
        let ctx: InnovCtx = InnovCtx(router: router, tools: tools, settings: settings, memory: memory, dots: dots, scheduler: scheduler,
                                     publish: { (ev: String, o: Any) in b.publish(ev, o) })
        InnovCtx.shared = ctx

        // Minuteurs (références statiques fortes ; premiers tirs différés pour ne pas alourdir le démarrage).
        if InnovCtx.backupTimer == nil {
            let t: DispatchSourceTimer = DispatchSource.makeTimerSource(queue: DispatchQueue(label: "nova.bg.backup", qos: .utility))
            t.schedule(deadline: .now() + 900, repeating: 3600, leeway: .seconds(60))
            t.setEventHandler { InnovBackup.dailyTick() }
            InnovCtx.backupTimer = t
            t.resume()
        }
        if InnovCtx.delegTimer == nil {
            let t: DispatchSourceTimer = DispatchSource.makeTimerSource(queue: DispatchQueue(label: "nova.bg.delegation", qos: .utility))
            t.schedule(deadline: .now() + 120, repeating: 3600, leeway: .seconds(60))
            t.setEventHandler { InnovDeleg.expireDue() }
            InnovCtx.delegTimer = t
            t.resume()
        }
        if InnovCtx.styleTimer == nil {
            let t: DispatchSourceTimer = DispatchSource.makeTimerSource(queue: DispatchQueue(label: "nova.bg.style", qos: .utility))
            t.schedule(deadline: .now() + 1800, repeating: 6 * 3600, leeway: .seconds(120))
            t.setEventHandler { StyleProfile.weeklyTick() }
            InnovCtx.styleTimer = t
            t.resume()
        }

        // 1. Jumeau de décision
        s.on("POST", "/api/decision/twin") { req, res in
            let j: [String: Any] = req.json
            let q: String = ((j["question"] as? String) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            guard !q.isEmpty else { res.json(["error": "question vide"], status: 400); return }
            let opts: [String] = ((j["options"] as? [Any]) ?? []).compactMap { $0 as? String }.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
            let memo: String = ((j["memo"] as? String) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            let r: [String: Any] = InnovDecisions.twin(question: innovCut(q, 1500), options: Array(opts.prefix(6)), memo: memo)
            res.json(r, status: r["error"] == nil ? 200 : 502)
        }
        s.on("POST", "/api/decision/log") { req, res in
            let r: [String: Any] = InnovDecisions.log(req.json)
            res.json(r, status: r["error"] == nil ? 200 : 400)
        }
        s.on("GET", "/api/decision/log") { _, res in
            let all: [[String: Any]] = InnovDecisions.file.read(default: [[String: Any]]())
            res.json(["items": Array(all.reversed().prefix(200))])
        }

        // 2. Délégation
        s.on("POST", "/api/delegate") { req, res in
            let r: [String: Any] = InnovDeleg.create(req.json)
            res.json(r, status: r["error"] == nil ? 200 : 400)
        }
        s.on("GET", "/api/delegate") { _, res in
            InnovDeleg.expireDue()
            res.json(["items": InnovDeleg.list()])
        }
        s.on("POST", "/api/delegate/stop") { req, res in
            let id: String = (req.json["id"] as? String) ?? ""
            if InnovDeleg.stop(id, status: "arretee") { res.json(["ok": true]) } else { res.json(["error": "délégation introuvable"], status: 404) }
        }

        // 3. Style
        s.on("GET", "/api/style") { _, res in res.json(StyleProfile.state()) }
        s.on("POST", "/api/style/learn") { _, res in
            if StyleProfile.startLearn() { res.json(["ok": true, "started": true]) } else { res.json(["ok": true, "started": false, "running": true]) }
        }
        s.on("POST", "/api/style/auto") { req, res in
            let on: Bool = (req.json["on"] as? Bool) ?? false
            ctx.settings.set(["style_auto": on])
            res.json(["ok": true, "auto": on])
        }

        // 4. Sauvegardes
        s.on("GET", "/api/backup") { _, res in res.json(InnovBackup.state()) }
        s.on("POST", "/api/backup/run") { _, res in
            if InnovBackup.start() { res.json(["ok": true, "started": true]) } else { res.json(["ok": true, "started": false, "running": true]) }
        }
        s.on("POST", "/api/backup/auto") { req, res in
            let on: Bool = (req.json["on"] as? Bool) ?? true
            ctx.settings.set(["backup_auto": on])
            res.json(["ok": true, "auto": on])
        }
        s.on("POST", "/api/backup/restore") { req, res in
            let r: [String: Any] = InnovBackup.restore((req.json["file"] as? String) ?? "")
            res.json(r, status: r["error"] == nil ? 200 : 400)
        }
    }
}
