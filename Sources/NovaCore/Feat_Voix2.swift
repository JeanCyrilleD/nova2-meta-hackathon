import Foundation
#if os(macOS)
import ApplicationServices
#endif
#if canImport(Speech) && canImport(AVFoundation) && os(macOS)
import Speech
import AVFoundation
#endif
#if canImport(NaturalLanguage)
import NaturalLanguage
#endif

// VAGUE 2 (24/10/2026) — VOIX FIABLE : dictée, vocabulaire, live sans silence.
//
// Constat (« la reconnaissance n'est toujours pas bonne ») :
//  - la dictée du champ (web) enregistrait un bloc MediaRecorder sans aucun texte partiel,
//    puis l'envoyait à une chaîne cloud SANS vocabulaire :
//    CAFU, OCHA, 3W, Sonatel, Ouédraogo… sortaient déformés ;
//  - la reconnaissance Apple (⌃⌥D, repli live) n'avait aucun contextualStrings ;
// Ce lot : vocabulaire personnel calculé (engagements, corps de mails/Teams, mémoire, Éclats,
// termes métier, villes du Sahel) + ajouts manuels ; dictée native Apple en flux pour le web
// (texte partiel sur le bus « voix_dictee ») ; post-correction (distance d'édition faible,
// noms propres, montants FCFA) ; réglages et diagnostic honnêtes.
// Le texte dicté n'est ni journalisé ni stocké (comptes de caractères seulement).

// MARK: - Réglages (voix_reglages.json)

public enum VoixReglages {
    static let file: JSONFile = JSONFile("voix_reglages.json")
    static let langues: [String] = ["fr-FR", "fr-CA", "en-US", "auto"]
    static let defaults: [String: Any] = ["moteur": "apple", "langue": "fr-FR", "pause_ms": 1400,
                                          "phrases_attente": false, "sur_appareil": false]   // 25/10 : phrases d'attente coupées par défaut

    public static func all() -> [String: Any] {
        var d: [String: Any] = defaults
        let cur: [String: Any] = file.read(default: [String: Any]())
        for (k, v) in cur { d[k] = v }
        if cur["pa_v2"] == nil { d["phrases_attente"] = false }
        if cur["sa_v2"] == nil { d["sur_appareil"] = false }   // 26/10 : reconnaissance serveur d'Apple par défaut (plus juste sur l'accent burkinabè) ; sur l'appareil reste au choix   // 25/10 : un ancien « true » n'est plus suivi tant qu'Ahadi ne le réactive pas
        return d
    }
    /// « apple » : reconnaissance vocale système du Mac, en flux (version Meta : seul moteur de dictée en flux ;
    /// la transcription d'un enregistrement passe par Muse Voice Transcribe, Meta).
    public static func moteur() -> String { "apple" }
    /// fr-FR · fr-CA · en-US · auto (fr-FR + en-US en parallèle, choix à la fin).
    public static func langue() -> String {
        let l: String = (all()["langue"] as? String) ?? "fr-FR"
        return langues.contains(l) ? l : "fr-FR"
    }
    /// Locale unique pour les chemins qui ne savent pas faire « auto » (⌃⌥D, live).
    public static func localePrincipale() -> String {
        let l: String = langue()
        return l == "auto" ? "fr-FR" : l
    }
    /// Code langue des moteurs cloud : « fra » (historique), « en », ou « auto ».
    public static func codeCloud() -> String {
        let l: String = langue()
        if l == "auto" { return "auto" }
        if l.hasPrefix("en") { return "en" }
        return "fra"
    }
    /// Pause tolérée avant de clore une phrase (800–3000 ms, défaut 1400).
    public static func pauseMs() -> Int {
        let v: Any? = all()["pause_ms"]
        var n: Int = 1400
        if let i = v as? Int { n = i } else if let d = v as? Double { n = Int(d) }
        return max(800, min(3000, n))
    }
    public static func phrasesAttente() -> Bool { (all()["phrases_attente"] as? Bool) ?? false }   // 25/10 : coupées par défaut (« ça ressemble à du pré-enregistré »)
    /// Version Meta : reconnaissance SUR L'APPAREIL exigée dès que la langue la prend en charge (aucun envoi aux serveurs de reconnaissance).
    public static func surAppareil() -> Bool { true }

    /// Applique un patch validé. Retourne l'erreur éventuelle (nil = accepté).
    static func apply(_ body: [String: Any]) -> String? {
        var cur: [String: Any] = file.read(default: [String: Any]())
        if let m = body["moteur"] as? String {
            guard m == "apple" else { return "moteur inconnu : « " + m + " » (apple seulement)" }
            cur["moteur"] = m
        }
        if let l = body["langue"] as? String {
            guard langues.contains(l) else { return "langue inconnue : « " + l + " » (fr-FR, fr-CA, en-US ou auto)" }
            cur["langue"] = l
        }
        if let raw = body["pause_ms"] {
            var n: Int = -1
            if let i = raw as? Int { n = i } else if let d = raw as? Double { n = Int(d) }
            guard n >= 800 && n <= 3000 else { return "pause_ms hors bornes (800 à 3000)" }
            cur["pause_ms"] = n
        }
        if let b = body["phrases_attente"] as? Bool { cur["phrases_attente"] = b; cur["pa_v2"] = true }
        if let b = body["sur_appareil"] as? Bool { cur["sur_appareil"] = b; cur["sa_v2"] = true }
        file.write(cur)
        return nil
    }
}

// MARK: - Vocabulaire personnel

public enum VoixVocab {
    static let file: JSONFile = JSONFile("voix_vocabulaire.json")   // {ajouts:[String], retraits:[String]}
    static let lock: NSLock = NSLock()
    static var cacheAt: Date = Date.distantPast
    static var cacheList: [[String: String]] = []
    /// Posée par voix2Routes (la mémoire durable de l'app) ; nil = pas de termes tirés de la mémoire.
    static var memory: Memory? = nil
    public static let limite: Int = 100

