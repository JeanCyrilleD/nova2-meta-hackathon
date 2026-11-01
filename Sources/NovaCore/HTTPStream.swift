import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

public enum ErrKind: String {
    case auth, credit, rate, timeout, network, server, model, cut, canceled, other
    /// Erreur durable (clé/crédit/modèle) → disjoncteur long ; sinon court.
    public var durable: Bool { self == .auth || self == .credit || self == .model }
}

public struct HTTPResult {
    public var status: Int = 0
    public var error: String? = nil
    public var kind: ErrKind? = nil
    public var body: Data = Data()   // corps complet seulement pour les erreurs / réponses non-stream
}

public func classify(status: Int, body: String) -> ErrKind {
    switch status {
    case 401, 403: return .auth
    case 402: return .credit
    case 429:
        // 29/10 (banc Argon) : « You exceeded your current quota » ([tiers]) / « insufficient_quota » ([tiers]) = plus de crédit,
        // pas une limite de débit passagère → disjoncteur long au lieu de 45 s.
        let b429 = body.lowercased()
        if b429.contains("exceeded your current quota") || b429.contains("insufficient_quota") { return .credit }
        return .rate
    case 404: return .model
    case 400:
        let b = body.lowercased()
        if b.contains("credit balance") { return .credit }   // AUDIT-BRAIN-A : [tiers] « credit balance is too low » arrive en 400 → disjoncteur long (30 min), plus un nouvel essai toutes les 30 s
        return (b.contains("model") && (b.contains("not") || b.contains("invalid") || b.contains("unknown"))) ? .model : .other
    case 500...599: return .server
    default: return .other
    }
}

/// Client HTTP en flux, bloquant, portable Darwin/Linux (pas de URLSession.bytes qui n'existe pas sous Linux).
/// - firstByteTimeout : délai maximal avant le premier octet (c'est lui qui déclenche la bascule de cerveau).
/// - idleTimeout : silence maximal une fois le flux commencé.
public final class HTTPStream: NSObject, URLSessionDataDelegate {
    let sem = DispatchSemaphore(value: 0)
    var onChunk: ((Data) -> Bool)!
    var result = HTTPResult()
    var errBody = Data()
    var task: URLSessionDataTask?
    var session: URLSession?
    var lastActivity = Date()
    var gotFirst = false
    var stopped = false
    let lock = NSLock()

    public static func run(_ req: URLRequest, firstByteTimeout: TimeInterval = 10, idleTimeout: TimeInterval = 30,
                           totalTimeout: TimeInterval = 300, cancel: (() -> Bool)? = nil,
                           onChunk: @escaping (Data) -> Bool) -> HTTPResult {
        // 01/11 (meta_only) : barrière réseau — un appel de modèle non Meta est bloqué AVANT l'envoi et journalisé
        // (MetaOnly.swift). Réglage faux (défaut) : aucun effet.
        if let why = MetaOnly.gate(req, source: "http") {
            var blocked = HTTPResult(); blocked.error = why; blocked.kind = .other
            return blocked
        }
        let h = HTTPStream()
        h.onChunk = onChunk
        // 01/11 (voix-test) : RÉUTILISATION DE CONNEXION pour les hôtes de modèle Meta (api.meta.ai). Avant : une URLSession
        // éphémère par requête = poignée de main TCP + TLS à CHAQUE dictée et à chaque tour Spark (la dictée puis la réponse
        // ouvraient deux connexions vers le même hôte). Ici : une session partagée (HTTPPool), la connexion HTTP/2 reste chaude.
        // Délais, annulation et barrière meta_only identiques. Interrupteur : HTTPStream.poolEnabled (tests) / hôtes : pooledHosts.
        if HTTPStream.usesPool(req.url) {
            return HTTPPool.shared.run(req, h: h, firstByteTimeout: firstByteTimeout, idleTimeout: idleTimeout, totalTimeout: totalTimeout, cancel: cancel)
        }
        let cfg = URLSessionConfiguration.ephemeral
        cfg.timeoutIntervalForRequest = max(firstByteTimeout, idleTimeout) + 5
        cfg.timeoutIntervalForResource = totalTimeout
        #if os(macOS)
        cfg.waitsForConnectivity = false
        #endif
        let s = URLSession(configuration: cfg, delegate: h, delegateQueue: nil)
        h.session = s
        let t = s.dataTask(with: req)
        h.lock.lock(); h.task = t; h.lastActivity = Date(); h.lock.unlock()
        let started = Date()
        t.resume()
        // surveillance : délais + annulation
        h.watch(started: started, firstByteTimeout: firstByteTimeout, idleTimeout: idleTimeout, totalTimeout: totalTimeout, cancel: cancel)
        s.invalidateAndCancel()
        return h.finalResult()
    }

