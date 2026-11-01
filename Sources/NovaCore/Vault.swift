import Foundation
#if os(macOS)
import Security
import CryptoKit
import CommonCrypto
import LocalAuthentication
#endif

/// Coffre Finances / Santé / Portefeuilles — V3 « chiffré au repos » (24/10/2026, conseil_24-10/V3_COFFRE.md).
///
/// • Au repos : chaque fichier du coffre (vault_finance.json, vault_sante.json, vault_portefeuilles.json,
///   vault_portefeuilles_vus.json) est scellé en AES-256-GCM (CryptoKit) dans « <nom>.enc » ; données
///   authentifiées = nom du fichier (un fichier ne peut pas être substitué à un autre). Clé symétrique 256 bits
///   générée UNE fois, rangée au Trousseau (kSecAttrAccessibleWhenUnlockedThisDeviceOnly), jamais écrite ailleurs.
/// • Migration : au premier déverrouillage, chaque fichier clair est chiffré, la copie est relue et déchiffrée,
///   une sauvegarde chiffrée vérifiée est posée dans « coffre-sauvegardes/ », et SEULEMENT ENSUITE le clair est
///   retiré. Idempotente ; en cas de doute (versions divergentes, JSON illisible), rien n'est supprimé.
/// • Déverrouillage : LAContext (.deviceOwnerAuthentication : Touch ID ou mot de passe du Mac) côté moteur ;
///   le code reste possible en repli ou en second facteur. Le code voyage vers le moteur (boucle locale,
///   jamais journalisé ni stocké) et y est vérifié par empreinte salée PBKDF2-HMAC-SHA256 (CommonCrypto),
///   poivrée par une clé dérivée (HKDF) de la clé du coffre. Délai croissant après échecs (persisté).
///   La route n'accepte plus d'empreinte : l'ancien défaut « l'empreinte vaut mot de passe » est fermé.
/// • Session : jeton en mémoire, 5 min sans activité (30 min au plus), clé et données déchiffrées effacées
///   de la mémoire du moteur quand plus aucun jeton n'est vivant. Journal scellé (BlackBox) : ouvert / fermé /
///   refusé / migré — jamais de contenu ni de code.
/// Extraction de texte PDF fournie par la couche Mac (PDFKit) ; absente sous Linux.
public enum VaultHooks { nonisolated(unsafe) public static var pdfText: ((String) -> String?)? }

enum VaultError: Error { case seal, format }

struct VaultTok { var last: Date; let born: Date; let how: String }

/// Jetons de session du coffre (mémoire seulement). Ordre des verrous : `lock` → `VaultCrypto.io`, jamais l'inverse.
final class VaultSession {
    static let shared: VaultSession = VaultSession()
    static let idle: TimeInterval = 300        // 5 min sans activité
    static let maxAge: TimeInterval = 1800     // 30 min au plus, même active
    let lock = NSLock()
    let codeLock = NSLock()                    // vérifications de code en série : le compteur d'échecs ne se contourne pas en parallèle
    var tokens: [String: VaultTok] = [:]
    var tickets: [String: Date] = [:]          // second facteur : Touch ID accepté, code attendu (2 min)
    var opening: Int = 0                       // ouvertures en cours : la clé ne doit pas être effacée sous leurs pieds

    private func purgeLocked(_ now: Date) {
        let before: Int = tokens.count
        tokens = tokens.filter { now.timeIntervalSince($0.value.last) < VaultSession.idle && now.timeIntervalSince($0.value.born) < VaultSession.maxAge }
        tickets = tickets.filter { $0.value > now }
        if before > 0 && tokens.isEmpty {
            _ = BlackBox.record(["tool": "coffre", "actor": "Nova", "effect": "lecture", "ok": true, "why": "coffre fermé", "result": "expiration : 5 min sans activité ou 30 min de session"])
            if opening == 0 { VaultCrypto.close() }
        }
    }
    /// Jeton vivant ? `touch` = action de l'utilisateur : repousse l'expiration d'inactivité.
    func check(_ t: String, touch: Bool) -> Bool {
        lock.lock(); defer { lock.unlock() }
        let now = Date()
        purgeLocked(now)
        guard !t.isEmpty, var v = tokens[t] else { return false }
        if touch { v.last = now; tokens[t] = v }
        return true
    }
    func isOpen() -> Bool {
        lock.lock(); defer { lock.unlock() }
        purgeLocked(Date())
        return !tokens.isEmpty
    }
    func beginOpen() { lock.lock(); opening += 1; lock.unlock() }
    /// Fin d'une tentative d'ouverture : émet un jeton si `how` est fourni ; sinon referme la clé si personne ne s'en sert.
    func endOpen(issue how: String?) -> String? {
        lock.lock(); defer { lock.unlock() }
        opening = max(0, opening - 1)
        if let h = how {
            let t: String = UUID().uuidString + "-" + UUID().uuidString
            let now = Date()
            tokens[t] = VaultTok(last: now, born: now, how: h)
            return t
        }
        if tokens.isEmpty && opening == 0 { VaultCrypto.close() }
        return nil
    }
    func revoke(_ t: String) -> Bool {
        lock.lock(); defer { lock.unlock() }
        let had: Bool = !t.isEmpty && tokens.removeValue(forKey: t) != nil
        if tokens.isEmpty && opening == 0 { VaultCrypto.close() }
        return had
    }
    func newTicket() -> String {
        lock.lock(); defer { lock.unlock() }
        let t: String = UUID().uuidString
        tickets[t] = Date().addingTimeInterval(120)
        return t
    }
    func hasTicket(_ t: String) -> Bool {
        lock.lock(); defer { lock.unlock() }
        purgeLocked(Date())
        return !t.isEmpty && tickets[t] != nil
    }
    func dropTicket(_ t: String) { lock.lock(); tickets.removeValue(forKey: t); lock.unlock() }
}

/// Fichier du coffre : même usage que JSONFile (read(default:) / write), chiffré au repos sur Mac.
/// Lisible et inscriptible UNIQUEMENT pendant qu'un jeton de coffre est vivant (clé chargée) ; sinon read rend
/// la valeur par défaut et write refuse (false) — jamais d'écrasement d'un fichier qu'on n'a pas su lire.
public final class VaultFile {
    public let name: String
    public init(_ name: String) { self.name = name }
    public func read<T>(default def: T) -> T {
        let r: (value: Any?, error: String?) = VaultCrypto.load(name)
        guard let v = r.value, let o = v as? T else { return def }
        return o
    }
    /// value nil + error nil = fichier absent ; error non nil = coffre fermé ou fichier illisible.
    public func readChecked() -> (value: Any?, error: String?) { VaultCrypto.load(name) }
    @discardableResult public func write(_ obj: Any) -> Bool { VaultCrypto.store(name, obj) }
    /// Vrai si les données du coffre sont lisibles en ce moment (coffre ouvert dans ce processus).
    public static var isOpen: Bool { VaultCrypto.isOpen }
}

