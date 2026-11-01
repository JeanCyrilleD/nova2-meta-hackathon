import Foundation
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

public struct Request {
    public var method: String, path: String, query: [String: String]
    public var headers: [String: String]   // clés en minuscules
    public var body: Data
    public var json: [String: Any] { parseJSON(body) ?? [:] }
    public var cookies: [String: String] {
        var o: [String: String] = [:]
        for p in (headers["cookie"] ?? "").split(separator: ";") {
            let kv = p.split(separator: "=", maxSplits: 1).map { $0.trimmingCharacters(in: .whitespaces) }
            if kv.count == 2 { o[kv[0]] = kv[1] }
        }
        return o
    }
}

public final class Response {
    let fd: Int32
    public private(set) var headersSent = false
    public private(set) var closed = false
    // Mode « capture » (dispatchDirect, schéma nova://) : rien n'est écrit sur un socket, la réponse est gardée en mémoire.
    let capturing: Bool
    var capStatus = 200
    var capType = "application/octet-stream"
    var capHeaders: [String: String] = [:]
    var capBody = Data()
    public init(fd: Int32) { self.fd = fd; self.capturing = false }
    init(capture: Bool) { self.fd = -1; self.capturing = capture }

    @discardableResult
    func writeAll(_ d: Data) -> Bool {
        if closed { return false }
        if capturing { capBody.append(d); return true }
        var off = 0; let n = d.count
        return d.withUnsafeBytes { (p: UnsafeRawBufferPointer) -> Bool in
            while off < n {
                #if canImport(Glibc)
                let w = send(fd, p.baseAddress! + off, n - off, Int32(MSG_NOSIGNAL))
                #else
                let w = write(fd, p.baseAddress! + off, n - off)
                #endif
                if w <= 0 { closed = true; return false }
                off += w
            }
            return true
        }
    }
    public func head(_ status: Int, _ type: String, extra: [String: String] = [:], length: Int? = nil) {
        guard !headersSent else { return }
        headersSent = true
        if capturing {
            capStatus = status; capType = type
            var h: [String: String] = ["Cache-Control": "no-store", "Referrer-Policy": "no-referrer", "X-Content-Type-Options": "nosniff"]
            if let l = length { h["Content-Length"] = "\(l)" }
            for (k, v) in extra { h[k] = v }
            capHeaders = h
            // Un flux (SSE) ne peut pas être capturé : le « client » est déclaré parti, les boucles de flux s'arrêtent d'elles-mêmes.
            if type.hasPrefix("text/event-stream") { closed = true }
            return
        }
        var s = "HTTP/1.1 \(status) \(status == 200 ? "OK" : "Status")\r\nContent-Type: \(type)\r\nConnection: close\r\nCache-Control: no-store\r\nReferrer-Policy: no-referrer\r\nX-Content-Type-Options: nosniff\r\n"
        if let l = length { s += "Content-Length: \(l)\r\n" }
        for (k, v) in extra { s += "\(k): \(v)\r\n" }
        s += "\r\n"
        writeAll(Data(s.utf8))
    }
    public func json(_ obj: Any, status: Int = 200, extra: [String: String] = [:]) {
        let d = jsonData(obj); head(status, "application/json; charset=utf-8", extra: extra, length: d.count); writeAll(d)
    }
    public func data(_ d: Data, type: String, status: Int = 200, extra: [String: String] = [:]) {
        head(status, type, extra: extra, length: d.count); writeAll(d)
    }
    public func sseStart() { head(200, "text/event-stream; charset=utf-8", extra: ["X-Accel-Buffering": "no"]) }
    /// Renvoie false si le client est parti (annulation côté navigateur).
    @discardableResult
    public func sse(_ event: String, _ obj: Any) -> Bool {
        writeAll(Data("event: \(event)\ndata: \(jsonString(obj))\n\n".utf8))
    }
    @discardableResult public func chunk(_ d: Data) -> Bool { writeAll(d) }
    public var clientGone: Bool {
        if closed { return true }
        if capturing { return false }
        var b: UInt8 = 0
        let r = recv(fd, &b, 1, Int32(MSG_PEEK | MSG_DONTWAIT))
        if r == 0 { closed = true; return true }
        return false
    }
}

