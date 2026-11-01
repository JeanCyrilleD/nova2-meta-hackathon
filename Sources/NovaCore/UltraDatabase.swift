import Foundation
#if canImport(SQLite3)
import SQLite3   // libsqlite3 du système : le module SQLite3 du SDK macOS la lie automatiquement (aucune dépendance SPM)
#endif

/// Persistance SQLite (WAL) de Nova — interrupteur « NovaSQLite » (UserDefaults, défaut : désactivé) ou NOVA_SQLITE=1.
/// - kv(ns, k, v, ts) : valeurs JSON brutes (une ligne par fichier d'état JSONFile, ns = "json").
/// - activity : journal d'événements append-only (lignes des journaux JSONL), écrit sur une file série dédiée.
/// Toute la connexion est utilisée depuis UNE file série (q) : aucun accès concurrent à sqlite3.
/// Si la base ne s'ouvre pas, `active` vaut nil et Nova reste sur les fichiers JSON (repli automatique).
final class FTSFlag: @unchecked Sendable { var ok = true }

public final class UltraDatabase {
    public static let jsonNS = "json"
    static let migrationKey = "migrated_json_v1"

    public static var flagEnabled: Bool {
        UserDefaults.standard.bool(forKey: "NovaSQLite") || ProcessInfo.processInfo.environment["NOVA_SQLITE"] == "1"
    }
    /// Miroir JSON (défaut : oui). Tant qu'il est actif, couper NovaSQLite ne perd rien.
    public static var mirrorJSON: Bool {
        (UserDefaults.standard.object(forKey: "NovaSQLiteMirrorJSON") as? Bool) ?? true
    }
    /// Base ouverte si l'interrupteur est actif, nil sinon (ou si l'ouverture a échoué).
    public static var active: UltraDatabase? { flagEnabled ? shared : nil }
    static let shared: UltraDatabase? = {
        let db = UltraDatabase(path: Paths.file("nova.sqlite").path)
        db?.migrateIfNeeded()
        return db
    }()
    /// Fichiers jamais copiés dans la base (coffre chiffré, jetons des appareils appairés, gros index reconstructible) : JSON seul.
    public static func eligible(_ name: String) -> Bool {
        !name.hasPrefix("vault_") && name != "bridge_devices.json" && name != "knowledge_index.json"
    }
    /// Attend la fin des écritures en file (fermeture de l'app).
    public static func drain() { if flagEnabled, let db = shared { db.q.sync {} } }

    /// Branche le pont SQLite de NovaFoundation (JSONFile/Journal) sur cette base — mêmes
    /// conditions qu'avant le découpage : base active (interrupteur) + fichier éligible.
    public static func registerSQLiteBridge() {
        SQLiteBridge.put = { name, data in
            guard let db = UltraDatabase.active, UltraDatabase.eligible(name) else { return false }
            return db.put(ns: UltraDatabase.jsonNS, key: name, value: data)
        }
        SQLiteBridge.get = { name in
            guard let db = UltraDatabase.active, UltraDatabase.eligible(name) else { return nil }
            return db.getWithTime(ns: UltraDatabase.jsonNS, key: name)
        }
        SQLiteBridge.mirrorJSON = { UltraDatabase.mirrorJSON }
        SQLiteBridge.drain = { UltraDatabase.drain() }
        SQLiteBridge.append = { ns, value in UltraDatabase.active?.append(ns: ns, value: value) }
    }

    public let path: String
    let q = DispatchQueue(label: "nova.sqlite", qos: .userInitiated)
    private var db: OpaquePointer? = nil
    private var stPut: OpaquePointer? = nil
    private var stGet: OpaquePointer? = nil
    private var stAppend: OpaquePointer? = nil
    /// Phase 8 : vrai si la table FTS5 chunks_fts a pu être créée (SQLite compilé avec FTS5). Sinon Knowledge garde son BM25 mémoire.
    public private(set) var ftsAvailable = false
    private var ftsGen = 0
    private let ftsGenLock = NSLock()

