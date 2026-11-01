import Foundation
#if os(macOS)
import Security
#endif

/// Références de clés : on ne manipule JAMAIS une valeur en dehors de `KeyStore.value`, jamais loggée ni renvoyée à l'UI.
public struct KeyRef: Hashable {
    public let service: String
    public let accounts: [String]   // comptes essayés dans l'ordre ("" = n'importe lequel)
    public let envVars: [String]
    public init(service: String, accounts: [String] = [], envVars: [String] = []) {
        self.service = service; self.accounts = accounts; self.envVars = envVars
    }
}

public protocol KeyStore {
    func value(_ ref: KeyRef) -> String?
}

/// Trousseau macOS via /usr/bin/security (même mécanique que SparkLocal : les éléments existants restent lisibles).
public final class KeychainStore: KeyStore {
    var cache: [String: (String?, Date)] = [:]
    let lock = NSLock()
    public init() {}
    static var user: String { ProcessInfo.processInfo.environment["USER"] ?? NSUserName() }

    public func value(_ ref: KeyRef) -> String? {
        for v in ref.envVars {
            if let e = ProcessInfo.processInfo.environment[v], !e.trimmingCharacters(in: .whitespaces).isEmpty {
                return e.trimmingCharacters(in: .whitespacesAndNewlines)
            }
        }
        let ck = ref.service + "|" + ref.accounts.joined(separator: ",")
        lock.lock()
        if let c = cache[ck], Date().timeIntervalSince(c.1) < 300 { lock.unlock(); return c.0 }
        lock.unlock()
        var found: String? = nil
        #if os(macOS)
        var tries: [[String]] = ref.accounts.map { ["-a", $0 == "$USER" ? Self.user : $0, "-s", ref.service] }
        tries.append(["-s", ref.service])
        for t in tries {
            // Sonde native (attributs seulement, jamais la valeur secrète : aucune demande d'autorisation du Trousseau).
            // Élément absent → on passe sans lancer /usr/bin/security (~0,5 s par appel évité).
            if !Self.exists(service: ref.service, account: t.count == 4 ? t[1] : nil) { continue }
            let (code, out) = runProcess("/usr/bin/security", ["find-generic-password"] + t + ["-w"], timeout: 3)
            let v = out.trimmingCharacters(in: .whitespacesAndNewlines)
            if code == 0 && !v.isEmpty { found = v; break }
        }
        #endif
        lock.lock(); cache[ck] = (found, Date()); lock.unlock()
        return found
    }

