import Foundation

/// AMPLITUDE — émetteur d'analytics événementiel unique de Nova2 (plan Growth, workspace
/// [workspace]). Lot CRÉDITS du 23/10/2026 — fichier STAGÉ pour le prochain build
/// groupé : aucun build ni aucune relance dans ce lot.
///
/// Contrat (contrainte de dégradation d'Ahadi, 23/10 12:54 — l'analytics est le PREMIER
/// fusible, jamais un blocage) :
/// - AUCUNE donnée personnelle, AUCUN contenu de message dans les payloads : noms
///   d'événements fixes + propriétés sobres (compteurs, durées, statuts, booléens).
/// - Émission asynchrone bornée : `track` ne fait qu'enfiler (file plafonnée) et rend la
///   main immédiatement ; l'envoi HTTP vit sur une file série dédiée, timeout court
///   (3 s requête / 5 s ressource), jamais d'attente sur le chemin de l'émetteur.
/// - Interrupteur : réglage `amplitude_enabled` (Settings, défaut true).
/// - Disjoncteur : `breakerThreshold` échecs consécutifs (ou clé invalide / quota :
///   HTTP 400/401/403/429 comptés, 401/403 = déclenchement immédiat) → désactivation
///   automatique + événement au journal (BlackBox), file purgée, silence complet côté
///   app. Réactivation MANUELLE : remettre `amplitude_enabled` à true et relancer
///   l'app (ou appeler `Amplitude.rearm()` depuis un futur point d'UI).
/// - Clé API : JAMAIS dans le code. Résolution, dans l'ordre (patron Keys.swift /
///   SentryBootstrap / Algolia) :
///   1. Trousseau « nova-amplitude-api » (ou variable AMPLITUDE_API_KEY) via
///      `KnownKeys.amplitudeAPI` et `KeychainStore` ;
///   2. fichier `amplitude_config.json` du magasin (~/Library/Application Support/Nova/),
///      clé « api_key » — seul emplacement inscriptible sans interface.
///   Aucune clé configurée → émetteur dormant : comportement de l'app strictement inchangé.
/// - Endpoint : POST https://api2.amplitude.com/2/httpapi, corps
///   { "api_key": …, "events": [ … ] } — le harnais de preuve VM construit les payloads
///   EXACTEMENT dans cette structure.
public enum Amplitude {
    // MARK: Constantes nommées (critères d'acceptation)
    static let endpoint = "https://api2.amplitude.com/2/httpapi"
    static let breakerThreshold = 5          // échecs consécutifs avant désactivation automatique
    static let queueCap = 200                // au-delà : les événements les plus anciens sont jetés
    static let flushAt = 10                  // taille de lot déclenchant un envoi immédiat
    static let requestTimeout: TimeInterval = 3
    static let resourceTimeout: TimeInterval = 5
    static let appVersion = "2.0.0"

    // MARK: État (protégé par `lock`)
    private static let lock = NSLock()
    private static var started = false
    private static var dormant = false       // pas de clé ou interrupteur coupé au démarrage
    private static var breakerTripped = false
    private static var consecutiveFailures = 0
    private static var apiKey: String? = nil
    private static var queue: [[String: Any]] = []
    private static var flushScheduled = false
    private static let sendQueue = DispatchQueue(label: "nova.amplitude.send", qos: .utility)

    /// Identifiant d'appareil ANONYME et stable (UUID local, aucune donnée personnelle).
    /// Généré une fois, persisté dans amplitude_state.json du magasin.
    private static var deviceId: String {
        let f = JSONFile("amplitude_state.json")
        let cur: [String: Any] = f.read(default: [String: Any]())
        if let d = cur["device_id"] as? String, !d.isEmpty { return d }
        let d = UUID().uuidString.lowercased()
        var next = cur; next["device_id"] = d; f.write(next)
        return d
    }

    // MARK: Démarrage (appelé par main.swift juste après SentryBootstrap.start())

    public static func start() {
        lock.lock()
        guard !started else { lock.unlock(); return }
        started = true
        lock.unlock()
        guard Settings().get("amplitude_enabled", true) else { dormant = true; return }
        guard let key = resolveKey(), !key.isEmpty else { dormant = true; return }   // pas de clé → silence total
        apiKey = key
        track("session_started", ["cold_start": true])
    }

    /// Réactivation manuelle après déclenchement du disjoncteur (le réglage doit être à true).
    public static func rearm() {
        lock.lock()
        breakerTripped = false
        consecutiveFailures = 0
        lock.unlock()
        _ = BlackBox.record(["tool": "amplitude", "actor": "Nova", "why": "AMPLITUDE : disjoncteur réarmé manuellement", "ok": true, "effect": "config", "result": "rearm"])
    }