    static let metier: [String] = [
        "CAFU", "OCHA", "HRP", "3W", "IPC", "Sahel", "Save the Children", "UNICEF", "PAM", "HCR",
        "ReliefWeb", "Cadre Harmonisé", "BRVM", "SBIF", "Sonatel", "FCFA", "UEMOA",
        "CEDEAO", "Nova", "Ahadi", "Dahani"]
    static let villes: [String] = [
        "Ouagadougou", "Ouaga", "Bobo-Dioulasso", "Koudougou", "Ouahigouya", "Kaya", "Fada N'Gourma",
        "Dori", "Djibo", "Tenkodogo", "Banfora", "Dédougou", "Gaoua", "Ziniaré", "Kongoussi", "Gorom-Gorom",
        "Arbinda", "Titao", "Diapaga", "Sebba", "Liptako-Gourma", "Niamey", "Tillabéri", "Diffa", "Agadez",
        "Bamako", "Mopti", "Tombouctou", "Gao", "Ménaka", "Nouakchott", "Abidjan", "Dakar", "Lomé", "Cotonou"]
    static let bourse: [String] = [
        "Orange Côte d'Ivoire", "SGBCI", "Ecobank", "Coris Bank", "Oragroup", "NSIA Banque", "Société Ivoirienne de Banque",
        "Solibra", "Palm CI", "SAPH", "Total Sénégal", "Bank of Africa"]
    static let noms: [String] = [
        "Ouédraogo", "Sawadogo", "Kaboré", "Compaoré", "Traoré", "Ouattara", "Zongo", "Zoungrana", "Yaméogo",
        "Ilboudo", "Nikiéma", "Tapsoba", "Kiemdé", "Konaté", "Diallo", "Coulibaly", "Sanou", "Somé"]
    static let stopContacts: [String] = ["moi", "eux", "equipe", "tous", "toi", "nous", "vous", "inconnu", "personne", "ahadi"]
    static let stopMemoire: Set<String> = ["le", "la", "les", "un", "une", "des", "il", "elle", "ils", "elles", "je", "tu", "nous", "vous",
        "ce", "cette", "ces", "son", "sa", "ses", "mon", "ma", "mes", "en", "au", "aux", "du", "de", "et", "ou", "si", "on", "a", "pour",
        "par", "avec", "sans", "dans", "sur", "lundi", "mardi", "mercredi", "jeudi", "vendredi", "samedi", "dimanche", "janvier", "fevrier",
        "mars", "avril", "mai", "juin", "juillet", "aout", "septembre", "octobre", "novembre", "decembre", "decision", "note", "rappel",
        "pas", "ne", "plus", "tres", "aussi", "toujours", "jamais", "quand", "apres", "avant", "chaque", "tout", "toute", "ok", "oui", "non"]

    static func fold(_ s: String) -> String {
        return s.lowercased().folding(options: .diacriticInsensitive, locale: Locale(identifier: "fr_FR"))
    }
    /// Clé de dédoublonnage : repliée, alphanumérique seulement.
    static func key(_ s: String) -> String {
        let parts: [String] = fold(s).components(separatedBy: CharacterSet.alphanumerics.inverted).filter { (p: String) -> Bool in !p.isEmpty }
        return parts.joined(separator: " ")
    }

    static func manual() -> (ajouts: [String], retraits: [String]) {
        let d: [String: Any] = file.read(default: [String: Any]())
        let a: [String] = (d["ajouts"] as? [String]) ?? []
        let r: [String] = (d["retraits"] as? [String]) ?? []
        return (a, r)
    }

    /// Nom de contact plausible (pas une adresse, pas un service automatique).
    static func cleanContact(_ raw: String) -> String? {
        var s: String = Engagements.personDisplay(raw)
        if s.isEmpty || s.contains("@") || s.count < 3 || s.count > 40 { return nil }
        let low: String = fold(s)
        let bad: [String] = ["noreply", "no reply", "no-reply", "notification", "microsoft", "teams", "outlook", "mailer", "support", "info", "newsletter", "admin", "service"]
        for b in bad where low.contains(b) { return nil }
        if stopContacts.contains(key(s)) { return nil }
        let words: [Substring] = s.split(separator: " ")
        if words.isEmpty || words.count > 4 { return nil }
        if s == s.lowercased() { s = s.capitalized }
        guard let f: Character = s.first, f.isLetter else { return nil }
        return s
    }

    /// Termes calculés [{terme, source}] — cache 60 s.
    public static func calcule() -> [[String: String]] {
        lock.lock()
        if Date().timeIntervalSince(cacheAt) < 60 && !cacheList.isEmpty { let c: [[String: String]] = cacheList; lock.unlock(); return c }
        lock.unlock()
        var out: [[String: String]] = []
        var seen: Set<String> = []
        func add(_ t: String, _ src: String) {
            let term: String = t.trimmingCharacters(in: .whitespacesAndNewlines)
            let k: String = key(term)
            if term.isEmpty || term.count > 50 || k.isEmpty || seen.contains(k) { return }
            seen.insert(k)
            out.append(["terme": term, "source": src])
        }
        // 1) Contacts : engagements (qui) puis expéditeurs des corps lus (mails/Teams), par fréquence.
        var freq: [String: Int] = [:]
        var display: [String: String] = [:]
        let co: [String: Any] = JSONFile("commitments.json").read(default: [String: Any]())
        for it in (co["items"] as? [[String: Any]]) ?? [] {
            if let q = it["qui"] as? String, let c = cleanContact(q) { let k: String = key(c); freq[k, default: 0] += 3; if display[k] == nil { display[k] = c } }
        }
        let bodies: [String: Any] = JSONFile("webmail_bodies.json").read(default: [String: Any]())
        for k0 in bodies.keys {
            let first: String = k0.split(separator: "│", omittingEmptySubsequences: false).first.map { (x: Substring) -> String in String(x) } ?? ""
            if let c = cleanContact(first) { let k: String = key(c); freq[k, default: 0] += 1; if display[k] == nil { display[k] = c } }
        }
        let topContacts: [String] = freq.sorted { (a: (key: String, value: Int), b: (key: String, value: Int)) -> Bool in a.value > b.value }.prefix(35).compactMap { (e: (key: String, value: Int)) -> String? in display[e.key] }
        for c in topContacts { add(c, "contact") }
        // 2) Termes métier, villes, bourse, patronymes courants.
        for t in metier { add(t, "métier") }
        for t in villes { add(t, "ville") }
        for t in noms { add(t, "patronyme") }
        for t in bourse { add(t, "BRVM") }
        // 3) Noms des Éclats.
        let dl: [[String: Any]] = JSONFile("dots.json").read(default: [[String: Any]]())
        for d in dl.prefix(40) { if let n = d["name"] as? String, n.count <= 40 { add(n, "Éclat") } }
        // 4) Noms propres récurrents de la mémoire (≥ 2 occurrences).
        if let m = memory {
            var mf: [String: Int] = [:]
            var md: [String: String] = [:]
            let rx: NSRegularExpression? = try? NSRegularExpression(pattern: "\\b(\\p{Lu}\\p{Ll}+(?:[ -]\\p{Lu}\\p{Ll}+){0,2}|\\p{Lu}[\\p{Lu}0-9]{1,5})\\b", options: [])
            for it in m.list().suffix(400) {
                if (it["forgiven"] as? Bool) == true { continue }
                let txt: String = (it["text"] as? String) ?? ""
                guard let r = rx, !txt.isEmpty else { continue }
                let ns: NSString = txt as NSString
                for mt in r.matches(in: txt, options: [], range: NSRange(location: 0, length: ns.length)) {
                    // Début de phrase ignoré : une majuscule de phrase n'est pas un nom propre.
                    if mt.range.location == 0 { continue }
                    let before: String = ns.substring(with: NSRange(location: max(0, mt.range.location - 2), length: min(2, mt.range.location)))
                    if before.rangeOfCharacter(from: CharacterSet(charactersIn: ".!?:;\n•-—«\"")) != nil { continue }
                    let w: String = ns.substring(with: mt.range)
                    let k: String = key(w)
                    if k.count < 3 || stopMemoire.contains(k) { continue }
                    mf[k, default: 0] += 1
                    if md[k] == nil { md[k] = w }
                }
            }
            let top: [String] = mf.filter { (e: (key: String, value: Int)) -> Bool in e.value >= 2 }.sorted { (a: (key: String, value: Int), b: (key: String, value: Int)) -> Bool in a.value > b.value }.prefix(30).compactMap { (e: (key: String, value: Int)) -> String? in md[e.key] }
            for t in top { add(t, "mémoire") }
        }
        lock.lock(); cacheList = out; cacheAt = Date(); lock.unlock()
        return out
    }

