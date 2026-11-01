import Foundation
#if canImport(Network)
import Network
#endif

// V5-S (25/10/2026) — LECTURE DIRECTE DE LA BOÎTE ZOHO CAMPAGNE (campagne@nova-campagne.example). Branché dans Extras.extraRoutes().
//
// Voie choisie (une phrase) : IMAP en EXAMINE + BODY.PEEK : la lecture seule est garantie par le protocole lui-même
// (le serveur refuse toute écriture sur une boîte ouverte en EXAMINE, et PEEK ne pose jamais \Seen), sans application
// OAuth à enregistrer ni dépendance — Ahadi saisit lui-même un mot de passe d'application Zoho dans Nova, gardé au Trousseau.
//
// Règles codées en dur ici :
//  - liste blanche FERMÉE des commandes IMAP (ZohoGuard) : CAPABILITY, LOGIN, EXAMINE "INBOX", UID SEARCH, UID FETCH
//    (BODY.PEEK seulement), LOGOUT. STORE, COPY, MOVE, EXPUNGE, APPEND, SELECT, DELETE… sont IMPOSSIBLES : command()
//    refuse d'envoyer tout autre verbe (statut « REFUSED », rien ne part sur le réseau) ;
//  - le mot de passe d'application ne vit QU'AU Trousseau (KnownKeys.zoho, service « nova-zoho-imap ») ; il n'est jamais
//    journalisé, jamais mis dans un message d'erreur, jamais renvoyé à l'interface ; le journal ne porte que l'hôte,
//    le compte, des comptes, des durées et une classe d'erreur ;
//  - cache local (zoho_mail.json) : expéditeur, objet, date, extrait ≤ 600 caractères ;
//    un message qui contient un SECRET (code, mot de passe, clé — SecretsGuard, V5-V 25/10) n'a pas d'extrait stocké ;
//  - 25/10 (ordre d'Ahadi : « lire intégralement le contenu ») : le CORPS complet décodé (texte, ≤ 12 000 caractères,
//    lu par BODY.PEEK[TEXT]<0.20000>) vit dans un magasin DÉDIÉ, zoho_bodies.json (200 corps au plus) — même règle de
//    secret que l'extrait : un message à secret a son corps MASQUÉ en entier (état « masqué », aucun texte stocké).
//    Il alimente l'événement du Fil direct (état « lu », extrait) et l'outil mail_corps (boite « zoho ») ;
//    SCI / sujets RH restent lisibles dans la boîte (seul le CANAL Fundings les écarte) ;
//  - zéro brouillon, zéro envoi, zéro marquage, zéro déplacement : ce module LIT et n'émet rien vers Zoho d'autre
//    que les commandes de la liste blanche ;
//  - Fundings : chaque message est passé au correspondant (ZohoFundings) puis à Fundings.ingest — même anti-doublon,
//    même filtre d'étanchéité, mêmes notifications. Statut « confirmé » seulement si le domaine d'expédition est celui
//    du programme ; montant « visé » jamais présenté comme acquis ; une date exclue (exemple : le 26/10) est hors campagne.
//
// Auto-contrôle sur le Mac : GET /api/zoho/selftest (liste blanche + cas refusés + décodage + 6 messages types,
// attendus documentés dans conseil_24-10/V5_S_ZOHO.md).

// MARK: - Garde de lecture seule

enum ZohoGuard {
    /// Liste blanche FERMÉE. Tout autre verbe (STORE, UID STORE, COPY, UID COPY, MOVE, UID MOVE, EXPUNGE, UID EXPUNGE,
    /// APPEND, SELECT, DELETE, CREATE, RENAME, SUBSCRIBE, IDLE, AUTHENTICATE…) est refusé AVANT tout envoi.
    static let allowList: [String] = ["CAPABILITY", "LOGIN", "EXAMINE", "UID SEARCH", "UID FETCH", "LOGOUT"]

    static func allowed(verb: String, args: String) -> Bool {
        let v: String = verb.uppercased()
        guard allowList.contains(v) else { return false }
        if verb.contains("\r") || verb.contains("\n") || args.contains("\r") || args.contains("\n") { return false }
        let a: String = args.uppercased()
        switch v {
        case "CAPABILITY", "LOGOUT":
            return args.isEmpty
        case "EXAMINE":
            return a == "\"INBOX\""   // jamais SELECT : EXAMINE ouvre la boîte en lecture seule côté serveur
        case "LOGIN":
            return args.hasPrefix("\"")   // deux chaînes entre guillemets ; jamais journalisées
        case "UID SEARCH":
            // critères de recherche seulement (SINCE 15-Oct-2026, UNSEEN) : lettres, chiffres, espaces, tirets
            return !a.isEmpty && a.allSatisfy { (ch: Character) -> Bool in ch.isLetter || ch.isNumber || ch == " " || ch == "-" }
        case "UID FETCH":
            // BODY.PEEK obligatoire : BODY[…], RFC822, RFC822.TEXT et RFC822.HEADER poseraient \Seen.
            let noPeek: String = a.replacingOccurrences(of: "BODY.PEEK[", with: "")
            if noPeek.contains("BODY[") { return false }
            let noSize: String = a.replacingOccurrences(of: "RFC822.SIZE", with: "")
            if noSize.contains("RFC822") { return false }
            if a.contains("STORE") || a.contains("+FLAGS") || a.contains("-FLAGS") { return false }
            return true
        default:
            return false
        }
    }

    /// Cas d'auto-contrôle (servis par /api/zoho/selftest) : (verbe, arguments affichables, attendu).
    static let selfCases: [(String, String, Bool)] = [
        ("CAPABILITY", "", true),
        ("EXAMINE", "\"INBOX\"", true),
        ("UID SEARCH", "SINCE 15-Oct-2026", true),
        ("UID SEARCH", "UNSEEN", true),
        ("UID FETCH", "1:5 (UID FLAGS INTERNALDATE RFC822.SIZE BODY.PEEK[HEADER.FIELDS (FROM SUBJECT)] BODY.PEEK[TEXT]<0.6000>)", true),
        ("LOGOUT", "", true),
        ("SELECT", "\"INBOX\"", false),
        ("EXAMINE", "\"Sent\"", false),
        ("STORE", "1 +FLAGS (\\Seen)", false),
        ("UID STORE", "1 +FLAGS (\\Seen)", false),
        ("UID COPY", "1 \"Archive\"", false),
        ("UID MOVE", "1 \"Trash\"", false),
        ("COPY", "1 \"Archive\"", false),
        ("MOVE", "1 \"Trash\"", false),
        ("EXPUNGE", "", false),
        ("UID EXPUNGE", "1", false),
        ("APPEND", "\"INBOX\" {10}", false),
        ("DELETE", "\"INBOX\"", false),
        ("UID FETCH", "1 (BODY[TEXT])", false),
        ("UID FETCH", "1 (RFC822)", false),
        ("UID FETCH", "1 (RFC822.TEXT)", false),
        ("UID SEARCH", "SINCE 15-Oct-2026\r\nA1 STORE 1 +FLAGS (\\Seen)", false),
    ]
}

// MARK: - Client IMAP minimal (synchrone, à appeler hors du fil principal)

final class ZohoBox: @unchecked Sendable {
    private let lock: NSLock = NSLock()
    private var value: String = ""
    func set(_ v: String) { lock.lock(); value = v; lock.unlock() }
    func get() -> String { lock.lock(); defer { lock.unlock() }; return value }
}

struct ZohoUntagged {
    var texts: [String]   // segments de texte de la réponse ; un littéral suit chaque segment i < literals.count
    var literals: [Data]
}

struct ZohoReply {
    var status: String    // OK | NO | BAD | TIMEOUT | CLOSED | REFUSED
    var text: String
    var untagged: [ZohoUntagged]
}

final class ZohoIMAPClient: @unchecked Sendable {
    private let lock: NSLock = NSLock()
    private var buffer: Data = Data()
    private var closed: Bool = false
    private let dataSem: DispatchSemaphore = DispatchSemaphore(value: 0)
    private let queue: DispatchQueue = DispatchQueue(label: "nova.zoho.imap", qos: .utility)
    private var tagN: Int = 0
    let commandTimeout: TimeInterval = 30
    #if canImport(Network)
    private var conn: NWConnection? = nil
    #endif

