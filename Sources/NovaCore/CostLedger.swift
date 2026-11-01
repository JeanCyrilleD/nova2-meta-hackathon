import Foundation
import NovaFoundation
#if canImport(SQLite3)
import SQLite3   // libsqlite3 du système macOS (même module qu'UltraDatabase) : aucune dépendance SPM
#endif
#if canImport(CryptoKit)
import CryptoKit
#endif

// PHASE 2 (brief 2.5) — grand livre des coûts, réservations atomiques, empreintes d'entrée.
//
// Choix du stockage : SQLite en WAL (libsqlite3 du système, déjà utilisée par UltraDatabase), fichier dédié
// <données Nova>/couts_v2.sqlite. Pourquoi pas le magasin JSON existant : JSONFile écrit en DIFFÉRÉ (~150 ms, Util.swift)
// et ne verrouille qu'à l'intérieur du processus — une réservation pourrait être perdue au plantage, et deux processus
// (app + outil) pourraient réserver la même marge. Ici : chaque réservation est une transaction BEGIN IMMEDIATE
// (verrou d'écriture SQLite, valable entre fils ET entre processus) + un NSLock pour la connexion partagée ;
// synchronous=FULL : une réservation validée survit à un plantage ou à une coupure.
//
// États d'une ligne : reserved (envoi en cours) · settled (usage rapporté, coût réel) · kept (usage absent : la réservation
// reste comptée — usage absent ≠ gratuit) · released (preuve que rien n'a été facturé : refus 4xx avant traitement).
// Montant engagé d'une ligne = actual si settled, sinon reserved (reserved/kept) ; released = 0.

public final class CostLedger {
    public struct Caps {
        public var monthHard: Micros, dayForeground: Micros, dayBackground: Micros, perTask: Micros
        /// WP2 : plafond du jour de la voie « bench » (banc de qualité) ; nil = celui du premier plan.
        public var dayBench: Micros?
        public init(monthHard: Micros, dayForeground: Micros, dayBackground: Micros, perTask: Micros, dayBench: Micros? = nil) {
            self.monthHard = monthHard; self.dayForeground = dayForeground; self.dayBackground = dayBackground; self.perTask = perTask
            self.dayBench = dayBench
        }
        public init(_ r: BrainRegistry) {
            self.init(monthHard: r.monthlyHardCap, dayForeground: r.dayCapForeground, dayBackground: r.dayCapBackground, perTask: r.perTaskCap)
        }
    }
    public enum Reservation: Equatable {
        case reserved(String)
        case refused(String)
        public var id: String? { if case .reserved(let i) = self { return i }; return nil }
    }

    public let path: String
    let lock = NSLock()
    #if canImport(SQLite3)
    private var db: OpaquePointer? = nil
    static let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
    #endif

