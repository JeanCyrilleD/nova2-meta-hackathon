import Foundation
#if canImport(SQLite3)
import SQLite3
#endif

// WP3 + WP4 (31/10) — APPROBATION UNIQUE LIÉE À L'ACTION EXACTE, ÉTAT D'ENVOI DURABLE ET IDEMPOTENT.
//
// Avant : fenêtres GLOBALES du processus (Tools.sendUntil / sendAllowed posée par le moteur sur un simple
// verbe « envoie », Tools.frontUntil, Tools.freeUntil) et garde « inFlight » en mémoire. Une fenêtre ouverte
// dans la conversation A valait pour B, pour un Dot lancé pendant les 3 minutes, pour un brouillon modifié.
//
// Maintenant :
//   • ExecContext : contexte d'exécution LIMITÉ AU RUN (thread du tour), posé par la route du chat, remplacé
//     par un contexte « dot » pendant un Dot (Dots.run) — un Dot n'hérite jamais de l'approbation d'Ahadi.
//   • SendApprovals : service UNIQUE (chat, voix, bouton de l'interface). Une approbation lie : id d'action,
//     conversation / run / tour, brouillon + révision, canal, destinataires résolus exacts, expéditeur,
//     instantané objet / corps / pièces jointes (empreintes SHA-256 — même machinerie qu'AgentsV2 : Sha),
//     expiration, nonce à usage unique, source. Consommation atomique ; tout changement matériel change
//     l'empreinte, donc la clé d'idempotence, donc exige une nouvelle approbation.
//   • Un verbe « envoie » n'autorise rien : il DEMANDE l'approbation. La confirmation explicite d'Ahadi au
//     message qui SUIT la carte « Envoi à approuver » (affichée par le moteur, pas par le modèle) approuve
//     EXACTEMENT l'action affichée — pas de seconde confirmation.
//   • Sources qui ne peuvent JAMAIS créer d'approbation : Dot, tâche de fond / banc / rejeu, modèle, shell,
//     contenu distant, téléphone (politique existante : le téléphone n'agit pas sur le Mac).
//   • États persistés (SQLite, fichier dédié send_ledger.sqlite, WAL + synchronous FULL) :
//       draft → awaitingApproval → approved → sending → submitted → verified
//                                                    ↘ failed | deliveryUnknown ; cancelled
//     approved → sending est un compare-and-set DANS une transaction (BEGIN IMMEDIATE) qui relit l'état.
//     Preuve de soumission ≠ vérification de livraison ; Teams n'est jamais « verified » sur Entrée ni sur
//     un extrait relu (preuve faible) ; Message-ID retenu quand disponible ; délai / plantage ambigu →
//     deliveryUnknown, jamais de relance automatique ; reprise prudente au démarrage.
//   • Journal de diagnostic (BlackBox) : identifiants, états, comptes, préfixes d'empreinte — jamais corps,
//     objet ni adresses.
// COUPER : il n'y a pas d'interrupteur d'envoi « sans approbation » (c'est le but). Pour revenir à l'ancien
// chemin, revert du commit WP3/WP4 ; le registre send_ledger.sqlite peut être supprimé sans perte de brouillon.

// MARK: - Contexte d'exécution limité au run

public enum ExecSource: String, Codable, Sendable, CaseIterable {
    case chat, voice, ui, phone, dot, background, model, shell, remote
    /// Seules les surfaces où Ahadi agit lui-même peuvent créer (et consommer) une approbation d'envoi.
    public var canApproveSends: Bool { self == .chat || self == .voice || self == .ui }
}

public final class ExecContext: @unchecked Sendable {
    public let runId: String
    public let conversationId: String
    public let turnId: String
    public let source: ExecSource
    public let actor: String
    public let startedAt: Date
    private let lock = NSLock()
    private var front: Bool = false

    public init(conversationId: String, source: ExecSource, actor: String = "Nova", turnId: String? = nil, startedAt: Date = Date()) {
        self.runId = SendApprovals.randomId(16)
        self.conversationId = conversationId
        self.turnId = turnId ?? SendApprovals.randomId(16)
        self.source = source
        self.actor = actor
        self.startedAt = startedAt
    }

    /// « Devant moi » : vaut pour CE run seulement (remplace la fenêtre globale de 3 min Tools.frontUntil).
    public var frontAllowed: Bool {
        get { lock.lock(); defer { lock.unlock() }; return front }
        set { lock.lock(); front = newValue; lock.unlock() }
    }

    /// Portée des confirmations d'outils (Tools.needConfirm / fenêtre « commandes courantes ») : la conversation
    /// pour le chat et la voix, le Dot pour un Dot — jamais partagée entre les deux.
    public var scopeKey: String {
        switch source {
        case .chat, .voice: return "conv:" + conversationId
        default: return source.rawValue + ":" + conversationId
        }
    }

    static let tdKey: String = "nova.execctx"
    public static var current: ExecContext? { Thread.current.threadDictionary[tdKey] as? ExecContext }
    /// Pose `c` sur le thread courant et renvoie le contexte précédent (à rendre avec `restore`).
    @discardableResult
    public static func enter(_ c: ExecContext) -> ExecContext? {
        let prev = current
        Thread.current.threadDictionary[tdKey] = c
        return prev
    }
    public static func restore(_ prev: ExecContext?) {
        if let p = prev { Thread.current.threadDictionary[tdKey] = p } else { Thread.current.threadDictionary.removeObject(forKey: tdKey) }
    }
    public static func with<T>(_ c: ExecContext, _ body: () throws -> T) rethrows -> T {
        let prev = enter(c)
        defer { restore(prev) }
        return try body()
    }
    /// Contexte d'un Dot : arrière-plan, aucune approbation possible, portée propre.
    public static func dot(_ id: String) -> ExecContext { ExecContext(conversationId: id, source: .dot, actor: "Dot " + id) }
}

// MARK: - Intention d'envoi dans un message d'Ahadi

public enum SendIntent: Equatable, Sendable {
    case confirm, negated, none

