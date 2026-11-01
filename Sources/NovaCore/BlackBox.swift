import Foundation

/// SHA-256 et HMAC-SHA256 autonomes (aucune dépendance, identiques sur Mac et Linux).
enum Sha {
    static let k: [UInt32] = [
        0x428a2f98,0x71374491,0xb5c0fbcf,0xe9b5dba5,0x3956c25b,0x59f111f1,0x923f82a4,0xab1c5ed5,0xd807aa98,0x12835b01,0x243185be,0x550c7dc3,0x72be5d74,0x80deb1fe,0x9bdc06a7,0xc19bf174,
        0xe49b69c1,0xefbe4786,0x0fc19dc6,0x240ca1cc,0x2de92c6f,0x4a7484aa,0x5cb0a9dc,0x76f988da,0x983e5152,0xa831c66d,0xb00327c8,0xbf597fc7,0xc6e00bf3,0xd5a79147,0x06ca6351,0x14292967,
        0x27b70a85,0x2e1b2138,0x4d2c6dfc,0x53380d13,0x650a7354,0x766a0abb,0x81c2c92e,0x92722c85,0xa2bfe8a1,0xa81a664b,0xc24b8b70,0xc76c51a3,0xd192e819,0xd6990624,0xf40e3585,0x106aa070,
        0x19a4c116,0x1e376c08,0x2748774c,0x34b0bcb5,0x391c0cb3,0x4ed8aa4a,0x5b9cca4f,0x682e6ff3,0x748f82ee,0x78a5636f,0x84c87814,0x8cc70208,0x90befffa,0xa4506ceb,0xbef9a3f7,0xc67178f2]
    @inline(__always) static func rotr(_ x: UInt32, _ n: UInt32) -> UInt32 { (x >> n) | (x << (32 - n)) }
    static func sha256(_ data: [UInt8]) -> [UInt8] {
        var h: [UInt32] = [0x6a09e667,0xbb67ae85,0x3c6ef372,0xa54ff53a,0x510e527f,0x9b05688c,0x1f83d9ab,0x5be0cd19]
        var m = data; m.append(0x80)
        while m.count % 64 != 56 { m.append(0) }
        let bits = UInt64(data.count) * 8
        for i in (0..<8).reversed() { m.append(UInt8((bits >> (UInt64(i) * 8)) & 0xff)) }
        var w = [UInt32](repeating: 0, count: 64)
        for chunk in stride(from: 0, to: m.count, by: 64) {
            for i in 0..<16 { let j = chunk + i * 4; w[i] = UInt32(m[j]) << 24 | UInt32(m[j+1]) << 16 | UInt32(m[j+2]) << 8 | UInt32(m[j+3]) }
            for i in 16..<64 {
                let s0 = rotr(w[i-15], 7) ^ rotr(w[i-15], 18) ^ (w[i-15] >> 3)
                let s1 = rotr(w[i-2], 17) ^ rotr(w[i-2], 19) ^ (w[i-2] >> 10)
                w[i] = w[i-16] &+ s0 &+ w[i-7] &+ s1
            }
            var a = h[0], b = h[1], c = h[2], d = h[3], e = h[4], f = h[5], g = h[6], hh = h[7]
            for i in 0..<64 {
                let S1 = rotr(e, 6) ^ rotr(e, 11) ^ rotr(e, 25)
                let ch = (e & f) ^ (~e & g)
                let t1 = hh &+ S1 &+ ch &+ k[i] &+ w[i]
                let S0 = rotr(a, 2) ^ rotr(a, 13) ^ rotr(a, 22)
                let mj = (a & b) ^ (a & c) ^ (b & c)
                let t2 = S0 &+ mj
                hh = g; g = f; f = e; e = d &+ t1; d = c; c = b; b = a; a = t1 &+ t2
            }
            h[0] = h[0] &+ a; h[1] = h[1] &+ b; h[2] = h[2] &+ c; h[3] = h[3] &+ d; h[4] = h[4] &+ e; h[5] = h[5] &+ f; h[6] = h[6] &+ g; h[7] = h[7] &+ hh
        }
        var out = [UInt8](); for v in h { out += [UInt8(v >> 24), UInt8((v >> 16) & 0xff), UInt8((v >> 8) & 0xff), UInt8(v & 0xff)] }
        return out
    }
    static func hex(_ b: [UInt8]) -> String { b.map { String(format: "%02x", $0) }.joined() }
    static func hash(_ s: String) -> String { hex(sha256(Array(s.utf8))) }
    static func hmac(_ key: [UInt8], _ msg: [UInt8]) -> [UInt8] {
        var k = key; if k.count > 64 { k = sha256(k) }; k += [UInt8](repeating: 0, count: 64 - k.count)
        return sha256(k.map { $0 ^ 0x5c } + sha256(k.map { $0 ^ 0x36 } + msg))
    }
}