public final class HTTPServer {
    public typealias Handler = (Request, Response) -> Void
    var routes: [(String, String, Handler)] = []   // méthode, préfixe/chemin exact, handler
    public var staticDir: String? = nil
    public var overlayLookup: ((String) -> Data?)? = nil   // surcouche d'interface (Atelier d'évolution)
    public var token: String
    public var requireToken = true
    public private(set) var port: Int = 0
    // Pont téléphone : second serveur, joignable hors de la machine, qui n'accepte QUE les appareils appairés (jeton propre à chaque appareil).
    public var bindAddress = "127.0.0.1"
    public var remoteAuth: ((Request) -> Bool)? = nil          // non nil = mode pont (pas de contrôle d'hôte local, authentification par appareil)
    public var openPaths: Set<String> = []                      // chemins du pont accessibles sans jeton (appairage)
    public weak var parent: HTTPServer? = nil                   // le serveur principal : ses routes ne sont atteignables que si elles figurent dans remoteAllow
    public var remoteAllow: [String] = []
    // PHASE 1 (course trouvée par TSan) : listenFD est écrit par stop() et lu par le fil d'accept — sous fdLock.
    private var _listenFD: Int32 = -1
    private let fdLock = NSLock()
    var listenFD: Int32 {
        get { fdLock.lock(); defer { fdLock.unlock() }; return _listenFD }
        set { fdLock.lock(); _listenFD = newValue; fdLock.unlock() }
    }
    let q = DispatchQueue(label: "nova.http", attributes: .concurrent)

    public init(token: String = UUID().uuidString.replacingOccurrences(of: "-", with: "")) { self.token = token }

    // PHASE 1 (sécurité) : plafond unique des envois (corps de requête), serveur HTTP ET schéma nova:// — au-delà : 413.
    public static let maxBodyBytes = 10 * 1024 * 1024
    /// PHASE 1 : comparaison de jetons en temps constant (la durée ne dépend pas de la position du premier octet différent).
    public static func constantTimeEquals(_ a: String?, _ b: String) -> Bool {
        guard let a = a else { return false }
        let x = Array(a.utf8), y = Array(b.utf8)
        var diff: UInt8 = x.count == y.count ? 0 : 1
        for i in 0..<y.count { diff |= (i < x.count ? x[i] : 0) ^ y[i] }
        return diff == 0 && !y.isEmpty
    }
    /// PHASE 1 : contrôle Origin (anti-CSRF en plus du jeton). Absente = navigation ou requête de même origine (le jeton reste exigé).
    /// Présente : seules l'interface servie par CE serveur (127.0.0.1/localhost sur son port) et le document nova://app sont admis.
    public func originAllowed(_ origin: String?) -> Bool {
        guard let o = origin?.trimmingCharacters(in: .whitespaces).lowercased(), !o.isEmpty else { return true }
        return o == "http://127.0.0.1:\(port)" || o == "http://localhost:\(port)" || o == "nova://app"
    }
    /// PHASE 1 : garde d'entrée du serveur principal (pure, testable sans socket). nil = admis ; sinon (statut, message).
    /// Ordre : hôte local (anti DNS-rebinding, socket seulement) → Origin → taille du corps. Le jeton est contrôlé ensuite (route).
    func admission(_ req: Request, direct: Bool) -> (Int, String)? {
        if !direct {
            let host = (req.headers["host"] ?? "").lowercased()
            let hostName = host.split(separator: ":", maxSplits: 1, omittingEmptySubsequences: false).first.map(String.init) ?? host
            guard hostName == "127.0.0.1" || hostName == "localhost" else { return (403, "hôte refusé") }
        }
        guard originAllowed(req.headers["origin"]) else { return (403, "origine refusée") }
        guard req.body.count <= HTTPServer.maxBodyBytes else { return (413, "envoi trop gros (> 10 Mo)") }
        return nil
    }
    /// PHASE 1 : jeton du serveur présent (cookie nova_t ou en-tête X-Nova-Token), comparé en temps constant.
    func tokenOK(_ req: Request) -> Bool {
        !requireToken || HTTPServer.constantTimeEquals(req.cookies["nova_t"], token) || HTTPServer.constantTimeEquals(req.headers["x-nova-token"], token)
    }

    public func on(_ method: String, _ path: String, _ h: @escaping Handler) { routes.append((method, path, h)) }

