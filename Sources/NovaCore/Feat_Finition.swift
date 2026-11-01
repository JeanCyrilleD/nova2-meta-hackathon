import Foundation

/// 29/10 (Ahadi : « qualité aléatoire des réponses ») — finition de la réponse FINALE avant enregistrement et affichage.
/// Constat (note ACLED 22:43) : les annonces d'étape (« Je m'en occupe… », « Je lis… », « J'ai assez pour livrer… ») et
/// un résumé en double précédaient le BLUF, et la carte du livrable arrivait avant la synthèse.
/// Règle : si la réponse a un BLUF (citation « > **BLUF ») ou un premier titre « ## », la prose qui le précède est retirée
/// (elle ne contient que des annonces et un pré-résumé que le BLUF reprend) ; les blocs ```nova-livrable qui le précédaient
/// sont replacés juste avant le bloc ```nova-suites (ou à la fin). Le BLUF est ainsi TOUJOURS la première chose lue.
public enum Finition {
    /// 29/10 : note interne du moteur recopiée par le cerveau (« [Outils utilisés (note du moteur… ] ») ou en-têtes moteur → retirés.
    static func stripEngineNotes(_ s: String) -> String {
        var t: String = s
        while let r = t.range(of: "[Outils utilisés") {
            let lineEnd: String.Index = t[r.lowerBound...].firstIndex(of: "\n") ?? t.endIndex
            let seg: Substring = t[r.lowerBound..<lineEnd]
            if let close = seg.lastIndex(of: "]") { t.removeSubrange(r.lowerBound...close) } else { t.removeSubrange(r.lowerBound..<lineEnd) }
        }
        let kept: [String] = t.components(separatedBy: "\n").filter { (l: String) -> Bool in
            let x = l.trimmingCharacters(in: .whitespaces)
            return !(x.hasPrefix("[MOTEUR NOVA") || x.hasPrefix("[RÉSULTAT DE L'OUTIL"))
        }
        return kept.joined(separator: "\n").replacingOccurrences(of: "\n\n\n+", with: "\n\n", options: .regularExpression)
    }

    public static func polish(_ s0: String) -> String {
        // 30/10 (test direct : un portefeuille dont le total et le tableau précédaient « ## Remarques » a été AMPUTÉ — l'ancre « ## »
        // prenait les tableaux pour de la prose d'annonce). Le serveur ne fait plus que retirer les notes moteur ; la mise en ordre
        // (BLUF en tête, annonces retirées, livrable en fin) est faite à l'affichage par web/js/normalize.js, testé sur 25 cas.
        return stripEngineNotes(s0).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    public static func polishLegacy(_ s0: String) -> String {
        let s: String = stripEngineNotes(s0)
        let lines: [String] = s.components(separatedBy: "\n")
        guard let anchor = lines.firstIndex(where: { (l: String) -> Bool in
            let t = l.trimmingCharacters(in: .whitespaces)
            return t.hasPrefix("> **BLUF") || t.hasPrefix(">**BLUF") || t.hasPrefix("> BLUF") || t.hasPrefix("## ")
        }), anchor > 0 else { return s.trimmingCharacters(in: .whitespacesAndNewlines) }
        // Prose avant l'ancre : on garde seulement les blocs de code (livrables, cartes).
        var moved: [String] = []
        var i: Int = 0
        var proseChars: Int = 0
        while i < anchor {
            let t: String = lines[i].trimmingCharacters(in: .whitespaces)
            if t.hasPrefix("```") {
                var block: [String] = [lines[i]]; i += 1
                while i < anchor { block.append(lines[i]); if lines[i].trimmingCharacters(in: .whitespaces).hasPrefix("```") { i += 1; break }; i += 1 }
                moved.append(block.joined(separator: "\n"))
                continue
            }
            proseChars += t.count
            i += 1
        }
        // Garde-fou : une vraie introduction longue (> 900 caractères) n'est pas une annonce — on ne touche à rien.
        if proseChars > 900 { return s.trimmingCharacters(in: .whitespacesAndNewlines) }
        var rest: [String] = Array(lines[anchor...])
        if !moved.isEmpty {
            let insertAt: Int = rest.firstIndex(where: { $0.trimmingCharacters(in: .whitespaces).hasPrefix("```nova-suites") }) ?? rest.count
            rest.insert(contentsOf: ["", moved.joined(separator: "\n\n"), ""], at: insertAt)
        }
        return rest.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