    static func invalidate() { lock.lock(); cacheAt = Date.distantPast; lock.unlock() }

    /// Liste effective (ajouts manuels d'abord, retraits ôtés), bornée à `limite` termes de ≤ 50 caractères.
    public static func effectif(max: Int = VoixVocab.limite) -> [String] {
        let man = manual()
        let retraits: Set<String> = Set(man.retraits.map { (t: String) -> String in key(t) })
        var out: [String] = []
        var seen: Set<String> = []
        for t in man.ajouts + calcule().map({ (e: [String: String]) -> String in e["terme"] ?? "" }) {
            let k: String = key(t)
            if k.isEmpty || t.count > 50 || seen.contains(k) || retraits.contains(k) { continue }
            seen.insert(k)
            out.append(t)
            if out.count >= max { break }
        }
        return out
    }

    /// POST /api/voix/vocabulaire : {ajout} ou {retrait}. nil = accepté.
    static func modify(ajout: String?, retrait: String?) -> String? {
        var d: [String: Any] = file.read(default: [String: Any]())
        var a: [String] = (d["ajouts"] as? [String]) ?? []
        var r: [String] = (d["retraits"] as? [String]) ?? []
        if let raw = ajout {
            let t: String = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            guard t.count >= 2 && t.count <= 50 else { return "terme vide ou trop long (2 à 50 caractères)" }
            let k: String = key(t)
            guard !k.isEmpty else { return "terme sans lettre ni chiffre" }
            r.removeAll { (x: String) -> Bool in key(x) == k }
            if !a.contains(where: { (x: String) -> Bool in key(x) == k }) { a.insert(t, at: 0) }
            if a.count > 200 { a = Array(a.prefix(200)) }
        } else if let raw = retrait {
            let t: String = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            let k: String = key(t)
            guard !k.isEmpty else { return "terme à retirer vide" }
            if a.contains(where: { (x: String) -> Bool in key(x) == k }) {
                a.removeAll { (x: String) -> Bool in key(x) == k }
            } else if !r.contains(where: { (x: String) -> Bool in key(x) == k }) {
                r.append(t)
            }
        } else {
            return "corps attendu : {\"ajout\": \"…\"} ou {\"retrait\": \"…\"}"
        }
        d["ajouts"] = a
        d["retraits"] = r
        file.write(d)
        invalidate()
        return nil
    }
}

// MARK: - Post-traitement : vocabulaire (distance d'édition faible), noms propres, montants FCFA

public enum VoixPost {
    struct Entry {
        let canon: String
        let keyTokens: [String]
        let joined: [Unicode.Scalar]
        let fuzzy: Bool
        let accented: Bool
        let acronym: Bool
    }
    struct Tok {
        var word: String
        var sep: String
    }
    /// Formes souvent entendues → forme juste (correspondance exacte sur la forme repliée).
    static let alias: [(String, String)] = [
        ("cafou", "CAFU"), ("kafou", "CAFU"), ("ca fou", "CAFU"), ("caf u", "CAFU"), ("ka fou", "CAFU"),
        ("o c h a", "OCHA"), ("oh cha", "OCHA"), ("trois w", "3W"), ("3 w", "3W"), ("trois double v", "3W"),
        ("3 double v", "3W"), ("trois doubles v", "3W"), ("i p c", "IPC"), ("h r p", "HRP"), ("b r v m", "BRVM"),
        ("s b i f", "SBIF"), ("sona tel", "Sonatel"), ("save de children", "Save the Children"),
        ("sauve the children", "Save the Children"), ("bobo dioulasso", "Bobo-Dioulasso"), ("fada ngourma", "Fada N'Gourma"),
        ("fada n gourma", "Fada N'Gourma"), ("l ocha", "l'OCHA")]
    /// Mots courants jamais « corrigés » en nom propre par simple changement de casse.
    static let communs: Set<String> = ["pierre", "rose", "claire", "olive", "blanche", "marine", "prix", "bon", "fort", "grand", "petit",
        "bien", "mars", "mai", "juin", "aout", "nova", "gao", "dori", "kaya", "cluster", "ong", "pam"]

    static let cacheLock: NSLock = NSLock()
    static var cacheKey: String = ""
    static var cacheEntries: [Entry] = []

    static func scalars(_ s: String) -> [Unicode.Scalar] { Array(s.unicodeScalars) }

    static func tokensOf(_ s: String) -> [String] {
        return VoixVocab.fold(s).components(separatedBy: CharacterSet.alphanumerics.inverted).filter { (p: String) -> Bool in !p.isEmpty }
    }

    static func entries(_ vocab: [String]) -> [Entry] {
        let ck: String = vocab.joined(separator: "\u{1}")
        cacheLock.lock()
        if ck == cacheKey && !cacheEntries.isEmpty { let e: [Entry] = cacheEntries; cacheLock.unlock(); return e }
        cacheLock.unlock()
        var out: [Entry] = []
        for t in vocab {
            let kt: [String] = tokensOf(t)
            if kt.isEmpty { continue }
            let j: String = kt.joined()
            let acr: Bool = t.count <= 6 && t == t.uppercased() && t.rangeOfCharacter(from: CharacterSet.letters) != nil
            let acc: Bool = VoixVocab.fold(t) != t.lowercased()
            out.append(Entry(canon: t, keyTokens: kt, joined: scalars(j), fuzzy: j.count >= 7, accented: acc, acronym: acr))
        }
        for (a, c) in alias {
            let kt: [String] = tokensOf(a)
            if kt.isEmpty { continue }
            out.append(Entry(canon: c, keyTokens: kt, joined: scalars(kt.joined()), fuzzy: false, accented: true, acronym: false))
        }
        cacheLock.lock(); cacheKey = ck; cacheEntries = out; cacheLock.unlock()
        return out
    }

    static func lev(_ a: [Unicode.Scalar], _ b: [Unicode.Scalar], limit: Int) -> Int {
        if abs(a.count - b.count) > limit { return limit + 1 }
        if a.isEmpty { return b.count }
        if b.isEmpty { return a.count }
        var prev: [Int] = Array(0...b.count)
        var cur: [Int] = Array(repeating: 0, count: b.count + 1)
        for i in 1...a.count {
            cur[0] = i
            var rowMin: Int = cur[0]
            for j in 1...b.count {
                let cost: Int = (a[i - 1] == b[j - 1]) ? 0 : 1
                cur[j] = min(min(prev[j] + 1, cur[j - 1] + 1), prev[j - 1] + cost)
                if cur[j] < rowMin { rowMin = cur[j] }
            }
            if rowMin > limit { return limit + 1 }
            swap(&prev, &cur)
        }
        return prev[b.count]
    }