    /// Hôtes servis par la session partagée (connexion gardée chaude). Modèles Meta seulement : dictée et chat Spark.
    final class PoolConfig: @unchecked Sendable { let lock = NSLock(); var hosts: Set<String> = ["api.meta.ai"]; var enabled: Bool = true }
    static let poolConfig = PoolConfig()
    public static var pooledHosts: Set<String> {
        get { poolConfig.lock.lock(); defer { poolConfig.lock.unlock() }; return poolConfig.hosts }
        set { poolConfig.lock.lock(); poolConfig.hosts = newValue; poolConfig.lock.unlock() }
    }
    public static var poolEnabled: Bool {
        get { poolConfig.lock.lock(); defer { poolConfig.lock.unlock() }; return poolConfig.enabled }
        set { poolConfig.lock.lock(); poolConfig.enabled = newValue; poolConfig.lock.unlock() }
    }
    public static func usesPool(_ url: URL?) -> Bool {
        guard poolEnabled, let u = url, (u.scheme ?? "").lowercased().hasPrefix("http"), let h = u.host?.lowercased() else { return false }
        return pooledHosts.contains(h)
    }

    /// Boucle de surveillance commune (délais + annulation) ; rend quand la tâche est finie ou arrêtée.
    /// 01/11 (voix-test) : état partagé avec les rappels URLSession lu SOUS VERROU (avant : lu sans verrou — course de données).
    func watch(started: Date, firstByteTimeout: TimeInterval, idleTimeout: TimeInterval, totalTimeout: TimeInterval, cancel: (() -> Bool)?) {
        while sem.wait(timeout: .now() + 0.05) == .timedOut {
            lock.lock(); let last = lastActivity; let first = gotFirst; lock.unlock()
            let idle = Date().timeIntervalSince(last)
            if cancel?() == true { fail(.canceled, "annulé"); break }
            if !first && idle > firstByteTimeout { fail(.timeout, "aucune réponse après \(Int(firstByteTimeout)) s"); break }
            if first && idle > idleTimeout { fail(.timeout, "flux muet depuis \(Int(idleTimeout)) s"); break }
            if Date().timeIntervalSince(started) > totalTimeout { fail(.timeout, "durée maximale dépassée"); break }
        }
    }

    func finalResult() -> HTTPResult {
        lock.lock(); var r = result; let eb = errBody; lock.unlock()
        if r.status >= 400 && r.error == nil {
            let b = String(data: eb, encoding: .utf8) ?? ""
            r.kind = classify(status: r.status, body: b)
            r.error = "HTTP \(r.status) \(shortError(extractMessage(b), 200))"
            r.body = eb
        }
        return r
    }

    func fail(_ k: ErrKind, _ m: String) {
        lock.lock()
        if result.error == nil { result.error = m; result.kind = k }
        stopped = true
        let t = task
        lock.unlock()
        t?.cancel()
    }

    public func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse,
                           completionHandler: @escaping (URLSession.ResponseDisposition) -> Void) {
        lock.lock()
        if let r = response as? HTTPURLResponse { result.status = r.statusCode }
        lastActivity = Date(); gotFirst = true
        lock.unlock()
        completionHandler(.allow)
    }
    public func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        lock.lock()
        lastActivity = Date(); gotFirst = true
        let isErr: Bool = result.status >= 400
        if isErr { errBody.append(data) }
        lock.unlock()
        if isErr { return }
        if !onChunk(data) { fail(.canceled, "annulé"); }
    }
    public func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        lock.lock()
        if let e = error as NSError?, result.error == nil, !stopped {
            let k: ErrKind = e.code == NSURLErrorTimedOut ? .timeout : .network
            result.error = e.localizedDescription; result.kind = k
        }
        lock.unlock()
        sem.signal()
    }
}

/// 01/11 (voix-test) : session URLSession PARTAGÉE pour les hôtes de HTTPStream.pooledHosts. Chaque tâche garde son propre
/// HTTPStream (délais, tampon, annulation) ; le délégué unique aiguille les rappels par identifiant de tâche.
/// À la fin d'une requête, seule la TÂCHE est annulée (jamais la session) : la connexion reste ouverte pour la suivante.
final class HTTPPool: NSObject, URLSessionDataDelegate {
    static let shared = HTTPPool()
    private let lock = NSLock()
    private var handlers: [Int: HTTPStream] = [:]
    private var sessionStore: URLSession? = nil
    /// Requêtes servies et connexions réutilisées (diagnostic : voix_test.json).
    private var served: Int = 0
    func servedCount() -> Int { lock.lock(); defer { lock.unlock() }; return served }
    func pendingCount() -> Int { lock.lock(); defer { lock.unlock() }; return handlers.count }