    private static func resolveKey() -> String? {
        if let v = KeychainStore().value(KnownKeys.amplitudeAPI), !v.isEmpty { return v }
        let f: [String: Any] = JSONFile("amplitude_config.json").read(default: [String: Any]())
        let v = (f["api_key"] as? String) ?? ""
        return v.isEmpty ? nil : v
    }

    // MARK: Émission — chemin émetteur : enfiler et rendre la main (jamais de réseau ici)

    public static func track(_ eventType: String, _ props: [String: Any] = [:]) {
        Credits.localEvent(eventType)   // V5-I : repli toujours actif — compteur local par nom d'événement (jamais de contenu)
        if Credits.isOpen("amplitude") { return }   // V5-I : disjoncteur Crédits (clé refusée / quota) — compteurs locaux seulement
        lock.lock()
        guard started, !dormant, !breakerTripped, apiKey != nil else { lock.unlock(); return }
        guard Settings().get("amplitude_enabled", true) else { lock.unlock(); return }
        var clean: [String: Any] = [:]
        for (k, v) in props {
            switch v {
            case let s as String: clean[k] = String(s.prefix(64))   // sobres et bornées
            case is Int, is Double, is Bool: clean[k] = v
            default: break                                          // tout autre type est jeté
            }
        }
        let ev: [String: Any] = [
            "event_type": eventType,
            "device_id": deviceId,
            "time": Int(Date().timeIntervalSince1970 * 1000),
            "event_properties": clean,
            "app_version": appVersion,
            "platform": "macOS",
            "insert_id": UUID().uuidString.lowercased(),
        ]
        queue.append(ev)
        if queue.count > queueCap { queue.removeFirst(queue.count - queueCap) }
        let urgent = queue.count >= flushAt || eventType == "session_started"
        let needSchedule = !flushScheduled
        if needSchedule { flushScheduled = true }
        lock.unlock()
        if needSchedule { scheduleFlush(after: urgent ? 0.2 : 5) }   // lot urgent ou temporisé (≤ 5 s)
    }

    private static func scheduleFlush(after delay: TimeInterval) {
        sendQueue.asyncAfter(deadline: .now() + delay) { flushNow() }
    }

    // MARK: Envoi (file série dédiée — jamais sur le chemin de l'émetteur)

    private static func flushNow() {
        lock.lock()
        flushScheduled = false
        guard !breakerTripped, let key = apiKey, !queue.isEmpty else { lock.unlock(); return }
        let batch = queue
        queue.removeAll()
        lock.unlock()

        let body: [String: Any] = ["api_key": key, "events": batch]
        guard let url = URL(string: endpoint), let data = try? JSONSerialization.data(withJSONObject: body) else {
            registerFailure(status: nil)
            return
        }
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = data
        req.timeoutInterval = requestTimeout
        let cfg = URLSessionConfiguration.ephemeral
        cfg.timeoutIntervalForRequest = requestTimeout
        cfg.timeoutIntervalForResource = resourceTimeout
        let session = URLSession(configuration: cfg)
        let task = session.dataTask(with: req) { _, resp, err in
            session.finishTasksAndInvalidate()
            if err != nil { registerFailure(status: nil); return }
            let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
            if code == 200 {
                lock.lock(); consecutiveFailures = 0; lock.unlock()
                Credits.count("amplitude", n: batch.count, units: Double(batch.count), unit: "événements")   // V5-I : usage mesuré (lot accepté)
            } else {
                registerFailure(status: code)
            }
        }
        task.resume()
    }

    /// Échec d'envoi : compteur + disjoncteur. Clé invalide / quota (401/403) = immédiat ;
    /// 400/429 et erreurs réseau comptent vers `breakerThreshold`. Aucune exception ne
    /// remonte, rien n'est affiché : silence complet côté app, une ligne au journal.
    private static func registerFailure(status: Int?) {
        if let s = status { Credits.providerFailed("amplitude", status: s, detail: "") }   // V5-I : 401/402/403/429 → disjoncteur Crédits + notification une fois
        lock.lock()
        consecutiveFailures += 1
        let immediate = (status == 401 || status == 403)
        let trip = immediate || consecutiveFailures >= breakerThreshold
        if trip && !breakerTripped {
            breakerTripped = true
            queue.removeAll()
        }
        let failures = consecutiveFailures
        lock.unlock()
        if trip {
            _ = BlackBox.record(["tool": "amplitude", "actor": "Nova", "why": "AMPLITUDE : disjoncteur déclenché — émission désactivée (échecs consécutifs : \(failures), statut HTTP : \(status.map(String.init) ?? "réseau")) ; réactivation manuelle via le réglage amplitude_enabled + relance", "ok": false, "effect": "config", "result": "breaker_tripped"])
        }
    }
}