    public init?(path: String) {
        self.path = path
        #if canImport(SQLite3)
        var h: OpaquePointer? = nil
        guard sqlite3_open_v2(path, &h, SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX, nil) == SQLITE_OK, h != nil else {
            if h != nil { sqlite3_close(h) }
            return nil
        }
        db = h
        sqlite3_busy_timeout(h, 5000)
        let setup: [String] = [
            "PRAGMA journal_mode=WAL;",
            "PRAGMA synchronous=FULL;",
            """
            CREATE TABLE IF NOT EXISTS ledger(
              id TEXT PRIMARY KEY, ts REAL NOT NULL, day TEXT NOT NULL, month TEXT NOT NULL, task TEXT NOT NULL, lane TEXT NOT NULL,
              brain TEXT NOT NULL, profile TEXT NOT NULL, data_class TEXT NOT NULL, state TEXT NOT NULL,
              reserved INTEGER NOT NULL, actual INTEGER, in_tok INTEGER, cache_read INTEGER, cache_write INTEGER, out_tok INTEGER,
              reasoning_tok INTEGER, tools TEXT, retries INTEGER DEFAULT 0, fallbacks INTEGER DEFAULT 0, note TEXT, settled_ts REAL);
            """,
            "CREATE INDEX IF NOT EXISTS ledger_month ON ledger(month, state);",
            "CREATE INDEX IF NOT EXISTS ledger_day ON ledger(day, lane, state);",
            "CREATE INDEX IF NOT EXISTS ledger_task ON ledger(task, state);",
            "CREATE TABLE IF NOT EXISTS fingerprints(k TEXT PRIMARY KEY, hash TEXT NOT NULL, result TEXT, ts REAL);",
            "CREATE TABLE IF NOT EXISTS alerts(month TEXT NOT NULL, pct INTEGER NOT NULL, ts REAL, PRIMARY KEY(month, pct));",
        ]
        for sql in setup where sqlite3_exec(h, sql, nil, nil, nil) != SQLITE_OK {
            if !sql.hasPrefix("PRAGMA") { sqlite3_close(h); db = nil; return nil }
        }
        // WP2 — migration versionnée 1 (PRAGMA user_version), additive et réversible : colonnes nullables ignorées par le code v2,
        // table des dérogations. Retour arrière : ALTER TABLE ledger DROP COLUMN … (SQLite ≥ 3.35) ; DROP TABLE overrides ;
        // PRAGMA user_version=0. Les lignes du chemin v1 portent profile LIKE 'v1%' (DELETE FROM ledger WHERE profile LIKE 'v1%').
        if (int("PRAGMA user_version;", []) ?? 0) < 1 {
            for col in ["billing TEXT", "price_version TEXT", "measure TEXT", "override_id TEXT"] {
                _ = sqlite3_exec(h, "ALTER TABLE ledger ADD COLUMN \(col);", nil, nil, nil)   // colonne déjà là (migration rejouée) : sans effet
            }
            let ok: Bool = sqlite3_exec(h, """
                CREATE TABLE IF NOT EXISTS overrides(id TEXT PRIMARY KEY, created REAL NOT NULL, expires REAL NOT NULL, max INTEGER NOT NULL,
                  used INTEGER NOT NULL DEFAULT 0, lanes TEXT NOT NULL, reason TEXT NOT NULL, actor TEXT NOT NULL, revoked INTEGER NOT NULL DEFAULT 0);
                """, nil, nil, nil) == SQLITE_OK
            guard ok, sqlite3_exec(h, "PRAGMA user_version=1;", nil, nil, nil) == SQLITE_OK else { sqlite3_close(h); db = nil; return nil }
        }
        #else
        return nil
        #endif
    }
    deinit {
        #if canImport(SQLite3)
        if db != nil { sqlite3_close(db) }
        #endif
    }

    #if canImport(SQLite3)
    // MARK: - Petits outils SQLite (appelés sous `lock`)

    private func exec(_ sql: String) -> Bool { sqlite3_exec(db, sql, nil, nil, nil) == SQLITE_OK }
    private enum Arg { case t(String), i(Int64), d(Double), null }
    private func run(_ sql: String, _ args: [Arg]) -> Bool {
        var st: OpaquePointer? = nil
        guard sqlite3_prepare_v2(db, sql, -1, &st, nil) == SQLITE_OK else { return false }
        defer { sqlite3_finalize(st) }
        bind(st, args)
        return sqlite3_step(st) == SQLITE_DONE
    }
    private func bind(_ st: OpaquePointer?, _ args: [Arg]) {
        for (n, a) in args.enumerated() {
            let i = Int32(n + 1)
            switch a {
            case .t(let s): sqlite3_bind_text(st, i, s, -1, CostLedger.transient)
            case .i(let v): sqlite3_bind_int64(st, i, v)
            case .d(let v): sqlite3_bind_double(st, i, v)
            case .null: sqlite3_bind_null(st, i)
            }
        }
    }
    private func int(_ sql: String, _ args: [Arg]) -> Int64? {
        var st: OpaquePointer? = nil
        guard sqlite3_prepare_v2(db, sql, -1, &st, nil) == SQLITE_OK else { return nil }
        defer { sqlite3_finalize(st) }
        bind(st, args)
        guard sqlite3_step(st) == SQLITE_ROW else { return nil }
        return sqlite3_column_int64(st, 0)
    }
    private func text2(_ sql: String, _ args: [Arg]) -> (String, String?)? {
        var st: OpaquePointer? = nil
        guard sqlite3_prepare_v2(db, sql, -1, &st, nil) == SQLITE_OK else { return nil }
        defer { sqlite3_finalize(st) }
        bind(st, args)
        guard sqlite3_step(st) == SQLITE_ROW, let a = sqlite3_column_text(st, 0) else { return nil }
        let b: String? = sqlite3_column_text(st, 1).map { String(cString: $0) }
        return (String(cString: a), b)
    }
    static let committedExpr: String = "COALESCE(SUM(CASE WHEN state='settled' THEN COALESCE(actual, reserved) WHEN state IN ('reserved','kept') THEN reserved ELSE 0 END), 0)"
    private func committedLocked(month: String) -> Micros { int("SELECT \(CostLedger.committedExpr) FROM ledger WHERE month=?;", [.t(month)]) ?? Int64.max }
    private func committedLocked(day: String, lane: String) -> Micros { int("SELECT \(CostLedger.committedExpr) FROM ledger WHERE day=? AND lane=?;", [.t(day), .t(lane)]) ?? Int64.max }
    private func committedLocked(task: String) -> Micros { int("SELECT \(CostLedger.committedExpr) FROM ledger WHERE task=?;", [.t(task)]) ?? Int64.max }
    #endif