    /// Chaîne IMAP entre guillemets ; nil si vide ou hors ASCII imprimable (aucun littéral : rien à négocier).
    static func quoted(_ s: String) -> String? {
        guard !s.isEmpty, s.unicodeScalars.allSatisfy({ (u: Unicode.Scalar) -> Bool in u.value >= 32 && u.value < 127 }) else { return nil }
        return "\"" + s.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"") + "\""
    }

    /// Taille d'un littéral IMAP en fin de ligne (« … {123} » ou « {123+} »), nil sinon.
    static func literalSize(_ line: String) -> Int? {
        guard line.hasSuffix("}"), let open = line.lastIndex(of: "{") else { return nil }
        let start: String.Index = line.index(after: open)
        let end: String.Index = line.index(before: line.endIndex)
        guard start <= end else { return nil }
        var inner: String = String(line[start..<end])
        if inner.hasSuffix("+") { inner = String(inner.dropLast()) }
        guard !inner.isEmpty, inner.count <= 9, let n = Int(inner), n >= 0 else { return nil }
        return n
    }

    /// nil = connecté (TLS) ; sinon un motif lisible, sans aucun secret.
    func connect(host: String, port: UInt16, timeout: TimeInterval) -> String? {
        #if canImport(Network)
        guard let p: NWEndpoint.Port = NWEndpoint.Port(rawValue: port) else { return "port invalide" }
        let c: NWConnection = NWConnection(host: NWEndpoint.Host(host), port: p, using: NWParameters.tls)
        let ready: DispatchSemaphore = DispatchSemaphore(value: 0)
        let state: ZohoBox = ZohoBox()
        c.stateUpdateHandler = { [weak self] (st: NWConnection.State) in
            switch st {
            case .ready:
                state.set("ready"); ready.signal()
            case .failed(_):
                state.set("failed"); ready.signal(); self?.markClosed()
            case .cancelled:
                state.set("cancelled"); ready.signal(); self?.markClosed()
            case .waiting(_):
                state.set("waiting")
            default:
                break
            }
        }
        conn = c
        c.start(queue: queue)
        let waited: DispatchTimeoutResult = ready.wait(timeout: .now() + timeout)
        let st: String = state.get()
        if waited == .timedOut || st != "ready" {
            close()
            if st == "failed" { return "connexion TLS refusée" }
            return "délai de connexion dépassé (réseau ou serveur injoignable)"
        }
        receiveNext(c)
        return nil
        #else
        return "lecture IMAP indisponible sur cette plateforme"
        #endif
    }

    #if canImport(Network)
    private func receiveNext(_ c: NWConnection) {
        c.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [weak self] (data: Data?, ctx: NWConnection.ContentContext?, isComplete: Bool, error: NWError?) in
            guard let self = self else { return }
            if let d = data, !d.isEmpty {
                self.lock.lock(); self.buffer.append(d); self.lock.unlock()
                self.dataSem.signal()
            }
            var stop: Bool = isComplete
            if let _ = error { stop = true }
            if stop { self.markClosed(); return }
            self.receiveNext(c)
        }
    }
    #endif

    private func markClosed() {
        lock.lock(); closed = true; lock.unlock()
        dataSem.signal()
    }

    func close() {
        #if canImport(Network)
        let c: NWConnection? = conn
        conn = nil
        c?.stateUpdateHandler = nil
        c?.cancel()
        #endif
        markClosed()
    }

    private func isClosed() -> Bool { lock.lock(); defer { lock.unlock() }; return closed }

    private func sendRaw(_ s: String) -> Bool {
        #if canImport(Network)
        guard let c: NWConnection = conn else { return false }
        let done: DispatchSemaphore = DispatchSemaphore(value: 0)
        let ok: ZohoBox = ZohoBox()
        c.send(content: Data(s.utf8), completion: NWConnection.SendCompletion.contentProcessed({ (err: NWError?) in
            if let _ = err { ok.set("err") } else { ok.set("ok") }
            done.signal()
        }))
        if done.wait(timeout: .now() + commandTimeout) == .timedOut { return false }
        return ok.get() == "ok"
        #else
        return false
        #endif
    }

    /// Une ligne (sans CRLF) ou nil (délai dépassé / connexion fermée).
    private func readLineData(deadline: Date) -> Data? {
        let crlf: Data = Data([13, 10])
        while true {
            lock.lock()
            if let r = buffer.range(of: crlf) {
                let line: Data = buffer.subdata(in: buffer.startIndex..<r.lowerBound)
                buffer.removeSubrange(buffer.startIndex..<r.upperBound)
                lock.unlock()
                return line
            }
            let shut: Bool = closed
            lock.unlock()
            if shut { return nil }
            let left: TimeInterval = deadline.timeIntervalSinceNow
            if left <= 0 { return nil }
            _ = dataSem.wait(timeout: .now() + left)
        }
    }

    private func readBytes(_ n: Int, deadline: Date) -> Data? {
        while true {
            lock.lock()
            if buffer.count >= n {
                let end: Data.Index = buffer.index(buffer.startIndex, offsetBy: n)
                let out: Data = buffer.subdata(in: buffer.startIndex..<end)
                buffer.removeSubrange(buffer.startIndex..<end)
                lock.unlock()
                return out
            }
            let shut: Bool = closed
            lock.unlock()
            if shut { return nil }
            let left: TimeInterval = deadline.timeIntervalSinceNow
            if left <= 0 { return nil }
            _ = dataSem.wait(timeout: .now() + left)
        }
    }

    /// Accueil du serveur (« * OK … »).
    func greeting(timeout: TimeInterval) -> Bool {
        guard let d = readLineData(deadline: Date().addingTimeInterval(timeout)) else { return false }
        let l: String = String(decoding: d, as: UTF8.self).uppercased()
        return l.hasPrefix("* OK") || l.hasPrefix("* PREAUTH")
    }

    /// Commande étiquetée — REFUSÉE (rien n'est envoyé) si le verbe ou ses arguments sortent de la liste blanche.
    func command(_ verb: String, _ args: String) -> ZohoReply {
        guard ZohoGuard.allowed(verb: verb, args: args) else {
            return ZohoReply(status: "REFUSED", text: "commande hors liste blanche (lecture seule)", untagged: [])
        }
        tagN += 1
        let tag: String = "N" + String(tagN)
        let line: String = tag + " " + verb + (args.isEmpty ? "" : " " + args) + "\r\n"
        guard sendRaw(line) else { return ZohoReply(status: "CLOSED", text: "envoi impossible", untagged: []) }
        return readReply(tag: tag, deadline: Date().addingTimeInterval(commandTimeout))
    }

    /// 26/10 (Ahadi : « fais le brouillon directement dans Gmail ») — SEULE écriture permise hors liste blanche, et
    /// seulement par cette méthode : repérer le dossier des brouillons (attribut \Drafts de LIST, RFC 6154).
    /// IMAP ne sait pas envoyer : un APPEND dans \Drafts ne peut que déposer un brouillon.
    func draftsMailbox() -> String? {
        tagN += 1
        let tag: String = "N" + String(tagN)
        guard sendRaw(tag + " LIST \"\" \"*\"\r\n") else { return nil }
        let r: ZohoReply = readReply(tag: tag, deadline: Date().addingTimeInterval(commandTimeout))
        guard r.status == "OK" else { return nil }
        for u in r.untagged {
            for t in u.texts where t.uppercased().hasPrefix("* LIST") && t.contains("\\Drafts") {
                // * LIST (\HasNoChildren \Drafts) "/" "[Gmail]/Brouillons"  → dernier jeton (entre guillemets ou nu)
                if t.hasSuffix("\""), let open = t.dropLast().lastIndex(of: "\"") {
                    let name: String = String(t[t.index(after: open)..<t.index(before: t.endIndex)])
                    if !name.isEmpty { return name }
                } else if let sp = t.lastIndex(of: " ") {
                    let name: String = String(t[t.index(after: sp)...])
                    if !name.isEmpty { return name }
                }
            }
        }
        return nil
    }

    /// Dépose UN message (RFC 5322 complet) dans le dossier des brouillons, drapeau \Draft. Refusé pour tout autre dossier.
    func appendDraft(mailbox: String, message: Data) -> ZohoReply {
        if mailbox.contains("\r") || mailbox.contains("\n") || mailbox.contains("\"") || mailbox.isEmpty {
            return ZohoReply(status: "REFUSED", text: "dossier invalide", untagged: [])
        }
        tagN += 1
        let tag: String = "N" + String(tagN)
        let head: String = tag + " APPEND \"" + mailbox + "\" (\\Draft) {" + String(message.count) + "}\r\n"
        guard sendRaw(head) else { return ZohoReply(status: "CLOSED", text: "envoi impossible", untagged: []) }
        guard let cont: Data = readLineData(deadline: Date().addingTimeInterval(commandTimeout)) else {
            return ZohoReply(status: "TIMEOUT", text: "pas d'invitation du serveur", untagged: [])
        }
        let cl: String = String(decoding: cont, as: UTF8.self)
        guard cl.hasPrefix("+") else { return ZohoReply(status: "NO", text: cl, untagged: []) }
        var payload: Data = message
        payload.append(Data([13, 10]))
        #if canImport(Network)
        guard let c: NWConnection = conn else { return ZohoReply(status: "CLOSED", text: "connexion fermée", untagged: []) }
        let done: DispatchSemaphore = DispatchSemaphore(value: 0)
        let ok: ZohoBox = ZohoBox()
        c.send(content: payload, completion: NWConnection.SendCompletion.contentProcessed({ (err: NWError?) in
            if let _ = err { ok.set("err") } else { ok.set("ok") }
            done.signal()
        }))
        if done.wait(timeout: .now() + commandTimeout) == .timedOut || ok.get() != "ok" {
            return ZohoReply(status: "CLOSED", text: "envoi du brouillon interrompu", untagged: [])
        }
        #else
        return ZohoReply(status: "CLOSED", text: "réseau indisponible", untagged: [])
        #endif
        return readReply(tag: tag, deadline: Date().addingTimeInterval(commandTimeout))
    }

    func login(email: String, password: String) -> ZohoReply {
        guard let u: String = ZohoIMAPClient.quoted(email), let p: String = ZohoIMAPClient.quoted(password) else {
            return ZohoReply(status: "REFUSED", text: "identifiants non pris en charge", untagged: [])
        }
        return command("LOGIN", u + " " + p)
    }

    private func readReply(tag: String, deadline: Date) -> ZohoReply {
        var out: [ZohoUntagged] = []
        while true {
            guard let ld: Data = readLineData(deadline: deadline) else {
                return ZohoReply(status: isClosed() ? "CLOSED" : "TIMEOUT", text: "", untagged: out)
            }
            var line: String = String(decoding: ld, as: UTF8.self)
            if line.hasPrefix(tag + " ") {
                let rest: String = String(line.dropFirst(tag.count + 1))
                let st: String = rest.split(separator: " ", maxSplits: 1).first.map { (x: Substring) -> String in String(x).uppercased() } ?? "BAD"
                return ZohoReply(status: st, text: rest, untagged: out)
            }
            var u: ZohoUntagged = ZohoUntagged(texts: [], literals: [])
            while true {
                if let n: Int = ZohoIMAPClient.literalSize(line), n <= 4_000_000 {
                    u.texts.append(line)
                    guard let lit: Data = readBytes(n, deadline: deadline) else {
                        return ZohoReply(status: isClosed() ? "CLOSED" : "TIMEOUT", text: "", untagged: out)
                    }
                    u.literals.append(lit)
                    guard let nd: Data = readLineData(deadline: deadline) else {
                        return ZohoReply(status: isClosed() ? "CLOSED" : "TIMEOUT", text: "", untagged: out)
                    }
                    line = String(decoding: nd, as: UTF8.self)
                } else {
                    u.texts.append(line)
                    break
                }
            }
            out.append(u)
        }
    }
}

// MARK: - Décodage MIME (en-têtes RFC 2047, quoted-printable, base64, multipart)

struct ZohoRaw {
    var uid: Int = 0
    var seen: Bool = false
    var internalDate: String = ""
    var size: Int = 0
    var header: Data = Data()
    var text: Data = Data()
}

struct ZohoParsed {
    var key: String = ""
    var uid: Int = 0
    var uidValidity: String = ""
    var messageId: String = ""
    var fromName: String = ""
    var fromAddr: String = ""
    var subject: String = ""
    var date: Date = Date()
    var text: String = ""      // texte décodé, ≤ 3 000 caractères, EN MÉMOIRE seulement (jamais stocké)
    var full: String = ""      // 25/10 : corps lisible complet (≤ 12 000 car.) — stocké au seul magasin zoho_bodies.json, secrets exclus
    var seen: Bool = false
    var size: Int = 0
}

enum ZohoMime {
    static func hexVal(_ b: UInt8) -> UInt8? {
        switch b {
        case 48...57: return b - 48
        case 65...70: return b - 55
        case 97...102: return b - 87
        default: return nil
        }
    }

    /// Quoted-printable (header = true : variante « Q » des mots encodés, « _ » = espace).
    static func qp(_ src: Data, header: Bool) -> Data {
        let a: [UInt8] = [UInt8](src)
        var out: [UInt8] = []
        out.reserveCapacity(a.count)
        var i: Int = 0
        while i < a.count {
            let b: UInt8 = a[i]
            if header && b == 95 { out.append(32); i += 1; continue }
            if b == 61 {
                if i + 1 < a.count && a[i + 1] == 10 { i += 2; continue }
                if i + 2 < a.count && a[i + 1] == 13 && a[i + 2] == 10 { i += 3; continue }
                if i + 2 < a.count, let h: UInt8 = hexVal(a[i + 1]), let l: UInt8 = hexVal(a[i + 2]) {
                    out.append(h * 16 + l); i += 3; continue
                }
            }
            out.append(b); i += 1
        }
        return Data(out)
    }

    /// Base64 tolérant : pad = true complète le dernier groupe (mots encodés) ; false le retire (corps tronqué à 6 000 octets).
    static func b64(_ s: String, pad: Bool) -> Data {
        var t: String = String(s.unicodeScalars.filter { (u: Unicode.Scalar) -> Bool in
            (u.value >= 65 && u.value <= 90) || (u.value >= 97 && u.value <= 122) || (u.value >= 48 && u.value <= 57) || u.value == 43 || u.value == 47 || u.value == 61
        }.map { (u: Unicode.Scalar) -> Character in Character(u) })
        let r: Int = t.count % 4
        if pad {
            if r == 2 { t += "==" } else if r == 3 { t += "=" } else if r == 1 { t = String(t.dropLast()) }
        } else if r != 0 {
            t = String(t.dropLast(r))
        }
        return Data(base64Encoded: t, options: [.ignoreUnknownCharacters]) ?? Data()
    }

    static func charsetName(_ raw: String) -> String {
        var c: String = raw.trimmingCharacters(in: CharacterSet(charactersIn: "\"' \t")).lowercased()
        if let star = c.firstIndex(of: "*") { c = String(c[c.startIndex..<star]) }
        return c
    }

    static func decodeBytes(_ d: Data, charset: String) -> String {
        let c: String = charsetName(charset)
        var enc: String.Encoding = .utf8
        if c == "iso-8859-1" || c == "latin1" || c == "iso8859-1" || c == "iso-8859-15" || c == "latin-1" { enc = .isoLatin1 }
        else if c == "windows-1252" || c == "cp1252" { enc = .windowsCP1252 }
        if let s = String(data: d, encoding: enc) { return s }
        if let s = String(data: d, encoding: .utf8) { return s }
        if let s = String(data: d, encoding: .windowsCP1252) { return s }
        return String(decoding: d, as: UTF8.self)
    }

