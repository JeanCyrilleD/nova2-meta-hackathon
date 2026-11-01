import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
#if canImport(Network)
import Network
#endif

// VAGUE 2 (24/10/2026) — Résilience faible bande passante + compagnon de charge.
//
// RÉSEAU : NWPathMonitor (framework Network, macOS) dit si une interface existe ; une sonde HEAD
// espacée vers l'hôte de l'API du cerveau principal mesure la latence réelle. État servi :
// « bon » / « faible » / « hors_ligne » (« inconnu » tant qu'aucune mesure n'existe, traité comme bon).
// GET /api/reseau, événement « net » sur /api/events à chaque changement d'état.
// DÉGRADATION : le routeur (Router.chat) lit NetState.levelForRouting() — hors ligne : cerveau local
// seul s'il existe, sinon réponse honnête immédiate ; faible : délais ×1,5 et consigne courte de concision.
// FILE HORS LIGNE : demandes de chat (portail POST /api/chat ci-dessous, qui délègue TOUJOURS au
// handler principal) et Éclats planifiés retenus hors ligne ; rejeu automatique au retour du réseau,
// dans l'ordre, dédoublonné, plafonné. Jamais d'action d'envoi en file : une demande qui ressemble à
// un envoi est refusée de la file (Règle d'or n°2) ; le rejeu passe par le chat normal, donc toute
// action sensible rencontre la carte de confirmation du moteur.
// PRÉ-CALCUL : réseau bon → instantané local (Pulse du jour, agenda, derniers mails triés, engagements)
// horodaté, servi par GET /api/reseau?cache=1 pour un Accueil utile sans réseau.
// COMPAGNON DE CHARGE : signaux réels et explicables (réunions du jour, arrivées urgentes, engagements
// en retard, activité HID tardive, séquence sans pause du Gardien du corps) → au plus 1 à 2
// propositions par jour, en cartes du Pulse (pulseChargeCard), sous le plafond d'interruptions
// (AmeSilence / dots_plafond), jamais en heures calmes, interrupteur « charge_on ».
// Aucun diagnostic de santé, aucune culpabilisation, aucune donnée inventée.

// MARK: - État du réseau

public enum NetState {
    static let lock: NSLock = NSLock()
    nonisolated(unsafe) static var level: String = "inconnu"
    nonisolated(unsafe) static var pathOK: Bool? = nil   // PHASE 1 (relu, protégé) : sous lock (levelForRouting, recompute, snapshot, moniteur)
    nonisolated(unsafe) static var pathConstrained: Bool = false
    nonisolated(unsafe) static var pathExpensive: Bool = false
    nonisolated(unsafe) static var pathIface: String = ""
    nonisolated(unsafe) static var latencies: [Int] = []
    nonisolated(unsafe) static var consecutiveFails: Int = 0
    nonisolated(unsafe) static var lastProbeAt: Date = Date.distantPast
    nonisolated(unsafe) static var lastProbeError: String = ""
    nonisolated(unsafe) static var lastProbeHost: String = ""
    nonisolated(unsafe) static var lastProbeStatus: Int = 0
    nonisolated(unsafe) static var since: Date = Date()   // PHASE 1 (relu, protégé) : sous lock (recompute, snapshot)
    nonisolated(unsafe) static var probing: Bool = false   // PHASE 1 (relu, protégé) : sous lock (probeNow)
    nonisolated(unsafe) static var wantProbe: Bool = true   // PHASE 1 (relu, protégé) : sous lock
    nonisolated(unsafe) static var probes: Int = 0
    // PHASE 1 (partiel confirmé) : `enabled` est réécrit à chaud par POST /api/charge/reglage et lu sans verrou par le chat,
    // le routeur et l'ordonnanceur ; `slowMs` est posé à l'installation. Verrou propre (cfgLock), jamais pris sous `lock` ailleurs
    // que pour une lecture courte : pas d'interblocage (cfgLock ne prend aucun autre verrou).
    static let cfgLock: NSLock = NSLock()
    nonisolated(unsafe) private static var _enabled: Bool = true      // sous cfgLock seulement
    nonisolated(unsafe) private static var _slowMs: Int = 1500        // sous cfgLock seulement
    public static var enabled: Bool { get { cfgLock.lock(); defer { cfgLock.unlock() }; return _enabled } set { cfgLock.lock(); _enabled = newValue; cfgLock.unlock() } }
    public static var slowMs: Int { get { cfgLock.lock(); defer { cfgLock.unlock() }; return _slowMs } set { cfgLock.lock(); _slowMs = newValue; cfgLock.unlock() } }
    nonisolated(unsafe) static var target: () -> URL? = { URL(string: "https://api.meta.ai/") }
    nonisolated(unsafe) static var onChange: ((String, String) -> Void)? = nil
    nonisolated(unsafe) static var monitorRef: AnyObject? = nil
    /// Décisions récentes du portail de chat (texte → « garde » / « envoi » / « plein »), lues par le routeur pour un message exact.
    nonisolated(unsafe) static var decisions: [(at: Date, text: String, status: String)] = []

    public static let weakNote: String = "CONNEXION FAIBLE (consigne courte du routeur) : la liaison réseau d'Ahadi est lente en ce moment. Va droit au but : réponse plus courte, l'essentiel d'abord, sans rien retirer de ce qui est demandé. Cette consigne ne modifie aucune autre règle."

    public static func label(_ l: String) -> String {
        switch l {
        case "bon": return "bon"
        case "faible": return "faible"
        case "hors_ligne": return "hors ligne"
        default: return "en mesure"
        }
    }

    /// État courant, sans sonde (non bloquant).
    public static func current() -> String {
        lock.lock(); let l: String = level; lock.unlock()
        return l
    }

    /// État lu par le routeur. « inconnu » → « bon ». Un « hors ligne » déduit des seules sondes
    /// (interface présente) est revérifié par une sonde courte s'il date de plus de 20 s :
    /// une fausse coupure ne bloque jamais le cloud plus longtemps qu'une sonde.
    public static func levelForRouting() -> String {
        if !enabled { return "bon" }
        lock.lock()
        let l: String = level
        let p: Bool? = pathOK
        let age: TimeInterval = Date().timeIntervalSince(lastProbeAt)
        lock.unlock()
        if l == "hors_ligne", p != false, age > 20 {
            let n: String = probeNow(timeout: 4)
            return n == "inconnu" ? "bon" : n
        }
        return l == "inconnu" ? "bon" : l
    }

    static func median(_ a: [Int]) -> Int? {
        if a.isEmpty { return nil }
        let s: [Int] = a.sorted()
        return s[s.count / 2]
    }

    /// Recalcule l'état ; notifie hors verrou en cas de changement.
    @discardableResult
    static func recompute() -> String {
        lock.lock()
        let old: String = level
        var n: String = "inconnu"
        if pathOK == false { n = "hors_ligne" }
        else if consecutiveFails >= 2 { n = "hors_ligne" }
        else if consecutiveFails == 1 { n = "faible" }
        else if let m: Int = median(latencies) { n = (m > slowMs || pathConstrained) ? "faible" : "bon" }
        else if pathOK == true { n = "inconnu" }
        if n != old { level = n; since = Date() }
        lock.unlock()
        if n != old, let cb = onChange { cb(old, n) }
        return n
    }

