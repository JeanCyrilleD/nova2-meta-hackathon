import Foundation

// 01/11/2026 (Ahadi) — NOTIFICATIONS « UNE CONVERSATION ATTEND TON ACTION » + « UN TRAVAIL LONG EST FINI ».
//
// Couche au-dessus du crochet unique NovaNotifier (NovaNotifier.swift) — elle ne le remplace pas :
// - ATTENTE D'ACTION : demande d'autorisation (Tools.needConfirm → carte de confirmation), approbation d'envoi
//   (SendApprovals → état awaitingApproval), décision GO d'un Éclat. Une demande d'autorisation BLOQUE un run :
//   elle passe les heures calmes (sans son, règle « urgent » de NovaNotifier) et le plafond de débit.
// - FIN DE TRAVAIL : réponse finie (tour de chat ≥ 8 s), Éclat terminé, note CAFU prête.
// - ANTI-BRUIT : (1) rien si la cible est visible ET la fenêtre de Nova active (l'interface signale la conversation
//   affichée par POST /api/notify/visible) ; (2) regroupement par conversation (source « attn:conv:<cid> » → rafales
//   de 90 s de NovaNotifier, fil de notification par conversation) ; (3) débit global : au plus 4 notifications non
//   urgentes par 5 min, le surplus part en UNE notification « N autres » en fin de fenêtre ; (4) heures calmes
//   (quiet_from / quiet_to, Briefs.inQuietHours) respectées, sauf autorisation bloquante.
// - Réglage « notif_conversations » (Réglages › Général), en plus de l'interrupteur général « notify ».
// - PASTILLE DU DOCK : nombre de demandes en attente (autorisations + envois à approuver + GO d'Éclats),
//   recalculée à chaque événement et chaque minute ; posée par l'app (NovaMac/NovaNotify.swift).
// - Le texte d'une commande à autoriser n'est JAMAIS mis dans la notification (écran verrouillé) : nature + fil.
public enum AttentionNotif {
    public enum Kind: String, CaseIterable, Sendable {
        case authorization, sendApproval, goDecision, responseDone, cafuReady, eclatDone
        /// Bloquant : passe les heures calmes et le plafond de débit.
        var blocking: Bool { self == .authorization }
        var sound: Bool { self == .authorization || self == .sendApproval || self == .goDecision }
    }
    public enum Outcome: String, Sendable { case sent, disabled, quiet, visible, held, tooShort }

