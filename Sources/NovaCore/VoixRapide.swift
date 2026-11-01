import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// 01/11 (voix-rapide) — LOGIQUE PURE de la voix « premier son plus tôt » (testée sans micro, sans réseau, sans clé).
/// Portable sur la branche 100 % Meta : aucune dépendance à un fournisseur non Meta. La langue est devinée localement
/// (mots-outils), l'accusé de réception est rendu par AVSpeech (LocalVoice), la reconnaissance reste SFSpeech.
/// (Fichier hors Feat_* : cliquet de verify.sh, ≤ 89 fichiers Feat_.)
public enum VoixRapide {

    // MARK: - Première clause (synthèse dès une clause courte)

    /// Première clause disible du tampon, avant toute fin de phrase : une virgule (« , » « ; » « : ») suivie d'un blanc,
    /// ou au moins `minMots` mots complets (le dernier suivi d'un blanc). nil = attendre. « 2,5 » n'est pas une virgule de clause.
    public static func premiereClause(_ buf: String, minMots: Int = 6) -> (clause: String, rest: String)? {
        let chars: [Character] = Array(buf)
        var words: Int = 0
        var inWord: Bool = false
        var i: Int = 0
        while i < chars.count {
            let c: Character = chars[i]
            let blank: Bool = c == " " || c == "\n" || c == "\t"
            if blank {
                if inWord {
                    words += 1; inWord = false
                    if words >= minMots {
                        let clause: String = String(chars[0..<i]).trimmingCharacters(in: .whitespacesAndNewlines)
                        return (VLSentences.clean(clause), VLSentences.dropLeadingBlanks(String(chars[i...])))
                    }
                }
            } else {
                inWord = true
                if (c == "," || c == ";" || c == ":"), i + 1 < chars.count, chars[i + 1] == " " || chars[i + 1] == "\n" {
                    let clause: String = String(chars[0...i]).trimmingCharacters(in: .whitespacesAndNewlines)
                    if clause.count >= 3 { return (VLSentences.clean(clause), VLSentences.dropLeadingBlanks(String(chars[(i + 1)...]))) }
                }
            }
            i += 1
        }
        return nil
    }

    /// Découpe du flux : tant que rien n'a été dit dans le tour (`premier`), la première clause part seule ;
    /// ensuite, la règle des phrases (VLSentences) s'applique. Une fin de phrase arrivée avant la clause est prioritaire.
    public static func decoupe(_ buf: String, premier: Bool) -> (ready: [String], rest: String) {
        if premier {
            if let (s, r) = VLSentences.firstSentence(in: buf) {
                let more = VLSentences.extract(r)
                return ([s] + more.ready, more.rest)
            }
            if let (c, r) = premiereClause(buf) {
                let more = VLSentences.extract(r)
                return ([c] + more.ready, more.rest)
            }
            return ([], buf)
        }
        return VLSentences.extract(buf)
    }

    // MARK: - Langue de la réponse (lue par une voix de la même langue)

    static let motsEN: Set<String> = ["the", "is", "are", "and", "of", "to", "you", "your", "i", "i'm", "it", "it's", "that", "this", "what", "which",
        "with", "for", "not", "don't", "have", "has", "be", "can", "could", "would", "should", "there", "here", "about", "from", "will", "my", "we",
        "they", "do", "does", "sure", "know", "were", "was", "been", "these", "those", "how", "why", "where", "when", "who", "or", "but", "if", "than",
        "then", "yes", "no", "okay", "please", "thanks", "an", "at", "by", "into", "our", "their", "any", "some", "more", "most", "check", "latest"]
    static let motsFR: Set<String> = ["le", "la", "les", "des", "du", "de", "un", "une", "est", "et", "je", "tu", "vous", "nous", "pas", "que", "qui",
        "pour", "avec", "sur", "dans", "ce", "cette", "ces", "il", "elle", "ils", "elles", "sont", "ne", "au", "aux", "mais", "ou", "oui", "non",
        "très", "être", "avoir", "fait", "faut", "peux", "peut", "suis", "sais", "c'est", "d'accord", "j'ai", "n'ai", "l'", "d'", "j'", "n'", "qu'",
        "s'", "quel", "quelle", "quels", "quelles", "comment", "pourquoi", "selon", "chez", "entre", "aussi", "encore", "voici", "voilà", "merci"]

