import Foundation
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

/// Pont téléphone : Nova (Mac) ⇄ application Android.
/// - Désactivé par défaut. Quand il est activé, un SECOND serveur écoute sur le port 8765 ; le serveur principal reste sur 127.0.0.1.
/// - Seuls les appareils appairés (code à 6 chiffres affiché dans Nova, valable 5 min, usage unique) obtiennent un jeton propre, révocable.
/// - Le téléphone n'atteint que : fichiers des dossiers autorisés (lecture), dépôt de fichiers dans ~/Nova-Reçus, chat, file de commandes.
/// - Il ne peut PAS valider une confirmation : toute action risquée demandée par le téléphone s'affiche sur le Mac.
public enum Bridge {
    static let devices = JSONFile("bridge_devices.json")
    static let lock = NSLock()
    nonisolated(unsafe) static var codes: [String: Date] = [:]
    nonisolated(unsafe) static var queue: [String: [[String: Any]]] = [:]       // deviceId → commandes Mac → téléphone
    nonisolated(unsafe) static var results: [[String: Any]] = []                 // derniers retours du téléphone
    nonisolated(unsafe) static var seen: [String: Date] = [:]                    // deviceId → dernière activité — PHASE 1 : lu ET écrit sous `lock` seulement (lastSeen, remoteAuth)
    // PHASE 1 : `server` n'est lu/écrit QUE sous serverLock (cycle de vie du second serveur : démarrage, arrêt, état) —
    // deux POST /api/bridge/newcode simultanés ne peuvent plus lancer deux serveurs. Les autres états restent sous `lock`.
    nonisolated(unsafe) static var server: HTTPServer? = nil
    static let serverLock = NSLock()
    static var isRunning: Bool { serverLock.lock(); defer { serverLock.unlock() }; return server != nil }
    /// Arrête et oublie le serveur du pont (sous verrou).
    static func stopServer() { serverLock.lock(); let s = server; server = nil; serverLock.unlock(); s?.stop() }
    /// Dernière activité d'un appareil (lecture sous verrou).
    static func lastSeen(_ id: String) -> Date? { lock.lock(); defer { lock.unlock() }; return seen[id] }
    /// PHASE 1 : plafond d'un dépôt de fichier par le téléphone (identique au serveur principal).
    static let maxUploadBytes = HTTPServer.maxBodyBytes
    nonisolated(unsafe) static var pairFails = 0
    nonisolated(unsafe) static var pairLockUntil = Date.distantPast
    static let port = 8765

    static func list() -> [[String: Any]] { devices.read(default: [[String: Any]]()) }
    static func device(for req: Request) -> [String: Any]? {
        guard let h = req.headers["authorization"], h.hasPrefix("Bearer ") else { return nil }
        let t = String(h.dropFirst(7))
        guard !t.isEmpty else { return nil }
        lock.lock(); let all = list(); lock.unlock()   // PHASE 1 : lecture sous le verrou des écritures (revoke, pair)
        return all.first { HTTPServer.constantTimeEquals(t, ($0["token"] as? String) ?? "") }   // PHASE 1 : temps constant
    }
    static func newCode() -> String {
        lock.lock(); defer { lock.unlock() }
        codes = codes.filter { $0.value > Date() }
        let c = String(format: "%06d", Int.random(in: 0..<1_000_000)); codes[c] = Date().addingTimeInterval(300); return c
    }
    static func addresses() -> [String] {
        var out: [String] = []; var ifa: UnsafeMutablePointer<ifaddrs>? = nil
        guard getifaddrs(&ifa) == 0, let first = ifa else { return out }
        defer { freeifaddrs(ifa) }
        var p: UnsafeMutablePointer<ifaddrs>? = first
        while let c = p {
            let a = c.pointee
            if let sa = a.ifa_addr, sa.pointee.sa_family == sa_family_t(AF_INET) {
                var buf = [CChar](repeating: 0, count: Int(NI_MAXHOST))
                if getnameinfo(sa, socklen_t(MemoryLayout<sockaddr_in>.size), &buf, socklen_t(buf.count), nil, 0, NI_NUMERICHOST) == 0 {
                    let ip = String(cString: buf); if !ip.hasPrefix("127.") && !ip.hasPrefix("169.254.") { out.append(ip) }
                }
            }
            p = a.ifa_next
        }
        return out
    }
    /// Dossiers lisibles par le téléphone (réglage « bridge_roots »). Jamais Nova-Finances, trousseau, clés SSH.
    static func roots(_ settings: Settings) -> [String] {
        let h = NSHomeDirectory()
        let def = [h + "/Documents", h + "/Desktop", h + "/Downloads", h + "/Nova-Reçus"]
        return (settings.get("bridge_roots", def) as [String]).map { ($0 as NSString).expandingTildeInPath }
    }
    static func safePath(_ raw: String, roots: [String]) -> String? {
        let p = ((raw as NSString).expandingTildeInPath as NSString).standardizingPath
        let real = URL(fileURLWithPath: p).resolvingSymlinksInPath().path
        // NOVA2-FIX (écart E2 du transfert des amendements) : ~/.bionic-tools ajouté — il contient
        // l'outillage et les secrets de l'ancienne flotte ; jamais listable par le pont téléphone.
        // 29/10 (audit P0-3, GO Ahadi) : ajout du dossier SCI (données humanitaires/PII), des mémoires
        // privées _AI_PRIVATE et des données d'apps [tiers] — jamais lisibles par le pont téléphone.
        let blocked = ["/Nova-Finances", "/.ssh", "/Library/Keychains", "/.aws", "/.gnupg", "/.bionic-tools",
                       "/save the children", "_ai_private"]
        guard !blocked.contains(where: { real.lowercased().contains($0.lowercased()) }) else { return nil }
        for r in roots { let rr = URL(fileURLWithPath: r).resolvingSymlinksInPath().path; if real == rr || real.hasPrefix(rr + "/") { return real } }
        return nil
    }
}

