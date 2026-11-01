import Foundation

// 27/10 (Ahadi : « il dit qu'il fait puis rien ne se passe ; les tâches précédentes
// semblent oubliées au profit des nouvelles ») — deux garde-fous mécaniques du fil :
//
// 1) REGISTRE DES TÂCHES INTERROMPUES (ChatTasks) : quand un tour se termine sans
//    réponse livrée (échec de run, plafond d'étapes, arrêt), la demande d'Ahadi est
//    consignée ici. Au tour suivant du même fil, le moteur reçoit une note explicite :
//    terminer d'abord la tâche en attente si le nouveau message ne la remplace pas.
//    Un tour qui livre une vraie réponse efface l'entrée. L'arrêt volontaire (Stop)
//    ne crée pas d'entrée : c'est un choix, pas un oubli.
//
// 2) DÉDOUBLONNAGE DU FLUX (StreamDedup) : les phrases de reprise identiques émises
//    après chaque outil (« Je lance… », « Je m'en occupe… » répétées mot pour mot)
//    ne partent qu'une fois à l'écran quand elles se suivent. Le texte émis et le
//    texte stocké restent identiques (même source : ce qui est filtré ici l'est partout).

/// Registre des runs de conversation EN COURS (27/10, Ahadi : « un Direct arrive pendant
/// qu'il exécute ma tâche, la coupe et il n'a plus livré »). Règle de priorité absolue :
/// une tâche d'Ahadi en cours ne cède jamais devant une arrivée automatique — c'est
/// l'arrivée qui attend (composition Direct différée, relance d'Éclat en vol ignorée).
public enum ChatRuns {
    static var active: [String: Date] = [:]
    static let lock: NSLock = NSLock()
    public static func begin(_ cid: String) { lock.lock(); active[cid] = Date(); lock.unlock() }
    public static func end(_ cid: String) { lock.lock(); active.removeValue(forKey: cid); lock.unlock() }
    public static func anyActive() -> Bool { lock.lock(); defer { lock.unlock() }; return !active.isEmpty }
}

public enum ChatTasks {
    static let file: JSONFile = JSONFile("chat_tasks.json")
    static let lock: NSLock = NSLock()

    public static func pending(_ cid: String) -> [String: Any]? {
        lock.lock(); defer { lock.unlock() }
        let all: [String: Any] = file.read(default: [String: Any]())
        return all[cid] as? [String: Any]
    }

    public static func register(cid: String, ask: String, cause: String) {
        lock.lock(); defer { lock.unlock() }
        var all: [String: Any] = file.read(default: [String: Any]())
        all[cid] = ["ask": String(ask.prefix(400)), "cause": String(cause.prefix(200)), "ts": nowISO()]
        file.write(all)
        _ = BlackBox.record(["tool": "chat", "actor": "Nova", "why": "tâche de conversation non livrée, consignée pour reprise au prochain tour", "ok": false, "effect": "écrit", "result": String(cause.prefix(120))])
    }

    public static func clear(_ cid: String) {
        lock.lock(); defer { lock.unlock() }
        var all: [String: Any] = file.read(default: [String: Any]())
        if all.removeValue(forKey: cid) != nil { file.write(all) }
    }

    /// Note moteur injectée dans le message courant quand une tâche attend dans ce fil.
    public static func note(for cid: String) -> String? {
        guard let p: [String: Any] = pending(cid), let ask: String = p["ask"] as? String, !ask.isEmpty else { return nil }
        let cause: String = (p["cause"] as? String) ?? ""
        return "\n\n[NOTE MOTEUR] La tâche précédente de ce fil (« " + ask.replacingOccurrences(of: "\n", with: " ")
            + " ») s'est arrêtée sans livrer" + (cause.isEmpty ? "" : " (" + cause + ")")
            + ". Si le message actuel ne la remplace pas clairement, termine-la d'abord avec ce que le fil donne déjà, puis traite le nouveau message. Ne redemande pas son sujet."
    }
}