    /// « en » ou « fr » d'après les mots-outils et les accents ; `defaut` en cas d'égalité (texte trop court, sigles).
    public static func langue(_ text: String, defaut: String = "fr") -> String {
        let low: String = text.lowercased().replacingOccurrences(of: "’", with: "'")
        var en: Int = 0, fr: Int = 0
        for raw in low.components(separatedBy: CharacterSet.letters.union(CharacterSet(charactersIn: "'")).inverted) where !raw.isEmpty {
            if motsEN.contains(raw) { en += 1 }
            if motsFR.contains(raw) { fr += 1 }
            if let a = raw.firstIndex(of: "'"), a != raw.startIndex {
                let head: String = String(raw[...a])
                if motsFR.contains(head) { fr += 1 }   // l'…, d'…, j'…, n'…, qu'…
            }
        }
        for ch in low where "éèêàùûôîçœ".contains(ch) { fr += 1 }
        if en > fr { return "en" }
        if fr > en { return "fr" }
        return defaut.hasPrefix("en") ? "en" : "fr"
    }

    /// Langue passée à LocalVoice : « en » = voix anglaise ; nil = voix française (comportement historique).
    public static func langueVoix(_ l: String) -> String? { l.hasPrefix("en") ? "en" : nil }

    // MARK: - Accusé de réception instantané (« Mm. », « D'accord, »)

    public static let seuilAccuseMs: Int = 700
    static let accusesFR: [String] = ["Mm.", "D'accord,"]
    static let accusesEN: [String] = ["Mm.", "Okay,"]
    public static func accuses(langue: String) -> [String] { langue.hasPrefix("en") ? accusesEN : accusesFR }

    /// Phrase d'accusé : jamais la même que la précédente.
    public static func phraseAccuse(langue: String, precedente: String) -> String {
        let pool: [String] = accuses(langue: langue)
        return pool.first(where: { $0 != precedente }) ?? pool[0]
    }

    /// Jouer l'accusé ? Réglage actif, réponse sans aucun son après le seuil, tour non clos, et JAMAIS deux tours de suite.
    public static func doitAccuser(reglage: Bool, ecouleMs: Int, dejaDuSon: Bool, tourClos: Bool, accuseAuTourPrecedent: Bool,
                                   seuilMs: Int = seuilAccuseMs) -> Bool {
        return reglage && ecouleMs >= seuilMs && !dejaDuSon && !tourClos && !accuseAuTourPrecedent
    }

    // MARK: - Départ anticipé (fin de parole → cerveau avec le partiel)

    /// Le partiel est-il stable ? (aucun nouveau partiel depuis `stableMs`, ou attente plafonnée à `plafondMs` depuis la fin de parole).
    public static func partielStable(depuisDernierPartielMs: Int, depuisFinParoleMs: Int, stableMs: Int = 250, plafondMs: Int = 500) -> Bool {
        return depuisDernierPartielMs >= stableMs || depuisFinParoleMs >= plafondMs
    }

    /// Ahadi reprend la parole pendant la fenêtre du départ anticipé : au moins un mot réel (≥ 3 lettres), pas l'écho de Nova.
    public static func repriseDeParole(_ partiel: String, dejaDit: String) -> Bool {
        let w: [String] = mots(partiel)
        guard !w.isEmpty else { return false }
        let dit: Set<String> = Set(mots(dejaDit))
        let neufs: Int = w.filter { !dit.contains($0) }.count
        return Double(neufs) / Double(w.count) >= 0.7
    }
    static func mots(_ s: String) -> [String] {
        s.lowercased().components(separatedBy: CharacterSet.alphanumerics.inverted).filter { $0.count >= 3 }
    }

    /// Texte du tour fusionné : début dit avant la pause + suite (sans doubler un recouvrement éventuel).
    public static func fusion(_ debut: String, _ suite: String) -> String {
        let a: String = debut.trimmingCharacters(in: .whitespacesAndNewlines)
        let b: String = suite.trimmingCharacters(in: .whitespacesAndNewlines)
        if a.isEmpty { return b }
        if b.isEmpty { return a }
        if b.lowercased().hasPrefix(a.lowercased()) { return b }   // la reconnaissance a rendu le tout
        var base: String = a
        while let last = base.last, ".!?…".contains(last) { base.removeLast() }
        return base + " " + b
    }

    // MARK: - Préchauffage de la connexion HTTP vers api.meta.ai (dès que le micro s'ouvre)

    final class Warm: @unchecked Sendable { let lock = NSLock(); var at: Date = .distantPast; var count: Int = 0 }
    static let warm = Warm()
    public static var prechauffageMeta: URL = URL(string: "https://api.meta.ai/v1/models")!   // surchargé par les tests (serveur local)

