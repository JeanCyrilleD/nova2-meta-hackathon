#if canImport(AppKit)
import AppKit
import WebKit
import NovaCore

// Schéma nova:// — l'UI de Nova parle au noyau SANS socket TCP (expérimental, interrupteur « NovaIPC »).
//   nova://app/<fichier de web/>   fichiers statiques (même service que le serveur HTTP : servePage)
//   nova://app/api/...             API (les fetch relatifs « /api/... » de la page arrivent ici)
//   nova://api/...                 alias : nova://api/state ≡ /api/state
// Tout passe par HTTPServer.dispatchDirect (même routage, même contrôle du jeton que HTTP), sauf les routes en flux
// (HTTPServer.streamingPaths : SSE /api/events, /api/chat, /api/dots/run, /api/council, /api/tts) qui sont relayées
// au fil de l'eau vers le serveur HTTP local (127.0.0.1) par HTTPServer.streamLoopback.
//
// Jeton : WebKit n'envoie pas de cookie sur un schéma personnalisé. Le gestionnaire n'est enregistré QUE sur les deux vues de
// Nova (fenêtre principale et assistant flottant) ; il appose le jeton du lancement uniquement si la requête vient d'un document
// nova://app (en-têtes Origin / Referer absents ou égaux à nova://app, document principal nova://). Toute autre origine
// (iframe externe, etc.) arrive sans jeton et reçoit le même 401 que sur HTTP. Un jeton envoyé explicitement (X-Nova-Token) reste accepté.

/// Tâches en vol. stop() retire la tâche ; plus aucun appel didReceive/didFinish ne lui est fait ensuite (sinon WebKit lève une exception).
final class NovaSchemeTasks {
    private let lock = NSLock()
    private var live = Set<ObjectIdentifier>()
    func add(_ id: ObjectIdentifier) { lock.lock(); live.insert(id); lock.unlock() }
    func remove(_ id: ObjectIdentifier) { lock.lock(); live.remove(id); lock.unlock() }
    func isLive(_ id: ObjectIdentifier) -> Bool { lock.lock(); defer { lock.unlock() }; return live.contains(id) }
}

/// Utilitaires sans isolement d'acteur (appelables depuis les files de travail).
enum NovaSchemeIO {
    static let queue = DispatchQueue(label: "nova.scheme", qos: .userInteractive, attributes: .concurrent)

    /// Interrupteur : UserDefaults « NovaIPC » = true ou variable d'environnement NOVA_IPC=1. Défaut : désactivé (UI en http://127.0.0.1).
    static var enabled: Bool {
        UserDefaults.standard.bool(forKey: "NovaIPC") || ProcessInfo.processInfo.environment["NOVA_IPC"] == "1"
    }

    /// Corps de la requête : httpBody, sinon httpBodyStream (fetch avec Blob/FormData), plafonné à 30 Mo comme le serveur HTTP.
    static func readBody(_ r: URLRequest) -> Data {
        if let b = r.httpBody { return b }
        guard let s = r.httpBodyStream else { return Data() }
        var out = Data()
        let cap = 65536
        var buf = [UInt8](repeating: 0, count: cap)
        s.open()
        while true {
            let n = s.read(&buf, maxLength: cap)
            if n <= 0 { break }
            out.append(buf, count: n)
            if out.count > HTTPServer.maxBodyBytes { break }   // PHASE 1 : au-delà de 10 Mo, la route répond 413 (HTTPServer.admission)
        }
        s.close()
        return out
    }

    /// FIX-STT : journalise ce que WebKit livre réellement pour /api/stt —
    /// httpBody présent et sa taille, httpBodyStream présent, taille rendue par
    /// readBody. Verrouille le mécanisme de perte du corps Blob (le 22/10 :
    /// blob > 0 au départ web, 0 octet à l'arrivée, sans aucun signal).
    static let transportJournal = Journal("voix_journal.jsonl")
    static func logTransport(_ r: URLRequest, _ body: Data) {
        transportJournal.add(["stt": "transport", "httpBody": r.httpBody?.count ?? -1, "stream": r.httpBodyStream != nil, "lu": body.count])
    }

    /// La requête vient-elle d'un document de Nova chargé en nova://app ?
    static func fromNovaDocument(_ r: URLRequest, _ h: [String: String]) -> Bool {
        // PHASE 1 : décision déplacée dans NovaCore (NovaSchemeGate, testée) — Origin ET Referer vides ne suffisent plus.
        return NovaSchemeGate.fromNovaDocument(origin: h["origin"], referer: h["referer"],
                                               mainDocumentScheme: r.mainDocumentURL?.scheme, hasMainDocument: r.mainDocumentURL != nil)
    }