public enum VaultCrypto {
    static let io = NSLock()
    static let cfg: JSONFile = JSONFile("vault_config.json")   // sel + vérificateur du code, compteur d'échecs, empreinte de la clé : AUCUNE donnée
    static let files: [String] = ["vault_finance.json", "vault_sante.json", "vault_portefeuilles.json", "vault_portefeuilles_vus.json"]
    nonisolated(unsafe) static var cache: [String: Any] = [:]
    nonisolated(unsafe) static var lastError: String = ""
    nonisolated(unsafe) static var keyLoaded: Bool = false
    nonisolated(unsafe) static var clearMode: Bool = false     // clé illisible ET aucun fichier chiffré : ancien comportement (clair), signalé
    #if os(macOS)
    nonisolated(unsafe) static var key: SymmetricKey? = nil
    static let magic: Data = Data("NOVAVLT1".utf8)
    static let kcService: String = "nova-vault-key"
    static let kcAccount: String = "nova-coffre-aes256"
    #endif

    public static var platformSupported: Bool {
        #if os(macOS)
        return true
        #else
        return false
        #endif
    }
    public static var isOpen: Bool {
        io.lock(); defer { io.unlock() }
        return keyLoaded || clearMode || !platformSupported
    }
    static func encURL(_ name: String) -> URL { Paths.file(name + ".enc") }
    static func exists(_ u: URL) -> Bool { FileManager.default.fileExists(atPath: u.path) }
    static var backupDir: URL { Paths.home.appendingPathComponent("coffre-sauvegardes", isDirectory: true) }

    /// Efface la clé et les données déchiffrées de la mémoire (verrouillage ou expiration).
    static func close() {
        io.lock()
        #if os(macOS)
        key = nil
        #endif
        keyLoaded = false
        clearMode = false
        cache.removeAll()
        io.unlock()
    }
    static func enableClearMode(_ reason: String) { io.lock(); clearMode = true; lastError = reason; io.unlock() }
    static func errorText() -> String { io.lock(); defer { io.unlock() }; return lastError }

    /// Un fichier chiffré (ou une sauvegarde chiffrée) existe-t-il déjà ? Si oui, la clé ne doit JAMAIS être recréée.
    static func anyEncrypted() -> Bool {
        if files.contains(where: { exists(encURL($0)) }) { return true }
        let items: [String] = (try? FileManager.default.contentsOfDirectory(atPath: backupDir.path)) ?? []
        return items.contains(where: { $0.hasSuffix(".enc") })
    }

    static func writeSecure(_ d: Data, to url: URL) -> Bool {
        do { try d.write(to: url, options: .atomic) } catch { return false }
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        return true
    }
    static func canon(_ d: Data) -> Data? {
        guard let o = try? JSONSerialization.jsonObject(with: d) else { return nil }
        return jsonData(o)
    }