    // MARK: fournisseurs (posés par l'app ; remplaçables par les tests)
    nonisolated(unsafe) public static var titleFor: ((String) -> String)? = nil
    nonisolated(unsafe) public static var isOn: (() -> Bool)? = nil          // « notif_conversations »
    nonisolated(unsafe) public static var sendPending: (() -> Int)? = nil
    nonisolated(unsafe) public static var goPending: (() -> Int)? = nil
    nonisolated(unsafe) public static var authPending: (() -> Int)? = { Tools.pendingAuthorizationCount() }
    /// Posé par l'app : pastille du Dock (0 = aucune).
    nonisolated(unsafe) public static var badge: ((Int) -> Void)? = nil
    /// Livraison : par défaut NovaNotifier.send (rafales, Silence, repli osascript).
    nonisolated(unsafe) static var sink: (_ source: String, _ title: String, _ body: String, _ target: [String: String], _ sound: Bool, _ urgent: Bool, _ quiet: Bool) -> Void = { src, t, b, tg, snd, urg, q in
        NovaNotifier.send(source: src, title: t, body: b, target: tg, sound: snd, urgent: urg, enabled: true, quiet: q)
    }
    nonisolated(unsafe) static var schedule: (_ after: TimeInterval, _ work: @escaping () -> Void) -> Void = { after, work in
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + after, execute: work)
    }

    // MARK: état
    static let lock: NSLock = NSLock()
    nonisolated(unsafe) static var visModule: String = ""
    nonisolated(unsafe) static var visCid: String = ""
    nonisolated(unsafe) static var rate: Rate = Rate()
    nonisolated(unsafe) static var lastBadge: Int = -1
    public static let minResponseSeconds: TimeInterval = 8

    /// Débit global des notifications non bloquantes (fenêtre glissante).
    struct Rate {
        var window: TimeInterval = 300
        var max: Int = 4
        var sent: [Date] = []
        var held: Int = 0
        var lastHeldTitle: String = ""
        var flushPlanned: Bool = false
        /// true = afficher ; false = retenue (comptée pour le résumé de fin de fenêtre).
        mutating func admit(_ now: Date, title: String) -> (allow: Bool, planFlushIn: TimeInterval?) {
            sent = sent.filter { now.timeIntervalSince($0) < window }
            if sent.count < max { sent.append(now); return (true, nil) }
            held += 1; lastHeldTitle = title
            if flushPlanned { return (false, nil) }
            flushPlanned = true
            let oldest: Date = sent.min() ?? now
            return (false, Swift.max(1, window - now.timeIntervalSince(oldest)))
        }
        mutating func takeHeld() -> (Int, String) { let r = (held, lastHeldTitle); held = 0; lastHeldTitle = ""; flushPlanned = false; return r }
    }

    // MARK: visibilité (signalée par l'interface)
    public static func setVisible(module: String, cid: String) {
        lock.lock(); visModule = String(module.prefix(40)); visCid = String(cid.prefix(60)); lock.unlock()
    }
    static func normModule(_ m: String) -> String { m == "agent" ? "conversations" : m }
    /// La cible est-elle sous les yeux d'Ahadi ? Fenêtre active ET même écran (et même conversation pour un fil).
    static func isVisible(module: String, id: String, active: Bool) -> Bool {
        if !active { return false }
        lock.lock(); let vm: String = normModule(visModule); let vc: String = visCid; lock.unlock()
        let m: String = normModule(module)
        if m.isEmpty || vm != m { return false }
        if m == "conversations" { return !id.isEmpty && id == vc }
        return true
    }

    /// Portée d'une confirmation (ExecContext.scopeKey) → cible cliquable.
    static func target(forScope scope: String) -> (module: String, id: String) {
        if scope.hasPrefix("conv:") { return ("conversations", String(scope.dropFirst(5))) }
        if scope.hasPrefix("dot:") { return ("dots", String(scope.dropFirst(4))) }
        return ("conversations", "")
    }
    static func convTitle(_ cid: String) -> String {
        let t: String = (titleFor?(cid) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        if t.isEmpty { return "ta conversation" }
        return "« " + NovaNotifier.clean(t, 60) + " »"
    }

    // MARK: point d'entrée unique
    /// - now / active / enabled / quiet : injectables pour les tests (sinon fournisseurs de l'app).
    @discardableResult
    public static func notify(_ kind: Kind, module: String, id: String, title: String, body: String,
                              durationS: TimeInterval? = nil, now: Date = Date(),
                              active: Bool? = nil, enabled: Bool? = nil, quiet: Bool? = nil) -> Outcome {
        let on: Bool = enabled ?? ((NovaNotifier.isEnabled?() ?? true) && (isOn?() ?? true))
        if !on { return .disabled }
        if let d = durationS, (kind == .responseDone || kind == .cafuReady), d < minResponseSeconds { return .tooShort }
        let act: Bool = active ?? (NovaNotifier.appActive?() ?? false)
        if isVisible(module: module, id: id, active: act) { return .visible }
        let calm: Bool = quiet ?? (NovaNotifier.isQuiet?() ?? false)
        if calm && !kind.blocking { return .quiet }
        if !kind.blocking {
            lock.lock()
            let r = rate.admit(now, title: title)
            lock.unlock()
            if !r.allow {
                if let w = r.planFlushIn { schedule(w) { flushHeld() } }
                return .held
            }
        }
        var tg: [String: String] = ["module": normModule(module), "id": id, "attn": "1"]
        let m: String = normModule(module)
        tg["thread"] = m == "conversations" && !id.isEmpty ? "conv:" + id : m
        let source: String
        switch kind {
        case .authorization: source = "attn:auth:" + id
        case .goDecision: source = "dot:" + id
        case .eclatDone: source = "dot:fin"
        default: source = "attn:conv:" + (id.isEmpty ? "?" : id)
        }
        sink(source, title, body, tg, kind.sound && !calm, kind.blocking, calm)
        return .sent
    }

    /// Fin de fenêtre du débit : les notifications retenues partent en UNE seule.
    static func flushHeld() {
        lock.lock(); let (n, last) = rate.takeHeld(); lock.unlock()
        if n <= 0 { return }
        if !(NovaNotifier.isEnabled?() ?? true) || !(isOn?() ?? true) || (NovaNotifier.isQuiet?() ?? false) { return }
        let body: String = (n == 1 ? "1 autre notification regroupée" : String(n) + " autres notifications regroupées") + (last.isEmpty ? "" : " · dernière : " + last)
        sink("attn:resume", "Nova — en attente de toi", NovaNotifier.clean(body, 220), ["module": "attente", "id": "", "attn": "1", "thread": "attente"], false, false, false)
    }

    // MARK: producteurs
    /// Une carte de confirmation vient d'être créée (Tools.confirmHook). Bloquante : passe les heures calmes.
    public static func authorizationRequested(_ e: [String: Any], now: Date = Date(), active: Bool? = nil, enabled: Bool? = nil, quiet: Bool? = nil) -> Outcome {
        let reqId: String = (e["id"] as? String) ?? ""
        let kindTxt: String = ((e["kind"] as? String) ?? "action").trimmingCharacters(in: .whitespacesAndNewlines)
        let t = target(forScope: (e["scope"] as? String) ?? "")
        let qui: String = t.module == "dots" ? "L'Éclat " + (titleFor?("dot:" + t.id) ?? t.id) : convTitle(t.id)
        let out: Outcome = notify(.authorization, module: t.module, id: t.id, title: "Nova — autorisation demandée",
                                  body: qui + " attend ton autorisation (" + kindTxt + "). Rien ne part sans ton clic.",
                                  now: now, active: active, enabled: enabled, quiet: quiet)
        if out == .sent && !reqId.isEmpty { NovaNotifier.lock.lock(); NovaNotifier.goNotified.insert(reqId); NovaNotifier.lock.unlock() }   // pas de second rappel « GO t'attend » à 2 min
        refreshBadgeSoon()
        return out
    }

    /// Transition d'un envoi (SendApprovals.onTransition). Seule l'entrée en attente d'approbation notifie.
    public static func sendTransition(conversationId: String, channel: String, recipients: Int, to: String, now: Date = Date(),
                                      active: Bool? = nil, enabled: Bool? = nil, quiet: Bool? = nil) -> Outcome? {
        defer { refreshBadgeSoon() }
        guard to == "awaitingApproval" else { return nil }
        let canal: String = channel.isEmpty ? "message" : channel
        let dest: String = recipients <= 1 ? "1 destinataire" : String(recipients) + " destinataires"
        return notify(.sendApproval, module: "conversations", id: conversationId, title: "Nova — envoi à approuver",
                      body: convTitle(conversationId) + " : " + canal + " vers " + dest + " attend ton approbation.",
                      now: now, active: active, enabled: enabled, quiet: quiet)
    }

    /// Fin d'un tour de chat avec une vraie réponse (route /api/chat).
    public static func responseDone(cid: String, ask: String, excerpt: String, durationS: TimeInterval, now: Date = Date(),
                                    active: Bool? = nil, enabled: Bool? = nil, quiet: Bool? = nil) -> Outcome {
        let cafu: Bool = CafuMode.detect(ask) || excerpt.contains("cafu-note-")
        let flat: String = NovaNotifier.clean(excerpt.replacingOccurrences(of: "\n", with: " "), 160)
        return notify(cafu ? .cafuReady : .responseDone, module: "conversations", id: cid,
                      title: cafu ? "Nova — note CAFU prête" : "Nova — réponse prête",
                      body: convTitle(cid) + (flat.isEmpty ? "" : " — " + flat),
                      durationS: durationS, now: now, active: active, enabled: enabled, quiet: quiet)
    }

    /// Fin d'un Éclat (événement « dot » phase ready). decision = un GO est attendu.
    public static func eclatReady(dotId: String, name: String, summary: String, decision: Bool, now: Date = Date(),
                                  active: Bool? = nil, enabled: Bool? = nil, quiet: Bool? = nil) -> Outcome {
        defer { refreshBadgeSoon() }
        let nm: String = name.isEmpty ? "Éclat" : name
        if decision {
            return notify(.goDecision, module: "dots", id: dotId, title: "Nova — " + nm + " attend ton GO",
                          body: NovaNotifier.clean(summary, 200), now: now, active: active, enabled: enabled, quiet: quiet)
        }
        return notify(.eclatDone, module: "dots", id: dotId, title: "Nova — Éclat terminé : " + nm,
                      body: NovaNotifier.clean(summary, 200), now: now, active: active, enabled: enabled, quiet: quiet)
    }

    // MARK: pastille du Dock
    public static func pendingCount() -> Int {
        Swift.max(0, authPending?() ?? 0) + Swift.max(0, sendPending?() ?? 0) + Swift.max(0, goPending?() ?? 0)
    }
    /// Recalcule et pose la pastille si elle a changé. Retourne le compte.
    @discardableResult
    public static func refreshBadge() -> Int {
        let n: Int = pendingCount()
        lock.lock(); let changed: Bool = n != lastBadge; lastBadge = n; lock.unlock()
        if changed { badge?(n) }
        return n
    }

    /// Hors des verrous de l'appelant (SendApprovals, DotScheduler, Tools) : recalcul différé.
    public static func refreshBadgeSoon() { schedule(0.05) { _ = refreshBadge() } }

    /// Tests : remet l'état à zéro.
    static func resetForTests() {
        lock.lock(); visModule = ""; visCid = ""; rate = Rate(); lastBadge = -1; lock.unlock()
    }
}

