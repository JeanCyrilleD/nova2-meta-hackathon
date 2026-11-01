import Foundation

// 26/10 (Ahadi : « les directs doivent venir là où je suis en conversation active, comme nos messages, et je dois
// pouvoir réagir dessus ») — chaque arrivée composée pour le Fil direct est AUSSI déposée, comme un message de Nova
// (role « assistant »), dans la conversation qu'Ahadi a ouverte (signalée par l'interface, POST /api/ui/conv-active).
// Elle entre donc dans l'historique : « dis-m'en plus », « réponds-lui », « ouvre la pièce jointe » s'enchaînent
// comme dans n'importe quel échange. Le Fil direct garde tout ; la conversation active reçoit le message vivant.
public enum DirectActif {
    static let lock: NSLock = NSLock()
    nonisolated(unsafe) static var active: (id: String, at: Date)? = nil

    public static func setActive(_ id: String) {
        lock.lock(); active = id.isEmpty ? nil : (id, Date()); lock.unlock()
    }
    /// Conversation active depuis moins de 45 min (signal de l'interface), sinon nil.
    static func current() -> String? {
        lock.lock(); defer { lock.unlock() }
        guard let a = active, Date().timeIntervalSince(a.at) < 45 * 60 else { return nil }
        return a.id
    }

    /// 29/10 (audit erreurs silencieuses n°1) : dernière conversation connue, quel que soit son âge — cible des BRIEFS
    /// quand l'interface est calme (07:00), sinon le fil le plus récemment mis à jour.
    static func lastKnown(convs: Conversations, directId: String) -> String? {
        lock.lock(); let a = active; lock.unlock()
        if let x = a?.id, x != directId, convs.get(x) != nil { return x }
        let rows: [[String: Any]] = convs.list().filter { (($0["id"] as? String) ?? "") != directId }
        let best = rows.max { (($0["updated"] as? String) ?? "") < (($1["updated"] as? String) ?? "") }
        return best?["id"] as? String
    }

    /// Texte composé du Fil direct → message de conversation : sans marqueur de navigation ni étiquette d'appareil.
    static func chatText(_ composed: String) -> String {
        var t: String = composed
        t = t.replacingOccurrences(of: #"\s*\[Ouvrir\s*:[^\]]*\]\s*$"#, with: "", options: .regularExpression)
        t = t.replacingOccurrences(of: " · corps lu", with: "")
        t = t.replacingOccurrences(of: #"(?m)^Priorité : [^\n]*$\n?"#, with: "", options: .regularExpression)
        t = t.replacingOccurrences(of: #"(?m)^Commentaire : "#, with: "", options: .regularExpression)
        t = t.replacingOccurrences(of: #"(?m)^Ce qui reste pour toi : "#, with: "**À toi :** ", options: .regularExpression)
        t = t.replacingOccurrences(of: #"(?m)^Échéance : pas d'échéance dans le texte\.?\s*$\n?"#, with: "", options: .regularExpression)
        t = t.replacingOccurrences(of: #"(?m)^Extrait : « [\s\S]*?»\s*$"#, with: "", options: .regularExpression)
        t = t.replacingOccurrences(of: #"\n{3,}"#, with: "\n\n", options: .regularExpression)
        return t.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Dépose le message dans la conversation active (si elle existe et n'est pas le Fil direct).
    nonisolated(unsafe) static var delivered: [String] = []

    static func deliver(convs: Conversations, bus: Bus, directId: String, kind: String, composed: String, feed: String, evTs: String = "") {
        if ["autotest"].contains(kind) { return }
        // 30/10 (test direct : « ✅ Teams est de nouveau branché » tombé au milieu d'une analyse) : un retour à la normale
        // d'une intégration reste dans le Fil direct, jamais dans la conversation en cours.
        if composed.contains("de nouveau branché") || composed.contains(" rebranché") || composed.contains("est débranché") { return }   // 30/10 : alertes de connexion → Fil direct + notification, jamais au milieu d'une conversation
        // 26/10 : jamais de vieux direct rejoué au démarrage ; un même événement n'arrive qu'une fois dans la conversation.
        let maxAge: Double = kind == "brief" ? 4 * 3600 : 30 * 60   // 29/10 : un brief reste utile quelques heures
        if let d = ISO8601DateFormatter().date(from: evTs), Date().timeIntervalSince(d) > maxAge { return }
        lock.lock()
        let already: Bool = delivered.contains(feed)
        lock.unlock()
        if already { return }
        // 26/10 : un Éclat de routine terminé sans rien à décider n'interrompt pas la conversation (les mails ont leur propre direct).
        if kind == "dot.done" && composed.hasPrefix("✅") && !composed.contains("attend ta décision") { return }
        // 29/10 (Ahadi : « pas de vraie proactivité, qualité des infos ») — seul ce qui compte interrompt la conversation en cours :
        // les lettres d'info (📰), les priorités basses (🟢) et les comptes rendus d'Éclats sans décision restent dans le Fil direct.
        if kind != "brief" && (composed.hasPrefix("📰") || composed.contains("🟢 Pour info") || composed.contains("Priorité : basse")) { return }   // 30/10 : un brief CONTIENT des lignes « 🟢 Pour info » — il n'était jamais déposé à cause de ce filtre
        if kind == "dot.done" && !composed.contains("attend ta décision") && !composed.contains("⚠️") { return }
        // 29/10 (audit n°1 : « les briefs n'arrivent pas ») : à 07:00 l'interface est calme depuis > 45 min — un BRIEF va alors
        // dans la dernière conversation connue au lieu d'être perdu ; et il n'est marqué « livré » qu'une fois réellement déposé.
        let cidOpt: String? = current() ?? (kind == "brief" ? lastKnown(convs: convs, directId: directId) : nil)
        guard let cid = cidOpt, cid != directId, convs.get(cid) != nil else {
            if kind == "brief" { _ = BlackBox.record(["tool": "direct_actif", "actor": "Nova", "why": "brief non déposé : aucune conversation cible", "ok": false, "effect": "lecture", "result": "feed=" + feed]) }
            return
        }
        let text: String = chatText(composed)
        if text.count < 8 { return }
        lock.lock(); delivered.append(feed); if delivered.count > 300 { delivered.removeFirst(100) }; lock.unlock()
        let ts: String = convs.append(cid, role: "assistant", content: text, brain: "Nova · direct")
        let msg: [String: Any] = ["role": "assistant", "content": text, "ts": ts, "direct": true, "feed": feed, "kind": kind]
        bus.publish("conv.append", ["conv": cid, "msg": msg])
    }
}