    static let ewRx: NSRegularExpression = try! NSRegularExpression(pattern: #"=\?([^?\s]+)\?([bBqQ])\?([^?\s]*)\?="#, options: [])

    /// En-tête RFC 2047 (« =?UTF-8?B?…?= », « =?iso-8859-1?Q?…?= ») ; l'espace entre deux mots encodés est supprimé.
    static func decodeHeader(_ raw: String) -> String {
        let ns: NSString = raw as NSString
        let ms: [NSTextCheckingResult] = ewRx.matches(in: raw, options: [], range: NSRange(location: 0, length: ns.length))
        if ms.isEmpty { return raw }
        var out: String = ""
        var last: Int = 0
        var prevWord: Bool = false
        for m in ms {
            let gap: String = ns.substring(with: NSRange(location: last, length: m.range.location - last))
            if !(prevWord && gap.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty) { out += gap }
            let cs: String = ns.substring(with: m.range(at: 1))
            let mode: String = ns.substring(with: m.range(at: 2)).uppercased()
            let txt: String = ns.substring(with: m.range(at: 3))
            let bytes: Data = mode == "B" ? b64(txt, pad: true) : qp(Data(txt.utf8), header: true)
            out += decodeBytes(bytes, charset: cs)
            last = m.range.location + m.range.length
            prevWord = true
        }
        out += ns.substring(from: last)
        return out
    }

    /// En-têtes dépliés → dictionnaire (noms en minuscules, première occurrence).
    static func headers(_ raw: String) -> [String: String] {
        let unfolded: String = raw.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\n ", with: " ").replacingOccurrences(of: "\n\t", with: " ")
        var out: [String: String] = [:]
        for line in unfolded.components(separatedBy: "\n") {
            guard let i: String.Index = line.firstIndex(of: ":") else { continue }
            let k: String = line[line.startIndex..<i].trimmingCharacters(in: .whitespaces).lowercased()
            let v: String = line[line.index(after: i)...].trimmingCharacters(in: .whitespaces)
            if !k.isEmpty && out[k] == nil { out[k] = v }
        }
        return out
    }

    static func firstGroup(_ s: String, _ pattern: String) -> String? {
        guard let rx: NSRegularExpression = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else { return nil }
        let ns: NSString = s as NSString
        guard let m: NSTextCheckingResult = rx.firstMatch(in: s, options: [], range: NSRange(location: 0, length: ns.length)), m.numberOfRanges > 1 else { return nil }
        let r: NSRange = m.range(at: 1)
        if r.location == NSNotFound { return nil }
        return ns.substring(with: r)
    }

    /// Paramètre d'un en-tête Content-Type (boundary, charset).
    static func param(_ header: String, _ name: String) -> String {
        let pat: String = "(?:^|;)\\s*" + name + "\\s*=\\s*(?:\"([^\"]*)\"|([^;\\s]+))"
        guard let rx: NSRegularExpression = try? NSRegularExpression(pattern: pat, options: [.caseInsensitive]) else { return "" }
        let ns: NSString = header as NSString
        guard let m: NSTextCheckingResult = rx.firstMatch(in: header, options: [], range: NSRange(location: 0, length: ns.length)) else { return "" }
        for g in [1, 2] where g < m.numberOfRanges {
            let r: NSRange = m.range(at: g)
            if r.location != NSNotFound { return ns.substring(with: r) }
        }
        return ""
    }

    static func mediaType(_ ct: String) -> String {
        let t: String = (ct.split(separator: ";").first.map { (x: Substring) -> String in String(x) } ?? "").trimmingCharacters(in: .whitespaces).lowercased()
        return t.isEmpty ? "text/plain" : t
    }

    static func splitHeadBody(_ s: String) -> (String, String) {
        if let r = s.range(of: "\r\n\r\n") { return (String(s[s.startIndex..<r.lowerBound]), String(s[r.upperBound...])) }
        if let r = s.range(of: "\n\n") { return (String(s[s.startIndex..<r.lowerBound]), String(s[r.upperBound...])) }
        return ("", s)
    }

    /// bodyL1 : octets du corps lus en ISO-8859-1 (correspondance 1 octet = 1 caractère, sans perte).
    static func decodeBody(_ bodyL1: String, cte: String, charset: String) -> String {
        let raw: Data = bodyL1.data(using: .isoLatin1) ?? Data(bodyL1.utf8)
        let c: String = cte.lowercased().trimmingCharacters(in: .whitespaces)
        var bytes: Data = raw
        if c == "quoted-printable" { bytes = qp(raw, header: false) }
        else if c == "base64" { bytes = b64(bodyL1, pad: false) }
        return decodeBytes(bytes, charset: charset)
    }

    static func stripHTML(_ s: String) -> String {
        var t: String = s
        for pat in ["(?is)<style[^>]*>.*?</style>", "(?is)<script[^>]*>.*?</script>", "(?is)<head[^>]*>.*?</head>"] {
            t = t.replacingOccurrences(of: pat, with: " ", options: .regularExpression)
        }
        t = t.replacingOccurrences(of: "(?i)<br\\s*/?>|</p>|</div>|</tr>|</li>|</h[1-6]>", with: "\n", options: .regularExpression)
        t = t.replacingOccurrences(of: "<[^>]+>", with: " ", options: .regularExpression)
        let ents: [(String, String)] = [("&nbsp;", " "), ("&amp;", "&"), ("&lt;", "<"), ("&gt;", ">"), ("&quot;", "\""), ("&#39;", "'"), ("&apos;", "'"), ("&rsquo;", "’"), ("&#8217;", "’")]
        for (a, b) in ents { t = t.replacingOccurrences(of: a, with: b) }
        return t
    }

    /// Premier text/plain (repli : text/html débarrassé de ses balises), multipart jusqu'à 3 niveaux.
    static func text(contentType: String, cte: String, bodyL1: String, depth: Int) -> String {
        let ct: String = contentType.isEmpty ? "text/plain" : contentType
        let media: String = mediaType(ct)
        if media.hasPrefix("multipart/") {
            let b: String = param(ct, "boundary")
            if b.isEmpty || depth > 3 { return "" }
            let parts: [String] = bodyL1.components(separatedBy: "--" + b)
            var html: String = ""
            for (i, part) in parts.enumerated() {
                if i == 0 { continue }            // préambule
                if part.hasPrefix("--") { break } // délimiteur de fin
                let hb: (String, String) = splitHeadBody(part)
                let hh: [String: String] = headers(hb.0)
                let pct: String = hh["content-type"] ?? "text/plain"
                let pm: String = mediaType(pct)
                let pcte: String = hh["content-transfer-encoding"] ?? ""
                if pm.hasPrefix("multipart/") {
                    let t: String = text(contentType: pct, cte: pcte, bodyL1: hb.1, depth: depth + 1)
                    if !t.isEmpty { return t }
                } else if pm == "text/plain" {
                    let t: String = decodeBody(hb.1, cte: pcte, charset: param(pct, "charset"))
                    if !t.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return t }
                } else if pm == "text/html" && html.isEmpty {
                    html = stripHTML(decodeBody(hb.1, cte: pcte, charset: param(pct, "charset")))
                }
            }
            return html
        }
        let t: String = decodeBody(bodyL1, cte: cte, charset: param(ct, "charset"))
        return media == "text/html" ? stripHTML(t) : t
    }