    init?(path: String) {
        self.path = path
        #if canImport(SQLite3)
        var h: OpaquePointer? = nil
        let flags = SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX
        guard sqlite3_open_v2(path, &h, flags, nil) == SQLITE_OK, h != nil else {
            if h != nil { sqlite3_close(h) }
            return nil
        }
        db = h
        let setup = [
            "PRAGMA journal_mode=WAL;",
            "PRAGMA synchronous=NORMAL;",
            "PRAGMA mmap_size=268435456;",
            "PRAGMA temp_store=MEMORY;",
            "PRAGMA busy_timeout=3000;",
            "CREATE TABLE IF NOT EXISTS kv(ns TEXT NOT NULL, k TEXT NOT NULL, v BLOB, ts REAL, PRIMARY KEY(ns, k));",
            "CREATE TABLE IF NOT EXISTS activity(id INTEGER PRIMARY KEY AUTOINCREMENT, ns TEXT NOT NULL, ts REAL, v BLOB);",
            "CREATE INDEX IF NOT EXISTS activity_ns ON activity(ns, id);",
        ]
        for sql in setup where sqlite3_exec(h, sql, nil, nil, nil) != SQLITE_OK {
            // journal_mode peut échouer sur un volume exotique : seules les tables sont indispensables
            if sql.hasPrefix("CREATE") { sqlite3_close(h); db = nil; return nil }
        }
        // FTS5 facultatif : l'échec de création (module absent) n'invalide JAMAIS la base, il désactive seulement le canal plein-texte.
        ftsAvailable = sqlite3_exec(h, "CREATE VIRTUAL TABLE IF NOT EXISTS chunks_fts USING fts5(chunk_id UNINDEXED, path UNINDEXED, title, content, tokenize='unicode61 remove_diacritics 2');", nil, nil, nil) == SQLITE_OK
        stPut = prepare("INSERT OR REPLACE INTO kv(ns, k, v, ts) VALUES(?, ?, ?, ?);")
        stGet = prepare("SELECT v, ts FROM kv WHERE ns = ? AND k = ?;")
        stAppend = prepare("INSERT INTO activity(ns, ts, v) VALUES(?, ?, ?);")
        if stPut == nil || stGet == nil || stAppend == nil { close(); return nil }
        #else
        return nil
        #endif
    }

    deinit { close() }

    func close() {
        #if canImport(SQLite3)
        for st in [stPut, stGet, stAppend] where st != nil { sqlite3_finalize(st) }
        stPut = nil; stGet = nil; stAppend = nil
        if db != nil { sqlite3_close(db) }
        db = nil
        #endif
    }

    #if canImport(SQLite3)
    /// SQLITE_TRANSIENT : SQLite copie immédiatement les octets liés (les tampons Swift sont temporaires).
    static let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

    private func prepare(_ sql: String) -> OpaquePointer? {
        var st: OpaquePointer? = nil
        guard sqlite3_prepare_v2(db, sql, -1, &st, nil) == SQLITE_OK else { return nil }
        return st
    }
    private func bindText(_ st: OpaquePointer?, _ i: Int32, _ s: String) {
        sqlite3_bind_text(st, i, s, -1, UltraDatabase.transient)
    }
    private func bindBlob(_ st: OpaquePointer?, _ i: Int32, _ d: Data) {
        if d.isEmpty { sqlite3_bind_zeroblob(st, i, 0); return }
        d.withUnsafeBytes { (p: UnsafeRawBufferPointer) -> Void in
            _ = sqlite3_bind_blob(st, i, p.baseAddress, Int32(p.count), UltraDatabase.transient)
        }
    }
    private func columnBlob(_ st: OpaquePointer?, _ i: Int32) -> Data {
        let n = Int(sqlite3_column_bytes(st, i))
        guard n > 0, let p = sqlite3_column_blob(st, i) else { return Data() }
        return Data(bytes: p, count: n)
    }
    /// À appeler sur q uniquement.
    private func putLocked(_ ns: String, _ key: String, _ value: Data, _ ts: Double) -> Bool {
        guard let st = stPut else { return false }
        sqlite3_reset(st); sqlite3_clear_bindings(st)
        bindText(st, 1, ns); bindText(st, 2, key); bindBlob(st, 3, value); sqlite3_bind_double(st, 4, ts)
        let rc = sqlite3_step(st)
        sqlite3_reset(st)
        return rc == SQLITE_DONE
    }
    private func exec(_ sql: String) -> Bool { sqlite3_exec(db, sql, nil, nil, nil) == SQLITE_OK }
    #endif

    // MARK: API clé/valeur

    @discardableResult
    public func put(ns: String, key: String, value: Data) -> Bool {
        #if canImport(SQLite3)
        let ts = Date().timeIntervalSince1970
        return q.sync { putLocked(ns, key, value, ts) }
        #else
        return false
        #endif
    }