    /// Enregistre une clé saisie dans l'app (service "nova-…"). -U = mise à jour si elle existe.
    /// PHASE 1 (sécurité) : la valeur ne passe PLUS en argument de /usr/bin/security (visible un instant dans `ps` par tout
    /// processus de l'utilisateur). Elle est écrite sur l'entrée standard de `security -i` (mode commandes) : la ligne de
    /// commande visible ne contient que « /bin/sh -c exec /usr/bin/security -i 2>&1 ». On garde /usr/bin/security (et non
    /// SecItemAdd) pour que la liste d'accès de l'élément reste celle que KeychainStore.value sait relire sans dialogue.
    public static func save(service: String, value: String) -> Bool {
        #if os(macOS)
        if let inv = saveInvocation(user: user, service: service, value: value) {
            let (c, out) = runProcess(inv.path, inv.args, timeout: 8, stdin: inv.stdin)
            // `security -i` peut rendre 0 même si la commande échoue : on relit l'élément (comme KeychainStore.value) et on compare
            // en temps constant — aucune valeur n'est journalisée ni renvoyée.
            if c == 0 && !out.contains("security: ") {
                let (rc, back) = runProcess("/usr/bin/security", ["find-generic-password", "-a", user, "-s", service, "-w"], timeout: 5)
                if rc == 0 && HTTPServer.constantTimeEquals(back.trimmingCharacters(in: .newlines), value) { return true }
            }
        }
        // Repli (valeur non représentable en mode commandes, ou relecture différente) : ancien chemin, valeur en argument.
        // Journalisé sans la valeur pour qu'on sache que l'exposition `ps` a eu lieu.
        _ = BlackBox.record(["tool": "keychain", "actor": "Nova", "ok": false, "effect": "écriture",
                             "why": "PHASE 1 : écriture par entrée standard impossible pour \(service) — repli sur l'argument -w", "result": "repli"])
        let (c, _) = runProcess("/usr/bin/security", ["add-generic-password", "-U", "-a", user, "-s", service, "-w", value], timeout: 5)
        return c == 0
        #else
        return false
        #endif
    }
    /// PHASE 1 : invocation pure (testée) — la valeur n'apparaît que dans `stdin`, jamais dans `args`. nil = valeur refusée
    /// (vide, retour à la ligne, NUL, barre oblique inverse, ou les deux types de guillemets : non représentable sans ambiguïté).
    static func saveInvocation(user: String, service: String, value: String) -> (path: String, args: [String], stdin: Data)? {
        func quoted(_ s: String) -> String? {
            if s.isEmpty || s.contains("\n") || s.contains("\r") || s.contains("\u{0}") || s.contains("\\") { return nil }
            if !s.contains("\"") { return "\"" + s + "\"" }
            if !s.contains("'") { return "'" + s + "'" }
            return nil
        }
        guard let v = quoted(value), let a = quoted(user), let s = quoted(service) else { return nil }
        let line = "add-generic-password -U -a \(a) -s \(s) -w \(v)\n"
        return ("/bin/sh", ["-c", "exec /usr/bin/security -i 2>&1"], Data(line.utf8))
    }
    #if os(macOS)
    /// false UNIQUEMENT si le Trousseau répond « introuvable ». Lecture des attributs seuls (pas kSecReturnData) : les éléments créés
    /// par /usr/bin/security n'autorisent que cet outil à lire la donnée ; la lire ici déclencherait une boîte de dialogue.
    /// Tout autre statut (verrouillé, refus…) → true : on garde l'ancien chemin. Aucune écriture.
    static func exists(service: String, account: String?) -> Bool {
        var q: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
                                kSecAttrService as String: service,
                                kSecReturnAttributes as String: true,
                                kSecMatchLimit as String: kSecMatchLimitOne]
        if let a = account { q[kSecAttrAccount as String] = a }
        var out: CFTypeRef? = nil
        let st = SecItemCopyMatching(q as CFDictionary, &out)
        return st != errSecItemNotFound
    }
    #endif
    public func forget() { lock.lock(); cache.removeAll(); lock.unlock() }
    /// Réchauffe le cache en PARALLÈLE (chaque lecture lance /usr/bin/security : en série, le premier affichage de Nova prenait ~20 s).
    public func warm(_ refs: [KeyRef]) {
        guard !refs.isEmpty else { return }
        DispatchQueue.concurrentPerform(iterations: refs.count) { i in _ = self.value(refs[i]) }
    }
}

/// Pour les tests et le mode démo explicite : clés injectées.
public final class MemoryKeyStore: KeyStore {
    public var map: [String: String]
    public init(_ m: [String: String] = [:]) { map = m }
    public func value(_ ref: KeyRef) -> String? { map[ref.service] }
}