extension NovaApp {
    func bridgeInstall() {
        let s = server, st = settings
        // ——— côté Mac (serveur principal, local uniquement) : réglage, code d'appairage, appareils, envoi de commandes
        s.on("GET", "/api/bridge/state") { _, res in
            res.json(["enabled": st.get("bridge_enabled", false), "port": Bridge.port, "addresses": Bridge.addresses(), "running": Bridge.isRunning,
                      "devices": Bridge.list().map { ["id": $0["id"] ?? "", "name": $0["name"] ?? "", "since": $0["since"] ?? "", "seen": Bridge.lastSeen(($0["id"] as? String) ?? "").map { ISO8601DateFormatter().string(from: $0) } ?? ""] }])
        }
        s.on("POST", "/api/bridge/enable") { [self] req, res in
            let on = (req.json["enabled"] as? Bool) ?? false
            st.set(["bridge_enabled": on])
            if on { bridgeStart() } else { Bridge.stopServer() }   // le port se libère au prochain lancement ; les appareils restent appairés
            res.json(["enabled": on, "note": on ? "Pont actif sur le port \(Bridge.port)." : "Pont désactivé (relance Nova pour fermer le port immédiatement)."])
        }
        s.on("POST", "/api/bridge/newcode") { [self] _, res in
            if !Bridge.isRunning { st.set(["bridge_enabled": true]); bridgeStart() }
            guard Bridge.isRunning else { res.json(["error": "Tailscale introuvable sur ce Mac : installe Tailscale (tailscale.com), connecte-toi, puis réessaie."], status: 409); return }
            res.json(["code": Bridge.newCode(), "port": Bridge.port, "addresses": Bridge.addresses(), "valid_seconds": 300])
        }
        s.on("POST", "/api/bridge/revoke") { req, res in
            let id = req.json["id"] as? String ?? ""
            Bridge.lock.lock(); Bridge.devices.write(Bridge.list().filter { ($0["id"] as? String) != id }); Bridge.lock.unlock()   // audit #12 : sous verrou
            res.json(["ok": true])
        }
        s.on("POST", "/api/bridge/send") { req, res in
            res.json(["message": Bridge.send(req.json["device"] as? String ?? "", cmd: req.json["cmd"] as? String ?? "", args: req.json["args"] as? [String: Any] ?? [:], settings: st)])
        }
        if st.get("bridge_enabled", false) { bridgeStart() }
    }