    #if os(macOS)
    // ── Trousseau (Security, élément créé par Nova : lisible sans invite avec la signature stable « Nova Dev ») ──
    static func kcRead() -> (status: OSStatus, data: Data?) {
        let q: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
                                kSecAttrService as String: kcService,
                                kSecAttrAccount as String: kcAccount,
                                kSecReturnData as String: true,
                                kSecMatchLimit as String: kSecMatchLimitOne]
        var out: CFTypeRef? = nil
        let st: OSStatus = SecItemCopyMatching(q as CFDictionary, &out)
        return (st, out as? Data)
    }
    static func kcAdd(_ d: Data) -> OSStatus {
        var q: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
                                kSecAttrService as String: kcService,
                                kSecAttrAccount as String: kcAccount,
                                kSecAttrLabel as String: "Nova — clé du coffre (AES-256)",
                                kSecValueData as String: d,
                                kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlockedThisDeviceOnly]
        var st: OSStatus = SecItemAdd(q as CFDictionary, nil)
        if st == errSecParam {   // trousseau de session qui refuse l'attribut : on réessaie sans (signalé dans le rapport)
            q.removeValue(forKey: kSecAttrAccessible as String)
            st = SecItemAdd(q as CFDictionary, nil)
        }
        return st
    }
    static func keyBytes(_ k: SymmetricKey) -> Data { k.withUnsafeBytes { (p: UnsafeRawBufferPointer) -> Data in Data(p) } }
    static func fingerprint(_ k: SymmetricKey) -> String {
        let dg = SHA256.hash(data: Data("nova-vault-fp|".utf8) + keyBytes(k))
        let hx: String = dg.map { String(format: "%02x", $0) }.joined()
        return String(hx.prefix(16))
    }
    static func aad(_ name: String) -> Data { Data(("nova-vault-v1|" + name).utf8) }
    static func seal(_ plain: Data, name: String, key k: SymmetricKey) throws -> Data {
        let box: AES.GCM.SealedBox = try AES.GCM.seal(plain, using: k, nonce: AES.GCM.Nonce(), authenticating: aad(name))
        guard let comb = box.combined else { throw VaultError.seal }
        return magic + comb
    }
    static func unseal(_ blob: Data, name: String, key k: SymmetricKey) throws -> Data {
        guard blob.count > magic.count + 28, Data(blob.prefix(magic.count)) == magic else { throw VaultError.format }
        let box: AES.GCM.SealedBox = try AES.GCM.SealedBox(combined: Data(blob.dropFirst(magic.count)))
        return try AES.GCM.open(box, using: k, authenticating: aad(name))
    }
    #endif

    /// Charge la clé du Trousseau ; ne la crée qu'une seule fois, quand AUCUN fichier chiffré ni empreinte de clé n'existe.
    /// nil = clé prête ; sinon message honnête (rien n'est créé, écrasé ni supprimé).
    static func openKey() -> String? {
        #if os(macOS)
        io.lock(); defer { io.unlock() }
        if key != nil { return nil }
        var c: [String: Any] = cfg.read(default: [String: Any]())
        let known: String? = c["key_fp"] as? String
        if VaultBiometric.enabled() {   // PHASE 4 : la clé ne sort du Trousseau que derrière Touch ID (VaultBiometric.swift) — aucun repli silencieux
            let b: (data: Data?, error: String?) = VaultBiometric.readKey(reason: "ouvrir le coffre de Nova")
            guard let d = b.data, d.count == 32 else { lastError = "Touch ID : " + (b.error ?? "clé illisible") + " — rien n'est ouvert"; return lastError }
            let k = SymmetricKey(data: d)
            if let f = known, f != fingerprint(k) { lastError = "Trousseau biométrique : la clé ne correspond pas à celle du coffre — rien n'est ouvert"; return lastError }
            key = k; keyLoaded = true; lastError = ""
            return nil
        }
        let r: (status: OSStatus, data: Data?) = kcRead()
        if r.status == errSecSuccess {
            guard let d = r.data, d.count == 32 else { lastError = "Trousseau : élément « \(kcService) » inattendu — rien n'est ouvert ni écrasé"; return lastError }
            let k = SymmetricKey(data: d)
            let fp: String = fingerprint(k)
            if let f = known, f != fp { lastError = "Trousseau : la clé trouvée ne correspond pas à celle du coffre — rien n'est ouvert ni écrasé"; return lastError }
            if known == nil { c["key_fp"] = fp; cfg.write(c) }
            key = k; keyLoaded = true; lastError = ""
            return nil
        }
        if r.status != errSecItemNotFound { lastError = "Trousseau : lecture de la clé du coffre refusée ou impossible (OSStatus \(r.status))"; return lastError }
        if known != nil || anyEncrypted() { lastError = "clé du coffre introuvable au Trousseau alors que le coffre a déjà été chiffré : rien n'est créé ni écrasé (voir conseil_24-10/V3_COFFRE.md)"; return lastError }
        let k = SymmetricKey(size: .bits256)
        let d: Data = keyBytes(k)
        let st: OSStatus = kcAdd(d)
        guard st == errSecSuccess else { lastError = "Trousseau : enregistrement de la clé impossible (OSStatus \(st)) — chiffrement non activé"; return lastError }
        let back: (status: OSStatus, data: Data?) = kcRead()
        guard back.status == errSecSuccess, let bd = back.data, bd == d else { lastError = "Trousseau : la clé enregistrée ne se relit pas — chiffrement non activé"; return lastError }
        c["key_fp"] = fingerprint(k); c["key_created"] = nowISO(); cfg.write(c)
        key = k; keyLoaded = true; lastError = ""
        return nil
        #else
        return "chiffrement au repos indisponible sur cette plateforme"
        #endif
    }

    /// Poivre du code : HMAC-SHA256 sous une clé dérivée (HKDF) de la clé du coffre — une fiche volée ne se casse pas hors ligne.
    static func codeMAC(_ derived: [UInt8]) -> [UInt8]? {
        #if os(macOS)
        io.lock(); defer { io.unlock() }
        guard let k = key else { return nil }
        let pk: SymmetricKey = HKDF<SHA256>.deriveKey(inputKeyMaterial: k, info: Data("nova-vault-code-v2".utf8), outputByteCount: 32)
        let mac = HMAC<SHA256>.authenticationCode(for: Data(derived), using: pk)
        return Array(mac)
        #else
        return nil
        #endif
    }

    // ── Lecture / écriture ──
    static func load(_ name: String) -> (value: Any?, error: String?) {
        io.lock(); defer { io.unlock() }
        return loadLocked(name)
    }
    static func readClearLocked(_ name: String, _ u: URL) -> (value: Any?, error: String?) {
        guard exists(u) else { return (nil, nil) }
        guard let d = try? Data(contentsOf: u), let o = try? JSONSerialization.jsonObject(with: d) else { return (nil, "\(name) : fichier illisible") }
        cache[name] = o
        return (o, nil)
    }
    static func loadLocked(_ name: String) -> (value: Any?, error: String?) {
        if let v = cache[name] { return (v, nil) }
        let clear: URL = Paths.file(name)
        #if os(macOS)
        let enc: URL = encURL(name)
        if let k = key {
            if exists(enc) {
                guard let blob = try? Data(contentsOf: enc) else { return (nil, "\(name) : lecture du fichier chiffré impossible") }
                guard let plain = try? unseal(blob, name: name, key: k) else { return (nil, "\(name) : déchiffrement refusé (clé différente ou fichier altéré) — rien n'a été modifié") }
                guard let o = try? JSONSerialization.jsonObject(with: plain) else { return (nil, "\(name) : contenu déchiffré illisible") }
                cache[name] = o
                return (o, nil)
            }
            return readClearLocked(name, clear)   // pas encore migré (migration refusée ou en échec) : le coffre est ouvert, lecture claire
        }
        if clearMode && !exists(enc) { return readClearLocked(name, clear) }
        return (nil, "coffre fermé")
        #else
        return readClearLocked(name, clear)
        #endif
    }
    static func clearWriteLocked(_ d: Data, name: String, url: URL) -> Bool {
        guard writeSecure(d, to: url) else { lastError = "\(name) : écriture impossible"; return false }
        if let o = try? JSONSerialization.jsonObject(with: d) { cache[name] = o } else { cache.removeValue(forKey: name) }
        return true
    }
    static func store(_ name: String, _ obj: Any) -> Bool {
        io.lock(); defer { io.unlock() }
        let d: Data = jsonData(obj)
        let clear: URL = Paths.file(name)
        #if os(macOS)
        let enc: URL = encURL(name)
        if let k = key {
            if exists(enc) && cache[name] == nil {   // jamais d'écrasement d'un fichier chiffré qu'on n'a pas su lire
                let r: (value: Any?, error: String?) = loadLocked(name)
                if r.value == nil { lastError = r.error ?? "\(name) : fichier chiffré illisible — écriture refusée"; return false }
            }
            if !exists(enc) && exists(clear) { return clearWriteLocked(d, name: name, url: clear) }   // pas encore migré : on reste en clair, la migration s'en charge
            guard let blob = try? seal(d, name: name, key: k), writeSecure(blob, to: enc) else { lastError = "\(name) : écriture chiffrée impossible"; return false }
            if let o = try? JSONSerialization.jsonObject(with: d) { cache[name] = o } else { cache.removeValue(forKey: name) }
            return true
        }
        if clearMode && !exists(enc) { return clearWriteLocked(d, name: name, url: clear) }
        lastError = "coffre fermé : écriture refusée (\(name))"
        return false
        #else
        return clearWriteLocked(d, name: name, url: clear)
        #endif
    }

    // ── Migration clair → chiffré (sûre, vérifiée, idempotente) ──
    #if os(macOS)
    static func backupLocked(_ orig: Data, name: String, key k: SymmetricKey) -> URL? {
        do { try FileManager.default.createDirectory(at: backupDir, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700]) } catch { return nil }
        let stamp: String = nowISO().replacingOccurrences(of: ":", with: "-")
        let u: URL = backupDir.appendingPathComponent(name + "." + stamp + ".enc")
        guard let blob = try? seal(orig, name: name, key: k), writeSecure(blob, to: u) else { return nil }
        guard let rb = try? Data(contentsOf: u), let back = try? unseal(rb, name: name, key: k), back == orig else { return nil }
        return u
    }
    #endif
    static func migrate() -> [String: Any] {
        #if os(macOS)
        io.lock(); defer { io.unlock() }
        guard let k = key else { return ["ok": false, "error": "clé absente : migration non tentée"] }
        let fm = FileManager.default
        var done: [String] = [], conflicts: [String] = [], skipped: [String] = [], errors: [String] = []
        for name in files {
            let clear: URL = Paths.file(name), enc: URL = encURL(name)
            guard exists(clear) else { continue }
            guard let orig = try? Data(contentsOf: clear) else { errors.append(name + " : lecture du fichier clair impossible"); continue }
            guard let origCanon = canon(orig) else { skipped.append(name + " : JSON illisible, laissé tel quel"); continue }
            if exists(enc) {   // les deux existent (reprise après coupure, ou ancienne version relancée)
                guard let eb = try? Data(contentsOf: enc), let cur = try? unseal(eb, name: name, key: k), let curCanon = canon(cur) else { conflicts.append(name + " : fichier chiffré illisible à côté du clair — rien n'est supprimé"); continue }
                if curCanon != origCanon { conflicts.append(name + " : versions claire et chiffrée différentes — rien n'est supprimé (la version chiffrée fait foi)"); continue }
            }
            // 1. sauvegarde chiffrée de l'original, relue et vérifiée
            guard backupLocked(orig, name: name, key: k) != nil else { errors.append(name + " : sauvegarde chiffrée impossible — fichier clair conservé"); continue }
            // 2. fichier chiffré via un temporaire relu et vérifié, puis renommé, puis relu encore
            if !exists(enc) {
                let tmp: URL = Paths.file(name + ".enc.tmp")
                guard let blob = try? seal(orig, name: name, key: k), writeSecure(blob, to: tmp),
                      let rb = try? Data(contentsOf: tmp), let back = try? unseal(rb, name: name, key: k), back == orig else {
                    try? fm.removeItem(at: tmp); errors.append(name + " : chiffrement non vérifié — fichier clair conservé"); continue }
                do { try fm.moveItem(at: tmp, to: enc) } catch { try? fm.removeItem(at: tmp); errors.append(name + " : mise en place du fichier chiffré impossible — fichier clair conservé"); continue }
                guard let rb2 = try? Data(contentsOf: enc), let back2 = try? unseal(rb2, name: name, key: k), back2 == orig else {
                    try? fm.removeItem(at: enc); errors.append(name + " : relecture du fichier chiffré en échec — fichier clair conservé"); continue }
            }
            // 3. retrait du clair : son contenu exact vit désormais dans <nom>.enc ET dans la sauvegarde, tous deux vérifiés
            do { try fm.removeItem(at: clear) } catch { errors.append(name + " : chiffré, mais le fichier clair n'a pas pu être retiré"); continue }
            cache.removeValue(forKey: name)
            done.append(name)
        }
        let ok: Bool = errors.isEmpty && conflicts.isEmpty
        let out: [String: Any] = ["ok": ok, "at": nowISO(), "migrated": done, "conflicts": conflicts, "skipped": skipped, "errors": errors, "backup_dir": backupDir.path]
        if !(done.isEmpty && conflicts.isEmpty && skipped.isEmpty && errors.isEmpty) {
            var c: [String: Any] = cfg.read(default: [String: Any]()); c["migration"] = out; cfg.write(c)
            let detail: String = "\(done.count) fichier(s) chiffré(s) · \(conflicts.count) conflit(s) · \(errors.count) erreur(s) · \(skipped.count) laissé(s) tel(s) quel(s)"
            _ = BlackBox.record(["tool": "coffre", "actor": "Nova", "effect": "lecture", "ok": ok, "why": ok ? "coffre migré" : "coffre migré (partiel)", "result": detail])
        }
        return out
        #else
        return ["ok": false, "error": "chiffrement au repos indisponible sur cette plateforme"]
        #endif
    }

    /// Retour arrière : réécrit une copie CLAIRE de chaque fichier chiffré (sans rien supprimer, sans écraser un clair existant).
    static func restoreClear() -> [String: Any] {
        #if os(macOS)
        io.lock(); defer { io.unlock() }
        guard let k = key else { return ["ok": false, "error": "clé du coffre non chargée"] }
        var restored: [String] = [], kept: [String] = [], errors: [String] = []
        for name in files {
            let enc: URL = encURL(name), clear: URL = Paths.file(name)
            guard exists(enc) else { continue }
            if exists(clear) { kept.append(name); continue }
            guard let blob = try? Data(contentsOf: enc), let plain = try? unseal(blob, name: name, key: k), writeSecure(plain, to: clear) else { errors.append(name); continue }
            restored.append(name)
        }
        return ["ok": errors.isEmpty, "restored": restored, "already_clear": kept, "errors": errors,
                "note": "Copies claires posées à côté des fichiers chiffrés (rien n'est supprimé). Quitte Nova, puis reviens à la version précédente du code avant de rouvrir le coffre."]
        #else
        return ["ok": false, "error": "chiffrement au repos indisponible sur cette plateforme : rien à restaurer"]
        #endif
    }

    static func report() -> [String: Any] {
        io.lock(); defer { io.unlock() }
        let enc: Int = files.filter { exists(encURL($0)) }.count
        let clear: Int = files.filter { exists(Paths.file($0)) }.count
        var o: [String: Any] = ["supported": platformSupported, "encrypted_files": enc, "clear_files": clear, "active": keyLoaded, "clear_mode": clearMode,
                                "algorithm": "AES-256-GCM (CryptoKit) · clé au Trousseau (WhenUnlockedThisDeviceOnly)"]
        if !lastError.isEmpty { o["error"] = lastError }
        if let m = cfg.read(default: [String: Any]())["migration"] { o["migration"] = m }
        return o
    }
}