/// Boîte noire : journal chaîné (chaque ligne contient l'empreinte de la précédente) + reçus signés (HMAC) par une clé locale 0600.
/// La clé vit dans un fichier, jamais dans le Trousseau : aucune fenêtre d'autorisation. Toute modification d'une ligne passée casse la chaîne.
public enum BlackBox {
    static let lock = NSLock()
    static var url: URL { Paths.file("blackbox.jsonl") }
    static var keyURL: URL { Paths.file("blackbox.key") }
    nonisolated(unsafe) static var lastHash: String? = nil
    nonisolated(unsafe) static var seq = 0
    nonisolated(unsafe) static var cachedKey: [UInt8]? = nil
    static let genesis = String(repeating: "0", count: 64)

    static func key() -> [UInt8] {
        if let k = cachedKey { return k }
        if let d = try? Data(contentsOf: keyURL), d.count >= 32 { cachedKey = [UInt8](d); return cachedKey! }
        var b = [UInt8](); for _ in 0..<32 { b.append(UInt8.random(in: 0...255)) }
        FileManager.default.createFile(atPath: keyURL.path, contents: Data(b), attributes: [.posixPermissions: 0o600])
        cachedKey = b; return b
    }
    static func canonical(_ e: [String: Any]) -> String {
        guard let d = try? JSONSerialization.data(withJSONObject: e, options: [.sortedKeys]) else { return "{}" }
        return String(decoding: d, as: UTF8.self)
    }
    static func lineHash(prev: String, seq: Int, ts: String, entry: String) -> String { Sha.hash("\(prev)|\(seq)|\(ts)|\(entry)") }
    static func receipt(_ hash: String) -> String { Sha.hex(Sha.hmac(key(), Array(hash.utf8))) }

    /// Rotation au démarrage (P0 stabilité 27/10) : au-delà de ~8 Mo, le journal est
    /// archivé tel quel (jamais réécrit) et une chaîne neuve démarre. Contexte : le
    /// journal historique (17 Mo, 32 853 lignes) porte 55 ruptures de séquence autour
    /// de la ligne 7105 — deux processus écrivaient en parallèle à l'époque, pas une
    /// falsification — mais verify() ne pourra jamais le déclarer intact. L'archive
    /// reste consultable ; la nouvelle chaîne redevient vérifiable de bout en bout.
    /// Renvoie la tête (hash) de l'archive si une rotation vient d'avoir lieu.
    static let rotationSeuil: UInt64 = 8_388_608
    nonisolated(unsafe) static var teteArchivee: (nom: String, hash: String)? = nil
    static func rotateIfNeeded() -> (nom: String, hash: String)? {
        let fm = FileManager.default
        guard let attrs = try? fm.attributesOfItem(atPath: url.path),
              let size = (attrs[.size] as? NSNumber)?.uint64Value, size > rotationSeuil else { return nil }
        // tête actuelle (dernier hash) avant déplacement — lecture bornée, jamais tout le fichier
        var head = genesis
        if let fh = try? FileHandle(forReadingFrom: url) {
            let sz = fh.seekToEndOfFile()
            fh.seek(toFileOffset: sz > 131_072 ? sz - 131_072 : 0)
            if let s = String(data: fh.readDataToEndOfFile(), encoding: .utf8),
               let last = s.split(separator: "\n").last, let o = parseJSON(Data(last.utf8)),
               let h = o["hash"] as? String { head = h }
            try? fh.close()
        }
        let nom = "blackbox-archive-" + String(nowISO().prefix(16)).replacingOccurrences(of: ":", with: "").replacingOccurrences(of: "T", with: "_") + ".jsonl"
        let dest = Paths.file(nom)
        do { try fm.moveItem(at: url, to: dest) } catch { return nil }   // échec : on continue sur l'ancien fichier, jamais de perte
        return (nom, head)
    }

