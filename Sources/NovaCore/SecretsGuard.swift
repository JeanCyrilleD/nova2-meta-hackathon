import Foundation

// V5-V (25/10/2026) — GARDE DES SECRETS, UNIQUE ET PARTAGÉE.
//
// Politique d'Ahadi du 25/10 10:55 (verbatim) : « Nova will replace Muse on every single thing, so connect it too to all
// SCI work and all contents from the other AI in the Mac, the app settings and everything, and Nova should be aware that
// he knows and has full access — except passwords and sending, that are on me. »
//
// Conséquence : les anciens filtres de CONTENU qui écartaient SCI / Save the Children / probation / revue de confirmation
// hors du canal Fundings sont retirés (voir conseil_24-10/V5_V_ACCES.md). Il ne reste qu'une limite de contenu : les
// SECRETS. Cette garde est la seule à appeler pour ça, partout hors du canal Fundings (Fundings.forbidden reste réservé
// au tableau de bord de la campagne).
//
// - containsSecret(s) : vrai si le texte contient un mot de passe AVEC sa valeur, un code OTP / de vérification, une clé
//   d'API (sk-…, AKIA…, ghp_…, xox…, AIza…), un jeton (bearer, token=…, JWT), une clé privée, un IBAN valide (mod 97)
//   ou un numéro de carte valide (Luhn).
// - redact(s) : remplace ces passages par « [masqué] », puis applique Knowledge.redact (filet historique).
// - isCredentialPath(p) / isSensitiveRoot(p) : fichiers et dossiers d'identifiants à ne jamais lire ni indexer.
//
// La table `rules` + `ibanPattern` + `cardPattern` est relue TELLE QUELLE par tests/secrets_guard_test.py (pas de copie
// à la main) : toute modification ici est donc testée à l'identique. Garder une règle par ligne, au format
// SecretRule(name: "…", ci: true|false, pattern: #"…"#),

struct SecretRule {
    let name: String
    let ci: Bool
    let pattern: String
}

public enum SecretsGuard {

    // MARK: table des motifs (relue par le test Python — une règle par ligne)