/// FILET DE SORTIE (27/10, audit qualité 24 h G2/G3) : un tour qui se termine
/// sur une promesse sans livraison (« Je lance l'analyse et je te reviens »,
/// « Je m'en occupe. ») est continué UNE fois par le moteur avant stockage —
/// la réponse stockée et affichée est la version livrée, jamais l'annonce.
/// Critères volontairement étroits : demande substantielle, réponse courte,
/// marqueur de promesse, aucun contenu structuré déjà livré.
public enum DeliveryGate {
    static let promiseRx: NSRegularExpression? = try? NSRegularExpression(
        pattern: "(?i)(je (vais|m['’]en occupe|te reviens|te prépare|te détaille|creuse|lance|relève|récupère|corrige|m['’]occupe)|je (t['’]|te )?(l['’])?envoie|dans un instant|tout de suite|je reviens vers toi|je te pr[ée]viens|je surveille|je garde un [œo]e?il|je te rappelle)")   // 29/10 (recette, cas A) : « je te l'envoie / je t'envoie » est une promesse comme les autres
    static let greetRx: NSRegularExpression? = try? NSRegularExpression(
        pattern: "(?i)^\\s*(bonjour|bonsoir|salut|hello|merci|ok|d['’]accord|test|ca va|ça va|cava|hi)\\b")

    /// Demande d'action courte (« Transcription », « analyse ça ») : 1 à 6 mots
    /// contenant un nom d'action ou un objet — pas une salutation ni un accusé.
    /// (28/10, cas réel : « Transcription » -> « Je m'en occupe » sans livraison,
    /// que l'ancien plancher de 3 mots laissait passer.)
    static let actionWords: Set<String> = ["transcription", "analyse", "analyser", "affiche", "afficher", "montre", "ouvre", "ouvrir", "envoie", "envoyer", "prépare", "prepare", "cherche", "trouve", "résume", "resume", "traduis", "traduction", "relance", "vérifie", "verifie", "calcule", "compare", "liste", "téléphone", "telephone", "zoho", "brvm", "mail", "mails", "agenda", "fichier", "document", "rapport", "bilan", "brief", "cr", "go", "vas-y", "vasy"]

    public static func needsContinuation(answer: String, ask: String, toolCount: Int = 0) -> Bool {
        let a: String = answer.trimmingCharacters(in: .whitespacesAndNewlines)
        let q: String = ask.trimmingCharacters(in: .whitespacesAndNewlines)
        if a.isEmpty || q.isEmpty { return false }
        if let gr = greetRx, gr.firstMatch(in: q, range: NSRange(q.startIndex..., in: q)) != nil { return false }
        // 29/10 (Ahadi : « arrêter les questions inutiles et dont la réponse est évidente, livrer directement au lieu de
        // poser des mini-questions à chaque tour ») : une réponse qui se termine sur une OFFRE (« tu veux que je… ? »)
        // ou qui n'est qu'une courte question sans contenu livré est continuée une fois — Nova tranche et livre.
        if isQuestionInsteadOfDelivery(answer: a, ask: q, toolCount: toolCount) { return true }
        // 29/10 (recette, cas B) : une annonce APRÈS de vrais outils — le travail existe,
        // le filet ne continue jamais dessus (le livrable suit dans le même tour).
        if toolCount > 0 { return false }
        let qWords: [String] = q.split(whereSeparator: { (c: Character) -> Bool in c.isWhitespace }).map { String($0) }
        let shortAction: Bool = qWords.count < 3 && qWords.count >= 1 && qWords.contains { (w: String) -> Bool in
            actionWords.contains(w.lowercased().trimmingCharacters(in: .punctuationCharacters))
        }
        if qWords.count < 3 && !shortAction { return false }
        let words: Int = a.split(whereSeparator: { (c: Character) -> Bool in c.isWhitespace }).count
        // Réponse courte + promesse + AUCUN outil réellement exécuté : annonce pure,
        // quelle que soit sa longueur exacte sous 120 mots.
        if words >= 60 && !(toolCount == 0 && words < 120) { return false }
        if a.contains("\n- ") || a.contains("\n|") || a.contains("\n##") || a.contains("```") { return false }   // déjà du contenu livré
        guard let pr = promiseRx else { return false }
        return pr.firstMatch(in: a, range: NSRange(a.startIndex..., in: a)) != nil
    }