    /// Sonde HEAD synchrone vers l'hôte de l'API du cerveau principal (aucun contenu, aucune clé).
    @discardableResult
    static func probeNow(timeout: TimeInterval = 6) -> String {
        lock.lock()
        if probing { let l: String = level; lock.unlock(); return l }
        probing = true; wantProbe = false
        let skip: Bool = pathOK == false
        lock.unlock()
        var ok: Bool = false
        var ms: Int = 0
        var status: Int = 0
        var err: String = ""
        var hostOnly: Bool = false
        let u: URL? = target()
        if skip { err = "aucune interface réseau (NWPathMonitor)" }
        else if let url = u {
            let r: (ok: Bool, ms: Int, status: Int, error: String) = headProbe(url, timeout: timeout)
            ok = r.ok; ms = r.ms; status = r.status; err = r.error
            if !ok, let alt = URL(string: "https://www.apple.com/library/test/success.html") {
                // Hôte du cerveau injoignable : Internet l'est-il ? (évite un faux « hors ligne » si seul un fournisseur tombe)
                let r2: (ok: Bool, ms: Int, status: Int, error: String) = headProbe(alt, timeout: min(timeout, 4))
                if r2.ok { hostOnly = true; err = "hôte du cerveau injoignable (" + err + "), Internet joignable" }
            }
        } else { err = "aucune cible de sonde" }
        lock.lock()
        probing = false
        lastProbeAt = Date()
        lastProbeHost = u?.host ?? ""
        lastProbeStatus = status
        probes += 1
        if ok { consecutiveFails = 0; latencies = Array((latencies + [ms]).suffix(5)); lastProbeError = "" }
        else if hostOnly { consecutiveFails = 1; lastProbeError = err }
        else if !skip { consecutiveFails += 1; lastProbeError = err }
        else { lastProbeError = err }
        lock.unlock()
        return recompute()
    }

    /// Appelé par le routeur sur un échec « réseau » ou « délai » : une sonde est avancée au prochain battement.
    public static func noteRouterFailure() {
        lock.lock(); wantProbe = true; lock.unlock()
    }

    static func pathChanged(satisfied: Bool, constrained: Bool, expensive: Bool, iface: String) {
        lock.lock()
        let changed: Bool = pathOK != satisfied
        pathOK = satisfied; pathConstrained = constrained; pathExpensive = expensive; pathIface = iface
        if !satisfied { consecutiveFails = max(consecutiveFails, 2) }
        if changed { wantProbe = true; if satisfied { consecutiveFails = 0; latencies = [] } }
        lock.unlock()
        recompute()
    }

    static func startMonitor() {
        #if canImport(Network)
        lock.lock(); let already: Bool = monitorRef != nil; lock.unlock()
        if already { return }
        let m: NWPathMonitor = NWPathMonitor()
        m.pathUpdateHandler = { (path: NWPath) in
            var iface: String = ""
            if path.usesInterfaceType(.wifi) { iface = "Wi-Fi" }
            else if path.usesInterfaceType(.wiredEthernet) { iface = "Ethernet" }
            else if path.usesInterfaceType(.cellular) { iface = "cellulaire" }
            else if path.usesInterfaceType(.other) { iface = "autre" }
            NetState.pathChanged(satisfied: path.status == .satisfied, constrained: path.isConstrained, expensive: path.isExpensive, iface: iface)
        }
        m.start(queue: DispatchQueue(label: "nova.net.path", qos: .utility))
        lock.lock(); monitorRef = m; lock.unlock()
        #endif
    }

    /// Délai entre deux sondes : espacé quand tout va bien (données mobiles économisées).
    static func probePeriod() -> TimeInterval {
        switch current() {
        case "bon": return 180
        case "faible": return 60
        case "hors_ligne": return 30
        default: return 20
        }
    }

    static func snapshot() -> [String: Any] {
        lock.lock(); defer { lock.unlock() }
        let iso: ISO8601DateFormatter = ISO8601DateFormatter()
        var o: [String: Any] = [:]
        o["etat"] = level
        o["libelle"] = label(level)
        o["depuis"] = iso.string(from: since)
        o["latence_ms"] = latencies.last as Any? ?? NSNull()
        o["latence_mediane_ms"] = median(latencies) as Any? ?? NSNull()
        o["mesures"] = latencies
        o["seuil_lent_ms"] = slowMs
        o["echecs_consecutifs"] = consecutiveFails
        o["interface"] = pathOK == nil ? "non lue" : (pathOK == true ? (pathIface.isEmpty ? "présente" : pathIface) : "aucune")
        o["donnees_limitees"] = pathConstrained
        o["reseau_couteux"] = pathExpensive
        o["sonde_hote"] = lastProbeHost
        o["sonde_statut_http"] = lastProbeStatus
        o["sonde_erreur"] = lastProbeError
        o["sonde_derniere"] = lastProbeAt == Date.distantPast ? "" : iso.string(from: lastProbeAt)
        o["sondes"] = probes
        o["actif"] = enabled
        #if canImport(Network)
        o["moniteur"] = monitorRef != nil ? "NWPathMonitor" : "non démarré"
        #else
        o["moniteur"] = "indisponible sur cette plateforme"
        #endif
        return o
    }

    static func noteDecision(text: String, status: String) {
        lock.lock()
        let now: Date = Date()
        decisions = decisions.filter { now.timeIntervalSince($0.at) < 180 }
        decisions.append((at: now, text: String(text.prefix(200)), status: status))
        lock.unlock()
    }

    /// Message honnête servi par le routeur quand il n'y a ni réseau ni cerveau local.
    public static func offlineMessage(forPrompt p: String) -> String {
        lock.lock()
        let now: Date = Date()
        var st: String = ""
        for d in decisions.reversed() where now.timeIntervalSince(d.at) < 180 && !d.text.isEmpty && p.contains(d.text) { st = d.status; break }
        lock.unlock()
        let base: String = "Hors ligne : le réseau ne répond pas — les cerveaux Meta sont injoignables."
        switch st {
        case "garde": return base + " Je garde ta demande et je la traite dès le retour du réseau — tu la retrouveras dans ce fil."
        case "envoi": return base + " Ta demande ressemble à une action d'envoi : je ne la rejoue jamais seule. Redemande-la quand le réseau revient."
        case "plein": return base + " La file hors ligne est pleine : cette demande n'a pas été gardée. Redemande-la au retour du réseau."
        default: return base + " Je ne peux pas répondre maintenant ; réessaie au retour du réseau."
        }
    }
}

// MARK: - Stockage

final class ResilienceState: @unchecked Sendable {
    static let shared: ResilienceState = ResilienceState()
    let lock: NSLock = NSLock()
    var started: Bool = false
    var replaying: Bool = false
    var ticks: Int = 0
    var lastPrecalc: Date = Date.distantPast
    var lastCharge: Date = Date.distantPast
    var timers: [DispatchSourceTimer] = []
    let queueFile: JSONFile = JSONFile("hors_ligne_file.json")
    let cacheFile: JSONFile = JSONFile("hors_ligne_cache.json")
    let chargeFile: JSONFile = JSONFile("charge.json")
    let journal: Journal = Journal("resilience_journal.jsonl")
    let work: DispatchQueue = DispatchQueue(label: "nova.resilience.work", qos: .utility)
}

enum ResilienceKit {
    static let sendWords: [String] = ["envoie", "envoyer", "envoi ", "transmets", "transmettre", "publie", "publier", "poste ", "poster ",
                                      "reponds a", "repondre a", "paie", "payer", "paye ", "virement", "supprime", "supprimer", "efface", "effacer",
                                      "partage ", "partager", "forward", "send ", "reply"]

    static func norm(_ s: String) -> String {
        return s.lowercased().folding(options: .diacriticInsensitive, locale: Locale(identifier: "fr_FR"))
    }