    /// (chemin brut encodé %, requête brute) pour dispatchDirect. nil = URL refusée.
    static func target(_ url: URL) -> (path: String, query: String)? {
        guard url.scheme == "nova", let c = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return nil }
        let rawPath = c.percentEncodedPath.isEmpty ? "/" : c.percentEncodedPath
        let q = c.percentEncodedQuery ?? ""
        switch c.host ?? "" {
        case "app": return (path: rawPath, query: q)
        case "api": return (path: "/api" + (rawPath.hasPrefix("/") ? rawPath : "/" + rawPath), query: q)
        default: return nil
        }
    }

    static func response(_ url: URL, status: Int, mime: String, headers: [String: String], length: Int?) -> URLResponse {
        var h = headers
        h["Content-Type"] = mime
        // 27/10 (retour Ahadi : « les conversations se mélangent encore ») : aucun cache
        // pour les fichiers de l'interface — sans cet en-tête, la WebView pouvait servir
        // un ancien agent.js/shell.js après relance et l'écran contredisait le code livré.
        if url.host == "app" { h["Cache-Control"] = "no-store"; h["Referrer-Policy"] = "same-origin" }   // PHASE 1 : Referer nova://app/… sur les requêtes internes (preuve de provenance pour NovaSchemeGate), rien vers l'extérieur
        if let l = length { h["Content-Length"] = "\(l)" }
        if url.host == "api" { h["Access-Control-Allow-Origin"] = "nova://app" }   // nova://api est une autre origine que nova://app
        h["Set-Cookie"] = nil
        if let r = HTTPURLResponse(url: url, statusCode: status, httpVersion: "HTTP/1.1", headerFields: h) { return r }
        return URLResponse(url: url, mimeType: mime, expectedContentLength: length ?? -1, textEncodingName: nil)
    }
}

/// Sonde TV (C1 moteur) : instrumentation d'arrivée des manifestes au scheme handler.
/// Ne journalise jamais que l'hôte + le nom de fichier (jamais l'URL complète ni les en-têtes/jeton).
enum NovaSchemeTVProbe {
    // Fenêtre de garde-volume : une entrée d'arrivée au plus par même URL de manifeste et par fenêtre.
    static let window: TimeInterval = 10
    private static let lock = NSLock()
    private static var lastSeen: [String: TimeInterval] = [:]

    /// (clé de déduplication = URL décodée, hôte, fichier) si demande de manifeste TV, sinon nil.
    /// Tolère tout échec de décodage en silence (nil = pas d'entrée).
    static func manifestRef(path: String, query: String) -> (key: String, host: String, file: String)? {
        guard path == "/api/stream" || path == "/api/tv/stream" else { return nil }
        guard !query.isEmpty else { return nil }
        var rawU: String?
        // tg.query est la requête brute encodée % : balayage sans URLComponents (déjà disponible, coût minimal).
        var start = query.startIndex
        while start < query.endIndex {
            var end = start
            while end < query.endIndex && query[end] != "&" { end = query.index(after: end) }
            let part = query[start..<end]
            if part.hasPrefix("u=") {
                rawU = String(part.dropFirst(2))
                break
            }
            if end == query.endIndex { break }
            start = query.index(after: end)
        }
        guard let raw = rawU, !raw.isEmpty else { return nil }
        // Une seule passe de décodage % (les URL du catalogue n'ont pas d'identifiants) ; échec = silence.
        guard let decoded = raw.removingPercentEncoding, !decoded.isEmpty else { return nil }
        guard let url = URL(string: decoded) else { return nil }
        guard url.path.lowercased().hasSuffix(".m3u8") else { return nil }   // segments .ts exclus
        guard let host = url.host, !host.isEmpty else { return nil }
        let file = url.lastPathComponent.isEmpty ? "manifeste.m3u8" : url.lastPathComponent
        return (key: decoded, host: host, file: file)
    }

    /// Garde-volume : vrai une fois par même URL par fenêtre (état statique sous verrou).
    static func shouldLogArrival(key: String) -> Bool {
        let now = Date().timeIntervalSinceReferenceDate
        lock.lock()
        defer { lock.unlock() }
        if let last = lastSeen[key], now - last < window { return false }
        // 31/10 (voix/mémoire/Live) : une entrée par URL de manifeste vue, jamais retirée (URL à jeton qui tourne = croissance
        // sans fin). Au-delà de 256 entrées, on oublie celles hors fenêtre (elles ne servent plus au garde-volume).
        if lastSeen.count > 256 { lastSeen = lastSeen.filter { now - $0.value < window } }
        lastSeen[key] = now
        return true
    }
}

final class NovaSchemeHandler: NSObject, WKURLSchemeHandler {
    let server: HTTPServer
    let tasks = NovaSchemeTasks()
    init(server: HTTPServer) { self.server = server; super.init() }

