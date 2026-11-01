import Foundation

/// 01/11 (Ahadi : « le moins hallucinant ») — VÉRIFICATION LÉGÈRE DES SOURCES dans les réponses ORDINAIRES (pas seulement CAFU).
/// Le mode CAFU a déjà sa garde de citation (Feat_CafuMode.swift). Ici, même principe pour le chat ordinaire, sans aucun appel
/// supplémentaire de modèle tant que la réponse est propre :
///   1) une URL citée dans la réponse doit apparaître dans un résultat d'outil de CE tour, dans le fil ou dans le prompt système ;
///   2) si des outils sont disponibles et qu'au moins une URL est non sourcée → UNE passe de continuation (le cerveau vérifie
///      avec web_search/web_fetch, ou retire l'URL, ou la marque [[NON CONFIRMÉ]]) ;
///   3) ce qui reste non sourcé après cette passe (ou sans outils) est marqué [[NON CONFIRMÉ]] de façon déterministe.
/// Les pages d'accueil (hôte sans chemin, ex. https://brvm.org) sont tolérées : elles indiquent où chercher, sans rien affirmer.
/// COUPER sans recompiler : réglage « verif_faits » = false.
public enum FactGate {

    /// Textes vus pendant le tour (sorties d'outils), thread-safe. Plafond de taille pour ne jamais grossir sans borne.
    public final class Seen: @unchecked Sendable {
        private let lock = NSLock()
        private var parts: [String] = []
        private var total: Int = 0
        public init() {}
        public func add(_ s: String) {
            lock.lock(); defer { lock.unlock() }
            guard total < 2_000_000 else { return }
            let p: String = String(s.prefix(200_000))
            parts.append(p); total += p.utf8.count
        }
        public var all: [String] { lock.lock(); defer { lock.unlock() }; return parts }
    }

    public static let marque: String = "[[NON CONFIRMÉ]]"

    static func enabled(_ settings: Settings = Settings()) -> Bool { settings.get("verif_faits", true) }

    /// Formes normalisées de toutes les URL présentes dans les textes autorisés (les « \/ » des JSON sont dé-échappés).
    static func normsAutorisees(_ allowed: [String]) -> Set<String> {
        var out: Set<String> = []
        for t in allowed {
            let clair: String = t.replacingOccurrences(of: "\\/", with: "/")
            for u in CafuMode.cited(clair) { let n: String = CafuMode.norm(u); if !n.isEmpty { out.insert(n) } }
        }
        return out
    }

    /// URL citées dans `answer` qui ne figurent dans aucun texte autorisé (ordre d'apparition, sans doublon).
    public static func unsourced(answer: String, allowed: [String]) -> [String] {
        let ok: Set<String> = normsAutorisees(allowed)
        var out: [String] = []
        for u in CafuMode.cited(answer) {
            let n: String = CafuMode.norm(u)
            if n.isEmpty || ok.contains(n) { continue }
            if !n.contains("/") && !n.contains("?") { continue }        // page d'accueil : indique où chercher, n'affirme rien
            if u.contains(marque) { continue }
            if !out.contains(u) { out.append(u) }
        }
        return out
    }

    /// Consigne de continuation (une seule passe) si des URL ne sont pas sourcées et que des outils permettent de vérifier.
    public static func check(answer: String, allowed: [String], toolsAvailable: Bool) -> String? {
        guard toolsAvailable else { return nil }
        let bad: [String] = unsourced(answer: answer, allowed: allowed)
        guard !bad.isEmpty else { return nil }
        _ = BlackBox.record(["tool": "verif_faits", "actor": "Nova", "ok": false, "effect": "lecture",
                             "why": "URL citée(s) absente(s) des résultats d'outils du tour : " + String(bad.count),
                             "result": bad.prefix(3).joined(separator: " ")])
        return "[MOTEUR NOVA — VÉRIFICATION DES SOURCES] Ta réponse cite des adresses qu'aucun outil de ce tour n'a renvoyées : "
            + bad.prefix(6).joined(separator: " ; ")
            + ". Pour chacune : vérifie-la maintenant avec web_search ou web_fetch et garde-la seulement si tu l'as lue ; sinon retire-la, ou garde le fait en le marquant [[NON CONFIRMÉ]]. Ne rajoute aucune adresse que tu n'as pas lue. Livre ensuite la réponse complète mise à jour, résultat en tête, sans annoncer tes étapes."
    }

    /// Marque [[NON CONFIRMÉ]] après chaque URL non sourcée (idempotent : une URL déjà suivie de la marque n'est pas re-marquée).
    public static func annotate(answer: String, allowed: [String]) -> String {
        let bad: Set<String> = Set(unsourced(answer: answer, allowed: allowed))
        guard !bad.isEmpty, let rx = try? NSRegularExpression(pattern: "https?://[^\\s<>\"'\\])}|»«*]+") else { return answer }
        let m: NSMutableString = NSMutableString(string: answer)
        let matches: [NSTextCheckingResult] = rx.matches(in: answer, range: NSRange(location: 0, length: m.length))
        for r in matches.reversed() {
            let brut: String = m.substring(with: r.range)
            let u: String = CafuMode.trimURL(brut)
            guard bad.contains(u) else { continue }
            let fin: Int = r.range.location + (u as NSString).length          // juste après l'URL, ponctuation finale exclue
            let reste: String = m.substring(from: fin)
            if reste.trimmingCharacters(in: .whitespaces).hasPrefix(marque) { continue }
            m.insert(" " + marque, at: fin)
        }
        return m as String
    }
}