    // MARK: - Réservation atomique (avant envoi)

    /// Réserve `estimate` contre les plafonds mois (UTC), jour (par voie : fond / premier plan) et tâche, en une transaction
    /// BEGIN IMMEDIATE : deux réservations concurrentes ne peuvent jamais consommer la même marge. Lecture illisible → refus.
    ///
    /// WP2 (chemin v1) : `floorMonth` / `floorDay` = planchers conservateurs (dépense déjà comptée ailleurs, ex. depenses_llm.json) :
    /// engagé = max(grand livre, plancher). `overrideId` : dérogation délibérée — ne lève QUE les plafonds mois/jour, dans la limite
    /// de son reste, avant son expiration et pour sa voie ; jamais le plafond par tâche ni un grand livre illisible.
    public func reserve(task: String, lane: Lane, brain: String, profile: String, dataClass: DataClass, estimate: Micros,
                        caps: Caps, now: Date = Date(), floorMonth: Micros = 0, floorDay: Micros = 0, overrideId: String? = nil,
                        billing: String? = nil, priceVersion: String? = nil) -> Reservation {
        #if canImport(SQLite3)
        guard estimate >= 0 else { return .refused("estimation négative") }
        lock.lock(); defer { lock.unlock() }
        guard exec("BEGIN IMMEDIATE;") else { return .refused("grand livre occupé ou illisible : rien n'est envoyé") }
        let day: String = PeakWindows.dayKey(now), month: String = PeakWindows.monthKey(now)
        let m0: Micros = committedLocked(month: month)
        let d0: Micros = committedLocked(day: day, lane: lane.rawValue)
        let t: Micros = committedLocked(task: task)
        let m: Micros = m0 == Int64.max ? m0 : max(m0, floorMonth)
        let d: Micros = d0 == Int64.max ? d0 : max(d0, floorDay)
        let dayCap: Micros = lane == .background ? caps.dayBackground : (lane == .bench ? (caps.dayBench ?? caps.dayForeground) : caps.dayForeground)
        var refusal: String? = nil
        var capOnly: Bool = false   // refus dû SEULEMENT au plafond mois / jour (seul cas qu'une dérogation peut lever)
        if m == Int64.max || d == Int64.max || t == Int64.max { refusal = "grand livre illisible : rien n'est envoyé" }
        else if m + estimate > caps.monthHard { refusal = "plafond du mois : \(Money.format(m)) engagés + \(Money.format(estimate)) > \(Money.format(caps.monthHard))"; capOnly = true }
        else if d + estimate > dayCap { refusal = "plafond du jour (\(lane.rawValue)) : \(Money.format(d)) + \(Money.format(estimate)) > \(Money.format(dayCap))"; capOnly = true }
        else if t + estimate > caps.perTask { refusal = "plafond par tâche : \(Money.format(t)) + \(Money.format(estimate)) > \(Money.format(caps.perTask))" }
        var usedOverride: String? = nil
        if let r = refusal, capOnly, let oid = overrideId {
            if t + estimate > caps.perTask { refusal = r + " — et plafond par tâche dépassé : aucune dérogation ne le lève" }
            else if let o = overrideLocked(oid), o.revoked == false, now < o.expires, o.lanes.contains(lane), o.used + estimate <= o.max {
                usedOverride = oid
                refusal = nil
            } else {
                refusal = r + " — dérogation \(oid.prefix(8)) expirée, révoquée, épuisée ou hors voie"
            }
        }
        if let r = refusal { _ = exec("ROLLBACK;"); return .refused(r) }
        let id: String = UUID().uuidString.lowercased()
        var ok: Bool = run("INSERT INTO ledger(id, ts, day, month, task, lane, brain, profile, data_class, state, reserved, billing, price_version, override_id) VALUES(?,?,?,?,?,?,?,?,?, 'reserved', ?,?,?,?);",
                           [.t(id), .d(now.timeIntervalSince1970), .t(day), .t(month), .t(task), .t(lane.rawValue), .t(brain), .t(profile), .t(dataClass.rawValue), .i(estimate),
                            (billing.map { Arg.t($0) } ?? Arg.null), (priceVersion.map { Arg.t($0) } ?? Arg.null), (usedOverride.map { Arg.t($0) } ?? Arg.null)])
        if ok, let oid = usedOverride { ok = run("UPDATE overrides SET used = used + ? WHERE id=?;", [.i(estimate), .t(oid)]) }
        guard ok, exec("COMMIT;") else { _ = exec("ROLLBACK;"); return .refused("écriture du grand livre impossible : rien n'est envoyé") }
        return .reserved(id)
        #else
        return .refused("SQLite indisponible")
        #endif
    }