    /// Découpe en mots alphanumériques + séparateurs (le texte se recompose à l'identique).
    static func split(_ text: String) -> (lead: String, toks: [Tok]) {
        var lead: String = ""
        var toks: [Tok] = []
        var word: String = ""
        var sep: String = ""
        for ch in text {
            let isW: Bool = ch.isLetter || ch.isNumber
            if isW {
                if !word.isEmpty && !sep.isEmpty { toks.append(Tok(word: word, sep: sep)); word = ""; sep = "" }
                else if word.isEmpty && !sep.isEmpty { lead += sep; sep = "" }
                word.append(ch)
            } else {
                if word.isEmpty && toks.isEmpty { lead.append(ch) } else { sep.append(ch) }
            }
        }
        if !word.isEmpty { toks.append(Tok(word: word, sep: sep)) }
        else if !sep.isEmpty, var last = toks.popLast() { last.sep += sep; toks.append(last) }
        return (lead, toks)
    }

    /// Correction complète d'un texte dicté. Ne change jamais le sens : uniquement les termes
    /// du vocabulaire (forme proche), la casse des noms propres connus et la lisibilité des montants.
    public static func corriger(_ text: String, vocab: [String]? = nil, majusculeInitiale: Bool = true) -> String {
        let t0: String = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if t0.isEmpty || t0.count > 8000 { return t0 }
        let ents: [Entry] = entries(vocab ?? VoixVocab.effectif())
        var parts = split(t0)
        var toks: [Tok] = parts.toks
        let folded: [String] = toks.map { (x: Tok) -> String in VoixVocab.fold(x.word) }
        var out: [Tok] = []
        var i: Int = 0
        while i < toks.count {
            var done: Bool = false
            var n: Int = min(4, toks.count - i)
            while n >= 1 && !done {
                let win: [String] = Array(folded[i..<(i + n)])
                let wj: [Unicode.Scalar] = scalars(win.joined())
                let original: String = (i..<(i + n)).map { (k: Int) -> String in k == i + n - 1 ? toks[k].word : toks[k].word + toks[k].sep }.joined()
                for e in ents {
                    var hit: Bool = false
                    if e.keyTokens.count == n && e.keyTokens == win {
                        if original == e.canon { hit = false }
                        else if n > 1 || e.accented || e.acronym { hit = true }
                        else if original.lowercased() == e.canon.lowercased() && !communs.contains(win[0]) { hit = true }
                    } else if n >= e.keyTokens.count && n <= e.keyTokens.count + 2 && e.joined == wj && (n > 1 || e.acronym) {
                        hit = true   // « O C H A », « Sona tel » : lettres ou morceaux recollés
                    } else if e.fuzzy && n == e.keyTokens.count && wj.count >= 7 && wj.first == e.joined.first {
                        let lim: Int = e.joined.count >= 10 ? 2 : 1
                        if n == 1 && communs.contains(win[0]) { hit = false }
                        else if lev(wj, e.joined, limit: lim) <= lim { hit = original != e.canon }
                    }
                    if hit {
                        out.append(Tok(word: e.canon, sep: toks[i + n - 1].sep))
                        i += n
                        done = true
                        break
                    }
                }
                n -= 1
            }
            if !done { out.append(toks[i]); i += 1 }
        }
        toks = out
        parts.toks = toks
        var s: String = parts.lead + toks.map { (x: Tok) -> String in x.word + x.sep }.joined()
        s = montants(s)
        while s.contains("  ") { s = s.replacingOccurrences(of: "  ", with: " ") }
        if majusculeInitiale, let f: Character = s.first, f.isLowercase { s = String(f).uppercased() + String(s.dropFirst()) }
        return s
    }

    /// « francs CFA » → FCFA ; « 1500000 FCFA » → « 1 500 000 FCFA » (espace fine insécable).
    static func montants(_ text: String) -> String {
        var s: String = text
        s = s.replacingOccurrences(of: "\\bfrancs?\\s+c\\.?\\s?f\\.?\\s?a\\b\\.?", with: "FCFA", options: [.regularExpression, .caseInsensitive])
        s = s.replacingOccurrences(of: "\\bF\\s?CFA\\b", with: "FCFA", options: [.regularExpression, .caseInsensitive])
        guard let rx: NSRegularExpression = try? NSRegularExpression(pattern: "(?<![\\d,.])(\\d{4,})(?=\\s*(?:de\\s+|d['’]\\s*)?(?:FCFA|XOF|F\\b|francs?\\b|euros?\\b|€|dollars?\\b|\\$|USD\\b))", options: [.caseInsensitive]) else { return s }
        let ns: NSString = s as NSString
        let ms: [NSTextCheckingResult] = rx.matches(in: s, options: [], range: NSRange(location: 0, length: ns.length))
        var result: String = s
        for m in ms.reversed() {
            let digits: String = ns.substring(with: m.range(at: 1))
            var grouped: String = ""
            var c: Int = 0
            for ch in digits.reversed() {
                if c > 0 && c % 3 == 0 { grouped = "\u{202F}" + grouped }
                grouped = String(ch) + grouped
                c += 1
            }
            if let r: Range<String.Index> = Range(m.range(at: 1), in: result) { result.replaceSubrange(r, with: grouped) }
        }
        return result
    }
}

// MARK: - Dictée native pour le web (champ de saisie) — texte partiel en flux

#if canImport(Speech) && canImport(AVFoundation) && os(macOS)
final class VxTaskCtx {
    let gen: Int
    let req: SFSpeechAudioBufferRecognitionRequest
    var task: SFSpeechRecognitionTask? = nil
    var slot: Int = -1        // ≥ 0 : segment en clôture, son final remplace committed[slot]
    var done: Bool = false
    init(gen: Int, req: SFSpeechAudioBufferRecognitionRequest) { self.gen = gen; self.req = req }
}

final class VxLane {
    let locale: String
    let rec: SFSpeechRecognizer
    var committed: [String] = []
    var confs: [Float] = []
    var current: String = ""
    var lastPartialAt: Date = Date.distantPast
    var active: VxTaskCtx? = nil
    var closing: [VxTaskCtx] = []
    var failStreak: Int = 0
    init(locale: String, rec: SFSpeechRecognizer) { self.locale = locale; self.rec = rec }
    func text() -> String {
        var all: [String] = committed
        if !current.isEmpty { all.append(current) }
        return all.map { (x: String) -> String in x.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { (x: String) -> Bool in !x.isEmpty }.joined(separator: " ")
    }
    func avgConf() -> Float {
        let v: [Float] = confs.filter { (c: Float) -> Bool in c > 0 }
        if v.isEmpty { return -1 }
        return v.reduce(0, +) / Float(v.count)
    }
}
#endif

public final class VoixDictee {
    public static let shared: VoixDictee = VoixDictee()
    let q: DispatchQueue = DispatchQueue(label: "nova.voix2.dictee", qos: .userInitiated)
    let bufLock: NSLock = NSLock()
    let snapLock: NSLock = NSLock()
    var publish: ((String, [String: Any]) -> Void)? = nil
    let journal: Journal = Journal("voix_journal.jsonl")
    var running: Bool = false
    var lastError: String = ""
    var lastEngine: String = ""
    var lastLangue: String = ""
    var lastAt: String = ""
    var startedAt: Date? = nil
    var sessionGen: Int = 0
    var taskGen: Int = 0
    var wakeWasRunning: Bool = false
    var contextual: [String] = []
    var lastResult: [String: Any]? = nil
    var lastResultAt: Date = Date.distantPast
    var lastPartialPub: Date = Date.distantPast
    var lastLevelPub: Date = Date.distantPast
    #if canImport(Speech) && canImport(AVFoundation) && os(macOS)
    var engine: AVAudioEngine? = nil
    var lanes: [VxLane] = []
    var activeReqs: [SFSpeechAudioBufferRecognitionRequest] = []
    var timer: DispatchSourceTimer? = nil
    #endif