    static func load() {   // reprend la fin de chaîne existante au démarrage
        guard lastHash == nil else { return }
        teteArchivee = rotateIfNeeded()
        lastHash = genesis; seq = 0
        if teteArchivee != nil { return }   // fichier neuf après rotation : genèse propre
        // NOVA2-M (27/10 14:03, SentryFileIOTracker.measureNSData) : ne jamais relire
        // tout le journal pour retrouver sa fin — 16 Mo lus d'un bloc au démarrage
        // suffisent à passer le seuil AppHang. Seuls les derniers 128 Ko sont lus ;
        // la dernière ligne complète y tient toujours (ligne plafonnée par record()).
        guard let fh = try? FileHandle(forReadingFrom: url) else { return }
        defer { try? fh.close() }
        let size: UInt64 = fh.seekToEndOfFile()
        let start: UInt64 = size > 131_072 ? size - 131_072 : 0
        fh.seek(toFileOffset: start)
        let data: Data = fh.readDataToEndOfFile()
        guard let s = String(data: data, encoding: .utf8), let last = s.split(separator: "\n").last, let o = parseJSON(Data(last.utf8)) else { return }
        lastHash = (o["hash"] as? String) ?? genesis; seq = (o["seq"] as? Int) ?? 0
    }

    // SENTRY NOVA2 AppHang (26-27/10, 4 occurrences >= 2 000 ms) : record() ouvrait,
    // cherchait la fin et fermait le fichier SYNCHRONEMENT a chaque appel — y compris
    // depuis le thread de la WebView (NovaSchemeHandler journalise les manifestes TV).
    // Desormais : le recu (seq, hash, signature) reste calcule synchrone sous le verrou
    // (les appelants le consomment immediatement), seule l'ECRITURE part sur une file
    // serie d'arriere-plan qui garde le descripteur ouvert. L'ordre du fichier suit
    // l'ordre des appels (file FIFO + calcul sous verrou). verify()/tail() drainent
    // la file avant de relire.
    static let writeQueue: DispatchQueue = DispatchQueue(label: "nova.blackbox.writer", qos: .utility)
    nonisolated(unsafe) static var writeHandle: FileHandle? = nil

    private static func appendOnQueue(_ line: Data) {
        // Sur writeQueue uniquement.
        if writeHandle == nil {
            if !FileManager.default.fileExists(atPath: url.path) {
                FileManager.default.createFile(atPath: url.path, contents: nil)
            }
            writeHandle = try? FileHandle(forWritingTo: url)
            writeHandle?.seekToEndOfFile()
        }
        do {
            try writeHandle?.write(contentsOf: line)
        } catch {
            writeHandle = nil   // descripteur invalide : on rouvrira au prochain lot
        }
    }

    /// Draine les ecritures en attente (a appeler avant toute relecture du fichier).
    static func flushWrites() { writeQueue.sync {} }

    /// Ajoute une action à la chaîne et renvoie son reçu signé.
    @discardableResult
    public static func record(_ action: [String: Any]) -> [String: Any] {
        lock.lock(); defer { lock.unlock() }
        load()
        if let t = teteArchivee {
            // Première ligne après rotation : marqueur reliant la chaîne neuve à
            // l'archive (nom + tête) — la continuité reste auditable à la main.
            teteArchivee = nil
            let mEntry: [String: Any] = ["tool": "blackbox_rotation", "actor": "Nova", "effect": "lecture", "ok": true,
                                         "why": "rotation au demarrage (>8 Mo) - journal precedent archive sans reecriture",
                                         "result": "archive=\(t.nom) tete=\(t.hash)"]
            seq += 1
            let mPrev = lastHash ?? genesis, mts = nowISO()
            let mh = lineHash(prev: mPrev, seq: seq, ts: mts, entry: canonical(mEntry))
            let mRow: [String: Any] = ["seq": seq, "ts": mts, "prev": mPrev, "hash": mh, "sig": receipt(mh), "entry": mEntry]
            lastHash = mh
            let mLine = jsonData(mRow) + Data("\n".utf8)
            writeQueue.async { appendOnQueue(mLine) }
        }
        var entry: [String: Any] = [:]
        for k in ["id", "tool", "input", "actor", "effect", "ok", "why", "undo"] { if let v = action[k] { entry[k] = v } }
        entry["result"] = String(((action["result"] as? String) ?? "").prefix(200))
        let ts = nowISO(); seq += 1
        let prev = lastHash ?? genesis, c = canonical(entry)
        let h = lineHash(prev: prev, seq: seq, ts: ts, entry: c)
        let row: [String: Any] = ["seq": seq, "ts": ts, "prev": prev, "hash": h, "sig": receipt(h), "entry": entry]
        let line = jsonData(row) + Data("\n".utf8)
        lastHash = h
        writeQueue.async { appendOnQueue(line) }
        return ["seq": seq, "ts": ts, "hash": h, "sig": row["sig"] as Any]
    }