    /// Solde avec l'usage rapporté. `usage` nil ou vide → la réservation est GARDÉE (état kept), jamais comptée gratuite.
    /// WP2 : `measure` = « measured » (usage rapporté par le fournisseur) ou « estimated » (jetons comptés par Nova) — conservé tel quel.
    public func settle(_ id: String, usage: Usage?, cost: Micros?, tools: [String: Int] = [:], retries: Int = 0, fallbacks: Int = 0, now: Date = Date(),
                       measure: String = "measured") {
        #if canImport(SQLite3)
        lock.lock(); defer { lock.unlock() }
        let toolsJSON: String = jsonString(tools)
        if let u = usage, !u.isEmpty, let c = cost {
            _ = run("UPDATE ledger SET state='settled', actual=?, in_tok=?, cache_read=?, cache_write=?, out_tok=?, reasoning_tok=?, tools=?, retries=?, fallbacks=?, settled_ts=?, measure=? WHERE id=? AND state IN ('reserved','kept');",
                    [.i(c), .i(Int64(u.inputTokens)), .i(Int64(u.cacheRead)), .i(Int64(u.cacheWrite5m + u.cacheWrite1h)), .i(Int64(u.outputTokens)),
                     .i(Int64(u.reasoningTokens)), .t(toolsJSON), .i(Int64(retries)), .i(Int64(fallbacks)), .d(now.timeIntervalSince1970), .t(measure), .t(id)])
        } else {
            _ = run("UPDATE ledger SET state='kept', tools=?, retries=?, fallbacks=?, note='usage absent : réservation gardée', settled_ts=? WHERE id=? AND state='reserved';",
                    [.t(toolsJSON), .i(Int64(retries)), .i(Int64(fallbacks)), .d(now.timeIntervalSince1970), .t(id)])
        }
        #endif
    }

    /// Libère une réservation SEULEMENT quand rien n'a pu être facturé (refus du fournisseur avant traitement : clé, crédit, modèle).
    public func release(_ id: String, reason: String) {
        #if canImport(SQLite3)
        lock.lock(); defer { lock.unlock() }
        guard exec("BEGIN IMMEDIATE;") else { return }
        let oid: String? = text2("SELECT state, override_id FROM ledger WHERE id=?;", [.t(id)]).flatMap { $0.0 == "reserved" ? $0.1 : nil }
        let amount: Micros = int("SELECT reserved FROM ledger WHERE id=? AND state='reserved';", [.t(id)]) ?? 0
        var ok: Bool = run("UPDATE ledger SET state='released', note=?, settled_ts=? WHERE id=? AND state='reserved';", [.t(reason), .d(Date().timeIntervalSince1970), .t(id)])
        if ok, let o = oid, amount > 0 { ok = run("UPDATE overrides SET used = MAX(0, used - ?) WHERE id=?;", [.i(amount), .t(o)]) }   // rien facturé : la dérogation retrouve sa part
        _ = exec(ok ? "COMMIT;" : "ROLLBACK;")
        #endif
    }

    // MARK: - WP2 : ligne, solde d'ouverture v1, réservations orphelines