    func snapshot() -> [String: Any] {
        snapLock.lock(); defer { snapLock.unlock() }
        return ["en_cours": running, "derniere_erreur": lastError, "dernier_moteur": lastEngine,
                "derniere_langue": lastLangue, "derniere_dictee": lastAt]
    }
    func setError(_ e: String) { snapLock.lock(); lastError = e; snapLock.unlock() }

    /// Démarre la dictée native. done(ok, erreur nommée, infos).
    public func start(done: @escaping (Bool, String, [String: Any]) -> Void) {
        #if canImport(Speech) && canImport(AVFoundation) && os(macOS)
        q.async {
            if self.running { done(true, "", ["deja": true]); return }
            if Dictee.shared.running { done(false, "la dictée système (⌃⌥D) est en cours — termine-la d'abord", [:]); return }
            if VoiceLiveEngine.shared.stateName != "off" { done(false, "la conversation live est en cours — arrête-la d'abord", [:]); return }
            let mic: AVAuthorizationStatus = AVCaptureDevice.authorizationStatus(for: .audio)
            if mic == .denied || mic == .restricted {
                done(false, "micro refusé : autorise Nova dans Réglages Système › Confidentialité et sécurité › Micro", [:]); return
            }
            if mic == .notDetermined {
                AVCaptureDevice.requestAccess(for: .audio) { (granted: Bool) in
                    if granted { self.start(done: done) } else { done(false, "micro refusé par l'utilisateur", [:]) }
                }
                return
            }
            let st: SFSpeechRecognizerAuthorizationStatus = SFSpeechRecognizer.authorizationStatus()
            if st == .denied || st == .restricted {
                done(false, "reconnaissance vocale refusée : autorise Nova dans Réglages Système › Confidentialité et sécurité › Reconnaissance vocale", [:]); return
            }
            if st == .notDetermined {
                SFSpeechRecognizer.requestAuthorization { (s: SFSpeechRecognizerAuthorizationStatus) in
                    if s == .authorized { self.start(done: done) } else { done(false, "reconnaissance vocale refusée", [:]) }
                }
                return
            }
            self.begin(done: done)
        }
        #else
        done(false, "dictée native indisponible sur ce système", [:])
        #endif
    }

    #if canImport(Speech) && canImport(AVFoundation) && os(macOS)
    /// Sur q.
    func begin(done: @escaping (Bool, String, [String: Any]) -> Void) {
        let langue: String = VoixReglages.langue()
        let locales: [String] = langue == "auto" ? ["fr-FR", "en-US"] : [langue]
        var ls: [VxLane] = []
        for loc in locales {
            if let r: SFSpeechRecognizer = SFSpeechRecognizer(locale: Locale(identifier: loc)), r.isAvailable {
                ls.append(VxLane(locale: loc, rec: r))
            }
        }
        guard !ls.isEmpty else {
            let e: String = "reconnaissance " + locales.joined(separator: "/") + " indisponible (réseau ou langue non téléchargée)"
            setError(e); done(false, e, [:]); return
        }
        contextual = VoixVocab.effectif()
        lanes = ls
        sessionGen += 1
        let sg: Int = sessionGen
        for lane in lanes { newTask(lane, sg: sg) }
        // Le mot de réveil partage le micro : pause pendant la dictée.
        if WakeListener.shared.running { wakeWasRunning = true; WakeListener.shared.stop() }
        DispatchQueue.main.async {
            let e: AVAudioEngine = AVAudioEngine()
            let input: AVAudioInputNode = e.inputNode
            let fmt: AVAudioFormat = input.outputFormat(forBus: 0)
            input.installTap(onBus: 0, bufferSize: 2048, format: fmt) { [weak self] (buf: AVAudioPCMBuffer, _: AVAudioTime) in
                self?.feed(buf)
            }
            e.prepare()
            var startErr0: String = ""
            do { try e.start() } catch {
                startErr0 = "micro : " + error.localizedDescription
                input.removeTap(onBus: 0)
            }
            let startErr: String = startErr0
            self.q.async {
                if !startErr.isEmpty {
                    self.cancelAllTasks()
                    self.lanes = []
                    self.restoreWake()
                    self.setError(startErr)
                    done(false, startErr, [:]); return
                }
                self.engine = e
                self.snapLock.lock(); self.running = true; self.lastError = ""; self.snapLock.unlock()
                self.startedAt = Date()
                self.lastResult = nil
                self.startTimer(sg: sg)
                self.publish?("voix_dictee", ["etat": "ecoute"])
                let onDev: Bool = self.lanes.first.map { (l: VxLane) -> Bool in l.rec.supportsOnDeviceRecognition && VoixReglages.surAppareil() } ?? false
                self.lastEngine = onDev ? "apple-sur-appareil" : "apple-serveur"
                done(true, "", ["moteur": self.lastEngine, "langue": langue, "vocabulaire": self.contextual.count])
            }
        }
    }

    /// Fil temps réel du tap : distribution aux requêtes actives + niveau (publié hors de ce fil).
    func feed(_ buf: AVAudioPCMBuffer) {
        bufLock.lock(); let reqs: [SFSpeechAudioBufferRecognitionRequest] = activeReqs; bufLock.unlock()
        for r in reqs { r.append(buf) }
        let now: Date = Date()
        if now.timeIntervalSince(lastLevelPub) < 0.09 { return }
        lastLevelPub = now
        guard let ch = buf.floatChannelData?[0] else { return }
        let n: Int = Int(buf.frameLength)
        if n == 0 { return }
        var sum: Float = 0
        var i: Int = 0
        while i < n { let v: Float = ch[i]; sum += v * v; i += 2 }
        let rms: Float = (sum / Float(max(1, n / 2))).squareRoot()
        let lvl: Double = Double(min(1, rms * 6))
        q.async { if self.running { self.publish?("voix_dictee", ["niveau": lvl]) } }
    }

    func rebuildReqs() {
        let r: [SFSpeechAudioBufferRecognitionRequest] = lanes.compactMap { (l: VxLane) -> SFSpeechAudioBufferRecognitionRequest? in l.active?.req }
        bufLock.lock(); activeReqs = r; bufLock.unlock()
    }