    /// La demande ressemble-t-elle à une action d'envoi / publication / paiement / suppression ?
    static func looksLikeSend(_ text: String) -> Bool {
        let t: String = norm(text)
        for w in sendWords where t.contains(w) { return true }
        return false
    }

    static func key(_ parts: [String]) -> String {
        return norm(parts.joined(separator: "|")).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func hm(_ iso: String) -> String {
        guard let d: Date = ISO8601DateFormatter().date(from: iso) else { return "" }
        return DailyCal.hmFmt.string(from: d)
    }
}

// MARK: - Routes et moteur

extension NovaApp {
    func resilienceRoutes() {
        let s = server
        NetState.enabled = settings.get("resilience_on", true)
        NetState.slowMs = max(300, min(10000, settings.get("reseau_lent_ms", 1500)))
        NetState.target = { [weak self] in self?.resilienceProbeTarget() }
        NetState.onChange = { [weak self] (old: String, new: String) in self?.resilienceNetChanged(old: old, new: new) }

        // Éclats planifiés : hors ligne, l'ordonnanceur ne lance pas (le créneau reste ouvert 3 h, il repart au retour du réseau).
        let prevMotif: (() -> String?)? = DotScheduler.pauseMotif
        DotScheduler.pauseMotif = {
            if NetState.enabled && NetState.current() == "hors_ligne" { return "pause: hors ligne — créneau tenu ouvert (3 h), relancé au retour du réseau" }
            return prevMotif?()
        }

        // Portail de chat : enregistré AVANT le handler principal (extraRoutes passe en tête de routes()),
        // il ne répond jamais lui-même — il garde la demande en file si besoin puis DÉLÈGUE au handler suivant.
        let myIndex: Int = s.routes.count
        s.on("POST", "/api/chat") { [self] req, res in resilienceChatGate(req, res, after: myIndex) }

        s.on("GET", "/api/reseau") { [self] req, res in
            var o: [String: Any] = NetState.snapshot()
            o["file"] = resilienceQueueCounts()
            let c: [String: Any] = ResilienceState.shared.cacheFile.read(default: [String: Any]())
            o["precalcul"] = resiliencePrecalcSummary(c)
            if req.query["cache"] == "1" { o["cache"] = c }
            o["cerveau_local"] = router.localSpec()?.label as Any? ?? NSNull()
            o["ts"] = nowISO()
            res.json(o)
        }
        s.on("GET", "/api/offline/file") { [self] _, res in
            let items: [[String: Any]] = ResilienceState.shared.queueFile.read(default: [[String: Any]]())
            res.json(["items": Array(items.reversed()), "compte": resilienceQueueCounts(), "plafond": resilienceQueueMax(), "etat": NetState.current()])
        }
        s.on("POST", "/api/offline/rejouer") { [self] req, res in
            if let cancelId = req.json["annuler"] as? String, !cancelId.isEmpty {
                let ok: Bool = resilienceUpdate(id: cancelId) { (it: inout [String: Any]) in
                    if (it["statut"] as? String) == "attente" { it["statut"] = "annule"; it["note"] = "retirée de la file à ta demande" }
                }
                res.json(["ok": ok, "compte": resilienceQueueCounts()]); return
            }
            let lvl: String = NetState.probeNow(timeout: 5)
            if lvl == "hors_ligne" { res.json(["ok": false, "etat": lvl, "message": "Toujours hors ligne : la file attend le retour du réseau.", "compte": resilienceQueueCounts()]); return }
            let only: String? = req.json["id"] as? String
            ResilienceState.shared.work.async { [self] in _ = resilienceReplay(manual: true, only: only) }
            res.json(["ok": true, "etat": lvl, "message": "Rejeu lancé en arrière-plan.", "compte": resilienceQueueCounts()])
        }
        s.on("GET", "/api/charge") { [self] _, res in res.json(chargeView()) }
        s.on("POST", "/api/charge/reglage") { [self] req, res in
            if let b = req.json["actif"] as? Bool { settings.set(["charge_on": b]) }
            if let n = req.json["max_jour"] as? Int { settings.set(["charge_max_jour": max(0, min(2, n))]) }
            if let b = req.json["reseau_actif"] as? Bool { settings.set(["resilience_on": b]); NetState.enabled = b }
            ResilienceState.shared.journal.add(["evenement": "reglage", "charge_on": settings.get("charge_on", true), "resilience_on": settings.get("resilience_on", true)])
            res.json(chargeView())
        }
        resilienceStart()
    }

    // MARK: battement

    func resilienceStart() {
        let st: ResilienceState = ResilienceState.shared
        st.lock.lock()
        if st.started { st.lock.unlock(); return }
        st.started = true
        st.lock.unlock()
        NetState.startMonitor()
        let t: DispatchSourceTimer = DispatchSource.makeTimerSource(queue: DispatchQueue(label: "nova.resilience.tick", qos: .utility))
        t.schedule(deadline: .now() + 25, repeating: 10, leeway: .seconds(2))
        t.setEventHandler { [weak self] in self?.resilienceTick() }
        st.lock.lock(); st.timers.append(t); st.lock.unlock()
        t.resume()
    }

    func resilienceTick() {
        let st: ResilienceState = ResilienceState.shared
        st.lock.lock(); st.ticks += 1; let n: Int = st.ticks; let lastPre: Date = st.lastPrecalc; let lastCh: Date = st.lastCharge; st.lock.unlock()
        // 1) Sonde réseau : avancée sur demande (changement d'interface, échec du routeur), sinon espacée.
        NetState.lock.lock(); let want: Bool = NetState.wantProbe; let age: TimeInterval = Date().timeIntervalSince(NetState.lastProbeAt); NetState.lock.unlock()
        if NetState.enabled && (want || age >= NetState.probePeriod()) { NetState.probeNow() }
        let lvl: String = NetState.current()
        // 2) Toutes les 5 min : Éclats retenus hors ligne, suivi des Éclats rendus, compagnon de charge.
        if n % 30 == 0 {
            resilienceScanEclats()
            resilienceFollowEclats()
        }
        if Date().timeIntervalSince(lastCh) >= 300 {
            st.lock.lock(); st.lastCharge = Date(); st.lock.unlock()
            chargeTick()
        }
        // 3) Pré-calcul : réseau bon, toutes les 30 min.
        if lvl == "bon" && Date().timeIntervalSince(lastPre) >= 1800 {
            st.lock.lock(); st.lastPrecalc = Date(); st.lock.unlock()
            resiliencePrecalc()
        }
        // 4) File en attente et réseau bon (ex. rejeu interrompu) : nouvel essai toutes les 10 min.
        if lvl == "bon" && n % 60 == 0 && ((resilienceQueueCounts()["attente"] as? Int) ?? 0) > 0 {
            st.work.async { [self] in _ = resilienceReplay(manual: false, only: nil) }
        }
    }

    func resilienceProbeTarget() -> URL? {
        let id: String = settings.get("brain", "spark-1.3")
        let sp: BrainSpec? = (id == "auto" || id == "local") ? nil : router.spec(id)
        var base: String = sp?.baseURL ?? ""
        if sp?.kind == .local || base.isEmpty { base = "https://api.meta.ai/v1/chat/completions" }
        guard let u: URL = URL(string: base), let host: String = u.host, let scheme: String = u.scheme else { return URL(string: "https://api.meta.ai/") }
        if host == "127.0.0.1" || host == "localhost" { return URL(string: "https://api.meta.ai/") }
        return URL(string: scheme + "://" + host + "/")
    }