    public struct Row { public var state: String; public var reserved: Micros; public var actual: Micros?; public var measure: String?; public var billing: String?; public var overrideId: String?; public var lane: String }
    public func row(_ id: String) -> Row? {
        #if canImport(SQLite3)
        lock.lock(); defer { lock.unlock() }
        var st: OpaquePointer? = nil
        guard sqlite3_prepare_v2(db, "SELECT state, reserved, actual, measure, billing, override_id, lane FROM ledger WHERE id=?;", -1, &st, nil) == SQLITE_OK else { return nil }
        defer { sqlite3_finalize(st) }
        bind(st, [.t(id)])
        guard sqlite3_step(st) == SQLITE_ROW else { return nil }
        func txt(_ i: Int32) -> String? { sqlite3_column_text(st, i).map { String(cString: $0) } }
        return Row(state: txt(0) ?? "", reserved: sqlite3_column_int64(st, 1),
                   actual: sqlite3_column_type(st, 2) == SQLITE_NULL ? nil : sqlite3_column_int64(st, 2),
                   measure: txt(3), billing: txt(4), overrideId: txt(5), lane: txt(6) ?? "")
        #else
        return nil
        #endif
    }

    /// Reprise UNIQUE (une seule fois pour toute la vie du fichier) de la dépense déjà comptée par l'ancien compteur JSON :
    /// une ligne « mois » (voie « opening », hors plafonds du jour) + aujourd'hui fond et banc. Idempotent (ids fixes).
    /// Rend vrai si la reprise vient d'être écrite.
    @discardableResult
    public func seedOpeningOnce(monthOther: Micros, dayBackground: Micros, dayBench: Micros, now: Date = Date()) -> Bool {
        #if canImport(SQLite3)
        lock.lock(); defer { lock.unlock() }
        guard exec("BEGIN IMMEDIATE;") else { return false }
        if (int("SELECT COUNT(*) FROM ledger WHERE id='v1-ouverture-mois';", []) ?? 1) > 0 { _ = exec("ROLLBACK;"); return false }
        let day: String = PeakWindows.dayKey(now), month: String = PeakWindows.monthKey(now)
        var ok: Bool = true
        for (id, lane, amt) in [("v1-ouverture-mois", "opening", monthOther), ("v1-ouverture-fond", Lane.background.rawValue, dayBackground), ("v1-ouverture-banc", Lane.bench.rawValue, dayBench)] where ok {
            ok = run("INSERT OR IGNORE INTO ledger(id, ts, day, month, task, lane, brain, profile, data_class, state, reserved, actual, note, settled_ts, billing, measure) VALUES(?,?,?,?, 'ouverture-v1', ?, 'ouverture_v1', 'v1-ouverture', 'personal', 'settled', ?, ?, 'reprise unique de depenses_llm.json', ?, 'metered', 'measured');",
                     [.t(id), .d(now.timeIntervalSince1970), .t(day), .t(month), .t(lane), .i(max(0, amt)), .i(max(0, amt)), .d(now.timeIntervalSince1970)])
        }
        _ = exec(ok ? "COMMIT;" : "ROLLBACK;")
        return ok
        #else
        return false
        #endif
    }

    /// Réservations restées « reserved » au-delà de `olderThan` secondes (plantage, fil abandonné) → « kept » : toujours comptées,
    /// jamais rendues gratuites. Rend le nombre de lignes passées en kept.
    @discardableResult
    public func sweepStale(olderThan: TimeInterval, now: Date = Date()) -> Int {
        #if canImport(SQLite3)
        lock.lock(); defer { lock.unlock() }
        guard run("UPDATE ledger SET state='kept', note='réservation orpheline (plantage ou abandon) : gardée', settled_ts=? WHERE state='reserved' AND ts < ?;",
                  [.d(now.timeIntervalSince1970), .d(now.timeIntervalSince1970 - olderThan)]) else { return 0 }
        return Int(sqlite3_changes(db))
        #else
        return 0
        #endif
    }

    // MARK: - WP2 : dérogations (délibérées, bornées, expirantes, journalisées)