    public func start(port want: Int = 0) throws -> Int {
        signal(SIGPIPE, SIG_IGN)
        #if canImport(Glibc)
        let fd = socket(AF_INET, Int32(SOCK_STREAM.rawValue), 0)
        #else
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        #endif
        guard fd >= 0 else { throw NSError(domain: "nova", code: 1, userInfo: [NSLocalizedDescriptionKey: "socket"]) }
        var one: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &one, socklen_t(MemoryLayout<Int32>.size))
        var addr = sockaddr_in()
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = in_port_t(UInt16(want).bigEndian)
        addr.sin_addr.s_addr = inet_addr(bindAddress)   // 127.0.0.1 par défaut : le serveur principal n'est JAMAIS exposé au réseau
        let ok = withUnsafePointer(to: &addr) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) } }
        guard ok == 0, listen(fd, 64) == 0 else { close(fd); throw NSError(domain: "nova", code: 2, userInfo: [NSLocalizedDescriptionKey: "port \(want) occupé"]) }
        var out = sockaddr_in(); var len = socklen_t(MemoryLayout<sockaddr_in>.size)
        _ = withUnsafeMutablePointer(to: &out) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(fd, $0, &len) } }
        port = Int(UInt16(bigEndian: out.sin_port))
        listenFD = fd
        Thread.detachNewThread { [self] in
            while true {
                let lf = listenFD; if lf < 0 { break }
                let c = accept(lf, nil, nil)
                if c < 0 { if errno == EINTR { continue }; break }
                #if canImport(Darwin)
                var on: Int32 = 1; setsockopt(c, SOL_SOCKET, SO_NOSIGPIPE, &on, socklen_t(MemoryLayout<Int32>.size))
                #endif
                self.dispatchConnection(c)
            }
        }
        return port
    }

    // Réserve de threads réutilisables (pile 16 Mo : les piles GCD de 512 Ko débordent en build debug, d'où pas de DispatchQueue ici).
    // Un thread libre reprend la connexion ; s'il n'y en a aucun (flux SSE longs, chat en cours…), un nouveau est créé : jamais de famine.
    // Au-delà de 4 threads inoccupés depuis 30 s, les surnuméraires se terminent.
    // Les travaux sont des fermetures : une connexion socket OU un appel direct (dispatchDirect) — même réserve, même pile de 16 Mo.
    let poolCond = NSCondition()
    var pendingJobs: [() -> Void] = []
    var idleWorkers = 0

    func dispatchConnection(_ c: Int32) { enqueue { self.handle(c) } }

    func enqueue(_ job: @escaping () -> Void) {
        poolCond.lock()
        pendingJobs.append(job)
        let spawn = idleWorkers < pendingJobs.count
        poolCond.signal()
        poolCond.unlock()
        if spawn {
            let t = Thread { self.workerLoop() }
            t.stackSize = 16 << 20
            t.start()
        }
    }

    func workerLoop() {
        poolCond.lock()
        while true {
            idleWorkers += 1
            var expired = false
            while pendingJobs.isEmpty && !expired {
                if !poolCond.wait(until: Date().addingTimeInterval(30)) { expired = true }
            }
            idleWorkers -= 1
            if pendingJobs.isEmpty {
                if idleWorkers >= 4 { poolCond.unlock(); return }
                continue
            }
            let job = pendingJobs.removeFirst()
            poolCond.unlock()
            job()
            poolCond.lock()
        }
    }

    /// Ferme réellement le port d'écoute (le thread d'accept se termine).
    public func stop() {
        fdLock.lock(); let fd = _listenFD; _listenFD = -1; fdLock.unlock()   // PHASE 1 : lecture + remise à -1 atomiques (un seul close)
        if fd >= 0 { shutdown(fd, SHUT_RDWR); close(fd) }
    }

    func readRequest(_ fd: Int32, tooLarge: inout Bool) -> Request? {
        var buf = Data(); var tmp = [UInt8](repeating: 0, count: 16384)
        var tv = timeval(tv_sec: 15, tv_usec: 0)
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
        var headEnd: Range<Data.Index>? = nil
        while headEnd == nil {
            let n = recv(fd, &tmp, tmp.count, 0)
            if n <= 0 { return nil }
            buf.append(contentsOf: tmp[0..<n])
            headEnd = buf.range(of: Data("\r\n\r\n".utf8))
            if buf.count > 2_000_000 { return nil }
        }
        let headStr = String(data: buf.subdata(in: buf.startIndex..<headEnd!.lowerBound), encoding: .utf8) ?? ""
        var lines = headStr.components(separatedBy: "\r\n")
        let first = lines.removeFirst().split(separator: " ")
        guard first.count >= 2 else { return nil }
        var headers: [String: String] = [:]
        for l in lines { if let i = l.firstIndex(of: ":") { headers[l[..<i].lowercased()] = l[l.index(after: i)...].trimmingCharacters(in: .whitespaces) } }
        var body = buf.subdata(in: headEnd!.upperBound..<buf.endIndex)
        let want = Int(headers["content-length"] ?? "0") ?? 0
        if want > HTTPServer.maxBodyBytes { tooLarge = true; return nil }   // PHASE 1 : plafond 10 Mo, refus 413 explicite (handle)
        while body.count < want {
            let n = recv(fd, &tmp, tmp.count, 0)
            if n <= 0 { break }
            body.append(contentsOf: tmp[0..<n])
        }
        let target = String(first[1])
        let parts = target.split(separator: "?", maxSplits: 1)
        let query = parts.count == 2 ? HTTPServer.parseQuery(String(parts[1])) : [:]
        return Request(method: String(first[0]), path: (String(parts[0]).removingPercentEncoding ?? String(parts[0])), query: query, headers: headers, body: body)
    }

    /// Chaîne de requête brute (encodée %) → dictionnaire décodé, exactement comme pour une requête HTTP.
    static func parseQuery(_ raw: String) -> [String: String] {
        var query: [String: String] = [:]
        for kv in raw.split(separator: "&") {
            let p = kv.split(separator: "=", maxSplits: 1).map { String($0) }
            guard let k0 = p.first else { continue }
            query[k0.removingPercentEncoding ?? k0] = p.count > 1 ? (p[1].replacingOccurrences(of: "+", with: " ").removingPercentEncoding ?? p[1]) : ""
        }
        return query
    }

    // Diagnostic pont (28/10) : journal des connexions du pont (lecture/routage), borné.
    static let bridgeDiag = Journal("bridge_diag.jsonl")
    func handle(_ fd: Int32) {
        let res = Response(fd: fd)
        defer { close(fd) }
        var tooLarge = false
        guard let req = readRequest(fd, tooLarge: &tooLarge) else {
            if tooLarge { res.json(["error": "envoi trop gros (> 10 Mo)"], status: 413) }
            if remoteAuth != nil { HTTPServer.bridgeDiag.add(["ev": "read_nil", "errno": errno]) }
            return
        }
        if remoteAuth != nil { HTTPServer.bridgeDiag.add(["ev": "req", "method": req.method, "path": req.path]) }
        route(req, res, direct: false)
        if remoteAuth != nil { HTTPServer.bridgeDiag.add(["ev": "routed", "path": req.path, "headersSent": res.headersSent, "closed": res.closed]) }
    }

    /// Routes qui écrivent un flux long (SSE, audio en continu) : elles ne passent PAS par dispatchDirect (une réponse capturée
    /// en mémoire ne peut pas être livrée au fil de l'eau). Le schéma nova:// les relaie vers le serveur HTTP local (streamLoopback).
    public static let streamingPaths: Set<String> = ["/api/events", "/api/chat", "/api/dots/run", "/api/council/stream", "/api/tts", "/api/stream", "/api/tv/stream"]
    public static func isStreamingPath(_ path: String) -> Bool { streamingPaths.contains(path) }

    /// Appel direct sans socket (schéma nova://, auto-test) : MÊME logique de routage, d'authentification et de fichiers statiques
    /// que le chemin HTTP (fonction route), exécutée sur la même réserve de threads (pile 16 Mo). Seul le contrôle d'hôte
    /// (anti DNS-rebinding, propre au réseau) est sans objet ici. `path` et `query` sont bruts (encodés %), comme dans une requête HTTP.
    /// Les routes en flux (streamingPaths) sont refusées (501) : utiliser le chemin HTTP pour elles.
    public func dispatchDirect(method: String, path: String, query: String, headers: [String: String], body: Data) -> (status: Int, mimeType: String, headers: [String: String], data: Data) {
        var h: [String: String] = [:]
        for (k, v) in headers { h[k.lowercased()] = v }
        let p0 = path.isEmpty ? "/" : path
        let req = Request(method: method.uppercased(), path: p0.removingPercentEncoding ?? p0, query: HTTPServer.parseQuery(query), headers: h, body: body)
        if HTTPServer.isStreamingPath(req.path) {
            return (501, "application/json; charset=utf-8", ["Cache-Control": "no-store"], jsonData(["error": "route en flux : passer par le serveur HTTP local", "path": req.path]))
        }
        let res = Response(capture: true)
        let sem = DispatchSemaphore(value: 0)
        enqueue { self.route(req, res, direct: true); sem.signal() }
        if sem.wait(timeout: .now() + 180) == .timedOut {
            return (504, "application/json; charset=utf-8", ["Cache-Control": "no-store"], jsonData(["error": "délai dépassé", "path": req.path]))
        }
        if !res.headersSent { return (204, "text/plain", ["Cache-Control": "no-store"], Data()) }
        return (res.capStatus, res.capType, res.capHeaders, res.capBody)
    }

    /// Logique de routage unique (socket HTTP et appel direct).
    func route(_ req: Request, _ res: Response, direct: Bool) {
        if let auth = remoteAuth {   // pont téléphone
            guard req.path.hasPrefix("/api/") else { res.json(["error": "introuvable"], status: 404); return }
            if req.method == "OPTIONS" { res.head(204, "text/plain"); return }
            guard openPaths.contains(req.path) || auth(req) else { res.json(["error": "appareil non autorisé"], status: 401); return }
            for (m, p, h) in routes where m == req.method && (p == req.path || (p.hasSuffix("/") && req.path.hasPrefix(p))) { h(req, res); return }
            if let par = parent, remoteAllow.contains(where: { req.path == $0 || ($0.hasSuffix("/") && req.path.hasPrefix($0)) }) {
                var rq = req; rq.headers["x-nova-remote"] = "1"   // marque l'origine téléphone (le client ne peut pas la retirer)
                for (m, p, h) in par.routes where m == rq.method && (p == rq.path || (p.hasSuffix("/") && rq.path.hasPrefix(p))) { h(rq, res); return }
            }
            res.json(["error": "inconnu", "path": req.path], status: 404); return
        }
        // Garde-fous : hôte local uniquement (anti DNS-rebinding ; sans objet en appel direct), Origin, taille, puis jeton pour l'API.
        if let rej = admission(req, direct: direct) { res.json(["error": rej.1], status: rej.0); return }
        var authed = tokenOK(req)
        if let t = req.query["t"], HTTPServer.constantTimeEquals(t, token) {   // première ouverture : pose le cookie puis sert la page
            authed = true
            if req.path == "/" || req.path.hasSuffix(".html") {
                let page = servePage(req.path, withCookie: true, res: res); if page { return }
            }
        }
        if req.path.hasPrefix("/api/") {
            guard authed else { res.json(["error": "non autorisé"], status: 401); return }
            if req.path.hasPrefix("/api/xxii/") {   // NOVA XXII : délégué au pont additif, APRÈS le contrôle du jeton ; les autres routes ne sont pas touchées
                // PHASE 1 : le résultat passe par une boîte verrouillée — après un délai dépassé, la tâche peut encore écrire pendant qu'on lit.
                let sem = DispatchSemaphore(value: 0); let box = LockedBox<(status: Int, mime: String, data: Data)?>(nil)
                Task { let r = await NovaXXIIBridge.handleRoute(method: req.method, path: req.path, body: req.body); box.set(r); sem.signal() }
                _ = sem.wait(timeout: .now() + 10)
                if let o = box.get() { res.data(o.data, type: o.mime, status: o.status); return }
            }
            if req.method == "OPTIONS" { res.head(204, "text/plain"); return }
            for (m, p, h) in routes where m == req.method && (p == req.path || (p.hasSuffix("/") && req.path.hasPrefix(p))) { h(req, res); return }
            res.json(["error": "inconnu", "path": req.path], status: 404); return
        }
        if !servePage(req.path, withCookie: false, res: res) { res.json(["error": "introuvable"], status: 404) }
    }

    func servePage(_ path: String, withCookie: Bool, res: Response) -> Bool {
        guard let dir = staticDir else { return false }
        var rel = path == "/" ? "/index.html" : path
        if rel.contains("..") { return false }
        rel = String(rel.dropFirst())
        // WP5 / WP7.M : chemin décodé (%2e%2e, %2f), sans « .. », NUL ni antislash, puis RÉSOLU (liens symboliques) et confiné
        // dans le dossier web résolu — un lien posé dans web/ vers l'extérieur ne sert plus aucun fichier.
        guard let dec = rel.removingPercentEncoding, !dec.contains("\0"), !dec.contains("\\"),
              !dec.split(separator: "/", omittingEmptySubsequences: false).contains(where: { $0 == ".." || $0 == "." }) else { return false }
        let url = URL(fileURLWithPath: dir).appendingPathComponent(rel)
        let d: Data
        if let o = overlayLookup?(rel) { d = o } else {
            guard let real = PathPolicy.containedStaticFile(root: dir, relative: rel), let dd = try? Data(contentsOf: URL(fileURLWithPath: real)) else { return false }
            d = dd
        }
        let ext = url.pathExtension.lowercased()
        let types = ["html": "text/html; charset=utf-8", "js": "text/javascript; charset=utf-8", "mjs": "text/javascript; charset=utf-8", "css": "text/css; charset=utf-8",
                     "json": "application/json", "svg": "image/svg+xml", "png": "image/png", "woff2": "font/woff2", "mp3": "audio/mpeg"]
        var extra: [String: String] = [:]
        // 29/10 (audit P0-2) : script-src 'none' (un livrable HTML servi n'exécute rien) ; frame-ancestors 'self'
        // au lieu de 'none' : la webview Nova doit pouvoir iframer ses propres aperçus, personne d'autre.
        // 29/10 (correctif Claude) : appliqué à TOUT html, « script-src 'none' » bloquait aussi l'interface de Nova
        // (index.html, panel.html, companion.html : écran figé sur le squelette au lancement). Les pages de l'interface
        // (racine du bundle web) gardent leurs scripts ; tout autre html servi (livrables, aperçus) reste sans script.
        if ext == "html" {
            let uiPages: Set<String> = ["index.html", "panel.html", "companion.html"]
            if uiPages.contains(rel) { extra["Content-Security-Policy"] = "object-src 'none'; base-uri 'self'; frame-ancestors 'self'" }
            else { extra["Content-Security-Policy"] = "object-src 'none'; base-uri 'self'; frame-ancestors 'self'; script-src 'none'" }
        }
        if HTTPServer.isolationEnabled {   // interrupteur « NovaIsolation » (défaut : désactivé) — uniquement l'UI de Nova, jamais les API
            if ext == "html" || ext == "js" || ext == "mjs" {
                extra["Cross-Origin-Opener-Policy"] = "same-origin"
                extra["Cross-Origin-Embedder-Policy"] = HTTPServer.coepValue
            }
            extra["Cross-Origin-Resource-Policy"] = "same-origin"
        }
        if withCookie { extra["Set-Cookie"] = "nova_t=\(token); Path=/; HttpOnly; SameSite=Strict" }
        res.data(d, type: types[ext] ?? "application/octet-stream", extra: extra)
        return true
    }

    /// Isolation inter-origines (COOP/COEP) : UserDefaults « NovaIsolation » = true ou NOVA_ISOLATION=1. Désactivée par défaut.
    /// COEP « require-corp » casse toute ressource externe sans en-tête CORP (flux TV, images distantes, iframes) : on envoie donc
    /// « credentialless » par défaut (ignoré sans dommage si WebKit ne le reconnaît pas) ; « NovaIsolationCOEP » = "require-corp" pour forcer.
    public static var isolationEnabled: Bool {
        UserDefaults.standard.bool(forKey: "NovaIsolation") || ProcessInfo.processInfo.environment["NOVA_ISOLATION"] == "1"
    }
    public static var coepValue: String {
        let v = UserDefaults.standard.string(forKey: "NovaIsolationCOEP") ?? ""
        return v == "require-corp" ? "require-corp" : "credentialless"
    }

    /// Client de bouclage pour les routes en flux appelées via nova:// : renvoie la requête au serveur HTTP local (127.0.0.1, jeton
    /// du lancement), passe l'en-tête à onHead puis chaque morceau à onData, au fil de l'eau. S'arrête quand cancel() devient vrai,
    /// quand onData renvoie false ou à la fermeture du flux. Renvoie false si aucune réponse n'a pu être lue.
    public func streamLoopback(method: String, target: String, headers: [String: String], body: Data, cancel: () -> Bool,
                               onHead: (Int, [String: String]) -> Void, onData: (Data) -> Bool) -> Bool {
        guard port > 0, remoteAuth == nil else { return false }
        #if canImport(Glibc)
        let fd = socket(AF_INET, Int32(SOCK_STREAM.rawValue), 0)
        #else
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        #endif
        guard fd >= 0 else { return false }
        defer { close(fd) }
        #if canImport(Darwin)
        var on: Int32 = 1; setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &on, socklen_t(MemoryLayout<Int32>.size))
        #endif
        var addr = sockaddr_in()
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = in_port_t(UInt16(port).bigEndian)
        addr.sin_addr.s_addr = inet_addr("127.0.0.1")
        let c = withUnsafePointer(to: &addr) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) } }
        guard c == 0 else { return false }
        var tv = timeval(tv_sec: 1, tv_usec: 0)   // réveil chaque seconde pour vérifier cancel()
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
        var head = "\(method) \(target) HTTP/1.1\r\nHost: 127.0.0.1:\(port)\r\nX-Nova-Token: \(token)\r\nConnection: close\r\nContent-Length: \(body.count)\r\n"
        let skip: Set<String> = ["host", "content-length", "connection", "x-nova-token", "cookie", "transfer-encoding"]
        for (k, v) in headers where !skip.contains(k.lowercased()) {
            if k.contains("\r") || k.contains("\n") || v.contains("\r") || v.contains("\n") { continue }
            head += "\(k): \(v)\r\n"
        }
        head += "\r\n"
        let out = Response(fd: fd)
        guard out.writeAll(Data(head.utf8) + body) else { return false }
        var buf = Data(); var tmp = [UInt8](repeating: 0, count: 16384); var gotHead = false
        while !cancel() {
            let n = recv(fd, &tmp, tmp.count, 0)
            if n == 0 { break }
            if n < 0 {
                let e = errno
                if e == EAGAIN || e == EWOULDBLOCK || e == EINTR { continue }
                break
            }
            if gotHead {
                if !onData(Data(tmp[0..<n])) { break }
                continue
            }
            buf.append(contentsOf: tmp[0..<n])
            guard let r = buf.range(of: Data("\r\n\r\n".utf8)) else { if buf.count > 1_000_000 { break }; continue }
            let headStr = String(data: buf.subdata(in: buf.startIndex..<r.lowerBound), encoding: .utf8) ?? ""
            var lines = headStr.components(separatedBy: "\r\n")
            let first = lines.isEmpty ? [] : lines.removeFirst().split(separator: " ")
            let status = first.count >= 2 ? (Int(first[1]) ?? 502) : 502
            var h: [String: String] = [:]
            for l in lines { if let i = l.firstIndex(of: ":") { h[String(l[..<i])] = l[l.index(after: i)...].trimmingCharacters(in: .whitespaces) } }
            h["Connection"] = nil
            onHead(status, h)
            gotHead = true
            let rest = buf.subdata(in: r.upperBound..<buf.endIndex)
            buf = Data()
            if !rest.isEmpty, !onData(rest) { break }
        }
        return gotHead
    }
}