    /// Sur q : nouvelle tâche de reconnaissance active pour une voie.
    func newTask(_ lane: VxLane, sg: Int) {
        let req: SFSpeechAudioBufferRecognitionRequest = SFSpeechAudioBufferRecognitionRequest()
        req.shouldReportPartialResults = true
        req.taskHint = .dictation
        req.addsPunctuation = true
        req.contextualStrings = contextual
        if lane.rec.supportsOnDeviceRecognition && VoixReglages.surAppareil() { req.requiresOnDeviceRecognition = true }
        taskGen += 1
        let ctx: VxTaskCtx = VxTaskCtx(gen: taskGen, req: req)
        ctx.task = lane.rec.recognitionTask(with: req) { [weak self] (result: SFSpeechRecognitionResult?, err: Error?) in
            var text: String = ""
            var fin: Bool = false
            var conf: Float = 0
            let has: Bool = (result != nil)
            if let r: SFSpeechRecognitionResult = result {
                text = r.bestTranscription.formattedString
                fin = r.isFinal
                if fin {
                    let segs: [SFTranscriptionSegment] = r.bestTranscription.segments
                    if !segs.isEmpty { conf = segs.map { (s: SFTranscriptionSegment) -> Float in s.confidence }.reduce(0, +) / Float(segs.count) }
                }
            }
            let errMsg: String = err?.localizedDescription ?? ""
            self?.q.async { self?.onResult(lane: lane, ctx: ctx, sg: sg, text: text, fin: fin, conf: conf, has: has, errMsg: errMsg) }
        }
        lane.active = ctx
        rebuildReqs()
    }

    /// Sur q.
    func onResult(lane: VxLane, ctx: VxTaskCtx, sg: Int, text: String, fin: Bool, conf: Float, has: Bool, errMsg: String) {
        guard sg == sessionGen, !ctx.done else { return }
        let t: String = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if ctx.slot >= 0 {
            // Segment en clôture : son résultat final (ponctué, avec confiance) remplace le dernier partiel.
            if has && !t.isEmpty && ctx.slot < lane.committed.count { lane.committed[ctx.slot] = t }
            if fin { lane.confs.append(conf) }
            if fin || !errMsg.isEmpty {
                ctx.done = true
                lane.closing.removeAll { (c: VxTaskCtx) -> Bool in c === ctx }
            }
            if fin { publishPartial(force: true) }
            return
        }
        guard lane.active === ctx else { return }
        if has { lane.failStreak = 0 }
        if fin {
            // Apple a clos le segment lui-même : on l'engrange et on enchaîne.
            if !t.isEmpty { lane.committed.append(t); lane.confs.append(conf) }
            lane.current = ""
            ctx.done = true
            lane.active = nil
            if running { newTask(lane, sg: sg) } else { rebuildReqs() }
            publishPartial(force: true)
            return
        }
        if has {
            // 26/10 (audit) : si Apple repart de zéro après une pause, le nouveau partiel est court et ne prolonge pas l'ancien —
            // l'ancien est engrangé au lieu d'être écrasé (des mots disparaissaient de la dictée).
            let prev: String = lane.current
            if !prev.isEmpty && !t.isEmpty && Double(t.count) < Double(prev.count) * 0.6 {
                let head: String = String(t.lowercased().prefix(8))
                if !prev.lowercased().hasPrefix(head) { lane.committed.append(prev); lane.confs.append(0.5) }
            }
            if t != lane.current { lane.current = t; lane.lastPartialAt = Date() }
            publishPartial(force: false)
            return
        }
        if !errMsg.isEmpty {
            // Erreur sans résultat (souvent : aucun son détecté) — reprise douce, jamais de boucle serrée.
            ctx.done = true
            lane.active = nil
            let cur: String = lane.current.trimmingCharacters(in: .whitespacesAndNewlines)
            if !cur.isEmpty { lane.committed.append(cur); lane.current = "" }
            lane.failStreak += 1
            rebuildReqs()
            if lane.failStreak >= 30 {
                setError("reconnaissance " + lane.locale + " : " + errMsg)
                publish?("voix_dictee", ["etat": "erreur", "erreur": "la reconnaissance ne répond plus — " + shortError(errMsg, 80)])
                return
            }
            q.asyncAfter(deadline: .now() + 0.4) {
                guard self.running, sg == self.sessionGen, lane.active == nil else { return }
                self.newTask(lane, sg: sg)
            }
        }
    }

    /// Sur q : pause ≥ pause_ms après le dernier partiel → le segment est clos (final demandé),
    /// une tâche neuve écoute déjà la suite. Évite les réécritures tardives et la limite ~1 min.
    func startTimer(sg: Int) {
        timer?.cancel()
        let t: DispatchSourceTimer = DispatchSource.makeTimerSource(queue: q)
        t.schedule(deadline: .now() + 0.25, repeating: 0.2)
        t.setEventHandler { [weak self] in
            guard let self = self, self.running, sg == self.sessionGen else { return }
            let pause: Double = Double(VoixReglages.pauseMs()) / 1000.0
            let now: Date = Date()
            for lane in self.lanes where lane.active != nil && !lane.current.isEmpty && now.timeIntervalSince(lane.lastPartialAt) >= pause {
                self.closeSegment(lane)
                self.newTask(lane, sg: sg)
            }
            if let s0 = self.startedAt, now.timeIntervalSince(s0) > 600 {
                // Garde-fou : 10 min de dictée continue → arrêt propre, résultat gardé pour le prochain /stop.
                self.finishStop(reason: "durée maximale atteinte (10 min)") { (_: [String: Any]) in }
            }
        }
        timer = t
        t.resume()
    }

    func closeSegment(_ lane: VxLane) {
        guard let ctx: VxTaskCtx = lane.active else { return }
        ctx.slot = lane.committed.count
        lane.committed.append(lane.current.trimmingCharacters(in: .whitespacesAndNewlines))
        lane.current = ""
        lane.closing.append(ctx)
        lane.active = nil
        ctx.req.endAudio()
        q.asyncAfter(deadline: .now() + 3.0) {
            if !ctx.done { ctx.done = true; ctx.task?.cancel(); lane.closing.removeAll { (c: VxTaskCtx) -> Bool in c === ctx } }
        }
    }

    func publishPartial(force: Bool) {
        let now: Date = Date()
        if !force && now.timeIntervalSince(lastPartialPub) < 0.12 { return }
        lastPartialPub = now
        guard let lane: VxLane = lanes.first else { return }
        let txt: String = lane.text()
        publish?("voix_dictee", ["partiel": String(txt.suffix(600)), "etat": running ? "ecoute" : "transcription"])
    }

    func cancelAllTasks() {
        for lane in lanes {
            lane.active?.done = true
            lane.active?.task?.cancel()
            lane.active = nil
            for c in lane.closing { c.done = true; c.task?.cancel() }
            lane.closing = []
        }
        bufLock.lock(); activeReqs = []; bufLock.unlock()
    }

    func teardownAudio() {
        timer?.cancel(); timer = nil
        let e: AVAudioEngine? = engine
        engine = nil
        DispatchQueue.main.async {
            e?.inputNode.removeTap(onBus: 0)
            e?.stop()
        }
    }

    /// Voie retenue : une seule langue → elle ; « auto » → confiance moyenne, puis détection de langue.
    func choose() -> VxLane? {
        guard let fr: VxLane = lanes.first else { return nil }
        if lanes.count < 2 { return fr }
        let en: VxLane = lanes[1]
        let cf: Float = fr.avgConf()
        let ce: Float = en.avgConf()
        if cf >= 0 && ce >= 0 { return ce > cf + 0.08 ? en : fr }
        #if canImport(NaturalLanguage)
        let te: String = en.text()
        let tf: String = fr.text()
        if !te.isEmpty {
            let r1: NLLanguageRecognizer = NLLanguageRecognizer()
            r1.processString(te)
            let pEn: Double = r1.languageHypotheses(withMaximum: 3)[NLLanguage.english] ?? 0
            let r2: NLLanguageRecognizer = NLLanguageRecognizer()
            r2.processString(tf)
            let pFr: Double = r2.languageHypotheses(withMaximum: 3)[NLLanguage.french] ?? 0
            if pEn > 0.85 && pFr < 0.6 { return en }
        }
        #endif
        return fr
    }