    func webView(_ webView: WKWebView, start urlSchemeTask: WKURLSchemeTask) {
        let task = urlSchemeTask
        let id = ObjectIdentifier(task)
        let tasks = self.tasks
        let srv = self.server
        let req = task.request
        tasks.add(id)
        guard let url = req.url, let tg = NovaSchemeIO.target(url) else {
            tasks.remove(id)
            task.didFailWithError(NSError(domain: NSURLErrorDomain, code: NSURLErrorBadURL, userInfo: nil))
            return
        }
        var hdr: [String: String] = [:]
        for (k, v) in req.allHTTPHeaderFields ?? [:] { hdr[k.lowercased()] = v }
        if tg.path.hasPrefix("/api/"), hdr["x-nova-token"] == nil, NovaSchemeIO.fromNovaDocument(req, hdr) {
            hdr["x-nova-token"] = srv.token
        }
        // Provenance « interface » (Feat_SendQueue, M6) : en-tête jamais accepté du client, posé seulement pour un document nova://app.
        hdr[SendQueue.headerName] = nil
        if NovaSchemeIO.fromNovaDocument(req, hdr) { hdr[SendQueue.headerName] = SendQueue.uiSecret }
        let headers = hdr
        let method = (req.httpMethod ?? "GET").uppercased()
        // Sonde TV (C1) : arrivée d'un manifeste au scheme handler (« la webview a émis »), à corréler avec TVStreamRelay.serve().
        // Synchrone-minime et fire-and-forget : ne lève ni ne retarde jamais la livraison.
        let tvManifest = NovaSchemeTVProbe.manifestRef(path: tg.path, query: tg.query)
        if let m = tvManifest, NovaSchemeTVProbe.shouldLogArrival(key: m.key) {
            BlackBox.record(["tool": "tv_stream", "actor": "Nova", "why": "schéma : manifeste demandé", "ok": true, "effect": "lecture", "result": "\(m.host)/\(m.file)"])
        }

        if HTTPServer.isStreamingPath(tg.path.removingPercentEncoding ?? tg.path) {
            // Le relais pose lui-même le jeton : il n'est donc ouvert qu'aux requêtes déjà autorisées (même 401 que HTTP sinon).
            if !HTTPServer.constantTimeEquals(headers["x-nova-token"], srv.token) {   // PHASE 1 : temps constant
                tasks.remove(id)
                let d = Data("{\"error\":\"non autorisé\"}".utf8)
                task.didReceive(NovaSchemeIO.response(url, status: 401, mime: "application/json; charset=utf-8", headers: [:], length: d.count))
                task.didReceive(d)
                task.didFinish()
                return
            }
            // Flux (SSE, chat, voix) : relais au fil de l'eau vers le serveur HTTP local, sur un thread dédié (flux potentiellement infini).
            let th = Thread {
                let body = NovaSchemeIO.readBody(req)
                if tg.path == "/api/stt" { NovaSchemeIO.logTransport(req, body) }
                let target = tg.query.isEmpty ? tg.path : tg.path + "?" + tg.query
                let ok = srv.streamLoopback(method: method, target: target, headers: headers, body: body,
                    cancel: { !tasks.isLive(id) },
                    onHead: { status, h in
                        let mime = h["Content-Type"] ?? "application/octet-stream"
                        var hh = h; hh["Content-Length"] = nil; hh["Content-Type"] = nil
                        let resp = NovaSchemeIO.response(url, status: status, mime: mime, headers: hh, length: nil)
                        DispatchQueue.main.async { if tasks.isLive(id) { task.didReceive(resp) } }
                    },
                    onData: { d in
                        if !tasks.isLive(id) { return false }
                        DispatchQueue.main.async { if tasks.isLive(id) { task.didReceive(d) } }
                        return true
                    })
                // Sonde TV (C1) : échec du relais loopback pour un manifeste — sans garde-volume (échecs rares et précieux).
                if !ok, let m = tvManifest {
                    BlackBox.record(["tool": "tv_stream", "actor": "Nova", "why": "schéma : relais loopback en échec", "ok": false, "effect": "lecture", "result": "\(m.host)/\(m.file)"])
                }
                DispatchQueue.main.async {
                    guard tasks.isLive(id) else { return }
                    tasks.remove(id)
                    if ok { task.didFinish() }
                    else { task.didFailWithError(NSError(domain: NSURLErrorDomain, code: NSURLErrorCannotConnectToHost, userInfo: nil)) }
                }
            }
            th.stackSize = 1 << 20
            th.start()
            return
        }

        NovaSchemeIO.queue.async {
            let body = NovaSchemeIO.readBody(req)
            if tg.path == "/api/stt" { NovaSchemeIO.logTransport(req, body) }
            let out = srv.dispatchDirect(method: method, path: tg.path, query: tg.query, headers: headers, body: body)
            let resp = NovaSchemeIO.response(url, status: out.status, mime: out.mimeType, headers: out.headers, length: out.data.count)
            DispatchQueue.main.async {
                guard tasks.isLive(id) else { return }   // annulée entre-temps (stop) : on n'appelle plus rien
                tasks.remove(id)
                task.didReceive(resp)
                if !out.data.isEmpty { task.didReceive(out.data) }
                task.didFinish()
            }
        }
    }

    func webView(_ webView: WKWebView, stop urlSchemeTask: WKURLSchemeTask) {
        tasks.remove(ObjectIdentifier(urlSchemeTask))
    }
}
#endif