/// PHASE 1 : valeur partagée entre fils sous un verrou unique (lecture/écriture atomiques).
public final class LockedBox<T>: @unchecked Sendable {
    private let lock = NSLock()
    private var value: T
    public init(_ v: T) { value = v }
    public func get() -> T { lock.lock(); defer { lock.unlock() }; return value }
    public func set(_ v: T) { lock.lock(); value = v; lock.unlock() }
}

/// PHASE 1 (sécurité, schéma nova://) : décision pure d'injection du jeton par NovaSchemeHandler (NovaMac), testable ici.
/// Avant : Origin vide ET Referer vide suffisaient — une sous-ressource d'un cadre tiers avec referrerpolicy=no-referrer
/// (aucun des deux en-têtes) recevait le jeton. Désormais il faut une preuve POSITIVE de provenance nova://app :
/// Origin == nova://app, ou Referer nova://app/… (les documents nova://app sont servis en Referrer-Policy: same-origin),
/// sans en-tête contradictoire, et un document principal nova: (ou absent).
public enum NovaSchemeGate {
    public static func fromNovaDocument(origin: String?, referer: String?, mainDocumentScheme: String?, hasMainDocument: Bool) -> Bool {
        let o = (origin ?? "").trimmingCharacters(in: .whitespaces), r = (referer ?? "").trimmingCharacters(in: .whitespaces)
        let originOK = o.isEmpty || o == "nova://app"
        let refererOK = r.isEmpty || r.hasPrefix("nova://app/")
        let positive = o == "nova://app" || r.hasPrefix("nova://app/")
        let docOK = !hasMainDocument || mainDocumentScheme == "nova"
        return originOK && refererOK && positive && docOK
    }
}
