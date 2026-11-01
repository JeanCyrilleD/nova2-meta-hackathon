import Foundation

// V5-H (24/10/2026) — Crochet UNIQUE des notifications de Nova (côté cœur).
//
// Tous les producteurs (fin d'Éclat, brief prêt, alerte mail/Teams/WhatsApp, Fundings,
// engagement passé en retard, GO en attente) appellent NovaNotifier.send(...).
// - L'app macOS pose `post` (NovaMac/NovaNotify.swift : UNUserNotificationCenter, notification
//   cliquable avec cible {module, id}, actions « Voir » / « Plus tard », AUCUNE notification
//   quand la fenêtre de Nova est déjà active). Sans `post` (binaire hors paquet .app, tests),
//   repli sur l'ancien `display notification` d'osascript — le comportement d'avant, inchangé.
// - Règles identiques à l'existant : réglage « notify », heures calmes (Briefs.inQuietHours,
//   mode concentration compris) ; une alerte URGENTE passe les heures calmes, mais sans son.
// - Rafales : même source < 90 s → la première part tout de suite, les suivantes sont
//   regroupées en UNE notification « N nouveautés » à la fin de la fenêtre.
// - Rien n'est envoyé à personne : une notification est un affichage local.
// - V5-O : plafond « Silence » (Feat_Silence.swift, SilenceGate.admit) au moment de l'affichage natif — non urgent seulement.
public enum NovaNotifier {
    /// Posé par l'app (NovaNotify.install). title, body, cible {module, id}, son.
    nonisolated(unsafe) public static var post: ((_ title: String, _ body: String, _ target: [String: String], _ sound: Bool) -> Void)? = nil
    /// Fournisseurs par défaut (posés par engagementsRoutes) quand l'appelant ne passe pas enabled / quiet.
    nonisolated(unsafe) public static var isEnabled: (() -> Bool)? = nil
    nonisolated(unsafe) public static var isQuiet: (() -> Bool)? = nil
    /// Posé par l'app : vrai quand la fenêtre de Nova est au premier plan (lisible depuis n'importe quel fil).
    nonisolated(unsafe) public static var appActive: (() -> Bool)? = nil

    static let window: TimeInterval = 90
    static let lock: NSLock = NSLock()
    struct Burst {
        var opened: Date
        var pending: Int
        var title: String
        var lastBody: String
        var target: [String: String]
        var sound: Bool
        var flushScheduled: Bool
    }
    nonisolated(unsafe) static var bursts: [String: Burst] = [:]   // PHASE 1 (relu, protégé) : sous lock (post et vidage)