    /// Plusieurs écritures dans UNE transaction (beaucoup plus rapide qu'une par une).
    @discardableResult
    public func putMany(ns: String, _ items: [(String, Data)]) -> Bool {
        #if canImport(SQLite3)
        let ts = Date().timeIntervalSince1970
        return q.sync { () -> Bool in
            guard exec("BEGIN IMMEDIATE;") else { return false }
            var ok = true
            for (k, v) in items where !putLocked(ns, k, v, ts) { ok = false; break }
            _ = exec(ok ? "COMMIT;" : "ROLLBACK;")
            return ok
        }
        #else
        return false
        #endif
    }

    public func get(ns: String, key: String) -> Data? { getWithTime(ns: ns, key: key)?.data }

    public func getWithTime(ns: String, key: String) -> (data: Data, ts: Double)? {
        #if canImport(SQLite3)
        return q.sync { () -> (data: Data, ts: Double)? in
            guard let st = stGet else { return nil }
            sqlite3_reset(st); sqlite3_clear_bindings(st)
            bindText(st, 1, ns); bindText(st, 2, key)
            guard sqlite3_step(st) == SQLITE_ROW else { return nil }
            let d = columnBlob(st, 0)
            let ts = sqlite3_column_double(st, 1)
            sqlite3_reset(st)
            return (data: d, ts: ts)
        }
        #else
        return nil
        #endif
    }

    // MARK: journal d'activité (append-only)

    /// Ajout asynchrone sur la file série dédiée : l'appelant n'attend jamais le disque.
    public func append(ns: String, value: Data) {
        #if canImport(SQLite3)
        let ts = Date().timeIntervalSince1970
        q.async { [self] in
            guard let st = stAppend else { return }
            sqlite3_reset(st); sqlite3_clear_bindings(st)
            bindText(st, 1, ns); sqlite3_bind_double(st, 2, ts); bindBlob(st, 3, value)
            _ = sqlite3_step(st)
            sqlite3_reset(st)
        }
        #endif
    }

    public func count(_ table: String) -> Int {
        #if canImport(SQLite3)
        guard table == "kv" || table == "activity" else { return 0 }
        return q.sync { () -> Int in
            var st: OpaquePointer? = nil
            guard sqlite3_prepare_v2(db, "SELECT COUNT(*) FROM \(table);", -1, &st, nil) == SQLITE_OK else { return 0 }
            defer { sqlite3_finalize(st) }
            return sqlite3_step(st) == SQLITE_ROW ? Int(sqlite3_column_int64(st, 0)) : 0
        }
        #else
        return 0
        #endif
    }

    // MARK: Phase 8 — index plein-texte FTS5 (chunks_fts)

    /// Option de compilation de la SQLite du système (information ; la création réussie de la table fait foi).
    public static func fts5Compiled() -> Bool {
        #if canImport(SQLite3)
        return sqlite3_compileoption_used("ENABLE_FTS5") != 0
        #else
        return false
        #endif
    }

    /// Remplace tout le contenu de chunks_fts (lignes : identifiant d'extrait, chemin, titre, texte) par lots, sur la file série q,
    /// sans la bloquer longtemps. `done(true)` seulement si aucune reconstruction plus récente n'a pris le relais et que tout s'est bien écrit.
    public func ftsRebuild(rows: [(id: Int, path: String, title: String, content: String)], done: @escaping (Bool) -> Void) {
        #if canImport(SQLite3)
        guard ftsAvailable else { done(false); return }
        ftsGenLock.lock(); ftsGen += 1; let gen = ftsGen; ftsGenLock.unlock()
        func stale() -> Bool { ftsGenLock.lock(); defer { ftsGenLock.unlock() }; return gen != ftsGen }
        let okBox = FTSFlag()
        q.async { [self] in if stale() { return }; okBox.ok = exec("DELETE FROM chunks_fts;") }
        let batch = 400
        var i = 0
        while i < rows.count {
            let slice = Array(rows[i..<min(i + batch, rows.count)]); i += batch
            q.async { [self] in
                if stale() || !okBox.ok { return }
                guard exec("BEGIN IMMEDIATE;") else { okBox.ok = false; return }
                var st: OpaquePointer? = nil
                guard sqlite3_prepare_v2(db, "INSERT INTO chunks_fts(chunk_id, path, title, content) VALUES(?, ?, ?, ?);", -1, &st, nil) == SQLITE_OK else { _ = exec("ROLLBACK;"); okBox.ok = false; return }
                for r in slice {
                    sqlite3_reset(st); sqlite3_clear_bindings(st)
                    sqlite3_bind_int64(st, 1, Int64(r.id)); bindText(st, 2, r.path); bindText(st, 3, r.title); bindText(st, 4, r.content)
                    if sqlite3_step(st) != SQLITE_DONE { okBox.ok = false; break }
                }
                sqlite3_finalize(st)
                _ = exec(okBox.ok ? "COMMIT;" : "ROLLBACK;")
            }
        }
        q.async { if stale() { return }; done(okBox.ok) }
        #else
        done(false)
        #endif
    }