    public struct Override { public var id: String; public var created: Date; public var expires: Date; public var max: Micros; public var used: Micros; public var lanes: Set<Lane>; public var reason: String; public var actor: String; public var revoked: Bool
        public var remaining: Micros { Swift.max(0, max - used) }
    }
    #if canImport(SQLite3)
    private func overrideLocked(_ id: String) -> Override? {
        var st: OpaquePointer? = nil
        guard sqlite3_prepare_v2(db, "SELECT id, created, expires, max, used, lanes, reason, actor, revoked FROM overrides WHERE id=?;", -1, &st, nil) == SQLITE_OK else { return nil }
        defer { sqlite3_finalize(st) }
        bind(st, [.t(id)])
        guard sqlite3_step(st) == SQLITE_ROW else { return nil }
        return overrideFrom(st)
    }
    private func overrideFrom(_ st: OpaquePointer?) -> Override {
        func txt(_ i: Int32) -> String { sqlite3_column_text(st, i).map { String(cString: $0) } ?? "" }
        let lanes: Set<Lane> = Set(txt(5).split(separator: ",").compactMap { Lane(rawValue: String($0)) })
        return Override(id: txt(0), created: Date(timeIntervalSince1970: sqlite3_column_double(st, 1)), expires: Date(timeIntervalSince1970: sqlite3_column_double(st, 2)),
                        max: sqlite3_column_int64(st, 3), used: sqlite3_column_int64(st, 4), lanes: lanes, reason: txt(6), actor: txt(7), revoked: sqlite3_column_int64(st, 8) != 0)
    }
    #endif
    /// Écrit une dérogation. Les bornes (montant, durée, voies) sont vérifiées par l'appelant (LLMSpend.grantOverride) ; ici : max > 0,
    /// expiration future, au moins une voie, motif non vide. Rend l'id, nil si refusée.
    public func grantOverride(max: Micros, until: Date, lanes: Set<Lane>, reason: String, actor: String, now: Date = Date()) -> String? {
        #if canImport(SQLite3)
        let why: String = reason.trimmingCharacters(in: .whitespacesAndNewlines)
        guard max > 0, until > now, !lanes.isEmpty, !why.isEmpty else { return nil }
        lock.lock(); defer { lock.unlock() }
        let id: String = UUID().uuidString.lowercased()
        let ls: String = lanes.map { $0.rawValue }.sorted().joined(separator: ",")
        guard run("INSERT INTO overrides(id, created, expires, max, used, lanes, reason, actor, revoked) VALUES(?,?,?,?,0,?,?,?,0);",
                  [.t(id), .d(now.timeIntervalSince1970), .d(until.timeIntervalSince1970), .i(max), .t(ls), .t(String(why.prefix(200))), .t(String(actor.prefix(40)))]) else { return nil }
        return id
        #else
        return nil
        #endif
    }
    public func overrideInfo(_ id: String) -> Override? {
        #if canImport(SQLite3)
        lock.lock(); defer { lock.unlock() }; return overrideLocked(id)
        #else
        return nil
        #endif
    }
    /// Dérogation utilisable maintenant pour cette voie (non révoquée, non expirée, reste > 0) — la plus récente.
    public func activeOverride(lane: Lane, now: Date = Date()) -> Override? {
        overrides(limit: 50).first { !$0.revoked && now < $0.expires && $0.lanes.contains(lane) && $0.remaining > 0 }
    }
    public func revokeOverride(_ id: String) -> Bool {
        #if canImport(SQLite3)
        lock.lock(); defer { lock.unlock() }
        return run("UPDATE overrides SET revoked=1 WHERE id=?;", [.t(id)]) && sqlite3_changes(db) > 0
        #else
        return false
        #endif
    }
    /// Journal des dérogations (plus récentes d'abord) — audit.
    public func overrides(limit: Int = 20) -> [Override] {
        #if canImport(SQLite3)
        lock.lock(); defer { lock.unlock() }
        var st: OpaquePointer? = nil
        guard sqlite3_prepare_v2(db, "SELECT id, created, expires, max, used, lanes, reason, actor, revoked FROM overrides ORDER BY created DESC LIMIT ?;", -1, &st, nil) == SQLITE_OK else { return [] }
        defer { sqlite3_finalize(st) }
        bind(st, [.i(Int64(max(1, limit)))])
        var out: [Override] = []
        while sqlite3_step(st) == SQLITE_ROW { out.append(overrideFrom(st)) }
        return out
        #else
        return []
        #endif
    }

    // MARK: - Lectures (tableau de bord, tests)