/// Code du coffre : empreinte salée PBKDF2-HMAC-SHA256 (CommonCrypto), comparée en temps constant.
enum VaultCode {
    static let rounds: Int = 210000   // identique à l'ancienne dérivation côté interface : les fiches existantes restent vérifiables
    static func hex(_ b: [UInt8]) -> String { b.map { String(format: "%02x", $0) }.joined() }
    static func unhex(_ s: String) -> [UInt8]? {
        let cs: [UInt8] = Array(s.utf8)
        guard !cs.isEmpty, cs.count % 2 == 0 else { return nil }
        var out: [UInt8] = []
        out.reserveCapacity(cs.count / 2)
        var i: Int = 0
        while i < cs.count {
            guard let v = UInt8(String(decoding: cs[i..<(i + 2)], as: UTF8.self), radix: 16) else { return nil }
            out.append(v)
            i += 2
        }
        return out
    }
    static func same(_ a: [UInt8], _ b: [UInt8]) -> Bool {
        guard a.count == b.count, !a.isEmpty else { return false }
        var d: UInt8 = 0
        for i in 0..<a.count { d |= a[i] ^ b[i] }
        return d == 0
    }
    static func salt() -> [UInt8] { (0..<16).map { _ in UInt8.random(in: 0...255) } }
    static func pbkdf2(_ code: String, salt: [UInt8], rounds n: Int) -> [UInt8]? {
        #if os(macOS)
        guard !salt.isEmpty, n > 0 else { return nil }
        var out: [UInt8] = [UInt8](repeating: 0, count: 32)
        let pwLen: Int = code.utf8.count
        let saltLen: Int = salt.count
        let st: Int32 = code.withCString { (pw: UnsafePointer<CChar>) -> Int32 in
            salt.withUnsafeBufferPointer { (sp: UnsafeBufferPointer<UInt8>) -> Int32 in
                out.withUnsafeMutableBufferPointer { (op: inout UnsafeMutableBufferPointer<UInt8>) -> Int32 in
                    CCKeyDerivationPBKDF(CCPBKDFAlgorithm(kCCPBKDF2), pw, pwLen, sp.baseAddress, saltLen,
                                         CCPseudoRandomAlgorithm(kCCPRFHmacAlgSHA256), UInt32(n), op.baseAddress, 32)
                }
            }
        }
        return st == Int32(kCCSuccess) ? out : nil
        #else
        return nil
        #endif
    }
    /// Fiche v2 (poivrée) ; nil si la clé du coffre n'est pas chargée.
    static func record(_ code: String) -> [String: Any]? {
        let s: [UInt8] = salt()
        guard let d = pbkdf2(code, salt: s, rounds: rounds), let m = VaultCrypto.codeMAC(d) else { return nil }
        return ["v": 2, "kdf": "PBKDF2-HMAC-SHA256", "iter": rounds, "salt": hex(s), "mac": hex(m)]
    }
    /// Fiche v1 (sel + empreinte PBKDF2 calculée par le moteur) : seulement si la clé du coffre est indisponible.
    static func legacy(_ code: String) -> (salt: String, hash: String)? {
        let s: [UInt8] = salt()
        guard let d = pbkdf2(code, salt: s, rounds: rounds) else { return nil }
        return (hex(s), hex(d))
    }
}