    /// Relit toute la chaîne : empreintes, chaînage et signatures. `ok` faux + `brokenAt` = première ligne altérée.
    public static func verify() -> [String: Any] {
        flushWrites()
        lock.lock(); defer { lock.unlock() }
        guard let s = try? String(contentsOf: url, encoding: .utf8) else { return ["ok": true, "count": 0, "message": "Journal vide."] }
        var prev = genesis, n = 0, expect = 1
        for l in s.split(separator: "\n") {
            guard let o = parseJSON(Data(l.utf8)), let sq = o["seq"] as? Int, let ts = o["ts"] as? String, let p = o["prev"] as? String,
                  let h = o["hash"] as? String, let sig = o["sig"] as? String, let e = o["entry"] as? [String: Any] else { return ["ok": false, "count": n, "brokenAt": expect, "message": "Ligne \(expect) illisible."] }
            if sq != expect || p != prev || lineHash(prev: p, seq: sq, ts: ts, entry: canonical(e)) != h || receipt(h) != sig {
                return ["ok": false, "count": n, "brokenAt": sq, "message": "Chaîne rompue à l'action n° \(sq) : le journal a été modifié."] }
            prev = h; n += 1; expect += 1
        }
        return ["ok": true, "count": n, "head": prev, "message": "\(n) actions, chaîne intacte et signatures valides."]
    }

    public static func tail(_ n: Int) -> [[String: Any]] {
        flushWrites()
        lock.lock(); defer { lock.unlock() }
        // 31/10 (voix/mémoire/Live) : lecture bornée par la fin (journalTailLines) au lieu du fichier entier (jusqu'à 8 Mo).
        return journalTailLines(url, n).compactMap { parseJSON(Data($0.utf8)) }
    }
    /// Reçu d'une action (par son id) : preuve horodatée et signée, vérifiable avec `verify`.
    public static func receipt(forAction id: String) -> [String: Any]? {
        tail(5000).last(where: { (($0["entry"] as? [String: Any])?["id"] as? String) == id })
            .map { ["seq": $0["seq"] as Any, "ts": $0["ts"] as Any, "hash": $0["hash"] as Any, "sig": $0["sig"] as Any, "entry": $0["entry"] as Any, "format": "nova-receipt-v1"] }
    }
    /// Actions à effet enregistrées depuis `since` (sert aux budgets du Permis d'agir).
    static func countSince(_ since: Date, tool: String? = nil, actor: String? = nil) -> Int {
        let f = ISO8601DateFormatter()
        return tail(2000).filter { r in
            guard let t = r["ts"] as? String, let d = f.date(from: t), d >= since, let e = r["entry"] as? [String: Any], e["effect"] as? String == "écrit" else { return false }
            if let tool = tool, e["tool"] as? String != tool { return false }
            if let actor = actor, e["actor"] as? String != actor { return false }
            return true
        }.count
    }
}

/// Permis d'agir : règles écrites en langage naturel, compilées en règles vérifiables, appliquées AVANT chaque outil.
public enum Permits {
    static let file = JSONFile("permits.json")
    static let lock = NSLock()

    public static func list() -> [[String: Any]] { file.read(default: [[String: Any]]()) }