    func resilienceNetPayload() -> [String: Any] {
        let snap: [String: Any] = NetState.snapshot()
        let etat: String = (snap["etat"] as? String) ?? "inconnu"
        let lat: Any = snap["latence_mediane_ms"] ?? NSNull()
        return ["etat": etat, "libelle": NetState.label(etat), "latence_ms": lat,
                "depuis": (snap["depuis"] as? String) ?? "", "file": resilienceQueueCounts(), "ts": nowISO()]
    }

    func resilienceNetChanged(old: String, new: String) {
        let lat: Any = NetState.snapshot()["latence_mediane_ms"] ?? NSNull()
        ResilienceState.shared.journal.add(["evenement": "etat", "de": old, "vers": new, "latence_ms": lat])
        bus.publish("net", resilienceNetPayload())
        if new == "bon" && old != "bon" {
            let st: ResilienceState = ResilienceState.shared
            st.work.async { [self] in
                _ = resilienceReplay(manual: false, only: nil)
                st.lock.lock(); st.lastPrecalc = Date(); st.lock.unlock()
                resiliencePrecalc()
            }
        }
    }

    // MARK: file hors ligne

    func resilienceQueueMax() -> Int { return max(5, min(50, settings.get("offline_file_max", 20))) }

    func resilienceQueueCounts() -> [String: Any] {
        let items: [[String: Any]] = ResilienceState.shared.queueFile.read(default: [[String: Any]]())
        var c: [String: Int] = ["attente": 0, "fait": 0, "echec": 0, "relance": 0]
        for it in items { let s: String = (it["statut"] as? String) ?? ""; c[s] = (c[s] ?? 0) + 1 }
        return ["attente": c["attente"] ?? 0, "fait": c["fait"] ?? 0, "echec": c["echec"] ?? 0, "relance": c["relance"] ?? 0, "total": items.count]
    }

    /// Ajoute une entrée (dédoublonnée par clé, plafonnée). Retourne « garde », « doublon » ou « plein ».
    func resilienceEnqueue(_ entry: [String: Any]) -> String {
        let st: ResilienceState = ResilienceState.shared
        st.lock.lock(); defer { st.lock.unlock() }
        var items: [[String: Any]] = st.queueFile.read(default: [[String: Any]]())
        let k: String = (entry["cle"] as? String) ?? ""
        if !k.isEmpty, items.contains(where: { ($0["cle"] as? String) == k && ["attente", "relance"].contains(($0["statut"] as? String) ?? "") }) { return "doublon" }
        let pending: Int = items.filter { ($0["statut"] as? String) == "attente" }.count
        if pending >= resilienceQueueMax() { return "plein" }
        var e: [String: Any] = entry
        e["id"] = "q" + String(UUID().uuidString.prefix(8)).lowercased()
        e["ts"] = nowISO()
        e["statut"] = "attente"
        e["essais"] = 0
        items.append(e)
        // Historique borné : les entrées closes les plus anciennes partent d'abord.
        while items.count > 80, let i: Int = items.firstIndex(where: { ($0["statut"] as? String) != "attente" }) { items.remove(at: i) }
        st.queueFile.write(items)
        st.journal.add(["evenement": "file", "type": e["type"] ?? "", "id": e["id"] ?? ""])
        return "garde"
    }

    @discardableResult
    func resilienceUpdate(id: String, _ f: (inout [String: Any]) -> Void) -> Bool {
        let st: ResilienceState = ResilienceState.shared
        st.lock.lock(); defer { st.lock.unlock() }
        var items: [[String: Any]] = st.queueFile.read(default: [[String: Any]]())
        guard let i: Int = items.firstIndex(where: { ($0["id"] as? String) == id }) else { return false }
        var it: [String: Any] = items[i]
        f(&it)
        items[i] = it
        st.queueFile.write(items)
        return true
    }

    func resilienceChatDelegate(_ req: Request, _ res: Response, after idx: Int) {
        let rs: [(String, String, HTTPServer.Handler)] = server.routes
        var i: Int = idx + 1
        while i < rs.count {
            let r: (String, String, HTTPServer.Handler) = rs[i]
            if r.0 == "POST" && r.1 == "/api/chat" { r.2(req, res); return }
            i += 1
        }
        res.json(["error": "route de conversation introuvable"], status: 500)
    }