/// Registre des clés — version hackathon Meta : clé Meta Model API, Baseten et Hugging Face (Spark Open), services non-IA.
public enum KnownKeys {
    public static let spark = KeyRef(service: "sparklocal-meta-api-key", accounts: ["$USER"], envVars: ["MODEL_API_KEY", "META_API_KEY"])
    // Le jeton OAuth du CLI Meta (« ai.meta.dev.credentials ») n'est plus lu : il déclenchait une demande de mot de passe du Trousseau à chaque lancement.
    public static let sparkNova = KeyRef(service: "nova-spark", accounts: ["$USER"], envVars: [])
    // META-MUSE (26/10) : clé Meta Model API déposée sous le service Nova dédié « nova-meta »
    // (Réglages › Connexions) ; les variables MODEL_API_KEY / META_API_KEY restent lues via `spark`.
    public static let metaModelAPI = KeyRef(service: "nova-meta", accounts: ["$USER"], envVars: [])
    // 26/10 : Hugging Face Inference Providers (Muse Spark Open 816B) — jeton déposé par Ahadi au Trousseau, jamais en clair.
    public static let hf = KeyRef(service: "huggingface-token", accounts: ["$USER"], envVars: ["HF_TOKEN"])
    public static let hfNova = KeyRef(service: "nova-huggingface", accounts: ["$USER"], envVars: [])
    // 28/10 : Baseten (hackathon Meta) — Muse Spark Open servi par Baseten, 100 $ hackathon. Clé déposée par Ahadi au Trousseau « nova-baseten » ou variable BASETEN_API_KEY ; jamais en clair dans le source.
    public static let basetenNova = KeyRef(service: "nova-baseten", accounts: ["$USER"], envVars: ["BASETEN_API_KEY"])
    public static let braveNova = KeyRef(service: "nova-brave", accounts: ["$USER"], envVars: ["BRAVE_API_KEY"])   // NOVA2-FIX 20/10 : backend de recherche Brave (web_search), repli DuckDuckGo si absent
    public static let tavilyNova = KeyRef(service: "nova-tavily", accounts: ["$USER"], envVars: ["TAVILY_API_KEY"])   // NOVA2-FIX 21/10 : backend de recherche Tavily (web_search), en tête de chaîne si la clé est au Trousseau
    // SENTRY (22/10) : DSN du projet Sentry « Nova » (région EU), lu par SentryBootstrap (cible NovaMac).
    // La VALEUR ne vit jamais dans le source : Trousseau « nova-sentry-dsn » ou variable SENTRY_DSN ; repli fichier : clé « sentry_dsn » de settings.json (magasin).
    public static let sentryDSN = KeyRef(service: "nova-sentry-dsn", accounts: ["$USER"], envVars: ["SENTRY_DSN"])
    // ALGOLIA (23/10) : recherche d'index de la palette ⌘K — app_id et clé de RECHERCHE seulement.
    // La clé Admin n'existe pas côté app (l'amorçage de l'index se fait hors app, par le pilote).
    // Valeurs : Trousseau « nova-algolia-app » / « nova-algolia-search » ou variables d'environnement ;
    // repli fichier : algolia_config.json du magasin (route GET /api/search/algolia-config, Feat_Search.swift).
    public static let algoliaApp = KeyRef(service: "nova-algolia-app", accounts: ["$USER"], envVars: ["ALGOLIA_APP_ID"])
    public static let algoliaSearch = KeyRef(service: "nova-algolia-search", accounts: ["$USER"], envVars: ["ALGOLIA_SEARCH_KEY"])
    // AMPLITUDE (23/10, lot CRÉDITS) : clé API PROJET de l'émetteur analytics Amplitude.swift
    // (plan Growth). La VALEUR ne vit jamais dans le source :
    // Trousseau « nova-amplitude-api » ou variable AMPLITUDE_API_KEY ; repli fichier : clé
    // « api_key » de amplitude_config.json du magasin.
    public static let amplitudeAPI = KeyRef(service: "nova-amplitude-api", accounts: ["$USER"], envVars: ["AMPLITUDE_API_KEY"])
    // ZOHO MAIL (25/10, V5-S) : mot de passe d'APPLICATION Zoho de la boîte campagne, saisi par Ahadi lui-même
    // dans Réglages › Données & comptes (POST /api/zoho/connect → KeychainStore.save). Lu UNIQUEMENT au Trousseau :
    // aucune variable d'environnement, aucun fichier, aucun autre système. Jamais journalisé ni renvoyé à l'UI.
    public static let zoho = KeyRef(service: "nova-zoho-imap", accounts: ["$USER"], envVars: [])
}

/// Un « coffre » de plusieurs références : la première qui répond gagne.
public struct KeyChain {
    public let refs: [KeyRef]
    public let fallback: String?   // passerelle locale sans clé : valeur factice acceptée
    public init(_ r: [KeyRef], fallback: String? = nil) { refs = r; self.fallback = fallback }
    public func resolve(_ s: KeyStore) -> String? {
        for r in refs { if let v = s.value(r) { return v } }
        return fallback
    }
}