    /// Compile une phrase. Retourne la règle ou nil si non comprise.
    /// Reconnaît : « pas plus de 10 actions par heure », « maximum 5 shell par jour », « jamais de shell / interdit d'utiliser applescript »,
    /// « ne touche jamais à ~/Documents/Contrats », « Dot Veille : 20 actions par jour ».
    public static func compile(_ text: String) -> [String: Any]? {
        let t = text.lowercased().folding(options: .diacriticInsensitive, locale: nil).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty else { return nil }
        let tools = ["shell", "applescript", "open", "app", "ui", "shortcut", "remember", "draft_reply", "forge_tool", "momo", "web_fetch", "web_search"]
        let tool = tools.first(where: { t.range(of: "\\b\($0)\\b", options: .regularExpression) != nil })
        var rule: [String: Any] = ["id": String(UUID().uuidString.prefix(6)).lowercased(), "text": text, "enabled": true, "created": nowISO()]
        if let tool = tool { rule["tool"] = tool }
        if let m = t.range(of: #"(?:dot|agent)\s+([a-z0-9_\-]+)"#, options: .regularExpression) {
            rule["actor"] = String(t[m]).split(separator: " ").last.map(String.init) ?? ""
        }
        // budget : « 10 actions par heure »
        if let m = t.range(of: #"(\d+)\s*(?:actions?|fois|appels?|[a-z_]+)?\s*(?:par|/|each|per)\s*(minute|heure|jour|semaine)"#, options: .regularExpression) {
            let s = String(t[m]); let n = Int(s.prefix(while: { $0.isNumber || $0 == " " }).trimmingCharacters(in: .whitespaces)) ?? 0
            let unit = ["minute": 1, "heure": 60, "jour": 1440, "semaine": 10080].first(where: { s.contains($0.key) })?.value ?? 60
            if n > 0 { rule["kind"] = "limit"; rule["max"] = n; rule["minutes"] = unit; return rule }
        }
        // chemin protégé
        if let m = t.range(of: #"(?:~|/)[^\s,;]+"#, options: .regularExpression), t.contains("jamais") || t.contains("interdit") || t.contains("pas toucher") {
            rule["kind"] = "path"; rule["path"] = String(text[m.lowerBound..<m.upperBound]).replacingOccurrences(of: "~", with: NSHomeDirectory()); return rule
        }
        // interdiction d'un outil
        if tool != nil, t.contains("jamais") || t.contains("interdit") || t.contains("pas de") || t.contains("sans") || t.contains("n'utilise pas") { rule["kind"] = "deny"; return rule }
        return nil
    }

    @discardableResult
    public static func add(_ text: String) -> [String: Any]? {
        guard let r = compile(text) else { return nil }
        lock.lock(); defer { lock.unlock() }
        var all = list(); all.append(r); file.write(all); return r
    }
    public static func remove(_ id: String) { lock.lock(); defer { lock.unlock() }; file.write(list().filter { ($0["id"] as? String) != id }) }
    public static func toggle(_ id: String, _ on: Bool) { lock.lock(); defer { lock.unlock() }; file.write(list().map { var r = $0; if r["id"] as? String == id { r["enabled"] = on }; return r }) }

    /// nil = permis ; sinon la raison du refus (renvoyée au modèle, journalisée).
    public static func check(tool: String, arg: String, actor: String) -> String? {
        let rules = list().filter { ($0["enabled"] as? Bool) ?? true }
        guard !rules.isEmpty else { return nil }
        let a = actor.lowercased().folding(options: .diacriticInsensitive, locale: nil)
        for r in rules {
            if let rt = r["tool"] as? String, rt != tool { continue }
            if let ra = r["actor"] as? String, !ra.isEmpty, !a.contains(ra) { continue }
            switch (r["kind"] as? String) ?? "" {
            case "deny": return "Refusé par ton Permis d'agir (« \(r["text"] as? String ?? "") »)."
            case "path": if let p = r["path"] as? String, arg.contains(p) { return "Refusé par ton Permis d'agir : « \(r["text"] as? String ?? "") »." }
            case "limit":
                let mins = (r["minutes"] as? Int) ?? 60, mx = (r["max"] as? Int) ?? 0
                let used = BlackBox.countSince(Date().addingTimeInterval(-Double(mins) * 60), tool: r["tool"] as? String, actor: nil)
                if used >= mx { return "Budget d'autonomie épuisé (\(used)/\(mx) sur \(mins >= 1440 ? "\(mins/1440) j" : mins >= 60 ? "\(mins/60) h" : "\(mins) min")) — règle : « \(r["text"] as? String ?? "") ». Demande à l'utilisateur d'élargir le permis." }
            default: break
            }
        }
        return nil
    }
}