    /// Ouvre (ou garde chaude) la connexion HTTP/2 partagée (HTTPPool) vers api.meta.ai : une requête HEAD sans clé ni corps,
    /// hors fil appelant. Au plus une toutes les `intervalle` secondes. Rend vrai si une sonde est partie.
    @discardableResult
    public static func prechaufferMeta(intervalle: TimeInterval = 20, attendre: Bool = false) -> Bool {
        warm.lock.lock()
        if Date().timeIntervalSince(warm.at) < intervalle { warm.lock.unlock(); return false }
        warm.at = Date(); warm.count += 1
        warm.lock.unlock()
        let url: URL = prechauffageMeta
        let go: () -> Void = { _ = headProbe(url, timeout: 4) }
        if attendre { go() } else { DispatchQueue.global(qos: .userInitiated).async(execute: go) }
        return true
    }
    static func resetPrechauffage() { warm.lock.lock(); warm.at = .distantPast; warm.count = 0; warm.lock.unlock() }
    static func prechauffages() -> Int { warm.lock.lock(); defer { warm.lock.unlock() }; return warm.count }

    // MARK: - Vocabulaire (SFSpeech contextualStrings + Voice Transcribe « keywords »)

    /// Noms de pays du Sahel et sigles humanitaires : toujours en tête du vocabulaire (jamais coupés par la limite de 100 termes).
    public static let vocabulairePrioritaire: [String] = [
        "Mali", "Burkina Faso", "Niger", "Tchad", "Mauritanie", "Sénégal", "Nigeria", "Cameroun", "Sahel", "Lac Tchad", "Liptako-Gourma",
        "CAFU", "OCHA", "GHO", "UNICEF", "SCI", "ONG", "DRC", "HCR", "PAM", "OIM", "IPC", "Save the Children"]

    /// Mots-clés envoyés à Muse Voice Transcribe (champ « keywords » documenté, dev.meta.ai/docs/api-reference/voice/schemas) :
    /// liste FIXE (sigles, pays, villes, termes métier) — jamais les contacts ni la mémoire d'Ahadi.
    public static func motsClesMeta(max: Int = 60) -> [String] {
        var out: [String] = []
        var seen: Set<String> = []
        for t in vocabulairePrioritaire + VoixVocab.metier + VoixVocab.villes {
            let k: String = VoixVocab.key(t)
            if k.isEmpty || seen.contains(k) || t == "Ahadi" || t == "Dahani" { continue }
            seen.insert(k); out.append(t)
            if out.count >= max { break }
        }
        return out
    }

    /// « languageBias » documenté (noms de langue anglais) ; nil = détection par le modèle (« auto »).
    public static func languageBias(_ language: String) -> [String]? {
        let l: String = language.lowercased()
        if l == "auto" || l.isEmpty { return nil }
        if l.hasPrefix("en") { return ["English"] }
        if l.hasPrefix("fr") { return ["French"] }
        return nil
    }

    // MARK: - Réponses vides de Spark

    /// Plafond de sortie minimal de Spark en mode « voice » : son raisonnement (même « minimal ») est facturé en jetons de sortie
    /// mais n'est PAS diffusé ; à 320 jetons, il pouvait consommer tout le plafond → aucun texte (banc du 01/11 08:42).
    public static let plancherSortieVoixMeta: Int = 1024

    /// Motif nommé d'une réponse sans texte (finish_reason relevé dans le flux).
    public static func motifVide(finish: String, raisonnementVu: Bool) -> String {
        if finish == "length" { return "réponse vide (finish_reason length : plafond de sortie atteint pendant le raisonnement non diffusé)" }
        if finish == "content_filter" { return "réponse vide (finish_reason content_filter : filtre de contenu du fournisseur)" }
        if raisonnementVu { return "raisonnement sans texte (plafond de sortie atteint pendant la réflexion)" }
        return finish.isEmpty ? "réponse vide" : "réponse vide (finish_reason " + finish + ")"
    }
    /// Échec qui mérite UNE relance : le fournisseur a répondu SANS texte (ni erreur réseau, ni refus de clé, ni budget).
    public static func relancerSiVide(_ message: String) -> Bool {
        let m: String = message.lowercased()
        return m.contains("réponse vide") || m.contains("raisonnement sans texte")   // aussi « Tous les cerveaux ont échoué. Dernier : … réponse vide »
    }
    /// Dernier recours, honnête, après la relance : jamais le silence.
    public static func phraseSansReponse(langue: String) -> String {
        langue.hasPrefix("en") ? "I don't have an answer to that right now, could you rephrase?" : "Je n'ai pas de réponse là-dessus pour l'instant, tu peux reformuler ?"
    }
}