    static let rules: [SecretRule] = [
        SecretRule(name: "password", ci: true, pattern: #"(?:mot\s+de\s+passe|password|passwd|pwd|\bmdp|passcode|passphrase)(?:\s*[:=]\s*["'«]?\S{4,}|\s+(?:est|is)\s*:?\s+["'«]?(?=\S*[\d!@#$%^&*_+=?])\S{4,})"#),
        SecretRule(name: "otp", ci: true, pattern: #"(?:code\s+(?:de\s+)?(?:v[ée]rification|s[ée]curit[ée]|confirmation|connexion|validation|acc[eè]s)|verification\s+code|security\s+code|confirmation\s+code|login\s+code|sign[-\s]?in\s+code|one[-\s]time\s+(?:code|password|passcode)|\botp\b|\b2fa\b)\D{0,30}\d{4,8}\b"#),
        SecretRule(name: "otp_reverse", ci: true, pattern: #"\b\d{4,8}\s+(?:is\s+your|est\s+votre|est\s+ton)\b"#),
        SecretRule(name: "sk_key", ci: false, pattern: #"\bsk-(?:ant-|proj-|or-v1-|live-|test-)?[A-Za-z0-9_-]{16,}"#),
        SecretRule(name: "aws_key", ci: false, pattern: #"\b(?:AKIA|ASIA)[0-9A-Z]{16}\b"#),
        SecretRule(name: "github_token", ci: false, pattern: #"\b(?:gh[pousr]_[A-Za-z0-9]{20,}|github_pat_[A-Za-z0-9_]{20,})"#),
        SecretRule(name: "slack_token", ci: false, pattern: #"\bxox[abposr]-[A-Za-z0-9-]{10,}"#),
        SecretRule(name: "google_key", ci: false, pattern: #"\bAIza[0-9A-Za-z_-]{30,}"#),
        SecretRule(name: "prefixed_token", ci: false, pattern: #"\b(?:glpat|xapp|pk_live|sk_live|rk_live|hf|npm|pypi)[-_][A-Za-z0-9_-]{16,}"#),
        SecretRule(name: "bearer", ci: true, pattern: #"\bbearer\s+[A-Za-z0-9._~+/=-]{16,}"#),
        SecretRule(name: "key_value", ci: true, pattern: #"\b(?:api[_-]?key|apikey|access[_-]?token|refresh[_-]?token|auth[_-]?token|client[_-]?secret|secret[_-]?key|token|secret)\s*["']?\s*[:=]\s*["']?[A-Za-z0-9._~+/=-]{8,}"#),
        SecretRule(name: "jwt", ci: false, pattern: #"\beyJ[A-Za-z0-9_-]{8,}\.[A-Za-z0-9_-]{8,}\.[A-Za-z0-9_-]{6,}"#),
        SecretRule(name: "private_key", ci: false, pattern: #"-----BEGIN (?:[A-Z0-9 ]+ )?PRIVATE KEY-----"#),
    ]
    /// Candidat IBAN (validé ensuite par la clé mod 97 — un code quelconque ne suffit pas).
    static let ibanPattern: String = #"\b[A-Z]{2}\d{2}(?:[ ]?[A-Z0-9]){11,30}\b"#
    /// Candidat numéro de carte (13 à 19 chiffres, espaces/tirets tolérés), validé ensuite par Luhn.
    static let cardPattern: String = #"\b\d(?:[ -]?\d){12,18}\b"#

    static let compiled: [NSRegularExpression] = rules.compactMap { (r: SecretRule) -> NSRegularExpression? in
        try? NSRegularExpression(pattern: r.pattern, options: r.ci ? [.caseInsensitive] : [])
    }
    static let ibanRx: NSRegularExpression = try! NSRegularExpression(pattern: ibanPattern, options: [])
    static let cardRx: NSRegularExpression = try! NSRegularExpression(pattern: cardPattern, options: [])

    // MARK: validateurs

    /// Luhn sur 13 à 19 chiffres ; une suite d'un seul chiffre répété n'est jamais une carte.
    static func luhnOK(_ raw: String) -> Bool {
        let digits: [Int] = raw.compactMap { (c: Character) -> Int? in c.isASCII ? c.wholeNumberValue : nil }
        guard digits.count >= 13 && digits.count <= 19, Set(digits).count > 1 else { return false }
        var sum: Int = 0
        for (i, d) in digits.reversed().enumerated() {
            var v: Int = d
            if i % 2 == 1 { v *= 2; if v > 9 { v -= 9 } }
            sum += v
        }
        return sum % 10 == 0
    }

    /// Clé IBAN (ISO 13616, mod 97 == 1). Le candidat peut avoir avalé un mot final en capitales : on essaie les
    /// longueurs de la plus longue (34) à la plus courte (15).
    static func ibanOK(_ raw: String) -> Bool {
        let compact: [Character] = Array(raw.replacingOccurrences(of: " ", with: "").uppercased())
        guard compact.count >= 15 else { return false }
        var n: Int = min(34, compact.count)
        while n >= 15 {
            if ibanMod97(Array(compact[0..<n])) { return true }
            n -= 1
        }
        return false
    }
    static func ibanMod97(_ s: [Character]) -> Bool {
        guard s.count >= 15 else { return false }
        let re: [Character] = Array(s[4...]) + Array(s[0..<4])
        var rem: Int = 0
        for c in re {
            if c.isASCII, let d = c.wholeNumberValue { rem = (rem * 10 + d) % 97 }
            else if let a = c.asciiValue, a >= 65, a <= 90 { rem = (rem * 100 + Int(a) - 55) % 97 }
            else { return false }
        }
        return rem == 1
    }

    // MARK: API

    /// Plages (NSRange) de tous les secrets trouvés, fusionnées et triées.
    static func secretRanges(_ s: String) -> [NSRange] {
        let ns: NSString = s as NSString
        let full: NSRange = NSRange(location: 0, length: ns.length)
        var ranges: [NSRange] = []
        for rx in compiled {
            for m in rx.matches(in: s, options: [], range: full) { ranges.append(m.range) }
        }
        for m in ibanRx.matches(in: s, options: [], range: full) where ibanOK(ns.substring(with: m.range)) { ranges.append(m.range) }
        for m in cardRx.matches(in: s, options: [], range: full) where luhnOK(ns.substring(with: m.range)) { ranges.append(m.range) }
        ranges.sort { (a: NSRange, b: NSRange) -> Bool in a.location < b.location }
        var merged: [NSRange] = []
        for r in ranges {
            if let last = merged.last, r.location <= last.location + last.length {
                let end: Int = max(last.location + last.length, r.location + r.length)
                merged[merged.count - 1] = NSRange(location: last.location, length: end - last.location)
            } else {
                merged.append(r)
            }
        }
        return merged
    }

    /// Vrai si le texte contient un secret (voir l'en-tête). Ne dit rien de SCI ni d'aucun sujet : seuls les secrets comptent.
    public static func containsSecret(_ s: String) -> Bool {
        if s.isEmpty { return false }
        let full: NSRange = NSRange(location: 0, length: (s as NSString).length)
        for rx in compiled where rx.firstMatch(in: s, options: [], range: full) != nil { return true }
        let ns: NSString = s as NSString
        for m in ibanRx.matches(in: s, options: [], range: full) where ibanOK(ns.substring(with: m.range)) { return true }
        for m in cardRx.matches(in: s, options: [], range: full) where luhnOK(ns.substring(with: m.range)) { return true }
        return false
    }

    /// Masque chaque secret par « [masqué] », puis passe Knowledge.redact (filet historique : jetons longs, IBAN bruts).
    public static func redact(_ s: String) -> String {
        if s.isEmpty { return s }
        let ranges: [NSRange] = secretRanges(s)
        let ns: NSString = s as NSString
        var out: String = ""
        var cursor: Int = 0
        for r in ranges {
            if r.location > cursor { out += ns.substring(with: NSRange(location: cursor, length: r.location - cursor)) }
            out += "[masqué]"
            cursor = r.location + r.length
        }
        if cursor < ns.length { out += ns.substring(from: cursor) }
        return Knowledge.redact(out)
    }

    /// Toutes les règles ont compilé sous ICU (exposé par GET /api/sources → « secrets_guard »).
    public static var compiledOK: Bool { compiled.count == rules.count }

    /// Lignes « clé = valeur » de préférences (defaults read, réglages) dont la CLÉ désigne un secret : valeur masquée.
    public static func redactKeyedLines(_ s: String) -> String {
        let marks: [String] = ["password", "passwd", "motdepasse", "token", "secret", "apikey", "api_key", "api-key", "cookie", "credential", "session", "bearer", "private"]
        var out: [String] = []
        for line in s.components(separatedBy: "\n") {
            let low: String = line.lowercased()
            if marks.contains(where: { (m: String) -> Bool in low.contains(m) }), let eq = line.firstIndex(where: { (c: Character) -> Bool in c == "=" || c == ":" }) {
                out.append(String(line[...eq]) + " [masqué]")
            } else {
                out.append(line)
            }
        }
        return redact(out.joined(separator: "\n"))
    }

    // MARK: fichiers et dossiers d'identifiants

    static let credentialDirs: [String] = ["/.ssh/", "/.gnupg/", "/.aws/", "/library/keychains/", "/library/cookies/", "/.config/gh/", "/.config/gcloud/",
                                           "/.codex/", "/nova-finances", "/.bionic-tools", "/.secrets/", "/.password-store/", "/1password", "/bitwarden"]
    static let credentialNames: Set<String> = [".env", ".netrc", ".npmrc", ".pypirc", ".pgpass", "credentials", "credentials.json", "token.json", "tokens.json",
                                                "client_secret.json", "login data", "login data-journal", "cookies", "cookies.binarycookies", "web data",
                                                "local state", "keychain-2.db", "known_hosts", "authorized_keys"]
    static let credentialSuffixes: [String] = [".pem", ".key", ".p12", ".pfx", ".keychain", ".keychain-db", ".kdbx", ".ppk", ".gpg", ".asc", ".binarycookies", ".jks", ".keystore"]
    static let credentialWords: [String] = ["password", "passwd", "motdepasse", "mot de passe", "mot_de_passe", "mot-de-passe", "secret", "credential", "token",
                                            "cookie", "keychain", "login data", "backup codes", "backup-codes", "recovery code", "recovery-code", "codes de secours"]

    /// Fichier d'identifiants évident (.env, *.pem, id_rsa*, trousseaux, *password*, cookies, Login Data…) : jamais lu ni indexé.
    public static func isCredentialPath(_ path: String) -> Bool {
        let low: String = path.lowercased()
        if credentialDirs.contains(where: { (d: String) -> Bool in low.contains(d) }) { return true }
        let name: String = (low as NSString).lastPathComponent
        if credentialNames.contains(name) || name.hasPrefix(".env.") || name.hasPrefix("id_rsa") || name.hasPrefix("id_dsa") || name.hasPrefix("id_ecdsa") || name.hasPrefix("id_ed25519") { return true }
        if credentialSuffixes.contains(where: { (x: String) -> Bool in name.hasSuffix(x) }) { return true }
        return credentialWords.contains(where: { (w: String) -> Bool in name.contains(w) })
    }

    static let novaDataLower: String = Paths.home.path.lowercased() + "/"

    /// Dossier qu'on ne déclare jamais comme source (identifiants, trousseaux, données propres de Nova).
    public static func isSensitiveRoot(_ path: String) -> Bool {
        let low: String = path.lowercased() + "/"
        if credentialDirs.contains(where: { (d: String) -> Bool in low.contains(d) }) { return true }
        let novaData: String = novaDataLower
        if low.hasPrefix(novaData) { return true }   // le dossier de données de Nova lui-même
        if novaData.hasPrefix(low) && low.contains("/library/") { return true }   // un parent qui l'englobe sous ~/Library (~/Library, ~/Library/Application Support)
        return false
    }
}