/// LocalAuthentication côté moteur (même processus que l'app) : Touch ID ou mot de passe du Mac.
enum VaultSystemAuth {
    struct Avail { let ok: Bool; let biometry: String; let label: String; let message: String }
    final class Box { var ok: Bool = false; var code: Int = 0; var msg: String = "" }

    static func availability() -> Avail {
        #if os(macOS)
        let c = LAContext()
        var err: NSError? = nil
        let ok: Bool = c.canEvaluatePolicy(.deviceOwnerAuthentication, error: &err)
        var berr: NSError? = nil
        let bio: Bool = c.canEvaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, error: &berr)
        let touch: Bool = bio && c.biometryType == .touchID
        let why: String = berr?.localizedDescription ?? "aucun capteur ou aucune empreinte enregistrée"
        let whyNot: String = err?.localizedDescription ?? "raison inconnue"
        if !ok { return Avail(ok: false, biometry: "aucune", label: "", message: "Authentification du Mac indisponible : " + whyNot + ".") }
        if touch { return Avail(ok: true, biometry: "touchid", label: "Déverrouiller avec Touch ID", message: "") }
        return Avail(ok: true, biometry: "motdepasse", label: "Déverrouiller avec le mot de passe du Mac", message: "Touch ID indisponible (" + why + ") : macOS demandera le mot de passe de ta session.")
        #else
        return Avail(ok: false, biometry: "aucune", label: "", message: "Authentification système indisponible sur cette plateforme.")
        #endif
    }

    /// Bloque jusqu'à la réponse de l'utilisateur (ou `timeout`). Aucun secret ne transite par Nova.
    static func evaluate(reason: String, timeout: TimeInterval) -> (ok: Bool, cancelled: Bool, message: String) {
        #if os(macOS)
        let c = LAContext()
        c.localizedCancelTitle = "Annuler"
        let box = Box()
        let sem = DispatchSemaphore(value: 0)
        c.evaluatePolicy(.deviceOwnerAuthentication, localizedReason: reason) { (success: Bool, error: Error?) in
            box.ok = success
            if let e = error as NSError? { box.code = e.code; box.msg = e.localizedDescription }
            sem.signal()
        }
        if sem.wait(timeout: .now() + timeout) == .timedOut {
            c.invalidate()
            return (false, true, "délai dépassé : aucune réponse à la demande d'authentification")
        }
        if box.ok { return (true, false, "") }
        let cancelCodes: [Int] = [LAError.Code.userCancel.rawValue, LAError.Code.systemCancel.rawValue, LAError.Code.appCancel.rawValue]
        return (false, cancelCodes.contains(box.code), box.msg.isEmpty ? "authentification refusée" : box.msg)
        #else
        return (false, false, "authentification système indisponible sur cette plateforme")
        #endif
    }
}