/// V4-D (24/10) — SÉCURITÉ DES CLÉS : migration UNIQUE et VÉRIFIÉE d'une clé laissée en clair dans un fichier
/// « *_config.json » du magasin vers le Trousseau macOS. Règle d'Ahadi : ne jamais perdre une clé.
///  1. le Trousseau contient déjà la même valeur → migrée (le fichier n'est plus lu) ;
///  2. sinon : écriture au Trousseau (KeychainStore.save), puis RELECTURE par une instance neuve (sans cache) ;
///     identique → migrée ; sinon (Trousseau verrouillé, refus, valeur différente) → repli sur la valeur du fichier,
///     rien n'est perdu, et l'échec est journalisé (sans la valeur) ;
///  3. le fichier n'est JAMAIS modifié ni supprimé ici : Ahadi l'efface lui-même après la migration (voir V4_D_FOND.md).
/// La valeur n'est ni journalisée, ni renvoyée à l'interface ; seul l'état (migrée / repli) est tracé.
public enum KeyMigration {
    static let lock: NSLock = NSLock()
    nonisolated(unsafe) static var verified: [String: String] = [:]   // service → valeur relue au Trousseau (même cache mémoire que KeychainStore)
    nonisolated(unsafe) static var failedAt: [String: Date] = [:]     // service → dernier échec (nouvel essai 10 min plus tard au plus tôt)

    /// Valeur de la clé : Trousseau après migration vérifiée, sinon repli fichier. nil si le fichier n'a pas de valeur.
    public static func fromPlainFile(file: String, field: String, service: String) -> String? {
        lock.lock()
        if let v = verified[service] { lock.unlock(); return v }
        let lastFail: Date? = failedAt[service]
        lock.unlock()
        let f: [String: Any] = JSONFile(file).read(default: [String: Any]())
        let plain: String = ((f[field] as? String) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        if plain.isEmpty { return nil }
        if let lf = lastFail, Date().timeIntervalSince(lf) < 600 { return plain }   // échec récent : repli fichier, sans relancer /usr/bin/security
        let ref: KeyRef = KeyRef(service: service, accounts: ["$USER"], envVars: [])
        let before: String = (KeychainStore().value(ref) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        if before == plain {
            lock.lock(); verified[service] = plain; lock.unlock()
            return plain
        }
        if !before.isEmpty {
            // Le Trousseau porte déjà une AUTRE valeur pour ce service : on ne l'écrase jamais. Le Trousseau fait foi.
            _ = BlackBox.record(["tool": "cles", "actor": "Nova", "why": "migration « " + file + " » → Trousseau « " + service + " » : le Trousseau a déjà une autre valeur — conservée, fichier ignoré (à effacer par Ahadi après vérification)", "ok": true, "effect": "lecture"])
            lock.lock(); verified[service] = before; lock.unlock()
            return before
        }
        let saved: Bool = KeychainStore.save(service: service, value: plain)
        let after: String = (KeychainStore().value(ref) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        if saved && after == plain {
            _ = BlackBox.record(["tool": "cles", "actor": "Nova", "why": "clé de « " + file + " » copiée au Trousseau « " + service + " » et relue identique — le fichier n'est plus lu ; Ahadi peut l'effacer", "ok": true, "effect": "écrit"])
            lock.lock(); verified[service] = plain; failedAt.removeValue(forKey: service); lock.unlock()
            return plain
        }
        _ = BlackBox.record(["tool": "cles", "actor": "Nova", "why": "migration « " + file + " » → Trousseau « " + service + " » NON prouvée (écriture " + (saved ? "faite" : "refusée") + ", relecture " + (after.isEmpty ? "vide" : "différente") + ") — repli sur le fichier, aucune clé perdue", "ok": false, "effect": "aucun"])
        lock.lock(); failedAt[service] = Date(); lock.unlock()
        return plain
    }

    /// État pour un diagnostic (jamais la valeur).
    public static func isVerified(_ service: String) -> Bool {
        lock.lock(); defer { lock.unlock() }
        return verified[service] != nil
    }
}