    /// Recherche BM25 native FTS5. `match` est une expression MATCH déjà échappée. Retourne nil si FTS5 est indisponible ou la requête échoue
    /// (l'appelant retombe alors sur son BM25 mémoire) ; score = -bm25() (plus grand = meilleur).
    public func ftsSearch(match: String, limit: Int) -> [(id: Int, score: Double)]? {
        #if canImport(SQLite3)
        guard ftsAvailable, !match.isEmpty else { return nil }
        return q.sync { () -> [(id: Int, score: Double)]? in
            var st: OpaquePointer? = nil
            let sql = "SELECT chunk_id, -bm25(chunks_fts, 0.0, 0.0, 2.0, 1.0) AS s FROM chunks_fts WHERE chunks_fts MATCH ?1 ORDER BY s DESC LIMIT ?2;"
            guard sqlite3_prepare_v2(db, sql, -1, &st, nil) == SQLITE_OK else { return nil }
            defer { sqlite3_finalize(st) }
            bindText(st, 1, match); sqlite3_bind_int64(st, 2, Int64(limit))
            var out: [(id: Int, score: Double)] = []
            while true {
                let rc = sqlite3_step(st)
                if rc == SQLITE_ROW { out.append((Int(sqlite3_column_int64(st, 0)), sqlite3_column_double(st, 1))) }
                else if rc == SQLITE_DONE { break }
                else { return nil }
            }
            return out
        }
        #else
        return nil
        #endif
    }

    // MARK: migration (copie, jamais de suppression)

    /// Premier lancement avec l'interrupteur : copie chaque fichier d'état *.json (conversations, mémoire, ame_*…) dans kv,
    /// et les lignes des journaux *.jsonl dans activity. Les fichiers d'origine ne sont NI modifiés NI supprimés.
    func migrateIfNeeded() {
        #if canImport(SQLite3)
        if get(ns: "meta", key: UltraDatabase.migrationKey) != nil { return }
        let fm = FileManager.default
        let home = Paths.home
        let names = ((try? fm.contentsOfDirectory(atPath: home.path)) ?? []).sorted()
        var copied = 0, lines = 0
        q.sync { () -> Void in
            guard exec("BEGIN IMMEDIATE;") else { return }
            for n in names {
                let u = home.appendingPathComponent(n)
                let size = ((try? fm.attributesOfItem(atPath: u.path))?[.size] as? NSNumber)?.intValue ?? 0
                if size > 200_000_000 { continue }
                if n.hasSuffix(".json"), UltraDatabase.eligible(n), let d = try? Data(contentsOf: u) {
                    let mtime = ((try? fm.attributesOfItem(atPath: u.path))?[.modificationDate] as? Date)?.timeIntervalSince1970 ?? Date().timeIntervalSince1970
                    if putLocked(UltraDatabase.jsonNS, n, d, mtime) { copied += 1 }
                } else if n.hasSuffix(".jsonl"), let st = stAppend, let txt = try? String(contentsOf: u, encoding: .utf8) {
                    for l in txt.split(separator: "\n").suffix(20000) {
                        sqlite3_reset(st); sqlite3_clear_bindings(st)
                        bindText(st, 1, n); sqlite3_bind_double(st, 2, 0); bindBlob(st, 3, Data(l.utf8))
                        if sqlite3_step(st) == SQLITE_DONE { lines += 1 }
                    }
                    sqlite3_reset(st)
                }
            }
            let info: [String: Any] = ["ts": nowISO(), "files": copied, "lines": lines]
            let marker = jsonData(info)
            if putLocked("meta", UltraDatabase.migrationKey, marker, Date().timeIntervalSince1970) { _ = exec("COMMIT;") } else { _ = exec("ROLLBACK;") }
        }
        #endif
    }