    func bridgeStart() {
        // PHASE 1 : tout le démarrage (test, création, écoute, publication) sous serverLock — plus de check-then-act concurrent.
        Bridge.serverLock.lock(); defer { Bridge.serverLock.unlock() }
        if Bridge.server != nil { return }
        // Le pont n'écoute QUE sur l'adresse Tailscale du Mac (100.64.0.0/10, réseau privé chiffré WireGuard) : jamais sur le Wi-Fi ni sur Internet.
        guard let ts = Bridge.addresses().first(where: { a in let p = a.split(separator: ".").compactMap { Int($0) }; return p.count == 4 && p[0] == 100 && p[1] >= 64 && p[1] <= 127 }) else { Bridge.server = nil; return }
        let b = HTTPServer(token: UUID().uuidString)
        b.bindAddress = ts; b.parent = server; b.remoteAllow = ["/api/chat", "/api/conversations"]
        b.openPaths = ["/api/pair"]
        b.remoteAuth = { req in
            guard let d = Bridge.device(for: req) else { return false }
            Bridge.lock.lock(); Bridge.seen[(d["id"] as? String) ?? ""] = Date(); Bridge.lock.unlock(); return true
        }
        let st = settings
        b.on("POST", "/api/pair") { req, res in
            let j = req.json; let code = (j["code"] as? String) ?? ""
            Bridge.lock.lock()
            if Date() < Bridge.pairLockUntil { Bridge.lock.unlock(); res.json(["error": "trop d'essais : réessaie dans quelques minutes"], status: 429); return }
            let ok = (Bridge.codes[code] ?? .distantPast) > Date(); if ok { Bridge.codes[code] = nil; Bridge.pairFails = 0 }
            else { Bridge.pairFails += 1; if Bridge.pairFails >= 5 { Bridge.pairFails = 0; Bridge.codes = [:]; Bridge.pairLockUntil = Date().addingTimeInterval(300) } }
            Bridge.lock.unlock()
            guard ok else { res.json(["error": "code invalide ou expiré"], status: 403); return }
            let name = String(((j["name"] as? String) ?? "Téléphone").prefix(60))
            let id = UUID().uuidString.prefix(8).lowercased().description, token = UUID().uuidString.replacingOccurrences(of: "-", with: "") + UUID().uuidString.replacingOccurrences(of: "-", with: "")
            Bridge.lock.lock(); Bridge.devices.write(Bridge.list() + [["id": id, "name": name, "token": token, "since": nowISO()]]); Bridge.lock.unlock()   // audit #12 : sous verrou
            res.json(["id": id, "token": token, "mac": ProcessInfo.processInfo.hostName])
        }
        b.on("GET", "/api/ping") { _, res in res.json(["ok": true, "time": nowISO(), "version": NovaApp.version]) }
        b.on("GET", "/api/files") { req, res in
            let roots = Bridge.roots(st)
            let raw = req.query["path"] ?? ""
            if raw.isEmpty { res.json(["path": "", "items": roots.filter { FileManager.default.fileExists(atPath: $0) }.map { ["name": ($0 as NSString).lastPathComponent, "path": $0, "dir": true, "size": 0] }]); return }
            guard let p = Bridge.safePath(raw, roots: roots) else { res.json(["error": "dossier non autorisé"], status: 403); return }
            let names = ((try? FileManager.default.contentsOfDirectory(atPath: p)) ?? []).filter { !$0.hasPrefix(".") }.sorted()
            let items: [[String: Any]] = names.prefix(500).map { n in
                let f = p + "/" + n; var d: ObjCBool = false; _ = FileManager.default.fileExists(atPath: f, isDirectory: &d)
                let size = (try? FileManager.default.attributesOfItem(atPath: f)[.size] as? Int) ?? 0
                return ["name": n, "path": f, "dir": d.boolValue, "size": size ?? 0]
            }
            res.json(["path": p, "items": items])
        }
        b.on("GET", "/api/search") { req, res in
            let q = (req.query["q"] ?? "").trimmingCharacters(in: .whitespaces); let roots = Bridge.roots(st)
            guard !q.isEmpty else { res.json(["items": [Any]()]); return }
            var out: [[String: Any]] = []
            for r in roots where FileManager.default.fileExists(atPath: r) {
                let (_, o) = runProcess("/usr/bin/mdfind", ["-onlyin", r, "-name", q], timeout: 15)
                for l in o.split(separator: "\n").prefix(30) { if let p = Bridge.safePath(String(l), roots: roots) { out.append(["name": (p as NSString).lastPathComponent, "path": p, "dir": false, "size": (try? FileManager.default.attributesOfItem(atPath: p)[.size] as? Int) ?? 0]) } }
            }
            res.json(["items": Array(out.prefix(40))])
        }
        b.on("GET", "/api/file") { req, res in
            // audit #12 : aucun fichier ou dossier caché (composant commençant par « . »).
            let rawPath: String = req.query["path"] ?? ""
            let hidden: Bool = rawPath.split(separator: "/").contains(where: { $0.hasPrefix(".") })
            if hidden { res.json(["error": "fichier caché non autorisé"], status: 403); return }
            guard let p = Bridge.safePath(rawPath, roots: Bridge.roots(st)), !p.split(separator: "/").contains(where: { $0.hasPrefix(".") }), ![".env", ".pem", ".key", ".p12", "secret", "token", "password", "id_rsa", "keychain"].contains(where: { (p as NSString).lastPathComponent.lowercased().contains($0) }), let a = try? FileManager.default.attributesOfItem(atPath: p), (a[.size] as? Int ?? 0) <= 150_000_000, (a[.type] as? FileAttributeType) == .typeRegular, let d = FileManager.default.contents(atPath: p) else { res.json(["error": "fichier non autorisé, introuvable ou trop gros (> 150 Mo)"], status: 403); return }
            res.data(d, type: "application/octet-stream", extra: ["Content-Disposition": "attachment; filename=\"\(((p as NSString).lastPathComponent).replacingOccurrences(of: "\"", with: ""))\""])
        }
        b.on("POST", "/api/upload") { req, res in
            guard req.body.count <= Bridge.maxUploadBytes else { res.json(["error": "fichier trop gros (> 10 Mo)"], status: 413); return }   // PHASE 1
            var name = ((req.query["name"] ?? "fichier") as NSString).lastPathComponent.replacingOccurrences(of: "/", with: "_"); if name.hasPrefix(".") || name.isEmpty { name = "fichier" }
            let dir = NSHomeDirectory() + "/Nova-Reçus"; try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
            var dest = dir + "/" + name; var i = 1
            while FileManager.default.fileExists(atPath: dest) { dest = dir + "/" + ((name as NSString).deletingPathExtension) + "-\(i)." + (name as NSString).pathExtension; i += 1 }
            guard (try? req.body.write(to: URL(fileURLWithPath: dest))) != nil else { res.json(["error": "écriture impossible"], status: 500); return }
            res.json(["ok": true, "path": dest])
        }
        b.on("GET", "/api/phone/poll") { req, res in   // le téléphone vient chercher ses commandes (appel court)
            guard let d = Bridge.device(for: req), let id = d["id"] as? String else { res.json(["error": "?"], status: 401); return }
            Bridge.lock.lock(); let cmds = Bridge.queue[id] ?? []; Bridge.queue[id] = []; Bridge.lock.unlock()
            res.json(["commands": cmds])
        }
        b.on("POST", "/api/phone/result") { req, res in
            Bridge.lock.lock(); Bridge.results = Array((Bridge.results + [req.json.merging(["ts": nowISO()]) { a, _ in a }]).suffix(50)); Bridge.lock.unlock(); res.json(["ok": true])
        }
        phoneBridgeRoutes(b)   // Feat_Phone.swift : page mobile /api/m + routes /api/phone/*
        do { _ = try b.start(port: Bridge.port); Bridge.server = b } catch { Bridge.server = nil }
    }
}

extension Bridge {
    /// Mac → téléphone. Commandes sans danger : notification, ouvrir un lien, récupérer un fichier du Mac.
    static func send(_ device: String, cmd: String, args: [String: Any], settings: Settings) -> String {
        let all = list(); guard let d = (device.isEmpty ? all.first : all.first { ($0["id"] as? String) == device || ($0["name"] as? String)?.lowercased() == device.lowercased() }), let id = d["id"] as? String else { return "Aucun téléphone appairé." }
        var a = args
        switch cmd {
        case "notify", "open_url", "locate", "ring": break
        case "push_file":
            guard let p = args["path"] as? String, let real = safePath(p, roots: roots(settings)) else { return "Fichier hors des dossiers autorisés." }
            a["path"] = real
        default: return "Commande inconnue : \(cmd)."
        }
        lock.lock(); queue[id, default: []].append(["cmd": cmd, "args": a, "id": UUID().uuidString.prefix(8).lowercased().description]); lock.unlock()
        return "Commande « \(cmd) » envoyée à \(d["name"] ?? "ton téléphone") (livrée dès qu'il se connecte)."
    }
}