    /// Texte aplati (lignes citées « > » retirées), borné à n caractères.
    static func flat(_ s: String, _ n: Int) -> String {
        let lines: [String] = s.components(separatedBy: CharacterSet.newlines).filter { (l: String) -> Bool in
            !l.trimmingCharacters(in: .whitespaces).hasPrefix(">")
        }
        let f: String = lines.joined(separator: " ").replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression).trimmingCharacters(in: .whitespacesAndNewlines)
        return f.count <= n ? f : String(f.prefix(n)) + "…"
    }

    /// 25/10 : corps LISIBLE complet — sauts de ligne gardés, blancs et lignes vides répétées réduits, borné à n caractères.
    static func readable(_ s: String, _ n: Int) -> String {
        let unix: String = s.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n")
        var out: [String] = []
        var blank: Int = 0
        for raw in unix.components(separatedBy: "\n") {
            let l: String = raw.replacingOccurrences(of: "[ \t\u{00A0}]+", with: " ", options: .regularExpression).trimmingCharacters(in: .whitespaces)
            if l.isEmpty {
                blank += 1
                if blank > 1 { continue }
            } else {
                blank = 0
            }
            out.append(l)
        }
        let t: String = out.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
        if t.count <= n { return t }
        return String(t.prefix(n)) + "…"
    }

    static func address(_ raw: String) -> (name: String, addr: String) {
        let d: String = decodeHeader(raw).trimmingCharacters(in: .whitespaces)
        if let lt: String.Index = d.lastIndex(of: "<"), let gt: String.Index = d.lastIndex(of: ">"), lt < gt {
            let a: String = String(d[d.index(after: lt)..<gt]).trimmingCharacters(in: .whitespaces).lowercased()
            let n: String = String(d[d.startIndex..<lt]).trimmingCharacters(in: CharacterSet(charactersIn: "\"' \t"))
            return (n, a)
        }
        return ("", d.trimmingCharacters(in: CharacterSet(charactersIn: "<>\"' \t")).lowercased())
    }

    static func domain(_ addr: String) -> String {
        guard addr.contains("@"), let last = addr.split(separator: "@").last else { return "" }
        return String(last).lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "> \t"))
    }

    static func posix(_ fmt: String) -> DateFormatter {
        let f: DateFormatter = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(identifier: "UTC") ?? TimeZone.current
        f.dateFormat = fmt
        return f
    }
    static func internalDate(_ s: String) -> Date? {
        posix("d-MMM-yyyy HH:mm:ss Z").date(from: s.trimmingCharacters(in: .whitespaces))
    }
    static func headerDate(_ s: String) -> Date? {
        var t: String = s.trimmingCharacters(in: .whitespaces)
        if let p = t.range(of: " (") { t = String(t[t.startIndex..<p.lowerBound]) }
        for fmt in ["EEE, d MMM yyyy HH:mm:ss Z", "d MMM yyyy HH:mm:ss Z", "EEE, d MMM yyyy HH:mm Z"] {
            if let d: Date = posix(fmt).date(from: t) { return d }
        }
        return nil
    }

    /// Une réponse « * n FETCH (…) » → champs bruts ; nil si ce n'est pas un FETCH.
    static func parseFetch(_ u: ZohoUntagged) -> ZohoRaw? {
        guard let first: String = u.texts.first, first.range(of: " FETCH ", options: .caseInsensitive) != nil else { return nil }
        var r: ZohoRaw = ZohoRaw()
        let all: String = u.texts.joined(separator: " ")
        if let v: String = firstGroup(all, #"\bUID (\d+)"#) { r.uid = Int(v) ?? 0 }
        if let v: String = firstGroup(all, #"FLAGS \(([^)]*)\)"#) { r.seen = v.range(of: "\\Seen", options: .caseInsensitive) != nil }
        if let v: String = firstGroup(all, #"INTERNALDATE "([^"]+)""#) { r.internalDate = v }
        if let v: String = firstGroup(all, #"RFC822\.SIZE (\d+)"#) { r.size = Int(v) ?? 0 }
        for (i, lit) in u.literals.enumerated() where i < u.texts.count {
            let before: String = u.texts[i].uppercased()
            let hi: Range<String.Index>? = before.range(of: "BODY[HEADER", options: .backwards)
            let ti: Range<String.Index>? = before.range(of: "BODY[TEXT", options: .backwards)
            var isHeader: Bool = false
            if let h = hi {
                if let t = ti { isHeader = t.lowerBound < h.lowerBound } else { isHeader = true }
            }
            if isHeader { r.header = lit } else if ti != nil { r.text = lit }
        }
        return r.uid > 0 ? r : nil
    }

    static func parse(_ r: ZohoRaw, uidValidity: String) -> ZohoParsed {
        var m: ZohoParsed = ZohoParsed()
        let hText: String = String(data: r.header, encoding: .utf8) ?? (String(data: r.header, encoding: .isoLatin1) ?? "")
        let hh: [String: String] = headers(hText)
        let from: (name: String, addr: String) = address(hh["from"] ?? "")
        m.fromName = String(from.name.prefix(120))
        m.fromAddr = String(from.addr.prefix(160))
        m.subject = String(decodeHeader(hh["subject"] ?? "").replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression).trimmingCharacters(in: .whitespaces).prefix(240))
        m.messageId = String((hh["message-id"] ?? "").trimmingCharacters(in: CharacterSet(charactersIn: "<> \t")).prefix(240))
        m.date = internalDate(r.internalDate) ?? (headerDate(hh["date"] ?? "") ?? Date())
        let bodyL1: String = String(data: r.text, encoding: .isoLatin1) ?? ""
        let decoded: String = text(contentType: hh["content-type"] ?? "", cte: hh["content-transfer-encoding"] ?? "", bodyL1: bodyL1, depth: 0)
        m.text = String(decoded.prefix(3000))
        m.full = readable(decoded, 12000)   // 25/10 : corps complet lisible (magasin dédié, voir Zoho.bodiesFile)
        m.uid = r.uid
        m.uidValidity = uidValidity
        m.seen = r.seen
        m.size = r.size
        m.key = m.messageId.isEmpty ? "uid:" + uidValidity + ":" + String(r.uid) + ":" + r.internalDate : "mid:" + m.messageId.lowercased()
        return m
    }
}

// MARK: - Correspondance message → événement Fundings (table de règles relisible)

struct ZohoProg {
    let id: String          // id du dossier Fundings (Fundings.seedProgrammes)
    let domains: [String]   // domaines d'expédition du programme LUI-MÊME → preuve (statut « confirmé »)
    let names: [String]     // noms reconnus dans l'expéditeur ou l'objet (SANS preuve)
    let needs: [String]     // domaine ou nom trop larges : un de ces mots doit figurer dans l'objet
}

struct ZohoRule {
    let categorie: String   // valeur acceptée par Fundings.canonCategorie
    let keys: [String]      // fragments en minuscules SANS accents (texte replié par Fundings.fold)
}

enum ZohoFundings {
    /// Programmes du dossier (ordre = priorité ; un domaine partagé passe d'abord par l'entrée la plus précise).
    static let programmes: [ZohoProg] = [
        ZohoProg(id: "cloudflare", domains: ["cloudflare.com"], names: ["cloudflare"], needs: []),
        ZohoProg(id: "posthog", domains: ["posthog.com"], names: ["posthog"], needs: []),
        ZohoProg(id: "exa", domains: ["exa.ai"], names: ["exa", "exa grants"], needs: []),
        ZohoProg(id: "speechmatics", domains: ["speechmatics.com"], names: ["speechmatics"], needs: []),
        ZohoProg(id: "mitsolve", domains: ["solve.mit.edu", "mit.edu"], names: ["mit solve"], needs: ["solve"]),
        ZohoProg(id: "techstars", domains: ["techstars.com"], names: ["techstars"], needs: []),
        ZohoProg(id: "yc", domains: ["ycombinator.com"], names: ["y combinator", "ycombinator"], needs: []),
        ZohoProg(id: "a16z", domains: ["a16z.com"], names: ["a16z", "speedrun"], needs: []),
        ZohoProg(id: "neon", domains: ["neon.tech", "databricks.com"], names: ["neon"], needs: []),
        ZohoProg(id: "dohatch", domains: ["digitalocean.com"], names: ["digitalocean hatch"], needs: ["hatch"]),
        ZohoProg(id: "digitalocean", domains: ["digitalocean.com"], names: ["digitalocean"], needs: []),
        ZohoProg(id: "e2b", domains: ["e2b.dev"], names: ["e2b"], needs: []),
        ZohoProg(id: "statsig", domains: ["statsig.com"], names: ["statsig"], needs: []),
        ZohoProg(id: "infobip", domains: ["infobip.com"], names: ["infobip"], needs: []),
        ZohoProg(id: "gladia", domains: ["gladia.io"], names: ["gladia"], needs: []),
        ZohoProg(id: "runware", domains: ["runware.ai"], names: ["runware"], needs: []),
        ZohoProg(id: "cartesia", domains: ["cartesia.ai"], names: ["cartesia"], needs: []),
        ZohoProg(id: "brightdata", domains: ["brightdata.com"], names: ["bright data", "brightdata"], needs: []),
        ZohoProg(id: "cloudrift", domains: ["cloudrift.ai"], names: ["cloudrift"], needs: []),
        ZohoProg(id: "runpod", domains: ["runpod.io"], names: ["runpod"], needs: []),
        ZohoProg(id: "ovhcloud", domains: ["ovhcloud.com", "ovh.com", "ovh.net"], names: ["ovhcloud"], needs: []),
        ZohoProg(id: "emergent", domains: ["mercatus.org", "gmu.edu"], names: ["emergent ventures"], needs: ["emergent"]),
        ZohoProg(id: "alibaba", domains: ["alibabacloud.com", "alibaba-inc.com"], names: ["alibaba cloud"], needs: []),
        ZohoProg(id: "aws", domains: ["aws.amazon.com", "amazonaws.com", "amazon.com"], names: ["aws", "amazon web services"], needs: ["aws", "activate", "credit", "startup", "case", "project"]),
        ZohoProg(id: "deepgram", domains: ["deepgram.com"], names: ["deepgram"], needs: []),
        ZohoProg(id: "zoho", domains: ["zoho.com", "zoho.eu", "zohomail.com", "zohocorp.com"], names: ["zoho mail"], needs: ["premium", "trial", "essai", "subscription", "abonnement", "renew", "renouvel", "billing", "factur", "plan"]),
        ZohoProg(id: "sentry", domains: ["sentry.io"], names: ["sentry"], needs: []),
        ZohoProg(id: "algolia", domains: ["algolia.com", "algolia.io"], names: ["algolia"], needs: []),
        ZohoProg(id: "amplitude", domains: ["amplitude.com"], names: ["amplitude"], needs: []),
        ZohoProg(id: "youcom", domains: ["you.com"], names: ["you.com"], needs: []),
        ZohoProg(id: "composio", domains: ["composio.dev"], names: ["composio"], needs: []),
        ZohoProg(id: "amd", domains: ["amd.com"], names: ["amd developer"], needs: []),
        ZohoProg(id: "retool", domains: ["retool.com"], names: ["retool"], needs: []),
        ZohoProg(id: "daytona", domains: ["daytona.io"], names: ["daytona"], needs: []),
        ZohoProg(id: "reducto", domains: ["reducto.ai"], names: ["reducto"], needs: []),
        ZohoProg(id: "mongodb", domains: ["mongodb.com"], names: ["mongodb"], needs: []),
        ZohoProg(id: "microsoft", domains: ["microsoft.com"], names: ["microsoft for startups"], needs: ["startup", "founders"]),
        ZohoProg(id: "koyeb", domains: ["koyeb.com"], names: ["koyeb"], needs: []),
        ZohoProg(id: "notion", domains: ["makenotion.com", "notion.so"], names: ["notion"], needs: []),
        ZohoProg(id: "ibm", domains: ["ibm.com"], names: ["ibm"], needs: []),
        ZohoProg(id: "intercom", domains: ["intercom.com", "intercom.io"], names: ["intercom"], needs: []),
    ]

    /// Sans domaine du programme (nom seul), l'OBJET doit parler d'une candidature : une newsletter qui cite un nom ne compte pas.
    static let subjectCues: [String] = ["application", "applied", "apply", "candidature", "startup", "program", "credit", "grant", "accelerator", "founder", "approved", "declined", "review"]

    /// Catégories : première règle qui correspond gagne (ordre = priorité). Fragments repliés (minuscules, sans accents, ’ → ').
    static let rules: [ZohoRule] = [
        // Dans chaque règle, les fragments précis d'abord, les génériques (« unfortunately », « congratulations ») en dernier :
        // la phrase clé citée est celle du fragment reconnu.
        ZohoRule(categorie: "REFUS", keys: ["not able to approve", "unable to approve", "unable to offer", "not been selected", "not selected", "not been approved", "not approved", "has been declined", "was declined", "have declined", "been rejected", "not eligible", "n'avons pas retenu", "pas ete retenue", "pas ete retenu", "we regret", "regrettons", "unfortunately", "malheureusement"]),
        ZohoRule(categorie: "APPROBATION", keys: ["credits have been applied", "credits have been added", "credits have been granted", "credits granted", "you've been approved", "you have been approved", "has been approved", "application approved", "accepted into", "you've been awarded", "you have been awarded", "a ete acceptee", "a ete approuvee", "credits ont ete", "congratulations", "felicitations"]),
        ZohoRule(categorie: "ACTION REQUISE", keys: ["action required", "action needed", "action requise", "please complete", "complete your", "please verify", "verify your", "please submit", "submit your", "missing information", "additional information", "please provide", "please confirm", "please upload", "merci de completer", "merci de fournir", "veuillez completer", "veuillez fournir"]),
        ZohoRule(categorie: "SIMPLE ACCUSÉ", keys: ["received your application", "application received", "application has been received", "application was received", "thanks for applying", "thank you for applying", "thank you for your application", "thanks for your application", "we have received", "we've received", "submission received", "thanks for your interest", "candidature recue", "avons bien recu", "bien recu"]),
        ZohoRule(categorie: "RÉPONSE ATTENDUE", keys: ["under review", "being reviewed", "in review", "we will get back", "we'll get back", "we will be in touch", "we'll be in touch", "will review", "reviewing your application", "decision by", "en cours d'examen", "en cours d'etude", "nous reviendrons"]),
    ]

    static let statutLabel: [String: String] = [
        "APPROBATION": "Approuvé", "REFUS": "Refusé", "ACTION REQUISE": "Action requise",
        "RÉPONSE ATTENDUE": "En revue — réponse attendue", "SIMPLE ACCUSÉ": "Accusé de réception",
    ]

    /// Sujets RH (probation, employeur) : HORS CAMPAGNE — le message n'entre jamais au canal.
    static let horsCampagneRx: NSRegularExpression = try! NSRegularExpression(pattern: #"probation|revue de confirmation|confirmation review|p[ée]riode d'essai|save\s+the\s+children|\bSCI\b"#, options: [.caseInsensitive])
    /// Codes et secrets : jamais d'extrait stocké ni de phrase clé (en plus de Fundings.forbiddenRx).
    static let secretRx: NSRegularExpression = try! NSRegularExpression(pattern: #"verification code|security code|one[- ]time|login code|sign[- ]in code|passcode|code\s*:\s*\d{4,}|\b\d{6}\b is your"#, options: [.caseInsensitive])

    static func rx(_ r: NSRegularExpression, _ s: String) -> Bool {
        r.firstMatch(in: s, options: [], range: NSRange(location: 0, length: (s as NSString).length)) != nil
    }
    static func sensitive(_ s: String) -> Bool { Fundings.forbidden(s) || rx(secretRx, s) }

    static func folded(_ s: String) -> String {
        Fundings.fold(s).lowercased().replacingOccurrences(of: "’", with: "'")
    }
    static func wordMatch(_ hay: String, _ needle: String) -> Bool {
        let pat: String = "\\b" + NSRegularExpression.escapedPattern(for: needle) + "\\b"
        return hay.range(of: pat, options: [.regularExpression, .caseInsensitive]) != nil
    }

    static func matchProgramme(fromAddr: String, fromName: String, subject: String) -> (prog: ZohoProg, own: Bool)? {
        let dom: String = ZohoMime.domain(fromAddr)
        let subjF: String = folded(subject)
        func needsOK(_ p: ZohoProg) -> Bool { p.needs.isEmpty || p.needs.contains(where: { (w: String) -> Bool in subjF.contains(w) }) }
        if !dom.isEmpty {
            for p in programmes {
                let domOK: Bool = p.domains.contains(where: { (d: String) -> Bool in dom == d || dom.hasSuffix("." + d) })
                if domOK && needsOK(p) { return (p, true) }
            }
        }
        guard subjectCues.contains(where: { (w: String) -> Bool in subjF.contains(w) }) else { return nil }
        let hay: String = folded(fromName + " " + subject)
        for p in programmes {
            if p.names.contains(where: { (n: String) -> Bool in wordMatch(hay, n) }) && needsOK(p) { return (p, false) }
        }
        return nil
    }

    static func categorise(_ text: String) -> (categorie: String, key: String)? {
        let t: String = folded(text)
        for r in rules {
            for k in r.keys where t.contains(k) { return (r.categorie, k) }
        }
        return nil
    }

    /// Phrase du texte (original, non replié) qui contient le fragment reconnu ; ≤ 280 caractères.
    static func sentence(_ text: String, containing key: String) -> String {
        let cut: String = text.replacingOccurrences(of: "([.!?])\\s+", with: "$1\n", options: .regularExpression)
        for p in cut.components(separatedBy: CharacterSet.newlines) {
            if folded(p).contains(key) {
                let s: String = p.replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression).trimmingCharacters(in: .whitespaces)
                return s.count <= 280 ? s : String(s.prefix(280)) + "…"
            }
        }
        return ""
    }

    static func group(_ n: Int) -> String {
        let s: String = String(n)
        var out: String = ""
        for (i, ch) in s.enumerated() {
            if i > 0 && (s.count - i) % 3 == 0 { out += " " }
            out.append(ch)
        }
        return out
    }

    /// Premier montant en dollars EXPLICITEMENT écrit (« $10,000 », « 10 000 USD », « $5k »), sinon nil.
    static func amount(_ text: String) -> Double? {
        let pats: [String] = [#"(?:US\s?)?\$\s?(\d{1,3}(?:[,.\s]\d{3})+|\d+(?:\.\d+)?)\s?([kK])?\b"#,
                              #"(\d{1,3}(?:[,.\s]\d{3})+|\d+)\s?(?:USD|US\$|dollars)\b"#]
        for pat in pats {
            guard let r: NSRegularExpression = try? NSRegularExpression(pattern: pat, options: []) else { continue }
            let ns: NSString = text as NSString
            guard let m: NSTextCheckingResult = r.firstMatch(in: text, options: [], range: NSRange(location: 0, length: ns.length)) else { continue }
            var digits: String = ns.substring(with: m.range(at: 1))
            if digits.range(of: #"^\d{1,3}([,.\s]\d{3})+$"#, options: .regularExpression) != nil {
                digits = digits.filter { (c: Character) -> Bool in c.isNumber }
            }
            guard var v: Double = Double(digits) else { continue }
            if m.numberOfRanges > 2 {
                let kr: NSRange = m.range(at: 2)
                if kr.location != NSNotFound { v *= 1000 }
            }
            if v >= 1 && v <= 10_000_000 { return v }
        }
        return nil
    }

    static let months: [String: Int] = [
        "january": 1, "jan": 1, "february": 2, "feb": 2, "march": 3, "mar": 3, "april": 4, "apr": 4, "may": 5, "june": 6, "jun": 6,
        "july": 7, "jul": 7, "august": 8, "aug": 8, "september": 9, "sept": 9, "sep": 9, "october": 10, "oct": 10, "november": 11, "nov": 11,
        "december": 12, "dec": 12, "janvier": 1, "fevrier": 2, "mars": 3, "avril": 4, "mai": 5, "juin": 6, "juillet": 7, "aout": 8,
        "septembre": 9, "octobre": 10, "novembre": 11, "decembre": 12,
    ]
    static let cue: String = #"\b(?:by|before|until|no later than|deadline(?: is)?:?|due(?: by| on)?|closes?(?: on)?|avant le|d'ici le|jusqu'au|au plus tard le|date limite\s*:?)\s+(?:(?:mon|tue|wed|thu|fri|sat|sun|lun|mar|mer|jeu|ven|sam|dim)[a-z]*\.?,?\s+)?"#

    /// Échéance EXPLICITE (précédée d'un mot d'échéance) → « AAAA-MM-JJ » ; sinon "".
    static func deadline(_ text: String, messageDate: Date) -> String {
        let t: String = folded(text)
        var cal: Calendar = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "UTC") ?? TimeZone.current
        let msgYear: Int = cal.component(.year, from: messageDate)
        let msgDay: String = ZohoMime.posix("yyyy-MM-dd").string(from: messageDate)
        // (motif, index du groupe mois, index du groupe jour, index du groupe année, mois numérique ?)
        let forms: [(String, Int, Int, Int, Bool)] = [
            (cue + #"(20\d\d)-(\d\d)-(\d\d)"#, 2, 3, 1, true),
            (cue + #"([a-z]+)\.?\s+(\d{1,2})(?:st|nd|rd|th)?(?:,?\s+(20\d\d))?"#, 1, 2, 3, false),
            (cue + #"(\d{1,2})(?:st|nd|rd|th|er)?\s+(?:of\s+)?([a-z]+)\.?(?:,?\s+(20\d\d))?"#, 2, 1, 3, false),
        ]
        for f in forms {
            guard let r: NSRegularExpression = try? NSRegularExpression(pattern: f.0, options: [.caseInsensitive]) else { continue }
            let ns: NSString = t as NSString
            for m in r.matches(in: t, options: [], range: NSRange(location: 0, length: ns.length)) {
                func g(_ i: Int) -> String {
                    guard i < m.numberOfRanges else { return "" }
                    let rr: NSRange = m.range(at: i)
                    return rr.location == NSNotFound ? "" : ns.substring(with: rr)
                }
                let month: Int = f.4 ? (Int(g(f.1)) ?? 0) : (months[g(f.1)] ?? 0)
                let day: Int = Int(g(f.2)) ?? 0
                let yRaw: String = g(f.3)
                var year: Int = Int(yRaw) ?? msgYear
                guard month >= 1 && month <= 12 && day >= 1 && day <= 31 else { continue }
                var dc: DateComponents = DateComponents()
                dc.year = year; dc.month = month; dc.day = day
                guard let d: Date = cal.date(from: dc), cal.component(.day, from: d) == day else { continue }
                var s: String = String(format: "%04ld-%02ld-%02ld", year, month, day)
                if yRaw.isEmpty && s < msgDay {   // « by January 5 » écrit en décembre → l'année suivante
                    year += 1
                    s = String(format: "%04ld-%02ld-%02ld", year, month, day)
                }
                return s
            }
        }
        return ""
    }

    static func dayFR(_ d: Date) -> String { ZohoMime.posix("dd/MM").string(from: d) }

    /// (événement au format du contrat d'ingestion — Fundings.ingest — ou nil, motif lisible).
    static func map(_ m: ZohoParsed, account: String, exclude2610: Bool) -> (event: [String: Any]?, motif: String) {
        let all: String = m.subject + "\n" + m.text
        let dayISO: String = ZohoMime.posix("yyyy-MM-dd").string(from: m.date)
        if m.fromAddr == account.lowercased() || ZohoMime.domain(m.fromAddr) == "nova-campagne.example" {
            return (nil, "message de la boîte campagne elle-même — pas un message de programme")
        }
        if exclude2610 && dayISO == "2026-10-26" {
            return (nil, "message daté du 26/10/2026 — date exclue (exemple), exclu du canal")
        }
        if rx(horsCampagneRx, all) { return (nil, "hors campagne — exclu du canal") }
        guard let hit: (prog: ZohoProg, own: Bool) = matchProgramme(fromAddr: m.fromAddr, fromName: m.fromName, subject: m.subject) else {
            return (nil, "aucun programme du dossier reconnu")
        }
        guard let cat: (categorie: String, key: String) = categorise(all) else {
            return (nil, "programme « " + hit.prog.id + " » reconnu, aucune catégorie explicite dans le message")
        }
        let dom: String = ZohoMime.domain(m.fromAddr)
        let base: String = statutLabel[cat.categorie] ?? cat.categorie
        let statut: String = hit.own
            ? base + " — confirmé par message du programme (" + dom + ", " + dayFR(m.date) + ")"
            : base + " — NON confirmé : message hors domaine du programme (" + dayFR(m.date) + ")"
        let secret: Bool = sensitive(all)
        let phrase: String = secret ? "" : sentence(all, containing: cat.key)
        var montant: String = ""
        var acquisUSD: Double? = nil
        if cat.categorie != "REFUS", let v: Double = amount(all) {
            let label: String = group(Int(v.rounded())) + " $"
            let fa: String = folded(all)
            let grantCue: Bool = ["credits have been", "credit has been", "granted", "awarded", "applied to your account", "added to your account", "credits ont ete", "accordes"].contains(where: { (w: String) -> Bool in fa.contains(w) })
            if cat.categorie == "APPROBATION" && hit.own && grantCue {
                montant = label + " accordés (selon le message du programme)"
                acquisUSD = v
            } else {
                montant = label + " mentionnés dans le message — visés, non acquis"
            }
        }
        var ech: String = deadline(all, messageDate: m.date)
        if ech.hasPrefix("2026-10-26") { ech = "" }   // la date du 26/10 n'est jamais une échéance du canal
        let expediteur: String = m.fromName.isEmpty ? m.fromAddr : m.fromName + " <" + m.fromAddr + ">"
        let objet: String = Fundings.forbidden(m.subject) ? "(objet masqué — contenu sensible)" : m.subject
        var ev: [String: Any] = [
            "programme": hit.prog.id, "categorie": cat.categorie, "statut": statut, "montant": montant,
            "action": cat.categorie == "ACTION REQUISE" ? phrase : "", "echeance": ech,
            "expediteur": String(expediteur.prefix(160)), "objet": objet, "phrase_cle": phrase,
            "source": String(("Lecture directe Zoho · " + account).prefix(120)),
            "origine": "zoho-direct", "message_id": m.messageId.isEmpty ? m.key : m.messageId,
            "date_message": ISO8601DateFormatter().string(from: m.date),
        ]
        if hit.own { ev["preuve"] = "message_programme" }
        if let a: Double = acquisUSD { ev["montant_usd"] = a }
        return (ev, "programme « " + hit.prog.id + " » · " + cat.categorie + (hit.own ? " · domaine du programme" : " · sans preuve"))
    }
}

// MARK: - Boîte campagne : état, synchronisation, minuterie

struct ZohoCtx {
    let bus: Bus
    let settings: Settings
    let briefs: Briefs
    let keys: KeyStore
}

enum Zoho {
    static let file: JSONFile = JSONFile("zoho_mail.json")
    static let journal: Journal = Journal("zoho_journal.jsonl")   // hôte, compte, comptes, durées, classe d'erreur — jamais de secret
    static let lock: NSLock = NSLock()
    nonisolated(unsafe) static var syncing: Bool = false   // PHASE 1 (relu, protégé) : sous lock (sync, état)
    nonisolated(unsafe) static var schedulerStarted: Bool = false   // PHASE 1 (relu, protégé) : sous lock
    static let defaultAccount: String = "campagne@nova-campagne.example"
    static let defaultSince: String = "2026-10-15"
    static let servers: [String] = ["imappro.zoho.com", "imap.zoho.com", "imappro.zoho.eu", "imap.zoho.eu", "imappro.zoho.in", "imappro.zoho.com.au"]
    static let maxCache: Int = 400
    static let fetchItems: String = "(UID FLAGS INTERNALDATE RFC822.SIZE BODY.PEEK[HEADER.FIELDS (FROM TO SUBJECT DATE MESSAGE-ID CONTENT-TYPE CONTENT-TRANSFER-ENCODING)] BODY.PEEK[TEXT]<0.20000>)"   // 25/10 : 6 000 → 20 000 octets (corps complet lisible) — toujours BODY.PEEK, ZohoGuard inchangé
    static let lectureSeule: String = "Lecture seule — Nova ne marque, ne déplace et n'envoie rien (IMAP EXAMINE + BODY.PEEK)."

    static func load() -> [String: Any] { file.read(default: [String: Any]()) }

    /// Lecture directe active = boîte connectée ET au moins une synchronisation réussie (bascule du canal Fundings).
    static func directActive() -> Bool {
        lock.lock(); let o: [String: Any] = load(); lock.unlock()
        return (o["connected"] as? Bool) == true && (o["synced_once"] as? Bool) == true
    }

    static func status(keys: KeyStore) -> [String: Any] {
        lock.lock(); let o: [String: Any] = load(); let busy: Bool = syncing; lock.unlock()
        let hasPw: Bool = keys.value(KnownKeys.zoho) != nil
        let msgs: [[String: Any]] = (o["messages"] as? [[String: Any]]) ?? []
        let flag: Bool = (o["connected"] as? Bool) == true
        var err: Any = o["error"] ?? NSNull()
        if flag && !hasPw { err = "Mot de passe d'application absent du Trousseau — reconnecte la boîte." }
        return ["connected": flag && hasPw, "account": (o["account"] as? String) ?? defaultAccount,
                "server": (o["server"] as? String) ?? "", "server_choice": (o["server_choice"] as? String) ?? "auto",
                "last_sync": o["last_sync"] ?? NSNull(), "last_ok": o["last_ok"] ?? NSNull(), "count": msgs.count,
                "unread": o["unread"] ?? NSNull(), "error": err, "error_class": o["error_class"] ?? NSNull(),
                "synced_once": (o["synced_once"] as? Bool) == true, "direct_active": flag && (o["synced_once"] as? Bool) == true,
                "syncing": busy, "fundings_events": (o["fundings_events"] as? Int) ?? 0,
                "lecture_seule": lectureSeule, "keychain_service": KnownKeys.zoho.service, "poll_s": 300]
    }

    static func messages(limit: Int) -> [[String: Any]] {
        lock.lock(); let o: [String: Any] = load(); lock.unlock()
        let msgs: [[String: Any]] = (o["messages"] as? [[String: Any]]) ?? []
        return Array(msgs.sorted { (a: [String: Any], b: [String: Any]) -> Bool in ((a["date"] as? String) ?? "") > ((b["date"] as? String) ?? "") }.prefix(limit))
    }

    /// 25/10 : vue texte (lecture seule, depuis la copie locale déjà synchronisée) pour les outils mail des agents —
    /// avant, aucune voie de lecture Zoho n'existait côté outils (autodiagnostic de Nova).
    static func toolText(limit: Int) -> String {
        let ms: [[String: Any]] = messages(limit: limit)
        if ms.isEmpty { return "" }
        var lines: [String] = []
        for m in ms {
            let who: String = (m["from_name"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? ((m["from"] as? String) ?? "?")
            let subj: String = (m["subject"] as? String) ?? ""
            let day: String = String(((m["date"] as? String) ?? "").prefix(16)).replacingOccurrences(of: "T", with: " ")
            let ex: String = String(((m["excerpt"] as? String) ?? "").prefix(220))
            var line: String = "- " + day + " · " + who + " — " + subj
            if !ex.isEmpty { line += "\n  " + ex }
            lines.append(line)
        }
        let head: String = "Zoho Mail (copie locale en lecture seule, \(ms.count) plus récents) :\n"
        let tail: String = "\n(corps complet d'un message Zoho : mail_corps {\"de\",\"objet\",\"boite\":\"zoho\"} — le magasin des corps fait foi)"
        return head + lines.joined(separator: "\n") + tail
    }

    // MARK: 25/10 — magasin des corps complets (zoho_bodies.json)

    static let bodiesFile: JSONFile = JSONFile("zoho_bodies.json")
    static let bodiesCap: Int = 200

    /// Ligne du magasin : corps lisible (état « lu »), ou rien (état « masqué » : secret ; « vide » : aucun texte lisible).
    static func bodyRow(_ m: ZohoParsed, subject: String, secret: Bool) -> [String: Any] {
        let iso: String = ISO8601DateFormatter().string(from: m.date)
        var row: [String: Any] = ["from": m.fromAddr, "from_name": m.fromName, "subject": subject, "date": iso, "ts": nowISO()]
        if secret {
            row["state"] = "masqué"
            row["body"] = ""
            row["len"] = 0
        } else if m.full.count < 10 {
            row["state"] = "vide"
            row["body"] = ""
            row["len"] = m.full.count
        } else {
            row["state"] = "lu"
            row["body"] = m.full
            row["len"] = m.full.count
        }
        return row
    }

    /// Champs d'enrichissement de l'événement du Fil direct (mêmes clés que BodyFetcher : body, bodyVia, bodyExcerpt).
    static func feedExtra(row: [String: Any], key: String) -> [String: Any] {
        let state: String = (row["state"] as? String) ?? ""
        var extra: [String: Any] = ["zoho_key": key]
        if state == "lu" {
            let b: String = (row["body"] as? String) ?? ""
            extra["body"] = "lu"
            extra["bodyVia"] = "zoho-imap"
            extra["bodyExcerpt"] = String(b.prefix(1500))
        } else if state == "masqué" {
            extra["body"] = "masqué"
        }
        return extra
    }

    /// À appeler SOUS `lock`. Fusionne les corps lus et garde les 200 plus récents (date du message).
    static func storeBodies(_ rows: [String: [String: Any]]) {
        var all: [String: [String: Any]] = bodiesFile.read(default: [String: [String: Any]]())
        for (k, v) in rows { all[k] = v }
        if all.count > bodiesCap {
            let sorted: [(key: String, value: [String: Any])] = all.sorted { (a: (key: String, value: [String: Any]), b: (key: String, value: [String: Any])) -> Bool in
                ((a.value["date"] as? String) ?? "") > ((b.value["date"] as? String) ?? "")
            }
            var kept: [String: [String: Any]] = [:]
            for e in sorted.prefix(bodiesCap) { kept[e.key] = e.value }
            all = kept
        }
        bodiesFile.write(all)
    }

    /// UIDs du cache (même UIDVALIDITY, encore présents dans la recherche) dont le corps manque au magasin — 20 au plus.
    static func backfillUIDs(cache: [[String: Any]], uidValidity: String, prevValidity: String, present: Set<Int>) -> [Int] {
        if uidValidity.isEmpty || prevValidity != uidValidity { return [] }
        lock.lock()
        let have: [String: [String: Any]] = bodiesFile.read(default: [String: [String: Any]]())
        lock.unlock()
        let sorted: [[String: Any]] = cache.sorted { (a: [String: Any], b: [String: Any]) -> Bool in ((a["date"] as? String) ?? "") > ((b["date"] as? String) ?? "") }
        var out: [Int] = []
        for x in sorted {
            if out.count >= 20 { break }
            guard let u: Int = x["uid"] as? Int, let k: String = x["key"] as? String else { continue }
            if (x["uidvalidity"] as? String) != uidValidity { continue }
            if have[k] != nil || !present.contains(u) { continue }
            out.append(u)
        }
        return out
    }

    static func normQ(_ s: String) -> String {
        s.lowercased().replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Ligne du magasin pour une clé (événement du Fil direct : champ zoho_key).
    static func body(forKey key: String) -> [String: Any]? {
        lock.lock(); defer { lock.unlock() }
        let all: [String: [String: Any]] = bodiesFile.read(default: [String: [String: Any]]())
        return all[key]
    }

    /// Corps au magasin dont l'expéditeur (nom ou adresse) et/ou l'objet contiennent la requête — 5 au plus, plus récent d'abord.
    static func bodyLookup(de: String, objet: String) -> [[String: Any]] {
        let dq: String = normQ(de)
        let oq: String = normQ(objet)
        // 25/10 : ni expéditeur ni objet → les plus récents LISIBLES d'abord (Nova cherchait des fichiers à la main).
        if dq.isEmpty && oq.isEmpty {
            lock.lock()
            let all0: [String: [String: Any]] = bodiesFile.read(default: [String: [String: Any]]())
            lock.unlock()
            let vals: [[String: Any]] = Array(all0.values)
            let readable: [[String: Any]] = vals.filter { (e: [String: Any]) -> Bool in ((e["state"] as? String) ?? "") == "lu" }
            let sortedR: [[String: Any]] = readable.sorted { (a: [String: Any], b: [String: Any]) -> Bool in ((a["date"] as? String) ?? "") > ((b["date"] as? String) ?? "") }
            return Array(sortedR.prefix(5))
        }
        lock.lock()
        let all: [String: [String: Any]] = bodiesFile.read(default: [String: [String: Any]]())
        lock.unlock()
        var hits: [[String: Any]] = []
        for (_, e) in all {
            let who: String = normQ(((e["from_name"] as? String) ?? "") + " " + ((e["from"] as? String) ?? ""))
            let subj: String = normQ((e["subject"] as? String) ?? "")
            let deOK: Bool = dq.isEmpty || who.contains(dq)
            let obOK: Bool = oq.isEmpty || subj.contains(oq) || (!subj.isEmpty && oq.contains(subj))
            if deOK && obOK { hits.append(e) }
        }
        let sorted: [[String: Any]] = hits.sorted { (a: [String: Any], b: [String: Any]) -> Bool in ((a["date"] as? String) ?? "") > ((b["date"] as? String) ?? "") }
        return Array(sorted.prefix(5))
    }

    /// 25/10 : réponse de l'outil mail_corps pour Zoho. Magasin des corps d'abord (lu / masqué / vide) ; strict
    /// (boîte « zoho » nommée) : un message connu de la copie locale SANS corps au magasin est rapporté tel quel
    /// (rattrapage à la prochaine synchronisation). nil : aucune correspondance.
    static func corpsToolText(de: String, objet: String, strict: Bool) -> String? {
        let hits: [[String: Any]] = bodyLookup(de: de, objet: objet)
        if let z: [String: Any] = hits.first {
            let state: String = (z["state"] as? String) ?? ""
            let who0: String = (z["from_name"] as? String) ?? ""
            let who: String = who0.isEmpty ? ((z["from"] as? String) ?? "?") : who0
            let subj: String = (z["subject"] as? String) ?? ""
            let day: String = String(((z["date"] as? String) ?? "").prefix(16)).replacingOccurrences(of: "T", with: " ")
            let ident: String = "message du " + day + ", de " + who + ", objet « " + subj + " »"
            var others: String = ""
            if hits.count > 1 {
                let rest: [String] = hits.dropFirst().map { (e: [String: Any]) -> String in "« " + ((e["subject"] as? String) ?? "") + " »" }
                others = "\n\n(Autres messages Zoho correspondants : " + rest.joined(separator: " ; ") + " — précise l'objet pour les distinguer.)"
            }
            if state == "masqué" {
                return "MESSAGE ZOHO À CORPS MASQUÉ — " + ident + " : il contient un code, un mot de passe ou un autre secret ; Nova ne stocke ni ne cite ce corps (règle des secrets). Rien à analyser au-delà de l'expéditeur et de l'objet." + others
            }
            if state != "lu" {
                return "MESSAGE ZOHO SANS TEXTE LISIBLE — " + ident + " : corps vide ou non décodable (image, pièce jointe seule). Rien d'autre à lire." + others
            }
            let body: String = (z["body"] as? String) ?? ""
            let len: Int = (z["len"] as? Int) ?? body.count
            let cut: String = (body.hasSuffix("…") && len >= 12000) ? "\n\n(Corps tronqué à 12 000 caractères.)" : ""
            let lead: String = "CORPS ZOHO AU MAGASIN — " + ident + " ; lu en lecture seule (IMAP EXAMINE + BODY.PEEK : rien n'est marqué lu). Ce texte fait foi pour l'analyse :\n\n"
            return lead + body + cut + others
        }
        if !strict { return nil }
        let dq: String = normQ(de)
        let oq: String = normQ(objet)
        for m in messages(limit: 400) {
            let who: String = normQ(((m["from_name"] as? String) ?? "") + " " + ((m["from"] as? String) ?? ""))
            let subj: String = normQ((m["subject"] as? String) ?? "")
            let deOK: Bool = dq.isEmpty || who.contains(dq)
            let obOK: Bool = oq.isEmpty || subj.contains(oq)
            if !(deOK && obOK) { continue }
            let ex: String = (m["excerpt"] as? String) ?? ""
            let s0: String = (m["subject"] as? String) ?? ""
            let lead: String = "MESSAGE ZOHO CONNU, CORPS PAS ENCORE AU MAGASIN — « " + s0 + " » : il a été synchronisé avant la lecture des corps complets ; le rattrapage est automatique (20 corps par synchronisation, toutes les 5 min). Seul l'extrait de la copie locale est disponible maintenant"
            return ex.isEmpty ? lead + "." : lead + " : « " + ex + " »"
        }
        return nil
    }

    /// Vue « semaine » pour mail_week : messages Zoho des n derniers jours (copie locale), extrait court.
    static func weekText(days: Int) -> String {
        let since: Date = Date().addingTimeInterval(-Double(days) * 86400)
        let iso: ISO8601DateFormatter = ISO8601DateFormatter()
        var lines: [String] = []
        for m in messages(limit: 60) {
            let ds: String = (m["date"] as? String) ?? ""
            guard let d: Date = iso.date(from: ds), d >= since else { continue }
            let who: String = (m["from_name"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? ((m["from"] as? String) ?? "?")
            let subj: String = (m["subject"] as? String) ?? ""
            let ex: String = String(((m["excerpt"] as? String) ?? "").prefix(160))
            let day: String = String(ds.prefix(16)).replacingOccurrences(of: "T", with: " ")
            var line: String = "REÇU (Zoho) | " + day + " | " + who + " | " + subj
            if !ex.isEmpty { line += " — " + ex }
            lines.append(line)
            if lines.count >= 30 { break }
        }
        if lines.isEmpty { return "" }
        let head: String = "Zoho Mail (copie locale en lecture seule, \(days) derniers jours) : \(lines.count)\n"
        let tail: String = "\n(corps complet d'un message Zoho : mail_corps {\"de\",\"objet\",\"boite\":\"zoho\"})"
        return head + lines.joined(separator: "\n") + tail
    }

    static func imapDate(_ day: String) -> String {
        let d: Date = Fundings.dayDate(day) ?? (Fundings.dayDate(defaultSince) ?? Date())
        return ZohoMime.posix("dd-MMM-yyyy").string(from: d)
    }

    static func searchUIDs(_ r: ZohoReply) -> [Int] {
        var out: [Int] = []
        for u in r.untagged {
            guard let t: String = u.texts.first, t.uppercased().hasPrefix("* SEARCH") else { continue }
            for w in t.dropFirst(8).split(separator: " ") { if let n = Int(w) { out.append(n) } }
        }
        return out
    }

    /// Essai de connexion (connexion TLS, accueil, LOGIN, LOGOUT) : rien n'est lu, rien n'est écrit.
    static func testLogin(host: String, email: String, password: String) -> (ok: Bool, errClass: String, message: String) {
        let c: ZohoIMAPClient = ZohoIMAPClient()
        defer { c.close() }
        if let e: String = c.connect(host: host, port: 993, timeout: 15) { return (false, "reseau", "Serveur " + host + " injoignable : " + e + ".") }
        guard c.greeting(timeout: 15) else { return (false, "protocole", "Le serveur " + host + " n'a pas répondu comme un serveur IMAP.") }
        let r: ZohoReply = c.login(email: email, password: password)
        if r.status == "OK" { _ = c.command("LOGOUT", ""); return (true, "", "") }
        if r.status == "NO" {
            return (false, "auth", "Zoho a refusé la connexion sur " + host + " : vérifie l'adresse, le mot de passe d'application, et qu'IMAP est activé (Zoho › Paramètres › Comptes de messagerie › IMAP).")
        }
        return (false, "protocole", "Réponse inattendue du serveur " + host + " (" + r.status + ").")
    }

    static func connect(email: String, password: String, choice: String, ctx: ZohoCtx) -> (body: [String: Any], status: Int) {
        let mail: String = email.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard mail.range(of: #"^[^@\s"]+@[^@\s"]+\.[a-z]{2,}$"#, options: .regularExpression) != nil else {
            let b: [String: Any] = ["ok": false, "error": "Adresse invalide."]; return (b, 400)
        }
        let pw: String = password.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !pw.isEmpty, pw.count <= 128, ZohoIMAPClient.quoted(pw) != nil else {
            let b: [String: Any] = ["ok": false, "error": "Mot de passe d'application vide ou contenant des caractères non pris en charge."]; return (b, 400)
        }
        let ch: String = (choice.isEmpty || choice == "auto") ? "auto" : choice
        guard ch == "auto" || servers.contains(ch) else {
            let b: [String: Any] = ["ok": false, "error": "Serveur inconnu."]; return (b, 400)
        }
        let hosts: [String] = ch == "auto" ? ["imappro.zoho.com", "imap.zoho.com"] : [ch]
        var okHost: String = ""
        var lastErr: String = ""
        var lastClass: String = ""
        for h in hosts {
            let t0: Date = Date()
            let r: (ok: Bool, errClass: String, message: String) = testLogin(host: h, email: mail, password: pw)
            journal.add(["op": "connexion", "host": h, "account": mail, "ok": r.ok, "error_class": r.errClass, "ms": Int(Date().timeIntervalSince(t0) * 1000)])
            if r.ok { okHost = h; break }
            lastErr = r.message; lastClass = r.errClass
            if r.errClass != "auth" { break }   // « automatique » : serveur suivant seulement sur refus d'authentification
        }
        guard !okHost.isEmpty else {
            let b: [String: Any] = ["ok": false, "error": lastErr, "error_class": lastClass]
            return (b, lastClass == "auth" ? 401 : 502)
        }
        guard KeychainStore.save(service: KnownKeys.zoho.service, value: pw) else {
            let b: [String: Any] = ["ok": false, "error": "Connexion réussie, mais le Trousseau a refusé l'écriture — rien n'a été enregistré."]
            return (b, 500)
        }
        (ctx.keys as? KeychainStore)?.forget()
        lock.lock()
        var o: [String: Any] = load()
        if (o["account"] as? String) != mail {
            o["messages"] = [[String: Any]](); o["uids"] = [Int](); o["uidvalidity"] = ""; o["synced_once"] = false
        }
        o["account"] = mail; o["server"] = okHost; o["server_choice"] = ch; o["connected"] = true
        o["error"] = NSNull(); o["error_class"] = NSNull(); o["connected_at"] = nowISO()
        file.write(o)
        lock.unlock()
        _ = BlackBox.record(["tool": "zoho", "actor": "Ahadi", "why": "Boîte Zoho campagne connectée (" + mail + " · " + okHost + ") — mot de passe d'application au Trousseau « " + KnownKeys.zoho.service + " », lecture seule", "ok": true, "effect": "écrit"])
        DispatchQueue.global(qos: .utility).async { _ = sync(ctx: ctx, reason: "connexion") }
        let b: [String: Any] = ["ok": true, "account": mail, "server": okHost]
        return (b, 200)
    }

    static func disconnect(ctx: ZohoCtx) -> [String: Any] {
        var deleted: Bool = false
        #if os(macOS)
        for _ in 0..<3 {
            let r: (Int32, String) = runProcess("/usr/bin/security", ["delete-generic-password", "-a", KeychainStore.user, "-s", KnownKeys.zoho.service], timeout: 5)
            if r.0 == 0 { deleted = true } else { break }
        }
        #endif
        (ctx.keys as? KeychainStore)?.forget()
        lock.lock()
        var o: [String: Any] = load()
        let acc: String = (o["account"] as? String) ?? defaultAccount
        o["connected"] = false; o["synced_once"] = false; o["error"] = NSNull(); o["error_class"] = NSNull(); o["disconnected_at"] = nowISO()
        file.write(o)
        lock.unlock()
        MailCounts.setZoho(nil)
        journal.add(["op": "déconnexion", "account": acc, "trousseau_efface": deleted])
        _ = BlackBox.record(["tool": "zoho", "actor": "Ahadi", "why": "Boîte Zoho campagne déconnectée — mot de passe " + (deleted ? "effacé du" : "absent du") + " Trousseau ; le canal Fundings repasse aux pushes du pilote", "ok": true, "effect": "écrit"])
        ctx.bus.publish("zoho", ["connected": false])
        return ["ok": true, "trousseau_efface": deleted]
    }

    static func fail(_ message: String, _ cls: String, account: String, host: String, t0: Date, ctx: ZohoCtx) -> [String: Any] {
        lock.lock()
        var o: [String: Any] = load()
        let wasAuth: Bool = ((o["error_class"] as? String) ?? "") == "auth"
        o["error"] = message; o["error_class"] = cls; o["last_sync"] = nowISO()
        file.write(o)
        lock.unlock()
        // 29/10 (audit n°4) : une déconnexion (auth) arrête la synchro — Ahadi est prévenu UNE fois, pas seulement le bus.
        if cls == "auth" && !wasAuth {
            NovaNotifier.send(source: "mail:auth:zoho", title: "Nova — Zoho déconnecté", body: message, target: ["module": "reglages"])
            _ = BlackBox.record(["tool": "zoho", "actor": "Nova", "ok": false, "effect": "lecture", "why": "Zoho déconnecté (auth) — synchro suspendue, Ahadi prévenu", "result": "auth"])
        }
        journal.add(["op": "synchro", "host": host, "account": account, "ok": false, "error_class": cls, "ms": Int(Date().timeIntervalSince(t0) * 1000)])
        ctx.bus.publish("zoho", ["error": message])
        return ["ok": false, "error": message, "error_class": cls]
    }

    static func heure(_ d: Date) -> String {
        let f: DateFormatter = DateFormatter()
        f.locale = Locale(identifier: "fr_FR"); f.timeZone = TimeZone.current; f.dateFormat = "EEE d MMM yyyy HH:mm"
        return f.string(from: d)
    }

    /// Une synchronisation : LOGIN, EXAMINE "INBOX", UID SEARCH, UID FETCH (PEEK), LOGOUT. Jamais deux à la fois.
    static func sync(ctx: ZohoCtx, reason: String) -> [String: Any] {
        lock.lock()
        if syncing { lock.unlock(); let b: [String: Any] = ["ok": false, "busy": true, "error": "Synchronisation déjà en cours."]; return b }
        syncing = true
        let o0: [String: Any] = load()
        lock.unlock()
        defer { lock.lock(); syncing = false; lock.unlock() }
        let account: String = (o0["account"] as? String) ?? ""
        let host: String = (o0["server"] as? String) ?? ""
        let t0: Date = Date()
        guard (o0["connected"] as? Bool) == true, !account.isEmpty, !host.isEmpty else {
            let b: [String: Any] = ["ok": false, "error": "Boîte Zoho non connectée dans Nova."]; return b
        }
        guard let pw: String = ctx.keys.value(KnownKeys.zoho), !pw.isEmpty else {
            return fail("Mot de passe d'application absent du Trousseau — reconnecte la boîte dans Réglages.", "trousseau", account: account, host: host, t0: t0, ctx: ctx)
        }
        let since: String = ctx.settings.get("zoho_since", defaultSince)
        let excl2610: Bool = ctx.settings.get("zoho_exclure_2610", true)
        let c: ZohoIMAPClient = ZohoIMAPClient()
        defer { c.close() }
        if let e: String = c.connect(host: host, port: 993, timeout: 15) {
            return fail("Serveur " + host + " injoignable : " + e + ".", "reseau", account: account, host: host, t0: t0, ctx: ctx)
        }
        guard c.greeting(timeout: 15) else {
            return fail("Le serveur " + host + " n'a pas répondu comme un serveur IMAP.", "protocole", account: account, host: host, t0: t0, ctx: ctx)
        }
        let lr: ZohoReply = c.login(email: account, password: pw)
        guard lr.status == "OK" else {
            if lr.status == "NO" {
                return fail("Zoho refuse la connexion (mot de passe d'application révoqué ou IMAP désactivé) — reconnecte la boîte dans Réglages. Synchronisation automatique suspendue.", "auth", account: account, host: host, t0: t0, ctx: ctx)
            }
            return fail("Connexion IMAP interrompue (" + lr.status + ").", "protocole", account: account, host: host, t0: t0, ctx: ctx)
        }
        let ex: ZohoReply = c.command("EXAMINE", "\"INBOX\"")
        guard ex.status == "OK" else {
            return fail("Boîte de réception illisible (" + ex.status + ").", "protocole", account: account, host: host, t0: t0, ctx: ctx)
        }
        var uidValidity: String = ""
        for u in ex.untagged {
            for t in u.texts { if let v: String = ZohoMime.firstGroup(t, #"UIDVALIDITY (\d+)"#) { uidValidity = v } }
        }
        let sr: ZohoReply = c.command("UID SEARCH", "SINCE " + imapDate(since))
        guard sr.status == "OK" else {
            return fail("Recherche refusée par le serveur (" + sr.status + ").", "protocole", account: account, host: host, t0: t0, ctx: ctx)
        }
        let uids: [Int] = searchUIDs(sr)
        let ur: ZohoReply = c.command("UID SEARCH", "UNSEEN")
        let unseen: Set<Int> = ur.status == "OK" ? Set(searchUIDs(ur)) : Set<Int>()
        let prevValidity: String = (o0["uidvalidity"] as? String) ?? ""
        let known: Set<Int> = prevValidity == uidValidity ? Set((o0["uids"] as? [Int]) ?? []) : Set<Int>()
        let fresh: [Int] = Array(uids.filter { (u: Int) -> Bool in !known.contains(u) }.sorted().suffix(150))
        // 25/10 : RATTRAPAGE des corps — messages déjà en cache (synchros d'avant ce lot) sans corps au magasin :
        // relus en BODY.PEEK (lecture seule, \Seen jamais posé), 20 au plus par synchro, les plus récents d'abord.
        let backfill: [Int] = backfillUIDs(cache: (o0["messages"] as? [[String: Any]]) ?? [], uidValidity: uidValidity, prevValidity: prevValidity, present: Set(uids))
        let freshSet: Set<Int> = Set(fresh)
        var toFetch: [Int] = fresh
        for u in backfill where !freshSet.contains(u) { toFetch.append(u) }
        var raws: [ZohoRaw] = []
        var i: Int = 0
        while i < toFetch.count {
            let end: Int = min(i + 15, toFetch.count)   // 25/10 : lots de 15 (corps jusqu'à 20 000 octets chacun)
            let batch: [Int] = Array(toFetch[i..<end])
            let seq: String = batch.map { (u: Int) -> String in String(u) }.joined(separator: ",")
            let fr: ZohoReply = c.command("UID FETCH", seq + " " + fetchItems)
            for u in fr.untagged { if let r: ZohoRaw = ZohoMime.parseFetch(u) { raws.append(r) } }
            if fr.status != "OK" { break }
            i += 15
        }
        _ = c.command("LOGOUT", "")
        c.close()

        // Traitement (hors réseau) : cache, Fundings, Fil direct.
        let first: Bool = (o0["synced_once"] as? Bool) != true
        var cache: [[String: Any]] = (o0["messages"] as? [[String: Any]]) ?? []
        var haveKeys: Set<String> = Set(cache.compactMap { (x: [String: Any]) -> String? in x["key"] as? String })
        var newMsgs: [[String: Any]] = []
        var events: Int = 0
        var feedN: Int = 0
        var skipped: Int = 0
        let now: Date = Date()
        let iso: ISO8601DateFormatter = ISO8601DateFormatter()
        let notifyOn: Bool = ctx.settings.get("notify", true) && ctx.settings.get("notify_mail", true)
        var bodyRows: [String: [String: Any]] = [:]   // 25/10 : corps complets lus dans cette synchro (magasin zoho_bodies.json)
        for r in raws.sorted(by: { (a: ZohoRaw, b: ZohoRaw) -> Bool in a.uid < b.uid }) {
            let m: ZohoParsed = ZohoMime.parse(r, uidValidity: uidValidity)
            let subjShown: String = SecretsGuard.containsSecret(m.subject) ? "(objet masqué — secret)" : m.subject
            // 25/10 : corps complet — même règle de secret que l'extrait, évaluée sur le corps ENTIER (plus prudent).
            let fullProbe: String = m.subject + "\n" + m.full
            let secretFull: Bool = SecretsGuard.containsSecret(fullProbe) || ZohoFundings.rx(ZohoFundings.secretRx, fullProbe)
            let row: [String: Any] = bodyRow(m, subject: subjShown, secret: secretFull)
            bodyRows[m.key] = row
            if haveKeys.contains(m.key) { continue }
            haveKeys.insert(m.key)
            let recent: Bool = now.timeIntervalSince(m.date) < 48 * 3600
            // V5-V (25/10, politique d'Ahadi 10:55) : la BOÎTE (cache, Fil direct) ne masque plus que les SECRETS
            // (SecretsGuard + phrases de code de Zoho) ; SCI / probation y restent lisibles. Le CANAL Fundings garde ses
            // propres filtres (ZohoFundings.map : horsCampagneRx, Fundings.forbidden) — inchangés.
            let secret: Bool = SecretsGuard.containsSecret(m.subject + "\n" + m.text) || ZohoFundings.rx(ZohoFundings.secretRx, m.subject + "\n" + m.text)
            let excerpt: String = secret ? "(extrait masqué : code, mot de passe ou autre secret)" : ZohoMime.flat(m.text, 600)
            // Fundings : contrat d'ingestion inchangé, mêmes filtres et anti-doublon.
            let mapped: (event: [String: Any]?, motif: String) = ZohoFundings.map(m, account: account, exclude2610: excl2610)
            var fstate: String = mapped.motif
            if let ev: [String: Any] = mapped.event {
                let res: (body: [String: Any], status: Int, push: [String: Any]?) = Fundings.ingest(ev, zohoActive: true)
                if let rec: [String: Any] = res.push {
                    Fundings.publish(rec, bus: ctx.bus, settings: ctx.settings, briefs: ctx.briefs, notify: recent && !first)
                    events += 1
                    fstate = "événement Fundings « " + ((rec["categorie"] as? String) ?? "") + " » — " + ((rec["motif"] as? String) ?? "")
                } else if res.status == 200 {
                    fstate = "doublon — " + ((res.body["motif"] as? String) ?? "déjà consigné")
                } else {
                    fstate = "refusé par le canal : " + ((res.body["error"] as? String) ?? "erreur")
                }
            }
            let who: String = m.fromName.isEmpty ? m.fromAddr : m.fromName
            newMsgs.append(["key": m.key, "uid": m.uid, "uidvalidity": uidValidity, "message_id": m.messageId,
                            "from_name": m.fromName, "from": m.fromAddr, "domain": ZohoMime.domain(m.fromAddr),
                            "subject": subjShown, "date": iso.string(from: m.date), "excerpt": excerpt,
                            "lu": !unseen.contains(m.uid), "size": m.size, "fundings": fstate])
            // Fil direct : arrivées nouvelles (première synchro : seulement les 5 plus récentes de moins de 48 h).
            let publishIt: Bool = first ? (recent && feedN < 5) : feedN < 10
            if publishIt {
                var lines: [String] = []
                lines.append("De : " + String((m.fromName.isEmpty ? m.fromAddr : m.fromName + " <" + m.fromAddr + ">").prefix(120)))
                if !subjShown.isEmpty { lines.append("Objet : " + String(subjShown.prefix(200))) }
                lines.append("Heure : " + heure(m.date))
                if !excerpt.isEmpty { lines.append("Aperçu : " + String(excerpt.prefix(300))) }
                // 25/10 : le corps lu accompagne l'événement DÈS sa publication (état « lu », extrait borné) —
                // la carte du Fil direct est composée directement sur le corps (DirectCompose, état « lu »).
                let extra: [String: Any] = feedExtra(row: row, key: m.key)
                ProactiveFeed.append(kind: "mail.new", box: "zm", title: subjShown.isEmpty ? who : String(subjShown.prefix(140)),
                                     text: lines.joined(separator: "\n"), urgent: false, who: who, extra: extra)
                feedN += 1
                if !first {
                    NovaNotifier.send(source: "mail:zm", title: "Nova — Zoho · " + who, body: String(subjShown.prefix(140)),
                                      target: ["module": "messages", "id": "zm"], urgent: false, enabled: notifyOn, quiet: ctx.briefs.inQuietHours())
                }
            } else if !first || recent {
                skipped += 1
            }
        }
        if skipped > 0 {
            ProactiveFeed.append(kind: "mail.new", box: "zm", title: "Zoho — lot résumé (" + String(skipped) + " messages)",
                                 text: "+" + String(skipped) + " messages récents dans la boîte Zoho campagne (lot résumé : liste dans Réglages › Zoho Mail et dans la boîte).", urgent: false, who: "")
        }
        cache.append(contentsOf: newMsgs)
        if cache.count > maxCache { cache = Array(cache.suffix(maxCache)) }
        for k in cache.indices {
            if let u: Int = cache[k]["uid"] as? Int, (cache[k]["uidvalidity"] as? String) == uidValidity { cache[k]["lu"] = !unseen.contains(u) }
        }
        let uidSet: Set<Int> = Set(uids)
        let knownAfter: [Int] = Array(known.union(raws.map { (r: ZohoRaw) -> Int in r.uid })).filter { (u: Int) -> Bool in uidSet.contains(u) }.sorted()
        let ms: Int = Int(Date().timeIntervalSince(t0) * 1000)
        lock.lock()
        var o: [String: Any] = load()
        let still: Bool = (o["account"] as? String) == account && (o["connected"] as? Bool) == true
        if still {
            o["messages"] = cache; o["uids"] = knownAfter; o["uidvalidity"] = uidValidity
            o["synced_once"] = true; o["last_sync"] = nowISO(); o["last_ok"] = nowISO()
            o["error"] = NSNull(); o["error_class"] = NSNull(); o["unread"] = unseen.count
            o["fundings_events"] = ((o["fundings_events"] as? Int) ?? 0) + events; o["last_duration_ms"] = ms
            file.write(o)
            if !bodyRows.isEmpty { storeBodies(bodyRows) }   // 25/10 : magasin des corps, sous le même verrou
        }
        lock.unlock()
        if still { MailCounts.setZoho(unseen.count) }
        journal.add(["op": "synchro", "host": host, "account": account, "ok": true, "raison": reason, "vus": uids.count, "nouveaux": newMsgs.count,
                     "fundings": events, "fil_direct": feedN, "non_lus": unseen.count, "ms": ms])
        ctx.bus.publish("zoho", ["synced": true, "nouveaux": newMsgs.count, "fundings": events])
        let b: [String: Any] = ["ok": true, "nouveaux": newMsgs.count, "fundings": events, "fil_direct": feedN, "non_lus": unseen.count, "ms": ms]
        return b
    }

    /// Toutes les 5 min tant que la boîte est connectée ; suspendue après un refus d'authentification (pas de verrouillage du compte).
    static func startScheduler(ctx: ZohoCtx) {
        lock.lock()
        if schedulerStarted { lock.unlock(); return }
        schedulerStarted = true
        lock.unlock()
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 60) { tick(ctx: ctx) }
    }
    static func tick(ctx: ZohoCtx) {
        lock.lock(); let o: [String: Any] = load(); lock.unlock()
        let on: Bool = (o["connected"] as? Bool) == true && ((o["error_class"] as? String) ?? "") != "auth"
        if on { _ = sync(ctx: ctx, reason: "minuterie (5 min)") }
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 300) { tick(ctx: ctx) }
    }
}

// MARK: - Auto-contrôle (GET /api/zoho/selftest) — aucun réseau, aucune écriture

enum ZohoSelfTest {
    static func sample(_ from: String, _ subject: String, _ dateISO: String, _ text: String) -> ZohoParsed {
        var m: ZohoParsed = ZohoParsed()
        let a: (name: String, addr: String) = ZohoMime.address(from)
        m.fromName = a.name; m.fromAddr = a.addr; m.subject = subject; m.text = text
        m.date = ISO8601DateFormatter().date(from: dateISO) ?? Date()
        m.messageId = "selftest-" + String(subject.count) + "@example.invalid"
        m.key = "mid:" + m.messageId
        return m
    }

    /// Les 6 messages types de conseil_24-10/V5_S_ZOHO.md : (nom, message, programme attendu ou "", catégorie attendue ou "").
    static func samples() -> [(String, ZohoParsed, String, String)] {
        return [
            ("1 Cloudflare approbation", sample("Cloudflare for Startups <startups@cloudflare.com>", "Your Cloudflare for Startups application has been approved", "2026-10-25T09:12:00Z",
                "Hi Ahadi,\nCongratulations! Your application to the Cloudflare for Startups program has been approved. $10,000 in Cloudflare credits have been applied to your account.\nThe Cloudflare Startups team"), "cloudflare", "APPROBATION"),
            ("2 PostHog refus", sample("PostHog for Startups <startups@posthog.com>", "Update on your PostHog for Startups application", "2026-10-25T10:03:00Z",
                "Hey Ahadi, thanks for applying. Unfortunately, we are not able to approve your application for the startup program at this time."), "posthog", "REFUS"),
            ("3 Exa accusé", sample("Exa Grants <grants@exa.ai>", "We received your Exa Grants application", "2026-10-25T11:20:00Z",
                "Thanks for applying to Exa Grants! We have received your application and the team will review it."), "exa", "SIMPLE ACCUSÉ"),
            ("4 MIT Solve action requise", sample("MIT Solve <solve@mit.edu>", "Action required: complete your Solve application", "2026-10-25T13:00:00Z",
                "Dear Ahadi, please complete the optional elevator pitch video and backup contact by November 2, 2026. Your solution remains SUBMITTED."), "mitsolve", "ACTION REQUISE"),
            ("5 Newsletter (aucun événement)", sample("Product Hunt Daily <hello@digest.producthunt.com>", "Top launches today: AI agents, Cloudflare Workers tips", "2026-10-25T14:00:00Z",
                "Here are today's top products. Cloudflare shipped new Workers features."), "", ""),
            ("6 Message du 26/10 (exclu)", sample("Rappels <noreply@calendar.example.org>", "Rappel : entretien RH le 26/10 (exemple fictif)", "2026-10-26T07:00:00Z",
                "Votre entretien RH (exemple fictif) est prévu le 26/10/2026 à 10:00."), "", ""),
        ]
    }

    static func run() -> [String: Any] {
        var guardRows: [[String: Any]] = []
        var guardOK: Bool = true
        for (v, a, want) in ZohoGuard.selfCases {
            let got: Bool = ZohoGuard.allowed(verb: v, args: a)
            if got != want { guardOK = false }
            guardRows.append(["verbe": v, "arguments": a.replacingOccurrences(of: "\r\n", with: "⏎"), "attendu": want, "obtenu": got, "ok": got == want])
        }
        var decRows: [[String: Any]] = []
        var decOK: Bool = true
        let decCases: [(String, String, String)] = [
            ("en-tête B utf-8", ZohoMime.decodeHeader("=?UTF-8?B?Q2FuZGlkYXR1cmUgcmXDp3Vl?="), "Candidature reçue"),
            ("en-tête Q iso-8859-1", ZohoMime.decodeHeader("=?iso-8859-1?Q?R=E9ponse_attendue?="), "Réponse attendue"),
            ("deux mots encodés", ZohoMime.decodeHeader("=?utf-8?Q?Cr=C3=A9dits?= =?utf-8?Q?_accord=C3=A9s?="), "Crédits accordés"),
            ("corps quoted-printable", ZohoMime.decodeBody("Cr=C3=A9dits accord=C3=A9s=\r\n !", cte: "quoted-printable", charset: "utf-8"), "Crédits accordés !"),
            ("corps base64", ZohoMime.decodeBody("Q3LDqWRpdHMgYWNjb3Jkw6lz", cte: "base64", charset: "utf-8"), "Crédits accordés"),
            ("multipart text/plain", ZohoMime.text(contentType: "multipart/alternative; boundary=\"b1\"", cte: "",
                bodyL1: "--b1\r\nContent-Type: text/plain; charset=utf-8\r\n\r\nBonjour Ahadi\r\n--b1\r\nContent-Type: text/html\r\n\r\n<p>Bonjour</p>\r\n--b1--\r\n", depth: 0).trimmingCharacters(in: .whitespacesAndNewlines), "Bonjour Ahadi"),
            ("html seul", ZohoMime.flat(ZohoMime.stripHTML("<html><head><style>p{}</style></head><body><p>Thanks&nbsp;for applying</p></body></html>"), 100), "Thanks for applying"),
        ]
        for (n, got, want) in decCases {
            if got != want { decOK = false }
            decRows.append(["cas": n, "attendu": want, "obtenu": got, "ok": got == want])
        }
        var mapRows: [[String: Any]] = []
        var mapOK: Bool = true
        for (name, m, wantProg, wantCat) in samples() {
            let r: (event: [String: Any]?, motif: String) = ZohoFundings.map(m, account: Zoho.defaultAccount, exclude2610: true)
            let gotProg: String = (r.event?["programme"] as? String) ?? ""
            let gotCat: String = (r.event?["categorie"] as? String) ?? ""
            let ok: Bool = gotProg == wantProg && gotCat == wantCat
            if !ok { mapOK = false }
            var row: [String: Any] = ["message": name, "attendu": wantProg.isEmpty ? "aucun événement" : wantProg + " · " + wantCat, "motif": r.motif, "ok": ok]
            if let ev: [String: Any] = r.event { row["evenement"] = ev }
            mapRows.append(row)
        }
        return ["liste_blanche": ZohoGuard.allowList, "garde": guardRows, "garde_ok": guardOK,
                "decodage": decRows, "decodage_ok": decOK, "fundings": mapRows, "fundings_ok": mapOK,
                "tout_ok": guardOK && decOK && mapOK, "lecture_seule": Zoho.lectureSeule,
                "note": "Aucun réseau, aucune écriture : la garde, les décodeurs et le correspondant Fundings sont exercés en mémoire."]
    }
}

// MARK: - Routes

extension NovaApp {
    func zohoRoutes() {
        let s = server
        let ctx: ZohoCtx = ZohoCtx(bus: bus, settings: settings, briefs: briefs, keys: keys)
        Zoho.startScheduler(ctx: ctx)
        s.on("GET", "/api/zoho/status") { _, res in
            res.json(Zoho.status(keys: ctx.keys))
        }
        s.on("GET", "/api/zoho/messages") { req, res in
            let n: Int = min(200, max(1, Int(req.query["limit"] ?? "50") ?? 50))
            let b: [String: Any] = ["messages": Zoho.messages(limit: n), "lecture_seule": Zoho.lectureSeule]
            res.json(b)
        }
        s.on("POST", "/api/zoho/connect") { req, res in
            let j: [String: Any] = req.json
            let r: (body: [String: Any], status: Int) = Zoho.connect(email: (j["email"] as? String) ?? "", password: (j["password"] as? String) ?? "",
                                                                    choice: (j["server"] as? String) ?? "auto", ctx: ctx)
            res.json(r.body, status: r.status)   // jamais le mot de passe : seulement {ok, account, server} ou {ok:false, error}
        }
        s.on("POST", "/api/zoho/disconnect") { _, res in
            res.json(Zoho.disconnect(ctx: ctx))
        }
        s.on("POST", "/api/zoho/sync") { _, res in
            let r: [String: Any] = Zoho.sync(ctx: ctx, reason: "demande d'Ahadi")
            res.json(r)
        }
        s.on("GET", "/api/zoho/selftest") { _, res in
            res.json(ZohoSelfTest.run())
        }
    }
}