    // MARK: mesure (GET /api/system/selftest)

    /// Base jetable dans le dossier temporaire : n écritures en une transaction, n écritures unitaires, n lectures.
    public static func benchmark(n: Int = 1000) -> [String: Any] {
        #if canImport(SQLite3)
        let p = NSTemporaryDirectory() + "nova-selftest-\(UUID().uuidString.prefix(8)).sqlite"
        defer { for suf in ["", "-wal", "-shm"] { try? FileManager.default.removeItem(atPath: p + suf) } }
        guard let db = UltraDatabase(path: p) else { return ["ok": false, "error": "ouverture SQLite impossible"] }
        defer { db.close() }
        let payload = jsonData(["text": String(repeating: "Nova ", count: 40), "n": 42])
        var t = Date()
        let items = (0..<n).map { ("k\($0)", payload) }
        let okMany = db.putMany(ns: "bench", items)
        let txMs = Date().timeIntervalSince(t) * 1000
        t = Date()
        var okOne = 0
        for i in 0..<min(n, 200) where db.put(ns: "bench1", key: "k\(i)", value: payload) { okOne += 1 }
        let oneMs = Date().timeIntervalSince(t) * 1000 / Double(max(1, min(n, 200)))
        t = Date()
        var hits = 0
        for i in 0..<n where db.get(ns: "bench", key: "k\(i)") != nil { hits += 1 }
        let readMs = Date().timeIntervalSince(t) * 1000
        func r(_ x: Double) -> Double { (x * 1000).rounded() / 1000 }
        return ["ok": okMany && hits == n && okOne == min(n, 200), "n": n, "ecriture_transaction_ms": r(txMs), "ecriture_unitaire_ms_moy": r(oneMs),
                "lecture_ms_total": r(readMs), "lecture_us_moy": r(readMs * 1000 / Double(max(1, n))), "payload_octets": payload.count]
        #else
        return ["ok": false, "error": "SQLite3 indisponible sur cette plateforme"]
        #endif
    }

    public static func status() -> [String: Any] {
        var o: [String: Any] = ["flag": flagEnabled, "mirror_json": mirrorJSON, "fts5_compiled": fts5Compiled()]
        if let db = active {
            o["open"] = true; o["fts5"] = db.ftsAvailable; o["path"] = db.path; o["kv"] = db.count("kv"); o["activity"] = db.count("activity")
            if let m = db.get(ns: "meta", key: migrationKey), let j = parseJSON(m) { o["migration"] = j }
        } else { o["open"] = false }
        return o
    }
}

/// Auto-test (GET /api/system/selftest) : chiffres réels mesurés sur la machine, pour valider les interrupteurs sur le Mac.
public enum NovaSelfTest {
    public static func run(server: HTTPServer) -> [String: Any] {
        let t0 = Date()
        var out: [String: Any] = ["ts": nowISO()]
        let flags: [String: Any] = [
            "NovaIPC": UserDefaults.standard.bool(forKey: "NovaIPC") || ProcessInfo.processInfo.environment["NOVA_IPC"] == "1",
            "NovaIsolation": HTTPServer.isolationEnabled, "NovaIsolationCOEP": HTTPServer.coepValue,
            "NovaSQLite": UltraDatabase.flagEnabled, "NovaVectors": UltraVectorIndex.enabled,
        ]
        out["interrupteurs"] = flags
        // dispatchDirect : même routage que HTTP, sans socket (moyenne sur 20 appels d'une route légère)
        var ok = 0
        let td = Date()
        for _ in 0..<20 {
            let r = server.dispatchDirect(method: "GET", path: "/api/memory/settings", query: "", headers: ["x-nova-token": server.token], body: Data())
            if r.status == 200 { ok += 1 }
        }
        let dd: [String: Any] = ["ok": ok == 20, "ms_moy": (Date().timeIntervalSince(td) * 1000 / 20 * 1000).rounded() / 1000]
        out["dispatch_direct"] = dd
        out["sqlite_bench"] = UltraDatabase.benchmark()
        out["sqlite"] = UltraDatabase.status()
        out["vecteurs"] = UltraVectorIndex.shared.selftest()
        out["total_ms"] = Int(Date().timeIntervalSince(t0) * 1000)
        return out
    }
}