extension NovaApp {
    func vaultRoutes() {
        let s = server
        let cfg: JSONFile = VaultCrypto.cfg
        let sess: VaultSession = VaultSession.shared
        let ttl: Int = Int(VaultSession.idle)
        func tok(_ req: Request) -> String { req.headers["x-vault"] ?? "" }
        func valid(_ req: Request) -> Bool { sess.check(tok(req), touch: false) }
        func validTouch(_ req: Request) -> Bool { sess.check(tok(req), touch: true) }
        func store(_ d: String) -> VaultFile { VaultFile("vault_\(d == "sante" ? "sante" : "finance").json") }
        func conf() -> [String: Any] { cfg.read(default: [String: Any]()) }
        func hasCode() -> Bool { let c = conf(); return c["code"] != nil || c["hash"] != nil }
        func secondFactor() -> Bool { (conf()["second_factor"] as? Bool) ?? false }
        func waitLeft() -> Int {
            let w: Double = (conf()["wait_until"] as? Double) ?? 0
            let left: Double = w - Date().timeIntervalSince1970
            return left > 0 ? Int(left.rounded(.up)) : 0
        }
        func journal(_ what: String, ok: Bool, _ detail: String) {
            _ = BlackBox.record(["tool": "coffre", "actor": "Ahadi", "effect": "lecture", "ok": ok, "why": what, "result": detail])
        }
        /// Échec de code : délai croissant persistant (3e échec : 5 s, puis ×2, plafond 15 min).
        func noteFail() -> Int {
            var c = conf()
            let n: Int = ((c["fails"] as? Int) ?? 0) + 1
            var w: Double = 0
            if n >= 3 { w = 5; var i: Int = 3; while i < n && w < 900 { w *= 2; i += 1 }; w = min(900, w) }
            c["fails"] = n
            c["wait_until"] = Date().timeIntervalSince1970 + w
            cfg.write(c)
            return Int(w)
        }
        func noteSuccess() { var c = conf(); c["fails"] = 0; c.removeValue(forKey: "wait_until"); cfg.write(c) }
        /// Vérifie le code ; met à niveau l'ancienne fiche (empreinte calculée par l'interface) en fiche v2 poivrée.
        func verifyCode(_ code: String) -> (ok: Bool, err: String?) {
            var c = conf()
            if let rec = c["code"] as? [String: Any] {
                guard let salt = VaultCode.unhex((rec["salt"] as? String) ?? ""), let mac = VaultCode.unhex((rec["mac"] as? String) ?? ""), let it = rec["iter"] as? Int else { return (false, "fiche du code illisible") }
                guard let d = VaultCode.pbkdf2(code, salt: salt, rounds: it) else { return (false, "dérivation du code impossible") }
                guard let m = VaultCrypto.codeMAC(d) else { return (false, "clé du coffre indisponible : le code ne peut pas être vérifié (" + VaultCrypto.errorText() + ")") }
                return (VaultCode.same(m, mac), nil)
            }
            if let h = c["hash"] as? String, let saltHex = c["salt"] as? String {
                guard let salt = VaultCode.unhex(saltHex), let want = VaultCode.unhex(h), let d = VaultCode.pbkdf2(code, salt: salt, rounds: VaultCode.rounds) else { return (false, "fiche du code illisible") }
                guard VaultCode.same(d, want) else { return (false, nil) }
                if let rec = VaultCode.record(code) {   // mise à niveau : l'ancienne empreinte disparaît du disque
                    c["code"] = rec; c.removeValue(forKey: "hash"); c.removeValue(forKey: "salt"); cfg.write(c)
                }
                return (true, nil)
            }
            return (false, "aucun code défini")
        }
        /// Fin d'ouverture acceptée (l'appelant a fait sess.beginOpen()) : clé, migration, jeton.
        func finishOpen(_ how: String, keyError: String?) -> (token: String?, error: String?, migration: [String: Any]) {
            if let e = keyError {
                if VaultCrypto.anyEncrypted() {
                    _ = sess.endOpen(issue: nil)
                    journal("coffre refusé", ok: false, how + " accepté, mais clé du coffre illisible : " + e)
                    return (nil, e, [:])
                }
                VaultCrypto.enableClearMode(e)
            }
            // 24/10 : Nova 1 partage ce dossier de données et lit le coffre EN CLAIR — la migration
            // n'a lieu que si Ahadi l'a demandée explicitement (POST /api/vault/encrypt), jamais seule.
            let wantEnc: Bool = Settings().get("vault_encrypt", "") == "1"
            let mig: [String: Any] = (keyError == nil && wantEnc) ? VaultCrypto.migrate() : [:]
            let t: String? = sess.endOpen(issue: how)
            let mode: String = keyError == nil ? "chiffré au repos" : "NON chiffré : " + (keyError ?? "")
            journal("coffre ouvert", ok: true, how + " · " + mode)
            return (t, nil, mig)
        }

        portfolioRoutes(valid: { (req: Request) -> Bool in sess.check(tok(req), touch: req.method == "POST") })

        s.on("GET", "/api/vault/status") { req, res in
            let a: VaultSystemAuth.Avail = VaultSystemAuth.availability()
            var o: [String: Any] = ["configured": hasCode(), "code": hasCode(), "unlocked": valid(req), "wait": waitLeft(),
                                    "second_factor": secondFactor(), "idle_ttl": ttl]
            o["system"] = ["available": a.ok, "biometry": a.biometry, "label": a.label, "message": a.message] as [String: Any]
            o["encryption"] = VaultCrypto.report()
            res.json(o)
        }
        // Touch ID / mot de passe du Mac (LAContext, dans le processus de l'app) → jeton, ou ticket si le code est exigé en second facteur.
        s.on("POST", "/api/vault/unlock/system") { req, res in
            let a: VaultSystemAuth.Avail = VaultSystemAuth.availability()
            guard a.ok else { res.json(["error": a.message], status: 409); return }
            // PHASE 4 : clé derrière Touch ID au Trousseau → c'est la LECTURE de la clé qui authentifie (une seule invite),
            // AVANT tout ticket ou jeton ; un refus ferme la porte (jamais de repli « coffre en clair »).
            let bioGate: Bool = VaultBiometric.enabled()
            if bioGate {
                if let e = VaultCrypto.openKey() {
                    journal("coffre refusé", ok: false, "touchid (Trousseau) : " + e)
                    res.json(["error": e, "cancelled": e.contains("annulée")], status: 401); return
                }
            }
            let r: (ok: Bool, cancelled: Bool, message: String) = bioGate ? (ok: true, cancelled: false, message: "") : VaultSystemAuth.evaluate(reason: "ouvrir le coffre de Nova", timeout: 120)
            guard r.ok else {
                journal("coffre refusé", ok: false, a.biometry + " : " + (r.cancelled ? "annulé" : r.message))
                res.json(["error": r.cancelled ? "Ouverture annulée." : r.message, "cancelled": r.cancelled], status: 401); return
            }
            if secondFactor() && hasCode() { res.json(["need_code": true, "ticket": sess.newTicket(), "ttl": 120]); return }
            sess.beginOpen()
            let ke: String? = VaultCrypto.openKey()
            let f = finishOpen(a.biometry, keyError: ke)
            guard let tk = f.token else { res.json(["error": f.error ?? "ouverture impossible"], status: 500); return }
            res.json(["token": tk, "ttl": ttl, "migration": f.migration])
        }
        // Code : repli (ou second facteur avec ticket). Le moteur dérive et compare ; il n'accepte plus d'empreinte.
        s.on("POST", "/api/vault/unlock") { req, res in
            let j: [String: Any] = req.json
            guard let code = j["code"] as? String, !code.isEmpty, code.count <= 256 else {
                res.json(["error": j["hash"] != nil ? "Interface périmée : recharge Nova (le code est désormais vérifié par le moteur)." : "code manquant"], status: 400); return
            }
            let ticket: String = (j["ticket"] as? String) ?? ""
            let viaTicket: Bool = sess.hasTicket(ticket)
            if secondFactor() && !viaTicket && VaultSystemAuth.availability().ok {
                res.json(["error": "Second facteur activé : déverrouille d'abord avec Touch ID ou le mot de passe du Mac."], status: 403); return
            }
            sess.codeLock.lock(); defer { sess.codeLock.unlock() }
            let w: Int = waitLeft()
            if w > 0 { res.json(["error": "Trop d'essais : attends \(w) s.", "wait": w], status: 429); return }
            sess.beginOpen()
            let ke: String? = VaultCrypto.openKey()
            let v: (ok: Bool, err: String?) = verifyCode(code)
            guard v.ok else {
                _ = sess.endOpen(issue: nil)
                if let e = v.err { journal("coffre refusé", ok: false, "code : " + e); res.json(["error": e], status: 409); return }
                let delay: Int = noteFail()
                journal("coffre refusé", ok: false, "code incorrect")
                res.json(["error": "Code incorrect.", "wait": delay], status: 401); return
            }
            noteSuccess()
            if viaTicket { sess.dropTicket(ticket) }
            let f = finishOpen(viaTicket ? "système + code" : "code", keyError: ke)
            guard let tk = f.token else { res.json(["error": f.error ?? "ouverture impossible"], status: 500); return }
            res.json(["token": tk, "ttl": ttl, "migration": f.migration])
        }
        // Définir / changer le code. Coffre ouvert exigé, sauf premier code sur un Mac sans authentification système.
        s.on("POST", "/api/vault/setup") { req, res in
            let j: [String: Any] = req.json
            guard let code = j["code"] as? String else { res.json(["error": j["hash"] != nil ? "Interface périmée : recharge Nova." : "code manquant"], status: 400); return }
            guard code.count >= 4, code.count <= 128 else { res.json(["error": "Le code doit faire de 4 à 128 caractères."], status: 400); return }
            let open: Bool = validTouch(req)
            if hasCode() && !open { res.json(["error": "Déverrouille d'abord le coffre pour changer le code."], status: 423); return }
            if !hasCode() && !open && VaultSystemAuth.availability().ok { res.json(["error": "Ouvre d'abord le coffre avec Touch ID ou le mot de passe du Mac, puis ajoute un code."], status: 423); return }
            if !open { sess.beginOpen() }
            let ke: String? = open ? nil : VaultCrypto.openKey()
            if let e = ke, VaultCrypto.anyEncrypted() { _ = sess.endOpen(issue: nil); res.json(["error": e], status: 500); return }
            var c = conf()
            if let rec = VaultCode.record(code) { c["code"] = rec; c.removeValue(forKey: "hash"); c.removeValue(forKey: "salt") }
            else if let leg = VaultCode.legacy(code) { c.removeValue(forKey: "code"); c["salt"] = leg.salt; c["hash"] = leg.hash }
            else { if !open { _ = sess.endOpen(issue: nil) }; res.json(["error": "dérivation du code impossible"], status: 500); return }
            c["fails"] = 0; c.removeValue(forKey: "wait_until"); cfg.write(c)
            journal("code du coffre défini", ok: true, open ? "changé, coffre ouvert" : "premier code (pas d'authentification système)")
            if open { res.json(["ok": true]); return }
            let f = finishOpen("code", keyError: ke)
            guard let tk = f.token else { res.json(["error": f.error ?? "ouverture impossible"], status: 500); return }
            res.json(["ok": true, "token": tk, "ttl": ttl, "migration": f.migration])
        }
        s.on("POST", "/api/vault/mode") { req, res in
            guard validTouch(req) else { res.json(["error": "coffre verrouillé"], status: 423); return }
            let on: Bool = (req.json["second_factor"] as? Bool) ?? false
            if on && !hasCode() { res.json(["error": "Définis d'abord un code."], status: 400); return }
            if on && !VaultSystemAuth.availability().ok { res.json(["error": "Touch ID et mot de passe du Mac indisponibles : le second facteur n'aurait pas de premier facteur."], status: 409); return }
            var c = conf(); c["second_factor"] = on; cfg.write(c)
            journal("mode du coffre", ok: true, on ? "second facteur : système + code" : "code en repli")
            res.json(["ok": true, "second_factor": on])
        }
        s.on("POST", "/api/vault/touch") { req, res in   // activité de l'utilisateur : repousse l'expiration d'inactivité
            let ok: Bool = validTouch(req)
            res.json(["ok": ok, "unlocked": ok, "ttl": ttl], status: ok ? 200 : 423)
        }
        s.on("POST", "/api/vault/lock") { req, res in
            if sess.revoke(tok(req)) { journal("coffre fermé", ok: true, "verrouillé (sortie d'écran ou bouton)") }
            res.json(["ok": true])
        }
        // Retour arrière (V3_COFFRE.md) : copies claires posées à côté des fichiers chiffrés, sur confirmation explicite.
        s.on("POST", "/api/vault/encrypt") { req, res in
            guard validTouch(req) else { res.json(["error": "coffre verrouillé"], status: 423); return }
            guard (req.json["confirm"] as? String) == "CHIFFRER" else { res.json(["error": "confirmation manquante (confirm: \"CHIFFRER\") — attention : Nova 1 ne pourra plus lire le coffre"], status: 400); return }
            Settings().set(["vault_encrypt": "1"])
            let r: [String: Any] = VaultCrypto.migrate()
            journal("coffre : chiffrement au repos activé par Ahadi", ok: true, "migration demandée")
            res.json(["ok": true, "migration": r])
        }
        s.on("POST", "/api/vault/restore-clear") { req, res in
            guard validTouch(req) else { res.json(["error": "coffre verrouillé"], status: 423); return }
            guard (req.json["confirm"] as? String) == "RESTAURER" else { res.json(["error": "confirmation manquante (confirm: \"RESTAURER\")"], status: 400); return }
            let r: [String: Any] = VaultCrypto.restoreClear()
            journal("coffre : copies claires restaurées", ok: (r["ok"] as? Bool) ?? false, "\(((r["restored"] as? [String]) ?? []).count) fichier(s)")
            res.json(r, status: ((r["ok"] as? Bool) ?? false) ? 200 : 500)
        }
        s.on("GET", "/api/vault/data") { req, res in
            guard valid(req) else { res.json(["error": "coffre verrouillé"], status: 423); return }
            let r: (value: Any?, error: String?) = store(req.query["domain"] ?? "finance").readChecked()
            if let e = r.error { res.json(["error": e], status: 500); return }
            res.json(r.value ?? (["sources": [Any]()] as [String: Any]))
        }
        s.on("POST", "/api/vault/import") { req, res in
            guard validTouch(req) else { res.json(["error": "coffre verrouillé"], status: 423); return }
            let dom = (req.json["domain"] as? String) ?? "finance"
            var path = (req.json["path"] as? String) ?? ""
            if path.hasPrefix("~") { path = NSHomeDirectory() + path.dropFirst() }
            path = URL(fileURLWithPath: path).standardizedFileURL.resolvingSymlinksInPath().path
            let home = URL(fileURLWithPath: NSHomeDirectory()).resolvingSymlinksInPath().path
            let bad = ["/.ssh", "/.gnupg", "/Library/Keychains", "/.bionic-tools", "/.aws", "/.config/gcloud", ".key", ".pem", "secret", "token", "password", "motdepasse"]
            guard path.hasPrefix(home + "/"), !bad.contains(where: { path.lowercased().contains($0.lowercased()) }) else { res.json(["error": "chemin refusé (hors de ton dossier ou emplacement sensible)"], status: 400); return }
            var pdfLines: [String]? = nil
            if path.lowercased().hasSuffix(".pdf") { guard let t = VaultHooks.pdfText?(path), !t.isEmpty else { res.json(["error": "PDF sans texte lisible (scan/image ?) — exporte plutôt en CSV ou Excel depuis la plateforme"], status: 400); return }; pdfLines = t.split(whereSeparator: \.isNewline).map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty } }
            guard let data = FileManager.default.contents(atPath: path), data.count < 8_000_000, let text = pdfLines != nil ? "" : String(data: data, encoding: .utf8) else { res.json(["error": "fichier illisible ou trop gros (> 8 Mo)"], status: 400); return }
            var cols: [String] = []; var rows: [[String]] = []
            if let pl = pdfLines {
                let parts = pl.prefix(2000).map { l in l.components(separatedBy: "  ").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty } }
                let w = max(1, parts.map(\.count).max() ?? 1); cols = (1...w).map { "col\($0)" }; rows = parts.map { $0 + Array(repeating: "", count: w - $0.count) }
            } else if path.lowercased().hasSuffix(".json"), let j = try? JSONSerialization.jsonObject(with: data) {
                func str(_ v: Any?) -> String { if let s = v as? String { return s }; if let n = v as? NSNumber { return n.stringValue }; return v == nil ? "" : "\(v!)" }
                if let arr = j as? [[String: Any]] { cols = Array(Set(arr.flatMap { $0.keys })).sorted(); rows = arr.prefix(2000).map { o in cols.map { str(o[$0]) } } }
                else if let o = j as? [String: Any] { cols = ["clé", "valeur"]; rows = o.keys.sorted().map { [$0, str(o[$0])] } }
            } else {
                let lines = text.split(whereSeparator: \.isNewline).map(String.init)
                let delim: Character = (lines.first?.filter { $0 == ";" }.count ?? 0) > (lines.first?.filter { $0 == "," }.count ?? 0) ? ";" : ((lines.first?.contains("\t") ?? false) ? "\t" : ",")
                func split(_ l: String) -> [String] { var out: [String] = [], cur = "", q = false
                    for ch in l { if ch == "\"" { q.toggle() } else if ch == delim && !q { out.append(cur); cur = "" } else { cur.append(ch) } }
                    out.append(cur); return out.map { $0.trimmingCharacters(in: .whitespaces) } }
                if let f = lines.first { cols = split(f); rows = lines.dropFirst().prefix(2000).map(split) }
            }
            guard !cols.isEmpty else { res.json(["error": "format non reconnu (CSV, JSON ou PDF texte attendu)"], status: 400); return }
            let f = store(dom)
            let cur: (value: Any?, error: String?) = f.readChecked()
            if let e = cur.error { res.json(["error": e], status: 500); return }
            var d: [String: Any] = (cur.value as? [String: Any]) ?? ["sources": [] as [Any]]
            var srcs = (d["sources"] as? [[String: Any]]) ?? []
            let id = String(UUID().uuidString.prefix(8)).lowercased()
            srcs.append(["id": id, "label": (req.json["label"] as? String) ?? (path as NSString).lastPathComponent, "path": path, "imported": nowISO(), "columns": cols, "rows": rows])
            d["sources"] = srcs
            guard f.write(d) else { res.json(["error": "écriture refusée : " + VaultCrypto.errorText()], status: 500); return }
            res.json(["ok": true, "id": id, "rows": rows.count, "columns": cols])
        }
        s.on("POST", "/api/vault/remove") { req, res in
            guard validTouch(req) else { res.json(["error": "coffre verrouillé"], status: 423); return }
            let f = store((req.json["domain"] as? String) ?? "finance")
            let cur: (value: Any?, error: String?) = f.readChecked()
            if let e = cur.error { res.json(["error": e], status: 500); return }
            var d: [String: Any] = (cur.value as? [String: Any]) ?? ["sources": [] as [Any]]
            d["sources"] = ((d["sources"] as? [[String: Any]]) ?? []).filter { ($0["id"] as? String) != (req.json["id"] as? String) }
            guard f.write(d) else { res.json(["error": "écriture refusée : " + VaultCrypto.errorText()], status: 500); return }
            res.json(["ok": true])
        }
    }
}