    static let confirmRx = try! NSRegularExpression(pattern: #"\benvoie(?![- ]moi\b)|\benvoy(er|ez)\b|\bgo\b|\boui\b|\bok\b|\bokay\b|\bvalide[rz]?\b|\bvas[- ]y\b|\bconfirme\b|\bc'est bon\b|\bfeu vert\b|\bd'accord\b|\bsend\b|\byes\b"#, options: .caseInsensitive)
    static let negRx = try! NSRegularExpression(pattern: #"\bn'\s*envoi|\bne\b|\bpas\b|\bnon\b|\bjamais\b|\brien\b|\battends?\b|\battendez\b|\bstop\b|\bannule|\barr[eê]te|\bdon'?t\b|\bdo not\b|\bnot\b|\bwait\b|\bhold\b|\bcancel"#, options: .caseInsensitive)
    static let modRx = try! NSRegularExpression(pattern: #"\bmais\b|\bchange|\bmodifi|\bcorrig|\bajout|\bretir|\benl[eè]v|\bremplac|\bsauf\b|\bplut[oô]t\b|\breformul|\braccourc|\bavant\b|\bd'abord\b|\bbut\b|\bedit|\bfix\b|\binstead\b|\?"#, options: .caseInsensitive)

    /// Classement PRUDENT : une confirmation = court (≤ 7 mots), un mot d'accord, aucune négation, aucune
    /// demande de modification, pas de question. Une négation l'emporte toujours.
    public static func classify(_ raw: String) -> SendIntent {
        let t = raw.replacingOccurrences(of: "’", with: "'").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty else { return .none }
        let words = t.split(whereSeparator: { $0.isWhitespace || $0 == "," }).count
        let hasConfirm = Tools.match(confirmRx, t)
        if Tools.match(negRx, t) { return (hasConfirm || words <= 4) ? .negated : .none }
        guard hasConfirm, words <= 7, !Tools.match(modRx, t) else { return .none }
        return .confirm
    }
}

// MARK: - Instantané exact de l'action

public enum SendChannel: String, Codable, Sendable { case mail, teams }

public struct SendAttachment: Codable, Equatable, Sendable {
    public let name: String
    public let sha256: String
    public let bytes: Int
    public init(name: String, sha256: String, bytes: Int) { self.name = name; self.sha256 = sha256; self.bytes = bytes }
}

public struct SendSnapshot: Codable, Equatable, Sendable {
    public let draftId: String
    public let revision: Int
    public let channel: SendChannel
    /// Destinataires RÉSOLUS exacts (adresses pour Mail, conversation cible pour Teams), dans l'ordre.
    public let recipients: [String]
    /// Expéditeur / compte ("" = compte par défaut de Mail). Jamais surchargeable après approbation.
    public let sender: String
    public let subject: String
    public let body: String
    public let attachments: [SendAttachment]

    public init(draftId: String, revision: Int, channel: SendChannel, recipients: [String], sender: String,
                subject: String, body: String, attachments: [SendAttachment]) {
        self.draftId = draftId; self.revision = revision; self.channel = channel; self.recipients = recipients
        self.sender = sender; self.subject = subject; self.body = body; self.attachments = attachments
    }

    public var canonical: String {
        let att = attachments.map { $0.name + ":" + $0.sha256 + ":" + String($0.bytes) }.joined(separator: "\u{1E}")
        return ["nova-send-v1", draftId, String(revision), channel.rawValue, recipients.joined(separator: "\u{1E}"),
                sender, subject, body, att].joined(separator: "\u{1F}")
    }
    /// Empreinte SHA-256 de l'instantané complet (machinerie AgentsV2 / Sha).
    public var sha256: String { AgentsV2.sha256(canonical) }
    /// Clé d'idempotence : un brouillon dans UNE version = une seule action d'envoi possible.
    public var idempotencyKey: String { AgentsV2.sha256("nova-send-idem-v1\u{1F}" + draftId + "\u{1F}" + sha256) }

    public static func hashFile(_ path: String) -> SendAttachment? {
        let p = (path as NSString).expandingTildeInPath
        guard let data = FileManager.default.contents(atPath: p) else { return nil }
        return SendAttachment(name: (p as NSString).lastPathComponent, sha256: Sha.hex(Sha.sha256([UInt8](data))), bytes: data.count)
    }

    /// Instantané d'un brouillon du magasin (seuls les champs DU MAGASIN comptent — aucune surcharge par requête).
    public static func from(draft d: [String: Any], hashFile: (String) -> SendAttachment? = SendSnapshot.hashFile) -> SendSnapshot? {
        guard let id = d["id"] as? String, !id.isEmpty else { return nil }
        let ch: SendChannel = ((d["channel"] as? String) ?? "mail") == "teams" ? .teams : .mail
        let rcpt: [String]
        if ch == .teams {
            let t = ((d["target"] as? String) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            rcpt = t.isEmpty ? [] : [t]
        } else {
            rcpt = SendQueue.recipients((d["to"] as? String) ?? "")
        }
        let sender = ((d["from"] as? String) ?? (d["account"] as? String) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let rev: Int = (d["rev"] as? Int) ?? Int((d["rev"] as? String) ?? "") ?? 0
        var atts: [SendAttachment] = []
        for a in (d["attachments"] as? [Any]) ?? [] {
            let p: String = (a as? String) ?? (((a as? [String: Any])?["path"] as? String) ?? "")
            guard !p.isEmpty else { continue }
            atts.append(hashFile(p) ?? SendAttachment(name: (p as NSString).lastPathComponent, sha256: "illisible", bytes: -1))
        }
        return SendSnapshot(draftId: id, revision: rev, channel: ch, recipients: rcpt, sender: sender,
                            subject: ch == .teams ? "" : ((d["subject"] as? String) ?? ""),
                            body: SendQueue.plain((d["body"] as? String) ?? ""), attachments: atts)
    }

    /// Carte affichée par le MOTEUR dans la conversation : c'est elle que la confirmation d'Ahadi approuve.
    public func card(actionId: String, sha: String) -> String {
        var l: [String] = ["🔒 **Envoi à approuver** · action `" + actionId + "` · brouillon `" + draftId + "` — rien n'est parti."]
        let canal: String = channel == .teams ? "Teams" : "Mail"
        let defaut: String = channel == .teams ? "session Teams de Nova" : "compte par défaut de Mail"
        let de: String = sender.isEmpty ? defaut : sender
        l.append("- Canal : " + canal + " · De : " + de)
        let quoi: String = channel == .teams ? "Conversation : " : "À : "
        let qui: String = recipients.isEmpty ? "—" : recipients.joined(separator: ", ")
        l.append("- " + quoi + qui)
        if channel == .mail { l.append("- Objet : " + (subject.isEmpty ? "(sans objet)" : subject)) }
        l.append("- Pièces jointes : " + (attachments.isEmpty ? "aucune" : attachments.map { $0.name }.joined(separator: ", ")))
        let b: String = body.count <= 1200 ? body : String(body.prefix(600)) + " […] (corps complet dans la file Brouillons, même empreinte)"
        let quoted: [String] = b.split(separator: "\n", omittingEmptySubsequences: false).map { (x: Substring) -> String in "> " + String(x) }
        l.append("- Corps :\n" + quoted.joined(separator: "\n"))
        l.append("- Empreinte " + String(sha.prefix(12)) + " · réponds « envoie » (ou « go ») au prochain message pour envoyer EXACTEMENT ceci ; toute modification demandera une nouvelle approbation.")
        return l.joined(separator: "\n")
    }
}

// MARK: - États et enregistrements persistés

public enum SendState: String, Codable, CaseIterable, Sendable {
    case draft, awaitingApproval, approved, sending, submitted, verified, failed, deliveryUnknown, cancelled

    static let allowed: [SendState: Set<SendState>] = [
        .draft: [.awaitingApproval, .cancelled],
        .awaitingApproval: [.approved, .cancelled],
        .approved: [.sending, .awaitingApproval, .cancelled],
        .sending: [.submitted, .failed, .deliveryUnknown],
        .submitted: [.verified],
        .deliveryUnknown: [.verified, .failed],
        .failed: [.awaitingApproval],
        .cancelled: [.awaitingApproval],
        .verified: [],
    ]
    public func canMove(to next: SendState) -> Bool { SendState.allowed[self]?.contains(next) ?? false }
}

public enum EvidenceStrength: String, Codable, Sendable {
    case providerMessageId = "provider_message_id"   // identifiant du fournisseur (Message-ID…)
    case transportAccepted = "transport_accepted"    // le transport a accepté la soumission (ex. « send » de Mail.app)
    case weakReadback = "weak_readback"              // extrait du corps relu : indice, PAS un reçu unique
}

public struct SubmissionEvidence: Codable, Equatable, Sendable {
    public let kind: String
    public let strength: EvidenceStrength
    public let providerMessageId: String?
    public let at: Date
    public init(kind: String, strength: EvidenceStrength, providerMessageId: String?, at: Date) {
        self.kind = kind; self.strength = strength; self.providerMessageId = providerMessageId; self.at = at
    }
}

public struct VerificationEvidence: Codable, Equatable, Sendable {
    public let method: String
    public let providerMessageId: String
    public let at: Date
}

public struct SendApproval: Codable, Equatable, Sendable {
    public let nonce: String
    public let source: ExecSource
    public let conversationId: String
    public let turnId: String
    public let runId: String
    public let approvedAt: Date
    public let expiresAt: Date
    public var consumedAt: Date?
}

public struct SendTransitionLog: Codable, Sendable {
    public let from: SendState
    public let to: SendState
    public let at: Date
    public let code: String
}

public struct SendRecord: Codable, Sendable {
    public let actionId: String
    public let idempotencyKey: String
    public let draftId: String
    /// Instantané APPROUVÉ : c'est lui qui part, jamais le brouillon relu au moment de l'envoi.
    public let snapshot: SendSnapshot
    public let snapshotSha: String
    public let createdAt: Date
    public var state: SendState
    public var updatedAt: Date
    public var conversationId: String
    public var requestTurnId: String
    public var displayedTurnId: String?
    public var approval: SendApproval?
    public var transportStartedAt: Date?
    public var submission: SubmissionEvidence?
    public var verification: VerificationEvidence?
    /// Motif court (aucun contenu : ni corps, ni objet, ni adresse).
    public var code: String
    public var history: [SendTransitionLog]

    public var channel: SendChannel { snapshot.channel }

    mutating func move(_ to: SendState, at: Date, code: String) -> Bool {
        guard state.canMove(to: to) else { return false }
        history.append(SendTransitionLog(from: state, to: to, at: at, code: code))
        if history.count > 40 { history.removeFirst(history.count - 40) }
        state = to; updatedAt = at; self.code = code
        return true
    }

    /// Vue sans contenu (diagnostic, liste de l'interface).
    public var summary: [String: Any] {
        var o: [String: Any] = ["action": actionId, "draft": draftId, "channel": channel.rawValue, "state": state.rawValue, "code": code,
                                "recipients": snapshot.recipients.count, "attachments": snapshot.attachments.count,
                                "sha": String(snapshotSha.prefix(12)), "revision": snapshot.revision,
                                "updated": ISO8601DateFormatter().string(from: updatedAt)]
        if let s = submission { o["evidence"] = s.strength.rawValue; o["provider_id"] = s.providerMessageId != nil }
        if let a = approval { o["approval_source"] = a.source.rawValue }
        if verification != nil { o["verified_by"] = verification?.method ?? "" }
        return o
    }
}

enum SendLedgerCodec {
    static func encode(_ r: SendRecord) -> Data? { try? JSONEncoder().encode(r) }
    static func decode(_ d: Data) -> SendRecord? { try? JSONDecoder().decode(SendRecord.self, from: d) }
}

// MARK: - Stockage (SQLite en production, mémoire en repli)

public protocol SendRecordStore: AnyObject {
    func get(_ actionId: String) -> SendRecord?
    func byIdempotencyKey(_ key: String) -> SendRecord?
    func forDraft(_ draftId: String) -> [SendRecord]
    func all() -> [SendRecord]
    /// Insère si la clé d'idempotence est neuve, sinon renvoie l'existant — jamais deux actions pour une même clé.
    func insertIfAbsent(_ r: SendRecord) -> (record: SendRecord, inserted: Bool)
    /// Compare-and-set ATOMIQUE : relit l'enregistrement dans la transaction, `mutate` décide (false = refus, rien
    /// n'est écrit). Renvoie l'enregistrement (modifié si applied) ; nil si introuvable ou erreur de stockage.
    /// `mutate` ne doit jamais rappeler le stockage.
    func update(_ actionId: String, _ mutate: (inout SendRecord) -> Bool) -> (record: SendRecord, applied: Bool)?
}

public final class MemorySendStore: SendRecordStore, @unchecked Sendable {
    private let lock = NSLock()
    private var rows: [String: SendRecord] = [:]
    public init() {}
    public func get(_ actionId: String) -> SendRecord? { lock.lock(); defer { lock.unlock() }; return rows[actionId] }
    public func byIdempotencyKey(_ key: String) -> SendRecord? { lock.lock(); defer { lock.unlock() }; return rows.values.first { $0.idempotencyKey == key } }
    public func forDraft(_ draftId: String) -> [SendRecord] { lock.lock(); defer { lock.unlock() }; return rows.values.filter { $0.draftId == draftId }.sorted { $0.createdAt < $1.createdAt } }
    public func all() -> [SendRecord] { lock.lock(); defer { lock.unlock() }; return rows.values.sorted { $0.createdAt < $1.createdAt } }
    public func insertIfAbsent(_ r: SendRecord) -> (record: SendRecord, inserted: Bool) {
        lock.lock(); defer { lock.unlock() }
        if let e = rows.values.first(where: { $0.idempotencyKey == r.idempotencyKey }) { return (e, false) }
        rows[r.actionId] = r
        return (r, true)
    }
    public func update(_ actionId: String, _ mutate: (inout SendRecord) -> Bool) -> (record: SendRecord, applied: Bool)? {
        lock.lock(); defer { lock.unlock() }
        guard let orig = rows[actionId] else { return nil }
        var r = orig
        guard mutate(&r) else { return (orig, false) }
        rows[actionId] = r
        return (r, true)
    }
}

#if canImport(SQLite3)
/// Registre durable : une ligne par action ; l'enregistrement complet en JSON (rec), état et clé indexés.
/// Une connexion, sérialisée par un verrou ; chaque écriture dans une transaction BEGIN IMMEDIATE (verrou
/// d'écriture pris AVANT la relecture : la relecture de l'état et l'écriture sont indivisibles, même entre processus).
public final class SQLiteSendStore: SendRecordStore, @unchecked Sendable {
    public let path: String
    private var db: OpaquePointer? = nil
    private let lock = NSLock()
    static let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

    public init?(path: String) {
        self.path = path
        var h: OpaquePointer? = nil
        guard sqlite3_open_v2(path, &h, SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX, nil) == SQLITE_OK, let hh = h else {
            if h != nil { sqlite3_close(h) }
            return nil
        }
        db = hh
        let setup: [String] = [
            "PRAGMA journal_mode=WAL;",
            "PRAGMA synchronous=FULL;",
            "PRAGMA busy_timeout=5000;",
            "CREATE TABLE IF NOT EXISTS send_records(action_id TEXT PRIMARY KEY, idem_key TEXT NOT NULL UNIQUE, draft_id TEXT NOT NULL, state TEXT NOT NULL, updated_at REAL NOT NULL, rec BLOB NOT NULL);",
            "CREATE INDEX IF NOT EXISTS send_records_draft ON send_records(draft_id);",
            "CREATE TABLE IF NOT EXISTS send_meta(k TEXT PRIMARY KEY, v TEXT);",
            "INSERT OR IGNORE INTO send_meta(k, v) VALUES('schema_version', '1');",
        ]
        for sql in setup where sqlite3_exec(hh, sql, nil, nil, nil) != SQLITE_OK {
            if !sql.hasPrefix("PRAGMA") { sqlite3_close(hh); db = nil; return nil }
        }
    }

    deinit { if db != nil { sqlite3_close(db) } }

    private func exec(_ sql: String) -> Bool { sqlite3_exec(db, sql, nil, nil, nil) == SQLITE_OK }

    private func query(_ sql: String, _ args: [String]) -> [SendRecord] {
        var st: OpaquePointer? = nil
        guard sqlite3_prepare_v2(db, sql, -1, &st, nil) == SQLITE_OK else { return [] }
        defer { sqlite3_finalize(st) }
        for (i, a) in args.enumerated() { sqlite3_bind_text(st, Int32(i + 1), a, -1, SQLiteSendStore.transient) }
        var out: [SendRecord] = []
        while sqlite3_step(st) == SQLITE_ROW {
            let n = Int(sqlite3_column_bytes(st, 0))
            if n > 0, let p = sqlite3_column_blob(st, 0), let r = SendLedgerCodec.decode(Data(bytes: p, count: n)) { out.append(r) }
        }
        return out
    }

    private func bindBlob(_ st: OpaquePointer?, _ i: Int32, _ d: Data) {
        d.withUnsafeBytes { (p: UnsafeRawBufferPointer) -> Void in
            _ = sqlite3_bind_blob(st, i, p.baseAddress, Int32(p.count), SQLiteSendStore.transient)
        }
    }

    private func write(_ r: SendRecord, insert: Bool) -> Bool {
        guard let data = SendLedgerCodec.encode(r), !data.isEmpty else { return false }
        let sql = insert
            ? "INSERT INTO send_records(action_id, idem_key, draft_id, state, updated_at, rec) VALUES(?, ?, ?, ?, ?, ?);"
            : "UPDATE send_records SET state = ?, updated_at = ?, rec = ? WHERE action_id = ?;"
        var st: OpaquePointer? = nil
        guard sqlite3_prepare_v2(db, sql, -1, &st, nil) == SQLITE_OK else { return false }
        defer { sqlite3_finalize(st) }
        let t = SQLiteSendStore.transient
        if insert {
            sqlite3_bind_text(st, 1, r.actionId, -1, t)
            sqlite3_bind_text(st, 2, r.idempotencyKey, -1, t)
            sqlite3_bind_text(st, 3, r.draftId, -1, t)
            sqlite3_bind_text(st, 4, r.state.rawValue, -1, t)
            sqlite3_bind_double(st, 5, r.updatedAt.timeIntervalSince1970)
            bindBlob(st, 6, data)
        } else {
            sqlite3_bind_text(st, 1, r.state.rawValue, -1, t)
            sqlite3_bind_double(st, 2, r.updatedAt.timeIntervalSince1970)
            bindBlob(st, 3, data)
            sqlite3_bind_text(st, 4, r.actionId, -1, t)
        }
        return sqlite3_step(st) == SQLITE_DONE && sqlite3_changes(db) == 1
    }

    public func get(_ actionId: String) -> SendRecord? {
        lock.lock(); defer { lock.unlock() }
        return query("SELECT rec FROM send_records WHERE action_id = ?;", [actionId]).first
    }
    public func byIdempotencyKey(_ key: String) -> SendRecord? {
        lock.lock(); defer { lock.unlock() }
        return query("SELECT rec FROM send_records WHERE idem_key = ?;", [key]).first
    }
    public func forDraft(_ draftId: String) -> [SendRecord] {
        lock.lock(); defer { lock.unlock() }
        return query("SELECT rec FROM send_records WHERE draft_id = ?;", [draftId]).sorted { $0.createdAt < $1.createdAt }
    }
    public func all() -> [SendRecord] {
        lock.lock(); defer { lock.unlock() }
        return query("SELECT rec FROM send_records;", []).sorted { $0.createdAt < $1.createdAt }
    }
    public func insertIfAbsent(_ r: SendRecord) -> (record: SendRecord, inserted: Bool) {
        lock.lock(); defer { lock.unlock() }
        guard exec("BEGIN IMMEDIATE;") else { return (r, false) }
        if let e = query("SELECT rec FROM send_records WHERE idem_key = ?;", [r.idempotencyKey]).first { _ = exec("ROLLBACK;"); return (e, false) }
        guard write(r, insert: true), exec("COMMIT;") else { _ = exec("ROLLBACK;"); return (r, false) }
        return (r, true)
    }
    public func update(_ actionId: String, _ mutate: (inout SendRecord) -> Bool) -> (record: SendRecord, applied: Bool)? {
        lock.lock(); defer { lock.unlock() }
        guard exec("BEGIN IMMEDIATE;") else { return nil }
        guard let orig = query("SELECT rec FROM send_records WHERE action_id = ?;", [actionId]).first else { _ = exec("ROLLBACK;"); return nil }
        var r = orig
        guard mutate(&r) else { _ = exec("ROLLBACK;"); return (orig, false) }
        guard write(r, insert: false), exec("COMMIT;") else { _ = exec("ROLLBACK;"); return nil }
        return (r, true)
    }
}
#endif

// MARK: - Transports et vérification (simulés en test, adaptateurs réels plus bas)

public enum TransportOutcome: Sendable {
    /// Le transport a accepté la soumission (preuve de SOUMISSION, pas de livraison).
    case submitted(SubmissionEvidence)
    /// Certainement pas parti (refus avant soumission) : nouvelle approbation possible.
    case rejected(String)
    /// Peut-être parti (délai, réponse absente, relecture ambiguë) : deliveryUnknown, aucune relance automatique.
    case ambiguous(String)
}

public protocol SendTransport: AnyObject {
    func submit(_ snapshot: SendSnapshot, idempotencyKey: String) -> TransportOutcome
}

public enum VerifyOutcome: Sendable {
    case confirmed(providerMessageId: String, method: String)
    case notFound
    case ambiguous(String)
}

public protocol SendVerifier: AnyObject {
    func verify(_ record: SendRecord) -> VerifyOutcome
}

public struct SendResult: Sendable {
    public enum Code: String, Sendable {
        case submitted, verified, needsApproval, changed, wrongScope, expired, inProgress, alreadySent, uncertain
        case failed, deliveryUnknown, refused, notFound, invalid
    }
    public let code: Code
    public let record: SendRecord?
    public let detail: String
    public var ok: Bool { code == .submitted || code == .verified }
}

public enum MintOutcome: Equatable, Sendable {
    case none, notAllowed, ambiguous([String]), stale(String)
    case negated(revoked: Int)
    case minted(actionId: String, draftId: String)

    /// Note du MOTEUR ajoutée au message d'Ahadi pour le cerveau du tour (jamais une autorisation en soi).
    public var engineNote: String? {
        switch self {
        case .minted(let a, let d):
            return "\n\n[NOTE MOTEUR] Ahadi vient d'APPROUVER l'envoi affiché (action " + a + ", brouillon " + d + "), pour ce tour seulement : appelle mail_envoyer avec l'id " + d + " puis rapporte son résultat tel quel. Toute modification du brouillon annulerait cette approbation."
        case .ambiguous(let ids):
            return "\n\n[NOTE MOTEUR] Plusieurs envois attendent une approbation (" + ids.joined(separator: ", ") + ") : AUCUN n'est approuvé. Demande à Ahadi lequel (« envoie <id> »)."
        case .stale(let d):
            return "\n\n[NOTE MOTEUR] Le brouillon " + d + " a changé depuis la carte affichée : approbation REFUSÉE. Rappelle mail_envoyer pour afficher la nouvelle version, Ahadi confirmera ensuite."
        case .negated(let n):
            return n > 0 ? "\n\n[NOTE MOTEUR] Contre-ordre d'Ahadi : " + String(n) + " envoi(s) en attente ne sont plus approuvables sans nouvelle carte. N'envoie rien." : nil
        case .none, .notAllowed:
            return nil
        }
    }
}

// MARK: - Service unique d'approbation et d'envoi

public final class SendApprovals: @unchecked Sendable {
    public static let approvalTTL: TimeInterval = 600

    public let store: SendRecordStore
    let now: () -> Date
    let hashFile: (String) -> SendAttachment?
    let onTransition: ((SendRecord, SendState, SendState, String) -> Void)?
    private let lock = NSLock()
    private var turns: [String: String] = [:]          // conversation → dernier tour vu (mémoire : perdu au redémarrage = prudent)
    private var draftsReader: () -> [[String: Any]]
    private var draftUpdater: (String, [String: Any]) -> Void

    public init(store: SendRecordStore, now: @escaping () -> Date = { Date() },
                drafts: @escaping () -> [[String: Any]] = { [] },
                updateDraft: @escaping (String, [String: Any]) -> Void = { _, _ in },
                hashFile: @escaping (String) -> SendAttachment? = SendSnapshot.hashFile,
                onTransition: ((SendRecord, SendState, SendState, String) -> Void)? = nil) {
        self.store = store; self.now = now; self.draftsReader = drafts; self.draftUpdater = updateDraft
        self.hashFile = hashFile; self.onTransition = onTransition
    }

    /// Instance de l'app : registre SQLite dédié (repli mémoire si la base ne s'ouvre pas — alors rien ne
    /// survit au redémarrage, ce qui reste prudent : aucune approbation ne survit non plus).
    public static let shared: SendApprovals = {
        var st: SendRecordStore = MemorySendStore()
        #if canImport(SQLite3)
        if let s = SQLiteSendStore(path: Paths.file("send_ledger.sqlite").path) { st = s }
        #endif
        return SendApprovals(store: st, onTransition: { r, from, to, code in
            let why: String = "envoi " + r.actionId + " : " + from.rawValue + " → " + to.rawValue + " (" + code + ")"
            let dest: String = String(r.snapshot.recipients.count)
            let pj: String = String(r.snapshot.attachments.count)
            let res: String = "canal=" + r.channel.rawValue + " dest=" + dest + " pj=" + pj + " sha=" + String(r.snapshotSha.prefix(12))
            let ok: Bool = to != .failed
            _ = BlackBox.record(["tool": "envoi", "actor": "Nova", "effect": "lecture", "ok": ok, "why": why, "result": res])
            _ = AttentionNotif.sendTransition(conversationId: r.conversationId, channel: r.channel.rawValue, recipients: r.snapshot.recipients.count, to: to.rawValue)   // 01/11 : envoi à approuver → notification + pastille du Dock
        })
    }()

    /// Branche le magasin de brouillons (appelé une fois, à l'enregistrement des routes).
    public func configure(drafts: @escaping () -> [[String: Any]], updateDraft: @escaping (String, [String: Any]) -> Void) {
        lock.lock(); draftsReader = drafts; draftUpdater = updateDraft; lock.unlock()
    }

    public static func randomId(_ n: Int) -> String {
        String((UUID().uuidString + UUID().uuidString).replacingOccurrences(of: "-", with: "").lowercased().prefix(n))
    }

    func readDrafts() -> [[String: Any]] { lock.lock(); let f = draftsReader; lock.unlock(); return f() }
    func writeDraft(_ id: String, _ fields: [String: Any]) { lock.lock(); let f = draftUpdater; lock.unlock(); f(id, fields) }
    func currentDraft(_ id: String) -> [String: Any]? { readDrafts().first { ($0["id"] as? String) == id } }
    public func snapshot(of d: [String: Any]) -> SendSnapshot? { SendSnapshot.from(draft: d, hashFile: hashFile) }
    public func records(draftId: String) -> [SendRecord] { store.forDraft(draftId) }
    public func all() -> [SendRecord] { store.all() }

    /// Transition atomique + journal de diagnostic (sans contenu).
    @discardableResult
    func transition(_ actionId: String, _ body: (inout SendRecord) -> Bool) -> (record: SendRecord, applied: Bool)? {
        var fired: (SendState, SendState, String)? = nil
        let r = store.update(actionId) { rec in
            let before = rec.state
            guard body(&rec) else { return false }
            if rec.state != before { fired = (before, rec.state, rec.code) }
            return true
        }
        if let r = r, r.applied, let f = fired { onTransition?(r.record, f.0, f.1, f.2) }
        return r
    }

    /// Reflète l'état d'envoi dans le brouillon (compatibilité de l'interface : « envoyé » = soumis).
    func reflect(_ r: SendRecord) {
        var f: [String: Any] = ["send_state": r.state.rawValue, "send_action": r.actionId]
        switch r.state {
        case .submitted, .verified:
            f["status"] = "envoyé"
            f["sentAt"] = ISO8601DateFormatter().string(from: r.submission?.at ?? r.updatedAt)
            f["verified"] = r.state == .verified
        case .deliveryUnknown:
            f["status"] = "envoi incertain — à vérifier"
        default: break
        }
        writeDraft(r.draftId, f)
    }

    // MARK: demande

    /// Demande d'approbation pour la version COURANTE du brouillon (ou l'action existante de cette version),
    /// rattachée à la conversation et au tour courants ; la carte sera affichée à la fin du tour.
    @discardableResult
    public func request(draft d: [String: Any], ctx: ExecContext) -> SendRecord? {
        guard let snap = snapshot(of: d) else { return nil }
        let t = now()
        let fresh = SendRecord(actionId: "env-" + SendApprovals.randomId(12), idempotencyKey: snap.idempotencyKey, draftId: snap.draftId,
                               snapshot: snap, snapshotSha: snap.sha256, createdAt: t, state: .awaitingApproval, updatedAt: t,
                               conversationId: ctx.conversationId, requestTurnId: ctx.turnId, displayedTurnId: nil, approval: nil,
                               transportStartedAt: nil, submission: nil, verification: nil, code: "demande",
                               history: [SendTransitionLog(from: .draft, to: .awaitingApproval, at: t, code: "demande")])
        let ins = store.insertIfAbsent(fresh)
        var result: SendRecord = ins.record
        if ins.inserted {
            onTransition?(ins.record, .draft, .awaitingApproval, "demande")
        } else {
            switch ins.record.state {
            case .failed, .cancelled:
                if let x = transition(ins.record.actionId, { r in
                    guard r.state == .failed || r.state == .cancelled else { return false }
                    r.approval = nil; r.transportStartedAt = nil
                    r.conversationId = ctx.conversationId; r.requestTurnId = ctx.turnId; r.displayedTurnId = nil
                    return r.move(.awaitingApproval, at: t, code: "nouvelle demande")
                }) { result = x.record }
            case .awaitingApproval:
                if let x = transition(ins.record.actionId, { r in
                    guard r.state == .awaitingApproval else { return false }
                    r.conversationId = ctx.conversationId; r.requestTurnId = ctx.turnId; r.displayedTurnId = nil; r.updatedAt = t
                    return true
                }) { result = x.record }
            default: break
            }
        }
        // Une version précédente du même brouillon ne peut plus partir.
        for old in store.forDraft(snap.draftId) where old.actionId != result.actionId && (old.state == .awaitingApproval || old.state == .approved) {
            transition(old.actionId) { r in
                guard r.state == .awaitingApproval || r.state == .approved else { return false }
                r.approval = nil
                return r.move(.cancelled, at: t, code: "remplacé par une nouvelle version")
            }
        }
        return result
    }

    /// Cartes « Envoi à approuver » à afficher à la fin de CE tour (moteur, pas modèle). Les brouillons nés
    /// pendant le tour reçoivent leur demande tout de suite : le « envoie » suivant suffira (pas de double confirmation).
    public func cardsToDisplay(ctx: ExecContext) -> String {
        guard ctx.source == .chat || ctx.source == .voice else { return "" }
        let t0 = ctx.startedAt.addingTimeInterval(-2)
        let iso = ISO8601DateFormatter()
        for d in readDrafts() {
            let st = ((d["status"] as? String) ?? "").lowercased()
            guard st.hasPrefix("à valider") || st.hasPrefix("a valider"),
                  let ts = d["ts"] as? String, let when = iso.date(from: ts), when >= t0 else { continue }
            if let s = snapshot(of: d), let e = store.byIdempotencyKey(s.idempotencyKey), e.state != .failed && e.state != .cancelled { continue }
            request(draft: d, ctx: ctx)
        }
        var out: [String] = []
        for r in store.all() where r.state == .awaitingApproval && r.conversationId == ctx.conversationId && r.requestTurnId == ctx.turnId && r.displayedTurnId == nil {
            guard let x = transition(r.actionId, { rec in
                guard rec.state == .awaitingApproval, rec.displayedTurnId == nil, rec.requestTurnId == ctx.turnId else { return false }
                rec.displayedTurnId = ctx.turnId; rec.updatedAt = now()
                return true
            }), x.applied else { continue }
            out.append(x.record.snapshot.card(actionId: x.record.actionId, sha: x.record.snapshotSha))
        }
        return out.isEmpty ? "" : "\n\n" + out.joined(separator: "\n\n")
    }

    // MARK: approbation

    /// Message d'Ahadi au début d'un tour : la SEULE porte de création d'approbation côté conversation.
    /// Une confirmation explicite approuve l'action affichée au tour précédent de CETTE conversation (ou celle
    /// qu'il nomme par son id) ; une négation révoque ; tout le reste ne crée rien.
    public func noteUserTurn(ctx: ExecContext, text: String) -> MintOutcome {
        lock.lock(); let prev = turns[ctx.conversationId]; turns[ctx.conversationId] = ctx.turnId; lock.unlock()
        let intent = SendIntent.classify(text)
        if intent == .negated { return .negated(revoked: revoke(conversationId: ctx.conversationId, code: "contre-ordre d'Ahadi")) }
        guard intent == .confirm else { return .none }
        guard ctx.source == .chat || ctx.source == .voice else { return .notAllowed }
        let low = text.lowercased()
        let pending = store.all().filter { $0.state == .awaitingApproval && $0.conversationId == ctx.conversationId && $0.displayedTurnId != nil }
        let named = pending.filter { low.contains($0.draftId.lowercased()) || low.contains($0.actionId.lowercased()) }
        let cands: [SendRecord] = !named.isEmpty ? named : pending.filter { prev != nil && $0.displayedTurnId == prev }
        guard !cands.isEmpty else { return .none }
        guard cands.count == 1, let c = cands.first else { return .ambiguous(cands.map { $0.draftId }) }
        // L'instantané affiché doit être EXACTEMENT la version courante du brouillon.
        guard let d = currentDraft(c.draftId), let snap = snapshot(of: d), snap.sha256 == c.snapshotSha else {
            transition(c.actionId) { r in
                guard r.state == .awaitingApproval else { return false }
                return r.move(.cancelled, at: now(), code: "modifié depuis l'affichage")
            }
            return .stale(c.draftId)
        }
        let t = now()
        let ap = SendApproval(nonce: SendApprovals.randomId(24), source: ctx.source, conversationId: ctx.conversationId, turnId: ctx.turnId,
                              runId: ctx.runId, approvedAt: t, expiresAt: t.addingTimeInterval(SendApprovals.approvalTTL), consumedAt: nil)
        guard let x = transition(c.actionId, { r in
            guard r.state == .awaitingApproval, r.snapshotSha == c.snapshotSha, r.conversationId == ctx.conversationId else { return false }
            r.approval = ap
            return r.move(.approved, at: t, code: "approuvé (" + ctx.source.rawValue + ")")
        }), x.applied else { return .none }
        return .minted(actionId: c.actionId, draftId: c.draftId)
    }

    /// Contre-ordre : les approbations non consommées de la conversation tombent, les cartes doivent être réaffichées.
    @discardableResult
    public func revoke(conversationId: String, code: String) -> Int {
        var n = 0
        for r in store.all() where r.conversationId == conversationId && (r.state == .approved || (r.state == .awaitingApproval && r.displayedTurnId != nil)) {
            let x = transition(r.actionId) { rec in
                guard rec.conversationId == conversationId else { return false }
                if rec.state == .approved {
                    rec.approval = nil; rec.displayedTurnId = nil
                    return rec.move(.awaitingApproval, at: now(), code: code)
                }
                if rec.state == .awaitingApproval && rec.displayedTurnId != nil {
                    rec.displayedTurnId = nil; rec.updatedAt = now(); rec.code = code
                    return true
                }
                return false
            }
            if x?.applied == true { n += 1 }
        }
        return n
    }

    // MARK: envoi

    /// Envoi d'un brouillon : consomme ATOMIQUEMENT l'approbation liée à (conversation, tour, source, instantané),
    /// passe approved → sending dans la transaction, soumet l'INSTANTANÉ APPROUVÉ, persiste le résultat.
    public func execute(draftId: String, ctx: ExecContext?, transport: SendTransport, uiNonce: String? = nil) -> SendResult {
        guard let ctx = ctx else {
            return SendResult(code: .refused, record: nil, detail: "aucun contexte interactif (Dot, tâche de fond, outil hors conversation) : un envoi exige l'approbation d'Ahadi dans sa conversation ou depuis le bouton d'envoi")
        }
        guard ctx.source.canApproveSends else {
            return SendResult(code: .refused, record: nil, detail: "source « " + ctx.source.rawValue + " » : ne peut ni approuver ni consommer une approbation d'envoi")
        }
        guard let d = currentDraft(draftId) else { return SendResult(code: .notFound, record: nil, detail: "brouillon introuvable") }
        guard let snap = snapshot(of: d), !snap.recipients.isEmpty else {
            return SendResult(code: .invalid, record: nil, detail: "aucun destinataire valide (adresse e-mail ou conversation Teams requise)")
        }
        guard let rec = store.byIdempotencyKey(snap.idempotencyKey) else {
            return SendResult(code: .needsApproval, record: request(draft: d, ctx: ctx), detail: "approbation requise pour cette version")
        }
        switch rec.state {
        case .submitted: return SendResult(code: .alreadySent, record: rec, detail: "déjà soumis — aucun second envoi")
        case .verified: return SendResult(code: .alreadySent, record: rec, detail: "déjà envoyé et vérifié — aucun second envoi")
        case .sending: return SendResult(code: .inProgress, record: rec, detail: "envoi déjà en cours pour ce brouillon")
        case .deliveryUnknown: return SendResult(code: .uncertain, record: rec, detail: "envoi INCERTAIN déjà tenté — vérifie avant tout renvoi ; aucune relance automatique")
        case .draft, .awaitingApproval, .failed, .cancelled:
            return SendResult(code: .needsApproval, record: request(draft: d, ctx: ctx), detail: "approbation requise pour cette version")
        case .approved: break
        }
        let t = now()
        var why: SendResult.Code = .needsApproval
        let claimed = transition(rec.actionId) { r in
            guard r.state == .approved, let ap = r.approval, ap.consumedAt == nil else {
                why = r.state == .sending ? .inProgress : ((r.state == .submitted || r.state == .verified) ? .alreadySent : (r.state == .deliveryUnknown ? .uncertain : .needsApproval))
                return false
            }
            guard r.snapshotSha == snap.sha256 else { why = .changed; return false }
            guard ap.conversationId == ctx.conversationId, ap.turnId == ctx.turnId, ap.source == ctx.source else { why = .wrongScope; return false }
            if let n = uiNonce, n != ap.nonce { why = .wrongScope; return false }
            guard ap.expiresAt > t else { why = .expired; return false }
            var a2 = ap; a2.consumedAt = t; r.approval = a2
            return r.move(.sending, at: t, code: "réservé pour envoi")
        }
        guard let c = claimed, c.applied else {
            if why == .expired {
                transition(rec.actionId) { r in
                    guard r.state == .approved else { return false }
                    r.approval = nil; r.displayedTurnId = nil
                    return r.move(.awaitingApproval, at: t, code: "approbation expirée")
                }
                return SendResult(code: .expired, record: request(draft: d, ctx: ctx), detail: "approbation expirée — nouvelle approbation requise")
            }
            let msg: String
            switch why {
            case .wrongScope: msg = "l'approbation existante appartient à une autre conversation, un autre tour ou une autre surface"
            case .inProgress: msg = "envoi déjà en cours pour ce brouillon"
            case .alreadySent: msg = "déjà soumis — aucun second envoi"
            case .uncertain: msg = "envoi INCERTAIN déjà tenté — vérifie avant tout renvoi"
            case .changed: msg = "le brouillon a changé depuis l'approbation"
            default: msg = "approbation requise"
            }
            return SendResult(code: why, record: claimed?.record ?? store.get(rec.actionId), detail: msg)
        }
        // Ligne franchie : à partir d'ici, un plantage sans résultat = deliveryUnknown (jamais « rien n'est parti »).
        guard let started = transition(rec.actionId, { r in
            guard r.state == .sending, r.transportStartedAt == nil else { return false }
            r.transportStartedAt = now(); r.updatedAt = now()
            return true
        }), started.applied else {
            return SendResult(code: .inProgress, record: store.get(rec.actionId), detail: "envoi déjà en cours pour ce brouillon")
        }
        writeDraft(draftId, ["send_state": SendState.sending.rawValue, "send_action": rec.actionId])
        let outcome = transport.submit(started.record.snapshot, idempotencyKey: started.record.idempotencyKey)   // l'instantané APPROUVÉ fait foi
        let t2 = now()
        let fin = transition(rec.actionId) { r in
            guard r.state == .sending else { return false }
            switch outcome {
            case .submitted(let ev): r.submission = ev; return r.move(.submitted, at: t2, code: ev.kind)
            case .rejected(let code): return r.move(.failed, at: t2, code: code)
            case .ambiguous(let code): return r.move(.deliveryUnknown, at: t2, code: code)
            }
        }
        // Le résultat suit l'état PERSISTÉ (une reprise concurrente a pu classer l'envoi incertain entre-temps).
        let final: SendRecord? = fin?.record ?? store.get(rec.actionId)
        if let f = final { reflect(f) }
        let why2: String = final?.code ?? ""
        switch final?.state ?? .deliveryUnknown {
        case .submitted: return SendResult(code: .submitted, record: final, detail: "soumis au transport (preuve de soumission ; livraison non vérifiée)")
        case .verified: return SendResult(code: .verified, record: final, detail: "envoyé et vérifié")
        case .failed: return SendResult(code: .failed, record: final, detail: "rien n'est parti : " + why2)
        default: return SendResult(code: .deliveryUnknown, record: final, detail: "envoi INCERTAIN (" + why2 + ") — vérifie avant tout renvoi ; aucune relance automatique")
        }
    }

    /// Bouton ENVOYER de l'interface (provenance vérifiée par la route) : le geste explicite d'Ahadi sur la carte
    /// liée par empreinte crée l'approbation (source ui) et la consomme dans la même requête — même politique.
    public func sendFromUI(draftId: String, expectFNV: String, ctx: ExecContext, transport: SendTransport) -> SendResult {
        guard ctx.source == .ui else { return SendResult(code: .refused, record: nil, detail: "réservé au bouton d'envoi de l'interface") }
        guard let d = currentDraft(draftId) else { return SendResult(code: .notFound, record: nil, detail: "brouillon introuvable") }
        guard !expectFNV.isEmpty, expectFNV == DraftLint.hash(d) else {
            return SendResult(code: .changed, record: nil, detail: "le brouillon a changé depuis l'aperçu — relis la nouvelle version puis reconfirme")
        }
        guard let snap = snapshot(of: d), !snap.recipients.isEmpty else {
            return SendResult(code: .invalid, record: nil, detail: "aucun destinataire valide (adresse e-mail ou conversation Teams requise)")
        }
        var rec: SendRecord? = store.byIdempotencyKey(snap.idempotencyKey)
        if rec == nil || rec?.state == .failed || rec?.state == .cancelled || rec?.state == .awaitingApproval || rec?.state == .approved {
            if rec?.state != .approved { rec = request(draft: d, ctx: ctx) }
            guard let r0 = rec else { return SendResult(code: .invalid, record: nil, detail: "instantané impossible") }
            let t = now()
            let ap = SendApproval(nonce: SendApprovals.randomId(24), source: .ui, conversationId: ctx.conversationId, turnId: ctx.turnId,
                                  runId: ctx.runId, approvedAt: t, expiresAt: t.addingTimeInterval(120), consumedAt: nil)
            let x = transition(r0.actionId) { r in
                guard r.snapshotSha == snap.sha256 else { return false }
                if r.state == .approved { r.approval = nil; guard r.move(.awaitingApproval, at: t, code: "réapprouvé depuis l'interface") else { return false } }
                guard r.state == .awaitingApproval else { return false }
                r.approval = ap
                return r.move(.approved, at: t, code: "approuvé (ui)")
            }
            guard x?.applied == true else { return execute(draftId: draftId, ctx: ctx, transport: transport, uiNonce: "-") }
            return execute(draftId: draftId, ctx: ctx, transport: transport, uiNonce: ap.nonce)
        }
        return execute(draftId: draftId, ctx: ctx, transport: transport, uiNonce: "-")
    }

    /// Vérification de LIVRAISON (séparée de la soumission) : seul un identifiant du fournisseur fait « verified ».
    public func verify(draftId: String, verifier: SendVerifier) -> SendResult {
        guard let rec = store.forDraft(draftId).last(where: { $0.state == .submitted || $0.state == .deliveryUnknown || $0.state == .verified }) else {
            return SendResult(code: .notFound, record: nil, detail: "aucun envoi soumis pour ce brouillon")
        }
        if rec.state == .verified { return SendResult(code: .verified, record: rec, detail: "déjà vérifié") }
        switch verifier.verify(rec) {
        case .confirmed(let mid, let method):
            guard !mid.isEmpty else { return SendResult(code: rec.state == .submitted ? .submitted : .deliveryUnknown, record: rec, detail: "aucun identifiant de message : non vérifié") }
            let t = now()
            let x = transition(rec.actionId) { r in
                guard r.state == .submitted || r.state == .deliveryUnknown else { return false }
                r.verification = VerificationEvidence(method: method, providerMessageId: mid, at: t)
                return r.move(.verified, at: t, code: method)
            }
            if let f = x?.record { reflect(f) }
            return SendResult(code: .verified, record: x?.record ?? rec, detail: "retrouvé par identifiant de message")
        case .notFound:
            return SendResult(code: rec.state == .submitted ? .submitted : .deliveryUnknown, record: rec, detail: "non retrouvé — à vérifier par Ahadi (jamais un faux vert)")
        case .ambiguous(let why):
            return SendResult(code: rec.state == .submitted ? .submitted : .deliveryUnknown, record: rec, detail: "vérification ambiguë : " + why)
        }
    }

    /// Ahadi tranche un envoi incertain depuis l'interface (« pas parti ») : failed, puis nouvelle approbation possible.
    public func resolveUnknown(actionId: String, notSent: Bool, ctx: ExecContext) -> SendResult {
        guard ctx.source == .ui else { return SendResult(code: .refused, record: nil, detail: "réservé à l'interface") }
        guard notSent else { return SendResult(code: .refused, record: store.get(actionId), detail: "seul « pas parti » se tranche ici ; « parti » se prouve par la vérification") }
        let x = transition(actionId) { r in
            guard r.state == .deliveryUnknown else { return false }
            return r.move(.failed, at: now(), code: "Ahadi : pas parti")
        }
        guard let rr = x, rr.applied else { return SendResult(code: .refused, record: x?.record, detail: "aucun envoi incertain sous cet id") }
        writeDraft(rr.record.draftId, ["send_state": SendState.failed.rawValue, "status": "à valider"])
        return SendResult(code: .failed, record: rr.record, detail: "marqué « pas parti » : une nouvelle approbation est requise pour renvoyer")
    }

    /// Reprise PRUDENTE au démarrage : « sending » sans transport lancé → failed ; transport lancé → deliveryUnknown ;
    /// approbations non consommées → retombent (elles étaient liées à un tour qui n'existe plus). Aucune relance.
    @discardableResult
    public func recoverAtStartup() -> (failed: Int, unknown: Int, dropped: Int) {
        var f = 0, u = 0, dr = 0
        for r in store.all() where r.state == .sending || r.state == .approved {
            let x = transition(r.actionId) { rec in
                switch rec.state {
                case .sending:
                    if rec.transportStartedAt == nil { return rec.move(.failed, at: now(), code: "interrompu avant soumission") }
                    return rec.move(.deliveryUnknown, at: now(), code: "interrompu pendant la soumission")
                case .approved:
                    rec.approval = nil; rec.displayedTurnId = nil
                    return rec.move(.awaitingApproval, at: now(), code: "approbation perdue au redémarrage")
                default:
                    return false
                }
            }
            guard let rr = x, rr.applied else { continue }
            switch rr.record.state {
            case .failed: f += 1
            case .deliveryUnknown: u += 1; reflect(rr.record)
            default: dr += 1
            }
        }
        return (f, u, dr)
    }
}

// MARK: - Adaptateurs réels (Mail.app, volet Teams) — jamais appelés par les tests

public final class MailAppTransport: SendTransport {
    public init() {}
    public func submit(_ s: SendSnapshot, idempotencyKey: String) -> TransportOutcome {
        guard s.channel == .mail, !s.recipients.isEmpty else { return .rejected("instantané invalide pour Mail") }
        guard s.attachments.isEmpty else { return .rejected("pièces jointes non prises en charge par ce transport") }
        #if os(macOS)
        SendQueue.ensureMail()
        let r = Tools.osa(SendQueue.script(to: s.recipients, subject: s.subject, body: s.body, sender: s.sender), timeout: 40)
        if r.ok { return .submitted(SubmissionEvidence(kind: "mail_app_send", strength: .transportAccepted, providerMessageId: nil, at: Date())) }
        return MailAppTransport.classify(r.out)
        #else
        return .rejected("indisponible hors macOS")
        #endif
    }
    /// Refus CERTAINS avant soumission (autorisation, syntaxe) ; tout le reste peut être parti → ambigu.
    /// Codes fixes : la sortie d'osascript (qui peut citer le script) n'est jamais recopiée.
    static func classify(_ out: String) -> TransportOutcome {
        let low = out.lowercased()
        if low.contains("-1743") || low.contains("not authorized") || low.contains("-2740") || low.contains("-2741") { return .rejected("Mail a refusé le script (autorisation ou syntaxe)") }
        if low.contains("délai") || low.contains("-1712") || low.contains("timed out") { return .ambiguous("délai dépassé pendant l'envoi par Mail") }
        return .ambiguous("erreur de Mail après lancement de l'envoi")
    }
}

public final class TeamsPaneTransport: SendTransport {
    public typealias Page = ([String: Any], TimeInterval) -> [String: Any]?
    let page: Page
    public init(page: Page? = nil) {
        self.page = page ?? { (a: [String: Any], t: TimeInterval) -> [String: Any]? in UIPilot.shared.request("page", a, timeout: t) }
    }

    static func occurrences(_ hay: String, _ needle: String) -> Int {
        guard !needle.isEmpty else { return 0 }
        return hay.components(separatedBy: needle).count - 1
    }
    func readBack(_ probe: String) -> (count: Int, messageId: String?)? {
        guard let lu = page(["pane": "tm", "sub": "lire", "q": probe], 30) else { return nil }
        let txt = (lu["texte"] as? String) ?? (lu["extrait"] as? String) ?? ""
        return (TeamsPaneTransport.occurrences(txt, probe), lu["messageId"] as? String)
    }

    public func submit(_ s: SendSnapshot, idempotencyKey: String) -> TransportOutcome {
        guard s.channel == .teams, let target = s.recipients.first, !target.isEmpty else { return .rejected("conversation Teams cible manquante") }
        guard s.attachments.isEmpty else { return .rejected("pièces jointes non prises en charge par le volet Teams") }
        guard let etat = page(["pane": "tm", "sub": "etat"], 15), (etat["ok"] as? Bool) == true else { return .rejected("volet Teams injoignable ou session fermée") }
        guard let clic = page(["pane": "tm", "sub": "clic", "q": target], 20), (clic["ok"] as? Bool) == true else { return .rejected("conversation Teams introuvable dans le volet") }
        let probe = String(s.body.prefix(60))
        let before = readBack(probe)
        var typed = false
        for champ in ["Taper un nouveau message", "Type a new message", "Rédiger un nouveau message", "Nouveau message"] {
            if let r = page(["pane": "tm", "sub": "saisir", "q": champ, "value": s.body, "enter": false], 20), (r["ok"] as? Bool) == true { typed = true; break }
        }
        guard typed else { return .rejected("composeur Teams introuvable — rien n'a été saisi") }
        guard let enter = page(["pane": "tm", "sub": "touche", "q": "Enter"], 15) else { return .ambiguous("Entrée sans réponse du volet") }
        if (enter["ok"] as? Bool) == false { return .rejected("Entrée refusée par le volet — texte resté dans le composeur, rien n'est parti") }
        guard (enter["ok"] as? Bool) == true else { return .ambiguous("Entrée tentée, résultat du volet illisible") }
        guard !probe.isEmpty, let b0 = before, let after = readBack(probe) else { return .ambiguous("relecture du fil impossible") }
        if after.count > b0.count {
            let mid = after.messageId.flatMap { $0.isEmpty ? nil : $0 }
            return .submitted(SubmissionEvidence(kind: "teams_readback", strength: mid == nil ? .weakReadback : .providerMessageId, providerMessageId: mid, at: Date()))
        }
        return .ambiguous("relecture ambiguë : nouveau message non distingué dans le fil")
    }
}

/// Vérification Mail : Éléments envoyés (25 plus récents), objet + premier destinataire ; « verified » seulement si
/// UN message correspond et que son Message-ID est lu.
public final class MailSentVerifier: SendVerifier {
    public init() {}
    public func verify(_ r: SendRecord) -> VerifyOutcome {
        guard r.channel == .mail, let to1 = r.snapshot.recipients.first else { return .ambiguous("canal non vérifiable par Mail") }
        #if os(macOS)
        let sc = """
        tell application "Mail"
        set nb to 0
        set mid to ""
        set n to count of messages of sent mailbox
        if n > 25 then set n to 25
        repeat with k from 1 to n
        set m to message k of sent mailbox
        if (subject of m) is \(SendQueue.q(r.snapshot.subject)) then
        try
        if (address of first to recipient of m) is \(SendQueue.q(to1)) then
        set nb to nb + 1
        if mid is "" then set mid to (message id of m)
        end if
        end try
        end if
        end repeat
        return (nb as string) & "|" & mid
        end tell
        """
        let out = Tools.osa(sc, timeout: 25)
        guard out.ok else { return .ambiguous("Mail n'a pas répondu") }
        let parts = out.out.trimmingCharacters(in: .whitespacesAndNewlines).split(separator: "|", maxSplits: 1, omittingEmptySubsequences: false).map(String.init)
        let nb = Int(parts.first ?? "") ?? -1
        let mid = parts.count > 1 ? parts[1].trimmingCharacters(in: .whitespacesAndNewlines) : ""
        if nb == 0 { return .notFound }
        if nb == 1 && !mid.isEmpty { return .confirmed(providerMessageId: mid, method: "mail_sent_mailbox_message_id") }
        return .ambiguous(nb > 1 ? "plusieurs messages identiques dans les Éléments envoyés" : "réponse de Mail illisible")
        #else
        return .ambiguous("indisponible hors macOS")
        #endif
    }
}