    func restoreWake() {
        if wakeWasRunning {
            wakeWasRunning = false
            DispatchQueue.main.async { _ = WakeListener.shared.begin() }
        }
    }

    /// Sur q : coupe le micro, attend les finals (≤ 1,3 s), choisit la voie, corrige, publie.
    func finishStop(reason: String, done: @escaping ([String: Any]) -> Void) {
        guard running else { done(lastResult ?? ["ok": false, "erreur": "aucune dictée en cours"]); return }
        snapLock.lock(); running = false; snapLock.unlock()
        teardownAudio()
        for lane in lanes { if lane.active != nil { closeSegment(lane) } }
        rebuildReqs()
        publish?("voix_dictee", ["etat": "transcription"])
        let deadline: Date = Date().addingTimeInterval(1.3)
        let sg: Int = sessionGen
        func waitLoop() {
            guard sg == self.sessionGen else { return }
            let pending: Bool = self.lanes.contains { (l: VxLane) -> Bool in !l.closing.isEmpty }
            if pending && Date() < deadline {
                self.q.asyncAfter(deadline: .now() + 0.08) { waitLoop() }
                return
            }
            let chosen: VxLane? = self.choose()
            let brut: String = chosen?.text() ?? ""
            let langue: String = chosen?.locale ?? ""
            self.cancelAllTasks()
            self.sessionGen += 1
            let fixed: String = VoixPost.corriger(brut, vocab: self.contextual)
            let ms: Int = Int(Date().timeIntervalSince(self.startedAt ?? Date()) * 1000)
            let res: [String: Any] = ["ok": true, "text": fixed, "brut": brut, "langue": langue, "moteur": self.lastEngine,
                                      "corrige": fixed != brut, "duree_ms": ms, "raison": reason]
            self.lastResult = res
            self.lastResultAt = Date()
            self.snapLock.lock(); self.lastLangue = langue; self.lastAt = nowISO(); self.snapLock.unlock()
            self.journal.add(["stt": "apple-dictee", "moteur": self.lastEngine, "langue": langue, "chars": fixed.count,
                              "corrige": fixed != brut, "duree_ms": ms, "voies": self.lanes.count])
            self.lanes = []
            self.restoreWake()
            self.publish?("voix_dictee", ["etat": "repos"])
            done(res)
        }
        waitLoop()
    }
    #endif

    public func stop(done: @escaping ([String: Any]) -> Void) {
        #if canImport(Speech) && canImport(AVFoundation) && os(macOS)
        q.async {
            if !self.running {
                if let r = self.lastResult, Date().timeIntervalSince(self.lastResultAt) < 120 { self.lastResult = nil; done(r); return }
                done(["ok": false, "erreur": "aucune dictée en cours"]); return
            }
            self.finishStop(reason: "arrêt demandé", done: done)
        }
        #else
        done(["ok": false, "erreur": "dictée native indisponible sur ce système"])
        #endif
    }

    public func cancel() {
        #if canImport(Speech) && canImport(AVFoundation) && os(macOS)
        q.async {
            guard self.running else { return }
            self.snapLock.lock(); self.running = false; self.snapLock.unlock()
            self.teardownAudio()
            self.cancelAllTasks()
            self.sessionGen += 1
            self.lanes = []
            self.lastResult = nil
            self.restoreWake()
            self.publish?("voix_dictee", ["etat": "repos"])
        }
        #endif
    }
}

// MARK: - Phrases d'attente (voix live) — variées, jamais la même deux fois de suite

public enum VoixAttente {
    static let lock: NSLock = NSLock()
    static var last: String = ""
    static let neutres: [String] = ["Une seconde…", "Voyons voir…", "Laisse-moi réfléchir une seconde…", "D'accord, je réfléchis…", "Je te dis ça tout de suite…"]

