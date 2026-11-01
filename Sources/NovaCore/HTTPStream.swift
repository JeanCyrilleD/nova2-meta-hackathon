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
        let cfg = URLSessionConfiguration.ephemeral
        cfg.timeoutIntervalForRequest = max(firstByteTimeout, idleTimeout) + 5
        cfg.timeoutIntervalForResource = totalTimeout
        #if os(macOS)
        cfg.waitsForConnectivity = false
        #endif
        let s = URLSession(configuration: cfg, delegate: h, delegateQueue: nil)
        h.session = s
        let t = s.dataTask(with: req)
        h.task = t
        h.lastActivity = Date()
        let started = Date()
        t.resume()
        // surveillance : délais + annulation
        while h.sem.wait(timeout: .now() + 0.05) == .timedOut {
            let idle = Date().timeIntervalSince(h.lastActivity)
            if cancel?() == true { h.fail(.canceled, "annulé"); break }
            if !h.gotFirst && idle > firstByteTimeout { h.fail(.timeout, "aucune réponse après \(Int(firstByteTimeout)) s"); break }
            if h.gotFirst && idle > idleTimeout { h.fail(.timeout, "flux muet depuis \(Int(idleTimeout)) s"); break }
            if Date().timeIntervalSince(started) > totalTimeout { h.fail(.timeout, "durée maximale dépassée"); break }
        }
        s.invalidateAndCancel()
        var r = h.result
        if r.status >= 400 && r.error == nil {
            let b = String(data: h.errBody, encoding: .utf8) ?? ""
            r.kind = classify(status: r.status, body: b)
            r.error = "HTTP \(r.status) \(shortError(extractMessage(b), 200))"
            r.body = h.errBody
        }
        return r
    }

    func fail(_ k: ErrKind, _ m: String) {
        lock.lock(); defer { lock.unlock() }
        if result.error == nil { result.error = m; result.kind = k }
        stopped = true
        task?.cancel()
    }

    public func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse,
                           completionHandler: @escaping (URLSession.ResponseDisposition) -> Void) {
        if let r = response as? HTTPURLResponse { result.status = r.statusCode }
        lastActivity = Date(); gotFirst = true
        completionHandler(.allow)
    }
    public func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        lastActivity = Date(); gotFirst = true
        if result.status >= 400 { errBody.append(data); return }
        if !onChunk(data) { fail(.canceled, "annulé"); }
    }
    public func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        if let e = error as NSError?, result.error == nil, !stopped {
            let k: ErrKind = e.code == NSURLErrorTimedOut ? .timeout : .network
            result.error = e.localizedDescription; result.kind = k
        }
        sem.signal()
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