    static let offerQRx: NSRegularExpression? = try? NSRegularExpression(
        pattern: "(?i)(tu veux que je|veux-tu que je|voulez-vous que je|souhaites-tu que je|tu souhaites que je|dois-je|je peux (te|le|la|les|aussi)[^?]*\\?|tu préfères|tu prefere|tu préférerais|on part sur|je continue \\?|je lance \\?|c'est bon pour toi \\?|ça te va \\?)")
    static func isQuestionInsteadOfDelivery(answer a: String, ask q: String, toolCount: Int) -> Bool {
        let qWords: Int = q.split(whereSeparator: { (c: Character) -> Bool in c.isWhitespace }).count
        if qWords < 2 { return false }
        guard a.hasSuffix("?") || a.hasSuffix("? ") else { return false }
        // dernière phrase seulement
        let parts: [String] = a.components(separatedBy: CharacterSet(charactersIn: ".!\n"))
        let last: String = (parts.last(where: { (x: String) -> Bool in !x.trimmingCharacters(in: .whitespaces).isEmpty }) ?? a).trimmingCharacters(in: .whitespaces)
        let isOffer: Bool = offerQRx.map { (rx: NSRegularExpression) -> Bool in rx.firstMatch(in: last, range: NSRange(last.startIndex..., in: last)) != nil } ?? false
        if isOffer { return true }
        let words: Int = a.split(whereSeparator: { (c: Character) -> Bool in c.isWhitespace }).count
        let structured: Bool = a.contains("\n- ") || a.contains("\n|") || a.contains("\n##") || a.contains("```") || a.contains("\n1.")
        return toolCount == 0 && words < 70 && !structured
    }

    public static let continuationNote: String = "[MOTEUR NOVA — FILET DE SORTIE] Ta réponse précédente s'arrête sur une annonce ou une question au lieu de livrer. Continue maintenant et livre le résultat complet et structuré. Les choix évidents, tu les prends toi-même et tu les dis en une ligne (« J'ai pris X — dis-moi si tu préfères Y »). Aucune question d'offre (« tu veux que je… ? ») : une suite utile et sans risque, tu la fais. Une question seulement si une information indispensable manque et ne peut pas être devinée — une seule, à la fin, après avoir livré tout le reste. Si un outil est nécessaire, utilise-le."
}

public final class StreamDedup {
    private var pending: String = ""
    private var lastSentence: String = ""
    private var progressKeys: [String: Int] = [:]   // 27/10 : frein anti-boucle « Je corrige… »

    private static func normalize(_ s: String) -> String {
        s.trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "\n", with: " ")
    }

    /// Renvoie le texte à émettre maintenant (peut être vide). Les phrases complètes
    /// identiques à la phrase juste avant (≥ 25 caractères) sont jetées une fois.
    public func push(_ chunk: String) -> String {
        pending += chunk
        var out: String = ""
        while let end: String.Index = StreamDedup.sentenceEnd(pending) {
            let sentence: String = String(pending[..<end])
            pending = String(pending[end...])
            let norm: String = StreamDedup.normalize(sentence)
            if norm.count >= 25 && norm == lastSentence { continue }
            // Frein anti-boucle (27/10, cas réel « Je corrige / Je corrige ça / Tu as
            // raison — je corrige… » ×9) : une courte phrase de progression (< 110 car.)
            // partageant ses 2 premiers mots avec deux phrases déjà émises est jetée.
            if norm.count < 110 {
                let words: [String] = norm.lowercased().split(whereSeparator: { (c: Character) -> Bool in !(c.isLetter) }).map { String($0) }
                if words.count >= 2 {
                    let key: String = words.prefix(2).joined(separator: " ")
                    if (progressKeys[key] ?? 0) >= 2 { continue }
                    progressKeys[key] = (progressKeys[key] ?? 0) + 1
                }
            }
            if !norm.isEmpty { lastSentence = norm }
            out += sentence
        }
        return out
    }

    public func flush() -> String {
        let t: String = pending
        pending = ""
        return t
    }

    public func reset() {
        pending = ""
        lastSentence = ""
        progressKeys = [:]
    }

    /// Fin de la première phrase complète (ponctuation + espace, ou saut de ligne).
    private static func sentenceEnd(_ s: String) -> String.Index? {
        var i: String.Index = s.startIndex
        while i < s.endIndex {
            let c: Character = s[i]
            if c == "\n" { return s.index(after: i) }
            if c == "." || c == "!" || c == "?" || c == "…" {
                let next: String.Index = s.index(after: i)
                if next == s.endIndex { return next }
                if s[next] == " " || s[next] == "\n" { return next }
            }
            i = s.index(after: i)
        }
        return nil
    }
}