extension Tools {
    /// Demandes d'autorisation encore valables (même fenêtre que le rappel GO : 6 h).
    static func pendingAuthorizationCount(now: Date = Date()) -> Int {
        let iso: ISO8601DateFormatter = ISO8601DateFormatter()
        apLock.lock(); let pend: [String: [String: Any]] = pendingConfirm; apLock.unlock()
        return pend.values.filter { e in
            guard let ts = e["ts"] as? String, let d = iso.date(from: ts) else { return true }
            return now.timeIntervalSince(d) <= 6 * 3600
        }.count
    }
}

extension NovaApp {
    /// Fournisseurs de AttentionNotif + route de visibilité. Appelé une fois depuis routes().
    func attentionRoutes(_ s: HTTPServer) {
        let cv: Conversations = convs
        let ds: Dots = dots
        let sch: DotScheduler = scheduler
        let st: Settings = settings
        AttentionNotif.titleFor = { key in
            if key.hasPrefix("dot:") {
                let id: String = String(key.dropFirst(4))
                return (ds.list().first(where: { ($0["id"] as? String) == id })?["name"] as? String) ?? id
            }
            return (cv.get(key)?["title"] as? String) ?? ""
        }
        AttentionNotif.isOn = { st.get("notif_conversations", true) }
        AttentionNotif.sendPending = { SendApprovals.shared.all().filter { $0.state == .awaitingApproval }.count }
        AttentionNotif.goPending = { sch.waiting().filter { ($0["decision"] as? Bool) == true }.count }
        // L'interface signale l'écran et la conversation affichés (shell.js) : sert à NE PAS notifier ce qu'Ahadi a sous les yeux.
        s.on("POST", "/api/notify/visible") { req, res in
            let j: [String: Any] = req.json
            AttentionNotif.setVisible(module: (j["module"] as? String) ?? "", cid: (j["cid"] as? String) ?? "")
            let out: [String: Any] = ["ok": true, "pending": AttentionNotif.refreshBadge()]
            res.json(out)
        }
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 5) { _ = AttentionNotif.refreshBadge() }
    }
}