    /// - source : clé de regroupement (ex. « dot:veille », « mail:gm », « fundings »).
    /// - target : {module, id} ouvert au clic (module = id d'écran du shell web).
    /// - urgent : passe les heures calmes (sans son) et n'est jamais retardé par le regroupement.
    public static func send(source: String, title: String, body: String, target: [String: String] = [:],
                            sound: Bool = true, urgent: Bool = false, enabled: Bool? = nil, quiet: Bool? = nil) {
        let on: Bool = enabled ?? (isEnabled?() ?? true)
        if !on { return }
        let calm: Bool = quiet ?? (isQuiet?() ?? false)
        if calm && !urgent { return }
        let snd: Bool = sound && !calm
        let t: String = clean(title, 120)
        let b: String = clean(body, 220)
        let now: Date = Date()
        var deliverNow: Bool = true
        var scheduleFlush: Bool = false
        lock.lock()
        if var br: Burst = bursts[source], now.timeIntervalSince(br.opened) < window, !urgent {
            br.pending += 1
            br.title = t
            br.lastBody = b
            br.target = target
            br.sound = br.sound || snd
            if !br.flushScheduled { br.flushScheduled = true; scheduleFlush = true }
            bursts[source] = br
            deliverNow = false
        } else {
            bursts[source] = Burst(opened: now, pending: 0, title: t, lastBody: b, target: target, sound: snd, flushScheduled: false)
        }
        if bursts.count > 64 {
            let stale: [String] = bursts.filter { (kv: (key: String, value: Burst)) -> Bool in now.timeIntervalSince(kv.value.opened) > window * 4 && !kv.value.flushScheduled }.map { $0.key }
            for k in stale { bursts.removeValue(forKey: k) }
        }
        let wait: TimeInterval = Swift.max(1, window - now.timeIntervalSince(bursts[source]?.opened ?? now))
        lock.unlock()
        if deliverNow && (urgent || SilenceGate.admit(source: source, title: t, body: b, target: target)) { deliver(title: t, body: b, target: target, sound: snd) }   // V5-O : plafond Silence (Feat_Silence.swift) — l'urgent passe toujours
        if scheduleFlush {
            DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + wait) { flush(source) }
        }
    }

    /// Fin de fenêtre : les éléments retenus partent en UNE notification « N nouveautés ».
    /// La fenêtre est rouverte à cet instant (une rafale continue donne une notification / 90 s au plus).
    static func flush(_ source: String) {
        lock.lock()
        guard var br: Burst = bursts[source], br.pending > 0 else { lock.unlock(); return }
        let n: Int = br.pending
        let title: String = br.title
        let last: String = br.lastBody
        let target: [String: String] = br.target
        let snd: Bool = br.sound
        br.pending = 0
        br.flushScheduled = false
        br.opened = Date()
        br.sound = false
        bursts[source] = br
        lock.unlock()
        let head: String = n == 1 ? "1 nouveauté" : String(n) + " nouveautés"
        let body: String = last.isEmpty ? head : head + " · dernière : " + last
        if !SilenceGate.admit(source: source, title: title, body: clean(body, 220), target: target) { return }   // V5-O : une rafale regroupée compte pour UNE notification (jamais urgente : l'urgent ne passe pas par la rafale)
        deliver(title: title, body: clean(body, 220), target: target, sound: snd)
    }

    static func deliver(title: String, body: String, target: [String: String], sound: Bool) {
        if let p = post {
            p(title, body, target, sound)
            return
        }
        #if os(macOS)
        let snd: String = sound ? " sound name \"Glass\"" : ""
        _ = Tools.osa("display notification \"" + osaSafe(body) + "\" with title \"" + osaSafe(title) + "\"" + snd, timeout: 5)
        #endif
    }

    static func clean(_ s: String, _ max: Int) -> String {
        let one: String = s.replacingOccurrences(of: "\r", with: " ").replacingOccurrences(of: "\n", with: " ").trimmingCharacters(in: .whitespacesAndNewlines)
        if one.count <= max { return one }
        return String(one.prefix(max - 1)) + "…"
    }
    static func osaSafe(_ s: String) -> String {
        s.replacingOccurrences(of: "\\", with: "").replacingOccurrences(of: "\"", with: "'")
    }

    // MARK: - GO en attente

    nonisolated(unsafe) static var goNotified: Set<String> = []

    /// Une carte d'approbation (Tools.pendingConfirm) attend depuis plus de 2 min : une notification, une seule fois par
    /// demande. NovaNotify n'affiche rien quand Nova est active (la carte est déjà sous les yeux d'Ahadi) ; sans l'app
    /// (repli osascript), on ne notifie pas : l'état « app active » est inconnu. Le texte de la commande n'est jamais
    /// mis dans la notification (écran verrouillé) — seulement sa nature et son ancienneté.
    static func checkPendingConfirms(now: Date = Date()) {
        if post == nil { return }
        if appActive?() == true { return }   // Nova au premier plan : la carte est sous les yeux d'Ahadi — rien n'est marqué
        if (NovaNotifier.isQuiet?() ?? false) || !(NovaNotifier.isEnabled?() ?? true) { return }   // heures calmes : rien n'est marqué, la notification partira après
        let iso: ISO8601DateFormatter = ISO8601DateFormatter()
        Tools.apLock.lock()
        let pend: [String: [String: Any]] = Tools.pendingConfirm
        Tools.apLock.unlock()
        var due: [(String, String, Int)] = []
        lock.lock()
        goNotified = goNotified.intersection(Set(pend.keys))
        for (id, e) in pend where !goNotified.contains(id) {
            guard let ts: String = e["ts"] as? String, let d: Date = iso.date(from: ts) else { continue }
            let age: TimeInterval = now.timeIntervalSince(d)
            if age < 120 || age > 6 * 3600 { continue }
            goNotified.insert(id)
            due.append((id, (e["kind"] as? String) ?? "action", Int(age / 60)))
        }
        lock.unlock()
        for (id, kind, mins) in due {
            send(source: "go", title: "Nova — un GO t'attend",
                 body: "Autorisation demandée (" + kind + ") en attente depuis " + String(mins) + " min. Rien ne part sans ton clic.",
                 target: ["module": "conversations", "id": "confirm:" + id], urgent: false)
        }
    }
}