    public func committed(month: String) -> Micros {
        #if canImport(SQLite3)
        lock.lock(); defer { lock.unlock() }; return committedLocked(month: month)
        #else
        return 0
        #endif
    }
    public func committed(day: String, lane: Lane) -> Micros {
        #if canImport(SQLite3)
        lock.lock(); defer { lock.unlock() }; return committedLocked(day: day, lane: lane.rawValue)
        #else
        return 0
        #endif
    }
    public func committed(task: String) -> Micros {
        #if canImport(SQLite3)
        lock.lock(); defer { lock.unlock() }; return committedLocked(task: task)
        #else
        return 0
        #endif
    }
    public func state(_ id: String) -> String? {
        #if canImport(SQLite3)
        lock.lock(); defer { lock.unlock() }
        return text2("SELECT state, note FROM ledger WHERE id=?;", [.t(id)])?.0
        #else
        return nil
        #endif
    }
    public func budgetView(task: String, lane: Lane, now: Date = Date()) -> BudgetView {
        BudgetView(month: committed(month: PeakWindows.monthKey(now)), day: committed(day: PeakWindows.dayKey(now), lane: lane), task: committed(task: task))
    }

    /// Seuils d'alerte (en % du plafond dur) franchis pour la PREMIÈRE fois ce mois-ci — chaque seuil n'est rendu qu'une fois.
    public func newlyCrossedAlerts(thresholdsPct: [Int], cap: Micros, now: Date = Date()) -> [Int] {
        #if canImport(SQLite3)
        let month: String = PeakWindows.monthKey(now)
        lock.lock(); defer { lock.unlock() }
        let c: Micros = committedLocked(month: month)
        guard c != Int64.max, cap > 0 else { return [] }
        var out: [Int] = []
        for p in thresholdsPct.sorted() where c * 100 >= cap * Int64(p) {
            if int("SELECT COUNT(*) FROM alerts WHERE month=? AND pct=?;", [.t(month), .i(Int64(p))]) == 0,
               run("INSERT OR IGNORE INTO alerts(month, pct, ts) VALUES(?,?,?);", [.t(month), .i(Int64(p)), .d(now.timeIntervalSince1970)]) { out.append(p) }
        }
        return out
        #else
        return []
        #endif
    }

    // MARK: - Empreinte d'entrée (brief 2.5.6) : entrée inchangée → résultat réutilisé, zéro appel

    public func fingerprint(_ key: String) -> (hash: String, result: String?)? {
        #if canImport(SQLite3)
        lock.lock(); defer { lock.unlock() }
        return text2("SELECT hash, result FROM fingerprints WHERE k=?;", [.t(key)]).map { (hash: $0.0, result: $0.1) }
        #else
        return nil
        #endif
    }
    public func storeFingerprint(_ key: String, hash: String, result: String) {
        #if canImport(SQLite3)
        lock.lock(); defer { lock.unlock() }
        _ = run("INSERT OR REPLACE INTO fingerprints(k, hash, result, ts) VALUES(?,?,?,?);", [.t(key), .t(hash), .t(result), .d(Date().timeIntervalSince1970)])
        #endif
    }
    /// Exécute `call` seulement si l'empreinte de `parts` a changé depuis le dernier résultat réussi de `key`.
    /// Un résultat nil (échec) n'est jamais mémorisé.
    public func reuseIfUnchanged(key: String, parts: [String], call: () -> String?) -> (result: String?, reused: Bool) {
        let h: String = InputFingerprint.of(parts)
        if let f = fingerprint(key), f.hash == h, let r = f.result { return (r, true) }
        let r: String? = call()
        if let rr = r { storeFingerprint(key, hash: h, result: rr) }
        return (r, false)
    }
}

public enum InputFingerprint {
    /// SHA-256 hexadécimal de parties préfixées par leur longueur (« ab|c » ≠ « a|bc »).
    public static func of(_ parts: [String]) -> String {
        var d = Data()
        for p in parts {
            let b = Data(p.utf8)
            d.append(Data(String(b.count).utf8)); d.append(0x3A); d.append(b); d.append(0x0A)
        }
        #if canImport(CryptoKit)
        return SHA256.hash(data: d).map { String(format: "%02x", $0) }.joined()
        #else
        return String(d.hashValue)
        #endif
    }
}