    var session: URLSession {
        lock.lock(); defer { lock.unlock() }
        if let s = sessionStore { return s }
        let cfg = URLSessionConfiguration.ephemeral
        cfg.timeoutIntervalForRequest = 600
        cfg.timeoutIntervalForResource = 1800
        cfg.httpMaximumConnectionsPerHost = 6
        #if os(macOS)
        cfg.waitsForConnectivity = false
        #endif
        let s = URLSession(configuration: cfg, delegate: self, delegateQueue: nil)
        sessionStore = s
        return s
    }

    func run(_ reqIn: URLRequest, h: HTTPStream, firstByteTimeout: TimeInterval, idleTimeout: TimeInterval, totalTimeout: TimeInterval, cancel: (() -> Bool)?) -> HTTPResult {
        var req = reqIn
        req.timeoutInterval = max(firstByteTimeout, idleTimeout) + 5
        let s = session
        let t = s.dataTask(with: req)
        h.lock.lock(); h.task = t; h.lastActivity = Date(); h.lock.unlock()
        lock.lock(); handlers[t.taskIdentifier] = h; served += 1; lock.unlock()
        let started = Date()
        t.resume()
        h.watch(started: started, firstByteTimeout: firstByteTimeout, idleTimeout: idleTimeout, totalTimeout: totalTimeout, cancel: cancel)
        if t.state == .running || t.state == .suspended { t.cancel() }
        lock.lock(); handlers.removeValue(forKey: t.taskIdentifier); lock.unlock()
        return h.finalResult()
    }

    private func handler(_ t: URLSessionTask) -> HTTPStream? {
        lock.lock(); defer { lock.unlock() }
        return handlers[t.taskIdentifier]
    }
    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse,
                    completionHandler: @escaping (URLSession.ResponseDisposition) -> Void) {
        guard let h = handler(dataTask) else { completionHandler(.cancel); return }
        h.urlSession(session, dataTask: dataTask, didReceive: response, completionHandler: completionHandler)
    }
    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        handler(dataTask)?.urlSession(session, dataTask: dataTask, didReceive: data)
    }
    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        handler(task)?.urlSession(session, task: task, didCompleteWithError: error)
    }
}

/// VAGUE 2 (RÉSILIENCE) : sonde de joignabilité — une requête HEAD, aucun corps, aucune clé.
/// Toute réponse HTTP (même 404/405) prouve que l'hôte est joignable ; seule l'absence de réponse est un échec.
public func headProbe(_ url: URL, timeout: TimeInterval = 6) -> (ok: Bool, ms: Int, status: Int, error: String) {
    var r: URLRequest = URLRequest(url: url)
    r.httpMethod = "HEAD"
    r.cachePolicy = .reloadIgnoringLocalCacheData
    r.setValue("Nova/2 (sonde réseau)", forHTTPHeaderField: "User-Agent")
    let t0: Date = Date()
    let res: HTTPResult = HTTPStream.run(r, firstByteTimeout: timeout, idleTimeout: timeout, totalTimeout: timeout + 2) { (_: Data) -> Bool in true }
    let ms: Int = Int(Date().timeIntervalSince(t0) * 1000)
    if res.status > 0 { return (true, ms, res.status, "") }
    return (false, ms, 0, res.error ?? "aucune réponse")
}

public func extractMessage(_ body: String) -> String {
    if let o = parseJSON(Data(body.utf8)) {
        if let e = o["error"] as? [String: Any], let m = e["message"] as? String { return m }
        if let e = o["error"] as? String { return e }
        if let m = o["message"] as? String { return m }
    }
    return body
}

/// Découpe un flux SSE en événements `data:` complets (octets arrivant par morceaux arbitraires).
public struct SSEParser {
    var buf = Data()
    public init() {}
    public mutating func feed(_ d: Data) -> [(event: String?, data: String)] {
        buf.append(d)
        var out: [(String?, String)] = []
        let sep1 = Data("\n\n".utf8), sep2 = Data("\r\n\r\n".utf8)
        while true {
            let r1 = buf.range(of: sep1), r2 = buf.range(of: sep2)
            guard let r = [r1, r2].compactMap({ $0 }).min(by: { $0.lowerBound < $1.lowerBound }) else { break }
            let block = buf.subdata(in: buf.startIndex..<r.lowerBound)
            buf.removeSubrange(buf.startIndex..<r.upperBound)
            var ev: String? = nil; var datas: [String] = []
            for line in (String(data: block, encoding: .utf8) ?? "").split(whereSeparator: { $0 == "\n" || $0 == "\r\n" }) {
                let l = line.hasSuffix("\r") ? String(line.dropLast()) : String(line)
                if l.hasPrefix("event:") { ev = l.dropFirst(6).trimmingCharacters(in: .whitespaces) }
                else if l.hasPrefix("data:") { datas.append(String(l.dropFirst(5)).trimmingCharacters(in: .init(charactersIn: " "))) }
            }
            if !datas.isEmpty { out.append((ev, datas.joined(separator: "\n"))) }
        }
        return out
    }
}