    func resilienceChatGate(_ req: Request, _ res: Response, after idx: Int) {
        let replay: Bool = req.headers["x-nova-replay"] == "1"
        let j: [String: Any] = req.json
        let text: String = ((j["text"] as? String) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        if replay || !NetState.enabled || text.isEmpty { resilienceChatDelegate(req, res, after: idx); return }
        let remote: Bool = req.headers["x-nova-remote"] == "1"
        let mode: String = (j["mode"] as? String) ?? "fast"
        let withTools: Bool = remote ? false : ((j["tools"] as? Bool) ?? true)
        var rq: Request = req
        var queued: Bool = false
        var knownCid: String? = (j["conversation_id"] as? String).flatMap { convs.get($0) != nil ? $0 : nil }
        if NetState.levelForRouting() == "hors_ligne" && router.localSpec() == nil {
            // La conversation est fixée ici (même règle que le handler principal) pour que le rejeu retrouve le fil.
            let cid: String = knownCid ?? convs.create()
            knownCid = cid
            var o: [String: Any] = j
            o["conversation_id"] = cid
            rq.body = jsonData(o)
            let status: String = resilienceEnqueueChat(text: text, cid: cid, mode: mode, tools: withTools)
            NetState.noteDecision(text: text, status: status)
            queued = status == "garde"
        }
        resilienceChatDelegate(rq, res, after: idx)
        // Coupure EN COURS de tour : le tour s'est fini sans réponse et le réseau n'est plus bon → la demande est gardée.
        if !queued, let cid = knownCid, NetState.current() != "bon" {
            let msgs: [[String: Any]] = (convs.get(cid)?["messages"] as? [[String: Any]]) ?? []
            if let last = msgs.last, (last["role"] as? String) == "assistant",
               let c = last["content"] as? String, c.hasPrefix("(sans réponse — échec du run"), !c.contains("annulé") {
                _ = resilienceEnqueueChat(text: text, cid: cid, mode: mode, tools: withTools)
            }
        }
    }

    /// « garde » (ou doublon déjà gardé), « envoi » (refusé : action d'envoi), « plein ».
    func resilienceEnqueueChat(text: String, cid: String, mode: String, tools: Bool) -> String {
        if ResilienceKit.looksLikeSend(text) {
            ResilienceState.shared.journal.add(["evenement": "refus_file", "motif": "action d'envoi : jamais rejouée seule"])
            return "envoi"
        }
        let r: String = resilienceEnqueue(["type": "chat", "conversation_id": cid, "texte": String(text.prefix(8000)), "mode": mode, "outils": tools,
                                           "cle": ResilienceKit.key(["chat", cid, String(text.prefix(400))])])
        if r != "plein" { bus.publish("net", resilienceNetPayload()) }
        return r == "plein" ? "plein" : "garde"
    }

    /// Hors ligne : les créneaux d'Éclats dus et non lancés sont inscrits (visibles) ; l'ordonnanceur les relance seul au retour.
    func resilienceScanEclats() {
        guard NetState.enabled, NetState.current() == "hors_ligne", settings.get("dots_auto", true) else { return }
        let now: Date = Date()
        let cal: Calendar = Calendar.current
        let day: String = String(ISO8601DateFormatter().string(from: now).prefix(10))   // même clé que DotScheduler.tick
        let mins: Int = cal.component(.hour, from: now) * 60 + cal.component(.minute, from: now)
        let stt: [String: Any] = JSONFile("dots_etat.json").read(default: [String: Any]())
        for d in dots.list() {
            guard let id = d["id"] as? String, (d["paused"] as? Bool) != true else { continue }
            for slot in DotScheduler.slots((d["schedule"] as? String) ?? "", now: now) {
                let p: [Substring] = slot.split(separator: ":")
                guard p.count == 2, let h = Int(p[0]), let m = Int(p[1]) else { continue }
                let t: Int = h * 60 + m
                let key: String = day + "T" + slot
                let last: [String] = ((stt[id] as? [String: Any])?["last"] as? [String]) ?? []
                let expired: [String] = ((stt[id] as? [String: Any])?["expired"] as? [String]) ?? []
                if mins >= t, mins - t <= 180, !last.contains(key), !expired.contains(key) {
                    let r: String = resilienceEnqueue(["type": "eclat", "eclat": id, "nom": (d["name"] as? String) ?? id, "creneau": key,
                                                       "cle": ResilienceKit.key(["eclat", id, key])])
                    if r == "garde" { bus.publish("net", resilienceNetPayload()) }
                }
            }
        }
    }

    /// Éclats rendus au planificateur : le passage suivant (réussi ou non) clôt l'entrée ; au-delà de 4 h, l'entrée expire.
    func resilienceFollowEclats() {
        let items: [[String: Any]] = ResilienceState.shared.queueFile.read(default: [[String: Any]]())
        let iso: ISO8601DateFormatter = ISO8601DateFormatter()
        for it in items where (it["type"] as? String) == "eclat" && (it["statut"] as? String) == "relance" {
            guard let qid = it["id"] as? String, let eid = it["eclat"] as? String else { continue }
            let handed: Date = ((it["rendu"] as? String).flatMap { iso.date(from: $0) }) ?? Date()
            var found: [String: Any]? = nil
            for r in dots.history(eid) {
                guard let ts = r["ts"] as? String, let d = iso.date(from: ts), d >= handed, (r["statut"] as? String) != "en_cours" else { continue }
                found = r; break
            }
            if let r = found {
                let ok: Bool = (r["ok"] as? Bool) == true
                resilienceUpdate(id: qid) { (x: inout [String: Any]) in x["statut"] = ok ? "fait" : "echec"; x["fin"] = nowISO(); x["note"] = ok ? "passage effectué par le planificateur" : "passage du planificateur en échec (voir Éclats)" }
            } else if Date().timeIntervalSince(handed) > 4 * 3600 {
                resilienceUpdate(id: qid) { (x: inout [String: Any]) in x["statut"] = "echec"; x["fin"] = nowISO(); x["note"] = "aucun passage constaté : fenêtre de rattrapage du planificateur dépassée" }
            }
        }
    }

    /// Rejoue la file (ordre d'arrivée). Chat : renvoyé au handler normal en local (mêmes cartes de confirmation) ;
    /// Éclat : rendu au planificateur (qui le lance seul, un à la fois). Retourne le bilan.
    func resilienceReplay(manual: Bool, only: String?) -> [String: Any] {
        let st: ResilienceState = ResilienceState.shared
        st.lock.lock()
        if st.replaying { st.lock.unlock(); return ["ok": false, "motif": "rejeu déjà en cours"] }
        st.replaying = true
        st.lock.unlock()
        defer { st.lock.lock(); st.replaying = false; st.lock.unlock() }
        let items: [[String: Any]] = st.queueFile.read(default: [[String: Any]]())
        let pending: [[String: Any]] = items.filter { ($0["statut"] as? String) == "attente" && (only == nil || ($0["id"] as? String) == only) }
            .sorted { (($0["ts"] as? String) ?? "") < (($1["ts"] as? String) ?? "") }
        var nChat: Int = 0, nEclat: Int = 0, nFail: Int = 0
        for it in pending {
            if NetState.current() == "hors_ligne" { break }
            guard let qid = it["id"] as? String else { continue }
            let type: String = (it["type"] as? String) ?? ""
            if type == "eclat" {
                resilienceUpdate(id: qid) { (x: inout [String: Any]) in x["statut"] = "relance"; x["rendu"] = nowISO(); x["note"] = "rendu au planificateur au retour du réseau" }
                nEclat += 1
                continue
            }
            if type != "chat" { continue }
            let r: (ok: Bool, note: String) = resilienceReplayChat(it)
            let tries: Int = ((it["essais"] as? Int) ?? 0) + 1
            resilienceUpdate(id: qid) { (x: inout [String: Any]) in
                x["essais"] = tries
                x["dernier_essai"] = nowISO()
                x["note"] = r.note
                if r.ok { x["statut"] = "fait"; x["fin"] = nowISO() }
                else if tries >= 3 { x["statut"] = "echec"; x["fin"] = nowISO() }
            }
            if r.ok { nChat += 1 } else { nFail += 1; if NetState.current() != "bon" { break } }
        }
        let total: Int = nChat + nEclat
        st.journal.add(["evenement": "rejeu", "manuel": manual, "chat": nChat, "eclats": nEclat, "echecs": nFail])
        if total > 0 { resilienceNotifyReplay(chat: nChat, eclats: nEclat) }
        bus.publish("net", resilienceNetPayload())
        return ["ok": true, "chat": nChat, "eclats": nEclat, "echecs": nFail]
    }

    func resilienceReplayChat(_ it: [String: Any]) -> (ok: Bool, note: String) {
        guard let cid = it["conversation_id"] as? String, let text = it["texte"] as? String, !text.isEmpty else { return (false, "entrée incomplète") }
        guard convs.get(cid) != nil else { return (false, "conversation introuvable (supprimée ?)") }
        guard server.port > 0, let url: URL = URL(string: "http://127.0.0.1:" + String(server.port) + "/api/chat") else { return (false, "serveur local pas encore prêt") }
        let before: Int = ((convs.get(cid)?["messages"] as? [[String: Any]]) ?? []).count
        var r: URLRequest = URLRequest(url: url)
        r.httpMethod = "POST"
        r.setValue("application/json", forHTTPHeaderField: "Content-Type")
        r.setValue(server.token, forHTTPHeaderField: "x-nova-token")
        r.setValue("1", forHTTPHeaderField: "x-nova-replay")
        let body: [String: Any] = ["text": "↻ Reprise au retour du réseau — " + text, "conversation_id": cid,
                                   "mode": (it["mode"] as? String) ?? "fast", "tools": (it["outils"] as? Bool) ?? true]
        r.httpBody = jsonData(body)
        let res: HTTPResult = HTTPStream.run(r, firstByteTimeout: 30, idleTimeout: 300, totalTimeout: 900) { (_: Data) -> Bool in true }
        if res.status != 200 { return (false, "rejeu refusé : " + (res.error ?? ("HTTP " + String(res.status)))) }
        // Le tour peut finir côté serveur après la coupure du flux local : on lit le fil (≤ 90 s) jusqu'à la réponse FINALE.
        var c: String = ""
        var waited: Int = 0
        while waited <= 90 {
            let msgs: [[String: Any]] = (convs.get(cid)?["messages"] as? [[String: Any]]) ?? []
            if msgs.count > before, let last = msgs.last, (last["role"] as? String) == "assistant", let t = last["content"] as? String, !t.hasPrefix("⏳") { c = t; break }
            Thread.sleep(forTimeInterval: 3); waited += 3
        }
        if c.isEmpty { return (false, "aucune réponse finale enregistrée") }
        if c.hasPrefix("(sans réponse") || c.hasPrefix("(interrompu") { return (false, String(c.prefix(160))) }
        return (true, "traitée au retour du réseau")
    }

    func resilienceNotifyReplay(chat: Int, eclats: Int) {
        var parts: [String] = []
        let chatW: String = chat > 1 ? " conversations" : " conversation"
        let eclW: String = eclats > 1 ? " Éclats rendus au planificateur" : " Éclat rendu au planificateur"
        if chat > 0 { parts.append(String(chat) + chatW) }
        if eclats > 0 { parts.append(String(eclats) + eclW) }
        let n: Int = chat + eclats
        let head: String = n > 1 ? " demandes traitées" : " demande traitée"
        let detail: String = parts.joined(separator: ", ")
        let msg: String = String(n) + head + " au retour du réseau (" + detail + ")."
        bus.publish("net", ["etat": NetState.current(), "libelle": NetState.label(NetState.current()), "rejeu": ["chat": chat, "eclats": eclats], "message": msg, "file": resilienceQueueCounts(), "ts": nowISO()])
        _ = BlackBox.record(["tool": "resilience", "actor": "Nova", "why": "file hors ligne rejouée au retour du réseau", "ok": true, "effect": "lecture", "result": msg])
        #if os(macOS)
        if settings.get("notify", true), !briefs.inQuietHours() {
            _ = Tools.osa("display notification \"" + msg.replacingOccurrences(of: "\"", with: "'") + "\" with title \"Nova — réseau revenu\"", timeout: 5)
        }
        #endif
    }

    // MARK: pré-calcul hors ligne

    func resiliencePrecalc() {
        let now: Date = Date()
        let iso: ISO8601DateFormatter = ISO8601DateFormatter()
        var o: [String: Any] = ["ts": nowISO(), "heure": DailyCal.hmFmt.string(from: now), "jour": PulseKit.dayKey(now)]
        // Pulse du jour (cartes hors coffre — jamais de carte du coffre sur disque).
        let pulse: [String: Any] = PulseState.shared.today.read(default: [String: Any]())
        var brief: [[String: Any]] = []
        if (pulse["day"] as? String) == PulseKit.dayKey(now) {
            for c in ((pulse["cards"] as? [[String: Any]]) ?? []) where (c["vault"] as? Bool) != true {
                brief.append(["titre": c["titre"] ?? "", "cat": c["cat"] ?? "", "lignes": c["lignes"] ?? [String](), "source": c["source"] ?? [String: Any]()])
                if brief.count >= 8 { break }
            }
        }
        o["brief"] = brief
        // Agenda du jour.
        var agenda: [[String: Any]] = []
        for e in dailyEvents(force: false) {
            let ts: Double = (e["ts"] as? Double) ?? 0
            if !Calendar.current.isDateInToday(Date(timeIntervalSince1970: ts)) { continue }
            agenda.append(["heure": e["hhmm"] ?? "", "titre": PulseKit.clean(e["title"], 140), "calendrier": PulseKit.clean(e["cal"], 60), "ts": ts])
            if agenda.count >= 15 { break }
        }
        o["agenda"] = agenda
        // Derniers mails / Teams triés (urgents d'abord) — le tri est celui du Fil direct.
        var mails: [[String: Any]] = []
        let since: Date = now.addingTimeInterval(-26 * 3600)
        for ev in ProactiveFeed.list(limit: 150) {
            let kind: String = (ev["kind"] as? String) ?? ""
            if kind != "mail.new" && kind != "teams.new" { continue }
            guard let ts = ev["ts"] as? String, let d = iso.date(from: ts), d >= since else { continue }
            let box: String = (ev["box"] as? String) ?? ""
            var boite: String = "Outlook"
            if box == "tm" || kind == "teams.new" { boite = "Teams" } else if box == "gm" { boite = "Gmail" } else if box == "wa" { boite = "WhatsApp" } else if box == "zm" { boite = "Zoho" }
            let urgent: Bool = (ev["urgent"] as? Bool) == true
            mails.append(["titre": PulseKit.clean(ev["title"], 140), "texte": PulseKit.clean(ev["text"], 220), "de": PulseKit.clean(ev["who"], 60),
                          "boite": boite, "urgent": urgent, "ts": ts])
        }
        mails.sort { (a: [String: Any], b: [String: Any]) -> Bool in
            let ua: Bool = (a["urgent"] as? Bool) == true, ub: Bool = (b["urgent"] as? Bool) == true
            if ua != ub { return ua }
            return ((a["ts"] as? String) ?? "") > ((b["ts"] as? String) ?? "")
        }
        o["mails"] = Array(mails.prefix(15))
        // Engagements ouverts.
        let co: [String: Any] = DailyState.shared.commitFile.read(default: [String: Any]())
        var eng: [[String: Any]] = []
        for c in dailySortCommitments((co["items"] as? [[String: Any]]) ?? []) {
            if ((c["status"] as? String) ?? "ouvert") != "ouvert" { continue }
            let ech: String = (c["echeance"] as? String) ?? ""
            let late: Bool = DailyCal.deadline(ech).map { $0 < now } ?? false
            eng.append(["quoi": PulseKit.clean(c["quoi"], 160), "qui": PulseKit.clean(c["qui"], 60), "echeance": ech, "sens": (c["dir"] as? String) ?? "moi", "en_retard": late])
            if eng.count >= 12 { break }
        }
        o["engagements"] = eng
        ResilienceState.shared.cacheFile.write(o)
        ResilienceState.shared.journal.add(["evenement": "precalcul", "brief": brief.count, "agenda": agenda.count, "mails": min(15, mails.count), "engagements": eng.count])
    }

    func resiliencePrecalcSummary(_ c: [String: Any]) -> [String: Any] {
        let ts: String = (c["ts"] as? String) ?? ""
        if ts.isEmpty { return ["fait": false, "note": "aucun pré-calcul encore (il se fait quand le réseau est bon, toutes les 30 min)"] }
        let n: (String) -> Int = { (k: String) -> Int in ((c[k] as? [Any]) ?? []).count }
        let heure: String = (c["heure"] as? String) ?? ResilienceKit.hm(ts)
        let libelle: String = "hors ligne — état de " + heure
        return ["fait": true, "ts": ts, "heure": heure, "jour": c["jour"] ?? "", "libelle": libelle,
                "brief": n("brief"), "agenda": n("agenda"), "mails": n("mails"), "engagements": n("engagements")]
    }

    // MARK: compagnon de charge

    /// Signaux RÉELS du jour, chacun avec sa source et son seuil. Un signal non mesurable est dit « non mesuré », jamais estimé.
    func chargeSignals() -> [[String: Any]] {
        let now: Date = Date()
        let iso: ISO8601DateFormatter = ISO8601DateFormatter()
        var out: [[String: Any]] = []
        // 1) Réunions du jour (Calendrier, cache de l'agenda — lecture seule).
        let evs: [[String: Any]] = dailyEvents(force: false).filter { Calendar.current.isDateInToday(Date(timeIntervalSince1970: ($0["ts"] as? Double) ?? 0)) && (($0["hhmm"] as? String) ?? "") != "00:00" }
        let st0: DailyState = DailyState.shared
        st0.lock.lock(); let calNote: String = st0.calNote; st0.lock.unlock()
        let nowTs0: Double = now.timeIntervalSince1970
        let restantes: Int = evs.filter { (($0["ts"] as? Double) ?? 0) > nowTs0 }.count
        let calOK: Bool = calNote.isEmpty
        let reuVal: Any = calOK ? (evs.count as Any) : (NSNull() as Any)
        let reuDetail: String = calOK ? (String(restantes) + " encore à venir") : ("agenda non lu : " + String(calNote.prefix(80)))
        out.append(["id": "reunions", "label": "Réunions aujourd'hui", "valeur": reuVal, "seuil": 5, "unite": "",
                    "mesure": calOK, "depasse": calOK && evs.count >= 5, "source": "Calendrier (lecture seule)", "detail": reuDetail])
        // 2) Arrivées urgentes et volume (Fil direct, tri existant).
        var urgents: Int = 0, arrivees: Int = 0
        let since12: Date = now.addingTimeInterval(-12 * 3600)
        for ev in ProactiveFeed.list(limit: 200) {
            let kind: String = (ev["kind"] as? String) ?? ""
            if kind != "mail.new" && kind != "teams.new" { continue }
            guard let ts = ev["ts"] as? String, let d = iso.date(from: ts) else { continue }
            if Calendar.current.isDateInToday(d) { arrivees += 1 }
            if d >= since12 && (ev["urgent"] as? Bool) == true { urgents += 1 }
        }
        let urgDetail: String = String(arrivees) + " arrivée(s) mail/Teams aujourd'hui"
        out.append(["id": "urgents", "label": "Messages urgents (12 h)", "valeur": urgents, "seuil": 3, "unite": "", "mesure": true, "depasse": urgents >= 3,
                    "source": "Fil direct (tri URGENT existant)", "detail": urgDetail])
        out.append(["id": "mails", "label": "Arrivées mail/Teams aujourd'hui", "valeur": arrivees, "seuil": 20, "unite": "", "mesure": true, "depasse": arrivees >= 20,
                    "source": "Fil direct", "detail": ""])
        // 3) Engagements en retard (ceux qu'Ahadi doit).
        let co: [String: Any] = DailyState.shared.commitFile.read(default: [String: Any]())
        var retard: Int = 0
        for c in ((co["items"] as? [[String: Any]]) ?? []) {
            if ((c["status"] as? String) ?? "ouvert") != "ouvert" || ((c["dir"] as? String) ?? "moi") != "moi" { continue }
            if let dl = DailyCal.deadline((c["echeance"] as? String) ?? ""), dl < now { retard += 1 }
        }
        out.append(["id": "retard", "label": "Engagements en retard", "valeur": retard, "seuil": 2, "unite": "", "mesure": true, "depasse": retard >= 2,
                    "source": "Engagements suivis", "detail": ""])
        // 4) Activité tardive (après 20 h) mesurée par Nova via l'inactivité HID.
        let ch: [String: Any] = ResilienceState.shared.chargeFile.read(default: [String: Any]())
        let tard: [String: Int] = (ch["tard"] as? [String: Int]) ?? [:]
        let today: String = PulseKit.dayKey(now)
        let yesterday: String = PulseKit.dayKey(now.addingTimeInterval(-86400))
        let tardMax: Int = max(tard[today] ?? 0, tard[yesterday] ?? 0)
        let hidOK: Bool = AmeBody.idle != nil
        let tardVal: Any = hidOK ? (tardMax as Any) : (NSNull() as Any)
        let tardY: String = String(tard[yesterday] ?? 0)
        let tardT: String = String(tard[today] ?? 0)
        let tardDetail: String = hidOK ? ("hier : " + tardY + " min · ce soir : " + tardT + " min") : "inactivité HID non mesurable"
        out.append(["id": "tardif", "label": "Activité après 20 h (hier ou ce soir)", "valeur": tardVal, "seuil": 60, "unite": "min",
                    "mesure": hidOK, "depasse": hidOK && tardMax >= 60, "source": "Inactivité HID (Gardien du corps), mesurée seulement quand Nova tourne", "detail": tardDetail])
        // 5) Séquence sans pause (Gardien du corps, Ame.swift).
        let seuilPause: Int = settings.get("corps_pause_min", 90)
        let streak: Int = AmeBody.streak
        let pauseVal: Any = hidOK ? (streak as Any) : (NSNull() as Any)
        out.append(["id": "pause", "label": "Séquence devant l'écran sans pause de 5 min", "valeur": pauseVal, "seuil": seuilPause, "unite": "min",
                    "mesure": hidOK, "depasse": hidOK && streak >= seuilPause, "source": "Gardien du corps (inactivité HID)", "detail": ""])
        return out
    }

    func chargeLevel(_ sig: [[String: Any]]) -> (code: String, label: String, n: Int) {
        let n: Int = sig.filter { ($0["depasse"] as? Bool) == true }.count
        if n >= 3 { return ("dense", "journée dense", n) }
        if n >= 1 { return ("soutenue", "journée soutenue", n) }
        return ("legere", "rythme habituel", n)
    }

    func chargeDayState() -> [String: Any] {
        var ch: [String: Any] = ResilienceState.shared.chargeFile.read(default: [String: Any]())
        if (ch["jour"] as? String) != PulseKit.dayKey() {
            ch["jour"] = PulseKit.dayKey(); ch["emises"] = [[String: Any]](); ch["retenues"] = [[String: Any]]()
        }
        return ch
    }

    func chargeView() -> [String: Any] {
        let sig: [[String: Any]] = chargeSignals()
        let lv: (code: String, label: String, n: Int) = chargeLevel(sig)
        let ch: [String: Any] = chargeDayState()
        let emises: [[String: Any]] = (ch["emises"] as? [[String: Any]]) ?? []
        let maxJ: Int = max(0, min(2, settings.get("charge_max_jour", 2)))
        let plaf: Int = SilenceGate.cap(settings)
        let gf1: String = "Au plus " + String(maxJ) + " proposition(s) par jour, espacées d'au moins 2 h."
        let gf2: String = "Chaque proposition compte dans le plafond d'interruptions du jour (" + String(plaf) + ")."
        let plafond: [String: Any] = ["max_jour": maxJ, "emises": emises.count, "interruptions_aujourdhui": AmeSilence.count(), "plafond_interruptions": plaf]
        let gardeFous: [String] = [gf1, gf2, "Rien en heures calmes ni en mode concentration.",
                                   "Aucun diagnostic : des signaux de rythme de travail, jamais un état de santé.",
                                   "Une proposition ne change rien d'elle-même : agenda, mails et engagements restent tels quels."]
        return ["actif": settings.get("charge_on", true), "niveau": lv.code, "niveau_libelle": lv.label, "signaux_au_dessus": lv.n,
                "signaux": sig, "suggestions": emises, "retenues": (ch["retenues"] as? [[String: Any]]) ?? [[String: Any]](),
                "plafond": plafond, "heures_calmes": briefs.inQuietHours(), "garde_fous": gardeFous,
                "reseau": NetState.current(), "ts": nowISO()]
    }

    func chargeTick() {
        let now: Date = Date()
        let hour: Int = Calendar.current.component(.hour, from: now)
        // Activité tardive : +5 min par battement actif (HID < 5 min) après 20 h (ou avant 5 h, comptée pour la veille).
        if let idle = AmeBody.idle, idle < 300, hour >= 20 || hour < 5 {
            let st: ResilienceState = ResilienceState.shared
            st.lock.lock()
            var ch: [String: Any] = st.chargeFile.read(default: [String: Any]())
            var tard: [String: Int] = (ch["tard"] as? [String: Int]) ?? [:]
            let k: String = PulseKit.dayKey(hour < 5 ? now.addingTimeInterval(-86400) : now)
            tard[k] = (tard[k] ?? 0) + 5
            let keep: [String] = Array(tard.keys.sorted().suffix(7))
            var t2: [String: Int] = [:]
            for kk in keep { t2[kk] = tard[kk] ?? 0 }
            ch["tard"] = t2
            st.chargeFile.write(ch)
            st.lock.unlock()
        }
        guard settings.get("charge_on", true), !briefs.inQuietHours() else { return }
        let maxJour: Int = max(0, min(2, settings.get("charge_max_jour", 2)))
        let stt: ResilienceState = ResilienceState.shared
        stt.lock.lock()
        let ch: [String: Any] = chargeDayState()
        stt.lock.unlock()
        let emises: [[String: Any]] = (ch["emises"] as? [[String: Any]]) ?? []
        if emises.count >= maxJour { return }
        let iso: ISO8601DateFormatter = ISO8601DateFormatter()
        if let lastTs = emises.last?["ts"] as? String, let d = iso.date(from: lastTs), now.timeIntervalSince(d) < 7200 { return }
        let done: Set<String> = Set(emises.compactMap { $0["type"] as? String })
        let retenuesTypes: Set<String> = Set(((ch["retenues"] as? [[String: Any]]) ?? []).compactMap { $0["type"] as? String })
        let sig: [[String: Any]] = chargeSignals()
        func v(_ id: String) -> Int {
            let row: [String: Any]? = sig.first(where: { ($0["id"] as? String) == id })
            return (row?["valeur"] as? Int) ?? 0
        }
        func over(_ id: String) -> Bool {
            let row: [String: Any]? = sig.first(where: { ($0["id"] as? String) == id })
            return (row?["depasse"] as? Bool) == true
        }
        let lv: (code: String, label: String, n: Int) = chargeLevel(sig)
        let reunions: Int = v("reunions"), urgents: Int = v("urgents"), arrivees: Int = v("mails")
        var pick: (type: String, titre: String, lignes: [String], module: String, label: String)? = nil
        // Ordre : débrief du soir > pause > décaler > regrouper les mails. Une seule fois par type et par jour.
        if pick == nil, hour >= 18, !done.contains("debrief"), !retenuesTypes.contains("debrief"), lv.n >= 3 || reunions >= 5 {
            let a1: String = "Aujourd'hui : " + String(reunions) + " réunion(s), " + String(urgents) + " message(s) urgent(s) sur 12 h"
            let a2: String = a1 + ", " + String(v("retard")) + " engagement(s) en retard."
            let l: [String] = [a2, "Proposition : trois lignes avec Nova — ce qui est fait, ce qui attend demain, ce qui peut lâcher."]
            pick = (type: "debrief", titre: "Débrief de fin de journée, 5 min ?", lignes: l, module: "agent", label: "Débriefer avec Nova")
        }
        if pick == nil, !done.contains("pause"), !retenuesTypes.contains("pause"), over("pause"), reunions >= 3 || urgents >= 3,
           now.timeIntervalSince(AmeBody.lastNudge) > 2700 {
            let nowTs: Double = now.timeIntervalSince1970
            let next: [String: Any]? = dailyEvents(force: false).first(where: { (e: [String: Any]) -> Bool in
                let ts: Double = (e["ts"] as? Double) ?? 0
                return ts > nowTs && Calendar.current.isDateInToday(Date(timeIntervalSince1970: ts))
            })
            let nextTs: Double = (next?["ts"] as? Double) ?? 0
            let soon: Bool = nextTs > 0 && nextTs - nowTs < 600
            if !soon {
                let nextHm: String = (next?["hhmm"] as? String) ?? ""
                let when: String = next == nil ? "maintenant" : ("avant ta réunion de " + nextHm)
                let b1: String = "Environ " + String(AmeBody.streak) + " min devant l'écran sans pause de 5 min détectée"
                let b2: String = b1 + ", " + String(reunions) + " réunion(s) aujourd'hui."
                let l: [String] = [b2, "Proposition : 10 min loin de l'écran " + when + "."]
                pick = (type: "pause", titre: "Protéger 10 min de pause", lignes: l, module: "temps", label: "Voir l'agenda")
            }
        }
        if pick == nil, !done.contains("decaler"), !retenuesTypes.contains("decaler"), reunions >= 5 || lv.n >= 3 {
            let co: [String: Any] = DailyState.shared.commitFile.read(default: [String: Any]())
            var cand: (quoi: String, ech: String, jours: Int)? = nil
            for c in dailySortCommitments((co["items"] as? [[String: Any]]) ?? []) {
                if ((c["status"] as? String) ?? "ouvert") != "ouvert" || ((c["dir"] as? String) ?? "moi") != "moi" { continue }
                let ech: String = (c["echeance"] as? String) ?? ""
                guard let dl = DailyCal.deadline(ech) else { continue }
                let jours: Int = Int(dl.timeIntervalSince(now) / 86400)
                if jours >= 2 && jours <= 7 { let q: String = PulseKit.clean(c["quoi"], 120); if !q.isEmpty { cand = (q, ech, jours); break } }
            }
            if let c = cand {
                let c1: String = "Journée chargée : " + String(reunions) + " réunion(s), " + String(urgents) + " urgent(s)."
                let c2a: String = "« " + c.quoi + " » est dû le " + c.ech
                let c2: String = c2a + " (dans " + String(c.jours) + " j) : le sortir d'aujourd'hui ne crée pas de retard."
                pick = (type: "decaler", titre: "Décaler une tâche non urgente ?", lignes: [c1, c2], module: "engagements", label: "Voir l'engagement")
            }
        }
        if pick == nil, !done.contains("mails"), !retenuesTypes.contains("mails"), urgents >= 3 || arrivees >= 20, hour >= 9, hour < 18 {
            let m1: String = String(arrivees) + " arrivée(s) mail/Teams aujourd'hui, dont " + String(urgents) + " urgente(s) sur 12 h."
            let l: [String] = [m1, "Proposition : traiter les urgentes d'abord, puis un seul créneau groupé pour le reste plutôt qu'au fil de l'eau."]
            pick = (type: "mails", titre: "Regrouper les mails", lignes: l, module: "messages", label: "Ouvrir les messages")
        }
        guard let p = pick else { return }
        let plafond: Int = SilenceGate.cap(settings)
        let allowed: Bool = AmeSilence.allow(plafond: plafond)
        let entry: [String: Any] = ["type": p.type, "titre": p.titre, "lignes": p.lignes, "ts": nowISO(),
                                    "signaux": sig.filter { ($0["depasse"] as? Bool) == true }.compactMap { $0["label"] as? String }]
        stt.lock.lock()
        var ch2: [String: Any] = chargeDayState()
        if allowed {
            var e: [[String: Any]] = (ch2["emises"] as? [[String: Any]]) ?? []
            e.append(entry); ch2["emises"] = e
        } else {
            var r: [[String: Any]] = (ch2["retenues"] as? [[String: Any]]) ?? []
            let motif: String = "plafond d'interruptions du jour atteint (" + String(plafond) + ")"
        var x: [String: Any] = entry; x["motif"] = motif
            r.append(x); ch2["retenues"] = r
        }
        stt.chargeFile.write(ch2)
        stt.lock.unlock()
        stt.journal.add(["evenement": "charge", "type": p.type, "emise": allowed])
        if allowed {
            pulseChargeCard(titre: p.titre, lignes: p.lignes, ref: PulseKit.dayKey() + ":" + p.type, module: p.module, label: p.label)
        }
    }
}