    /// Phrase pour un outil RÉELLEMENT lancé (nom de l'outil), sinon phrase neutre (réflexion lente).
    public static func phrase(outil: String?) -> String {
        var pool: [String] = neutres
        if let o0 = outil {
            let o: String = o0.lowercased()
            if o.contains("mail") || o.contains("inbox") || o.contains("outlook") || o.contains("boite") { pool = ["Je regarde ta boîte…", "Je jette un œil à tes mails…", "Je regarde tes messages…"] }
            else if o.contains("agenda") || o.contains("calendar") || o.contains("event") || o.contains("reunion") { pool = ["Je regarde ton agenda…", "Je vérifie ton calendrier…"] }
            else if o.contains("web") || o.contains("search") || o.contains("recherche") || o.contains("fetch") { pool = ["Je cherche ça…", "Je fais une recherche rapide…", "Je regarde en ligne…"] }
            else if o.contains("file") || o.contains("fichier") || o.contains("read") || o.contains("doc") { pool = ["J'ouvre le fichier…", "Je regarde le document…"] }
            else if o.contains("brvm") || o.contains("bourse") || o.contains("portfolio") || o.contains("cours") { pool = ["Je regarde les cours…", "Je vérifie ton portefeuille…"] }
            else if o.contains("teams") { pool = ["Je regarde Teams…", "Je jette un œil à tes discussions…"] }
            else { pool = ["Je vérifie…", "Je regarde ça…", "Je m'en occupe…"] }
        }
        lock.lock(); defer { lock.unlock() }
        let choices: [String] = pool.filter { (p: String) -> Bool in p != last }
        let pick: String = (choices.isEmpty ? pool : choices).randomElement() ?? "Une seconde…"
        last = pick
        return pick
    }
}

// MARK: - Routes

extension NovaApp {
    func voix2Routes() {
        let s = server
        let busRef: Bus = bus
        VoixVocab.memory = memory
        VoixDictee.shared.publish = { (ev: String, payload: [String: Any]) in busRef.publish(ev, payload) }

        func vocabPayload() -> [String: Any] {
            let man = VoixVocab.manual()
            let eff: [String] = VoixVocab.effectif()
            return ["calcule": VoixVocab.calcule(), "ajouts": man.ajouts, "retraits": man.retraits,
                    "effectif": eff, "total": eff.count, "limite": VoixVocab.limite]
        }
        func reglagesPayload() -> [String: Any] {
            var d: [String: Any] = VoixReglages.all()
            d["moteur"] = VoixReglages.moteur()
            d["langue"] = VoixReglages.langue()
            d["pause_ms"] = VoixReglages.pauseMs()
            #if canImport(Speech) && canImport(AVFoundation) && os(macOS)
            d["apple_dispo"] = true
            #else
            d["apple_dispo"] = false
            #endif
            return d
        }

        s.on("GET", "/api/voix/vocabulaire") { _, res in res.json(vocabPayload()) }
        s.on("POST", "/api/voix/vocabulaire") { req, res in
            let b: [String: Any] = req.json
            if let e = VoixVocab.modify(ajout: b["ajout"] as? String, retrait: b["retrait"] as? String) {
                res.json(["ok": false, "erreur": e], status: 400); return
            }
            var p: [String: Any] = vocabPayload(); p["ok"] = true
            res.json(p)
        }
        s.on("GET", "/api/voix/reglages") { _, res in res.json(reglagesPayload()) }
        s.on("POST", "/api/voix/reglages") { req, res in
            if let e = VoixReglages.apply(req.json) { res.json(["ok": false, "erreur": e], status: 400); return }
            var p: [String: Any] = reglagesPayload(); p["ok"] = true
            res.json(p)
        }
        s.on("POST", "/api/voix/corriger") { req, res in
            let t: String = (req.json["text"] as? String) ?? ""
            res.json(["text": VoixPost.corriger(t), "brut": t])
        }

        // Dictée native (web) : start → partiels sur le bus « voix_dictee » → stop rend le texte corrigé.
        s.on("POST", "/api/voix/dictee/start") { _, res in
            let sem: DispatchSemaphore = DispatchSemaphore(value: 0)
            var ok: Bool = false
            var err: String = ""
            var info: [String: Any] = [:]
            VoixDictee.shared.start { (o: Bool, e: String, i: [String: Any]) in ok = o; err = e; info = i; sem.signal() }
            if sem.wait(timeout: .now() + 20) == .timedOut { res.json(["ok": false, "erreur": "délai dépassé (autorisation micro ou reconnaissance en attente)"], status: 504); return }
            var p: [String: Any] = info; p["ok"] = ok; p["erreur"] = err
            res.json(p, status: ok ? 200 : 409)
        }
        s.on("POST", "/api/voix/dictee/stop") { _, res in
            let sem: DispatchSemaphore = DispatchSemaphore(value: 0)
            var out: [String: Any] = [:]
            VoixDictee.shared.stop { (r: [String: Any]) in out = r; sem.signal() }
            if sem.wait(timeout: .now() + 8) == .timedOut { res.json(["ok": false, "erreur": "délai dépassé à l'arrêt de la dictée"], status: 504); return }
            res.json(out, status: ((out["ok"] as? Bool) ?? false) ? 200 : 409)
        }
        s.on("POST", "/api/voix/dictee/annuler") { _, res in
            VoixDictee.shared.cancel()
            res.json(["ok": true])
        }

        // Transcription d'un enregistrement (repli web) — Muse Voice Transcribe (Meta), même corps que /api/stt.
        s.on("POST", "/api/voix/transcrire") { [self] req, res in
            var audio: Data = req.body
            var mime: String = req.headers["content-type"] ?? "audio/wav"
            if let b64 = req.json["audio_b64"] as? String {
                guard let d = Data(base64Encoded: b64) else { res.json(["error": "audio_b64 illisible (base64 invalide)", "audio_bytes": 0], status: 400); return }
                audio = d
                if let t = req.json["type"] as? String, !t.isEmpty { mime = t }
            }
            guard !audio.isEmpty else { res.json(["error": "enregistrement vide (0 octet) — le son n'est pas parvenu à Nova", "audio_bytes": 0, "audio_type": mime], status: 400); return }
            let vocab: [String] = VoixVocab.effectif()
            let lang: String = VoixReglages.codeCloud()
            var text: String? = nil
            var via: String = ""
            var errs: [String] = []
            if text == nil {
                let r = voice.transcribe(audio: audio, mime: mime, language: lang)
                if let t = r.text { text = t; via = r.via ?? "inconnu" } else { errs.append(r.error ?? "échec") }
            }
            guard let brut = text else {
                VoixDictee.shared.setError(shortError(errs.joined(separator: " · "), 200))
                res.json(["error": errs.joined(separator: " · "), "audio_bytes": audio.count, "audio_type": mime], status: 502); return
            }
            let fixed: String = VoixPost.corriger(brut, vocab: vocab)
            res.json(["text": fixed, "brut": brut, "via": via, "corrige": fixed != brut])
        }

        // Diagnostic honnête : uniquement ce qui est lu sur la machine, jamais d'état supposé.
        s.on("GET", "/api/voix/diagnostic") { [self] _, res in
            var d: [String: Any] = [:]
            var langs: [String: Any] = [:]
            #if canImport(Speech) && canImport(AVFoundation) && os(macOS)
            let mic: AVAuthorizationStatus = AVCaptureDevice.authorizationStatus(for: .audio)
            switch mic {
            case .authorized: d["micro"] = "autorisé"
            case .denied: d["micro"] = "refusé"
            case .restricted: d["micro"] = "restreint"
            case .notDetermined: d["micro"] = "jamais demandé"
            @unknown default: d["micro"] = "inconnu"
            }
            let sp: SFSpeechRecognizerAuthorizationStatus = SFSpeechRecognizer.authorizationStatus()
            switch sp {
            case .authorized: d["reconnaissance"] = "autorisée"
            case .denied: d["reconnaissance"] = "refusée"
            case .restricted: d["reconnaissance"] = "restreinte"
            case .notDetermined: d["reconnaissance"] = "jamais demandée"
            @unknown default: d["reconnaissance"] = "inconnue"
            }
            for loc in ["fr-FR", "fr-CA", "en-US"] {
                if let r: SFSpeechRecognizer = SFSpeechRecognizer(locale: Locale(identifier: loc)) {
                    let one: [String: Any] = ["disponible": r.isAvailable, "sur_appareil": r.supportsOnDeviceRecognition]
                    langs[loc] = one
                } else {
                    let none: [String: Any] = ["disponible": false, "sur_appareil": false]
                    langs[loc] = none
                }
            }
            #else
            d["micro"] = "indisponible sur ce système"
            d["reconnaissance"] = "indisponible sur ce système"
            #endif
            #if os(macOS)
            d["accessibilite_dictee_systeme"] = AXIsProcessTrusted()
            #endif
            d["langues"] = langs
            let principal: String = VoixReglages.localePrincipale()
            let onDev: Bool = ((langs[principal] as? [String: Any])?["sur_appareil"] as? Bool) ?? false
            d["sur_appareil_dispo"] = onDev
            d["moteur_actif"] = onDev ? "reconnaissance système sur l'appareil (en flux)" : "reconnaissance système (langue sans modèle sur l'appareil)"
            d["reglages"] = reglagesPayload()
            d["transcription_enregistrement"] = "muse-voice-transcribe-1.0 (API Meta Model)"
            let nat: [String: Any] = VoixDictee.shared.snapshot()
            d["dictee_app"] = nat
            let sys: [String: Any] = ["en_cours": Dictee.shared.running, "derniere_erreur": Dictee.shared.lastError]
            d["dictee_systeme"] = sys
            d["voix_live"] = VoiceLiveEngine.shared.snapshot()
            let wk: [String: Any] = ["actif": WakeListener.shared.running, "derniere_erreur": WakeListener.shared.lastError]
            d["mot_de_reveil"] = wk
            d["vocabulaire_termes"] = VoixVocab.effectif().count
            let errs: [String] = [(nat["derniere_erreur"] as? String) ?? "", Dictee.shared.lastError, WakeListener.shared.lastError].filter { (x: String) -> Bool in !x.isEmpty }
            d["derniere_erreur"] = errs.first ?? ""
            res.json(d)
        }
    }
}
